import json
import os
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .mathutil import norm

from . import MAP_TOOLS

CHANNELS = ('diffuse', 'normal', 'specular', 'lightmap', 'detail', 'transparent', 'decal')


@dataclass
class Texture:
    id: str
    path: Path
    width: int
    height: int
    format: str

    def rgba(self):
        data = np.frombuffer(self.path.read_bytes(), np.uint8)
        return data[:self.width * self.height * 4].reshape(self.height, self.width, 4)


@dataclass
class Material:
    key: str
    name: str
    shader: str
    textures: dict
    alpha_mode: int = 0
    alpha_cutoff: float = 0.5


@dataclass
class Mesh:
    material: str
    positions: np.ndarray
    faces: np.ndarray
    uvs: np.ndarray
    normals: np.ndarray
    lightmap_uvs: np.ndarray = None
    name: str = ''
    decal_uvs: np.ndarray = None
    scenery: bool = False


# A collision triangle's "surface" (uint64): the retail surface ID in the low
# 32 bits; bits 32-55 its three native edge codes, bit 56 set when it has
# them, bit 57 when its mesh is one-sided (gm_sk8: carried into SK3C 3 so
# SkateGM's engine gets the edges a .skate package's RWCM gave it)
EDGES_SHIFT = 32
HAS_EDGES = 1 << 56
ONE_SIDED = 1 << 57
SURFACE_MASK = 0xFFFFFFFF


def pack_surface(surface, edge_codes, one_sided):
    v = int(surface) & SURFACE_MASK
    if edge_codes is not None:
        e = [int(c) & 0xFF for c in edge_codes]
        v |= (e[0] | e[1] << 8 | e[2] << 16) << EDGES_SHIFT | HAS_EDGES
    if one_sided:
        v |= ONE_SIDED
    return v


@dataclass
class Collision:
    triangles: np.ndarray
    surfaces: np.ndarray

    @staticmethod
    def empty():
        return Collision(np.zeros((0, 3, 3), np.float32), np.zeros(0, np.uint64))


@dataclass
class Rail:
    points: np.ndarray
    closed: bool = False
    # the retail spline as a .skate package stores it (map_writer.py): spline
    # id, type signature, flags, trailing word, segment count, then each
    # segment's 30 words, little endian, in Skate 3's own coordinates
    native: bytes | None = None


@dataclass
class Scene:
    root: Path
    district: str
    textures: dict = field(default_factory=dict)
    materials: dict = field(default_factory=dict)
    meshes: list = field(default_factory=list)
    collision: Collision = field(default_factory=Collision.empty)
    rails: list = field(default_factory=list)

    def bounds(self):
        points = [m.positions for m in self.meshes] + [self.collision.triangles.reshape(-1, 3)]
        points = np.concatenate([p for p in points if len(p)])
        return points.min(0), points.max(0)


def _material_key(mesh):
    ids = mesh.get('retail_texture_ids') or {}
    parts = [mesh.get('shader_name') or '', str(mesh.get('alpha_mode', 0))]
    parts += [f'{c}={ids[c]}' for c in CHANNELS if ids.get(c)]
    if not ids.get('diffuse') and mesh.get('texture_id'):
        parts.append('diffuse=' + mesh['texture_id'])
    return '|'.join(parts)


def _textures(root, manifest):
    out = {}
    for tid, entry in manifest['textures'].items():
        if not entry.get('rgba') or entry.get('cube_faces', 1) != 1:
            continue
        path = root / entry['rgba']
        if path.is_file():
            out[tid.lower()] = Texture(tid.lower(), path, entry['width'], entry['height'], entry.get('format', ''))
    return out


def resolve_texture(tid, textures):
    if not tid:
        return None
    tid = tid.lower()
    if tid in textures:
        return tid
    try:
        flagged = f'0x{int(tid, 16) | (1 << 63):016x}'
    except ValueError:
        return None
    return flagged if flagged in textures else None


def material_for(entry, textures, materials):
    key = _material_key(entry)
    if key not in materials:
        ids = {c: (v or '').lower() for c, v in (entry.get('retail_texture_ids') or {}).items()}
        if not ids.get('diffuse') and entry.get('texture_id'):
            ids['diffuse'] = entry['texture_id'].lower()
        resolved = {c: resolve_texture(t, textures) for c, t in ids.items()}
        materials[key] = Material(key, entry.get('material_name') or 'material', entry.get('shader_name') or '',
                                  {c: t for c, t in resolved.items() if t},
                                  int(entry.get('alpha_mode') or 0), float(entry.get('alpha_cutoff') or 0.5))
    return key


def mesh_from(entry, arrays, key):
    i = entry['index']
    if f'vertices_{i}' not in arrays:
        return None
    lm = arrays[f'lightmap_uvs_{i}'] if f'lightmap_uvs_{i}' in arrays else None
    decal = arrays[f'decal_uvs_{i}'] if f'decal_uvs_{i}' in arrays else None
    return Mesh(key, np.asarray(arrays[f'vertices_{i}'], np.float32), np.asarray(arrays[f'faces_{i}'], np.int64),
                np.asarray(arrays[f'uvs_{i}'], np.float32), np.asarray(arrays[f'normals_{i}'], np.float32),
                None if lm is None else np.asarray(lm, np.float32), entry.get('name', ''),
                None if decal is None else np.asarray(decal, np.float32))


def _materials_and_meshes(root, manifest, textures):
    materials, meshes = {}, []
    for model in manifest['models']:
        npz = np.load(root / model['npz'])
        arrays = {k: npz[k] for k in npz.files}
        for entry in model['meshes']:
            mesh = mesh_from(entry, arrays, material_for(entry, textures, materials))
            if mesh is not None:
                meshes.append(mesh)
    return materials, meshes


def _decode_vertices_fixed(cluster, vertex_count, compression, granularity, vertex_data_end):
    import retail_collision_mesh as rcm
    if compression != 1:
        return _decode_vertices_fixed.original(cluster, vertex_count, compression, granularity, vertex_data_end)
    base = struct.unpack_from('>3i', cluster, rcm.CLUSTER_HEADER_SIZE)
    out = []
    for index in range(vertex_count):
        offset = rcm.CLUSTER_HEADER_SIZE + 12 + index * 6
        if offset + 6 > vertex_data_end:
            raise ValueError('16-bit compressed vertex extends into the unit stream')
        delta = struct.unpack_from('>3H', cluster, offset)
        out.append(tuple(rcm._f32(max(-2 ** 31, min(2 ** 31 - 1, base[a] + delta[a])) * granularity) for a in range(3)))
    return out


def _collision_module():
    if str(MAP_TOOLS) not in sys.path:
        sys.path.insert(0, str(MAP_TOOLS))
    import retail_collision_mesh as rcm
    if not hasattr(_decode_vertices_fixed, 'original'):
        _decode_vertices_fixed.original = rcm._decode_vertices
        rcm._decode_vertices = _decode_vertices_fixed
    return rcm


COLLISION_CACHE = 'mapgen_collision_v2.npz'


def _collision(root, manifest):
    cached = root / COLLISION_CACHE
    if cached.is_file():
        data = np.load(cached)
        return Collision(data['triangles'], data['surfaces'])
    collision = _decode_collision(root, manifest)
    part = cached.with_name(f'{cached.stem}.{os.getpid()}.part.npz')
    np.savez(part, triangles=collision.triangles, surfaces=collision.surfaces)
    os.replace(part, cached)
    return collision


def _decode_collision(root, manifest):
    rcm = _collision_module()
    tris, surfaces = [], []
    for asset in manifest.get('simulation_assets', []):
        if not asset.get('collision_meshes') or not asset.get('rx2'):
            continue
        path = root / asset['rx2']
        if not path.is_file():
            continue
        for mesh in rcm.decode_rx2_clustered_meshes(path.read_bytes()):
            one_sided = bool(mesh.mesh_flags & 0x10)
            for t in mesh.triangles:
                tris.append((t.a, t.b, t.c))
                surfaces.append(pack_surface(t.surface, t.edge_codes, one_sided))
    if not tris:
        return Collision.empty()
    return Collision(np.asarray(tris, np.float32), np.asarray(surfaces, np.uint64))


def _segment_points(payload, steps):
    f = struct.unpack('>30f', payload)
    a, b, c, d = (np.array(f[k:k + 3]) for k in (0, 4, 8, 12))
    t = np.linspace(0.0, 1.0, steps + 1)[:, None]
    return ((a * t + b) * t + c) * t + d


def _rails(manifest):
    rails = []
    for rail in manifest.get('grind_splines', []):
        pieces = []
        payloads = [bytes.fromhex(h) for h in rail.get('native_segment_payloads', [])]
        native = None
        if payloads and all(len(p) == 120 for p in payloads):
            try:
                native = struct.pack('<QQIII', int(rail['spline_id'], 0), int(rail['type_signature'], 0),
                                     int(rail['flags']), int(rail['trailing_word']), len(payloads))
                native += b''.join(np.frombuffer(p, '>u4').astype('<u4').tobytes() for p in payloads)
            except (KeyError, ValueError, TypeError):
                native = None
        for payload in payloads:
            if len(payload) < 120:
                continue
            coarse = _segment_points(payload, 1)
            length = float(norm(coarse[1] - coarse[0]))
            steps = int(np.clip(np.ceil(length / 0.5), 1, 64))
            points = _segment_points(payload, steps)
            pieces.append(points if not pieces else points[1:])
        if pieces:
            points = np.concatenate(pieces).astype(np.float32)
            if np.all(np.isfinite(points)) and len(points) >= 2:
                rails.append(Rail(points, bool(rail.get('closed')), native))
    return rails


def load(root, collision=True, fallback_textures=None):
    root = Path(root)
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
    scene = Scene(root, manifest.get('district_name', ''))
    scene.textures = dict(fallback_textures or {})
    scene.textures.update(_textures(root, manifest))
    scene.materials, scene.meshes = _materials_and_meshes(root, manifest, scene.textures)
    if collision:
        scene.collision = _collision(root, manifest)
    scene.rails = _rails(manifest)
    return scene
