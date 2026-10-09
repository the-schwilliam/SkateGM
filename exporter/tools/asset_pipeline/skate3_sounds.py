"""Skate 3's own board sounds for Garry's Mod, from the player's game.

Writes an add-on (garrysmod/addons/skategm_s3sounds) holding:
  sound/skate3/<bank>/<n>.wav     the samples the board sounds use (44.1 kHz mono):
                                  Splice banks by sample index, AEMS banks by stream
  sound/skate3/grains/<grain>/<band>.wav   rolling: each surface's recording cut into
                                  speed bands, each a seamless loop
and garrysmod/data/skategm/skate3_sounds.json: how to play them (the Splice
patch trees of the sounds used, as retail plays them: groups layered, one
member each, with its gain, pitch ratio, delay and probability; the surface
table; the grind ids per surface; grain speed curves).

Ids and tables follow SK8-ENGINE/skate-3-rust-engine's native audio player
(crates/skate-audio/src/player, splice/format.rs). The files are EA's, from
the player's own copy of the game: they stay on their PC.
"""
import json
import os
import shutil
import struct
import subprocess
import wave
from pathlib import Path

import numpy as np

from tools.owned_game.big import BigArchive
from .audio_formats import grain, loop_bands, scan_snr, splc_streams, standalone
from .audio_export import grain_tuning, player_tuning

VERSION = 1
RATE = 44100
BANDS = 6
CROSSFADE = 0.08
LOOP_FADE = 0.12

SPLICE = ('Skate_Collisions.bnk', 'Skate_Metal.bnk', 'sk8_foley.bnk')
POP = [1097, 1098, 1099]
POP_HOLLOW = [1103, 1104, 1105]
OLLIE = 1096
LANDING = 1095
POP_ROLL = 1111
TOUCHDOWN = [
    [1051, 1052, 1053, 1054, 1055, 1056, 1057, 1058, 1059, 1060, 1061, 1127, 1050],
    [1073, 1074, 1075, 1076, 1077, 1078, 1079, 1080, 1081, 1082, 1128, 1129, 1130],
    [1062, 1063, 1064, 1065, 1066, 1067, 1068, 1069, 1070, 1071, 1131, 1132, 1072],
    [1084, 1085, 1086, 1087, 1088, 1089, 1090, 1091, 1092, 1093, 1133, 1134, 1094],
]
STEPS = list(range(76, 97))
BOARD_MATERIAL, TRUCK_MATERIAL, BODY_MATERIAL = 95, 96, 113
BODY_PARTS = {'head': 97, 'torso': 98, 'legs': 99, 'arms': 100}
ABK = {
    'GRINDS.abk': [13, 14, 20, 21, 22, 23, 54, 55, 56],
    'WHEEL_SKID_BANK.abk': list(range(96)),
    'FOOT_DRAG.abk': [36, 37, 38, 39, 44, 45, 46, 47, 60, 61, 62, 63, 64],
    'fstep_skateshoe1_sm.abk': list(range(6, 18)) + list(range(74, 85)),
    'Bodyslide.abk': list(range(16)),
    'Sk8_Air_Flip_Tricks.abk': [1, 2, 3],
    'Brd_Squeaks.abk': list(range(18)),
}
LOOPED = {'GRINDS.abk', 'FOOT_DRAG.abk', 'Bodyslide.abk'}
SKID_GROUP = 8
CHAIN_SECONDS = 3.0
CHAIN_FADE = 0.03
FE_SOUNDS = {'multiplyer_2': 'multiplier_2', 'multiplyer_3': 'multiplier_3'}
GRAINS = {1: 'asphalt_rough', 2: 'concrete_rough', 3: 'asphalt_smooth', 4: 'concrete_smooth',
          5: 'wood_ramp', 6: 'concrete_aggregate', 9: 'metal_smooth'}


def _f32(d, at):
    return struct.unpack_from('>f', d, at)[0]


def _u16(d, at):
    return struct.unpack_from('>H', d, at)[0]


def _u32(d, at):
    return struct.unpack_from('>I', d, at)[0]


def patch_tree(d):
    """An SPLC bank's records and containers (layout: skate-audio splice/format.rs)."""
    if d[:4] != b'SPLC':
        raise ValueError('not an SPLC bank')
    table, records, containers, samples = 60 + _u32(d, 8), _u32(d, 12), _u32(d, 16), _u32(d, 24)
    cbase = 60 + 36 * records
    out_containers = []
    for c in range(containers):
        at = cbase + 72 * c
        out_containers.append({'mode': d[at + 69], 'ids': [_u16(d, at + 4 + 2 * k) for k in range(min(d[at + 68], 32))]})
    cursor = cbase + 72 * containers
    out_records = []
    for r in range(records):
        at = 60 + 36 * r
        groups = []
        for _ in range(d[at + 7]):
            count, mode = d[cursor + 8], d[cursor + 9]
            cursor += 12
            members = []
            for _ in range(count):
                m = cursor
                sample = _u16(d, m)
                if sample >= samples:
                    raise ValueError(f'record {r}: sample {sample} of {samples}')
                members.append({'s': sample, 'gain': round(_f32(d, m + 4), 4), 'pitch': round(_f32(d, m + 8), 4),
                                'delay': round(_f32(d, m + 20), 4), 'gainSpread': round(_f32(d, m + 44), 4),
                                'pitchRand': round(_f32(d, m + 48), 4), 'delayRand': round(_f32(d, m + 52), 4),
                                'prob': round(_f32(d, m + 64), 4)})
                cursor += 72
            groups.append({'mode': mode, 'members': members})
        out_records.append({'gain': round(_f32(d, at + 8), 4), 'pitch': round(_f32(d, at + 12), 4),
                            'pitchRand': round(_f32(d, at + 16), 4), 'groups': groups})
    if cursor != table:
        raise ValueError(f'patch tree ends at {cursor:#x}, sample table at {table:#x}')
    return {'records': out_records, 'containers': out_containers}


def resolve(tree, wanted):
    """The records and containers a set of ids reaches."""
    records, containers = {}, {}
    count = len(tree['records'])
    todo = list(wanted)
    while todo:
        i = todo.pop()
        if i < count:
            records[i] = tree['records'][i]
        elif i - count < len(tree['containers']):
            if i not in containers:
                c = tree['containers'][i - count]
                containers[i] = c
                todo.extend(c['ids'])
        else:
            records[count - 1] = tree['records'][count - 1]
    return records, containers


def _read_wav(path):
    with wave.open(str(path)) as w:
        ch, rate, n = w.getnchannels(), w.getframerate(), w.getnframes()
        pcm = np.frombuffer(w.readframes(n), dtype='<i2').astype(np.float64)
    if ch > 1:
        pcm = pcm.reshape(-1, ch).mean(axis=1)
    return rate, pcm


def _resample(rate, x):
    if rate == RATE or len(x) < 2:
        return x
    n = max(1, int(round(len(x) * RATE / rate)))
    return np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x)


def _seamless(x):
    fade = min(len(x) // 3, int(LOOP_FADE * RATE))
    if fade < 2:
        return x
    ramp = np.linspace(0, 1, fade)
    return np.concatenate([x[:fade] * ramp + x[-fade:] * (1 - ramp), x[fade:-fade]])


def chain(grains, seconds=CHAIN_SECONDS, fade=CHAIN_FADE, seed=1):
    """A loop of whole grains back to back (as the game strings its skid
    pieces), short crossfades, never the same one twice running, levels
    evened, the end crossfaded into the start."""
    rng = np.random.default_rng(seed)
    f = int(fade * RATE)
    level = np.median([np.sqrt(np.mean(g * g)) for g in grains])
    grains = [g * (level / max(1.0, np.sqrt(np.mean(g * g)))) for g in grains if len(g) > 2 * f]
    out, last = np.zeros(0), -1
    while len(out) < seconds * RATE:
        k = int(rng.integers(len(grains)))
        if k == last and len(grains) > 1:
            continue
        last, g = k, grains[k]
        if len(out) >= f:
            ramp = np.linspace(0, 1, f)
            out[-f:] = out[-f:] * (1 - ramp) + g[:f] * ramp
            out = np.concatenate([out, g[f:]])
        else:
            out = g.copy()
    ramp = np.linspace(0, 1, f)
    return np.concatenate([out[:f] * ramp + out[-f:] * (1 - ramp), out[f:-f]])


def write_wav(path, x, loop=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = np.clip(np.round(x), -32768, 32767).astype('<i2').tobytes()
    chunks = [b'fmt ' + struct.pack('<IHHIIHH', 16, 1, 1, RATE, RATE * 2, 2, 16), b'data' + struct.pack('<I', len(pcm)) + pcm]
    if loop:
        chunks.append(b'cue ' + struct.pack('<II', 28, 1) + struct.pack('<II4sIII', 1, 0, b'data', 0, 0, 0))
    body = b''.join(chunks)
    path.write_bytes(b'RIFF' + struct.pack('<I', 4 + len(body)) + b'WAVE' + body)


def _decode(vgmstream, folder, names):
    flags = {'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {}
    for start in range(0, len(names), 256):
        batch = names[start:start + 256]
        done = subprocess.run([str(vgmstream), '-i', '-o', '?f.wav', *batch], cwd=folder,
                              capture_output=True, text=True, errors='replace', **flags)
        if done.returncode:
            raise RuntimeError(f'vgmstream failed on {folder.name}: {done.stdout[-300:]}{done.stderr[-300:]}')


def _samples(vgmstream, work, data, streams, indices):
    """Decode the streams at `indices` of a bank: {index: 44.1 kHz mono floats}."""
    work.mkdir(parents=True, exist_ok=True)
    names = []
    for i in sorted(indices):
        (work / f'{i:04d}.snr').write_bytes(standalone(data, streams[i]))
        names.append(f'{i:04d}.snr')
    _decode(vgmstream, work, names)
    out = {}
    for i in sorted(indices):
        rate, x = _read_wav(work / f'{i:04d}.snr.wav')
        out[i] = _resample(rate, x)
    return out


def tables(collections):
    pt = player_tuning(collections)
    gt = grain_tuning(collections)
    surfaces = {}
    for row in pt['surface_table']:
        surfaces[row[0] + 1] = {'grain': row[1], 'hollow': row[2], 'skid': row[3], 'grind': row[4], 'drag': row[5]}
    grinds = [{'metal': g['metal'], 'on': g['on']['ids'], 'off': g['off']['ids'], 'onGain': g['on']['gain'], 'offGain': g['off']['gain']}
              for g in pt['grind']]
    materials = pt['collision']['materials']

    def material(i):
        m = materials[i]
        return {'ids': m['ids'], 'bands': m['bands'], 'gain': m['gain'] / 32767}
    collision = {'board': material(BOARD_MATERIAL), 'truck': material(TRUCK_MATERIAL), 'body': material(BODY_MATERIAL),
                 'parts': {k: material(v) for k, v in BODY_PARTS.items()}}
    curves = {}
    for name, g in gt['surfaces'].items():
        curves[name] = {'max_kmh': g['max_kmh'], 'bezier': g['bezier']}
    return pt, surfaces, grinds, collision, curves


def _field(record, key):
    return record['fields'].get(key, {}).get('data')


def mix(tree, record_id, samples):
    """One playing of a record: each group's first member, at its gain, pitch and delay."""
    count = len(tree['records'])
    if record_id >= count:
        record_id = tree['containers'][record_id - count]['ids'][0]
    rec = tree['records'][record_id]
    parts = []
    for group in rec['groups']:
        m = group['members'][0]
        x = samples[m['s']]
        ratio = m['pitch'] * rec['pitch']
        if ratio > 0 and abs(ratio - 1) > 1e-3:
            x = np.interp(np.arange(0, len(x) - 1, ratio), np.arange(len(x)), x)
        parts.append((int(m['delay'] * RATE), x * m['gain'] * rec['gain']))
    length = max((d + len(x) for d, x in parts), default=0)
    out = np.zeros(length)
    for d, x in parts:
        out[d:d + len(x)] += x
    return out


def frontend(files, by_name, collections, vgmstream, work, out, report):
    """The trick display's multiplier sounds (class fe records, sk8_menu.bnk)."""
    entry = by_name.get('sk8_menu.bnk')
    if entry is None:
        return 0
    data = files.read(entry)
    tree = patch_tree(data)
    fe = {_field(r, 'Hash_942AB8AEE4B414ED') or r['key']: r for r in collections if r['class'] == 'fe'}
    plans = {}
    for name, saved in FE_SOUNDS.items():
        record = fe.get(name)
        if not record:
            continue
        sid = int(_field(record, 'Hash_8FCC7EF9B9208858'), 16)
        level = struct.unpack('>f', bytes.fromhex(_field(record, 'Hash_875BA75341DC8391') or '3F800000'))[0]
        plans[saved] = (sid, level)
    used = set()
    for sid, _ in plans.values():
        records, _ = resolve(tree, [sid])
        used |= {m['s'] for rec in records.values() for g in rec['groups'] for m in g['members']}
    samples = _samples(vgmstream, work / 'sk8_menu', data, splc_streams(data), used)
    out.mkdir(parents=True, exist_ok=True)
    for saved, (sid, level) in plans.items():
        x = mix(tree, sid, samples)
        fade = min(len(x), int(0.3 * RATE))
        if fade:
            x[-fade:] *= np.linspace(1, 0, fade)
        peak = np.abs(x).max() if len(x) else 0
        if peak > 32767:
            x = x * (32767 / peak)
        write_wav(out / f'{saved}.wav', x)
        (out / f'{saved}.txt').write_text(f'{level}\n', encoding='utf-8')
    report(f"Skate 3 trick display sounds: {len(plans)}")
    return len(plans)


DRAG_SURFACES = 5
DRAG_SPEED = 5000
RENDER_SECONDS = 6


def drag_words(surface, speed):
    return [32767, 32767, 0, 0, 4096, 25000, 0, speed, surface, 4000, 4500, 4000, 22500, 0, 7]


def render_loops(files, by_name, aems_render, vgmstream, work, root, report):
    """The foot-brake loops, rendered through Skate 3's own sound engine
    (skate-audio's aems_render: the .csi projects and .abk banks with their
    decoded samples), the first second (the attack) left out, made seamless."""
    folder = work / 'aems'
    folder.mkdir(parents=True, exist_ok=True)
    order = [Path(e.path).name for e in files.entries if e.path.lower().endswith('.csi')]
    (folder / 'csi_order.txt').write_text(''.join(n + '\n' for n in order), encoding='utf-8')
    for e in files.entries:
        name = Path(e.path).name
        if name.lower().endswith(('.abk', '.csi')):
            (folder / name).write_bytes(files.read(e))
    for stem in ('emitter_utility', 'FOOT_DRAG'):
        data = (folder / f'{stem}.abk').read_bytes()
        streams = scan_snr(data)
        banks = folder / 'audio' / 'banks' / stem
        banks.mkdir(parents=True, exist_ok=True)
        names = []
        for i, st in enumerate(streams):
            (banks / f'{i:04d}.snr').write_bytes(standalone(data, st))
            names.append(f'{i:04d}.snr')
        if names:
            _decode(vgmstream, banks, names)
            for i in range(len(names)):
                (banks / f'{i:04d}.snr.wav').replace(banks / f'{i:04d}.wav')
    flags = {'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {}
    made = 0
    for surface in range(DRAG_SURFACES):
        out = folder / f'drag_{surface}.wav'
        done = subprocess.run([str(aems_render), str(folder), str(folder / 'audio'), 'FOOT_DRAG', 'Class_foot_drag',
                               ','.join(map(str, drag_words(surface, DRAG_SPEED))), str(RENDER_SECONDS), str(out)],
                              capture_output=True, text=True, errors='replace', **flags)
        if done.returncode or not out.is_file():
            continue
        rate, x = _read_wav(out)
        x = _resample(rate, x[rate:])
        if len(x) < RATE or np.abs(x).max() < 30:
            continue
        write_wav(root / 'loops' / f'drag_{surface}.wav', _seamless(x), True)
        made += 1
    report(f'Skate 3 brake loops: {made}')
    return made


def installed(gmod):
    """True when this builder's sounds are already in garrysmod (same VERSION)."""
    gmod = Path(gmod)
    try:
        manifest = json.loads((gmod / 'garrysmod' / 'data' / 'skategm' / 'skate3_sounds.json').read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return False
    sounds = gmod / 'garrysmod' / 'addons' / 'skategm_s3sounds' / 'sound' / 'skate3'
    return manifest.get('version') == VERSION and sounds.is_dir() and next(sounds.rglob('*.wav'), None) is not None


def build(game_root, collections_path, gmod, vgmstream, work, report=print, aems_render=None):
    """Decode the sounds into garrysmod/addons/skategm_s3sounds; return the manifest."""
    game_root, gmod, work = Path(game_root), Path(gmod), Path(work)
    collections = json.loads(Path(collections_path).read_text(encoding='utf-8'))['collections']
    pt, surfaces, grinds, collision, curves = tables(collections)
    addon = gmod / 'garrysmod' / 'addons' / 'skategm_s3sounds'
    stage = addon.with_name(addon.name + '.partial')
    shutil.rmtree(stage, ignore_errors=True)
    root = stage / 'sound' / 'skate3'
    root.mkdir(parents=True)
    (stage / 'addon.json').write_text(json.dumps({'title': 'SkateGM - Skate 3 sounds (from your game)', 'type': 'effects', 'tags': []}),
                                      encoding='utf-8')
    files = BigArchive(game_root / 'data/audio/audiofiles.big')
    by_name = {Path(e.path).name.lower(): e for e in files.entries}
    wanted = {
        'Skate_Collisions': set(POP + POP_HOLLOW + [OLLIE, LANDING, POP_ROLL] + [i for row in TOUCHDOWN for i in row]),
        'Skate_Metal': set(),
        'sk8_foley': set(STEPS),
    }
    for g in grinds:
        wanted['Skate_Metal' if g['metal'] else 'Skate_Collisions'].update(g['on'] + g['off'])
    for m in [collision['board'], collision['truck'], collision['body'], *collision['parts'].values()]:
        wanted['Skate_Collisions'].update(i for i in m['ids'] if i)
    banks = {}
    report('Decoding Skate 3 board sounds')
    for bank in SPLICE:
        stem = Path(bank).stem
        data = files.read(by_name[bank.lower()])
        tree = patch_tree(data)
        records, containers = resolve(tree, wanted[stem])
        used = {m['s'] for r in records.values() for g in r['groups'] for m in g['members']}
        decoded = _samples(vgmstream, work / stem, data, splc_streams(data), used)
        for i, x in decoded.items():
            write_wav(root / stem / f'{i}.wav', x)
        banks[stem] = {'count': len(tree['records']), 'records': {str(k): v for k, v in sorted(records.items())},
                       'containers': {str(k): v for k, v in sorted(containers.items())}}
    abk = {}
    for bank, picks in ABK.items():
        stem = Path(bank).stem
        entry = by_name.get(bank.lower())
        if entry is None:
            continue
        data = files.read(entry)
        streams = scan_snr(data)
        picks = [i for i in picks if i < len(streams)]
        decoded = _samples(vgmstream, work / stem, data, streams, picks)
        for i, x in decoded.items():
            loop = bank in LOOPED
            if bank == 'WHEEL_SKID_BANK.abk':
                continue
            write_wav(root / stem / f'{i}.wav', _seamless(x) if loop else x, loop)
        if bank == 'WHEEL_SKID_BANK.abk':
            for group in range(len(picks) // SKID_GROUP):
                grains = [decoded[i] for i in picks[group * SKID_GROUP:(group + 1) * SKID_GROUP]]
                write_wav(root / 'loops' / f'skid_{group}.wav', chain(grains), True)
            continue
        abk[stem] = picks
    try:
        frontend(files, by_name, collections, vgmstream, work, gmod / 'garrysmod' / 'data' / 'skategm_hud' / 'sound', report)
    except Exception as error:
        report("Skate 3 trick display sounds were skipped: " + (str(error) or type(error).__name__))
    loops = 0
    if aems_render and Path(aems_render).is_file():
        try:
            loops = render_loops(files, by_name, aems_render, vgmstream, work, root, report)
        except Exception as error:
            report('Skate 3 brake loops were skipped: ' + (str(error) or type(error).__name__))
    report('Decoding Skate 3 rolling sounds')
    archive = BigArchive(game_root / 'data/audio/grains.big')
    rolled = {}
    gwork = work / 'grains'
    gwork.mkdir(parents=True, exist_ok=True)
    names = []
    for entry in archive.entries:
        if not entry.path.endswith('.grain'):
            continue
        stem = Path(entry.path).stem
        data = archive.read(entry)
        (gwork / f'{stem}.snr').write_bytes(standalone(data, grain(data).stream))
        names.append(stem)
    _decode(vgmstream, gwork, [f'{s}.snr' for s in names])
    for stem in names:
        rate, x = _read_wav(gwork / f'{stem}.snr.wav')
        pcm = np.clip(np.round(x), -32768, 32767).astype('<i2').tobytes()
        for i, band in enumerate(loop_bands(pcm, BANDS, round(CROSSFADE * rate))):
            y = _resample(rate, np.frombuffer(band, dtype='<i2').astype(np.float64))
            write_wav(root / 'grains' / stem / f'{i}.wav', y, True)
        rolled[stem] = curves.get(stem)
    manifest = {'version': VERSION, 'banks': banks, 'abk': abk, 'grains': rolled, 'grainNames': GRAINS,
                'surfaces': surfaces, 'grinds': grinds, 'collision': collision,
                'pop': POP, 'popHollow': POP_HOLLOW, 'ollie': OLLIE, 'landing': LANDING, 'popRoll': POP_ROLL,
                'touchdown': TOUCHDOWN, 'jump': pt['jump_thresholds'], 'dragLoops': loops}
    shutil.rmtree(addon, ignore_errors=True)
    stage.rename(addon)
    data_dir = gmod / 'garrysmod' / 'data' / 'skategm'
    data_dir.mkdir(parents=True, exist_ok=True)
    (data_dir / 'skate3_sounds.json').write_text(json.dumps(manifest), encoding='utf-8')
    count = sum(1 for _ in (addon / 'sound').rglob('*.wav'))
    report(f'Skate 3 board sounds: {count} files')
    return manifest
