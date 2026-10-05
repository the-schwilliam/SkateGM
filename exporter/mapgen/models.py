import os
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .mathutil import norm as length
from .sourcetools import ToolError

CELL = 1536.0
RENDER_CELL = 8192.0
MAX_TRIANGLES = 25000
MAX_MATERIALS = 30
MAX_CONVEX = 400
PIECE_THICKNESS = 3.0
PIECE_GAP = 0.03


@dataclass
class Part:
    material: str
    positions: np.ndarray
    normals: np.ndarray
    uvs: np.ndarray
    colours: np.ndarray = None


@dataclass
class Chunk:
    name: str
    origin: np.ndarray
    parts: list = field(default_factory=list)
    collision: np.ndarray = None
    mass: float = 0.0

    def triangle_count(self):
        return sum(len(p.positions) for p in self.parts)


def _cell_keys(centroids, cell):
    return [tuple(k) for k in np.floor(centroids[:, :2] / cell).astype(np.int64)]


def _split_meshes(meshes, cell):
    cells = {}
    for mesh in meshes:
        tri_pos = mesh.positions[mesh.faces]
        tri_nrm = mesh.normals[mesh.faces]
        tri_uv = mesh.uvs[mesh.faces]
        tri_col = mesh.colours[mesh.faces] if mesh.colours is not None else np.full(tri_pos.shape, np.nan)
        keys = np.floor(tri_pos.mean(1) / cell).astype(np.int64)
        order = np.lexsort((keys[:, 2], keys[:, 1], keys[:, 0]))
        keys, tri_pos, tri_nrm, tri_uv, tri_col = keys[order], tri_pos[order], tri_nrm[order], tri_uv[order], tri_col[order]
        if not len(keys):
            continue
        breaks = np.flatnonzero(np.any(np.diff(keys, axis=0) != 0, axis=1)) + 1
        for start, end in zip(np.r_[0, breaks], np.r_[breaks, len(keys)]):
            key = tuple(keys[start])
            cells.setdefault(key, {}).setdefault(mesh.material, []).append(
                (tri_pos[start:end], tri_nrm[start:end], tri_uv[start:end], tri_col[start:end]))
    return cells


def _merge(pieces):
    return [np.concatenate([p[i] for p in pieces]) for i in range(4)]


def build_chunks(surfaces, collision_triangles, prefix, cell=CELL, render_cell=RENDER_CELL):
    cells = {('r',) + k: v for k, v in _split_meshes(surfaces.meshes, render_cell).items()}
    col_cells = {}
    if collision_triangles is not None and len(collision_triangles):
        keys = np.floor(collision_triangles.mean(1) / cell).astype(np.int64)
        for key in set(map(tuple, keys)):
            col_cells[('c',) + key] = collision_triangles[np.all(keys == key, axis=1)]
    chunks = []
    for key in sorted(set(cells) | set(col_cells)):
        origin = np.zeros(3)
        current = None
        for material, pieces in sorted(cells.get(key, {}).items()):
            pos, nrm, uv, col = _merge(pieces)
            start = 0
            while start < len(pos):
                if current is None or len(current.parts) >= MAX_MATERIALS or current.triangle_count() >= MAX_TRIANGLES:
                    current = Chunk(f'{prefix}_{len(chunks):03d}', origin)
                    chunks.append(current)
                room = MAX_TRIANGLES - current.triangle_count()
                take = min(room, len(pos) - start)
                colours = col[start:start + take]
                current.parts.append(Part(material, pos[start:start + take], nrm[start:start + take], uv[start:start + take],
                                          None if np.isnan(colours).all() else colours))
                start += take
        tris = col_cells.get(key)
        if tris is not None and len(tris):
            for start in range(0, len(tris), MAX_CONVEX):
                holder = Chunk(f'{prefix}_{len(chunks):03d}', origin)
                holder.collision = tris[start:start + MAX_CONVEX]
                chunks.append(holder)
    for chunk in chunks:
        chunk.origin = geometry_centre(chunk)
    return chunks


def geometry_centre(chunk):
    points = [p.positions.reshape(-1, 3) for p in chunk.parts]
    if chunk.collision is not None and len(chunk.collision):
        points.append(chunk.collision.reshape(-1, 3))
    if not points:
        return chunk.origin
    allp = np.concatenate(points)
    return np.round((allp.min(0) + allp.max(0)) / 2)


def _vertex(f, p, n, uv):
    f.write(f'0 {p[0]:.4f} {p[1]:.4f} {p[2]:.4f} {n[0]:.4f} {n[1]:.4f} {n[2]:.4f} {uv[0]:.6f} {1.0 - uv[1]:.6f}\n')


SMD_HEAD = 'version 1\nnodes\n0 "root" -1\nend\nskeleton\ntime 0\n0 0 0 0 0 0 0\nend\ntriangles\n'


def _normalised(v):
    return v / np.maximum(length(v), 1e-12)[..., None]


VERTEX_GRID = 0.25


def snap(points):
    return np.round(np.asarray(points, np.float64) / VERTEX_GRID) * VERTEX_GRID


def write_reference(chunk, path):
    with open(path, 'w', encoding='ascii', newline='\n') as f:
        f.write(SMD_HEAD)
        for part in chunk.parts:
            name = part.material.rsplit('/', 1)[-1]
            pos = snap(part.positions - chunk.origin)
            nrm = _normalised(part.normals)
            for t in range(len(pos)):
                f.write(name + '\n')
                for i in (0, 1, 2):
                    _vertex(f, pos[t, i], nrm[t, i], part.uvs[t, i])
        f.write('end\n')


MIN_ALTITUDE = 2.0
COLLISION_TIMEOUT = 180


def prism(tri, thickness=PIECE_THICKNESS, gap=PIECE_GAP):
    a, b, c = tri
    n = np.cross(b - a, c - a)
    area = float(length(n))
    longest = max(float(length(b - a)), float(length(c - b)), float(length(a - c)))
    if area < 1e-6 or area / max(longest, 1e-6) < MIN_ALTITUDE:
        return None
    n = n / area
    centre = (a + b + c) / 3
    top = [p + (centre - p) * min(0.5, gap / max(float(length(centre - p)), 1e-6)) for p in (a, b, c)]
    bottom = [p - n * thickness for p in top]
    return top, bottom


BRUSH_EDGE = 2048.0
BRUSH_ALTITUDE = 16.0
BRUSH_MAX_COS = 0.985


def split_brushes(triangles, limit=BRUSH_EDGE):
    if triangles is None or not len(triangles):
        return triangles, np.zeros((0, 3, 3), np.float32)
    tris = np.asarray(triangles, np.float64)
    edges = np.stack([tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 1], tris[:, 0] - tris[:, 2]], 1)
    longest = length(edges).max(1)
    area2 = length(np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0]))
    sides = length(edges)
    cos = []
    for k in range(3):
        a, b = -edges[:, (k + 2) % 3], edges[:, k]
        cos.append((a * b).sum(1) / np.maximum(sides[:, (k + 2) % 3] * sides[:, k], 1e-12))
    sharpest = np.max(np.stack(cos, 1), axis=1)
    big = (longest > limit) & (area2 / np.maximum(longest, 1e-9) >= BRUSH_ALTITUDE) & (sharpest <= BRUSH_MAX_COS)
    return triangles[~big], triangles[big]


def prism_faces(tri):
    shape = prism(np.asarray(tri, np.float64))
    if shape is None:
        return None
    (a, b, c), (d, e, g) = shape
    return [(a, b, c), (g, e, d), (a, d, e, b), (b, e, g, c), (c, g, d, a)]


def write_collision(chunk, path):
    with open(path, 'w', encoding='ascii', newline='\n') as f:
        f.write(SMD_HEAD)
        zero = np.array([0.0, 0.0, 1.0])
        uv = (0.0, 0.0)

        def face(p, q, r):
            f.write('phys\n')
            for v in (p, r, q):
                _vertex(f, v, zero, uv)

        for tri in chunk.collision - chunk.origin:
            shape = prism(tri.astype(np.float64))
            if shape is None:
                continue
            (a, b, c), (d, e, g) = shape
            face(a, b, c)
            face(d, g, e)
            for p, q, r, s in ((a, d, e, b), (b, e, g, c), (c, g, d, a)):
                face(p, q, r)
                face(p, r, s)
        f.write('end\n')


def write_hull(chunk, path):
    with open(path, 'w', encoding='ascii', newline='\n') as f:
        f.write(SMD_HEAD)
        up = np.array([0.0, 0.0, 1.0])
        for part in chunk.parts:
            pos = part.positions - chunk.origin
            for t in range(len(pos)):
                f.write('phys\n')
                for i in (0, 1, 2):
                    _vertex(f, pos[t, i], up, (0.0, 0.0))
        f.write('end\n')


def physics_props(templates, prefix):
    chunks = []
    for i, (key, meshes) in enumerate(templates):
        chunk = Chunk(f'{prefix}_{i:02d}', np.zeros(3))
        for mesh in meshes:
            chunk.parts.append(Part(mesh.material, mesh.positions[mesh.faces], mesh.normals[mesh.faces],
                                    mesh.uvs[mesh.faces]))
        chunks.append((key, chunk))
    return chunks


def write_qc(chunk, folder, model_dir, material_dir, nodraw_body):
    qc = Path(folder) / (chunk.name + '.qc')
    if chunk.mass > 0:
        write_reference(chunk, Path(folder) / (chunk.name + '.smd'))
        write_hull(chunk, Path(folder) / (chunk.name + '_phys.smd'))
        lines = [f'$modelname "{model_dir}/{chunk.name}.mdl"', '$surfaceprop "metal"', f'$cdmaterials "{material_dir}"',
                 f'$body body "{chunk.name}.smd"', f'$sequence idle "{chunk.name}.smd"',
                 f'$collisionmodel "{chunk.name}_phys.smd" {{\n\t$mass {chunk.mass:g}\n}}']
        qc.write_text('\n'.join(lines) + '\n', encoding='ascii')
        return qc
    lines = [f'$modelname "{model_dir}/{chunk.name}.mdl"', '$staticprop', '$surfaceprop "concrete"',
             f'$cdmaterials "{material_dir}"']
    if chunk.parts:
        write_reference(chunk, Path(folder) / (chunk.name + '.smd'))
        lines += [f'$body body "{chunk.name}.smd"', f'$sequence idle "{chunk.name}.smd"']
    else:
        lines += [f'$body body "{nodraw_body}"', f'$sequence idle "{nodraw_body}"']
    if chunk.collision is not None and len(chunk.collision):
        write_collision(chunk, Path(folder) / (chunk.name + '_phys.smd'))
        lines.append(f'$collisionmodel "{chunk.name}_phys.smd" {{\n\t$concave\n\t$maxconvexpieces {MAX_CONVEX + 24}\n}}')
    qc.write_text('\n'.join(lines) + '\n', encoding='ascii')
    return qc


def write_nodraw_body(folder):
    path = Path(folder) / 'nodraw.smd'
    with open(path, 'w', encoding='ascii', newline='\n') as f:
        f.write(SMD_HEAD)
        f.write('nodraw\n')
        for p in ((0, 0, 0), (1, 0, 0), (0, 1, 0)):
            f.write(f'0 {p[0]} {p[1]} {p[2]} 0 0 1 0 0\n')
        f.write('end\n')
    return path.name


def _cost(qc):
    folder, stem = Path(qc).parent, Path(qc).stem
    return sum((folder / f'{stem}{tail}').stat().st_size for tail in ('.smd', '_phys.smd') if (folder / f'{stem}{tail}').is_file())


def compile_models(tools, qcs, report=print, workers=None):
    workers = workers or os.cpu_count() or 4
    report(f'compiling {len(qcs)} models')
    failed = []
    times = []

    def one(qc):
        start = time.perf_counter()
        has_collision = Path(qc).with_name(Path(qc).stem + '_phys.smd').is_file()
        try:
            out = tools.run('studiomdl', ['-nop4', '-game', tools.game, qc], timeout=COLLISION_TIMEOUT if has_collision else 3600,
                            check=lambda out: 'ERROR' not in out.upper() or 'Completed' in out)
        except subprocess.TimeoutExpired:
            out = 'Error with convex elements'
        except ToolError as error:
            if 'IVP Failed' not in str(error) or not Path(qc).with_name(Path(qc).stem + '_phys.smd').is_file():
                raise
            out = 'Error with convex elements'
        if 'Error with convex elements' in out:
            failed.append(Path(qc).stem)
        times.append((time.perf_counter() - start, Path(qc).stem))

    with ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(one, sorted(qcs, key=_cost, reverse=True)))
    slow = sorted(times, reverse=True)[:3]
    report('slowest: ' + ', '.join(f'{name} {t:.1f} s' for t, name in slow) + (f'; {len(failed)} to split' if failed else ''))
    return failed


def visual_only(chunk):
    return chunk.parts and (chunk.collision is None or not len(chunk.collision)) and chunk.mass <= 0


def write_direct(chunks, out_dir, model_dir, material_dir, report=print):
    from . import mdlwrite
    out_dir.mkdir(parents=True, exist_ok=True)
    rest, written = [], []
    for chunk in chunks:
        if os.environ.get('MAPGEN_STUDIOMDL') or not visual_only(chunk):
            rest.append(chunk)
            continue
        try:
            mdlwrite.write(chunk, out_dir, model_dir, material_dir, snap)
            written.append(chunk)
        except mdlwrite.TooBig:
            rest.append(chunk)
    if written:
        report(f'wrote {len(written)} models directly, {len(rest)} through studiomdl')
    return written, rest


def compile_all(tools, chunks, folder, model_dir, material_dir, report=print):
    nodraw = write_nodraw_body(folder)
    done, pending = write_direct(chunks, Path(tools.game) / 'models' / model_dir, model_dir, material_dir, report)
    while pending:
        by_name = {c.name: c for c in pending}
        failed = compile_models(tools, [write_qc(c, folder, model_dir, material_dir, nodraw) for c in pending], report)
        done += [c for c in pending if c.name not in failed]
        pending = []
        for name in failed:
            chunk = by_name[name]
            for stale in (Path(tools.game) / 'models' / model_dir).glob(name + '.*'):
                stale.unlink()
            tris = chunk.collision
            if len(tris) <= 1:
                report(f'dropping an unbuildable collision triangle in {name}')
                continue
            half = len(tris) // 2
            order = np.argsort(tris.mean(1)[:, 0] + tris.mean(1)[:, 1] * 1e-3)
            for i, part in enumerate((order[:half], order[half:])):
                piece = Chunk(f'{name}_{i}', chunk.origin)
                piece.collision = tris[part]
                piece.origin = geometry_centre(piece)
                pending.append(piece)
            if chunk.parts:
                visual = Chunk(f'{name}_v', chunk.origin, chunk.parts)
                pending.append(visual)
    return done
