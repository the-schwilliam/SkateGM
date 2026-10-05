import numpy as np

from .bake import SRGB_TO_LINEAR, MipChain, linear_to_srgb8

SIZE = 512
SEA_BLEND = 24.0
FACES = {
    'rt': (np.array([1.0, 0.0, 0.0]), np.array([0.0, -1.0, 0.0]), np.array([0.0, 0.0, -1.0])),
    'bk': (np.array([0.0, 1.0, 0.0]), np.array([1.0, 0.0, 0.0]), np.array([0.0, 0.0, -1.0])),
    'lf': (np.array([-1.0, 0.0, 0.0]), np.array([0.0, 1.0, 0.0]), np.array([0.0, 0.0, -1.0])),
    'ft': (np.array([0.0, -1.0, 0.0]), np.array([-1.0, 0.0, 0.0]), np.array([0.0, 0.0, -1.0])),
    'up': (np.array([0.0, 0.0, 1.0]), np.array([0.0, -1.0, 0.0]), np.array([1.0, 0.0, 0.0])),
    'dn': (np.array([0.0, 0.0, -1.0]), np.array([0.0, -1.0, 0.0]), np.array([-1.0, 0.0, 0.0])),
}


def _dot(v, axis):
    return v[:, 0] * axis[0] + v[:, 1] * axis[1] + v[:, 2] * axis[2]


def _unwrap(uvs, faces):
    tri_uv = uvs[faces].copy()
    u = tri_uv[..., 0]
    wide = (u.max(1) - u.min(1)) > 0.5
    shift = wide[:, None] & (u < (u.max(1, keepdims=True) - 0.5))
    tri_uv[..., 0] = np.where(shift, u + 1.0, u)
    return tri_uv


def face(directions, tri_uv, faces, mip, axes, size=SIZE):
    forward, right, down = axes
    w, x, y = _dot(directions, forward), _dot(directions, right), _dot(directions, down)
    out = np.zeros((size, size, 3))
    covered = np.zeros((size, size), bool)
    for t in range(len(faces)):
        idx = faces[t]
        wt = w[idx]
        if (wt <= 1e-6).any():
            continue
        sx = (x[idx] / wt + 1.0) * 0.5 * size
        sy = (y[idx] / wt + 1.0) * 0.5 * size
        x0, x1 = max(0, int(np.floor(sx.min()))), min(size - 1, int(np.ceil(sx.max())))
        y0, y1 = max(0, int(np.floor(sy.min()))), min(size - 1, int(np.ceil(sy.max())))
        if x1 < x0 or y1 < y0:
            continue
        d = (sy[1] - sy[2]) * (sx[0] - sx[2]) + (sx[2] - sx[1]) * (sy[0] - sy[2])
        if abs(d) < 1e-12:
            continue
        X, Y = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        a = ((sy[1] - sy[2]) * (X - sx[2]) + (sx[2] - sx[1]) * (Y - sy[2])) / d
        b = ((sy[2] - sy[0]) * (X - sx[2]) + (sx[0] - sx[2]) * (Y - sy[2])) / d
        g = 1 - a - b
        inside = (a >= -1e-4) & (b >= -1e-4) & (g >= -1e-4)
        if not inside.any():
            continue
        a, b, g = a[inside], b[inside], g[inside]
        inv = a / wt[0] + b / wt[1] + g / wt[2]
        uv = tri_uv[t]
        u = (a * uv[0, 0] / wt[0] + b * uv[1, 0] / wt[1] + g * uv[2, 0] / wt[2]) / inv
        v = (a * uv[0, 1] / wt[0] + b * uv[1, 1] / wt[1] + g * uv[2, 1] / wt[2]) / inv
        colour = mip.sample(u, np.clip(v, 0.0, 0.9999), 0)
        xi, yi = X[inside].astype(np.int64), Y[inside].astype(np.int64)
        out[yi, xi] = colour[:, :3]
        covered[yi, xi] = True
    return out, covered


def render(sky, frame, size=SIZE, sea_colour=None):
    directions = frame.direction(sky.positions)
    lengths = np.sqrt(directions[:, 0] ** 2 + directions[:, 1] ** 2 + directions[:, 2] ** 2)
    directions = directions / lengths[:, None]
    tri_uv = _unwrap(sky.uvs, sky.faces)
    mip = MipChain(sky.texture)
    faces = {}
    rendered = {name: face(directions, tri_uv, sky.faces, mip, axes, size) for name, axes in FACES.items()}
    horizon = np.zeros(3)
    count = 0
    for name in ('rt', 'bk', 'lf', 'ft'):
        image, covered = rendered[name]
        rows = np.flatnonzero(covered.any(1))
        if len(rows):
            last = rows.max()
            line = covered[last]
            horizon += image[last][line].sum(0)
            count += int(line.sum())
    horizon = horizon / max(count, 1)
    below = None if sea_colour is None else SRGB_TO_LINEAR[np.asarray(sea_colour, np.uint8)]
    for name, (image, covered) in rendered.items():
        filled = image.copy()
        filled[~covered] = horizon
        if below is not None:
            if name == 'dn':
                filled[~covered] = below
            elif name in ('rt', 'bk', 'lf', 'ft'):
                rows = np.flatnonzero(covered.any(1))
                start = rows.max() + 1 if len(rows) else size // 2
                band = np.zeros((size, 1))
                band[start:] = np.clip((np.arange(start, size) - start) / SEA_BLEND, 0, 1)[:, None]
                mix = horizon * (1 - band) + below * band
                filled[~covered] = np.broadcast_to(mix[:, None, :], filled.shape)[~covered]
        rgba = np.full((size, size, 4), 255, np.uint8)
        rgba[..., :3] = linear_to_srgb8(filled)
        faces[name] = rgba
    return faces
