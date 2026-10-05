import hashlib
import json
import os
import shutil
from dataclasses import asdict
from pathlib import Path

from . import regions as region_list
from .build import build
from .source import GameSource
from .sourcetools import ToolError

BUILD_VERSION = 2
ADDON = 'skategm_maps'
ADDON_JSON = {'title': 'SkateGM: Skate 3 maps (built on this PC)', 'type': 'map', 'tags': ['fun'], 'ignore': []}


def region_key(region):
    text = json.dumps({'build': BUILD_VERSION, 'region': asdict(region)}, sort_keys=True, default=str)
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def addon_dir(gmod):
    return Path(gmod) / 'garrysmod' / 'addons' / ADDON


def _state_path(gmod):
    return addon_dir(gmod) / 'maps.json'


def read_state(gmod):
    try:
        return json.loads(_state_path(gmod).read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}


PARALLEL = 2


def prepare_shared(source, regions, work, report=print):
    from . import decode, environment, props, scene
    for district in sorted({r.district for r in regions}):
        root = decode.decode(source, district, work / 'districts', report)
        scene.load(root, collision=True)
        if any(r.district == district and r.backdrop and len(r.corners) for r in regions):
            decode.decode_proxy(source, district, work / 'districts', report)
        for step in (lambda: environment.load(source, district, work / 'env'),
                     lambda: environment.water(source, district, work / 'env')):
            try:
                step()
            except (OSError, KeyError, ValueError, IndexError):
                pass
    try:
        props.catalog(source, work / 'dmo', report)
    except (OSError, KeyError, ValueError, IndexError):
        pass


def _child(name, game, gmod, maps, work, workers, queue):
    try:
        region = region_list.by_name(name)
        source = GameSource(game, Path(work) / 'disc')
        final, phases, _ = build(region, source, gmod, maps, work, report=lambda m: queue.put(('log', name, str(m))),
                                 workers=workers)
        queue.put(('done', name, str(final), phases))
    except Exception as error:
        queue.put(('fail', name, str(error) or type(error).__name__))


def install_maps(game, gmod, work, report=print, names=None, force=False, parallel=PARALLEL):
    import multiprocessing
    addon = addon_dir(gmod)
    maps = addon / 'maps'
    maps.mkdir(parents=True, exist_ok=True)
    (addon / 'addon.json').write_text(json.dumps(ADDON_JSON, indent='\t'), encoding='utf-8')
    chosen = [region_list.by_name(n) for n in names] if names else list(region_list.REGIONS)
    state = read_state(gmod)
    work = Path(work)
    source = GameSource(game, work / 'disc')
    built, failed = [], []
    retire(maps, state, report)
    _state_path(gmod).write_text(json.dumps(state, indent=1), encoding='utf-8')
    todo = []
    for region in chosen:
        target = maps / f'{region.map_name}.bsp'
        if not force and state.get(region.map_name, {}).get('key') == region_key(region) and target.is_file():
            report(f'{region.map_name}: already built')
        else:
            todo.append(region)
    if todo:
        report("Reading Skate 3's districts...")
        prepare_shared(source, todo, work, report)
    queue = multiprocessing.Queue()
    running = {}
    pending = list(todo)
    while pending or running:
        while pending and len(running) < max(1, parallel):
            region = pending.pop(0)
            report(f'Building {region.map_name} ({region.title})...')
            workers = max(1, (os.cpu_count() or 4) // max(1, parallel))
            proc = multiprocessing.Process(target=_child, args=(region.name, str(game), str(gmod), str(maps), str(work),
                                                                workers, queue))
            proc.start()
            running[region.name] = proc
        message = queue.get()
        kind, name = message[0], message[1]
        region = region_list.by_name(name)
        if kind == 'log':
            continue
        running.pop(name).join()
        if kind == 'fail':
            report(f'{region.map_name} could not be built: {message[2]}')
            failed.append(region.map_name)
            continue
        final, phases = Path(message[2]), message[3]
        state[region.map_name] = {'key': region_key(region), 'title': region.title, 'sha256': _sha256(final),
                                  'seconds': phases}
        _state_path(gmod).write_text(json.dumps(state, indent=1), encoding='utf-8')
        report(f'{region.map_name} built')
        built.append(region.map_name)
    for leftover in ('build', 'districts', 'disc'):
        shutil.rmtree(work / leftover, ignore_errors=True)
    return built, failed


def retire(maps, state, report=print):
    current = {r.map_name for r in region_list.REGIONS}
    for path in sorted(maps.glob('sgm_*.bsp')):
        if path.stem not in current:
            path.unlink(missing_ok=True)
            (maps / 'thumb' / f'{path.stem}.png').unlink(missing_ok=True)
            report(f'{path.stem}: removed (no longer one of the maps)')
    for name in [n for n in state if n not in current]:
        del state[name]


def remove_maps(gmod):
    shutil.rmtree(addon_dir(gmod), ignore_errors=True)


def _sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()
