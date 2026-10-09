"""Containers around Skate 3's EA SNR (EAAC) audio streams.

Layouts were worked out from the owned disc's archives (docs/hails-additions/11-audio.md):

- SNR header: u32 version(4) | codec(4) | channels-1(6) | sample rate(18);
  u32 type(2) | loop(1) | sample count(29); u32 loop start when looping.
  RAM streams (type 0) are followed by blocks: u8 flag (0x00, or 0x80 = last),
  u24 block size (incl. this 8-byte header), u32 samples in the block.
- SPLC `.bnk` (patch banks): u32 stream count at 0x18, parameter records, then
  that many SNR streams back to back at unaligned offsets.
- `.grain` (rolling surfaces): u32 offset of the SNR stream, f32 duration in
  seconds, a seek table (the `.sek` layout), then one SNR stream.

- `.ems` (per-map world emitters, `sfx_<map>.ems` etc.): u32 record count, then
  72-byte records: u32 index, u32 flags, f32 position[3], f32 extent[3],
  f32 scalars[4] (level, then the cos and sin of a yaw at [1] and [3]),
  u64 sound id, f32 gains[4]. The sound id is `name_id` of a bank's name.

vgmstream reads standalone SNR/SNS and ABKC banks itself; the SPLC and grain
streams are cut out with these helpers into standalone `.snr` files for it.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass

EA_XMA = 3


@dataclass(frozen=True)
class SnrStream:
    offset: int
    end: int
    codec: int
    channels: int
    sample_rate: int
    samples: int
    loop_start: int | None

    @property
    def seconds(self) -> float:
        return self.samples / self.sample_rate


def _u32(data: bytes, offset: int) -> int:
    return struct.unpack_from('>I', data, offset)[0]


def snr_at(data: bytes, offset: int, codecs=(EA_XMA,)) -> SnrStream | None:
    """The RAM SNR stream starting at `offset`, if its block chain is consistent."""
    if offset < 0 or offset + 16 > len(data):
        return None
    header = _u32(data, offset)
    version, codec = header >> 28, (header >> 24) & 0xF
    channels, rate = ((header >> 18) & 0x3F) + 1, header & 0x3FFFF
    if version > 1 or codec not in codecs or not 8000 <= rate <= 48000 or channels > 8:
        return None
    flags = _u32(data, offset + 4)
    kind, looped, samples = flags >> 30, (flags >> 29) & 1, flags & 0x1FFFFFFF
    if kind != 0 or samples == 0:
        return None
    loop_start = _u32(data, offset + 8) if looped else None
    cursor = offset + (12 if looped else 8)
    decoded = 0
    while decoded < samples:
        if cursor + 8 > len(data):
            return None
        flag, size = data[cursor], _u32(data, cursor) & 0xFFFFFF
        block_samples = _u32(data, cursor + 4)
        if flag not in (0x00, 0x80) or size <= 8 or cursor + size > len(data) or block_samples == 0:
            return None
        decoded += block_samples
        cursor += size
        if flag == 0x80:
            break
    if decoded != samples:
        return None
    return SnrStream(offset, cursor, codec, channels, rate, samples, loop_start)


def scan_snr(data: bytes, start: int = 0) -> list[SnrStream]:
    """Every consistent SNR stream in `data`, in file order."""
    streams = []
    offset = start
    while offset + 16 <= len(data):
        stream = snr_at(data, offset)
        if stream is None:
            offset += 1
        else:
            streams.append(stream)
            offset = stream.end
    return streams


def splc_streams(data: bytes) -> list[SnrStream]:
    if data[:4] != b'SPLC':
        raise ValueError('not an SPLC bank')
    expected = _u32(data, 0x18)
    streams = scan_snr(data)
    if len(streams) != expected:
        raise ValueError(f'SPLC bank declares {expected} streams; found {len(streams)}')
    return streams


@dataclass(frozen=True)
class Grain:
    duration: float
    stream: SnrStream


def grain(data: bytes) -> Grain:
    if len(data) < 8:
        raise ValueError('truncated grain file')
    offset = _u32(data, 0)
    duration = struct.unpack_from('>f', data, 4)[0]
    stream = snr_at(data, offset)
    if stream is None:
        raise ValueError(f'grain file has no SNR stream at {offset:#x}')
    if abs(stream.seconds - duration) > 0.01:
        raise ValueError(f'grain duration {duration:.3f}s does not match its stream ({stream.seconds:.3f}s)')
    return Grain(duration, stream)


def standalone(data: bytes, stream: SnrStream) -> bytes:
    """The stream as a standalone `.snr` file (header followed by its blocks)."""
    return data[stream.offset:stream.end]


# Five-channel EA ambience is L, C, R, Ls, Rs (channel 1 correlates with both
# 0 and 2; 0 pairs with 3 and 2 with 4). Each output is a weighted average
# whose weights sum to 1, so the downmix can never add gain or clip.
_FIVE_TO_STEREO = ((1.0, 0.7071, 0.0, 1.0, 0.0), (0.0, 0.7071, 1.0, 0.0, 1.0))


def downmix_weights(channels: int) -> tuple[tuple[float, ...], tuple[float, ...]] | None:
    """Per-output weights (normalised to sum 1) for a stereo downmix, or None to keep as is."""
    if channels <= 2:
        return None
    if channels == 5:
        rows = _FIVE_TO_STEREO
    else:
        # Unknown layouts: alternate channels left/right.
        rows = (tuple(float(i % 2 == 0) for i in range(channels)),
                tuple(float(i % 2 == 1) for i in range(channels)))
    return tuple(tuple(w / sum(row) for w in row) for row in rows)


def downmix_pcm16(frames: bytes, channels: int) -> bytes:
    """Interleaved little-endian PCM16 frames downmixed to stereo (no gain)."""
    weights = downmix_weights(channels)
    if weights is None:
        return frames
    import numpy
    source = numpy.frombuffer(frames, dtype='<i2').reshape(-1, channels).astype(numpy.float32)
    mixed = source @ numpy.asarray(weights, dtype=numpy.float32).T
    return numpy.rint(mixed).astype('<i2').tobytes()


def loop_bands(frames: bytes, bands: int, crossfade: int) -> list[bytes]:
    """Mono PCM16 cut into `bands` equal parts, each made seamless as a loop.

    A part's last `crossfade` samples are blended into its first ones with
    linear weights (w and 1 - w), so no sample can exceed the louder of its
    two sources; the blended tail is then dropped.
    """
    import numpy
    samples = numpy.frombuffer(frames, dtype='<i2').astype(numpy.float32)
    size = len(samples) // bands
    if size <= 2 * crossfade:
        raise ValueError('grain recording too short for its bands')
    out = []
    for index in range(bands):
        part = samples[index * size:(index + 1) * size].copy()
        head, tail = part[:crossfade], part[-crossfade:]
        fade_in = numpy.linspace(0.0, 1.0, crossfade, endpoint=False, dtype=numpy.float32)
        part[:crossfade] = head * fade_in + tail * (1.0 - fade_in)
        out.append(numpy.rint(part[:-crossfade]).astype('<i2').tobytes())
    return out


def splc_patches(data: bytes) -> dict:
    """The patch tree of an SPLC bank: what retail plays for each sound id.

    Layout (verified on all 20 banks of the owned disc: the walk ends exactly at
    the sample table, every member names a valid sample; field meanings follow
    upstream PR #4's notes, re-derived and checked here):
      header 60 bytes: +8 sample table offset (from byte 60), +12 record count,
        +16 container count, +20 24-byte extras (0), +24 sample count;
      records, 36 bytes: +4 u16 id (= index), +7 u8 group count;
      containers, 72 bytes: +4 u16 ids (records), +68 u8 count, +69 u8 mode;
      per record, its groups in order: 12-byte header (+8 u8 member count,
        +9 u8 mode) then 72-byte members: +0 u16 sample index (= our stream
        index), +8 f32 gain, +44 f32 pitch, +48 f32 gain range, +64 f32 probability.
    A record's groups are layers played together, one member each; an id at
    or above the record count names container (id - records), which picks one
    of its records. Sample index n is the n-th SNR stream (`splc_streams`).
    """
    if data[:4] != b'SPLC':
        raise ValueError('not an SPLC bank')
    table = 60 + _u32(data, 8)
    records, containers, samples = _u32(data, 12), _u32(data, 16), _u32(data, 24)
    if _u32(data, 20):
        raise ValueError('SPLC bank with 24-byte extras is not supported')
    container_base = 60 + 36 * records
    out_containers = []
    for c in range(containers):
        at = container_base + 72 * c
        count = data[at + 68]
        out_containers.append([struct.unpack_from('>H', data, at + 4 + 2 * k)[0] for k in range(count)])
    cursor = container_base + 72 * containers
    out_records = []
    for r in range(records):
        at = 60 + 36 * r
        if struct.unpack_from('>H', data, at + 4)[0] != r:
            raise ValueError(f'SPLC record {r} has id {struct.unpack_from(">H", data, at + 4)[0]}')
        groups = []
        for _ in range(data[at + 7]):
            count, mode = data[cursor + 8], data[cursor + 9]
            cursor += 12
            members = []
            for _ in range(count):
                sample = struct.unpack_from('>H', data, cursor)[0]
                if sample >= samples:
                    raise ValueError(f'SPLC member names sample {sample} of {samples}')
                gain, pitch, gain_range, probability = (struct.unpack_from('>f', data, cursor + o)[0] for o in (8, 44, 48, 64))
                members.append([sample, round(gain, 4), round(gain_range, 4), round(pitch, 4), round(probability, 4)])
                cursor += 72
            groups.append({'mode': mode, 'members': members})
        out_records.append(groups)
    if cursor != table:
        raise ValueError(f'SPLC patch tree ends at {cursor:#x}, sample table at {table:#x}')
    return {'records': out_records, 'containers': out_containers}


_MASK64 = (1 << 64) - 1
NAME_ID_SEED = 0xABCDEF0011223344


def _lookup8_mix(a: int, b: int, c: int) -> tuple[int, int, int]:
    # Bob Jenkins' lookup8 mix64 (public domain), in 64-bit arithmetic.
    a = (a - b - c) & _MASK64; a ^= c >> 43
    b = (b - c - a) & _MASK64; b ^= (a << 9) & _MASK64
    c = (c - a - b) & _MASK64; c ^= b >> 8
    a = (a - b - c) & _MASK64; a ^= c >> 38
    b = (b - c - a) & _MASK64; b ^= (a << 23) & _MASK64
    c = (c - a - b) & _MASK64; c ^= b >> 5
    a = (a - b - c) & _MASK64; a ^= c >> 35
    b = (b - c - a) & _MASK64; b ^= (a << 49) & _MASK64
    c = (c - a - b) & _MASK64; c ^= b >> 11
    a = (a - b - c) & _MASK64; a ^= c >> 12
    b = (b - c - a) & _MASK64; b ^= (a << 18) & _MASK64
    c = (c - a - b) & _MASK64; c ^= b >> 22
    return a, b, c


def name_id(name: str) -> int:
    """The 64-bit id Skate 3's audio data uses for a name: Bob Jenkins' lookup8
    hash of its bytes with level NAME_ID_SEED (the `.ems` sound ids)."""
    key = name.encode('ascii')
    a = b = NAME_ID_SEED
    c = 0x9E3779B97F4A7C13
    rest = key
    while len(rest) >= 24:
        a = (a + int.from_bytes(rest[0:8], 'little')) & _MASK64
        b = (b + int.from_bytes(rest[8:16], 'little')) & _MASK64
        c = (c + int.from_bytes(rest[16:24], 'little')) & _MASK64
        a, b, c = _lookup8_mix(a, b, c)
        rest = rest[24:]
    c = (c + len(key)) & _MASK64
    for index, byte in enumerate(rest):
        if index < 8:
            a = (a + (byte << (8 * index))) & _MASK64
        elif index < 16:
            b = (b + (byte << (8 * (index - 8)))) & _MASK64
        else:  # the low byte of c holds the length
            c = (c + (byte << (8 * (index - 15)))) & _MASK64
    return _lookup8_mix(a, b, c)[2]


EMS_RECORD = struct.Struct('>II3f3f4fQ4f')


def ems_emitters(data: bytes) -> list[dict]:
    """The records of an `.ems` emitter file, fields named by their layout."""
    count = _u32(data, 0)
    if len(data) != 4 + count * EMS_RECORD.size:
        raise ValueError(f'.ems: {count} records do not fill {len(data)} bytes')
    emitters = []
    for number in range(count):
        fields = EMS_RECORD.unpack_from(data, 4 + number * EMS_RECORD.size)
        emitters.append({
            'index': fields[0], 'flags': fields[1],
            'position': list(fields[2:5]), 'extent': list(fields[5:8]),
            'scalars': list(fields[8:12]), 'sound_id': fields[12], 'gains': list(fields[13:17]),
        })
    return emitters


# World-painter region layers (district `cSim_*.xsf` streams, RW4 arenas with ATOC processor
# 0xAB329A6A). Each 128 m tile holds, per layer, a quadtree of axis-aligned (x, z) boxes whose
# leaves index a table of u64 keys. Layers the game names (`name_id` of each):
REGION_LAYERS = (
    'test_layer0', 'test_layer1', 'livingworld_npc_census', 'livingworld_vehicle_census', 'districts',
    'district_locations', 'livingworld_security_guard_areas', 'audio_ambience', 'audio_emitters',
    'challenge_zone_races', 'audio_reverb', 'rendering_colorcube', 'cameras_race', 'services',
    'livingworld_dmo_safety', 'rendering_fog', 'rendering_sky', 'rendering_exposure', 'rendering_bloom',
)
REGION_PROCESSOR = 0xAB329A6A
_LAYER_RECORD, _QUADTREE, _KEY_TABLE = 0x00EB000F, 0x00EB0010, 0x00EB0011
NO_KEY = 0xFFFF


def region_layers(arena: bytes) -> list[dict]:
    """Every region layer in one arena: layer name, box (centre x, z, half x, z), quadtree
    nodes (four child indices, then the value; child 0 = NO_KEY marks a leaf) and keys."""
    names = {name_id(name): name for name in REGION_LAYERS}
    count, directory = _u32(arena, 0x20), _u32(arena, 0x30)
    entries = [struct.unpack_from('>6I', arena, directory + 24 * i) for i in range(count)]
    layers = []
    for entry in entries:
        if entry[5] != _LAYER_RECORD:
            continue
        tree_index, table_index = struct.unpack_from('>II', arena, entry[0])
        layer = struct.unpack_from('>Q', arena, entry[0] + 8)[0]
        tree, table = entries[tree_index][0], entries[table_index][0]
        cx, cz = struct.unpack_from('>ff', arena, tree)
        hx, hz = struct.unpack_from('>ff', arena, tree + 16)
        nodes_count, nodes_at = struct.unpack_from('>II', arena, tree + 32)
        nodes = [list(struct.unpack_from('>5H', arena, tree + nodes_at + 10 * i)) for i in range(nodes_count)]
        keys_count, keys_at = _u32(arena, table + 4), _u32(arena, table + 12)
        keys = []
        for i in range(keys_count):
            at = _u32(arena, table + keys_at + 8 * i)
            low, high = struct.unpack_from('>II', arena, table + at)  # stored low word first
            keys.append((high << 32) | low)
        layers.append({'layer': names.get(layer, f'{layer:016X}'), 'box': [cx, cz, hx, hz], 'nodes': nodes, 'keys': keys})
    return layers


def region_key(layer: dict, x: float, z: float) -> int | None:
    """The key a region layer holds at (x, z), or None (outside, or a leaf without a key)."""
    cx, cz, hx, hz = layer['box']
    nodes = layer['nodes']
    if not nodes or abs(x - cx) > hx or abs(z - cz) > hz:
        return None
    index = 0
    while True:
        node = nodes[index]
        if node[0] == NO_KEY:
            return None if node[4] == NO_KEY else layer['keys'][node[4]]
        hx, hz = hx * 0.5, hz * 0.5
        for child, (sx, sz) in enumerate(((-1, -1), (-1, 1), (1, -1), (1, 1))):
            ccx, ccz = cx + sx * hx, cz + sz * hz
            if abs(x - ccx) <= hx and abs(z - ccz) <= hz:
                index, cx, cz = node[child], ccx, ccz
                break
        else:
            return None
