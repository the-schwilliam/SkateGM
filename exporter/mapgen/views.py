import math

import numpy as np

from .mathutil import norm

EYE = 72.0
CANDIDATES = 400


def _angles(origin, target):
    d = np.asarray(target, float) - np.asarray(origin, float)
    yaw = math.degrees(math.atan2(d[1], d[0]))
    pitch = -math.degrees(math.atan2(d[2], math.hypot(d[0], d[1])))
    return pitch, yaw


def floor_points(triangles, min_area=400.0):
    n = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
    length = norm(n)
    up = (length > 1e-6) & (n[:, 2] > 0.9 * length) & (length / 2 > min_area)
    return triangles[up].mean(1)


GRID = 512.0


class Indexed:
    def __init__(self, triangles):
        self.tris = np.asarray(triangles, np.float64)
        self.lo, self.hi = self.tris.min(1), self.tris.max(1)
        c0 = np.floor(self.lo[:, :2] / GRID).astype(np.int64)
        c1 = np.floor(self.hi[:, :2] / GRID).astype(np.int64)
        span = (c1 - c0 + 1)
        counts = span[:, 0] * span[:, 1]
        owner = np.repeat(np.arange(len(self.tris)), counts)
        offset = np.arange(int(counts.sum())) - np.repeat(np.cumsum(counts) - counts, counts)
        cx = c0[owner, 0] + offset // span[owner, 1]
        cy = c0[owner, 1] + offset % span[owner, 1]
        order = np.lexsort((owner, cy, cx))
        cx, cy, owner = cx[order], cy[order], owner[order]
        keys = np.stack([cx, cy], 1)
        breaks = np.flatnonzero(np.any(np.diff(keys, axis=0) != 0, axis=1)) + 1
        self.cells = {}
        for a, b in zip(np.r_[0, breaks], np.r_[breaks, len(owner)]):
            if b > a:
                self.cells[(int(cx[a]), int(cy[a]))] = owner[a:b]

    def candidates(self, lo, hi):
        x0, y0 = np.floor(np.asarray(lo[:2]) / GRID).astype(np.int64)
        x1, y1 = np.floor(np.asarray(hi[:2]) / GRID).astype(np.int64)
        found = [self.cells[(x, y)] for x in range(x0, x1 + 1) for y in range(y0, y1 + 1) if (x, y) in self.cells]
        if not found:
            return np.zeros(0, np.int64)
        return np.unique(np.concatenate(found))


def indexed(triangles):
    return triangles if isinstance(triangles, Indexed) else Indexed(triangles)


def clear_above(point, triangles, height=EYE + 24):
    return _clear_above(point, triangles, height)


def spot_ok(origin, spot, triangles):
    eye = np.asarray(origin, np.float64) + np.array([0, 0, 40.0])
    target = np.asarray(spot, np.float64) + np.array([0, 0, 40.0])
    d = target - eye
    reach = float(norm(d[None])[0])
    if _ray_distances(eye, (d / reach)[None], triangles, reach + 1.0)[0] < reach:
        return False
    down = _ray_distances(target, np.array([[0.0, 0.0, -1.0]]), triangles, 96.0)[0]
    return down < 72.0 and clear_above(spot - np.array([0, 0, 16.0]), triangles)


def _clear_above(point, triangles, height=EYE + 24):
    ix = indexed(triangles)
    x, y = point[0], point[1]
    k = ix.candidates((x, y), (x, y))
    lo, hi = ix.lo[k], ix.hi[k]
    near = (lo[:, 0] <= x) & (hi[:, 0] >= x) & (lo[:, 1] <= y) & (hi[:, 1] >= y)
    above = (lo[:, 2] > point[2] + 4) & (lo[:, 2] < point[2] + height)
    return not np.any(near & above)


DIRECTIONS = 8
REACH = 1500.0
OPEN = 400.0
ROOM = 24.0


def _dot(a, b):
    return a[..., 0] * b[..., 0] + a[..., 1] * b[..., 1] + a[..., 2] * b[..., 2]


def _ray_distances(origin, directions, triangles, reach=REACH):
    ix = indexed(triangles)
    k = ix.candidates(origin - reach, origin + reach)
    lo, hi = ix.lo[k], ix.hi[k]
    near = np.all((hi >= origin - reach) & (lo <= origin + reach), axis=1)
    t = ix.tris[k[near]]
    out = np.full(len(directions), reach)
    if not len(t):
        return out
    e1, e2 = t[:, 1] - t[:, 0], t[:, 2] - t[:, 0]
    s = origin - t[:, 0]
    q = np.cross(s, e1)
    for i, d in enumerate(directions):
        p = np.cross(np.broadcast_to(d, e2.shape), e2)
        det = _dot(e1, p)
        ok = np.abs(det) > 1e-9
        inv = np.where(ok, 1.0 / np.where(ok, det, 1.0), 0.0)
        u = _dot(s, p) * inv
        v = _dot(np.broadcast_to(d, q.shape), q) * inv
        dist = _dot(e2, q) * inv
        hit = ok & (u >= 0) & (v >= 0) & (u + v <= 1) & (dist > 0.5)
        if hit.any():
            out[i] = min(reach, float(dist[hit].min()))
    return out


def _yaws():
    return [2 * math.pi * k / DIRECTIONS for k in range(DIRECTIONS)]


def outlook(eye, triangles, towards):
    yaws = _yaws()
    dirs = np.array([[math.cos(a), math.sin(a), 0.0] for a in yaws])
    dist = _ray_distances(np.asarray(eye, np.float64), dirs, triangles)
    if dist.min() < ROOM or dist.max() < OPEN:
        return None
    want = math.atan2(towards[1] - eye[1], towards[0] - eye[0])
    good = [k for k in range(len(yaws)) if dist[k] >= 0.8 * dist.max()]
    best = min(good, key=lambda k: abs(math.remainder(yaws[k] - want, 2 * math.pi)))
    return math.degrees(yaws[best]), float(dist[best])


def spread(points, count, seed_point):
    if len(points) == 0:
        return []
    chosen = [int(np.argmin(norm(points - seed_point)))]
    dist = norm(points - points[chosen[0]])
    while len(chosen) < min(count, len(points)):
        i = int(np.argmax(dist))
        chosen.append(i)
        dist = np.minimum(dist, norm(points - points[i]))
    return [points[i] for i in chosen]


def plan(triangles, lo, hi, ground=8, spawn=None):
    centre = (np.asarray(lo) + np.asarray(hi)) / 2
    size = np.asarray(hi) - np.asarray(lo)
    views = []
    reach = max(size[0], size[1]) * 0.55
    for i, (dx, dy) in enumerate(((-1, -1), (1, 1), (-1, 1), (1, -1))):
        origin = centre + np.array([dx * size[0] * 0.5, dy * size[1] * 0.5, size[2] * 0.5 + reach * 0.35])
        views.append((f'overview_{i + 1}', origin, *_angles(origin, centre - np.array([0, 0, size[2] * 0.3])), 80))
    floors = floor_points(triangles)
    if len(floors) > CANDIDATES:
        floors = floors[np.linspace(0, len(floors) - 1, CANDIDATES).astype(np.int64)]
    tris = indexed(triangles)
    floors = np.array([p for p in floors if _clear_above(p, tris)]) if len(floors) else floors
    looks = {}
    for k, p in enumerate(floors):
        look = outlook(p + np.array([0, 0, EYE]), tris, centre)
        if look is not None:
            looks[k] = look
    if looks:
        floors = floors[sorted(looks)]
        looks = [looks[k] for k in sorted(looks)]
    seed = spawn if spawn is not None else centre
    for i, p in enumerate(spread(floors, ground, np.asarray(seed))):
        origin = p + np.array([0, 0, EYE])
        k = int(np.argmin(norm(floors - p)))
        if looks:
            views.append((f'ground_{i + 1}', origin, 5.0, round(looks[k][0], 1), 90))
            continue
        target = np.array([centre[0], centre[1], origin[2] - 40])
        if norm(target[:2] - origin[:2]) < 200:
            target = origin + np.array([400, 0, -60])
        views.append((f'ground_{i + 1}', origin, *_angles(origin, target), 90))
    return views


def plan_text(views):
    return ''.join(f'{name} {o[0]:.0f} {o[1]:.0f} {o[2]:.0f} {pitch:.1f} {yaw:.1f} {fov}\n' for name, o, pitch, yaw, fov in views)
