"""SkateGM installer: finds Garry's Mod, converts the player's own game data
from their default.xex or the game's .iso, and installs the add-on and the engine module.

Nothing from the game is bundled: the data is made on this PC from the
player's own copy. Built into one .exe by tools/build_installer.py.

    SkateGM-Setup.exe                         the window
    SkateGM-Setup.exe --gmod DIR --xex FILE   no window (prints progress)
        [--data DIR] [--skip-convert] [--uninstall]
"""
from pathlib import Path
import argparse, os, re, shutil, sys, threading, traceback

ROOT = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parent))
PAYLOAD = ROOT / 'payload'
if (ROOT / 'exporter').is_dir():
    sys.path.insert(0, str(ROOT / 'exporter'))
else:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'exporter'))



def version():
    for path in (ROOT / 'VERSION', Path(__file__).resolve().parent.parent / 'VERSION'):
        try:
            return path.read_text(encoding='utf-8').strip()
        except OSError:
            pass
    return ''


VERSION = version()
TITLE = f'SkateGM {VERSION} Setup' if VERSION else 'SkateGM Setup'
DLL = 'gmcl_skategm_win64.dll'
BIN_EXTRAS = ['skategm_sdl2.dll', 'skategm_gamecontrollerdb.txt']
OLD_FILES = ['lua/bin/gmcl_sk8_win64.dll']
OLD_ADDONS = ['skate3_native', 'skategm']
DEFAULT_DATA = Path(os.environ.get('LOCALAPPDATA', str(Path.home()))) / 'SkateGM' / 'data'


def payload_dir(name):
    """Where a payload part is: bundled, or (running from source) the repo."""
    bundled = PAYLOAD / name
    if bundled.exists():
        return bundled
    repo = Path(__file__).resolve().parent.parent
    if name == 'addon':
        return repo / 'addon' / 'skategm'
    return repo / 'gm_skategm' / 'prebuilt' / name


# --------------------------------------------------------------------------
# finding Garry's Mod
# --------------------------------------------------------------------------
def steam_roots():
    roots = []
    try:
        import winreg
        for hive, key in ((winreg.HKEY_CURRENT_USER, r'Software\Valve\Steam'),
                          (winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\WOW6432Node\Valve\Steam'),
                          (winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\Valve\Steam')):
            try:
                with winreg.OpenKey(hive, key) as k:
                    for value in ('SteamPath', 'InstallPath'):
                        try:
                            roots.append(Path(winreg.QueryValueEx(k, value)[0]))
                        except OSError:
                            pass
            except OSError:
                pass
    except ImportError:
        pass
    roots.append(Path(r'C:\Program Files (x86)\Steam'))
    out = []
    for r in roots:
        if r not in out:
            out.append(r)
    return out


def steam_libraries():
    libs = []
    for root in steam_roots():
        vdf = root / 'steamapps' / 'libraryfolders.vdf'
        if root.is_dir():
            libs.append(root)
        if vdf.is_file():
            for path in re.findall(r'"path"\s+"([^"]+)"', vdf.read_text(encoding='utf-8', errors='replace')):
                libs.append(Path(path.replace('\\\\', '\\')))
    out = []
    for lib in libs:
        if lib not in out:
            out.append(lib)
    return out


def is_gmod(folder):
    folder = Path(folder)
    return (folder / 'garrysmod').is_dir() and ((folder / 'hl2.exe').is_file() or (folder / 'gmod.exe').is_file()
                                                or (folder / 'bin' / 'win64').is_dir())


def find_gmod():
    for lib in steam_libraries():
        candidate = lib / 'steamapps' / 'common' / 'GarrysMod'
        if is_gmod(candidate):
            return candidate
    return None


def on_x64_branch(gmod):
    return (Path(gmod) / 'bin' / 'win64' / 'gmod.exe').is_file()


# --------------------------------------------------------------------------
# installing
# --------------------------------------------------------------------------
class Cancelled(Exception):
    pass


def data_ready(data):
    assets = Path(data) / 'assets'
    return all((assets / f).is_file() for f in ('private/skater.glb', 'private/game.json', 'private/stock/physics-skeletons.json'))


def convert(xex, data, report):
    import convert as exporter
    report('Converting your game data (a few minutes)...')
    exporter.convert(Path(xex), Path(data))


IN_USE = "Some SkateGM files are in use: close Garry's Mod (and any window showing its addons folder) and try again."


def remove_tree(path):
    """Delete a folder completely, or say clearly why it can't be."""
    if not path.exists():
        return
    shutil.rmtree(path, ignore_errors=True)
    if path.exists():
        raise RuntimeError(IN_USE)


def install(gmod, xex, data, report, skip_convert=False, build_maps=True, map_names=None):
    gmod = Path(gmod)
    if not is_gmod(gmod):
        raise RuntimeError(f"{gmod} doesn't look like Garry's Mod (no garrysmod folder).")
    garrysmod = gmod / 'garrysmod'
    data = Path(data)
    if skip_convert and data_ready(data):
        report('Game data: already converted, keeping it')
    else:
        if not xex:
            raise RuntimeError("Choose your Skate 3 disc image (.iso) or default.xex.")
        convert(xex, data, report)
        remember_source(data, xex)
    if not data_ready(data):
        raise RuntimeError('The game data conversion did not finish.')
    report('Installing the add-on...')
    for old in OLD_ADDONS:
        remove_tree(garrysmod / 'addons' / old)
    for old in OLD_FILES:
        (garrysmod / old).unlink(missing_ok=True)
    shutil.copytree(payload_dir('addon'), garrysmod / 'addons' / 'skategm')
    report('Installing the engine module...')
    (garrysmod / 'lua' / 'bin').mkdir(parents=True, exist_ok=True)
    try:
        for name in [DLL, *BIN_EXTRAS]:
            shutil.copy2(payload_dir(name), garrysmod / 'lua' / 'bin' / name)
    except PermissionError:
        raise RuntimeError("Couldn't replace the engine module: close Garry's Mod and try again.")
    (garrysmod / 'data' / 'skategm').mkdir(parents=True, exist_ok=True)
    (garrysmod / 'data' / 'skategm' / 'datapath.txt').write_text(str((data / 'assets').resolve()).replace('\\', '/'), encoding='utf-8')
    if build_maps:
        install_maps(gmod, xex or remembered_source(data), data, report, map_names)
    report('Done! Start Garry\'s Mod and pick the SkateGM gamemode, or in any other gamemode type '
           '"bind j skategm_toggle" in the console once and press J.')


def remember_source(data, xex):
    try:
        (Path(data) / 'source.txt').write_text(str(Path(xex).resolve()), encoding='utf-8')
    except OSError:
        pass


def remembered_source(data):
    try:
        path = Path((Path(data) / 'source.txt').read_text(encoding='utf-8').strip())
    except OSError:
        return None
    return path if path.exists() else None


def install_maps(gmod, game, data, report, names=None):
    if not game:
        report('Skate 3 maps: choose your Skate 3 disc image (.iso) or default.xex to build them.')
        return
    report('Building the Skate 3 maps (a few minutes each)...')
    try:
        from mapgen.install import install_maps as build_all
        built, failed = build_all(game, gmod, Path(data) / 'mapgen', report, names=names)
    except Exception as error:
        traceback.print_exc()
        report('Skate 3 maps were skipped: ' + (str(error) or type(error).__name__))
        return
    if failed:
        report('Some maps could not be built: ' + ', '.join(failed))
    if built:
        report('Built: ' + ', '.join(built))


def uninstall(gmod, data, report, remove_data=False):
    garrysmod = Path(gmod) / 'garrysmod'
    for old in OLD_ADDONS:
        remove_tree(garrysmod / 'addons' / old)
    for f in ['lua/bin/' + n for n in [DLL, *BIN_EXTRAS]] + OLD_FILES:
        try:
            (garrysmod / f).unlink(missing_ok=True)
        except PermissionError:
            raise RuntimeError("Couldn't remove the engine module: close Garry's Mod and try again.")
    (garrysmod / 'data' / 'skategm' / 'datapath.txt').unlink(missing_ok=True)
    remove_tree(garrysmod / 'addons' / 'skategm_maps')
    if remove_data:
        shutil.rmtree(data, ignore_errors=True)
    report('SkateGM removed.' + (' Your converted game data was deleted too.' if remove_data else ''))


# --------------------------------------------------------------------------
# the window
# --------------------------------------------------------------------------
def map_choices():
    try:
        from mapgen.regions import REGIONS
    except Exception:
        traceback.print_exc()
        return []
    return [(r.map_name, f'{r.title} ({r.map_name})') for r in REGIONS]


def outdated_maps(gmod):
    try:
        from mapgen import install as mapinstall
        from mapgen.regions import REGIONS
    except Exception:
        return []
    state = mapinstall.read_state(gmod)
    maps = mapinstall.addon_dir(gmod) / 'maps'
    return [r.map_name for r in REGIONS
            if (maps / f'{r.map_name}.bsp').is_file() and state.get(r.map_name, {}).get('key') != mapinstall.region_key(r)]


def window():
    import tkinter as tk
    from tkinter import filedialog, messagebox, ttk

    root = tk.Tk()
    root.title(TITLE)
    root.resizable(False, False)
    pad = {'padx': 10, 'pady': 4}

    found = find_gmod()
    gmod_var = tk.StringVar(value=str(found) if found else '')
    xex_var = tk.StringVar()
    data_var = tk.StringVar(value=str(DEFAULT_DATA))

    frm = ttk.Frame(root, padding=12)
    frm.grid()
    header = ttk.Frame(frm)
    header.grid(column=0, row=0, columnspan=3, sticky='w')
    try:
        logo = tk.PhotoImage(file=str(payload_dir('addon') / 'materials' / 'skategm' / 'logo.png')).subsample(3, 3)
        ttk.Label(header, image=logo).grid(column=0, row=0, sticky='w')
        header.logo = logo
    except tk.TclError:
        ttk.Label(header, text='SkateGM', font=('Segoe UI', 16, 'bold')).grid(column=0, row=0, sticky='w')
    if VERSION:
        ttk.Label(header, text=f'Version {VERSION}', font=('Segoe UI', 11)).grid(column=1, row=0, sticky='sw', padx=(12, 0), pady=(0, 6))
    try:
        icon = tk.PhotoImage(file=str(payload_dir('addon') / 'gamemodes' / 'skategm' / 'icon24.png'))
        root.iconphoto(True, icon)
        root.icon = icon
    except tk.TclError:
        pass
    ttk.Label(frm, text='You need your own legally dumped Xbox 360 copy of the game: choose its disc image (.iso), '
                        'or default.xex from an extracted copy. '
                        'Its data is converted on this PC; nothing is downloaded.', wraplength=520).grid(column=0, row=1, columnspan=3, sticky='w', pady=(0, 8))

    def browse_gmod():
        d = filedialog.askdirectory(title="Your Garry's Mod folder (the one with garrysmod inside)")
        if d:
            gmod_var.set(d)
            check()

    def browse_xex():
        f = filedialog.askopenfilename(title='Your Skate 3 disc image (.iso), or default.xex from an extracted copy',
                                       filetypes=[('Skate 3 disc image or default.xex', '*.iso default.xex'), ('Disc image', '*.iso'), ('default.xex', 'default.xex')])
        if f:
            xex_var.set(f)

    def browse_data():
        d = filedialog.askdirectory(title='Where to keep the converted game data')
        if d:
            data_var.set(d)
            check()

    rows = [("Garry's Mod folder", gmod_var, browse_gmod), ('Skate 3 (.iso or default.xex)', xex_var, browse_xex), ('Converted data goes in', data_var, browse_data)]
    for i, (label, var, cmd) in enumerate(rows):
        ttk.Label(frm, text=label).grid(column=0, row=2 + i, sticky='w', **pad)
        ttk.Entry(frm, textvariable=var, width=58).grid(column=1, row=2 + i, **pad)
        ttk.Button(frm, text='Browse...', command=cmd).grid(column=2, row=2 + i, **pad)

    status = tk.StringVar()
    ttk.Label(frm, textvariable=status, wraplength=520, foreground='#a0522d').grid(column=0, row=5, columnspan=3, sticky='w', pady=(4, 0))
    reuse = tk.BooleanVar(value=False)
    reuse_box = ttk.Checkbutton(frm, text='Keep the game data I already converted (skip converting)', variable=reuse)
    reuse_box.grid(column=0, row=6, columnspan=3, sticky='w')
    maps = tk.BooleanVar(value=False)
    choices = ttk.Frame(frm)
    picks = {}
    for i, (name, title) in enumerate(map_choices()):
        picks[name] = tk.BooleanVar(value=True)
        ttk.Checkbutton(choices, text=title, variable=picks[name]).grid(column=i % 2, row=i // 2, sticky='w', padx=(24, 12))

    def show_choices():
        if maps.get() and picks:
            choices.grid(column=0, row=8, columnspan=3, sticky='w')
        else:
            choices.grid_remove()
    ttk.Checkbutton(frm, text='Generate maps (slow)', variable=maps,
                    command=show_choices).grid(column=0, row=7, columnspan=3, sticky='w')

    log = tk.Text(frm, width=74, height=10, state='disabled', wrap='word')
    log.grid(column=0, row=9, columnspan=3, pady=8, padx=10)
    bar = ttk.Progressbar(frm, mode='indeterminate', length=520)
    bar.grid(column=0, row=10, columnspan=3)

    buttons = ttk.Frame(frm)
    buttons.grid(column=0, row=11, columnspan=3, pady=(8, 0), sticky='e')

    def check():
        notes = []
        g = gmod_var.get().strip()
        if not g:
            notes.append("Garry's Mod wasn't found automatically: choose its folder.")
        elif not is_gmod(g):
            notes.append("That folder isn't Garry's Mod: choose the one with the garrysmod folder inside.")
        elif not on_x64_branch(g):
            notes.append("Garry's Mod isn't on the x86-64 branch yet. In Steam: right-click Garry's Mod > Properties > Betas > choose x86-64, then let it update. SkateGM needs it.")
        if g and is_gmod(g):
            old = outdated_maps(g)
            if old:
                notes.append(f"{len(old)} of your Skate 3 maps came from an older SkateGM ({', '.join(old)}). Tick Generate maps to "
                             "rebuild them: friends whose map differs from yours can't join you.")
        has = data_ready(data_var.get().strip() or DEFAULT_DATA)
        if has:
            reuse_box.state(['!disabled'])
        else:
            reuse.set(False)
            reuse_box.state(['disabled'])
        status.set('\n'.join(notes))

    def say(text):
        text = text.rstrip('\n')
        if not text:
            return

        def put():
            log.configure(state='normal')
            log.insert('end', text + '\n')
            log.see('end')
            log.configure(state='disabled')
        root.after(0, put)

    def busy(on):
        for b in buttons.winfo_children():
            b.state(['disabled'] if on else ['!disabled'])
        if on:
            bar.start(12)
        else:
            bar.stop()

    def run(job):
        busy(True)

        def work():
            try:
                job()
            except Exception as error:
                traceback.print_exc()
                message = str(error) or type(error).__name__
                say('ERROR: ' + message)
                root.after(0, lambda: messagebox.showerror(TITLE, message))
            finally:
                root.after(0, lambda: (busy(False), check()))
        threading.Thread(target=work, daemon=True).start()

    def do_install():
        g, x, d = gmod_var.get().strip(), xex_var.get().strip(), data_var.get().strip() or str(DEFAULT_DATA)
        if not is_gmod(g):
            return messagebox.showerror(TITLE, "Choose your Garry's Mod folder first.")
        if not reuse.get() and not x:
            return messagebox.showerror(TITLE, 'Choose your Skate 3 disc image (.iso) or default.xex first.')
        chosen = [name for name, var in picks.items() if var.get()]
        build = maps.get() and (bool(chosen) or not picks)
        run(lambda: install(g, x, d, say, skip_convert=reuse.get(), build_maps=build, map_names=chosen or None))

    def do_uninstall():
        g = gmod_var.get().strip()
        if not is_gmod(g):
            return messagebox.showerror(TITLE, "Choose your Garry's Mod folder first.")
        if not messagebox.askyesno(TITLE, 'Remove SkateGM from Garry\'s Mod?'):
            return
        remove = messagebox.askyesno(TITLE, 'Also delete your converted game data? (You can always convert it again from your game.)')
        run(lambda: uninstall(g, data_var.get().strip() or DEFAULT_DATA, say, remove))

    class LogStream:
        def write(self, text):
            for line in str(text).splitlines():
                say(line)

        def flush(self):
            pass
    sys.stdout = sys.stderr = LogStream()

    ttk.Button(buttons, text='Uninstall', command=do_uninstall).grid(column=0, row=0, padx=6)
    ttk.Button(buttons, text='Install', command=do_install).grid(column=1, row=0, padx=6)
    check()
    root.mainloop()


def main():
    import multiprocessing
    multiprocessing.freeze_support()
    if sys.stdout is None:
        try:
            sys.stdout = open(1, 'w', encoding='utf-8', errors='replace', closefd=False)
        except OSError:
            sys.stdout = open(os.devnull, 'w')
    if sys.stderr is None:
        sys.stderr = sys.stdout
    if len(sys.argv) > 2 and sys.argv[1] == '--task':
        import convert as exporter
        return exporter.run_task(sys.argv[2], sys.argv[3:])
    if len(sys.argv) == 1:
        window()
        return 0
    parser = argparse.ArgumentParser(description=TITLE)
    parser.add_argument('--gmod', type=Path)
    parser.add_argument('--xex', type=Path)
    parser.add_argument('--data', type=Path, default=DEFAULT_DATA)
    parser.add_argument('--skip-convert', action='store_true')
    parser.add_argument('--build-maps', action='store_true', help='build the Skate 3 maps (slow)')
    parser.add_argument('--no-maps', action='store_true', help="don't build the Skate 3 maps (the default)")
    parser.add_argument('--maps', help='build only these maps (comma separated, e.g. sgm_skate3_maloof)')
    parser.add_argument('--uninstall', action='store_true')
    parser.add_argument('--remove-data', action='store_true')
    parser.add_argument('--find', action='store_true', help="just print where Garry's Mod is")
    args = parser.parse_args()
    gmod = args.gmod or find_gmod()
    if args.find:
        print(gmod or 'not found', '(x86-64 branch)' if gmod and on_x64_branch(gmod) else '')
        return 0 if gmod else 1
    if not gmod:
        print("ERROR: Garry's Mod wasn't found: pass --gmod <folder>")
        return 2
    try:
        if args.uninstall:
            uninstall(gmod, args.data, print, args.remove_data)
        else:
            if not on_x64_branch(gmod):
                print("WARNING: Garry's Mod isn't on the x86-64 branch (Steam > Properties > Betas > x86-64); SkateGM needs it.")
            names = [n.strip() for n in args.maps.split(',') if n.strip()] if args.maps else None
            install(gmod, args.xex, args.data, print, skip_convert=args.skip_convert, build_maps=(args.build_maps or bool(names)) and not args.no_maps,
                    map_names=names)
    except Exception as error:
        traceback.print_exc()
        print('ERROR: ' + str(error))
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
