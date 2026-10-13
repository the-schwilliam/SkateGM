"""Builds release/SkateGM-Setup-<version>.exe (version from VERSION): the installer window, the converter, the
add-on and the engine module in one file. Nothing from the game is bundled.

    python tools/build_installer.py

Needs Rust (for the converter's refpack.dll) and Python 3; makes its own
build environment in .build/venv with pinned packages.
"""
from pathlib import Path
import glob, hashlib, io, json, os, shutil, subprocess, sys, tarfile, urllib.request, venv

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / '.build'
VENV = BUILD / 'venv'
PY = VENV / ('Scripts/python.exe' if sys.platform == 'win32' else 'bin/python')
PACKAGES = ['numpy==2.5.3', 'pillow==12.3.0', 'soundfile==0.14.0', 'cffi==2.1.1', 'pycparser==3.11']
PYINSTALLER = 'pyinstaller==6.22.3'
DLL = ROOT / 'gm_skategm' / 'prebuilt' / 'gmcl_skategm_win64.dll'
PREBUILT = ROOT / 'gm_skategm' / 'prebuilt'
EXTRAS = ['skategm_sdl2.dll', 'skategm_gamecontrollerdb.txt']
EXTRA_LICENSES = ['SDL2-LICENSE.txt', 'SDL2-README.txt', 'SDL_GameControllerDB-LICENSE.txt']
VGMSTREAM = PREBUILT / 'vgmstream'
AEMS_RENDER = ROOT / 'engine' / 'target' / 'release' / 'examples' / 'aems_render.exe'
SEP = ';' if sys.platform == 'win32' else ':'
VERSION = (ROOT / 'VERSION').read_text(encoding='utf-8').strip()
NAME = 'SkateGM-Setup-' + VERSION



def cdylib(source, out):
    run('rustc', '--edition', '2024', '--crate-type', 'cdylib', '-C', 'opt-level=3', '-C', 'panic=abort',
        '-C', 'target-feature=+crt-static', source, '-o', out)
    return out

def run(*args, env=None):
    print('>', ' '.join(map(str, args)), flush=True)
    subprocess.run([str(a) for a in args], check=True, env=env)


# Wine's _wtempnam only keeps the first three characters of the prefix. A bootloader that uses
# the C runtime DLL (ours, built with MinGW) then gets a temp folder like "_MEac6a.tmp" instead of
# "_MEI<pid>...", rejects it ("Security validation failure: unexpected name of application's home
# directory!") and the installer won't start under Wine or Proton. PyInstaller's prebuilt
# bootloaders have the C runtime built in, so they don't hit this. Name the folder ourselves.
TEMPNAM = r'''/* SkateGM: replaces _wtempnam, see tools/build_installer.py */
static wchar_t *
_skategm_tempnam(const wchar_t *dir, const wchar_t *prefix, int attempt)
{
    LARGE_INTEGER counter;
    wchar_t *path = malloc(PYI_PATH_MAX * sizeof(wchar_t));

    if (path == NULL) {
        return NULL;
    }
    QueryPerformanceCounter(&counter);
    if (swprintf(path, PYI_PATH_MAX, L"%ls%ls%06x", dir, prefix, (unsigned int)(counter.LowPart + attempt) & 0xffffff) < 0) {
        free(path);
        return NULL;
    }
    return path;
}

'''
BOOTLOADER_PATCH = 'wine-tempnam'


def pyinstaller_source():
    version = PYINSTALLER.split('==')[1]
    with urllib.request.urlopen(f'https://pypi.org/pypi/pyinstaller/{version}/json') as r:
        sdist = next(u for u in json.load(r)['urls'] if u['packagetype'] == 'sdist')
    with urllib.request.urlopen(sdist['url']) as r:
        data = r.read()
    if hashlib.sha256(data).hexdigest() != sdist['digests']['sha256']:
        raise SystemExit('PyInstaller source download failed its sha256 check')
    src = BUILD / f'pyinstaller-{version}'
    shutil.rmtree(src, ignore_errors=True)
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        tar.extractall(BUILD, filter='data')
    c = src / 'bootloader' / 'src' / 'pyi_utils_win32.c'
    text = c.read_text(encoding='utf-8')
    anchor = 'int\npyi_create_temporary_application_directory('
    call = '_wtempnam(tempdir_path, prefix)'
    if text.count(anchor) != 1 or text.count(call) != 1:
        raise SystemExit(f'{c.name} changed in {PYINSTALLER}: check whether the Wine temp folder patch is still needed')
    c.write_text(text.replace(anchor, TEMPNAM + anchor).replace(call, '_skategm_tempnam(tempdir_path, prefix, i)'),
                 encoding='utf-8', newline='')
    return src


def own_bootloader():
    marker = VENV / 'own_bootloader.txt'
    if marker.is_file() and marker.read_text(encoding='utf-8') == PYINSTALLER + ' ' + BOOTLOADER_PATCH:
        return
    env = dict(os.environ, PYINSTALLER_COMPILE_BOOTLOADER='1')
    if sys.platform == 'win32' and not shutil.which('gcc'):
        found = glob.glob(os.path.expandvars(r'%LOCALAPPDATA%\Microsoft\WinGet\Packages\BrechtSanders.WinLibs*\mingw64\bin'))
        if not found:
            raise SystemExit('a C compiler is needed for the bootloader: winget install BrechtSanders.WinLibs.POSIX.MSVCRT')
        env['PATH'] = found[0] + os.pathsep + env['PATH']
    run(PY, '-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '--force-reinstall', '--no-deps',
        pyinstaller_source(), env=env)
    run(PY, '-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', PYINSTALLER)
    marker.write_text(PYINSTALLER + ' ' + BOOTLOADER_PATCH, encoding='utf-8')


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
    run('cargo', 'build', '--release', '--manifest-path', ROOT / 'engine' / 'Cargo.toml', '-p', 'skate-audio', '--example', 'aems_render')
    if not (VGMSTREAM / 'vgmstream-cli.exe').is_file():
        raise SystemExit('vgmstream is missing: python tools/fetch_vgmstream.py')
    if not PY.is_file():
        venv.create(VENV, with_pip=True)
    run(PY, '-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', *PACKAGES)
    own_bootloader()
    work = BUILD / 'installer'
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    refpack = cdylib(ROOT / 'exporter' / 'tools' / 'asset_pipeline' / 'refpack_native.rs', work / 'refpack.dll')
    vtfenc = cdylib(ROOT / 'exporter' / 'mapgen' / 'native' / 'vtfenc.rs', work / 'vtfenc.dll')
    licenses = work / 'licenses'
    licenses.mkdir()
    for src, name in [('LICENSE', 'SkateGM-LICENSE.txt'), ('engine/LICENSE', 'engine-LICENSE.txt'), ('engine/NOTICE-mashup', 'engine-NOTICE.txt'),
                      ('LICENSE-THIRD-PARTY.md', 'README.md'), ('exporter/tools/vendor/utt/LICENSE', 'UTT.txt'),
                      ('exporter/tools/vendor/university/LICENSE-PROJECT.md', 'CustomEngineLayer.txt'),
                      ('exporter/tools/vendor/skate3_ui/LICENSE', 'skate3_ui.txt')]:
        shutil.copy2(ROOT / src, licenses / name)
    for name in EXTRA_LICENSES:
        shutil.copy2(PREBUILT / name, licenses / name)
    shutil.copy2(VGMSTREAM / 'COPYING', licenses / 'vgmstream-COPYING.txt')
    site = Path(subprocess.run([str(PY), '-c', 'import soundfile, _soundfile_data, os; print(os.path.dirname(soundfile.__file__))'],
                               check=True, capture_output=True, text=True).stdout.strip())
    shutil.copy2(site / '_soundfile_data' / 'COPYING', licenses / 'libsndfile-COPYING.txt')
    shutil.copy2(next(site.glob('soundfile-*.dist-info')) / 'LICENSE', licenses / 'python-soundfile-LICENSE.txt')
    out = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'release'
    version_file(work / 'version.txt')
    from PIL import Image
    Image.open(ROOT / 'addon' / 'skategm' / 'gamemodes' / 'skategm' / 'icon24.png').convert('RGBA').save(work / 'icon.ico', sizes=[(16, 16), (32, 32)])
    run(PY, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onefile', '--windowed', '--noupx', '--name', NAME,
        '--version-file', work / 'version.txt',
        '--paths', ROOT / 'exporter',
        '--hidden-import', 'numpy', '--hidden-import', 'PIL.Image', '--hidden-import', 'convert', '--hidden-import', 'xiso', '--hidden-import', 'soundfile', '--collect-submodules', 'mapgen',
        '--add-binary', f'{refpack}{SEP}tools/asset_pipeline',
        '--add-binary', f'{vtfenc}{SEP}mapgen/native',
        '--add-data', f'{ROOT / "exporter" / "tools"}{SEP}tools',
        '--add-data', f'{ROOT / "exporter" / "mapgen" / "icons"}{SEP}mapgen/icons',
        '--add-data', f'{ROOT / "addon" / "skategm"}{SEP}payload/addon',
        '--add-binary', f'{DLL}{SEP}payload',
        '--add-binary', f'{PREBUILT / EXTRAS[0]}{SEP}payload',
        '--add-data', f'{PREBUILT / EXTRAS[1]}{SEP}payload',
        '--add-data', f'{licenses}{SEP}licenses',
        '--add-data', f'{VGMSTREAM}{SEP}payload/vgmstream',
        '--add-binary', f'{AEMS_RENDER}{SEP}payload',
        '--add-data', f'{ROOT / "VERSION"}{SEP}.',
        '--icon', work / 'icon.ico',
        '--exclude-module', 'bpy', '--exclude-module', 'mathutils',
        '--copy-metadata', 'numpy', '--copy-metadata', 'Pillow', '--copy-metadata', 'soundfile',
        '--distpath', out, '--workpath', work / 'build', '--specpath', work,
        ROOT / 'installer' / 'setup_skategm.py')
    print('built', out / (NAME + '.exe'))


if __name__ == '__main__':
    main()
