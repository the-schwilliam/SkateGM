"""Converts the Skate 3 data the gm_skategm module reads, from the player's own
Xbox 360 disc image (.iso) or extracted default.xex: animation banks, state graphs, input and physics
settings, and the skater model the board and rig are taken from.

Runs the converters of SK8-ENGINE/skate-3-rust-engine (copied into ./tools,
commit cb79689). Nothing is downloaded and nothing from the game is bundled.
Adapted from 2010 Rust Rewrite Mashup's skate/converter/iw4l_skate_convert.py.

    python convert.py --xex <default.xex or the game's .iso> --out <folder>

Writes <folder>/assets on success; progress lines go to stdout.
"""
from pathlib import Path
import argparse, runpy, shutil, sys, tempfile, traceback

ROOT = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parent))
sys.path.insert(0, str(ROOT))

REQUIRED = [
    'data/big/miscload.big',
    'data/big/miscboot.big',
    'data/big/db.big',
    'data/content/createacharacter.big',
]


def run_task(script, args):
    # The converters start their own helper scripts through `--task`.
    script = Path(script)
    if not script.is_absolute():
        script = ROOT / script
    script = script.resolve()
    if not script.is_relative_to((ROOT / 'tools').resolve()):
        raise RuntimeError('Invalid conversion script')
    sys.path.insert(0, str(script.parent))
    sys.argv = [str(script), *args]
    runpy.run_path(str(script), run_name='__main__')
    return 0


HUD = ['data/big/fedata.big', 'data/big/fetexture.big', 'data/big/miscboot.big']
FROM_DISC = list(dict.fromkeys(['default.xex', 'data/anim', *REQUIRED, *HUD]))


def convert(xex, out):
    xex = xex.resolve()
    if xex.suffix.lower() == '.iso':
        import xiso
        out = out.resolve()
        out.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='skategm-disc-', dir=out.parent) as disc:
            print('Reading the files it needs from your disc image', flush=True)
            try:
                xiso.extract_files(xex, FROM_DISC, disc, lambda text: print(text, flush=True))
            except xiso.XisoError as error:
                raise RuntimeError(f'{xex.name}: {error}. Is this a Skate 3 (Xbox 360) disc image?')
            return convert_game(Path(disc), out)
    if xex.name.lower() != 'default.xex' or not xex.is_file():
        raise RuntimeError(f"Select default.xex from an extracted Skate 3 (Xbox 360) game folder, or the game's .iso, not {xex.name}.")
    return convert_game(xex.parent, out)


def prepare_hud(xex, data):
    """Only Skate 3's trick display, into already converted data."""
    from tools.asset_pipeline import asset_exports as exports
    xex, data = Path(xex).resolve(), Path(data).resolve()

    def report(text):
        print(text, flush=True)

    def run(game):
        with tempfile.TemporaryDirectory(prefix='skategm-hud-', dir=data) as work,                 (data / 'hud.log').open('w', encoding='utf-8') as log:
            exports.gmod_hud(game, data, Path(work), report, log)
    if xex.suffix.lower() == '.iso':
        import xiso
        with tempfile.TemporaryDirectory(prefix='skategm-disc-', dir=data) as disc:
            xiso.extract_files(xex, HUD, disc, lambda text: print(text, flush=True))
            return run(Path(disc))
    return run(xex.parent)


SOUNDS = ['data/audio/audiofiles.big', 'data/audio/grains.big']


def build_sounds(xex, data, gmod, vgmstream, aems_render=None):
    """Skate 3's board sounds into Garry's Mod (asset_pipeline/skate3_sounds.py)."""
    from tools.asset_pipeline import skate3_sounds
    xex, data = Path(xex).resolve(), Path(data).resolve()
    collections = data / 'assets' / 'private' / 'stock' / 'skater-collections.json'

    def report(text):
        print(text, flush=True)

    def run(game):
        with tempfile.TemporaryDirectory(prefix='skategm-sounds-', dir=data) as work:
            return skate3_sounds.build(game, collections, gmod, vgmstream, Path(work), report, aems_render)
    if xex.suffix.lower() == '.iso':
        import xiso
        with tempfile.TemporaryDirectory(prefix='skategm-disc-', dir=data) as disc:
            xiso.extract_files(xex, SOUNDS, disc, lambda text: print(text, flush=True))
            return run(Path(disc))
    return run(xex.parent)


def convert_game(game, out):
    missing = [path for path in REQUIRED if not (game / path).is_file()]
    if missing:
        raise RuntimeError('This folder is missing Skate 3 game data (' + ', '.join(missing) +
                           '). Keep the data folder beside default.xex.')

    from tools.asset_pipeline import asset_exports as exports

    out = out.resolve()
    stage = out.with_name(out.name + '.partial')
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)

    def report(text):
        print(text, flush=True)

    with tempfile.TemporaryDirectory(prefix='skategm-convert-', dir=stage.parent) as work, \
            (stage / 'conversion.log').open('w', encoding='utf-8') as log:
        work = Path(work)
        converted = exports.core(game, stage, work, report, log)
        exports.character(game, stage, work, report, log, converted)
        if all((game / path).is_file() for path in HUD):
            try:
                exports.gmod_hud(game, stage, work, report, log)
            except Exception as error:
                report("Skate 3's trick display was skipped: " + (str(error) or type(error).__name__))

    assets = stage / 'assets'
    for needed in ('private/skater.glb', 'private/game.json', 'private/stock/physics-skeletons.json',
                   'private/stock/skater-collections.json'):
        if not (assets / needed).is_file():
            raise RuntimeError(f'Conversion finished without {needed}.')
    shutil.rmtree(out, ignore_errors=True)
    stage.rename(out)
    report('Skate 3 data ready')


def main():
    if len(sys.argv) > 2 and sys.argv[1] == '--task':
        return run_task(sys.argv[2], sys.argv[3:])
    parser = argparse.ArgumentParser()
    parser.add_argument('--xex', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    try:
        convert(args.xex, args.out)
    except Exception as error:
        traceback.print_exc()
        print(f'ERROR: {error}', flush=True)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
