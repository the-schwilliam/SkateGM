import math

import numpy as np
from PIL import Image

SIZE = 512
OUT = 256


def _camera(origin, pitch, yaw):
    p, y = math.radians(pitch), math.radians(yaw)
    forward = np.array([math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), -math.sin(p)])
    right = np.cross(forward, [0.0, 0.0, 1.0])
    right /= math.sqrt(float(right @ right))
    up = np.cross(right, forward)
    return np.asarray(origin, np.float64), forward, right, up


def _texel(texture, uv):
    h, w = texture.shape[:2]
    x = np.clip((uv[:, 0] % 1.0 * w).astype(np.int64), 0, w - 1)
    y = np.clip((uv[:, 1] % 1.0 * h).astype(np.int64), 0, h - 1)
    return texture[y, x, :3].astype(np.float64)


def render(surfaces, view, fov=70.0, sky=(178, 186, 196)):
    _, origin, pitch, yaw, _ = view
    o, f, r, u = _camera(origin, pitch, yaw)
    focal = (SIZE / 2) / math.tan(math.radians(fov) / 2)
    image = np.empty((SIZE, SIZE, 3))
    image[:] = sky
    depth = np.full((SIZE, SIZE), np.inf)
    textures = {}
    for t in surfaces.textures.values():
        textures[t.name] = t.rgba
    for mesh in surfaces.meshes:
        material = surfaces.materials.get(mesh.material.rsplit('/', 1)[-1])
        texture = textures.get(material.params.get('$basetexture')) if material else None
        tris = mesh.positions[mesh.faces]
        centre_uv = mesh.uvs[mesh.faces].mean(1)
        colours = _texel(texture, centre_uv) if texture is not None else np.full((len(tris), 3), 150.0)
        rel = tris - o
        cx, cy, cz = rel @ r, rel @ u, rel @ f
        normal = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
        facing = (normal * -rel[:, 0]).sum(1) > 0
        visible = (cz > 8).all(1) & facing
        safe = np.where(cz > 8, cz, 1.0)
        px = SIZE / 2 + focal * cx / safe
        py = SIZE / 2 - focal * cy / safe
        area = np.abs((px[:, 1] - px[:, 0]) * (py[:, 2] - py[:, 0]) - (px[:, 2] - px[:, 0]) * (py[:, 1] - py[:, 0]))
        onscreen = (px.max(1) >= 0) & (px.min(1) < SIZE) & (py.max(1) >= 0) & (py.min(1) < SIZE)
        visible &= onscreen & (area > 0.5)
        for i in np.flatnonzero(visible):
            z = cz[i]
            sx = SIZE / 2 + focal * cx[i] / z
            sy = SIZE / 2 - focal * cy[i] / z
            x0, x1 = max(0, int(sx.min())), min(SIZE - 1, int(math.ceil(sx.max())))
            y0, y1 = max(0, int(sy.min())), min(SIZE - 1, int(math.ceil(sy.max())))
            if x1 < x0 or y1 < y0:
                continue
            d = (sy[1] - sy[2]) * (sx[0] - sx[2]) + (sx[2] - sx[1]) * (sy[0] - sy[2])
            if abs(d) < 1e-9:
                continue
            X, Y = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
            a = ((sy[1] - sy[2]) * (X - sx[2]) + (sx[2] - sx[1]) * (Y - sy[2])) / d
            b = ((sy[2] - sy[0]) * (X - sx[2]) + (sx[0] - sx[2]) * (Y - sy[2])) / d
            g = 1 - a - b
            inside = (a >= 0) & (b >= 0) & (g >= 0)
            zz = 1 / (a / z[0] + b / z[1] + g / z[2])
            yi, xi = Y.astype(np.int64), X.astype(np.int64)
            sel = inside & (zz < depth[yi, xi])
            depth[yi[sel], xi[sel]] = zz[sel]
            image[yi[sel], xi[sel]] = colours[i]
    picture = Image.fromarray(np.clip(image, 0, 255).astype(np.uint8))
    return picture.resize((OUT, OUT), Image.LANCZOS)
