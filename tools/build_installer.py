"""Builds release/SkateGM-Setup-<version>.exe (version from VERSION): the installer window, the converter, the
add-on and the engine module in one file. Nothing from the game is bundled.

    python tools/build_installer.py

Needs Rust (for the converter's refpack.dll) and Python 3; makes its own
build environment in .build/venv with pinned packages.
"""
from pathlib import Path
import glob, os, shutil, subprocess, sys, venv

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / '.build'
VENV = BUILD / 'venv'
PY = VENV / ('Scripts/python.exe' if sys.platform == 'win32' else 'bin/python')
PACKAGES = ['numpy==2.5.3', 'pillow==12.3.0']
PYINSTALLER = 'pyinstaller==6.22.3'
DLL = ROOT / 'gm_skategm' / 'prebuilt' / 'gmcl_skategm_win64.dll'
PREBUILT = ROOT / 'gm_skategm' / 'prebuilt'
EXTRAS = ['skategm_sdl2.dll', 'skategm_gamecontrollerdb.txt']
EXTRA_LICENSES = ['SDL2-LICENSE.txt', 'SDL2-README.txt', 'SDL_GameControllerDB-LICENSE.txt']
SEP = ';' if sys.platform == 'win32' else ':'
VERSION = (ROOT / 'VERSION').read_text(encoding='utf-8').strip()
NAME = 'SkateGM-Setup-' + VERSION


def run(*args, env=None):
    print('>', ' '.join(map(str, args)), flush=True)
    subprocess.run([str(a) for a in args], check=True, env=env)


def own_bootloader():
    marker = VENV / 'own_bootloader.txt'
    if marker.is_file() and marker.read_text(encoding='utf-8') == PYINSTALLER:
        return
    env = dict(os.environ, PYINSTALLER_COMPILE_BOOTLOADER='1')
    if sys.platform == 'win32' and not shutil.which('gcc'):
        found = glob.glob(os.path.expandvars(r'%LOCALAPPDATA%\Microsoft\WinGet\Packages\BrechtSanders.WinLibs*\mingw64\bin'))
        if not found:
            raise SystemExit('a C compiler is needed for the bootloader: winget install BrechtSanders.WinLibs.POSIX.MSVCRT')
        env['PATH'] = found[0] + os.pathsep + env['PATH']
    run(PY, '-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '--force-reinstall', '--no-deps',
        '--no-binary', 'pyinstaller', PYINSTALLER, env=env)
    run(PY, '-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', PYINSTALLER)
    marker.write_text(PYINSTALLER, encoding='utf-8')


def version_file(path):
    parts = [int(p) for p in VERSION.split('.') if p.isdigit()][:4]
    parts += [0] * (4 - len(parts))
    nums = ', '.join(map(str, parts))
    strings = {'CompanyName': 'SkateGM', 'FileDescription': 'SkateGM installer', 'FileVersion': VERSION,
               'InternalName': 'SkateGM-Setup', 'OriginalFilename': NAME + '.exe', 'ProductName': 'SkateGM',
               'ProductVersion': VERSION, 'LegalCopyright': 'SkateGM contributors'}
    rows = ',\n'.join(f'          StringStruct({k!r}, {v!r})' for k, v in strings.items())
    path.write_text(f"""VSVersionInfo(
  ffi=FixedFileInfo(filevers=({nums}), prodvers=({nums}), mask=0x3f, flags=0x0, OS=0x40004, fileType=0x1, subtype=0x0, date=(0, 0)),
  kids=[
    StringFileInfo([StringTable('040904B0', [
{rows}])]),
    VarFileInfo([VarStruct('Translation', [1033, 1200])])
  ]
)
""", encoding='utf-8')


def main():
    if not DLL.is_file():
        raise SystemExit(f'build the module first: {DLL} is missing')
    if not all((PREBUILT / n).is_file() for n in EXTRAS + EXTRA_LICENSES):
        raise SystemExit('SDL2 is missing: python tools/fetch_sdl.py')
    if not PY.is_file():
        venv.create(VENV, with_pip=True)
    run(PY, '-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', *PACKAGES)
    own_bootloader()
    work = BUILD / 'installer'
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    refpack = work / 'refpack.dll'
    run('rustc', '--edition', '2024', '--crate-type', 'cdylib', '-C', 'opt-level=3', '-C', 'panic=abort',
        '-C', 'target-feature=+crt-static', ROOT / 'exporter' / 'tools' / 'asset_pipeline' / 'refpack_native.rs', '-o', refpack)
    licenses = work / 'licenses'
    licenses.mkdir()
    for src, name in [('engine/LICENSE', 'engine-LICENSE.txt'), ('engine/NOTICE-mashup', 'engine-NOTICE.txt'),
                      ('LICENSE-THIRD-PARTY.md', 'README.md'), ('exporter/tools/vendor/utt/LICENSE', 'UTT.txt'),
                      ('exporter/tools/vendor/university/LICENSE-PROJECT.md', 'CustomEngineLayer.txt'),
                      ('exporter/tools/vendor/skate3_ui/LICENSE', 'skate3_ui.txt')]:
        shutil.copy2(ROOT / src, licenses / name)
    for name in EXTRA_LICENSES:
        shutil.copy2(PREBUILT / name, licenses / name)
    out = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'release'
    version_file(work / 'version.txt')
    from PIL import Image
    Image.open(ROOT / 'addon' / 'skategm' / 'gamemodes' / 'skategm' / 'icon24.png').convert('RGBA').save(work / 'icon.ico', sizes=[(16, 16), (32, 32)])
    run(PY, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onefile', '--windowed', '--noupx', '--name', NAME,
        '--version-file', work / 'version.txt',
        '--paths', ROOT / 'exporter',
        '--hidden-import', 'numpy', '--hidden-import', 'PIL.Image', '--hidden-import', 'convert', '--hidden-import', 'xiso', '--collect-submodules', 'mapgen',
        '--add-binary', f'{refpack}{SEP}tools/asset_pipeline',
        '--add-data', f'{ROOT / "exporter" / "tools"}{SEP}tools',
        '--add-data', f'{ROOT / "addon" / "skategm"}{SEP}payload/addon',
        '--add-binary', f'{DLL}{SEP}payload',
        '--add-binary', f'{PREBUILT / EXTRAS[0]}{SEP}payload',
        '--add-data', f'{PREBUILT / EXTRAS[1]}{SEP}payload',
        '--add-data', f'{licenses}{SEP}licenses',
        '--add-data', f'{ROOT / "VERSION"}{SEP}.',
        '--icon', work / 'icon.ico',
        '--exclude-module', 'bpy', '--exclude-module', 'mathutils',
        '--copy-metadata', 'numpy', '--copy-metadata', 'Pillow',
        '--distpath', out, '--workpath', work / 'build', '--specpath', work,
        ROOT / 'installer' / 'setup_skategm.py')
    print('built', out / (NAME + '.exe'))


if __name__ == '__main__':
    main()
