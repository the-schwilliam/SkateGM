import numpy as np

UNITS_PER_METRE = 1.0 / 0.0254


class Frame:
    def __init__(self, offset=(0.0, 0.0, 0.0), scale=UNITS_PER_METRE):
        self.offset = np.asarray(offset, np.float64)
        self.scale = scale

    @staticmethod
    def centred(lo, hi):
        frame = Frame()
        a, b = frame.raw(np.asarray(lo)), frame.raw(np.asarray(hi))
        mid = (np.minimum(a, b) + np.maximum(a, b)) / 2
        frame.offset = mid
        return frame

    def raw(self, points):
        p = np.asarray(points, np.float64)
        return np.stack([p[..., 0] * self.scale, -p[..., 2] * self.scale, p[..., 1] * self.scale], axis=-1)

    def point(self, points):
        return self.raw(points) - self.offset

    def direction(self, vectors):
        v = np.asarray(vectors, np.float64)
        return np.stack([v[..., 0], -v[..., 2], v[..., 1]], axis=-1)

    def to_dict(self):
        return {'offset': self.offset.tolist(), 'scale': self.scale}
