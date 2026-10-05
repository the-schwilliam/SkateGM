import base64
import hashlib
import struct
import zlib
from pathlib import Path

import numpy as np

FIXED = zlib.decompress(base64.b64decode(
    'eNpjYGBgUGFnQAG9rAwjBqxiYWD4jwfg0vfvf709igBjgzUM5wp6msMwkroGKAbahyLGgCTWgGERWlwsBLqXkQh/3WOGqONBEvv+//ihE6uFtsP4v/4fd/r9391pBTNxYWXz5///SWC1HxzBXiYyjHPIiBdQwJ/5/f+/BtC+D0ywMELExxUg/obmn59A//wC+gfkrhuwaIFifPF59oyPHQgT67YrUAwDILvuEO2zBnDcAwB1pGl7'))
HEADER = 408
HDR2, BONE, HITBOXSET, HITBOX, ANIM, SEQ, BODYPART = 408, 664, 880, 892, 964, 1076, 1296
MODEL = BODYPART + 16
MODEL_SIZE, MESH_SIZE, TEXTURE_SIZE = 148, 116, 64
VVD_VERTEX = 48
MAX_VERTICES = 65535
TRILIST = 0x01
HW_SKINNED = 0x02


class TooBig(ValueError):
    pass


def turn(points):
    p = np.asarray(points, np.float64)
    return np.stack([-p[:, 1], p[:, 0], p[:, 2]], axis=1)


def _tangents(pos, nrm, uv, faces):
    a, b, c = pos[faces[:, 0]], pos[faces[:, 1]], pos[faces[:, 2]]
    ta, tb, tc = uv[faces[:, 0]], uv[faces[:, 1]], uv[faces[:, 2]]
    e1, e2 = b - a, c - a
    d1, d2 = tb - ta, tc - ta
    r = d1[:, 0] * d2[:, 1] - d2[:, 0] * d1[:, 1]
    r = np.where(np.abs(r) < 1e-12, 1.0, r)
    sdir = (e1 * d2[:, 1:2] - e2 * d1[:, 1:2]) / r[:, None]
    tdir = (e2 * d1[:, 0:1] - e1 * d2[:, 0:1]) / r[:, None]
    tan, bit = np.zeros_like(pos), np.zeros_like(pos)
    for k in range(3):
        np.add.at(tan, faces[:, k], sdir)
        np.add.at(bit, faces[:, k], tdir)
    t = tan - nrm * (nrm * tan).sum(1, keepdims=True)
    length = np.sqrt((t * t).sum(1, keepdims=True))
    t = np.where(length > 1e-12, t / np.maximum(length, 1e-12), np.array([1.0, 0.0, 0.0]))
    cross = np.cross(nrm, t)
    w = np.where((cross * bit).sum(1) < 0, -1.0, 1.0)
    return np.concatenate([t, w[:, None]], 1)


def _mesh(part, origin, snap):
    pos = turn(snap(np.asarray(part.positions, np.float64).reshape(-1, 3) - origin))
    raw = np.asarray(part.normals, np.float64).reshape(-1, 3)
    raw = raw / np.maximum(np.sqrt((raw * raw).sum(1, keepdims=True)), 1e-12)
    nrm = turn(raw)
    uv = np.asarray(part.uvs, np.float64).reshape(-1, 2)
    rows = np.concatenate([pos, nrm, uv], 1).astype('<f4')
    unique, first, inverse = np.unique(rows.view(np.dtype((np.void, rows.dtype.itemsize * rows.shape[1]))).ravel(),
                                       return_index=True, return_inverse=True)
    keep = np.sort(first)
    remap = np.empty(len(first), np.int64)
    remap[np.argsort(first)] = np.arange(len(first))
    index = remap[inverse.reshape(-1)]
    verts = rows[keep].astype(np.float64)
    faces = index.reshape(-1, 3)[:, [0, 2, 1]]
    return verts, _unique_faces(faces)


def _unique_faces(faces):
    if not len(faces):
        return faces
    shift = faces.argmin(1)
    rows = np.arange(len(faces))[:, None]
    canon = faces[rows, (shift[:, None] + np.arange(3)) % 3]
    _, first = np.unique(canon, axis=0, return_index=True)
    return faces[np.sort(first)]


def _strings(names):
    table, offsets = bytearray(b'\0'), {'': 0}
    for name in names:
        if name not in offsets:
            offsets[name] = len(table)
            table += name.encode('ascii') + b'\0'
    return bytes(table), offsets


def write(chunk, folder, model_dir, material_dir, snap):
    meshes, materials = [], []
    for part in chunk.parts:
        name = part.material.rsplit('/', 1)[-1]
        verts, faces = _mesh(part, chunk.origin, snap)
        if name in materials:
            i = materials.index(name)
            v0, f0 = meshes[i]
            meshes[i] = (np.concatenate([v0, verts]), np.concatenate([f0, faces + len(v0)]))
        else:
            materials.append(name)
            meshes.append((verts, faces))
    total = sum(len(v) for v, _ in meshes)
    if total > MAX_VERTICES or any(len(v) > MAX_VERTICES for v, _ in meshes):
        raise TooBig(f'{chunk.name}: {total} vertices')
    all_pos = np.concatenate([v[:, :3] for v, _ in meshes])
    lo, hi = all_pos.min(0), all_pos.max(0)
    model_name = f'{model_dir}/{chunk.name}.mdl'
    cd = material_dir.replace('/', '\\') + '\\'
    table, off = _strings([model_name, 'concrete', 'static_prop', 'default', '@idle', 'idle', 'body', *materials, cd])

    n_mesh, n_tex = len(meshes), len(materials)
    mesh_start = MODEL + MODEL_SIZE
    tex_start = mesh_start + MESH_SIZE * n_mesh
    cd_start = tex_start + TEXTURE_SIZE * n_tex
    skin_start = cd_start + 4
    strings = skin_start + ((2 * n_tex + 3) // 4) * 4
    length = (strings + len(table) + 3) // 4 * 4

    digest = hashlib.sha256()
    for v, f in meshes:
        digest.update(v.astype('<f4').tobytes())
        digest.update(f.astype('<u2').tobytes())
    digest.update(model_name.encode())
    checksum = struct.unpack('<i', digest.digest()[:4])[0]

    out = bytearray(length)
    out[HEADER:BODYPART] = FIXED
    centre = (lo + hi) / 2
    struct.pack_into('<4sii64si', out, 0, b'IDST', 48, checksum, model_name.encode('ascii'), length)
    struct.pack_into('<18f', out, 80, 0, 0, 0, *centre, *lo, *hi, 0, 0, 0, 0, 0, 0)
    s = lambda name, base: strings + off[name] - base
    fields = [17, 1, BONE, 0, HITBOXSET, 1, HITBOXSET, 1, ANIM, 1, SEQ, 0, 0, n_tex, tex_start, 1, cd_start,
              n_tex, 1, skin_start, 1, BODYPART, 0, HITBOXSET, 0, BODYPART, BODYPART, 0, mesh_start, 0, mesh_start,
              0, mesh_start, 0, mesh_start, 0, mesh_start, 0, mesh_start, strings + off['concrete'], strings, 0, 0,
              mesh_start]
    struct.pack_into(f'<{len(fields)}i', out, 152, *fields)
    o = 152 + 4 * len(fields)
    struct.pack_into('<fiiiiiiiiiii', out, o, 1.0, 1, 0, tex_start, 0, strings, 0, tex_start, 0, 960, 0, 0)
    o += 48 + 4
    struct.pack_into('<iiifiii', out, o, 0, 0, mesh_start, 0.0, 0, HDR2, 0)

    struct.pack_into('<i', out, HDR2 + 4, strings)
    struct.pack_into('<i', out, HDR2 + 20, s(model_name, HDR2))
    struct.pack_into('<i', out, BONE, s('static_prop', BONE))
    struct.pack_into('<i', out, BONE + 176, s('concrete', BONE))
    struct.pack_into('<i', out, HITBOXSET, s('default', HITBOXSET))
    struct.pack_into('<6f', out, HITBOX + 8, *lo, *hi)
    struct.pack_into('<i', out, HITBOX + 32, s('', HITBOX))
    struct.pack_into('<i', out, ANIM + 4, s('@idle', ANIM))
    struct.pack_into('<ii', out, SEQ + 4, s('idle', SEQ), s('', SEQ))
    struct.pack_into('<6f', out, SEQ + 32, *lo, *hi)

    struct.pack_into('<iiii', out, BODYPART, s('body', BODYPART), 1, 1, MODEL - BODYPART)
    name = f'{chunk.name}.smd'.encode('ascii')[:63]
    struct.pack_into('<64sif', out, MODEL, name, 0, 0.0)
    struct.pack_into('<iiiiiiiiii', out, MODEL + 72, n_mesh, mesh_start - MODEL, total, 0, 0, 0, 0, 0,
                     tex_start - MODEL, 0)
    first = 0
    for i, (v, _) in enumerate(meshes):
        base = mesh_start + MESH_SIZE * i
        struct.pack_into('<iiiiiiiii3fi8i', out, base, i, MODEL - base, len(v), first, 0, 0, 0, 0, i, 0.0, 0.0, 0.0, 0,
                         *([len(v)] * 8))
        first += len(v)
    for i, mat in enumerate(materials):
        base = tex_start + TEXTURE_SIZE * i
        struct.pack_into('<i', out, base, s(mat, base))
    struct.pack_into('<i', out, cd_start, strings + off[cd])
    struct.pack_into(f'<{n_tex}h', out, skin_start, *range(n_tex))
    out[strings:strings + len(table)] = table

    vvd = _vvd(meshes, checksum)
    vtx = _vtx(meshes, checksum)
    stem = Path(folder) / chunk.name
    stem.with_suffix('.mdl').write_bytes(bytes(out))
    stem.with_suffix('.vvd').write_bytes(vvd)
    stem.with_name(chunk.name + '.dx90.vtx').write_bytes(vtx)
    stem.with_name(chunk.name + '.dx80.vtx').write_bytes(vtx)


def _vvd(meshes, checksum):
    verts = np.concatenate([v for v, _ in meshes])
    tans = np.concatenate([_tangents(v[:, :3], v[:, 3:6], v[:, 6:8], f) for v, f in meshes])
    n = len(verts)
    head = struct.pack('<4siii8iiiii', b'IDSV', 4, checksum, 1, *([n] * 8), 0, 64, 64, 64 + n * VVD_VERTEX)
    rec = np.zeros(n, np.dtype([('w', '<f4', 3), ('b', 'u1', 3), ('nb', 'u1'), ('p', '<f4', 3), ('n', '<f4', 3),
                                ('uv', '<f4', 2)]))
    rec['w'][:, 0] = 1.0
    rec['nb'] = 1
    rec['p'], rec['n'], rec['uv'] = verts[:, :3], verts[:, 3:6], verts[:, 6:8]
    return head + rec.tobytes() + tans.astype('<f4').tobytes()


def _vtx(meshes, checksum):
    n_mesh = len(meshes)
    header, body_part, model, lod = 36, 8, 8, 12
    mesh_at = header + body_part + model + lod
    group_at = mesh_at + 9 * n_mesh
    strip_at = group_at + 25 * n_mesh
    vert_at = strip_at + 27 * n_mesh
    index_at = vert_at + 9 * sum(len(v) for v, _ in meshes)
    changes_at = index_at + 2 * sum(3 * len(f) for _, f in meshes)
    repl_at = changes_at + 8 * n_mesh
    out = bytearray(repl_at + 8)
    struct.pack_into('<iiHHiiiiii', out, 0, 7, 24, 53, 9, 3, checksum, 1, repl_at, 1, header)
    struct.pack_into('<ii', out, header, 1, body_part)
    struct.pack_into('<ii', out, header + body_part, 1, model)
    struct.pack_into('<iif', out, header + body_part + model, n_mesh, lod, 0.0)
    vo, io = vert_at, index_at
    for i, (v, f) in enumerate(meshes):
        m, g, st = mesh_at + 9 * i, group_at + 25 * i, strip_at + 27 * i
        struct.pack_into('<iiB', out, m, 1, g - m, 0)
        struct.pack_into('<iiiiiiB', out, g, len(v), vo - g, 3 * len(f), io - g, 1, st - g, HW_SKINNED)
        struct.pack_into('<iiiihBii', out, st, 3 * len(f), 0, len(v), 0, 0, TRILIST, 0, changes_at + 8 * i - st)
        rec = np.zeros(len(v), np.dtype([('w', 'u1', 3), ('nb', 'u1'), ('id', '<u2'), ('b', 'i1', 3)]))
        rec['w'] = (0, 1, 2)
        rec['id'] = np.arange(len(v))
        out[vo:vo + rec.nbytes] = rec.tobytes()
        vo += rec.nbytes
        idx = f.astype('<u2').tobytes()
        out[io:io + len(idx)] = idx
        io += len(idx)
    return bytes(out)
