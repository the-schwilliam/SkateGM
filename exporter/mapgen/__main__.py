import argparse
import dataclasses
import sys
import traceback
from pathlib import Path

from . import regions
from .build import build
from .sourcetools import find_gmod


def main(argv=None):
    ap = argparse.ArgumentParser(prog='mapgen', description='Build Skate 3 areas into Garry\'s Mod maps')
    sub = ap.add_subparsers(dest='command', required=True)
    b = sub.add_parser('build')
    b.add_argument('--region', action='append', help='region name (default: all)')
    b.add_argument('--game', required=True, help='extracted Skate 3 folder (holds data/)')
    b.add_argument('--gmod', default=None)
    b.add_argument('--out', required=True, help='folder for the .bsp files')
    b.add_argument('--work', required=True, help='scratch folder (decode cache, build files)')
    b.add_argument('--workers', type=int, default=None)
    b.add_argument('--keep', action='store_true')
    b.add_argument('--fast', action='store_true')
    b.add_argument('--baked', action='store_true', help='bake lighting into textures instead of per-vertex lighting')
    b.add_argument('--lite', action='store_true', help='coarser lighting split (map name + _lite)')
    b.add_argument('--no-skybox', action='store_true', help='leave out the 3D skybox (map name + _nosky)')
    sub.add_parser('list')
    o = sub.add_parser('overhead', help='top-down pictures of districts, with a coordinate grid')
    o.add_argument('--game', required=True)
    o.add_argument('--work', required=True)
    o.add_argument('--out', required=True)
    o.add_argument('--district', action='append', help='e.g. DIST_University (default: the three boroughs)')
    o.add_argument('--scale', type=float, default=2.0, help='pixels per metre')
    a = ap.parse_args(argv)
    if a.command == 'overhead':
        from .overhead import make
        for f in make(a.game, a.work, a.district or ['DIST_University', 'DIST_DownTown', 'DIST_Industrial'], a.out, a.scale):
            print(f)
        return 0
    if a.command == 'list':
        for r in regions.REGIONS:
            print(f'{r.map_name}\t{r.title}\t{r.district}')
        return 0
    gmod = a.gmod or find_gmod()
    if not gmod:
        sys.exit('Garry\'s Mod not found: pass --gmod')
    chosen = [regions.by_name(n) for n in a.region] if a.region else regions.REGIONS
    if a.baked:
        chosen = [dataclasses.replace(r, vertex_lighting=False) for r in chosen]
    if a.lite:
        chosen = [dataclasses.replace(r, light_detail=regions.LITE, name=r.name + '_lite') for r in chosen]
    if a.no_skybox:
        chosen = [dataclasses.replace(r, skybox=False, name=r.name + '_nosky') for r in chosen]
    failed = []
    for region in chosen:
        try:
            final, _, shots = build(region, Path(a.game), Path(gmod), Path(a.out), Path(a.work), workers=a.workers,
                                    keep=a.keep, fast=a.fast)
        except Exception:
            traceback.print_exc()
            failed.append(region.map_name)
            continue
        final.with_suffix('.views.txt').write_text(shots)
    if failed:
        print('failed: ' + ', '.join(failed))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
