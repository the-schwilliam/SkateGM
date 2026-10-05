import sys
from pathlib import Path

from . import EXPORTER


class GameSource:
    def __init__(self, path, cache):
        path = Path(path)
        if path.is_file() and path.name.lower() == 'default.xex':
            path = path.parent
        self.path = path
        self.cache = Path(cache)
        self.iso = path.is_file() and path.suffix.lower() == '.iso'
        if not self.iso and not (path / 'data').is_dir():
            raise FileNotFoundError(f'{path} is neither a Skate 3 disc image nor a folder holding data/')

    def file(self, relative, report=print):
        relative = relative.replace('\\', '/')
        if not self.iso:
            found = self.path / relative
            if not found.is_file():
                raise FileNotFoundError(f'{relative} not found under {self.path}')
            return found
        target = self.cache / relative
        if target.is_file():
            return target
        if str(EXPORTER) not in sys.path:
            sys.path.insert(0, str(EXPORTER))
        import xiso
        partial = target.with_name(target.name + '.part')
        partial.parent.mkdir(parents=True, exist_ok=True)
        with xiso.Xiso(self.path) as disc:
            disc.extract(relative, str(partial))
        partial.replace(target)
        return target

    def district(self, district, report=print):
        return self.file(f'data/content/world{district}.big', report)
