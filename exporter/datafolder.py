import shutil
from pathlib import Path

MARKER = '.skategm-data'
OWN = {MARKER, 'assets', 'conversion.log', 'hud.log', 'mapgen', 'source.txt'}
SUBFOLDER = 'SkateGM data'


class NotOurs(RuntimeError):
    pass


def own_name(name):
    return name in OWN or (name.startswith('source_') and name.endswith('.txt')) or name.startswith('skategm-')


def is_ours(path):
    path = Path(path)
    if not path.is_dir():
        return False
    if (path / MARKER).is_file():
        return True
    entries = [p.name for p in path.iterdir()]
    return bool(entries) and 'assets' in entries and all(own_name(n) for n in entries)


def empty(path):
    path = Path(path)
    return path.is_dir() and not any(path.iterdir())


def usable(path):
    path = Path(path).resolve()
    if not path.exists() or empty(path) or is_ours(path):
        return path
    for n in range(1, 100):
        sub = path / (SUBFOLDER if n == 1 else f'{SUBFOLDER} {n}')
        if not sub.exists() or empty(sub) or is_ours(sub):
            return sub
    raise NotOurs(f'{path} has no free place for SkateGM data: choose an empty folder')


def claim(path):
    path = usable(path)
    path.mkdir(parents=True, exist_ok=True)
    (path / MARKER).write_text('This folder holds SkateGM game data. SkateGM only ever removes its own files here.\n',
                               encoding='utf-8')
    return path


def _remove(p):
    if p.is_dir() and not p.is_symlink():
        shutil.rmtree(p)
    elif p.exists() or p.is_symlink():
        p.unlink()


def replace(root, name, new):
    root = Path(root)
    if not is_ours(root):
        raise NotOurs(f'{root} is not a SkateGM data folder: nothing in it was changed')
    if not own_name(name) or name == MARKER:
        raise NotOurs(f'{name} is not a SkateGM data entry')
    target = root / name
    _remove(target)
    Path(new).rename(target)
    return target


def remove(path):
    path = Path(path)
    if not path.exists():
        return False
    if not is_ours(path):
        raise NotOurs(f'{path} is not a SkateGM data folder, so it was left alone')
    for p in sorted(path.iterdir()):
        if own_name(p.name):
            _remove(p)
    if empty(path):
        path.rmdir()
    return True
