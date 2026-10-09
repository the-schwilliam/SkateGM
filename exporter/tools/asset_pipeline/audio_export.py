"""Decode the owned disc's game audio into PCM16 WAV for the engine (assets/private/audio).

Only what the engine plays is exported (crates/skate-game/src/game_audio/): the
ambience beds, rolling grains, wheel spins, the sample banks below, and every
bank the per-map sound emitters (`sfx_*.ems`, `skateschool.ems`) place in the
world, with those emitters listed in the manifest. Audio is
written at its original level: nothing is normalised or boosted, and surround
ambience is downmixed to stereo by a weighted average (audio_formats.py).
"""
from __future__ import annotations

import json
import shutil
import struct
import subprocess
import wave
from pathlib import Path

from tools.owned_game.big import BigArchive
from .audio_formats import (REGION_PROCESSOR, downmix_pcm16, ems_emitters, grain, loop_bands, name_id, region_layers,
                            scan_snr, splc_patches, splc_streams, standalone)

VERSION = 5

# Each rolling grain is a recording that sweeps from slow to fast rolling (about
# 10 dB louder and brighter by the end). It is cut into this many speed bands,
# each made loopable, so the engine can play the band matching board speed.
GRAIN_BANDS = 6
LOOP_CROSSFADE = 0.08  # seconds

# Pinned decoder (EA-XMA needs FFmpeg's XMA2 decoder, which this build bundles).
# The SHA-256 matches the digest GitHub publishes for the release asset.
VGMSTREAM_URL = 'https://github.com/vgmstream/vgmstream/releases/download/r2117/vgmstream-win64.zip'
VGMSTREAM_SHA = '6c4a8a3813864fefed081bbd337dbc0ad93bf88e0b92f5db98d7ab258b22dc6c'

# Per-map ambience beds (ambience.big + headers in ambienceresident.big).
AMBIENCE = (
    '01_dt_apt', '02_dt_less_busy', '03_dt_rez', '04_dt_main', '05_dt_parks', '06_dt_open',
    '07_univ_mt_high', '08_univ_mt_low', '09_univ_campus', '10_univ_housing',
    '11_indu_shipyard', '12_indu_drydock', '13_indu_quarry', '14_reclaimed_a', '15_indu_new_factory',
    '16_spillway', '17_space_park', '18_skate_school', '19_reclaimed_b_fix', '20_indu_old_factory',
    '21_interior_arena_amb', '22_interior_tunnel_amb',
)

# Sample banks from audiofiles.big (data/audio/<name>).
BANKS = (
    'Skate_Collisions.bnk', 'Skate_Metal.bnk', 'sk8_foley.bnk', 'Sk82_Whsh_Bys.bnk',
    'Sk8_Air_Flip_Tricks.abk', 'GRINDS.abk', 'board_scrapes.abk', 'Brd_Squeaks.abk',
    'WHEEL_SKID_BANK.abk', 'FOOT_DRAG.abk', 'fstep_skateshoe1_sm.abk', 'Bodyslide.abk',
    'Rolling_Rattles.abk', 'Seams_Bank.abk', 'PatchBank_Rolling_Surfaces.abk', 'sense_of_speed.abk',
    'water_misc.abk', 'Foley_Cloth.abk',
    # The native player components' other banks: every bank bound to Class_rolling (a post reaches
    # each), and Class_Treatment's (skate_audio::player::{rolling, treatment}).
    'PatchBank_SpiderCracks.abk', 'PatchBank_Objects.abk', 'PatchBank_RocksBounce.abk', 'Treatments.abk',
    # Water emitters on the map's water (game_audio/water.rs) and splash tails.
    'water_lapping.abk', 'water_lapping_pond.abk', 'fountains_waterlaps_left.abk',
    'water_fountain.abk', 'ocean_wave_small.abk',
    # The front-end sounds (class `fe` records, frontend_sounds below): the session marker's
    # cellphone UI plays from this Splice bank.
    'sk8_menu.bnk',
)

# vgmstream stops accepting input files somewhere between 600 and 1100 arguments.
_BATCH = 256


def _decode(vgmstream: Path, directory: Path, names: list[str], log) -> None:
    """Decode standalone `<name>` files in `directory` to `<name>.wav` beside them."""
    for start in range(0, len(names), _BATCH):
        batch = names[start:start + _BATCH]
        # Imported lazily: install imports this module's group function.
        from . import install as engine
        child = engine.spawn([vgmstream, '-i', '-o', '?f.wav', *batch], cwd=directory,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        with child as process:
            output = process.stdout.read()
            if process.wait():
                log.write(output)
                raise RuntimeError(f'vgmstream failed on {directory.name}')
        for name in batch:
            if not (directory/(name + '.wav')).is_file():
                raise RuntimeError(f'vgmstream did not decode {directory.name}/{name}')


def _wav_info(path: Path) -> dict:
    with wave.open(str(path)) as source:
        return {'channels': source.getnchannels(), 'sample_rate': source.getframerate(),
                'seconds': round(source.getnframes() / source.getframerate(), 4)}


def _stereo(source: Path, target: Path) -> dict:
    with wave.open(str(source)) as reader:
        channels, rate, width = reader.getnchannels(), reader.getframerate(), reader.getsampwidth()
        frames = reader.readframes(reader.getnframes())
    if width != 2:
        raise RuntimeError(f'{source.name}: expected PCM16 from vgmstream')
    mixed = downmix_pcm16(frames, channels)
    with wave.open(str(target), 'wb') as writer:
        writer.setnchannels(min(channels, 2))
        writer.setsampwidth(2)
        writer.setframerate(rate)
        writer.writeframes(mixed)
    return {**_wav_info(target), 'source_channels': channels}


def _grain_bands(source: Path, folder: Path, prefix: str) -> list[dict]:
    with wave.open(str(source)) as reader:
        channels, rate, width = reader.getnchannels(), reader.getframerate(), reader.getsampwidth()
        frames = reader.readframes(reader.getnframes())
    if width != 2 or channels != 1:
        raise RuntimeError(f'{source.name}: expected mono PCM16 from vgmstream')
    folder.mkdir(parents=True)
    bands = []
    for index, pcm in enumerate(loop_bands(frames, GRAIN_BANDS, round(LOOP_CROSSFADE * rate))):
        target = folder/f'{index}.wav'
        with wave.open(str(target), 'wb') as writer:
            writer.setnchannels(1)
            writer.setsampwidth(2)
            writer.setframerate(rate)
            writer.writeframes(pcm)
        bands.append({'file': f'{prefix}/{index}.wav', **_wav_info(target)})
    return bands


def grain_whole(stem: str, member: bytes, decoded: Path, folder: Path) -> dict:
    """The whole recording for the native grain player (crates/skate-audio/src/grain): the raw
    `.grain` member (header, stored duration, seek table, EAAC stream; parsed and validated by the
    game) and its decoded PCM, read from a frame = rate × start seconds (grain-player-spec §2.6).
    Call after the bands are cut: the decoded WAV is moved into place."""
    info = grain(member)
    (folder/(stem + '.grain')).write_bytes(member)
    target = folder/(stem + '.wav')
    shutil.move(decoded, target)
    return {'file': f'grains/{stem}.wav', 'grain': f'grains/{stem}.grain', 'duration': info.duration,
            **_wav_info(target)}


def _streams(name: str, data: bytes):
    streams = splc_streams(data) if data[:4] == b'SPLC' else scan_snr(data)
    if not streams:
        raise ValueError(f'{name} contains no decodable streams')
    return streams


# Emitter files whose sounds play in the world (the others place reverb, music,
# crowds and speakers).
SOUND_EMITTERS = ('sfx_', 'skateschool')


# The emitter attribute class in the disc's skatercollections database: one
# record per emitter sound, keyed by the same id as the `.ems` records.
EMITTER_CLASS = 'Hash_F0CEF367088EFFF8'
EMITTER_FIELDS = {
    'volume': 'volume',
    'Hash_BE88128A30BE926E': 'bank_file',
    'Hash_C493ED34D1D32521': 'patch',
    'Hash_6D18B8674D7E5337': 'kind',  # Sk8::Audio::eVolumeType: 1 = looping emitter, 5 = reverb zone
    'Hash_F209C093F40A4CCC': 'falloff',  # eVolumeFalloffType: 0 = (1-d)^2, 1 = 1-d, else flat
    'Hash_9908F2D75D7381BD': 'seconds',  # float, 10 by default (meaning not verified)
    'Hash_99FD793BC30CF0FA': 'reverb',  # reverb zones (kind 5): the reverb preset (class 204CAC1FD77088B8)
}


# Location sets of random distant one-shots (sirens, dogs, bangs...): class
# `aud_wp_emitters`. Each set fires one of its sounds (weighted) at a random
# interval and level within its ranges (docs/hails-additions/11-audio.md).
RANDOM_SET_CLASS = 'Hash_39A2DE0232912CE5'
RANDOM_SET_FIELDS = {
    'Hash_29C68772F509F5A9': 'min_level',
    'Hash_B6AD5C13F4A403B3': 'max_level',
    'Hash_B1E6821F7F31E517': 'min_interval',
    'Hash_A306BD1F4023A642': 'max_interval',
    'Hash_5CA06CA086D8F953': 'sounds',  # RefSpec array of EMITTER_CLASS records
    'Hash_07DDABF96E5F2731': 'weights',  # Int32 array, one per sound
}


def _value(field):
    """A converted collection field: float, int, text, or a list for arrays
    (RefSpec items become the referenced record's u64 key)."""
    kind = field['type']
    if 'array' in field:
        items = field['array']['items']
        if kind.endswith('RefSpec'):
            return [int(item[16:32], 16) for item in items]
        return [_value({'type': kind, 'data': item}) for item in items]
    if kind.endswith('Text'):
        return field['data']
    if kind == 'Attrib::RefSpec':  # single untyped reference: the class key, then the record's
        return int(field['data'][16:32], 16)
    if 'RefSpec' in kind:  # single reference (ClassRefSpec_<class>): the record's u64 key first
        return int(field['data'][:16], 16)
    raw = bytes.fromhex(field['data'])
    if kind.endswith('Float'):
        return round(struct.unpack('>f', raw)[0], 6)
    return struct.unpack('>i', raw)[0]


def _resolved(collections: list[dict], cls: str, wanted: dict[str, str]) -> dict[int, dict]:
    """Records of one class by u64 key, with inherited fields resolved through parents."""
    records = {c['key']: c for c in collections if c['class'] == cls}
    resolved = {}
    for key in records:
        chain, cursor = [], key
        while cursor in records and len(chain) < 16:
            chain.append(records[cursor])
            cursor = records[cursor]['parent']
        fields = {}
        for record in reversed(chain):
            for name, field in record['fields'].items():
                if name in wanted:
                    fields[wanted[name]] = _value(field)
        # Named records (e.g. `spacepark`) are keyed by the name's id, like the hashed ones.
        resolved[int(key[5:], 16) if key.startswith('Hash_') else name_id(key)] = fields
    return resolved


def emitter_attributes(collections: list[dict]) -> dict[int, dict]:
    """Each emitter sound's attributes by sound id, with inherited fields resolved."""
    return _resolved(collections, EMITTER_CLASS, EMITTER_FIELDS)


# The front-end sounds: class `fe` (lookup8 `5831CB95F3E90598`), 237 records under `fe_sfx` (the
# cellphone / session-marker UI, menus, challenges, scores). Retail's front-end audio object plays a
# request (by record key) as a Splice start of the record's sk8_menu sound at the record's level
# (recomp sub_824955B8 → sub_82495828 → sub_824958F0; docs/hails-additions/15-world-audio.md
# "Session marker sounds"). `hom` (a HOM_Set_1 sound), `moment` (eMomentSFX) and `alt_bus` (output
# to the second front-end bus instead of the mastering graph) are carried for completeness.
FE_CLASSES = ('fe', 'Hash_5831CB95F3E90598')
FE_FIELDS = {
    'Hash_8FCC7EF9B9208858': 'id', 'Hash_875BA75341DC8391': 'level', 'Hash_845A10052522A2FB': 'hom',
    'Hash_A4080FB65880E3C2': 'moment', 'Hash_BF45D439FAC71A2E': 'alt_bus',
    'Hash_942AB8AEE4B414ED': 'name', 'Name': 'name',
}
FE_BANK = 'sk8_menu'


def frontend_sounds(collections: list[dict]) -> dict:
    """{bank, sounds: {key hex: {name, id, level, hom, moment, alt_bus}}} for every `fe` record
    (inherited fields resolved); {} when the database has no such class."""
    cls = next((c for c in FE_CLASSES if any(r['class'] == c for r in collections)), None)
    if cls is None:
        return {}
    sounds = {}
    for key, f in sorted(_resolved(collections, cls, FE_FIELDS).items()):
        sounds['%016X' % key] = {
            'name': f.get('name', ''), 'id': int(f.get('id', 0)), 'level': float(f.get('level', 1.0)),
            'hom': int(f.get('hom', 0)), 'moment': int(f.get('moment', 0)), 'alt_bus': bool(f.get('alt_bus', 0)),
        }
    return {'bank': FE_BANK, 'sounds': sounds}


# Zone ambience: the region layer `audio_ambience` holds `aud_wp_ambiences` keys. Each zone names
# its bed by number (01_dt_apt .. 22_interior_tunnel_amb in ambience.big) with a volume and two times;
# `aud_wp_ambience_crossfades` records join two zones to a group of the district's
# Main_Ambience_Crossfade bank (docs/hails-additions/11-audio.md).
ZONE_CLASS = 'Hash_656AAE7BB40F6C7F'
ZONE_FIELDS = {
    'volume': 'volume',
    'Hash_4042D2F96C4E4B8C': 'bed',  # bed number (prefix of the ambience.big stream name)
    'Hash_17C3EB9C543E1210': 'time_a',
    'Hash_2E2ABEBF53F107EC': 'time_b',
}
CROSSFADE_CLASS = 'Hash_5FD3F641DB66DF9A'
CROSSFADE_FIELDS = {
    'Hash_F3041C272479768A': 'from',
    'Hash_9124706DB04F6C30': 'to',
    'Hash_69359D816F0054B7': 'group',
    'Hash_875BA75341DC8391': 'level',
    'Hash_BA23AD9BAC046BAF': 'value_ba23',
    'Hash_8B068A069DFE9597': 'value_8b06',
    'Hash_542D1F3AAF8E371A': 'value_542d',
}
CROSSFADE_BANKS = ('Main_Ambience_Crossfade_DT.abk', 'Main_Ambience_Crossfade_Ind.abk', 'Main_Ambience_Crossfade_Uni.abk')


def ambience_zones(collections: list[dict], names: list[str]) -> tuple[dict, list[dict]]:
    """Zones by key ({name, bed stream, volume, times}) and crossfades ({name, from, to, group,
    level, ...} with zone keys as 16 hex digits)."""
    known = {name_id(n): n for n in names}
    beds = {int(name.split('_', 1)[0]): name for name in AMBIENCE}
    zones = {}
    for key, fields in _resolved(collections, ZONE_CLASS, ZONE_FIELDS).items():
        zones[f'{key:016X}'] = {'name': known.get(key), 'bed': beds.get(fields.get('bed', 0)),
                                **{k: fields[k] for k in ('volume', 'time_a', 'time_b') if k in fields}}
    crossfades = []
    for key, fields in _resolved(collections, CROSSFADE_CLASS, CROSSFADE_FIELDS).items():
        if 'from' not in fields or 'to' not in fields:
            continue  # the class default
        crossfades.append({'name': known.get(key), **{k: (f'{v:016X}' if k in ('from', 'to') else v)
                                                      for k, v in fields.items()}})
    return zones, sorted(crossfades, key=lambda c: c['name'] or '')


def random_sets(collections: list[dict], attributes: dict[int, dict], names: list[str],
                by_file: dict[str, str]) -> tuple[dict, set[str]]:
    """Each location set's ranges and sounds (bank, patch, volume, timeout, weight),
    named where `names` has the set's name, and the banks they use."""
    known = {name_id(n): n for n in names}
    listed, banks = {}, set()
    for key, fields in _resolved(collections, RANDOM_SET_CLASS, RANDOM_SET_FIELDS).items():
        weights = fields.get('weights') or []
        sounds = []
        for index, sound in enumerate(fields.get('sounds') or []):
            attrs = attributes.get(sound, {})
            bank = by_file.get(attrs.get('bank_file', '').lower())
            if not bank:
                continue
            banks.add(bank)
            sounds.append({'sound_id': f'{sound:016X}', 'bank': Path(bank).stem, 'patch': attrs.get('patch', 0),
                           'volume': attrs.get('volume', 1.0), 'seconds': attrs.get('seconds', 10.0),
                           'weight': weights[index] if index < len(weights) else 10})
        listed[f'{key:016X}'] = {
            'name': known.get(key), 'sounds': sounds,
            **{k: fields[k] for k in ('min_level', 'max_level', 'min_interval', 'max_interval') if k in fields},
        }
    return listed, banks


def emitters(files: BigArchive, attributes: dict[int, dict] | None = None) -> tuple[dict, set[str]]:
    """Every `.ems` file's records with their sound's attributes and bank (None
    when the disc has no such bank), and the banks placed by sound emitters."""
    attributes = attributes or {}
    banks = {}
    by_file = {Path(e.path).name.lower(): Path(e.path).name for e in files.entries}
    for entry in files.entries:
        name = Path(entry.path).name
        if name.endswith(('.abk', '.bnk')):
            # Ids hash the name either as the file is named or lower-cased (both occur).
            for key in {Path(name).stem, Path(name).stem.lower()}:
                banks[name_id(key)] = name
    listed, placed = {}, set()
    for entry in sorted(files.entries, key=lambda e: e.path):
        if not entry.path.endswith('.ems'):
            continue
        stem = Path(entry.path).stem
        records = ems_emitters(files.read(entry))
        for record in records:
            sound = dict(attributes.get(record['sound_id'], {}))
            named = sound.pop('bank_file', '')
            on_disc = by_file.get(named.lower()) if named else None
            bank = on_disc or banks.get(record['sound_id'])
            record.update(sound)
            if 'reverb' in record:
                record['reverb'] = f"{record['reverb']:016X}"
            record['bank'] = Path(bank).stem if bank else None
            record['sound_id'] = f"{record['sound_id']:016X}"
            if bank and stem.startswith(SOUND_EMITTERS):
                placed.add(bank)
        listed[stem] = records
    return listed, placed


# Region layers the engine uses: the location's random one-shot set (`aud_wp_emitters`), and
# for later the zone ambience bed (`aud_wp_ambiences`) and reverb (`aud_reverb`).
AUDIO_REGION_LAYERS = ('audio_emitters', 'audio_ambience', 'audio_reverb')


def regions(game_root: Path, work: Path) -> dict:
    """Each map's audio region layers from its district streams:
    {map: {layer: [{box, nodes, keys (16 hex digits)}]}}."""
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'vendor/university/tools/vanilla_map_extraction/tools'))
    from skate3_streams import read_atoc, read_sfil
    out = {}
    for archive in sorted((game_root/'data/content').glob('worldDIST_*.big')):
        district = archive.stem.removeprefix('worldDIST_')
        big = BigArchive(archive)
        index = next((e for e in big.entries if e.path.endswith('_Sim.xst')), None)
        if index is None:
            continue
        folder = work/'regions'/district
        folder.mkdir(parents=True, exist_ok=True)
        (folder/'index.xst').write_bytes(big.read(index))
        records = read_atoc(folder/'index.xst')
        by_id = {r.asset_id: r for r in records}
        layers, seen = {}, set()
        for entry in big.entries:
            name = Path(entry.path).name
            if not (name.startswith('cSim_') and name.endswith('.xsf')):
                continue
            (folder/name).write_bytes(big.read(entry))
            for asset in read_sfil(folder/name, records, require_all_records=False, record_index=by_id):
                if asset.record.processor_id != REGION_PROCESSOR or asset.record.asset_id in seen:
                    continue
                seen.add(asset.record.asset_id)
                for layer in region_layers(asset.data):
                    if layer['layer'] in AUDIO_REGION_LAYERS:
                        layers.setdefault(layer['layer'], []).append(
                            {'box': layer['box'], 'nodes': layer['nodes'], 'keys': [f'{k:016X}' for k in layer['keys']]})
        out[district] = layers
    return out


def _collections(game_root: Path, work: Path) -> tuple[list[dict], list[str]]:
    """The disc's skatercollections records (the same conversion the core group
    runs) and the record names listed in its summary report."""
    import re
    from . import install as engine
    from .vlt import convert as convert_vlt
    database = work/'database'
    engine.extract(game_root/'data/big/db.big', database, lambda e: Path(e.path).name.lower() in {
        'skaterschema.bin', 'skaterschema.vlt', 'skatercollections.bin', 'skatercollections.vlt',
        'skatercollections_summaryreport.txt'})
    names = (engine.TOOLS/'asset_pipeline/names.txt').read_text(encoding='utf-8').splitlines()
    converted = convert_vlt(database/'data/db/skaterschema', database/'data/db/skatercollections', names)
    report = database/'data/db/skatercollections_summaryreport.txt'
    text = report.read_text(encoding='latin-1') if report.exists() else ''
    return converted['collections'], re.findall(r'\.class/([A-Za-z0-9_]+)\.xml', text)


# Banks the native AEMS runtime needs besides the played ones (crates/skate-audio): the utility
# whose timers and shuffles feed the `*_snd` / `random_*_gbl` globals other banks read, and Common
# (class Start_up_Play_ctl: the `rnd_call` shuffles behind `send_random_0_to_9a/b/c`, which pick the
# Seams_Bank sample of every seam hit).
AEMS_EXTRA_BANKS = ('emitter_utility.abk', 'Common.abk')

# The MixMap mixer's data (crates/skate-audio/src/mixmap): a loose file next to the archives.
MIXMAP_FILE = 'MixMapSK8.mxb'


def mixmap_file(audio_root: Path, output: Path) -> str | None:
    """Copy MixMapSK8.mxb byte for byte into output/'aems' (checked: big-endian header with 1..64
    slots and an in-file slot table); return its manifest path, or None if the disc has none."""
    source = audio_root/MIXMAP_FILE
    if not source.is_file():
        return None
    data = source.read_bytes()
    if len(data) < 16:
        raise ValueError(f'{MIXMAP_FILE}: truncated')
    slots, table = struct.unpack_from('>II', data, 4)
    if not 1 <= slots <= 64 or table + 4 * slots > len(data):
        raise ValueError(f'{MIXMAP_FILE}: not a MixMap ({slots} slots, table at {table:#x})')
    (output/'aems').mkdir(parents=True, exist_ok=True)
    (output/'aems'/MIXMAP_FILE).write_bytes(data)
    return f'aems/{MIXMAP_FILE}'


# The granular rolling bed's tuning (audio-specs/grain-player-spec.md §1.4–1.5): the grain class
# (one collection per `.grain` member, inheriting from `default`), the board owner class (rocket
# layer, chain ramps) and the material → rolling surface table. Field roles from upstream PR #4's
# notes; values are read exactly (f32) because the port compares bit patterns.
GRAIN_CLASS = 'Hash_7AB23C11B6ADA2DE'
GRAIN_OWNER_CLASS = 'Hash_6E878344774A7999'
GRAIN_FIELDS = {
    'Hash_2C073BF8BC45063B': 'grain_file',
    'Hash_4890392C91829954': 'max_kmh',
    'Hash_CEC749561306022A': 'b_slope_gain',
    'Hash_D380D303C64CF6F8': 'b_slope_ramp_kmh',
    'Hash_1F459FC797B2C6BA': 'a_shift_per_slope_hz',
    'Hash_5C9AA28695C17004': 'turn_cap',
    'Hash_145D8340A9440DA3': 'b_base_shift_hz',
    'Hash_7FFF3A8AD44809EF': 'b_shift_per_slope_hz',
    'Hash_281FF01081475899': 'turn_rise_step',
    'Hash_63764B8C7EB9EC9B': 'turn_fall_step',
    'Hash_6BDC44AE7C3C79D0': 'special_gain',
    'Hash_F62BC5EBD8E5DDE8': 'special_shift_hz',
    'Hash_2D751DEB89BB5E33': 'push_ramp_kmh',
    'Hash_E239B03F0E890686': 'push_scale_low',
    'Hash_B87ECDDAAB0F8404': 'push_scale_high',
    'Hash_C658A7923FC7B99E': 'push_shift_low_hz',
    'Hash_A15AD56E225ADBA6': 'push_shift_high_hz',
    'Hash_B3D7468820AFC661': 'push_scale_attack_ms',
    'Hash_DAC9DA910EF0316C': 'push_scale_hold_ms',
    'Hash_0C3D5DBC262ED276': 'push_scale_return_ms',
    'Hash_09A5CC79BA2178E7': 'push_shift_attack_ms',
    'Hash_3206FD96427EA4D2': 'push_shift_hold_ms',
    'Hash_DB597F672CA47138': 'push_shift_return_ms',
    'Hash_57A78D3BE8D47BB3': 'slope_down_divisor',
    'Hash_8DD4C3FC8DAF4059': 'slope_up_divisor',
}
GRAIN_CURVE_FIELD = 'Hash_A985FBAA9326718D'   # 4×4 floats; column 1 of rows 3, 2, 1, 0 = P0..P3
GRAIN_PARAMS_FIELD = 'Hash_D18D1174735E5CDE'  # GrainParams: {attack, sustain, release, window, drift} per player
GRAIN_OWNER_FIELDS = {
    'Hash_7508154FF73DDCED': 'rocket_start_kmh',
    'Hash_1185E9A69919B051': 'rocket_top_kmh',
    'Hash_9BC13FA19CC4DF00': 'rocket_gain_word',
    'Hash_88AA96B08FD16914': 'g1_level_start_kmh',
    'Hash_3FFB5107C82BA3E0': 'g1_level_end_kmh',
    'Hash_D3E8894CA25A4F71': 'g1_level_floor',
    # The board chains (`sub_824CA938`, skate_audio::grain::chain::ChainTuning): the graph-1 ->
    # graph-3 send by speed, graph 3's clip and high shelf, the gain wobbles' speed ramp, segment
    # times and ranges for A's and B's chains.
    'Hash_0D665393E2EDC605': 'g3_send_start_kmh',
    'Hash_28E708782445747F': 'g3_send_end_kmh',
    'Hash_D900C07BE7C5450F': 'g3_send_max',
    'Hash_E64C04ED542DABC8': 'g3_clip',
    'Hash_55BEB30353F244A9': 'g3_shelf_hz',
    'Hash_45516395725ED16B': 'g3_shelf_gain',
    'Hash_281A501B22B6CCDF': 'wobble_start_kmh',
    'Hash_54CDE019E31FC04E': 'wobble_end_kmh',
    'Hash_36AE41817640FE04': 'wobble_a_ms_low',
    'Hash_71EE27313BD30F21': 'wobble_a_ms_high',
    'Hash_437D128B53669C34': 'wobble_a_low',
    'Hash_02885338DD5D7DCA': 'wobble_a_high',
    'Hash_2055BBF39C152FA9': 'wobble_b_ms_low',
    'Hash_F5240AFADA3B3FFC': 'wobble_b_ms_high',
    'Hash_F916E153393C5F24': 'wobble_b_low',
    'Hash_0A36F90732016D85': 'wobble_b_high',
}
SURFACE_MAP = ('Hash_C1831BDB6CB1B1EA', 'Hash_C489459A0C07D154', 'Hash_4CA607558B1CF440')


def _exact(field):
    """A converted field read without rounding: f32 as the exact float, ints, text; arrays as lists
    (an item holding several floats becomes a list of them)."""
    kind = field.get('type', '')
    if 'array' in field:
        return [_exact({'type': kind, 'data': item}) for item in field['array']['items']]
    data = ''.join(field.get('data', '').split())
    if kind.endswith('Text'):
        return field['data']
    if kind.endswith('Float'):
        floats = [struct.unpack('>f', bytes.fromhex(data[i:i + 8]))[0] for i in range(0, len(data), 8)]
        return floats[0] if len(floats) == 1 else floats
    if kind.endswith('Int32') and len(data) == 8:
        return struct.unpack('>i', bytes.fromhex(data))[0]
    return data


def _floats(field) -> list[float]:
    data = ''.join(field.get('data', '').split())
    return [struct.unpack('>f', bytes.fromhex(data[i:i + 8]))[0] for i in range(0, len(data) - 7, 8)]


def grain_tuning(collections: list[dict]) -> dict:
    """{'surfaces': {member stem: tuning}, 'default': tuning, 'owner': {...}, 'surface_map': [95 ints]}
    with inherited fields resolved through `default`."""
    records = {c['key']: c for c in collections if c['class'] == GRAIN_CLASS}

    def resolve(key, field):
        seen = 0
        while key in records and seen < 32:
            if field in records[key]['fields']:
                return records[key]['fields'][field]
            key, seen = records[key].get('parent', ''), seen + 1
        return None

    def tuning(key):
        out = {}
        for field, name in GRAIN_FIELDS.items():
            value = resolve(key, field)
            if value is not None:
                out[name] = _exact(value)
        curve = resolve(key, GRAIN_CURVE_FIELD)
        if curve is not None:
            m = _floats(curve)
            if len(m) == 16:
                out['bezier'] = [m[13], m[9], m[5], m[1]]
        params = resolve(key, GRAIN_PARAMS_FIELD)
        if params is not None:
            items = params['array']['items'] if 'array' in params else [params['data']]
            out['params'] = [_floats({'data': item}) for item in items]
        return out

    surfaces = {}
    for key in records:
        entry = tuning(key)
        member = entry.pop('grain_file', '')
        if member:
            surfaces[Path(member).stem] = entry
    owner = {}
    owners = {c['key']: c for c in collections if c['class'] == GRAIN_OWNER_CLASS}
    default_owner = owners.get('default', {'fields': {}})['fields']
    for field, name in GRAIN_OWNER_FIELDS.items():
        if field in default_owner:
            owner[name] = _exact(default_owner[field])
    if GRAIN_PARAMS_FIELD in default_owner:
        field = default_owner[GRAIN_PARAMS_FIELD]
        items = field['array']['items'] if 'array' in field else [field['data']]
        owner['rocket_params'] = _floats({'data': items[0]})
    surface_map = []
    holder = next((c for c in collections if c['class'] == SURFACE_MAP[0] and c['key'] == SURFACE_MAP[1]), None)
    if holder and SURFACE_MAP[2] in holder['fields']:
        for item in holder['fields'][SURFACE_MAP[2]]['array']['items']:
            surface_map.append(int(''.join(item.split())[8:16], 16))
    default = tuning('default')
    default.pop('grain_file', None)
    return {'surfaces': surfaces, 'default': default, 'owner': owner, 'surface_map': surface_map}


# The native player components' vault tuning (crates/skate-audio/src/player/tuning.rs). Field roles
# from our reading of the retail code (sub_824EF0B8, sub_824CA448, sub_824C2E48/sub_824C2D00,
# sub_824BA630, sub_824B2350), cross-checked with upstream PR #4's notes.
JITTER_CLASS = 'Hash_0AB9F005A2C8FBC7'
JITTER_FIELDS = {'Hash_8F956FBAD301AE26': 'enabled', 'Hash_E7D491E2EB228F54': 'id', 'Hash_B66AAD957873A8B3': 'params'}
SEAM_CLASS = 'Hash_7242F32831ED3332'
SEAM_PATTERNS = ('spidercrack', 'square_2_x_2', 'square_4_x_4', 'square_8_x_8', 'square_12_x_12', 'square_24_x_24',
                 'irregular_small', 'irregular_medium', 'irregular_large', 'slats', 'sidewalk',
                 'brick_tile_random_size', 'mini_tile', 'special_1', 'special_2')
SEAM_FIELDS = {'Hash_FA3A57801765A2F8': 'gain_low', 'Hash_32A9692F1B826274': 'gain_high',
               'Hash_F713CB547B1DF920': 'ms_low', 'Hash_0608B3129FF81F12': 'ms_high'}
# Class_Seams (`sub_824C1698` / `sub_824C1CA0` / `sub_824C1F18`): the pattern record (+0 gain, +4 grid
# angle, +8 grid z, +12 grid x, +16 class = w13) and its attributes (mode: 0 none, 1 grid, 2 distance;
# minimum frames between hits; speed threshold; distance spacing; level = w18); holder `default`
# `1911176187FB9B1F` = the grid scale on surface 3 for class-10 patterns.
SEAM_PATTERN_FIELDS = {'Hash_199170BB1C52EE64': 'gain', 'Hash_D18F436B5764F260': 'angle',
                       'Hash_534B0A719762E2E8': 'grid_z', 'Hash_107A78BA11A2B813': 'grid_x',
                       'Hash_5FAD918A2DE5459A': 'class', 'Hash_CA81764BF5A85E34': 'mode',
                       'Hash_DAE803A0CBD286D1': 'min_frames', 'Hash_F7BCA67F0A1FC92E': 'speed_threshold',
                       'Hash_A3BC1976039FA00A': 'spacing', 'Hash_2F29F40384863C8C': 'level',
                       'Hash_1911176187FB9B1F': 'surface3_scale'}
GRIND_CLASS = 'Hash_049861E8F9A8D16B'
# Grind surface 0..13 → collection: the image's key table at 0x82249F90 (TU3), as facts.
GRIND_SURFACE_KEYS = (0x72766EB54205429A, 0x849358CD45882044, 0x8DB0436F6B3405D5, 0xA36240FD856EEBA2,
                      0x8212F939B27CB441, 0x8710D7DAA28B90E7, 0x80AD71A0341B4AEB, 0x29FC132BB19BE7C9,
                      0xFD4F9F04AE61311B, 0x7CBD549861AE837E, 0xBDDCF1000271E0F7, 0x0C4C7B1701C3EA1B,
                      0x3696D249613957DD, 0xEDB51E711C25AA58)
GRIND_V = ('Hash_0ECECDAC28B2B979', 'Hash_58070BF511809903', 'Hash_72BA0780A8FA25D6', 'Hash_721A50C80028AD69')
GRIND_F = ('Hash_69969AF1BE6BB367', 'Hash_0555484D6D4A3128', 'Hash_C21983A2160ED3AC', 'Hash_69A5FC53091ED1F8')
MATERIAL_CLASS = 'Hash_D40CB4C0FFE45676'
MATERIAL_FOOTSTEPS = 'Hash_B1CF62EA632CF13F'
MATERIAL_STEP_GAIN = 'Hash_37320DF00471F91A'
MATERIAL_STEP_LANDING_GAIN = 'Hash_9D6068AB16703650'
LANDING_FLAG = 'Hash_1EBF9D2EB0DD56BA'
# The TU3 image's material → AudioSurface collection key table (16-byte stride, key at +8).
MATERIAL_KEY_TABLE = 0x8302D6E8
WHEEL_CLASS = 'Hash_C26949FCB638A2CA'
# eSk8AudioTricks (one collection per trick, key = hash64 of the lowercase scorable name): the audio
# trick id the board contacts and the trick foley read (state +348).
TRICK_CLASS = 'Hash_6918469984A8C596'
TRICK_FIELD = 'Hash_8C3025DB4D1761AF'
# The scorable's second audio trick (state +352, record +184; the Tricks component's cloth_trick B).
TRICK_FIELD_2 = 'Hash_A2C5C22C5BE725F8'
WHEEL_BUCKET = {'Hash_6D3D91A9BA7ADCDC': 'wheel_bucket_high', 'Hash_2A70BB8A382574E4': 'wheel_bucket_low'}

# The collision manager's per-material table (crates/skate-audio/src/player/collision.rs): the TU3
# image's material table at 0x8302D6E8 (16-byte stride: +0 the kind word = the Splice bank family
# 0 Skate_Collisions / 1 Skate_Metal / 2 HOM_Set_1, −1 none; +8 the AudioSurface collection key =
# hash64 of the lowercase material name), copied here as facts so setup needs no image.
MATERIAL_KINDS = (0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                  1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                  1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0, -1, 0, 0, 0,
                  0, 0, 0, 0, 2, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0,
                  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
MATERIAL_KEYS = (
    0x84EF7A70636ED529, 0x9182CCAD63479434, 0x49A5B1F124E53FDE, 0x49F167E3FC3A008B, 0xD7EFFA5849BB7B15,
    0x72B4ECCDC6CEE6E8, 0xAF8EAB3B0227FD48, 0x54D22F1336F8B796, 0x42CD19124AE613EB, 0x0613243A490D11EA,
    0xA4B6334D87D72CC7, 0x3738E9708EB6C776, 0x1BFF6E5CA982683A, 0x5BBDF4492AC7FB47, 0x22132549704E8733,
    0x1F2ACA29DEBE0729, 0x500227DC11D198AC, 0xB7DBFE813D021524, 0x6EAACF19DDD07B5A, 0x60EC16F48C0BE620,
    0x791C508A6E1205EA, 0x42337BA2D862B622, 0x10ED41289D47F052, 0xBD556D5B135BBF8E, 0xB74F55A0A96516A0,
    0x3B214D295DB514F7, 0xA7AB65A3C044B3DA, 0xE96D23CB66372699, 0xB062804C25EDD8A7, 0xA8EF0E67A39D62D9,
    0xF7141297FEB29B5D, 0x0DEB3D61CAED9567, 0x7AC77169773C0CE4, 0x0193A08E3EDA269B, 0xDBF3EC4C65A69F5D,
    0x3A43FEE3639BA301, 0x309033B5E5872675, 0xEF0C2293B7888864, 0xD807FA29ADE65957, 0x10017676688AA504,
    0xD8F132C02494531F, 0x5D4D49C598C7C2E3, 0xD3184F6BD8E629CC, 0xA227D8D1EB22C467, 0x7D5F7C90590CD76C,
    0xE351230372B8AA43, 0xC65BAF14769DFCEB, 0x13D19F33ABDEFDA4, 0x6B170B796C325537, 0x8640A18245382F66,
    0xC53FA0D15249C949, 0x9988214E2D3F25C2, 0x6A0D63DA93EF3459, 0x99433514E821A363, 0xF002CCA1F7FD6978,
    0x947A2EEC879CF0C4, 0xC5C3FCD994414A11, 0x45EF058BC984C7E8, 0x03745EEB6C08A0B7, 0xF3D78078D942C1F5,
    0x3E93846A0C0904EF, 0x71D3FF58545A7240, 0x36F1FB399593A42E, 0xCA39C5BF26B5A8CE, 0x98CD99EC1E257D5A,
    0x94BFC99C9D77FBE9, 0x3F4E33C9A0B9B05E, 0xDC7B09876FB19FFF, 0x8BD87DE72E1A3157, 0x0613243A490D11EA,
    0x0613243A490D11EA, 0x0613243A490D11EA, 0xBFBDAC657253E431, 0x73235D7F8A764EA3, 0x070B3A354E4B91E8,
    0x6C322F848110963C, 0x07FB54E5A776E0DD, 0x4EE7754C40081FFB, 0x59BA34C2182DFAED, 0x761C67A1D52C27D8,
    0x5AAA7F375D3FAFD7, 0x7CAF97EA114D54A9, 0xA029E9DED863C78E, 0xB13FD71EA972B2E7, 0x061A5C9D1EB44C60,
    0x0526D0B41AA7E7F3, 0xD7A4B6C19268884E, 0x0023C43AFE5425C2, 0x0B56CDEC643B3C5C, 0xA5C4BE35A6484D2A,
    0x44C45991DF83F528, 0x954AB2622DDDCDAE, 0xB2BD1F28DDE601B0, 0x09A0A000A6C314BE, 0x0000000000000000,
    0xF512E3A5DFD6C51C, 0x27CDE290C32867A9, 0x379CADECE541E342, 0xFC139EC967F75F74, 0xAB73644DAB95C51A,
    0x65AF5100E77A2982, 0x0DB9BC878EC6B280, 0xFB0158EFB8889A2A, 0x87684DAC4583AED5, 0xDC73596A59C3A8B9,
    0xF16BBF49DDEA88A9, 0xC83E4BE38A953FAA, 0xD2E3F99A952DC96B, 0x66153E29A9E4F5F0, 0xB025A0D5D09BAD53,
    0xC54DB3B091215CA0, 0xF2E9CB8F28FAED2D, 0x7410CAC4852F5168, 0x76535DC1C13DC342, 0x56AE4185FFB27F3B,
    0xBC46374D5FE945CC, 0x4E3F3F3D686C1376, 0xFD06F928C97B0C13, 0x272430E460312991, 0x8CDC59AF8D2FE8C0,
    0x3C39F714BDF14002, 0x582E3694A7D7A81C, 0xDAB71EE7131FB16F, 0x5C7F8A8CD61ADC6A, 0xD715DAADCCFE3707,
    0xD1104F0408894184, 0x0180D422774A2E76, 0x7EE4E115095A35FE, 0xE6ACC17E8C6E545D, 0x897D82A74C3DD55F,
    0x9322B76721A7E961, 0x88E70FFEEB920FAC, 0xE5E4636B15D921E1, 0xB2B199D7B0CC6E56, 0x361AF94AF4738607,
    0xBC8EB5FAC4FBFCAA, 0xDE485796A9BF0518, 0x4E988E099EB988FA, 0xBFA1E3CB2AC6A29F, 0xBA3A875662F7B1A3,
    0x90C5D36FD10D6A3C, 0x93046C79A53E24D9, 0x93610C96EB08CDAD,
)
# AudioSurface record (class D40CB4C0FFE45676) fields by their layout offset (skaterschema): +52 gain,
# +56 pitch-override flag, +68 pitch, +72 category (eMaterialNicotineType), +124 landing flag; the
# sample ids sub_824967F8 picks: per kind [tier 2, tier 0 × class 0/1/2, tier 1 × class 0/1/2]
# (kind 2: optional HOM_Set_1 fields, tier 0 class 0 through sub_824825D0).
MATERIAL_IDS = (
    ('Hash_9203DF6FD029B377', 'Hash_BFABF634D2B1E45A', 'Hash_9ABFC64574AB2F9F', 'Hash_BCD5E888294F7B15',
     'Hash_EF9BD81F9CFF725F', 'Hash_A3ADCA7B19287B5D', 'Hash_C676C87F862C0490'),
    ('Hash_F54277A83E0170FD', 'Hash_66A95889604DED36', 'Hash_595537EBA0196BE7', 'Hash_79DD0E6659793D0E',
     'Hash_B722B88FE44B046E', 'Hash_1411108A7E9CC74A', 'Hash_50796F92F3DE449B'),
    ('Hash_3EA2579C2F3BB23B', 'Hash_137C683BFB506ECA', 'Hash_2A2830137430BB02', 'Hash_79BDE00B04DF51B9',
     'Hash_5432B35224E4B1C1', 'Hash_3FCBE0407F833721', 'Hash_53311C6761F135A1'),
)
MATERIAL_GAIN, MATERIAL_PITCH_FLAG, MATERIAL_PITCH = 'Hash_875BA75341DC8391', 'Hash_57E3031C18C769A1', 'Hash_C090F2C1F048F17B'
MATERIAL_PITCH_ALT, MATERIAL_CATEGORY = 'Hash_3A3DD47E8DAFE796', 'Hash_D5EF686287A57AFE'
# RefSpecs: +0 the contact-level windows (class 13E20D398E385A56, sub_82496C58 / sub_82496F50), +24 the
# impact bands (class 7DAFF70B3A91CD5D, sub_82497088).
MATERIAL_WINDOWS, MATERIAL_BANDS = 'Hash_82B1451A90152514', 'Hash_E228508FE0F53970'
WINDOW_CLASS = 'Hash_13E20D398E385A56'
WINDOW_FIELDS = ('Hash_036F313CEBC664FD', 'Hash_8001982DA2E91D6A', 'Hash_E24D9CB4000A53AC', 'Hash_1A83AD0330976744',
                 'Hash_24B725E05CEB027E', 'Hash_CBBB19E302CE1A17', 'Hash_75DC915E876A9DC9', 'Hash_711F1F54903E76C9',
                 'Hash_C8DED1BC20B9D6A5', 'Hash_B8870D2001033E0F')
WINDOW_SCALE = 'Hash_1A5F7E8CCABBB0A2'
WINDOW_FIELDS_2 = ('Hash_41F2E2456A97752A', 'Hash_2638FF12C8FBBCCB', 'Hash_166BAB2FD5B60560', 'Hash_0D6EF57A39AF0C93')
BAND_CLASS = 'Hash_7DAFF70B3A91CD5D'
BAND_FIELDS = ('Hash_C8DED1BC20B9D6A5', 'Hash_B8870D2001033E0F', 'Hash_7D8DEDD338D45482', 'Hash_D660AC459139BDF4')
# Poster tuning: (class, collection, field, name).
COLLISION_POSTERS = (
    ('Hash_049861E8F9A8D16B', 'default', 'Hash_086B66C3D4FFEE8F', 'grind_split'),
    ('Hash_049861E8F9A8D16B', 'default', 'Hash_B2ACAFDBCD963C93', 'grind_high'),
    ('Hash_C26949FCB638A2CA', 'default', 'Hash_6D68BC2D1A23C29A', 'landing_air'),
    ('Hash_C26949FCB638A2CA', 'default', 'Hash_85FDC8BF696BCA5C', 'landing_board'),
    ('Hash_C26949FCB638A2CA', 'default', 'Hash_3462CBB16DCA696E', 'landing_split'),
    ('Hash_C26949FCB638A2CA', 'default', 'Hash_590495E420B399E5', 'landing_high'),
    ('Hash_C26949FCB638A2CA', 'default', 'Hash_31DEEF8FA219950F', 'landing_scale_a'),
    ('Hash_C26949FCB638A2CA', 'default', 'Hash_0EC6EEF5366FEA85', 'landing_scale_b'),
    ('Hash_6EBA5BCD3E38A98A', 'default', 'Hash_27D3C5DC3282B59D', 'deck_cooldown'),
    ('Hash_C26949FCB638A2CA', 'default', 'Hash_823D59FB46324175', 'scuff_speed'),
    ('Hash_C26949FCB638A2CA', 'default', 'Hash_733C45DF5B638ECB', 'scuff_ids'),
    ('Hash_C26949FCB638A2CA', 'default', 'Hash_F2866EE0540CDF05', 'scuff_ids_soft'),
    ('Hash_923CCB46EF5BF5BA', 'Hash_F1647BFB782BE97F', 'Hash_6BFB6A3F22AAF797', 'tap_off_ms'),
    ('Hash_923CCB46EF5BF5BA', 'Hash_F1647BFB782BE97F', 'Hash_B63CC740D29AD118', 'tap_speed'),
    ('Hash_923CCB46EF5BF5BA', 'Hash_F1647BFB782BE97F', 'Hash_7D1CA200987AA109', 'tap_mid'),
    ('Hash_923CCB46EF5BF5BA', 'Hash_F1647BFB782BE97F', 'Hash_E1F87C4937E3CCA2', 'tap_high'),
    ('Hash_923CCB46EF5BF5BA', 'Hash_F1647BFB782BE97F', 'Hash_6F133132EF3F8063', 'tap_first'),
    ('Hash_923CCB46EF5BF5BA', 'Hash_F1647BFB782BE97F', 'Hash_E518088F4E61203A', 'tap_second'),
    ('Hash_923CCB46EF5BF5BA', 'Hash_F1647BFB782BE97F', 'Hash_4CFF36855CA04B6F', 'tap_both'),
    ('Hash_923CCB46EF5BF5BA', 'Hash_F1647BFB782BE97F', 'Hash_3AC5AA2D2010B49C', 'tap_special'),
    ('Hash_923CCB46EF5BF5BA', 'Hash_F1647BFB782BE97F', 'Hash_DB56952676D7122E', 'tap_first_soft'),
    ('Hash_923CCB46EF5BF5BA', 'Hash_F1647BFB782BE97F', 'Hash_0ACFCB7E532B7A0B', 'tap_second_soft'),
    ('Hash_923CCB46EF5BF5BA', 'Hash_F1647BFB782BE97F', 'Hash_7EA37827E4228614', 'tap_other_soft'),
)

# The push foot's plant / lift (sub_824BBB28, Contacts `default`): sk8_foley ids by material kind 0..4.
PLANT_FIELDS = ('Hash_1A5D3CDBA6C160D0', 'Hash_6C93C9BAD7B07C6B', 'Hash_9CCABF46584CA16C', 'Hash_57553DC3A33C9B38',
                'Hash_4F138972C957C8AF')
LIFT_FIELDS = ('Hash_2D97D30AEA78BCE2', 'Hash_73CB69882A79481B', 'Hash_767F6CAEACB748C8', 'Hash_A17BA1994B766B55',
               'Hash_8D8EF475983B33A8')
# The eEQChain holder (class 42AFE160E647167C `default`): the plant / lift bus and the grind contact sounds' bus.
EQCHAIN_CLASS = 'Hash_42AFE160E647167C'
PLANT_EQ = 'Hash_748CBC9727A5347F'
GRIND_CONTACT_EQ = 'Hash_D1A87641CCB98787'
# The body poster (sub_824BC188; class 6EBA5BCD3E38A98A `default`): the per-region cooldown and the pad thresholds.
BODY_POSTERS = (('Hash_6DD85F43C1B6E6AA', 'body_cooldown'),
                ('Hash_D12003A60E987B9D', 'body_110_head_low'), ('Hash_FA2AA5A0C0481D00', 'body_110_head_high'),
                ('Hash_AFA4B5090F1BCF36', 'body_110_torso_low'), ('Hash_00960FEDB3EFEE9C', 'body_110_torso_high'),
                ('Hash_3695327CFB5E1AC3', 'body_111_low'), ('Hash_35FEE8A95523D812', 'body_111_high'),
                ('Hash_076E9081CA1759E9', 'body_112_low0'), ('Hash_DF539915EB7E883E', 'body_112_high0'),
                ('Hash_8E3025BAA686F721', 'body_112_low1'), ('Hash_504D3B73505972D4', 'body_112_high1'))
# The bridge's speed graph on the body impacts (sub_824B0DA8; class 6EBA5BCD3E38A98A `default`).
BODY_SPEED_GRAPH = 'Hash_8B164823E008749C'
# The grind on / off contact sounds per grind surface (class GRIND_CLASS): the metal flag (Skate_Metal, else
# Skate_Collisions), the ids per layer 0..3 by bank (sub_824C35D0 / sub_824C37D8), the per-layer level factor
# (sub_824C2FA0 / sub_824C3190) and the level / pitch endpoints A, B (sub_824C2FA0 / 3190 / 3380 / 34A8).
GRIND_METAL = 'Hash_02BAC36BCC8A30DE'
GRIND_CONTACTS = {
    'on': {'ids': (('Hash_013C2E46521A9080', 'Hash_71F2DBB8CA385137', 'Hash_F9FED84DD3E93919', 'Hash_2162F0EFBDDE72C6'),
                   ('Hash_F344EC2BC1BD4B6E', 'Hash_4A76108CDB52FDD3', 'Hash_8375C9A4AD144F7D', 'Hash_991C563B70C40DED')),
           'gain': ('Hash_3D63FBC14F6A6CEA', 'Hash_0BD0F347C3AC6D00', 'Hash_18A94AE8DEED0D27', 'Hash_AA81C2EC8304ADF0'),
           'level': ('Hash_60418B2EF89EFE2D', 'Hash_FF11B09A395C5F7B'),
           'pitch': ('Hash_AA380B47376A7415', 'Hash_E5E8E505DDEE595B')},
    'off': {'ids': (('Hash_FDDA1C015F450486', 'Hash_9086C01E46C97B05', 'Hash_B2DB39923B3A2C3F', 'Hash_FFD9CE934742D506'),
                    ('Hash_A7639B2F6ABFF8E8', 'Hash_F314474F29EB8D64', 'Hash_60470BE7D8CA45C4', 'Hash_92258B0B80C10301')),
            'gain': ('Hash_958D61F2EC118BFF', 'Hash_94E3254CD727BEA6', 'Hash_751C968D0992C231', 'Hash_624BCB9A663D35DB'),
            'level': ('Hash_D0BD38748095DCE3', 'Hash_E02ABA94997FABE7'),
            'pitch': ('Hash_9F866C1CA0A23F3C', 'Hash_196D60DE7611D2D3')},
}


def _words(field) -> list[int]:
    """Signed 32-bit words of a field (arrays: one per item, first word)."""
    items = field['array']['items'] if 'array' in field else [field.get('data', '')]
    out = []
    for item in items:
        data = ''.join(item.split())
        if len(data) >= 8:
            out.append(struct.unpack('>i', bytes.fromhex(data[:8]))[0])
        elif data:
            out.append(int(data[:2], 16))
    return out


def _scalar_or_list(field):
    """A scalar or array field: floats for Float types, else signed words."""
    if field.get('type', '').endswith('Float'):
        items = field['array']['items'] if 'array' in field else [field.get('data', '')]
        values = [struct.unpack('>f', bytes.fromhex(''.join(i.split())[:8]))[0] for i in items]
    else:
        values = _words(field)
    return values if 'array' in field else (values[0] if values else 0)


def collision_tuning(resolve, by_class) -> dict:
    """{'materials': [143 rows], 'posters': {...}}: the collision manager's material table and the
    vault values its posters read. `resolve(cls, key, field)` follows the parent chain."""
    # Some AudioSurface records are keyed by their name in the converted collections (head, torso, water,
    # drum_pylon, crumpled_paper; the band holder `default`), while the image's material table and the
    # RefSpecs name them by hash64: alias those so the lookups find them (before 2026-10-03 materials
    # 77 / 87 / 92 / 97 / 98 exported as missing and the RefSpecs to `default` bands resolved nothing).
    from .vlt import hash64
    outer = resolve
    aliased = {}
    for cls in (MATERIAL_CLASS, WINDOW_CLASS, BAND_CLASS):
        records = dict(by_class.get(cls, {}))
        for name in list(records):
            if not name.startswith('Hash_'):
                records.setdefault('Hash_%016X' % hash64(name), records[name])
        aliased[cls] = records

    def resolve(cls, key, field):
        if cls not in aliased:
            return outer(cls, key, field)
        records, seen = aliased[cls], 0
        while key in records and seen < 32:
            if field in records[key]['fields']:
                return records[key]['fields'][field]
            key, seen = records[key].get('parent', ''), seen + 1
        return None

    by_class = {**by_class, **aliased}
    def ref_key(field):
        data = ''.join(field.get('data', '').split()) if field else ''
        return 'Hash_' + data[16:32].upper() if len(data) >= 32 else None

    def word(cls, key, f, default=0):
        v = resolve(cls, key, f)
        return _words(v)[0] if v is not None and _words(v) else default

    rows = []
    for m in range(143):
        kind, key = MATERIAL_KINDS[m], 'Hash_%016X' % MATERIAL_KEYS[m]
        row = {'kind': kind}
        if key not in by_class.get(MATERIAL_CLASS, {}):
            row['missing'] = True
        if 0 <= kind < 3:
            row['ids'] = [word(MATERIAL_CLASS, key, f) for f in MATERIAL_IDS[kind]]
        row['gain'] = word(MATERIAL_CLASS, key, MATERIAL_GAIN)
        row['pitch'] = word(MATERIAL_CLASS, key, MATERIAL_PITCH, 4096)
        row['pitch_flag'] = word(MATERIAL_CLASS, key, MATERIAL_PITCH_FLAG) != 0
        alt = resolve(MATERIAL_CLASS, key, MATERIAL_PITCH_ALT)
        if alt is not None:
            row['pitch_alt'] = _words(alt)[0]
        row['category'] = word(MATERIAL_CLASS, key, MATERIAL_CATEGORY)
        row['landing'] = word(MATERIAL_CLASS, key, LANDING_FLAG) != 0
        # SFXObj_OffBoard's footstep layer of the material (`sub_82493E60`, skate_audio::player::
        # footsteps::FootstepMaterial): +125 has footsteps, +48 / the landing gain (x 32767).
        row['footsteps'] = word(MATERIAL_CLASS, key, MATERIAL_FOOTSTEPS) != 0
        row['step_gain'] = word(MATERIAL_CLASS, key, MATERIAL_STEP_GAIN, 32767)
        row['step_landing_gain'] = word(MATERIAL_CLASS, key, MATERIAL_STEP_LANDING_GAIN, 32767)
        windows_key = ref_key(resolve(MATERIAL_CLASS, key, MATERIAL_WINDOWS))
        if windows_key and windows_key in by_class.get(WINDOW_CLASS, {}):
            w = [word(WINDOW_CLASS, windows_key, f) for f in WINDOW_FIELDS]
            w += [word(WINDOW_CLASS, windows_key, f) for f in WINDOW_FIELDS_2]
            row['windows'] = w
            scale = resolve(WINDOW_CLASS, windows_key, WINDOW_SCALE)
            row['scale'] = _scalar_or_list(scale) if scale is not None else 0.0
        bands_key = ref_key(resolve(MATERIAL_CLASS, key, MATERIAL_BANDS))
        if bands_key and bands_key in by_class.get(BAND_CLASS, {}):
            row['bands'] = [(_scalar_or_list(v) if (v := resolve(BAND_CLASS, bands_key, f)) is not None else 0.0) for f in BAND_FIELDS]
        rows.append(row)
    posters = {}
    for cls, key, field, name in COLLISION_POSTERS:
        v = resolve(cls, key, field)
        if v is not None:
            posters[name] = _scalar_or_list(v)
    for name, fields in (('plant_ids', PLANT_FIELDS), ('lift_ids', LIFT_FIELDS)):
        values = [resolve(WHEEL_CLASS, 'default', f) for f in fields]
        if all(v is not None for v in values):
            posters[name] = [_words(v)[0] for v in values]
    v = resolve(EQCHAIN_CLASS, 'default', PLANT_EQ)
    if v is not None:
        posters['plant_eq'] = _words(v)[0]
    for field, name in BODY_POSTERS:
        v = resolve('Hash_6EBA5BCD3E38A98A', 'default', field)
        if v is not None:
            posters[name] = _scalar_or_list(v)
    # The audio-state bridge's speed graph (sub_824B0DA8 scales the region impacts by it at the
    # previous frame's |COM v|): a Sk8::PointNegGraphData8, x at +16, y at +48.
    v = resolve('Hash_6EBA5BCD3E38A98A', 'default', BODY_SPEED_GRAPH)
    if v is not None:
        floats = _floats(v)
        if len(floats) >= 20:
            posters['body_speed_x'], posters['body_speed_y'] = floats[4:12], floats[12:20]
    return {'materials': rows, 'posters': posters}


def _word(field) -> int:
    """The first 32-bit word of a field as a signed int (enums, bools as stored)."""
    data = ''.join(field.get('data', '').split())
    return struct.unpack('>i', bytes.fromhex(data[:8].ljust(8, '0')))[0] if data else 0


# The environment (reverb) network's presets (audio-specs/aems-env-bus-spec.md §3, §6): vault class
# `204CAC1FD77088B8` (`aud_reverb/reverbNN`), fields in record-offset order 0..172 (the layout the disc's
# schema gives; +48 is the preset number). `sub_8248DD18` reads them by offset.
REVERB_CLASS = 'Hash_204CAC1FD77088B8'
REVERB_FIELDS = ('48376C6D695CDDBB', '4E7CDD2F6C41296F', '22FB428A30D3602C', '66588E403F254F64', '8968075E7CBACC4E',
                 'FA81EA055905EB17', '2490987C531FB4E9', '5075CFC3C70ACB30', '1812369BC788F71F', 'D548E99383500988',
                 '4C50D4334042E446', '4ABF29854AA8167A', '3F9A78465CFFC183', '578AB8D6BF494236', 'C8A4239F7CBBF072',
                 'B3BB9F5129BBCFB5', '2EBE3CBF5E339625', '533ED00D3783EF02', '8249454FFE32EA2B', 'DECBDDB58AC61519',
                 '2DA3FDBA90F64924', 'C76E3B36EC05F9E0', '27D28928F58346B1', '30DCBFB636929C6A', '103E1FD179ADA674',
                 'F38B7E9560E0AA84', 'C7F29E4229F528B6', '3E80A0539763F3DF', 'EDA35434B3617A0A', '024737095437438A',
                 'E9E26ECCA2D28D11', '81504B05719020A0', '433B43350289C6CE', 'FC50736430148B30', '35B87D3598BAD8E5',
                 '58C65800CA17ACD9', '9BAA927DA7AA8970', '7492F9438252B839', '843273C75A0984F5', '7B2416B80E3BA149',
                 'D6812FA712AACD13', '796D8327E0995ECC', 'B388DAFB738410FC', 'EECADFA12642D9F3')
# The eight eEQChain ("material") buses (audio-specs/aems-eqchain-buses-spec.md §1.3): vault class
# `AA801D9FC0ADBBBF`, collection per bus from the TU3 image table 0x8224DC78 (facts), the enable flag,
# the clip level and the six (a, b) range pairs PI20#1 freq / gain / Q, PI20#2 freq / gain / Q.
EQ_BUS_CLASS = 'Hash_AA801D9FC0ADBBBF'
# The two FlangeSub effect returns (`sub_824DDF58` -> `sub_8248FE68`): class 4CDD7CDC1A955D5C,
# collection A (voice routing 4096 / 8192) and B (16384); nine floats by record offset 0..32.
FLANGE_CLASS = 'Hash_4CDD7CDC1A955D5C'
FLANGE_KEYS = ('C6290FFCB9E84CD9', 'DFDFFAD67CCBA322')
FLANGE_FIELDS = ('DE9BF5C10AB2C866', '113F78E17495296F', '3C0376079AD9A56C', '7D3294EC1C443CBD', 'CD44B25FAD9E48D9',
                 'EDEE41D561FA8CE5', '9C890EC62D3BC5C6', 'D10D7F661896AC30', '9024FC56E2314F9F')
EQ_BUS_KEYS = ('42DDFA3F5011BAB4', 'DA24A51DDC51EDF3', '201C88714085E3C3', '8AF23914D89E4AF0',
               'F7CFA0A8D2F98BDE', '8AA93567C056736B', '87D5F21D9A71736A', 'BFA2D9D8C138F925')
EQ_BUS_ENABLE = 'Hash_C6DA68C12A3822D2'
EQ_BUS_CLIP = 'Hash_2086A0CE99C39A86'
EQ_BUS_RANGES = (('5B48CBEB3EB440D2', '2B77D4F58AF71CCF'), ('7317CC02098BDFF6', '90A94DDDA5F804CB'),
                 ('F30B7500D67E206B', 'B4190B5C42432FA2'), ('3264F689300A522A', '1DA611DA4DE5A67A'),
                 ('54868EDE952EF581', '25853859640A3796'), ('594D91B30B95483A', 'CDF599CDEC9C7C64'))


def bus_tuning(collections: list[dict]) -> dict:
    """{'reverb': {key: [44 values by record offset]}, 'eq_buses': [8 × {'enabled', 'clip', 'ranges'}]}
    for the native runtime's environment network and eEQChain buses. Values exact (f32)."""
    by_class: dict[str, dict] = {}
    for c in collections:
        by_class.setdefault(c['class'], {})[c['key']] = c

    def resolve(cls, key, field):
        records, seen = by_class.get(cls, {}), 0
        while key in records and seen < 32:
            if field in records[key]['fields']:
                return records[key]['fields'][field]
            key, seen = records[key].get('parent', ''), seen + 1
        if key != 'default' and 'default' in records:
            return records['default']['fields'].get(field)
        return None

    out: dict = {}
    if REVERB_CLASS in by_class:
        presets = {}
        for key in by_class[REVERB_CLASS]:
            if not key.startswith('Hash_'):
                continue
            row = []
            for i, h in enumerate(REVERB_FIELDS):
                v = resolve(REVERB_CLASS, key, 'Hash_' + h)
                row.append(0 if v is None else (_word(v) if i == 12 else _exact(v)))
            presets[key[5:]] = row
        out['reverb'] = presets
    if EQ_BUS_CLASS in by_class:
        buses = []
        for key in EQ_BUS_KEYS:
            k = 'Hash_' + key
            enable = resolve(EQ_BUS_CLASS, k, EQ_BUS_ENABLE)
            clip = resolve(EQ_BUS_CLASS, k, EQ_BUS_CLIP)
            ranges = []
            for a, b in EQ_BUS_RANGES:
                va, vb = resolve(EQ_BUS_CLASS, k, 'Hash_' + a), resolve(EQ_BUS_CLASS, k, 'Hash_' + b)
                ranges.append([_exact(va) if va else 0.0, _exact(vb) if vb else 0.0])
            buses.append({'enabled': bool(enable and ''.join(enable['data'].split()).startswith('01')),
                          'clip': _exact(clip) if clip else 100.0, 'ranges': ranges})
        out['eq_buses'] = buses
    if FLANGE_CLASS in by_class:
        returns = []
        for key in FLANGE_KEYS:
            values = [resolve(FLANGE_CLASS, 'Hash_' + key, 'Hash_' + f) for f in FLANGE_FIELDS]
            if any(v is None for v in values):
                break
            returns.append([_exact(v) for v in values])
        if len(returns) == 2:
            out['flange'] = returns
    return out


def player_tuning(collections: list[dict], image: bytes | None = None, image_base: int = 0x82000000) -> dict:
    """{'surface_table': [95 × 18 ints], 'jitter': [...], 'seam_wobbles': [16], 'grind': [14],
    'landing_materials': [...], 'wheel_bucket_high', 'wheel_bucket_low'}. `image` (optional, the
    TU3 image from `image_base`) supplies the material key table; without it the landing-flag list
    is empty."""
    from .vlt import hash64
    by_class: dict[str, dict] = {}
    for c in collections:
        by_class.setdefault(c['class'], {})[c['key']] = c

    def resolve(cls, key, field):
        records, seen = by_class.get(cls, {}), 0
        while key in records and seen < 32:
            if field in records[key]['fields']:
                return records[key]['fields'][field]
            key, seen = records[key].get('parent', ''), seen + 1
        return None

    out: dict = {}
    holder = by_class.get(SURFACE_MAP[0], {}).get(SURFACE_MAP[1])
    if holder and SURFACE_MAP[2] in holder['fields']:
        rows = []
        for item in holder['fields'][SURFACE_MAP[2]]['array']['items']:
            data = ''.join(item.split())
            words = [struct.unpack('>i', bytes.fromhex(data[i:i + 8]))[0] for i in range(0, min(len(data), 144) - 7, 8)]
            rows.append(words + [0] * (18 - len(words)))
        out['surface_table'] = rows
    jitter = by_class.get(JITTER_CLASS, {})
    if jitter:
        parents = {c.get('parent', '') for c in jitter.values()}
        leaves = sorted((k for k in jitter if k not in parents and k.startswith('Hash_')), key=lambda k: int(k[5:], 16))
        channels = []
        for key in leaves:
            enabled = resolve(JITTER_CLASS, key, 'Hash_8F956FBAD301AE26')
            ident = resolve(JITTER_CLASS, key, 'Hash_E7D491E2EB228F54')
            params = resolve(JITTER_CLASS, key, 'Hash_B66AAD957873A8B3')
            if params is None:
                continue
            channels.append({'enabled': bool(enabled and enabled['data'].startswith('01')),
                             'id': _exact(ident) if ident else 0, 'params': _floats(params), 'key': key[5:]})
        out['jitter'] = channels
    if SEAM_CLASS in by_class:
        wobbles = []
        for key in ['default'] + ['Hash_%016X' % hash64(name) for name in SEAM_PATTERNS]:
            entry = {}
            for field, name in {**SEAM_FIELDS, **SEAM_PATTERN_FIELDS}.items():
                value = resolve(SEAM_CLASS, key, field)
                if value is not None:
                    entry[name] = _word(value) if name == 'mode' else _exact(value)
            wobbles.append(entry)
        out['seam_wobbles'] = wobbles
    if GRIND_CLASS in by_class:
        surfaces = []
        for k in GRIND_SURFACE_KEYS:
            key = 'Hash_%016X' % k
            v = [resolve(GRIND_CLASS, key, f) for f in GRIND_V]
            f = [resolve(GRIND_CLASS, key, f) for f in GRIND_F]
            entry = {'v': [_exact(x) if x else 1.0 for x in v], 'f': [_exact(x) if x else 1.0 for x in f]}
            # The grind on / off contact sounds (sub_824C3FC8 / sub_824C4138).
            metal = resolve(GRIND_CLASS, key, GRIND_METAL)
            if metal is not None:
                entry['metal'] = ''.join(metal.get('data', '').split())[:2] not in ('', '00')
            for kind, fields in GRIND_CONTACTS.items():
                ids = [resolve(GRIND_CLASS, key, x) for x in fields['ids'][int(entry.get('metal', False))]]
                gain = [resolve(GRIND_CLASS, key, x) for x in fields['gain']]
                level = [resolve(GRIND_CLASS, key, x) for x in fields['level']]
                pitch = [resolve(GRIND_CLASS, key, x) for x in fields['pitch']]
                if any(x is None for x in ids + level + pitch):
                    continue
                entry[kind] = {'ids': [_words(x)[0] for x in ids], 'gain': [_exact(x) if x else 1.0 for x in gain],
                               'level': [_exact(x) for x in level], 'pitch': [_exact(x) for x in pitch]}
            surfaces.append(entry)
        out['grind'] = surfaces
        bus = by_class.get(EQCHAIN_CLASS, {}).get('default', {}).get('fields', {}).get(GRIND_CONTACT_EQ)
        if bus is not None:
            out['grind_contact_eq'] = _words(bus)[0]
    wheel = by_class.get(WHEEL_CLASS, {}).get('default')
    if wheel:
        for field, name in WHEEL_BUCKET.items():
            if field in wheel['fields']:
                out[name] = _exact(wheel['fields'][field])
    # Conditioner82772D30 reads the two jump-strength cutoffs (index1 first).
    jump = resolve('Hash_A867FBE3454326FF', 'default', 'Hash_468752B0BEE65CDB')
    if jump is not None:
        values = [struct.unpack('>f', bytes.fromhex(x))[0] for x in jump['array']['items']]
        if len(values) != 2:
            raise ValueError('native jump-strength tuning must contain two thresholds')
        out['jump_thresholds'] = values
    if TRICK_CLASS in by_class:
        for name, field in (('audio_tricks', TRICK_FIELD), ('audio_tricks_2', TRICK_FIELD_2)):
            tricks = {}
            for key in by_class[TRICK_CLASS]:
                value = resolve(TRICK_CLASS, key, field) if key.startswith('Hash_') else None
                if value is not None and len(''.join(value.get('data', '').split())) == 8:
                    tricks[key[5:]] = struct.unpack('>i', bytes.fromhex(''.join(value['data'].split())))[0]
            out[name] = tricks
    if image is not None and MATERIAL_CLASS in by_class:
        flagged = []
        at = MATERIAL_KEY_TABLE - image_base
        for m in range(143):
            if at + 16 * m + 16 > len(image):
                break
            key = 'Hash_%016X' % struct.unpack_from('>Q', image, at + 16 * m + 8)[0]
            value = resolve(MATERIAL_CLASS, key, LANDING_FLAG)
            if value is not None and value['data'].startswith('01'):
                flagged.append(m)
        out['landing_materials'] = flagged
    if MATERIAL_CLASS in by_class:
        out['collision'] = collision_tuning(resolve, by_class)
        if 'landing_materials' not in out:
            out['landing_materials'] = [m for m, row in enumerate(out['collision']['materials']) if row['landing']]
    return out


def aems_files(files: BigArchive, output: Path, banks) -> dict:
    """Copy the native AEMS runtime's inputs into output/'aems', byte for byte: every Csis project
    (`.csi`, in archive order, the order the runtime installs them) and the ABKC module banks among
    `banks` plus AEMS_EXTRA_BANKS. The runtime runs each bank's own patch programs; its samples stay
    the decoded WAVs (S10A slot i = banks/<stem>/<i>.wav, the same order scan_snr finds them)."""
    folder = output/'aems'
    folder.mkdir(parents=True, exist_ok=True)
    by_name = {Path(e.path).name: e for e in files.entries}
    projects = [Path(e.path).name for e in files.entries if e.path.lower().endswith('.csi')]
    for name in projects:
        (folder/name).write_bytes(files.read(by_name[name]))
    copied = {}
    for bank in sorted(set(banks) | set(AEMS_EXTRA_BANKS)):
        entry = by_name.get(bank)
        if entry is None or not bank.lower().endswith('.abk'):
            continue
        data = files.read(entry)
        if data[:4] != b'ABKC':
            continue
        (folder/bank).write_bytes(data)
        copied[Path(bank).stem] = f'aems/{bank}'
    return {'projects': [f'aems/{name}' for name in projects], 'banks': copied}


def splice_trees(files: BigArchive, output: Path, banks) -> dict:
    """Copy the patch tree (header, records, containers, groups: everything before the sample table)
    of each SPLC bank among `banks` into output/'aems'/<stem>.splc for the native Splice player
    (crates/skate-audio `splice`); its samples stay the decoded WAVs (sample n = banks/<stem>/<n>.wav).
    Returns {stem: path}."""
    folder = output/'aems'
    by_name = {Path(e.path).name: e for e in files.entries}
    out = {}
    for bank in sorted(set(banks)):
        entry = by_name.get(bank)
        if entry is None or not bank.lower().endswith('.bnk'):
            continue
        data = files.read(entry)
        if data[:4] != b'SPLC':
            continue
        splc_patches(data)  # validates the walk ends exactly at the sample table
        tree = 60 + struct.unpack_from('>I', data, 8)[0]
        folder.mkdir(parents=True, exist_ok=True)
        (folder/f'{Path(bank).stem}.splc').write_bytes(data[:tree])
        out[Path(bank).stem] = f'aems/{Path(bank).stem}.splc'
    return out


def convert(game_root: Path, private: Path, work: Path, vgmstream: Path, report, log) -> dict:
    """Write private/audio/** and private/audio/audio_manifest.json; return the manifest."""
    audio_root = game_root/'data/audio'
    output = private/'audio'
    if output.exists():
        shutil.rmtree(output)
    work.mkdir(parents=True, exist_ok=True)
    manifest = {'version': VERSION, 'ambience': {}, 'grains': {}, 'wheels': {}, 'banks': {}, 'patches': {}}

    report('Decoding ambience')
    beds, headers = BigArchive(audio_root/'ambience.big'), BigArchive(audio_root/'ambienceresident.big')
    bodies = {Path(e.path).stem: e for e in beds.entries if e.path.endswith('.sns')}
    heads = {Path(e.path).stem: e for e in headers.entries if e.path.endswith('.snr')}
    folder = work/'ambience'
    folder.mkdir()
    for name in AMBIENCE:
        if name not in bodies or name not in heads:
            raise KeyError(f'ambience bed {name} is missing from the disc')
    (output/'ambience').mkdir(parents=True)
    for name in AMBIENCE:
        (folder/(name + '.snr')).write_bytes(headers.read(heads[name]))
        (folder/(name + '.sns')).write_bytes(beds.read(bodies[name]))
        _decode(vgmstream, folder, [name + '.snr'], log)
        decoded = folder/(name + '.snr.wav')
        info = _stereo(decoded, output/'ambience'/(name + '.wav'))
        decoded.unlink()  # ~65 MB of five-channel PCM each
        manifest['ambience'][name] = {'file': f'ambience/{name}.wav', **info}

    for kind, archive, suffix in (('grains', 'grains.big', '.grain'), ('wheels', 'wheels.big', '.snr')):
        report(f'Decoding {kind}')
        source = BigArchive(audio_root/archive)
        folder = work/kind
        folder.mkdir()
        names, members = [], {}
        for entry in source.entries:
            if not entry.path.endswith(suffix):
                continue
            stem, data = Path(entry.path).stem, source.read(entry)
            members[stem] = data
            stream = grain(data).stream if suffix == '.grain' else scan_snr(data)[0]
            (folder/(stem + '.snr')).write_bytes(standalone(data, stream))
            names.append(stem)
        _decode(vgmstream, folder, [stem + '.snr' for stem in names], log)
        (output/kind).mkdir(parents=True)
        for stem in names:
            decoded = folder/(stem + '.snr.wav')
            if kind == 'grains':
                bands = _grain_bands(decoded, output/kind/stem, f'{kind}/{stem}')
                manifest[kind][stem] = {'bands': bands, **grain_whole(stem, members[stem], decoded, output/kind)}
                continue
            target = output/kind/(stem + '.wav')
            shutil.move(decoded, target)
            manifest[kind][stem] = {'file': f'{kind}/{stem}.wav', **_wav_info(target)}

    report('Decoding sound effect banks')
    files = BigArchive(audio_root/'audiofiles.big')
    by_name = {Path(e.path).name: e for e in files.entries}
    collections, record_names = _collections(game_root, work)
    manifest['grain_player'] = grain_tuning(collections)
    manifest['player_tuning'] = player_tuning(collections)
    manifest['bus_tuning'] = bus_tuning(collections)
    manifest['frontend'] = frontend_sounds(collections)
    attributes = emitter_attributes(collections)
    manifest['emitters'], placed = emitters(files, attributes)
    by_file = {Path(e.path).name.lower(): Path(e.path).name for e in files.entries}
    manifest['random_sets'], random_banks = random_sets(collections, attributes, record_names, by_file)
    placed |= random_banks
    manifest['zones'], manifest['crossfades'] = ambience_zones(collections, record_names)
    placed |= set(CROSSFADE_BANKS)
    # The world sources' banks, tuning and speech index (crates/skate-audio/src/world; inert in game
    # until a ped / traffic system publishes owners).
    from .world_audio import WORLD_BANKS, WORLD_SPLICE_BANKS, world_tuning
    placed |= set(WORLD_BANKS)
    manifest['world_tuning'] = world_tuning(collections, record_names, (private/'stock', game_root))
    report('Reading audio regions')
    manifest['regions'] = regions(game_root, work)
    for bank in BANKS + tuple(sorted(placed - set(BANKS))):
        if bank not in by_name:
            raise KeyError(f'sound bank {bank} is missing from the disc')
        data = files.read(by_name[bank])
        stem = Path(bank).stem
        folder = work/'banks'/stem
        folder.mkdir(parents=True)
        streams = _streams(bank, data)
        for index, stream in enumerate(streams):
            (folder/f'{index:04d}.snr').write_bytes(standalone(data, stream))
        _decode(vgmstream, folder, [f'{index:04d}.snr' for index in range(len(streams))], log)
        target_folder = output/'banks'/stem
        target_folder.mkdir(parents=True)
        samples = []
        for index in range(len(streams)):
            target = target_folder/f'{index:04d}.wav'
            shutil.move(folder/f'{index:04d}.snr.wav', target)
            samples.append({'file': f'banks/{stem}/{index:04d}.wav', **_wav_info(target)})
        manifest['banks'][stem] = samples
        if data[:4] == b'SPLC':
            # Retail's own layering/randomisation per sound (audio_formats.splc_patches).
            manifest['patches'][stem] = splc_patches(data)

    report('Copying the AEMS banks and projects')
    manifest['aems'] = aems_files(files, output, BANKS + tuple(placed))
    mixmap = mixmap_file(audio_root, output)
    if mixmap:
        manifest['aems']['mixmap'] = mixmap
    manifest['aems']['splice'] = splice_trees(files, output, BANKS + WORLD_SPLICE_BANKS)
    speech = audio_root/'english'/'livingworldspeech.big'
    if speech.is_file():
        report('Indexing world speech')
        from .world_audio import decode_speech, speech_index, speech_requested
        index = speech_index(speech)
        (output/'speech').mkdir(parents=True, exist_ok=True)
        (output/'speech'/'livingworld.json').write_text(json.dumps(index), encoding='utf-8')
        entry = {'index': 'speech/livingworld.json', 'audio': None}
        if speech_requested():  # SKATE_SETUP_SPEECH=1: ~2.4 GB of PCM
            report('Decoding world speech')
            decode_speech(speech, index, output/'speech'/'livingworld', work/'speech', vgmstream, _decode, log)
            entry['audio'] = 'speech/livingworld'
        manifest['speech'] = {'livingworld': entry}
    main_cast = audio_root/'english'/'maincastspeech.big'
    if main_cast.is_file():
        report('Indexing main-cast speech')
        from .world_audio import MAIN_CAST_EVENTS, decode_speech, speech_index, speech_requested
        index = speech_index(main_cast, 'maincast')
        (output/'speech').mkdir(parents=True, exist_ok=True)
        (output/'speech'/'maincast.json').write_text(json.dumps(index), encoding='utf-8')
        entry = {'index': 'speech/maincast.json', 'audio': None}
        if speech_requested():  # SKATE_SETUP_SPEECH=1: ~0.95 GB more
            report('Decoding main-cast speech')
            decode_speech(main_cast, index, output/'speech'/'maincast', work/'speech_maincast', vgmstream, _decode, log,
                          events=MAIN_CAST_EVENTS)
            entry['audio'] = 'speech/maincast'
        manifest.setdefault('speech', {})['maincast'] = entry
    announcer = audio_root/'english'/'announcerspeech.big'
    if announcer.is_file():
        report('Indexing announcer speech')
        from .world_audio import ANNOUNCER_EVENTS, decode_speech, speech_index, speech_requested
        index = speech_index(announcer, 'announcer')
        (output/'speech').mkdir(parents=True, exist_ok=True)
        (output/'speech'/'announcer.json').write_text(json.dumps(index), encoding='utf-8')
        entry = {'index': 'speech/announcer.json', 'audio': None}
        if speech_requested():  # SKATE_SETUP_SPEECH=1: ~41 MB more (the crash line)
            report('Decoding announcer speech')
            decode_speech(announcer, index, output/'speech'/'announcer', work/'speech_announcer', vgmstream, _decode, log,
                          events=ANNOUNCER_EVENTS)
            entry['audio'] = 'speech/announcer'
        manifest.setdefault('speech', {})['announcer'] = entry
    (output/'audio_manifest.json').write_text(json.dumps(manifest, indent=1), encoding='utf-8')
    return manifest
