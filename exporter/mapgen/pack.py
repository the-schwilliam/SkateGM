from pathlib import Path


def pack(tools, bsp, files, out):
    listing = Path(bsp).with_suffix('.pack.txt')
    with open(listing, 'w', encoding='utf-8', newline='\n') as f:
        for internal, external in sorted(files.items()):
            f.write(internal.replace('\\', '/') + '\n')
            f.write(str(Path(external).resolve()) + '\n')
    tools.run('bspzip', ['-game', tools.game, '-addorupdatelist', bsp, listing, out])
    if not Path(out).is_file():
        raise RuntimeError('bspzip did not write ' + str(out))
    return out


def extract(tools, bsp, out):
    Path(out).mkdir(parents=True, exist_ok=True)
    tools.run('bspzip', ['-game', tools.game, '-extractfiles', bsp, out])


def game_files(game, folders):
    game = Path(game)
    files = {}
    for folder in folders:
        root = game / folder
        if not root.is_dir():
            continue
        for path in root.rglob('*'):
            if path.is_file() and path.suffix.lower() in ('.vtf', '.vmt', '.mdl', '.vvd', '.vtx', '.phy'):
                files[path.relative_to(game).as_posix()] = path
    return files
