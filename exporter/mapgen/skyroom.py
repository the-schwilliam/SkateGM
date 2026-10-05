from dataclasses import dataclass

import numpy as np

from . import clip, surfaces
from .scene import Scene

SCALE = 16
GAP = 256.0
MARGIN = 128.0
TOP = 15800.0
BUDGET = 24 * 1024 * 1024
PAGE = 256


class ScaledFrame:
    def __init__(self, frame, origin, scale=SCALE):
        self.frame = frame
        self.origin = np.asarray(origin, np.float64)
        self.scale = scale

    def point(self, points):
        return self.frame.point(points) / self.scale + self.origin

    def direction(self, vectors):
        return self.frame.direction(vectors)


@dataclass
class SkyRoom:
    surfaces: surfaces.Surfaces
    origin: np.ndarray
    lo: np.ndarray
    hi: np.ndarray


WHOLE = 'water'


def backdrop(scene, exclude):
    kept = [m for m in scene.meshes if m.name == WHOLE]
    cut = Scene(scene.root, scene.district, scene.textures, scene.materials,
                [m for m in scene.meshes if m.name != WHOLE])
    meshes = clip.ring(cut, clip.Area(), exclude) + kept
    used = {m.material for m in meshes}
    return Scene(scene.root, scene.district, scene.textures, {k: v for k, v in scene.materials.items() if k in used}, meshes)


def place(scene, frame, main_top):
    points = np.concatenate([m.positions for m in scene.meshes])
    rel = frame.point(points) / SCALE
    lo, hi = rel.min(0), rel.max(0)
    z = np.ceil(main_top + GAP + MARGIN - lo[2])
    if z + hi[2] + MARGIN > TOP:
        return None
    return np.array([0.0, 0.0, z])


def build(scene, exclude, frame, main_top, prefix, report=print, cache=None, workers=None):
    outside = backdrop(scene, exclude)
    if not outside.meshes:
        return None
    origin = place(outside, frame, main_top)
    if origin is None:
        report('the 3D skybox does not fit above this map; left out')
        return None
    builder = surfaces.Builder(outside, ScaledFrame(frame, origin), prefix, workers, report, cache, tag='sky_',
                               budget=BUDGET, scenery_cap=PAGE)
    built = builder.build()
    if not built.meshes:
        return None
    points = np.concatenate([m.positions for m in built.meshes] + [origin[None]])
    return SkyRoom(built, origin, np.floor(points.min(0)) - MARGIN, np.ceil(points.max(0)) + MARGIN)
