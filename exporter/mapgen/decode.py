import json
import shutil
import struct
import sys
from pathlib import Path

from . import EXPORTER, MAP_TOOLS, UTT

CACHE_FORMAT = 'skategm-mapgen-2'
PROXIES = {'DIST_University': 'University_100_Proxy', 'DIST_DownTown': 'Downtown_100_Proxy',
           'DIST_Industrial': 'Industrial_100_Proxy'}
EMPTY_ATOC = b'ATOC' + struct.pack('>I', 3) + bytes(16)


def _imports():
    for path in (EXPORTER, MAP_TOOLS):
        if str(path) not in sys.path:
            sys.path.insert(0, str(path))


AHEAD = 64


def _worker_init(paths):
    for path in paths:
        if path not in sys.path:
            sys.path.insert(0, path)


def _parse_texture(data):
    import rx2_parser
    return rx2_parser.parse_rx2(data)


def _parse_collision(data):
    from retail_collision_mesh import decode_rx2_clustered_meshes
    return decode_rx2_clustered_meshes(data)


class Ahead:
    def __init__(self, pool, fn, items):
        self.pool, self.fn, self.items = pool, fn, list(items)
        self.next, self.pending = 0, {}

    def _fill(self):
        while self.next < len(self.items) and len(self.pending) < AHEAD:
            data = self.items[self.next]
            self.pending.setdefault(id(data), []).append(self.pool.submit(self.fn, data))
            self.next += 1

    def get(self, data, fallback):
        self._fill()
        queue = self.pending.get(id(data))
        if not queue:
            return fallback(data)
        future = queue.pop(0)
        if not queue:
            del self.pending[id(data)]
        result = future.result()
        self._fill()
        return result


def _parallel_prepare(prepare, folder, stream, workers, **kwargs):
    import os
    from concurrent.futures import ProcessPoolExecutor
    import prepare_hawaiian_dream as phd
    import rx2_parser
    from skate3_streams import load_district_stream
    names = ['Pres', 'Sim'] + list(kwargs.get('texture_stream_names', ()))
    assets = {name: load_district_stream(folder, name, kwargs['district_name']) for name in names}
    textures = [a.data for name in names if name != 'Sim' for a in assets[name] if a.record.asset_type == phd.ASSET_TYPE_TEXTURE]
    sims = [a.data for a in assets['Sim']]
    real_load, real_parse, real_collision = phd.load_district_stream, rx2_parser.parse_rx2, phd.decode_rx2_clustered_meshes
    with ProcessPoolExecutor(max_workers=workers or os.cpu_count(), initializer=_worker_init, initargs=(list(sys.path),)) as pool:
        tex, col = Ahead(pool, _parse_texture, textures), Ahead(pool, _parse_collision, sims)
        phd.load_district_stream = lambda directory, name, district: assets[name] if name in assets else real_load(directory, name, district)
        rx2_parser.parse_rx2 = lambda data: tex.get(data, real_parse)
        phd.decode_rx2_clustered_meshes = lambda data: col.get(data, real_collision)
        try:
            return prepare(**kwargs)
        finally:
            phd.load_district_stream, rx2_parser.parse_rx2, phd.decode_rx2_clustered_meshes = real_load, real_parse, real_collision


def decode_stream(source, archive_path, stream, work, report=print, workers=None):
    _imports()
    from tools.owned_game.big import BigArchive
    from prepare_hawaiian_dream import prepare
    from prepare_university import EXCLUDED_NORMAL_TEXTURE_IDS
    out = Path(work) / stream
    manifest = out / 'intermediate/manifest.json'
    stamp = out / 'mapgen.json'
    archive = source.file(archive_path, report)
    key = {'format': CACHE_FORMAT, 'archive': archive.name, 'size': archive.stat().st_size}
    if manifest.is_file() and stamp.is_file() and json.loads(stamp.read_text()) == key:
        return manifest.parent
    if out.exists():
        shutil.rmtree(out)
    report(f'reading {archive.name}')
    big = BigArchive(archive)
    big.extract_entries(big.entries, out / 'raw')
    folder = out / 'raw/data/content/world/stream' / stream
    if not folder.is_dir():
        raise RuntimeError('missing stream ' + str(folder))
    sim = folder / f'{stream}_Sim.xst'
    if not sim.is_file():
        sim.write_bytes(EMPTY_ATOC)
    report(f'decoding {stream}')
    if str(UTT) not in sys.path:
        sys.path.insert(0, str(UTT))
    _parallel_prepare(prepare, folder, stream, workers, stream_directory=folder, output_root=out / 'intermediate', utt_root=UTT,
            district_name=stream, map_name=stream, package_name='Skate 3',
            cache_format='skate3-rust-map-v1',
            texture_stream_names=('Tex',) if any(folder.glob('cTex_*.xsf')) else (),
            excluded_normal_texture_ids=EXCLUDED_NORMAL_TEXTURE_IDS, raw_texture_cache=True,
            write_render_sources=False)
    stamp.write_text(json.dumps(key))
    return manifest.parent


def decode(source, district, work, report=print):
    return decode_stream(source, f'data/content/world{district}.big', district, work, report)


def decode_proxy(source, district, work, report=print):
    stream = PROXIES.get(district)
    if stream is None:
        return None
    return decode_stream(source, f'data/content/proxy{stream}.big', stream, work, report)
