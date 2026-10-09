import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DLL = os.path.join(ROOT, 'gm_skategm', 'prebuilt', 'gmcl_skategm_win64.dll')
ADDON = os.path.join(ROOT, 'addon', 'skategm')


def version():
    with open(os.path.join(ROOT, 'VERSION'), encoding='utf-8') as f:
        return f.read().strip()


def main():
    v = sys.argv[1] if len(sys.argv) > 1 else version()
    out_dir = os.path.join(ROOT, 'release')
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, 'skategm_%s.zip' % v)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        z.write(DLL, 'gmcl_skategm_win64.dll')
        prebuilt = os.path.dirname(DLL)
        for name in ['skategm_sdl2.dll', 'skategm_gamecontrollerdb.txt']:
            z.write(os.path.join(prebuilt, name), name)
        for name in ['SDL2-LICENSE.txt', 'SDL2-README.txt', 'SDL_GameControllerDB-LICENSE.txt']:
            z.write(os.path.join(prebuilt, name), 'licenses/' + name)
        exporter = os.path.join(ROOT, 'exporter')
        for base, dirs, files in os.walk(exporter):
            dirs[:] = [d for d in dirs if d != '__pycache__']
            for name in sorted(files):
                if name in ('import_upstream.py', 'refpack.dll'):
                    continue
                full = os.path.join(base, name)
                z.write(full, os.path.relpath(full, ROOT).replace(os.sep, '/'))
        z.write(os.path.join(ROOT, 'LICENSE'), 'LICENSE')
        z.write(os.path.join(ROOT, 'LICENSE-THIRD-PARTY.md'), 'LICENSE-THIRD-PARTY.md')
        z.write(os.path.join(ROOT, 'engine', 'LICENSE'), 'engine/LICENSE')
        z.write(os.path.join(ROOT, 'engine', 'NOTICE-mashup'), 'engine/NOTICE-mashup')
        z.write(os.path.join(ROOT, 'engine', 'README.md'), 'engine/README.md')
        z.write(os.path.join(ROOT, 'README.md'), 'README.md')
        for base, _, files in os.walk(ADDON):
            for name in sorted(files):
                full = os.path.join(base, name)
                rel = os.path.relpath(full, os.path.dirname(ADDON)).replace(os.sep, '/')
                z.write(full, rel)
    print(out)


if __name__ == '__main__':
    main()
