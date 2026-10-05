import numpy as np

MAX_EXTENT = 800.0
WALL_BELOW = 20.0
WALL_ABOVE = 40.0


def outline(region, collision):
    if len(region.corners):
        return np.asarray(region.corners, np.float64).reshape(-1, 2)
    tris = collision.reshape(-1, 3)
    lo, hi = tris[:, [0, 2]].min(0), tris[:, [0, 2]].max(0)
    return np.array([[lo[0], lo[1]], [hi[0], lo[1]], [hi[0], hi[1]], [lo[0], hi[1]]])


def walls(corners, y_lo, y_hi):
    bottom, top = y_lo - WALL_BELOW, y_hi + WALL_ABOVE
    out = []
    for i in range(len(corners)):
        (x0, z0), (x1, z1) = corners[i], corners[(i + 1) % len(corners)]
        a, b = np.array([x0, bottom, z0]), np.array([x1, bottom, z1])
        c, d = np.array([x1, top, z1]), np.array([x0, top, z0])
        out += [(a, b, c), (a, c, d), (a, c, b), (a, d, c)]
    return np.asarray(out, np.float32).reshape(-1, 3, 3)


def expanded(corners, margin):
    if margin <= 0:
        return corners
    centre = corners.mean(0)
    out = []
    for p in corners:
        d = p - centre
        length = float(np.sqrt(d[0] * d[0] + d[1] * d[1]))
        out.append(p + d / max(length, 1e-9) * margin * 1.41421356)
    return np.asarray(out)


def scenery_margin(corners, wanted):
    size = corners.max(0) - corners.min(0)
    room = (MAX_EXTENT - float(size.max())) / 2.0 / 1.41421356
    return max(0.0, min(wanted, room))
