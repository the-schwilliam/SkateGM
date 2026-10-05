import os
from dataclasses import dataclass, field

import hashlib
from pathlib import Path

import numpy as np
from PIL import Image

from . import bake, tone

DIFFUSE_FLIP_V = False
DECAL_LIFT = 1.0 / 39.3701
LIMIT = 15800.0
TEXEL_BUDGET = 80 * 1024 * 1024
MIN_PAGE = 128


@dataclass
class SourceTexture:
    name: str
    rgba: np.ndarray
    alpha: bool = False
    normal_map: bool = False
    sky: bool = False


@dataclass
class SourceMaterial:
    name: str
    shader: str
    params: dict = field(default_factory=dict)
    surfaceprop: str = 'concrete'


@dataclass
class SourceMesh:
    material: str
    positions: np.ndarray
    normals: np.ndarray
    uvs: np.ndarray
    faces: np.ndarray
    colours: np.ndarray = None


@dataclass
class Surfaces:
    textures: dict = field(default_factory=dict)
    materials: dict = field(default_factory=dict)
    meshes: list = field(default_factory=list)


def _mode(material):
    if 'tree' in material.shader:
        return 'foliage'
    if material.alpha_mode:
        return 'cutout'
    return 'opaque'


def _alpha_params(mode, cutoff):
    if mode in ('foliage', 'cutout'):
        params = {'$alphatest': 1, '$alphatestreference': round(cutoff, 3)}
        if mode == 'foliage':
            params['$nocull'] = 1
        return params
    return {}


class Builder:
    def __init__(self, scene, frame, prefix, workers=None, report=print, cache=None, tag='', budget=None,
                 scenery_cap=None, vertex_lighting=False, light_detail=None):
        self.scene = scene
        self.vertex_lighting = vertex_lighting
        self.light_detail = light_detail
        self.tag = tag
        self.budget = budget or TEXEL_BUDGET
        self.scenery_cap = scenery_cap or bake.SCENERY_SIZE
        self.frame = frame
        self.prefix = prefix
        self.workers = workers
        self.report = report
        self.out = Surfaces()
        self._rgba = {}
        self.cache = Path(cache) if cache else None
        self.dropped = 0

    def rgba(self, texture_id):
        if texture_id not in self._rgba:
            self._rgba[texture_id] = self.scene.textures[texture_id].rgba()
        return self._rgba[texture_id]

    def material_path(self, name):
        return f'{self.prefix}/{name}'

    def texture(self, name, rgba, alpha=False, normal_map=False):
        name = self.tag + name
        if name not in self.out.textures:
            self.out.textures[name] = SourceTexture(self.material_path(name), rgba, alpha, normal_map)
        return self.material_path(name)

    def add_material(self, name, shader, params, surfaceprop='concrete'):
        name = self.tag + name
        if name not in self.out.materials:
            self.out.materials[name] = SourceMaterial(self.material_path(name), shader, params, surfaceprop)
        return self.material_path(name)

    def add_mesh(self, material, mesh, uvs, colours=None):
        positions = self.frame.point(mesh.positions)
        normals = self.frame.direction(mesh.normals)
        faces = mesh.faces
        inside = (np.abs(positions) <= LIMIT).all(1)
        if not inside.all():
            keep = inside[faces].all(1)
            self.dropped += int((~keep).sum())
            faces = faces[keep]
        if len(faces):
            self.out.meshes.append(SourceMesh(material, positions, normals, uvs, faces, colours))

    def diffuse_uvs(self, mesh):
        uv = mesh.uvs.astype(np.float64).copy()
        if DIFFUSE_FLIP_V:
            uv[:, 1] = 1.0 - uv[:, 1]
        return uv

    def build(self):
        scene = self.scene
        baked, direct, lit = {}, [], []
        for mesh in scene.meshes:
            material = scene.materials[mesh.material]
            lm, diffuse = material.textures.get('lightmap'), material.textures.get('diffuse')
            if lm and diffuse and mesh.lightmap_uvs is not None:
                if self.vertex_lighting and not mesh.scenery:
                    lit.append(mesh)
                else:
                    baked.setdefault(lm, []).append(mesh)
            elif diffuse:
                direct.append(mesh)
        self._bake(baked)
        if lit:
            self.report(f'lighting {len(lit)} surfaces per vertex')
        for mesh in lit:
            self._vertex_lit(mesh)
        for mesh in direct:
            self._direct(mesh)
        if self.dropped:
            self.report(f'left out {self.dropped} triangles beyond the map size limit')
        return self.out

    def _bake(self, pages):
        jobs = []
        for lm, meshes in pages.items():
            entries = []
            for mesh in meshes:
                material = self.scene.materials[mesh.material]
                mode = _mode(material)
                decal = material.textures.get('decal')
                use_decal = decal is not None and mesh.decal_uvs is not None
                entries.append(bake.Entry(self.rgba(material.textures['diffuse']),
                                          np.abs(mesh.lightmap_uvs).astype(np.float64), self.diffuse_uvs(mesh),
                                          mesh.faces, mode != 'opaque',
                                          self.rgba(decal) if use_decal else None,
                                          mesh.decal_uvs.astype(np.float64) if use_decal else None))
            cap = bake.MAX_SIZE if any(not m.scenery for m in meshes) else self.scenery_cap
            jobs.append((lm, self.rgba(lm), entries, any(e.alpha for e in entries), cap))
        jobs = self._fit_budget(jobs)
        baked, todo = {}, []
        for job in jobs:
            cached = self._cached(job)
            if cached is not None:
                baked[job[0]] = cached
            else:
                todo.append(job)
        self.report(f'baking {len(todo)} lighting pages ({len(baked)} cached)')
        for page in bake.bake(todo, self.workers):
            self._store(page, next(j for j in todo if j[0] == page.lightmap))
            baked[page.lightmap] = page
        for lm in pages:
            page = baked[lm]
            tex = self.texture('lm_' + page.lightmap[2:], page.rgba, page.alpha)
            for mesh in pages[page.lightmap]:
                material = self.scene.materials[mesh.material]
                mode = _mode(material)
                params = {'$basetexture': tex, '$model': 1}
                params.update(_alpha_params(mode, material.alpha_cutoff))
                name = 'lm_' + page.lightmap[2:] + ('' if mode == 'opaque' else '_' + mode)
                path = self.add_material(name, 'UnlitGeneric', params)
                self.add_mesh(path, mesh, np.abs(mesh.lightmap_uvs).astype(np.float64))

    def _fit_budget(self, jobs):
        sizes = []
        for lm, lightmap, entries, alpha, cap in jobs:
            lh, lw = lightmap.shape[:2]
            scale = bake._scale_for(entries, lw, lh, cap)
            sizes.append([lw * scale, lh * scale])
        total = sum(w * h for w, h in sizes)
        while total > self.budget:
            i = max(range(len(sizes)), key=lambda k: (sizes[k][0] * sizes[k][1], -k))
            w, h = sizes[i]
            if max(w, h) <= MIN_PAGE:
                break
            total -= w * h // 4 * 3
            sizes[i] = [max(1, w // 2), max(1, h // 2)]
        out = []
        for job, (w, h) in zip(jobs, sizes):
            lm, lightmap, entries, alpha, cap = job
            out.append((lm, lightmap, entries, alpha, min(cap, max(w, h))))
        return out

    def _cache_key(self, job):
        lm, lightmap, entries, alpha, cap = job
        h = hashlib.sha256(f'{bake.VERSION}|{lm}|{alpha}|{cap}'.encode())
        for e in entries:
            for array in (e.diffuse, e.lightmap_uv, e.uv, e.faces, e.decal, e.decal_uv):
                if array is not None:
                    h.update(np.ascontiguousarray(array).tobytes())
            h.update(b'1' if e.alpha else b'0')
        return h.hexdigest()[:24]

    def _cached(self, job):
        if not self.cache:
            return None
        path = self.cache / (self._cache_key(job) + '.png')
        if not path.is_file():
            return None
        rgba = np.asarray(Image.open(path).convert('RGBA'))
        return bake.Page(job[0], rgba.shape[1], rgba.shape[0], rgba, job[3])

    def _store(self, page, job):
        if not self.cache:
            return
        self.cache.mkdir(parents=True, exist_ok=True)
        final = self.cache / (self._cache_key(job) + '.png')
        part = final.with_name(f'{final.stem}.{os.getpid()}.part')
        Image.fromarray(page.rgba, 'RGBA').save(part, format='PNG')
        os.replace(part, final)

    def _lightmap(self, texture_id):
        from .vertexlight import Lightmap
        if not hasattr(self, '_lightmaps'):
            self._lightmaps = {}
        if texture_id not in self._lightmaps:
            self._lightmaps[texture_id] = Lightmap(self.rgba(texture_id))
        return self._lightmaps[texture_id]

    def _albedo(self, texture_id):
        if not hasattr(self, '_albedos'):
            self._albedos = {}
        if texture_id not in self._albedos:
            self._albedos[texture_id] = tone.mean_albedo(self.rgba(texture_id))
        return self._albedos[texture_id]

    def _vertex_lit(self, mesh):
        from .scene import Mesh
        from .vertexlight import subdivide
        material = self.scene.materials[mesh.material]
        mode = _mode(material)
        diffuse = material.textures['diffuse']
        decal = material.textures.get('decal') if mesh.decal_uvs is not None else None
        extra = (mesh.decal_uvs,) if decal else ()
        out = subdivide(mesh, self._lightmap(material.textures['lightmap']), self.light_detail, extra)
        positions, uvs, normals, colours, faces = out[:5]
        colours = tone.vertex_light(colours, self._albedo(diffuse))
        if decal:
            self._decal_layer(decal, positions, normals, out[5][0], colours, faces, mesh)
        split = Mesh(mesh.material, positions.astype(np.float32), faces, uvs.astype(np.float32),
                     normals.astype(np.float32), None, mesh.name)
        tex = self.texture('d_' + diffuse[2:], self.rgba(diffuse), mode != 'opaque')
        params = {'$basetexture': tex, '$model': 1}
        params.update(_alpha_params(mode, material.alpha_cutoff))
        name = 'l_' + diffuse[2:] + ('' if mode == 'opaque' else '_' + mode)
        path = self.add_material(name, 'VertexLitGeneric', params)
        self.add_mesh(path, split, self.diffuse_uvs(split), colours)

    def _decal_layer(self, decal, positions, normals, decal_uvs, colours, faces, mesh):
        from .scene import Mesh
        lifted = positions + normals / np.maximum(np.sqrt((normals * normals).sum(1, keepdims=True)), 1e-12) * DECAL_LIFT
        layer = Mesh(mesh.material, lifted.astype(np.float32), faces, decal_uvs.astype(np.float32),
                     normals.astype(np.float32), None, mesh.name)
        tex = self.texture('dl_' + decal[2:], self.rgba(decal), True)
        path = self.add_material('ld_' + decal[2:], 'VertexLitGeneric', {'$basetexture': tex, '$model': 1, '$translucent': 1, '$decal': 1})
        self.add_mesh(path, layer, self.diffuse_uvs(layer), colours)

    def _direct(self, mesh):
        material = self.scene.materials[mesh.material]
        mode = _mode(material)
        diffuse = material.textures['diffuse']
        alpha = mode != 'opaque'
        tex = self.texture('d_' + diffuse[2:], self.rgba(diffuse), alpha)
        emissive = 'incandescent' in material.shader or material.shader == 'unlit'
        params = {'$basetexture': tex, '$model': 1}
        params.update(_alpha_params(mode, material.alpha_cutoff))
        if emissive:
            shader = 'UnlitGeneric'
        else:
            shader = 'VertexLitGeneric'
            normal = material.textures.get('normal')
            if normal:
                params['$bumpmap'] = self.texture('n_' + normal[2:], self.rgba(normal), False, True)
        name = ('e_' if emissive else 'v_') + diffuse[2:] + ('' if mode == 'opaque' else '_' + mode)
        path = self.add_material(name, shader, params)
        self.add_mesh(path, mesh, self.diffuse_uvs(mesh))


def build(scene, frame, prefix, workers=None, report=print, cache=None):
    return Builder(scene, frame, prefix, workers, report, cache).build()
