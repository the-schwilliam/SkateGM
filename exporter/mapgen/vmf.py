import itertools

import numpy as np

SKY = 'TOOLS/TOOLSSKYBOX'
LIMIT = 16000.0


class Vmf:
    def __init__(self):
        self.ids = itertools.count(1)
        self.solids = []
        self.entities = []

    def _side(self, plane, material):
        a, b, c = plane
        p = ' '.join(f'({x:g} {y:g} {z:g})' for x, y, z in (a, b, c))
        return ('\tside\n\t{\n'
                f'\t\t"id" "{next(self.ids)}"\n'
                f'\t\t"plane" "{p}"\n'
                f'\t\t"material" "{material}"\n'
                '\t\t"uaxis" "[1 0 0 0] 0.25"\n'
                '\t\t"vaxis" "[0 -1 0 0] 0.25"\n'
                '\t\t"rotation" "0"\n'
                '\t\t"lightmapscale" "16"\n'
                '\t\t"smoothing_groups" "0"\n'
                '\t}\n')

    def box(self, lo, hi, material):
        x0, y0, z0 = lo
        x1, y1, z1 = hi
        planes = [
            ((x0, y1, z1), (x1, y1, z1), (x1, y0, z1)),
            ((x0, y0, z0), (x1, y0, z0), (x1, y1, z0)),
            ((x0, y1, z1), (x0, y0, z1), (x0, y0, z0)),
            ((x1, y1, z0), (x1, y0, z0), (x1, y0, z1)),
            ((x1, y1, z1), (x0, y1, z1), (x0, y1, z0)),
            ((x1, y0, z0), (x0, y0, z0), (x0, y0, z1)),
        ]
        sides = ''.join(self._side(p, material) for p in planes)
        self.solids.append(f'solid\n{{\n\t"id" "{next(self.ids)}"\n{sides}}}\n')

    def shell(self, lo, hi, thickness=16.0, material=SKY):
        lo = np.maximum(np.asarray(lo, float), -LIMIT + thickness)
        hi = np.minimum(np.asarray(hi, float), LIMIT - thickness)
        t = thickness
        x0, y0, z0 = lo
        x1, y1, z1 = hi
        self.box((x0 - t, y0 - t, z0 - t), (x1 + t, y1 + t, z0), material)
        self.box((x0 - t, y0 - t, z1), (x1 + t, y1 + t, z1 + t), material)
        self.box((x0 - t, y0 - t, z0), (x0, y1 + t, z1), material)
        self.box((x1, y0 - t, z0), (x1 + t, y1 + t, z1), material)
        self.box((x0, y0 - t, z0), (x1, y0, z1), material)
        self.box((x0, y1, z0), (x1, y1 + t, z1), material)

    def entity(self, classname, **keys):
        self.entities.append((classname, keys))

    def convex(self, faces, material):
        points = np.concatenate([np.asarray(f, np.float64) for f in faces])
        centre = points.mean(0)
        materials = material if isinstance(material, (list, tuple)) else [material] * len(faces)
        sides = []
        for face, material in zip(faces, materials):
            a, b, c = (np.asarray(p, np.float64) for p in face[:3])
            if np.dot(np.cross(b - a, c - a), centre - a) < 0:
                b, c = c, b
            p = ' '.join(f'({x:.6f} {y:.6f} {z:.6f})' for x, y, z in (a, b, c))
            sides.append('\t\tside\n\t\t{\n'
                         f'\t\t\t"id" "{next(self.ids)}"\n'
                         f'\t\t\t"plane" "{p}"\n'
                         f'\t\t\t"material" "{material}"\n'
                         '\t\t\t"uaxis" "[1 0 0 0] 0.25"\n'
                         '\t\t\t"vaxis" "[0 -1 0 0] 0.25"\n'
                         '\t\t\t"rotation" "0"\n'
                         '\t\t\t"lightmapscale" "16"\n'
                         '\t\t\t"smoothing_groups" "0"\n'
                         '\t\t}\n')
        return f'\tsolid\n\t{{\n\t\t"id" "{next(self.ids)}"\n{"".join(sides)}\t}}\n'

    def brush_entity(self, classname, solids, **keys):
        self.entities.append((classname, dict(keys, _solids=''.join(solids))))

    def text(self, skyname):
        out = ['versioninfo\n{\n\t"editorversion" "400"\n\t"mapversion" "1"\n\t"formatversion" "100"\n}\n',
               'world\n{\n', f'\t"id" "{next(self.ids)}"\n', '\t"mapversion" "1"\n', '\t"classname" "worldspawn"\n',
               f'\t"skyname" "{skyname}"\n', '\t"detailmaterial" "detail/detailsprites"\n',
               '\t"detailvbsp" "detail.vbsp"\n']
        out += self.solids
        out.append('}\n')
        for classname, keys in self.entities:
            out.append(f'entity\n{{\n\t"id" "{next(self.ids)}"\n\t"classname" "{classname}"\n')
            for k, v in keys.items():
                if k == '_solids':
                    continue
                if isinstance(v, (tuple, list, np.ndarray)):
                    v = ' '.join(f'{float(x):g}' for x in v)
                out.append(f'\t"{k}" "{v}"\n')
            out.append(keys.get('_solids', ''))
            out.append('}\n')
        return ''.join(out)
