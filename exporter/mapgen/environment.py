import json
import os
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import EXPORTER, UTT

DB_FILES = {'skaterschema.bin', 'skaterschema.vlt', 'skatercollections.bin', 'skatercollections.vlt'}


@dataclass
class Sky:
    sun: np.ndarray
    fog_near: float
    fog_far: float
    fog_colour: tuple
    fog_max: float
    positions: np.ndarray
    uvs: np.ndarray
    faces: np.ndarray
    texture: np.ndarray


def _imports():
    for path in (EXPORTER, UTT):
        if str(path) not in sys.path:
            sys.path.insert(0, str(path))


def _collections(source, work):
    from tools.owned_game.big import BigArchive
    from tools.asset_pipeline.vlt import convert as convert_vlt
    from tools.asset_pipeline.environment import NAMES, Collections
    db = BigArchive(source.file('data/big/db.big'))
    out = Path(work) / 'db'
    if not (out / 'data/db/skatercollections.vlt').is_file():
        db.extract_entries([e for e in db.entries if Path(e.path).name.lower() in DB_FILES], out, overwrite=True)
    stem = out / 'data/db'
    names = (EXPORTER / 'tools/asset_pipeline/names.txt').read_text(encoding='utf-8').splitlines()
    return Collections(convert_vlt(stem / 'skaterschema', stem / 'skatercollections', [*names, *NAMES]))


def _world_row(collections, district):
    from tools.asset_pipeline.environment import key_hash
    for (cls, _), row in collections.rows.items():
        if cls != key_hash('world'):
            continue
        stream = next((v['data'] for k, v in row['fields'].items() if key_hash(k) == key_hash('WorldStream')), None)
        if stream == district:
            return row
    return None


def load(source, district, work):
    _imports()
    from tools.owned_game.big import BigArchive
    from tools.asset_pipeline.environment import world_environment
    from tools.asset_pipeline.sky import _material, _texture
    import mdl_parser
    import rx2_parser
    collections = _collections(source, work)
    row = _world_row(collections, district)
    if row is None:
        return None
    env = world_environment(collections, row['key'])
    misc = BigArchive(source.file('data/big/miscload.big'))
    entries = {e.path: e for e in misc.entries}
    raw = misc.read(entries['data/content/' + env['sky_model'] + '.rx2'])
    model = mdl_parser.parse_rx2(raw)
    table = rx2_parser.RX2File(raw)
    table.parse()
    channels = _material(raw, table)
    textures = rx2_parser.parse_rx2(misc.read(entries['data/content/' + env['sky_textures'] + '.rx2']))
    diffuse = _texture(textures, channels['diffuse'])
    mesh = model.meshes[0]
    fog = env['fog']
    return Sky(np.asarray(env['sun_direction'], np.float64), float(fog['fog_near'][0]), float(fog['fog_far'][0]),
               tuple(float(c) for c in fog['fog_colour'][:3]), float(fog['fog_max'][0]),
               np.asarray(mesh.vertices, np.float64), np.asarray(mesh.uvs, np.float64),
               np.asarray(mesh.faces, np.int64).reshape(-1, 3),
               np.frombuffer(diffuse.rgba, np.uint8).reshape(diffuse.height, diffuse.width, 4).copy())


WATER_FIELD = 'Hash_951898F6C0FA6856'
WATER_SHADE = 0.8
WATER_TILE = 16


def _channel_sets(raw, table):
    out = []
    for section in table.entries:
        if section.type_id != 0x00eb0005:
            continue
        o = section.f0
        h = struct.unpack_from('>8I', raw, o)
        channels = {}
        for i in range(h[1]):
            v = struct.unpack_from('>8I', raw, o + h[3] + i * 32)
            at = o + v[0]
            channels[raw[at:raw.index(b'\0', at)].decode('ascii')] = (v[4] << 32) | v[5]
        out.append(channels)
    return out


def water(source, district, work):
    _imports()
    from tools.owned_game.big import BigArchive
    from tools.asset_pipeline.sky import _texture
    import mdl_parser
    import rx2_parser
    from .scene import Material, Mesh, Texture
    row = _world_row(_collections(source, work), district)
    if row is None or WATER_FIELD not in row['fields']:
        return None
    path = 'data/content/' + row['fields'][WATER_FIELD]['data']
    misc = BigArchive(source.file('data/big/miscload.big'))
    entries = {e.path: e for e in misc.entries}
    if path + '.rx2' not in entries or path + '_Textures.rx2' not in entries:
        return None
    raw = misc.read(entries[path + '.rx2'])
    table = rx2_parser.RX2File(raw)
    table.parse()
    sea = next((c for c in _channel_sets(raw, table) if 'environment' in c), None)
    if sea is None:
        return None
    reflection = _texture(rx2_parser.parse_rx2(misc.read(entries[path + '_Textures.rx2'])), sea['environment'])
    pixels = np.frombuffer(bytes(reflection.rgba), np.uint8).reshape(-1, 4)[:, :3]
    colour = np.clip(np.round(pixels.mean(0) * WATER_SHADE), 0, 255).astype(np.uint8)
    texture_id = f'0x{sea["environment"]:016x}'
    out = Path(work) / f'water_{texture_id}.rgba'
    out.parent.mkdir(parents=True, exist_ok=True)
    tile = np.empty((WATER_TILE, WATER_TILE, 4), np.uint8)
    tile[..., :3], tile[..., 3] = colour, 255
    part = out.with_name(f'{out.name}.{os.getpid()}.part')
    part.write_bytes(tile.tobytes())
    os.replace(part, out)
    meshes = []
    for mesh in mdl_parser.parse_rx2(raw).meshes:
        positions = np.asarray(mesh.vertices, np.float32)
        if not len(positions) or mesh.uvs is None or float(np.ptp(positions[:, 1])) > 0.01:
            continue
        faces = np.asarray(mesh.faces, np.int64).reshape(-1, 3)
        normals = np.tile(np.array([0.0, 1.0, 0.0], np.float32), (len(positions), 1))
        meshes.append(Mesh('water', positions, faces, np.asarray(mesh.uvs, np.float32), normals, name='water'))
    if not meshes:
        return None
    return (Texture(texture_id, out, WATER_TILE, WATER_TILE, 'rgba'),
            Material('water', 'water', 'unlit', {'diffuse': texture_id}), meshes)


SEA_COLOUR = (52, 92, 128)
WATER_UP = 0.9
WATER_BAND = 1.0


def _water_model(source, district, work):
    _imports()
    from tools.owned_game.big import BigArchive
    row = _world_row(_collections(source, work), district)
    if row is None or WATER_FIELD not in row['fields']:
        return None, None
    path = 'data/content/' + row['fields'][WATER_FIELD]['data']
    misc = BigArchive(source.file('data/big/miscload.big'))
    entries = {e.path: e for e in misc.entries}
    if path + '.rx2' not in entries:
        return None, None
    return misc.read(entries[path + '.rx2']), path


def water_surfaces(source, district, work):
    raw, _ = _water_model(source, district, work)
    import mdl_parser
    if raw is None:
        return np.zeros((0, 3, 3)), SEA_COLOUR
    found = water(source, district, work)
    colour = tuple(int(c) for c in found[0].rgba()[0, 0, :3]) if found else SEA_COLOUR
    tris = []
    for mesh in mdl_parser.parse_rx2(raw).meshes:
        positions = np.asarray(mesh.vertices, np.float64)
        if not len(positions):
            continue
        flat = float(np.ptp(positions[:, 1])) <= 0.01
        reflective = 'refl' in (mesh.material_name or '').lower()
        if not (flat or reflective):
            continue
        t = positions[np.asarray(mesh.faces, np.int64).reshape(-1, 3)]
        n = np.cross(t[:, 1] - t[:, 0], t[:, 2] - t[:, 0])
        length = np.sqrt((n * n).sum(1))
        up = np.abs(n[:, 1]) > WATER_UP * np.maximum(length, 1e-12)
        tris.append(t[up & (length > 1e-6)])
    if not tris:
        return np.zeros((0, 3, 3)), colour
    t = np.concatenate(tris)
    n = np.cross(t[:, 1] - t[:, 0], t[:, 2] - t[:, 0])
    area = np.sqrt((n * n).sum(1))
    level = np.round(t[:, :, 1].mean(1))
    heights, inverse = np.unique(level, return_inverse=True)
    sums = np.zeros(len(heights))
    np.add.at(sums, inverse.reshape(-1), area)
    sea = heights[int(sums.argmax())]
    return t[np.abs(t[:, :, 1].mean(1) - sea) <= WATER_BAND], colour


def sea(source, district, work):
    t, colour = water_surfaces(source, district, work)
    if not len(t):
        return None
    n = np.cross(t[:, 1] - t[:, 0], t[:, 2] - t[:, 0])
    area = np.sqrt((n * n).sum(1))
    height = float(round((t[:, :, 1].mean(1) * area).sum() / max(area.sum(), 1e-9), 2))
    return height, colour


def sea_plane(height, colour, centre, reach, work, steps=8):
    from .scene import Material, Mesh, Texture
    texture_id = 'sea_%02x%02x%02x' % tuple(colour)
    out = Path(work) / f'{texture_id}.rgba'
    out.parent.mkdir(parents=True, exist_ok=True)
    tile = np.empty((WATER_TILE, WATER_TILE, 4), np.uint8)
    tile[..., :3], tile[..., 3] = colour, 255
    part = out.with_name(f'{out.name}.{os.getpid()}.part')
    part.write_bytes(tile.tobytes())
    os.replace(part, out)
    xs = np.linspace(centre[0] - reach, centre[0] + reach, steps + 1)
    zs = np.linspace(centre[1] - reach, centre[1] + reach, steps + 1)
    gx, gz = np.meshgrid(xs, zs, indexing='ij')
    positions = np.stack([gx.ravel(), np.full(gx.size, height), gz.ravel()], 1).astype(np.float32)
    uvs = np.stack([gx.ravel(), gz.ravel()], 1).astype(np.float32) / 100.0
    k = (steps + 1)
    faces = []
    for i in range(steps):
        for j in range(steps):
            a, b, c, d = i * k + j, (i + 1) * k + j, (i + 1) * k + j + 1, i * k + j + 1
            faces += [(a, c, b), (a, d, c)]
    normals = np.tile(np.array([0.0, 1.0, 0.0], np.float32), (len(positions), 1))
    mesh = Mesh('water', positions, np.asarray(faces, np.int64), uvs, normals, name='water')
    return (Texture(texture_id, out, WATER_TILE, WATER_TILE, 'rgba'),
            Material('water', 'water', 'unlit', {'diffuse': texture_id}), [mesh])
