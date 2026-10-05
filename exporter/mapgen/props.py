import json
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from . import EXPORTER, MAP_TOOLS
from .coords import UNITS_PER_METRE
from .scene import Texture, material_for, mesh_from

DENSITY = 150.0
MIN_MASS, MAX_MASS = 5.0, 1500.0


@dataclass
class Template:
    key: str
    meshes: list
    size: np.ndarray = None


@dataclass
class Instance:
    template: str
    name: str
    matrix: np.ndarray


@dataclass
class Props:
    templates: dict = field(default_factory=dict)
    instances: list = field(default_factory=list)
    materials: dict = field(default_factory=dict)
    textures: dict = field(default_factory=dict)


def _imports():
    for path in (EXPORTER, MAP_TOOLS):
        if str(path) not in sys.path:
            sys.path.insert(0, str(path))


def catalog(source, work, report=print):
    _imports()
    from tools.asset_pipeline import dynamic_props
    work = Path(work)
    path = work / 'catalog.json'
    if not path.is_file():
        report('reading the movable objects')
        archive = source.file('data/content/worlddmo.big')
        game_root = Path(str(archive)).parents[2]
        dynamic_props.prepare_catalog(game_root, work)
    return dynamic_props.load_catalog(path)


def placements(scene_root, area):
    _imports()
    from tools.asset_pipeline import dynamic_props
    manifest = json.loads((Path(scene_root) / 'manifest.json').read_text(encoding='utf-8'))
    found = {}
    for asset in manifest.get('simulation_assets', []):
        path = Path(scene_root) / asset['rx2']
        if not path.is_file():
            continue
        for item in dynamic_props.locators(path.read_bytes()):
            found[item['instance_id']] = item
    out = []
    for key in sorted(found):
        item = found[key]
        position = np.asarray(item['matrix'], np.float64)[3, :3]
        if area.contains(position[None])[0]:
            out.append(item)
    return out


def load(source, scene_root, area, work, report=print):
    templates, textures = catalog(source, work, report)
    props = Props()
    for tid, entry in textures.items():
        path = Path(entry.get('rgba', ''))
        if path.is_file() and entry.get('cube_faces', 1) == 1:
            props.textures[tid.lower()] = Texture(tid.lower(), path, entry['width'], entry['height'], entry.get('format', ''))
    for item in placements(scene_root, area):
        template = templates.get(item['template_id'])
        if template is None:
            continue
        key = item['template_id']
        if key not in props.templates:
            local = np.asarray(template['model_matrix'], np.float64) @ np.asarray(template['matrix'], np.float64)
            npz = np.load(template['npz'])
            arrays = {k: npz[k] for k in npz.files}
            meshes = []
            for entry in template['meshes']:
                mesh = mesh_from(entry, arrays, material_for(entry, props.textures, props.materials))
                if mesh is None:
                    continue
                mesh.positions = (mesh.positions.astype(np.float64) @ local[:3, :3] + local[3, :3]).astype(np.float32)
                mesh.normals = (mesh.normals.astype(np.float64) @ local[:3, :3]).astype(np.float32)
                mesh.lightmap_uvs = None
                meshes.append(mesh)
            if not meshes:
                continue
            allp = np.concatenate([m.positions for m in meshes])
            props.templates[key] = Template(key, meshes, allp.max(0) - allp.min(0))
        props.instances.append(Instance(key, item['name'], np.asarray(item['matrix'], np.float64)))
    return props


def source_rotation(matrix):
    r = matrix[:3, :3].T
    a = np.array([[1.0, 0.0, 0.0], [0.0, 0.0, -1.0], [0.0, 1.0, 0.0]])
    m = np.zeros((3, 3))
    for i in range(3):
        for j in range(3):
            m[i, j] = sum(a[i, k] * sum(r[k, l] * a[j, l] for l in range(3)) for k in range(3))
    for j in range(3):
        length = math.sqrt(m[0, j] ** 2 + m[1, j] ** 2 + m[2, j] ** 2)
        if length > 1e-9:
            m[:, j] /= length
    return m


STUDIOMDL_TURN = np.array([[0.0, 1.0, 0.0], [-1.0, 0.0, 0.0], [0.0, 0.0, 1.0]])


def placed_rotation(matrix):
    m = source_rotation(matrix)
    out = np.zeros((3, 3))
    for i in range(3):
        for j in range(3):
            out[i, j] = sum(m[i, k] * STUDIOMDL_TURN[k, j] for k in range(3))
    return out


def angles(m):
    forward, left, up = m[:, 0], m[:, 1], m[:, 2]
    xy = math.hypot(forward[0], forward[1])
    if xy > 0.001:
        yaw = math.degrees(math.atan2(forward[1], forward[0]))
        pitch = math.degrees(math.atan2(-forward[2], xy))
        roll = math.degrees(math.atan2(left[2], up[2]))
    else:
        yaw = math.degrees(math.atan2(-left[0], left[1]))
        pitch = math.degrees(math.atan2(-forward[2], xy))
        roll = 0.0
    return round(pitch, 2), round(yaw, 2), round(roll, 2)


def mass(template):
    size = np.maximum(template.size, 0.05)
    return float(round(min(MAX_MASS, max(MIN_MASS, float(size[0] * size[1] * size[2]) * DENSITY)), 1))


def origin(instance, frame):
    return np.round(frame.point(instance.matrix[3, :3][None])[0], 2)


def local_frame():
    from .coords import Frame
    return Frame((0.0, 0.0, 0.0), UNITS_PER_METRE)
