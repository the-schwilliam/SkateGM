import numpy as np

from .scene import Collision, Mesh, Rail, Scene


class Area:
    def __init__(self, corners=(), y_range=(-1.0e9, 1.0e9)):
        self.corners = np.asarray(corners, np.float64).reshape(-1, 2) if len(corners) else None
        self.y_range = y_range
        if self.corners is not None and _signed_area(self.corners) < 0:
            self.corners = self.corners[::-1].copy()

    def contains(self, points):
        p = np.asarray(points, np.float64)
        inside = (p[:, 1] >= self.y_range[0]) & (p[:, 1] <= self.y_range[1])
        if self.corners is None:
            return inside
        for a, b in self.edges():
            inside &= _side(p, a, b) >= 0
        return inside

    def edges(self):
        c = self.corners
        return [(c[i], c[(i + 1) % len(c)]) for i in range(len(c))]


def _signed_area(c):
    x, z = c[:, 0], c[:, 1]
    return 0.5 * float(np.sum(x * np.roll(z, -1) - np.roll(x, -1) * z))


def _side(points, a, b):
    return (b[0] - a[0]) * (points[..., 2] - a[1]) - (b[1] - a[1]) * (points[..., 0] - a[0])


def _clip_polygon(poly, a, b, keep_inside):
    out = []
    n = len(poly)
    for i in range(n):
        cur, nxt = poly[i], poly[(i + 1) % n]
        dc, dn = _side(cur[0], a, b), _side(nxt[0], a, b)
        if not keep_inside:
            dc, dn = -dc, -dn
        if dc >= 0:
            out.append(cur)
        if (dc >= 0) != (dn >= 0):
            t = dc / (dc - dn)
            out.append(tuple(c + (n_ - c) * t if c is not None else None for c, n_ in zip(cur, nxt)))
    return out


def _fan(poly):
    return [(poly[0], poly[i], poly[i + 1]) for i in range(1, len(poly) - 1)]


def _pieces(tri, area, inside):
    if inside:
        poly = list(tri)
        for a, b in area.edges():
            poly = _clip_polygon(poly, a, b, True)
            if len(poly) < 3:
                return []
        return _fan(poly)
    pieces, rest = [], list(tri)
    for a, b in area.edges():
        outside = _clip_polygon(rest, a, b, False)
        if len(outside) >= 3:
            pieces += _fan(outside)
        rest = _clip_polygon(rest, a, b, True)
        if len(rest) < 3:
            break
    return pieces


def _attributes(mesh):
    return [a for a in (mesh.positions, mesh.uvs, mesh.normals, mesh.lightmap_uvs, mesh.decal_uvs)]


def _classify(tris, area, inside):
    flags = np.stack([area.contains(tris[:, k]) for k in range(3)], 1)
    lo, hi = area.corners.min(0), area.corners.max(0)
    overlaps = ((tris[:, :, 0].max(1) >= lo[0]) & (tris[:, :, 0].min(1) <= hi[0]) &
                (tris[:, :, 2].max(1) >= lo[1]) & (tris[:, :, 2].min(1) <= hi[1]))
    all_in, none_in = flags.all(1), ~flags.any(1)
    straddle = ~all_in & ~(none_in & ~overlaps)
    return (all_in if inside else none_in & ~overlaps), straddle


def clip_mesh(mesh, area, inside=True, scenery=None):
    if area.corners is None:
        return mesh if inside else None
    tris = mesh.positions[mesh.faces].astype(np.float64)
    whole, straddle = _classify(tris, area, inside)
    attrs = _attributes(mesh)
    out = [[] for _ in attrs]
    for k in np.flatnonzero(whole):
        for j, a in enumerate(attrs):
            if a is not None:
                out[j].append(a[mesh.faces[k]].astype(np.float64))
    for k in np.flatnonzero(straddle):
        face = mesh.faces[k]
        tri = [tuple(None if a is None else a[face[v]].astype(np.float64) for a in attrs) for v in range(3)]
        for piece in _pieces(tri, area, inside):
            for j, a in enumerate(attrs):
                if a is not None:
                    out[j].append(np.stack([piece[v][j] for v in range(3)]))
    if not out[0]:
        return None
    arrays = [None if attrs[j] is None else np.asarray(out[j]).reshape(-1, attrs[j].shape[1]).astype(np.float32)
              for j in range(len(attrs))]
    count = len(arrays[0])
    faces = np.arange(count, dtype=np.int64).reshape(-1, 3)
    return Mesh(mesh.material, arrays[0], faces, arrays[1], arrays[2], arrays[3], mesh.name, arrays[4],
                mesh.scenery if scenery is None else scenery)


def clip_triangles(triangles, surfaces, area):
    if area.corners is None or not len(triangles):
        return triangles, surfaces
    tris = triangles.astype(np.float64)
    whole, straddle = _classify(tris, area, True)
    keep = [tris[whole]]
    keep_s = [surfaces[whole]]
    straddle = np.flatnonzero(straddle)
    extra, extra_s = [], []
    for k in straddle:
        for piece in _pieces([(p,) for p in tris[k]], area, True):
            extra.append(np.stack([v[0] for v in piece]))
            extra_s.append(surfaces[k])
    if extra:
        keep.append(np.asarray(extra))
        keep_s.append(np.asarray(extra_s, surfaces.dtype))
    return np.concatenate(keep).astype(np.float32), np.concatenate(keep_s)


def _rails(rails, area):
    out = []
    for rail in rails:
        inside = area.contains(rail.points)
        run = []
        for point, ok in zip(rail.points, inside):
            if ok:
                run.append(point)
            elif run:
                if len(run) >= 2:
                    out.append(Rail(np.asarray(run, np.float32), False))
                run = []
        if len(run) >= 2:
            out.append(Rail(np.asarray(run, np.float32), rail.closed and inside.all()))
    return out


def _subset(scene, meshes, collision, rails):
    used = {m.material for m in meshes}
    return Scene(scene.root, scene.district, scene.textures, {k: v for k, v in scene.materials.items() if k in used},
                 meshes, collision, rails)


def crop(scene, area):
    meshes = [m for m in (clip_mesh(m, area) for m in scene.meshes) if m is not None]
    tris, surf = clip_triangles(scene.collision.triangles, scene.collision.surfaces, area)
    return _subset(scene, meshes, Collision(tris, surf), _rails(scene.rails, area))


def ring(scene, outer, inner):
    out = []
    for mesh in scene.meshes:
        part = clip_mesh(mesh, outer)
        if part is not None:
            part = clip_mesh(part, inner, inside=False, scenery=True)
        if part is not None:
            out.append(part)
    return out


def outside(scene, area):
    return [m for m in (clip_mesh(mesh, area, inside=False, scenery=True) for mesh in scene.meshes) if m is not None]
