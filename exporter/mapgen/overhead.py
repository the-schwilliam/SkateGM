from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from . import decode, regions, scene, tone
from .bake import SRGB_TO_LINEAR, linear_to_srgb8
from .source import GameSource
from .vertexlight import Lightmap

SEA = (52, 92, 128)
GRID = 50.0
LABEL_EVERY = 100.0
MARGIN = 40.0
BUSY = 40


def _albedo(texture):
    rgba = texture.rgba()
    return SRGB_TO_LINEAR[rgba[..., :3].reshape(-1, 3)].mean(0)


def _font(size):
    for name in ('arialbd.ttf', 'arial.ttf', 'DejaVuSans-Bold.ttf'):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def triangles(scn):
    albedos, lightmaps = {}, {}
    out_tris, out_colours = [], []
    for mesh in scn.meshes:
        material = scn.materials.get(mesh.material)
        if material is None:
            continue
        diffuse = material.textures.get('diffuse')
        if diffuse not in scn.textures:
            continue
        if diffuse not in albedos:
            albedos[diffuse] = _albedo(scn.textures[diffuse])
        tris = mesh.positions[mesh.faces].astype(np.float64)
        lm = material.textures.get('lightmap')
        if lm in scn.textures and mesh.lightmap_uvs is not None:
            if lm not in lightmaps:
                lightmaps[lm] = Lightmap(scn.textures[lm].rgba())
            light = lightmaps[lm].sample(np.abs(mesh.lightmap_uvs)[mesh.faces].reshape(-1, 2)).reshape(-1, 3, 3).mean(1)
        else:
            n = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
            up = np.abs(n[:, 1]) / np.maximum(np.linalg.norm(n, axis=1), 1e-9)
            light = np.repeat((0.6 + 1.4 * up)[:, None], 3, 1)
        colour = linear_to_srgb8(tone.filmic(light * albedos[diffuse]))
        out_tris.append(tris)
        out_colours.append(colour)
    return np.concatenate(out_tris), np.concatenate(out_colours)


def render(scn, title, scale=2.0, outlines=()):
    tris, colours = triangles(scn)
    xz = tris[:, :, [0, 2]]
    cells, counts = np.unique(np.floor(xz.mean(1) / GRID).astype(np.int64), axis=0, return_counts=True)
    busy = cells[counts >= BUSY]
    lo = (busy.min(0)) * GRID - np.ceil(MARGIN / GRID) * GRID
    hi = (busy.max(0) + 1) * GRID + np.ceil(MARGIN / GRID) * GRID
    w, h = (int((hi[0] - lo[0]) * scale), int((hi[1] - lo[1]) * scale))
    image = Image.new('RGB', (w, h + 60), SEA)
    draw = ImageDraw.Draw(image)

    def px(x, z):
        return (x - lo[0]) * scale, 60 + (z - lo[1]) * scale

    order = np.argsort(tris[:, :, 1].max(1), kind='stable')
    pts = np.stack([(xz[..., 0] - lo[0]) * scale, 60 + (xz[..., 1] - lo[1]) * scale], -1)
    for k in order:
        p = pts[k]
        draw.polygon([(p[0, 0], p[0, 1]), (p[1, 0], p[1, 1]), (p[2, 0], p[2, 1])], fill=tuple(int(c) for c in colours[k]))

    grid = Image.new('RGBA', image.size, (0, 0, 0, 0))
    g = ImageDraw.Draw(grid)
    small, big = _font(max(12, int(7 * scale))), _font(max(16, int(10 * scale)))
    x = lo[0]
    while x <= hi[0]:
        major = abs(x / LABEL_EVERY - round(x / LABEL_EVERY)) < 1e-6
        g.line([px(x, lo[1]), px(x, hi[1])], fill=(255, 255, 255, 140 if major else 60), width=2 if major else 1)
        if major:
            g.text((px(x, lo[1])[0] + 3, 62), f'x {x:.0f}', font=small, fill=(255, 255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0, 255))
        x += GRID
    z = lo[1]
    while z <= hi[1]:
        major = abs(z / LABEL_EVERY - round(z / LABEL_EVERY)) < 1e-6
        g.line([px(lo[0], z), px(hi[0], z)], fill=(255, 255, 255, 140 if major else 60), width=2 if major else 1)
        if major:
            g.text((3, px(lo[0], z)[1] + 3), f'z {z:.0f}', font=small, fill=(255, 255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0, 255))
        z += GRID
    for name, corners in outlines:
        ring = [px(cx, cz) for cx, cz in corners] + [px(*corners[0])]
        g.line(ring, fill=(255, 210, 60, 255), width=max(3, int(2 * scale)))
        cx, cz = np.mean(corners, axis=0)
        g.text(px(cx, cz), name, font=big, fill=(255, 210, 60, 255), anchor='mm', stroke_width=3, stroke_fill=(0, 0, 0, 255))
    g.rectangle([0, 0, w, 58], fill=(20, 20, 20, 230))
    g.text((12, 10), f'{title}   (Skate metres; grid {GRID:.0f} m, labels every {LABEL_EVERY:.0f} m; yellow = maps already made)',
           font=big, fill=(255, 255, 255, 255))
    image = Image.alpha_composite(image.convert('RGBA'), grid).convert('RGB')
    return image


def make(game, work, districts, out_dir, scale=2.0, report=print):
    source = GameSource(game, Path(work) / 'disc')
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    files = []
    for district in districts:
        root = decode.decode(source, district, Path(work) / 'districts', report)
        scn = scene.load(root, collision=False)
        outlines = [(r.map_name, list(r.corners)) for r in regions.REGIONS if r.district == district and len(r.corners)]
        title = district.removeprefix('DIST_')
        report(f'{title}: {sum(len(m.faces) for m in scn.meshes)} triangles')
        path = out / f'overhead_{title}.jpg'
        render(scn, title, scale, outlines).save(path, quality=88)
        files.append(path)
    return files
