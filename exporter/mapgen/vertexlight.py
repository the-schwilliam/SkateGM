import struct
from pathlib import Path

import numpy as np

from .bake import LIGHTMAP_SCALE
from .models import VERTEX_GRID, snap

MAX_DEPTH = 4
MIN_TEXELS = 3.0
TOLERANCE = 0.15
VVD_VERTEX = 48


class Lightmap:
    def __init__(self, rgba):
        self.image = rgba[..., :3].astype(np.float64) / 255.0
        self.h, self.w = self.image.shape[:2]

    def sample(self, uv):
        uv = np.atleast_2d(np.asarray(uv, np.float64))
        x = np.clip(uv[:, 0] * self.w - 0.5, 0, self.w - 1)
        y = np.clip(uv[:, 1] * self.h - 0.5, 0, self.h - 1)
        x0, y0 = np.floor(x).astype(np.int64), np.floor(y).astype(np.int64)
        x1, y1 = np.minimum(x0 + 1, self.w - 1), np.minimum(y0 + 1, self.h - 1)
        fx, fy = (x - x0)[:, None], (y - y0)[:, None]
        top = self.image[y0, x0] * (1 - fx) + self.image[y0, x1] * fx
        bottom = self.image[y1, x0] * (1 - fx) + self.image[y1, x1] * fx
        return (top * (1 - fy) + bottom * fy) * LIGHTMAP_SCALE


CASES = {
    (False, False, False): [(0, 1, 2)],
    (True, False, False): [(0, 3, 2), (3, 1, 2)],
    (False, True, False): [(0, 1, 4), (0, 4, 2)],
    (False, False, True): [(0, 1, 5), (5, 1, 2)],
    (True, True, False): [(0, 3, 4), (0, 4, 2), (3, 1, 4)],
    (False, True, True): [(0, 1, 4), (0, 4, 5), (5, 4, 2)],
    (True, False, True): [(0, 3, 5), (3, 1, 2), (3, 2, 5)],
    (True, True, True): [(0, 3, 5), (3, 1, 4), (5, 4, 2), (3, 4, 5)],
}


def _split_edges(lightmap, lm, edges, tolerance=TOLERANCE, min_texels=MIN_TEXELS):
    a, b = lm[edges[:, 0]], lm[edges[:, 1]]
    span = np.abs(b - a) * (lightmap.w, lightmap.h)
    long_enough = np.sqrt(span[:, 0] ** 2 + span[:, 1] ** 2) >= min_texels
    wants = np.zeros(len(edges), bool)
    idx = np.flatnonzero(long_enough)
    if len(idx):
        t = np.linspace(0.0, 1.0, 5)
        pts = a[idx, None, :] + (b[idx] - a[idx])[:, None, :] * t[None, :, None]
        samples = lightmap.sample(pts.reshape(-1, 2)).reshape(len(idx), 5, 3)
        straight = samples[:, :1] + (samples[:, -1:] - samples[:, :1]) * t[None, :, None]
        wants[idx] = np.abs(samples - straight).max(axis=(1, 2)) > tolerance
    return wants


INTERIOR = np.array([[1 / 3, 1 / 3, 1 / 3], [2 / 3, 1 / 6, 1 / 6], [1 / 6, 2 / 3, 1 / 6], [1 / 6, 1 / 6, 2 / 3]])


def _split_interiors(lightmap, lm, faces, inverse, edge_count, tolerance=TOLERANCE, min_texels=MIN_TEXELS):
    tri = lm[faces]
    texels = tri * (lightmap.w, lightmap.h)
    sides = np.stack([texels[:, 1] - texels[:, 0], texels[:, 2] - texels[:, 1], texels[:, 0] - texels[:, 2]], 1)
    lengths = np.sqrt((sides ** 2).sum(2))
    big = lengths.max(1) >= min_texels
    wants = np.zeros(edge_count, bool)
    idx = np.flatnonzero(big)
    if not len(idx):
        return wants
    corners = lightmap.sample(tri[idx].reshape(-1, 2)).reshape(len(idx), 3, 3)
    points = np.einsum('kj,fjc->fkc', INTERIOR, tri[idx])
    samples = lightmap.sample(points.reshape(-1, 2)).reshape(len(idx), len(INTERIOR), 3)
    expected = np.einsum('kj,fjc->fkc', INTERIOR, corners)
    off = np.abs(samples - expected).max(axis=(1, 2)) > tolerance
    chosen = idx[off]
    longest = lengths[chosen].argmax(1)
    m = len(faces)
    edge_ids = inverse.reshape(3, m).T
    wants[edge_ids[chosen, longest]] = True
    return wants


def refine(lightmap, attributes, faces, detail=None):
    tolerance, depth, min_texels = detail or (TOLERANCE, MAX_DEPTH, MIN_TEXELS)
    arrays = [np.asarray(a, np.float64) for a in attributes]
    faces = np.asarray(faces, np.int64)
    for _ in range(depth):
        sides = np.concatenate([faces[:, [0, 1]], faces[:, [1, 2]], faces[:, [2, 0]]])
        keys = np.sort(sides, axis=1)
        unique, inverse = np.unique(keys, axis=0, return_inverse=True)
        wants = _split_edges(lightmap, arrays[3], unique, tolerance, min_texels)
        wants |= _split_interiors(lightmap, arrays[3], faces, inverse, len(unique), tolerance, min_texels)
        if not wants.any():
            break
        base = len(arrays[0])
        chosen = np.flatnonzero(wants)
        mid = np.full(len(unique), -1, np.int64)
        mid[chosen] = base + np.arange(len(chosen))
        for k in range(len(arrays)):
            arrays[k] = np.concatenate([arrays[k], (arrays[k][unique[chosen, 0]] + arrays[k][unique[chosen, 1]]) / 2])
        m = len(faces)
        ids = mid[inverse.reshape(-1)].reshape(3, m).T
        corners = np.concatenate([faces, ids], axis=1)
        flags = ids >= 0
        out = []
        for case, pattern in CASES.items():
            sel = np.all(flags == np.array(case), axis=1)
            if sel.any():
                rows = corners[sel]
                out += [rows[:, list(tri)] for tri in pattern]
        faces = np.concatenate(out)
    return arrays, faces


def subdivide(mesh, lightmap, detail=None, extra=()):
    attributes = [mesh.positions, mesh.uvs, mesh.normals, np.abs(mesh.lightmap_uvs), *extra]
    arrays, faces = refine(lightmap, attributes, mesh.faces, detail)
    positions, uvs, normals, lm = arrays[:4]
    colours = lightmap.sample(lm)
    if extra:
        return positions, uvs, normals, colours, faces, arrays[4:]
    return positions, uvs, normals, colours, faces


def read_vvd(path):
    data = Path(path).read_bytes()
    if data[:4] != b'IDSV':
        raise ValueError(f'{path} is not a VVD file')
    count = struct.unpack_from('<i', data, 16)[0]
    fixups = struct.unpack_from('<i', data, 48)[0]
    start = struct.unpack_from('<i', data, 56)[0]
    if fixups:
        raise ValueError(f'{path} has LOD fixups')
    raw = np.frombuffer(data, np.uint8, count * VVD_VERTEX, start).reshape(count, VVD_VERTEX)
    positions = raw[:, 16:28].copy().view('<f4').reshape(count, 3).astype(np.float64)
    uvs = raw[:, 40:48].copy().view('<f4').reshape(count, 2).astype(np.float64)
    return positions, uvs


def mdl_meshes(path):
    data = Path(path).read_bytes()
    count, index = struct.unpack_from('<ii', data, 232)
    out = []
    for b in range(count):
        part = index + b * 16
        _, models, _, model_index = struct.unpack_from('<iiii', data, part)
        for m in range(models):
            model = part + model_index + m * 148
            meshes, mesh_index, _, vertex_index = struct.unpack_from('<iiii', data, model + 72)
            for k in range(meshes):
                mesh = model + mesh_index + k * 116
                _, _, verts, offset = struct.unpack_from('<iiii', data, mesh)
                out.append((vertex_index // VVD_VERTEX + offset, verts))
    return out


def vtx_order(path, meshes, stripgroup_size=None):
    data = Path(path).read_bytes()
    parts, part_offset = struct.unpack_from('<ii', data, 28)
    order = []
    mesh_number = 0
    for size in ([stripgroup_size] if stripgroup_size else [25, 33]):
        order, mesh_number = [], 0
        try:
            for b in range(parts):
                bp = part_offset + b * 8
                models, model_offset = struct.unpack_from('<ii', data, bp)
                for m in range(models):
                    mp = bp + model_offset + m * 8
                    lods, lod_offset = struct.unpack_from('<ii', data, mp)
                    lp = mp + lod_offset
                    count, mesh_offset = struct.unpack_from('<ii', data, lp)
                    for k in range(count):
                        mh = lp + mesh_offset + k * 9
                        groups, group_offset = struct.unpack_from('<ii', data, mh)
                        start = meshes[mesh_number][0]
                        ids = []
                        for g in range(groups):
                            gh = mh + group_offset + g * size
                            verts, vert_offset = struct.unpack_from('<ii', data, gh)
                            for v in range(verts):
                                ids.append(start + struct.unpack_from('<H', data, gh + vert_offset + v * 9 + 4)[0])
                        order.append(ids)
                        mesh_number += 1
            if mesh_number == len(meshes):
                return order
        except (struct.error, IndexError):
            continue
    raise ValueError(f'could not read {path}')


def static_prop_models(bsp_path):
    data = Path(bsp_path).read_bytes()
    lump_offset, lump_length = struct.unpack_from('<ii', data, 8 + 35 * 16)
    count = struct.unpack_from('<i', data, lump_offset)[0]
    for k in range(count):
        gid, flags, version, offset, length = struct.unpack_from('<iHHii', data, lump_offset + 4 + k * 16)
        if gid == struct.unpack('<i', b'prps')[0]:
            return _sprp(data, offset, length, version)
    raise ValueError('no static prop lump')


def _sprp(data, offset, length, version):
    at = offset
    names = struct.unpack_from('<i', data, at)[0]
    at += 4
    models = []
    for _ in range(names):
        models.append(data[at:at + 128].split(b'\0')[0].decode('ascii', 'replace'))
        at += 128
    leaves = struct.unpack_from('<i', data, at)[0]
    at += 4 + leaves * 2
    props = struct.unpack_from('<i', data, at)[0]
    at += 4
    if props == 0:
        return []
    size = (offset + length - at) // props
    out = []
    for i in range(props):
        base = at + i * size
        origin = struct.unpack_from('<3f', data, base)
        model = struct.unpack_from('<H', data, base + 24)[0]
        out.append((models[model], origin))
    return out


def write_vhv(path, mdl_path, counts, colours):
    checksum = struct.unpack_from('<I', Path(mdl_path).read_bytes(), 8)[0]
    total = int(sum(counts))
    header = struct.pack('<IIIIIi4i', 2, checksum, 4, 4, total, len(counts), 0, 0, 0, 0)
    start = -(-(len(header) + 28 * len(counts)) // 512) * 512
    meshes = b''
    offset = start
    for n in counts:
        meshes += struct.pack('<III4i', 0, n, offset, 0, 0, 0, 0)
        offset += n * 4
    head = header + meshes
    rgb = encode_colour(colours)
    block = np.empty((total, 4), np.uint8)
    block[:, 0], block[:, 1], block[:, 2], block[:, 3] = rgb[:, 2], rgb[:, 1], rgb[:, 0], 255
    body = head + bytes(start - len(head)) + block.tobytes()
    Path(path).write_bytes(body + bytes(-len(body) % 512))


LEVEL_FLAGS_LUMP = 59
BAKED_PROP_LIGHTING_LDR = 0x1


def mark_baked_props(bsp_path):
    data = bytearray(Path(bsp_path).read_bytes())
    offset, length = struct.unpack_from('<ii', data, 8 + LEVEL_FLAGS_LUMP * 16)
    if length < 4:
        raise ValueError('map has no level flags lump')
    flags = struct.unpack_from('<I', data, offset)[0]
    struct.pack_into('<I', data, offset, flags | BAKED_PROP_LIGHTING_LDR)
    Path(bsp_path).write_bytes(bytes(data))


def light_props(bsp, chunks, game, model_dir, out_dir, extract, report=print):
    props = static_prop_models(bsp)
    lit = {f'models/{model_dir}/{c.name}.mdl': c for c in chunks if any(p.colours is not None for p in c.parts)}
    if not lit:
        return {}
    Path(out_dir).mkdir(parents=True, exist_ok=True)
    files = {}
    total = matched = 0
    for index, (model, _) in enumerate(props):
        chunk = lit.get(model.replace('\\', '/').lower())
        stem = Path(game) / model[:-4]
        if chunk is None:
            groups = vtx_order(stem.with_suffix('.dx90.vtx'), mdl_meshes(stem.with_suffix('.mdl')))
            grey = np.full((sum(len(g) for g in groups), 3), 1.0)
            for name in (f'sp_{index}.vhv', f'sp_hdr_{index}.vhv'):
                write_vhv(Path(out_dir) / name, stem.with_suffix('.mdl'), [len(g) for g in groups], grey)
                files[name] = Path(out_dir) / name
            continue
        vpos, vuv = read_vvd(stem.with_suffix('.vvd'))
        groups = vtx_order(stem.with_suffix('.dx90.vtx'), mdl_meshes(stem.with_suffix('.mdl')))
        order = np.concatenate([np.asarray(ids, np.int64) for ids in groups])
        vpos, vuv = vpos[order], vuv[order]
        local = snap(np.concatenate([p.positions.reshape(-1, 3) for p in chunk.parts]) - chunk.origin)
        uvs = np.concatenate([p.uvs.reshape(-1, 2) for p in chunk.parts])
        cols = np.concatenate([(p.colours if p.colours is not None else np.full(p.positions.shape, np.nan)).reshape(-1, 3)
                               for p in chunk.parts])
        known = ~np.isnan(cols).any(1)
        colours, mask = match_colours(vpos, vuv, turn(local[known]), uvs[known], cols[known])
        origin, _ = match_colours(vpos, vuv, turn(local), uvs, np.repeat(known[:, None].astype(np.float64), 3, 1))
        wanted = origin[:, 0] > 0.5
        total += int(wanted.sum())
        matched += int((mask & wanted).sum())
        if mask.any():
            colours[~mask] = colours[mask].mean(0)
        else:
            colours[:] = 0.5
        for name in (f'sp_{index}.vhv', f'sp_hdr_{index}.vhv'):
            path = Path(out_dir) / name
            write_vhv(path, stem.with_suffix('.mdl'), [len(g) for g in groups], colours)
            files[name] = path
    report(f'Skate lighting on {matched} of {total} lit prop vertices')
    return files


def turn(positions):
    return np.stack([-positions[:, 1], positions[:, 0], positions[:, 2]], axis=1)


def _keys(positions, uvs):
    q = np.concatenate([np.round(np.asarray(positions, np.float64) / VERTEX_GRID), np.round(np.asarray(uvs, np.float64) * 1000)], axis=1)
    return q.astype(np.int64)


def match_colours(vvd_positions, vvd_uvs, part_positions, part_uvs, part_colours):
    out = np.zeros((len(vvd_positions), 3))
    mask = np.zeros(len(vvd_positions), bool)
    if not len(part_positions):
        return out, mask
    table, index = np.unique(_keys(part_positions, part_uvs), axis=0, return_inverse=True)
    index = index.reshape(-1)
    sums = np.zeros((len(table), 3))
    np.add.at(sums, index, part_colours)
    counts = np.bincount(index, minlength=len(table))[:, None]
    means = sums / counts
    for uvs in (vvd_uvs, np.stack([vvd_uvs[:, 0], 1.0 - vvd_uvs[:, 1]], 1)):
        todo = np.flatnonzero(~mask)
        if not len(todo):
            break
        keys = _keys(vvd_positions[todo], uvs[todo])
        joined = np.concatenate([table, keys])
        _, first, inverse = np.unique(joined, axis=0, return_index=True, return_inverse=True)
        inverse = inverse.reshape(-1)
        hit_row = first[inverse[len(table):]]
        found = hit_row < len(table)
        out[todo[found]] = means[hit_row[found]]
        mask[todo[found]] = True
    todo = np.flatnonzero(~mask)
    if len(todo):
        spots = np.round(np.asarray(part_positions, np.float64) / VERTEX_GRID).astype(np.int64)
        table, index = np.unique(spots, axis=0, return_inverse=True)
        index = index.reshape(-1)
        sums = np.zeros((len(table), 3))
        np.add.at(sums, index, part_colours)
        means = sums / np.bincount(index, minlength=len(table))[:, None]
        keys = np.round(np.asarray(vvd_positions[todo], np.float64) / VERTEX_GRID).astype(np.int64)
        _, first, inverse = np.unique(np.concatenate([table, keys]), axis=0, return_index=True, return_inverse=True)
        hit_row = first[inverse.reshape(-1)[len(table):]]
        found = hit_row < len(table)
        out[todo[found]] = means[hit_row[found]]
        mask[todo[found]] = True
    return out, mask


def encode_colour(linear):
    return np.round(np.clip(linear / OVERBRIGHT, 0.0, 1.0) * 255).astype(np.uint8)


OVERBRIGHT = 4.0


def rewrite_vhv(path, colours, mask):
    data = bytearray(Path(path).read_bytes())
    version, checksum, flags, size, count, meshes = struct.unpack_from('<IIIIIi', data, 0)
    if version != 2 or size != 4 or count != len(colours):
        raise ValueError(f'{path}: unexpected layout ({version}, {size}, {count} vs {len(colours)})')
    first = struct.unpack_from('<III', data, 40)[2] if meshes else 512
    rgb = encode_colour(colours)
    block = np.frombuffer(bytes(data[first:first + count * 4]), np.uint8).reshape(count, 4).copy()
    block[mask, 0] = rgb[mask, 2]
    block[mask, 1] = rgb[mask, 1]
    block[mask, 2] = rgb[mask, 0]
    block[mask, 3] = 255
    data[first:first + count * 4] = block.tobytes()
    Path(path).write_bytes(bytes(data))
