import math
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass

import numpy as np

from .tone import filmic

VERSION = 4
LIGHTMAP_SCALE = 4.0
MAX_SIZE = 2048
SCENERY_SIZE = 512
DILATE = 8


@dataclass
class Entry:
    diffuse: np.ndarray
    lightmap_uv: np.ndarray
    uv: np.ndarray
    faces: np.ndarray
    alpha: bool = False
    decal: np.ndarray = None
    decal_uv: np.ndarray = None


@dataclass
class Page:
    lightmap: str
    width: int
    height: int
    rgba: np.ndarray
    alpha: bool


def cross2(a, b):
    return a[..., 0] * b[..., 1] - a[..., 1] * b[..., 0]


def _srgb_table():
    table = []
    for i in range(256):
        c = i / 255.0
        table.append(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4)
    return np.array([round(v * 16777216) / 16777216 for v in table], np.float64)


SRGB_TO_LINEAR = _srgb_table()
SRGB_EDGES = (SRGB_TO_LINEAR[:-1] + SRGB_TO_LINEAR[1:]) / 2


def srgb_to_linear(c8):
    return SRGB_TO_LINEAR[np.asarray(c8, np.uint8)]


def linear_to_srgb8(c):
    return np.searchsorted(SRGB_EDGES, np.clip(c, 0.0, 1.0)).astype(np.uint8)


def half_log2_floor(x):
    if not x > 0:
        return 0
    m, e = math.frexp(x)
    return (e - 1) // 2


class MipChain:
    def __init__(self, rgba):
        level = np.empty(rgba.shape, np.float64)
        level[..., :3] = srgb_to_linear(rgba[..., :3])
        level[..., 3] = rgba[..., 3] / 255.0
        self.levels = [level]
        while min(level.shape[:2]) > 1:
            h, w = level.shape[0] // 2 * 2, level.shape[1] // 2 * 2
            level = level[:h, :w]
            level = (level[0::2, 0::2] + level[1::2, 0::2] + level[0::2, 1::2] + level[1::2, 1::2]) / 4
            self.levels.append(level)

    def sample(self, u, v, lod):
        lod = int(np.clip(lod, 0, len(self.levels) - 1))
        img = self.levels[lod]
        h, w = img.shape[:2]
        x = u * w - 0.5
        y = v * h - 0.5
        x0 = np.floor(x).astype(np.int64)
        y0 = np.floor(y).astype(np.int64)
        fx = (x - x0)[:, None]
        fy = (y - y0)[:, None]
        x0, x1 = x0 % w, (x0 + 1) % w
        y0, y1 = y0 % h, (y0 + 1) % h
        top = img[y0, x0] * (1 - fx) + img[y0, x1] * fx
        bottom = img[y1, x0] * (1 - fx) + img[y1, x1] * fx
        return top * (1 - fy) + bottom * fy


def _lightmap_linear(rgba):
    return rgba[..., :3].astype(np.float64) / 255.0


def _bilinear_clamped(img, x, y):
    h, w = img.shape[:2]
    x = np.clip(x - 0.5, 0, w - 1)
    y = np.clip(y - 0.5, 0, h - 1)
    x0 = np.floor(x).astype(np.int64)
    y0 = np.floor(y).astype(np.int64)
    x1, y1 = np.minimum(x0 + 1, w - 1), np.minimum(y0 + 1, h - 1)
    fx, fy = (x - x0)[:, None], (y - y0)[:, None]
    top = img[y0, x0] * (1 - fx) + img[y0, x1] * fx
    bottom = img[y1, x0] * (1 - fx) + img[y1, x1] * fx
    return top * (1 - fy) + bottom * fy


def _scale_for(entries, lw, lh, max_size=MAX_SIZE):
    best = 1.0
    for e in entries:
        dh, dw = e.diffuse.shape[:2]
        a = e.lightmap_uv[e.faces]
        b = e.uv[e.faces]
        lm_area = np.abs(cross2(a[:, 1] - a[:, 0], a[:, 2] - a[:, 0])) * (lw * lh)
        d_area = np.abs(cross2(b[:, 1] - b[:, 0], b[:, 2] - b[:, 0])) * (dw * dh)
        ok = lm_area > 1e-6
        if ok.any():
            best = max(best, math.fsum(d_area[ok].tolist()) / math.fsum(lm_area[ok].tolist()))
    limit = max(1, max_size // max(lw, lh))
    scale = 1
    while scale * 2 <= limit and best >= (scale * 2) ** 2 / 2:
        scale *= 2
    return max(1, scale)


def _rasterise(out, filled, page_lm, scale, mip, entry, decal_mip=None):
    H, W = out.shape[:2]
    lm_uv, uv, faces, alpha_needed = entry.lightmap_uv, entry.uv, entry.faces, entry.alpha
    for f in faces:
        p = lm_uv[f] * np.array([W, H])
        t = uv[f]
        x0, x1 = int(max(0, math.floor(p[:, 0].min()))), int(min(W - 1, math.ceil(p[:, 0].max())))
        y0, y1 = int(max(0, math.floor(p[:, 1].min()))), int(min(H - 1, math.ceil(p[:, 1].max())))
        if x1 < x0 or y1 < y0:
            continue
        d = (p[1, 1] - p[2, 1]) * (p[0, 0] - p[2, 0]) + (p[2, 0] - p[1, 0]) * (p[0, 1] - p[2, 1])
        if abs(d) < 1e-12:
            continue
        X, Y = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        a = ((p[1, 1] - p[2, 1]) * (X - p[2, 0]) + (p[2, 0] - p[1, 0]) * (Y - p[2, 1])) / d
        b = ((p[2, 1] - p[0, 1]) * (X - p[2, 0]) + (p[0, 0] - p[2, 0]) * (Y - p[2, 1])) / d
        g = 1 - a - b
        eps = -0.5 / max(1.0, abs(d) ** 0.5)
        inside = (a >= eps) & (b >= eps) & (g >= eps)
        if not inside.any():
            continue
        a, b, g = a[inside], b[inside], g[inside]
        xs, ys = X[inside], Y[inside]
        u = a * t[0, 0] + b * t[1, 0] + g * t[2, 0]
        v = a * t[0, 1] + b * t[1, 1] + g * t[2, 1]
        texel_area = abs(cross2(t[1] - t[0], t[2] - t[0])) * mip.levels[0].shape[0] * mip.levels[0].shape[1]
        lod = half_log2_floor(texel_area / (abs(d) / 2)) if texel_area > 0 else 0
        colour = mip.sample(u, v, lod)
        if decal_mip is not None:
            q = entry.decal_uv[f]
            du = a * q[0, 0] + b * q[1, 0] + g * q[2, 0]
            dv = a * q[0, 1] + b * q[1, 1] + g * q[2, 1]
            d_area = abs(cross2(q[1] - q[0], q[2] - q[0])) * decal_mip.levels[0].shape[0] * decal_mip.levels[0].shape[1]
            d_lod = half_log2_floor(d_area / (abs(d) / 2)) if d_area > 0 else 0
            layer = decal_mip.sample(du, dv, d_lod)
            k = layer[:, 3:4]
            colour = np.concatenate([colour[:, :3] * (1 - k) + layer[:, :3] * k, colour[:, 3:4]], axis=1)
        light = _bilinear_clamped(page_lm, xs / scale, ys / scale) * LIGHTMAP_SCALE
        ix, iy = xs.astype(np.int64), ys.astype(np.int64)
        out[iy, ix, :3] = colour[:, :3] * light
        out[iy, ix, 3] = colour[:, 3] if alpha_needed else 1.0
        filled[iy, ix] = True


def _dilate(out, filled, steps):
    for _ in range(steps):
        empty = ~filled
        if not empty.any():
            break
        acc = np.zeros_like(out)
        count = np.zeros(filled.shape, np.float32)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                shifted = np.roll(np.roll(filled, dy, 0), dx, 1)
                acc += np.roll(np.roll(out, dy, 0), dx, 1) * shifted[..., None]
                count += shifted
        grow = empty & (count > 0)
        out[grow] = acc[grow] / count[grow][:, None]
        filled |= grow


def bake_page(lightmap_id, lightmap_rgba, entries, alpha, max_size=MAX_SIZE):
    lh, lw = lightmap_rgba.shape[:2]
    scale = _scale_for(entries, lw, lh, max_size)
    W, H = lw * scale, lh * scale
    out = np.zeros((H, W, 4), np.float64)
    filled = np.zeros((H, W), bool)
    page_lm = _lightmap_linear(lightmap_rgba)
    mips = {}

    def mip_for(image):
        if id(image) not in mips:
            mips[id(image)] = MipChain(image)
        return mips[id(image)]

    for entry in entries:
        decal = mip_for(entry.decal) if entry.decal is not None and entry.decal_uv is not None else None
        _rasterise(out, filled, page_lm, scale, mip_for(entry.diffuse), entry, decal)
    _dilate(out, filled, DILATE)
    rgba = np.empty((H, W, 4), np.uint8)
    rgba[..., :3] = linear_to_srgb8(filmic(out[..., :3]))
    rgba[..., 3] = np.round(np.clip(np.where(filled, out[..., 3], 1.0), 0, 1) * 255)
    return Page(lightmap_id, W, H, rgba, alpha)


def _work(args):
    return bake_page(*args)


def bake(page_jobs, workers=None):
    if workers == 1 or len(page_jobs) <= 1:
        return [_work(job) for job in page_jobs]
    with ProcessPoolExecutor(max_workers=workers) as pool:
        return list(pool.map(_work, page_jobs))
