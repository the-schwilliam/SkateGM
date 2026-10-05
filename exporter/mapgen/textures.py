import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image


def _settings(texture):
    lines = []
    if texture.normal_map:
        lines.append('normal 1')
    if texture.sky:
        lines += ['clamps 1', 'clampt 1', 'nomip 1', 'nolod 1']
    return '\n'.join(lines) + '\n' if lines else ''


def _has_alpha(texture):
    return texture.alpha and texture.rgba.shape[2] == 4 and int(texture.rgba[..., 3].min()) < 255


def write_sources(surfaces, game):
    sources = []
    for texture in surfaces.textures.values():
        tga = Path(game) / 'materialsrc' / (texture.name + '.tga')
        tga.parent.mkdir(parents=True, exist_ok=True)
        rgba = np.ascontiguousarray(texture.rgba)
        image = Image.fromarray(rgba, 'RGBA')
        if not _has_alpha(texture):
            image = image.convert('RGB')
        image.save(tga)
        settings = _settings(texture)
        if settings:
            tga.with_suffix('.txt').write_text(settings, encoding='ascii')
        sources.append(tga)
    return sources


def compile_textures(tools, sources, report=print, workers=None):
    workers = workers or os.cpu_count() or 4
    report(f'compiling {len(sources)} textures')

    def one(tga):
        tools.run('vtex', ['-nopause', '-game', tools.game, tga], check=lambda out: 'SUCCESS' in out.upper())

    with ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(one, sources))
    missing = [s for s in sources if not _vtf_for(tools.game, s).is_file()]
    if missing:
        raise RuntimeError('vtex did not produce ' + ', '.join(str(m) for m in missing[:5]))


def _vtf_for(game, tga):
    rel = Path(tga).relative_to(Path(game) / 'materialsrc')
    return Path(game) / 'materials' / rel.with_suffix('.vtf')


def _value(value):
    if isinstance(value, float):
        return f'{value:g}'
    return str(value)


def vmt_text(material):
    lines = [f'"{material.shader}"', '{']
    for key, value in material.params.items():
        lines.append(f'\t"{key}" "{_value(value)}"')
    if material.surfaceprop:
        lines.append(f'\t"$surfaceprop" "{material.surfaceprop}"')
    lines.append('}')
    return '\n'.join(lines) + '\n'


def write_materials(surfaces, game):
    written = []
    for material in surfaces.materials.values():
        path = Path(game) / 'materials' / (material.name + '.vmt')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(vmt_text(material), encoding='ascii')
        written.append(path)
    return written
