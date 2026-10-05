import math

import numpy as np

EXPOSURE = 0.7
MIN_ALBEDO = 0.02


def filmic(x):
    x = np.maximum(np.asarray(x, np.float64) * EXPOSURE, 0.0)
    return np.clip(x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0)


def mean_albedo(rgba):
    from .bake import SRGB_TO_LINEAR
    out = np.empty(3)
    for c in range(3):
        counts = np.bincount(np.asarray(rgba[..., c], np.uint8).reshape(-1), minlength=256)
        out[c] = math.fsum(int(n) * float(v) for n, v in zip(counts, SRGB_TO_LINEAR)) / max(int(counts.sum()), 1)
    return np.maximum(out, MIN_ALBEDO)


def vertex_light(light, albedo):
    return filmic(np.asarray(light, np.float64) * albedo) / albedo
