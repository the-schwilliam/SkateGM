import numpy as np


def norm(v):
    v = np.asarray(v, np.float64)
    total = v[..., 0] * v[..., 0]
    for i in range(1, v.shape[-1]):
        total = total + v[..., i] * v[..., i]
    return np.sqrt(total)
