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
WORKSHOP_ID = '3819058525'
WORKSHOP_URL = (f'https://steamcommunity.com/sharedfiles/filedetails/?id={WORKSHOP_ID}' if WORKSHOP_ID
                else 'https://steamcommunity.com/workshop/browse/?appid=4000&searchtext=SkateGM')
DEFAULT_DATA = Path(os.environ.get('LOCALAPPDATA', str(Path.home()))) / 'SkateGM' / 'data'


def payload_dir(name):
    """Where a payload part is: bundled, or (running from source) the repo."""
    bundled = PAYLOAD / name
    if bundled.exists():
        return bundled
    repo = Path(__file__).resolve().parent.parent
    if name == 'addon':
        return repo / 'addon' / 'skategm'
    if name == 'aems_render.exe':
        return repo / 'engine' / 'target' / 'release' / 'examples' / name
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


def installed(gmod):
    return (Path(gmod) / 'garrysmod' / 'lua' / 'bin' / DLL).is_file()


def data_ready(data):
    assets = Path(data) / 'assets'
    return all((assets / f).is_file() for f in ('private/skater.glb', 'private/game.json', 'private/stock/physics-skeletons.json'))


def data_folder(data, report=None):
    import datafolder
    chosen = Path(data).resolve()
    actual = datafolder.usable(chosen)
    if report and actual != chosen:
        report(f'{chosen} already has other files in it, so the game data goes in {actual} '
               '(SkateGM never deletes anything it did not create).')
    return actual


def convert(xex, data, report):
    import convert as exporter
    report('Converting your game data (a few minutes)...')
    return exporter.convert(Path(xex), Path(data))


IN_USE = "Some SkateGM files are in use: close Garry's Mod (and any window showing its addons folder) and try again."


def remove_tree(path):
    """Delete a folder completely, or say clearly why it can't be."""
    if not path.exists():
        return
    shutil.rmtree(path, ignore_errors=True)
    if path.exists():
        raise RuntimeError(IN_USE)


def install(gmod, xex, data, report, skip_convert=False, build_maps=True, map_names=None, skate2=None, install_addon=False):
    gmod = Path(gmod)
    if not is_gmod(gmod):
        raise RuntimeError(f"{gmod} doesn't look like Garry's Mod (no garrysmod folder).")
    garrysmod = gmod / 'garrysmod'
    data = data_folder(data, report)
    if skip_convert and data_ready(data):
        report('Game data: already converted, keeping it')
    else:
        if not xex:
            raise RuntimeError("Choose your Skate 3 disc image (.iso) or default.xex.")
        data = convert(xex, data, report)
        remember_source(data, xex)
    if not data_ready(data):
        raise RuntimeError('The game data conversion did not finish.')
    for old in OLD_ADDONS:
        if not install_addon and (garrysmod / 'addons' / old).exists():
            report(f'Removing the add-on copy in addons/{old} (it would clash with the Workshop one)...')
        remove_tree(garrysmod / 'addons' / old)
    for old in OLD_FILES:
        (garrysmod / old).unlink(missing_ok=True)
    if install_addon:
        report('Installing the add-on...')
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
    install_sounds(gmod, xex or remembered_source(data), data, report)
    install_hud(garrysmod, xex or remembered_source(data), data, report)
    install_music(gmod, xex or remembered_source(data), data, report)
    if skate2:
        remember_source(data, skate2, 'skate2')
    if build_maps:
        install_maps(gmod, xex or remembered_source(data), data, report, map_names,
                     skate2 or remembered_source(data, 'skate2'))
    if not install_addon:
        report('Subscribe to SkateGM on the Steam Workshop if you haven\'t: ' + WORKSHOP_URL)
    report('Done! Start Garry\'s Mod and pick the SkateGM gamemode, or in any other gamemode type '
           '"bind j skategm_toggle" in the console once and press J.')


def _source_file(data, game):
    return Path(data) / ('source.txt' if game == 'skate3' else f'source_{game}.txt')


def remember_source(data, xex, game='skate3'):
    try:
        _source_file(data, game).write_text(str(Path(xex).resolve()), encoding='utf-8')
    except OSError:
        pass


def remembered_source(data, game='skate3'):
    try:
        path = Path(_source_file(data, game).read_text(encoding='utf-8').strip())
    except OSError:
        return None
    return path if path.exists() else None


def install_hud(garrysmod, game, data, report):
    """Skate 3's own trick display, from the player's game, where the add-on reads it."""
    prepared = Path(data) / 'assets' / 'private' / 'gmod_hud'
    if not (prepared / 'runtime' / 'trickdisplay.json').is_file() and game:
        try:
            import convert as exporter
            exporter.prepare_hud(Path(game), Path(data))
        except Exception as error:
            traceback.print_exc()
            report("Skate 3's trick display was skipped: " + (str(error) or type(error).__name__))
    target = garrysmod / 'data' / 'skategm_hud'
    if (prepared / 'runtime' / 'trickdisplay.json').is_file():
        shutil.rmtree(target, ignore_errors=True)
        shutil.copytree(prepared, target)
        report("Skate 3's trick display: installed")


def install_sounds(gmod, game, data, report):
    """Skate 3's own board sounds, from the player's game (a few seconds)."""
    try:
        from tools.asset_pipeline import skate3_sounds
        import convert as exporter
        if skate3_sounds.installed(gmod, exporter.hud_sounds(data)):
            report('Skate 3 board sounds: already installed, keeping them')
            return
    except Exception:
        traceback.print_exc()
    if not game:
        report('Skate 3 board sounds: choose your Skate 3 disc image (.iso) or default.xex to use them.')
        return
    try:
        import convert as exporter
        exporter.build_sounds(Path(game), Path(data), Path(gmod), payload_dir('vgmstream') / 'vgmstream-cli.exe',
                              payload_dir('aems_render.exe'))
    except Exception as error:
        traceback.print_exc()
        report('Skate 3 board sounds were skipped (the stock ones play): ' + (str(error) or type(error).__name__))


def install_music(gmod, game, data, report):
    try:
        from tools.asset_pipeline import skate3_music
        if skate3_music.installed(gmod):
            report('Skate 3 music: already installed, keeping it')
            return
    except Exception:
        traceback.print_exc()
    if not game:
        report('Skate 3 music: choose your Skate 3 disc image (.iso) or default.xex to hear its music while you skate.')
        return
    try:
        import convert as exporter
        report('Skate 3 music: decoding the songs (a couple of minutes)')
        exporter.build_music(Path(game), Path(data), Path(gmod), payload_dir('vgmstream') / 'vgmstream-cli.exe')
    except Exception as error:
        traceback.print_exc()
        report('Skate 3 music was skipped (no music while skating): ' + (str(error) or type(error).__name__))


def install_maps(gmod, game, data, report, names=None, skate2=None):
    if not game and not skate2:
        report('Maps: choose your Skate 3 (or Skate 2) disc image (.iso) or default.xex to build them.')
        return
    report('Building the maps (a few minutes each)...')
    try:
        from mapgen.install import install_maps as build_all
        built, failed = build_all({'skate3': game, 'skate2': skate2}, gmod, Path(data) / 'mapgen', report, names=names)
    except Exception as error:
        traceback.print_exc()
        report('Maps were skipped: ' + (str(error) or type(error).__name__))
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
    remove_tree(garrysmod / 'data' / 'skategm_hud')
    remove_tree(garrysmod / 'addons' / 'skategm_s3sounds')
    (garrysmod / 'data' / 'skategm' / 'skate3_sounds.json').unlink(missing_ok=True)
    remove_tree(garrysmod / 'addons' / 'skategm_s3music')
    (garrysmod / 'data' / 'skategm' / 'skate3_music.json').unlink(missing_ok=True)
    removed = False
    if remove_data:
        import datafolder
        try:
            removed = datafolder.remove(data_folder(data))
        except datafolder.NotOurs as error:
            report(str(error))
    report('SkateGM removed.' + (' Your converted game data was deleted too.' if removed else ''))


# --------------------------------------------------------------------------
# the window
# --------------------------------------------------------------------------
def map_choices():
    """[(section title, [(map name, label, game)])]"""
    try:
        from mapgen.install import sections
    except Exception:
        traceback.print_exc()
        return []
    return [(title, [(r.map_name, f'{r.title} ({r.map_name})', r.game) for r in maps]) for title, maps in sections()]


def outdated_maps(gmod):
    try:
        from mapgen import install as mapinstall
    except Exception:
        return []
    state = mapinstall.read_state(gmod)
    maps = mapinstall.addon_dir(gmod) / 'maps'
    return [r.map_name for r in mapinstall.catalog()
            if (maps / f'{r.map_name}.bsp').is_file() and state.get(r.map_name, {}).get('key') != mapinstall.region_key(r)]


def window():
    import tkinter as tk
    from tkinter import filedialog, messagebox, ttk

    root = tk.Tk()
    root.title(TITLE)
    root.resizable(True, True)
    pad = {'padx': 10, 'pady': 4}

    found = find_gmod()
    gmod_var = tk.StringVar(value=str(found) if found else '')
    xex_var = tk.StringVar()
    skate2_var = tk.StringVar()
    data_var = tk.StringVar(value=str(DEFAULT_DATA))

    outer = ttk.Frame(root)
    outer.pack(fill='both', expand=True)
    canvas = tk.Canvas(outer, highlightthickness=0, borderwidth=0,
                       background=ttk.Style().lookup('TFrame', 'background') or None)
    scroll = ttk.Scrollbar(outer, orient='vertical', command=canvas.yview)
    canvas.configure(yscrollcommand=scroll.set)
    canvas.pack(side='left', fill='both', expand=True)
    frm = ttk.Frame(canvas, padding=12)
    canvas.create_window((0, 0), window=frm, anchor='nw')

    def fit(_=None):
        w, h = frm.winfo_reqwidth(), frm.winfo_reqheight()
        room = max(300, root.winfo_screenheight() - 170)
        canvas.configure(scrollregion=(0, 0, w, h), width=w, height=min(h, room))
        root.after_idle(need_scroll)

    def need_scroll(_=None):
        if frm.winfo_reqheight() > canvas.winfo_height() > 1:
            if not scroll.winfo_ismapped():
                scroll.pack(side='right', fill='y', before=canvas)
        elif scroll.winfo_ismapped():
            scroll.pack_forget()
            canvas.yview_moveto(0)
    frm.bind('<Configure>', fit)
    canvas.bind('<Configure>', need_scroll)

    def wheel(e):
        if scroll.winfo_ismapped() and not str(e.widget).endswith('text'):
            canvas.yview_scroll(int(-e.delta / 120) or (-1 if e.delta > 0 else 1), 'units')
    root.bind_all('<MouseWheel>', wheel)
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

    def browse_skate2():
        f = filedialog.askopenfilename(title='Your Skate 2 disc image (.iso), or default.xex from an extracted copy',
                                       filetypes=[('Skate 2 disc image or default.xex', '*.iso default.xex'), ('Disc image', '*.iso'), ('default.xex', 'default.xex')])
        if f:
            skate2_var.set(f)

    def browse_data():
        d = filedialog.askdirectory(title='Where to keep the converted game data')
        if d:
            data_var.set(d)
            check()

    rows = [("Garry's Mod folder", gmod_var, browse_gmod), ('Skate 3 (.iso or default.xex)', xex_var, browse_xex),
            ('Skate 2, for its maps (optional)', skate2_var, browse_skate2), ('Converted data goes in', data_var, browse_data)]
    for i, (label, var, cmd) in enumerate(rows):
        ttk.Label(frm, text=label).grid(column=0, row=2 + i, sticky='w', **pad)
        ttk.Entry(frm, textvariable=var, width=58).grid(column=1, row=2 + i, **pad)
        ttk.Button(frm, text='Browse...', command=cmd).grid(column=2, row=2 + i, **pad)

    status = tk.StringVar()
    ttk.Label(frm, textvariable=status, wraplength=520, foreground='#a0522d').grid(column=0, row=6, columnspan=3, sticky='w', pady=(4, 0))
    opts = ttk.Frame(frm)
    opts.grid(column=0, row=7, columnspan=3, sticky='w')
    reuse = tk.BooleanVar(value=False)
    reuse_box = ttk.Checkbutton(opts, text='Keep the game data I already converted (skip converting)', variable=reuse)
    reuse_box.grid(column=0, row=0, columnspan=2, sticky='w')
    addon = tk.BooleanVar(value=False)
    ttk.Checkbutton(opts, text='Install add-on', variable=addon).grid(column=0, row=1, sticky='w')
    ttk.Label(opts, text='(You can also do this from the Workshop)', foreground='#808080').grid(column=1, row=1, sticky='w', padx=(6, 0))
    maps = tk.BooleanVar(value=False)
    choices = ttk.Frame(frm)
    picks, pick_game = {}, {}
    choices.columnconfigure(0, weight=1)
    choices.columnconfigure(1, weight=1)
    row = 0
    for title, mine in map_choices():
        heading = ttk.Frame(choices)
        heading.grid(column=0, row=row, columnspan=2, sticky='ew', padx=(24, 10), pady=(10 if row else 4, 2))
        heading.columnconfigure(1, weight=1)
        ttk.Label(heading, text=title, font=('Segoe UI', 10, 'bold'), foreground='#2b6cb0').grid(column=0, row=0, sticky='w')
        ttk.Separator(heading, orient='horizontal').grid(column=1, row=0, sticky='ew', padx=(8, 0))
        row += 1
        for i, (name, label, gid) in enumerate(mine):
            picks[name] = tk.BooleanVar(value=True)
            pick_game[name] = gid
            ttk.Checkbutton(choices, text=label, variable=picks[name]).grid(column=i % 2, row=row + i // 2, sticky='w', padx=(32, 12))
        row += (len(mine) + 1) // 2

    def show_choices():
        if maps.get() and picks:
            choices.grid(column=0, row=9, columnspan=3, sticky='ew')
        else:
            choices.grid_remove()
    ttk.Checkbutton(frm, text='Generate maps (slow)', variable=maps,
                    command=show_choices).grid(column=0, row=8, columnspan=3, sticky='w')

    log = tk.Text(frm, width=74, height=10, state='disabled', wrap='word')
    log.grid(column=0, row=10, columnspan=3, pady=8, padx=10)
    bar = ttk.Progressbar(frm, mode='indeterminate', length=520)
    bar.grid(column=0, row=11, columnspan=3)

    buttons = ttk.Frame(root, padding=(12, 4, 22, 12))
    buttons.pack(side='bottom', anchor='e', before=outer)

    seen = {}

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
        here = data_var.get().strip() or str(DEFAULT_DATA)
        has = data_ready(here)
        if has:
            reuse_box.state(['!disabled'])
            if seen.get('data') != here:
                reuse.set(True)
        else:
            reuse.set(False)
            reuse_box.state(['disabled'])
        seen['data'] = here
        install_button.configure(text='Update' if g and is_gmod(g) and installed(g) else 'Install')
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
        s2 = skate2_var.get().strip()
        chosen = [name for name, var in picks.items() if var.get()]
        build = maps.get() and (bool(chosen) or not picks)
        if build and not x and any(pick_game.get(n) == 'skate3' for n in chosen):
            return messagebox.showerror(TITLE, 'Generating Skate 3 maps needs your Skate 3 disc image (.iso): choose it first.')
        if build and not s2 and any(pick_game.get(n) == 'skate2' for n in chosen):
            if not messagebox.askokcancel(TITLE, 'Skate 2 maps need your Skate 2 disc image (.iso) or default.xex. '
                                                 'Without it they are skipped. Continue?'):
                return
        run(lambda: install(g, x, d, say, skip_convert=reuse.get(), build_maps=build, map_names=chosen or None, skate2=s2 or None,
                            install_addon=addon.get()))

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
    install_button = ttk.Button(buttons, text='Install', command=do_install)
    install_button.grid(column=1, row=0, padx=6)
    for var in (gmod_var, data_var):
        var.trace_add('write', lambda *_: check())
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
    parser.add_argument('--skate2', type=Path, help='Skate 2 disc image or default.xex, for its maps')
    parser.add_argument('--data', type=Path, default=DEFAULT_DATA)
    parser.add_argument('--skip-convert', action='store_true')
    parser.add_argument('--build-maps', action='store_true', help='build the Skate 3 maps (slow)')
    parser.add_argument('--no-maps', action='store_true', help="don't build the Skate 3 maps (the default)")
    parser.add_argument('--maps', help='build only these maps (comma separated, e.g. sgm_skate3_maloof)')
    parser.add_argument('--install-addon', action='store_true', help='install the add-on too (it also comes from the Workshop)')
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
                    map_names=names, skate2=args.skate2, install_addon=args.install_addon)
    except Exception as error:
        traceback.print_exc()
        print('ERROR: ' + str(error))
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
