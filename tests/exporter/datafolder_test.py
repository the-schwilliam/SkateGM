import os
import sys
import tempfile
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "exporter"))
sys.path.insert(0, str(HERE.parent.parent / "installer"))
import convert
import datafolder


def check(label, ok):
    print("%-74s %s" % (label, "OK" if ok else "<-- WRONG"))


def players_folder(root):
    folder = Path(root) / "Games"
    (folder / "Other Game").mkdir(parents=True)
    (folder / "Skate 3.iso").write_bytes(b"iso" * 1000)
    (folder / "notes.txt").write_text("mine")
    (folder / "Other Game" / "save.dat").write_bytes(b"save")
    return folder


def untouched(folder):
    return ((folder / "Skate 3.iso").read_bytes() == b"iso" * 1000 and (folder / "notes.txt").read_text() == "mine"
            and (folder / "Other Game" / "save.dat").read_bytes() == b"save")


def fake_exports():
    mod = types.ModuleType("tools.asset_pipeline.asset_exports")

    def core(game, stage, work, report, log):
        for f in ("private/skater.glb", "private/game.json", "private/stock/physics-skeletons.json",
                  "private/stock/skater-collections.json"):
            p = Path(stage) / "assets" / f
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("x")
        return {}

    mod.core = core
    mod.character = lambda *a: None
    mod.gmod_hud = lambda *a: None
    pkg = types.ModuleType("tools.asset_pipeline")
    pkg.asset_exports = mod
    sys.modules["tools.asset_pipeline"] = pkg
    sys.modules["tools.asset_pipeline.asset_exports"] = mod


def fake_game(root):
    game = Path(root) / "game"
    for f in convert.REQUIRED:
        (game / f).parent.mkdir(parents=True, exist_ok=True)
        (game / f).write_bytes(b"")
    return game


fake_exports()

with tempfile.TemporaryDirectory() as d:
    folder = players_folder(d)
    out = convert.convert_game(fake_game(d), folder)
    check("converting into a folder with other files leaves every one of them alone", untouched(folder))
    check("... the data goes in a 'SkateGM data' folder inside it", out == (folder / "SkateGM data").resolve()
          and (out / "assets" / "private" / "game.json").is_file())
    again = convert.convert_game(fake_game(d), folder)
    check("converting again reuses that folder and still touches nothing else", again == out and untouched(folder))
    check("... and leaves no staging or work folders behind", sorted(p.name for p in out.iterdir())
          == sorted([datafolder.MARKER, "assets", "conversion.log"]))

with tempfile.TemporaryDirectory() as d:
    folder = players_folder(d)
    try:
        datafolder.remove(folder)
        refused = False
    except datafolder.NotOurs:
        refused = True
    check("removing a folder SkateGM didn't make is refused", refused and untouched(folder))
    try:
        datafolder.replace(folder, "assets", Path(d) / "nothing")
        refused = False
    except datafolder.NotOurs:
        refused = True
    check("... and so is replacing anything in it", refused and untouched(folder))

with tempfile.TemporaryDirectory() as d:
    folder = players_folder(d)
    out = convert.convert_game(fake_game(d), folder)
    (out / "my own file.txt").write_text("keep")
    datafolder.remove(out)
    check("removing SkateGM's data takes only SkateGM's entries", not (out / "assets").exists()
          and (out / "my own file.txt").read_text() == "keep" and untouched(folder))

with tempfile.TemporaryDirectory() as d:
    legacy = Path(d) / "data"
    (legacy / "assets" / "private").mkdir(parents=True)
    (legacy / "conversion.log").write_text("")
    (legacy / "source.txt").write_text("")
    (legacy / "mapgen").mkdir()
    check("an older install's data folder (only SkateGM's entries) is recognised", datafolder.is_ours(legacy))
    (legacy / "photo.jpg").write_bytes(b"x")
    check("... but not once anything else is in it", not datafolder.is_ours(legacy)
          and datafolder.usable(legacy) == (legacy / "SkateGM data").resolve())
    check("an empty or missing folder is used as it is", datafolder.usable(Path(d) / "new") == (Path(d) / "new").resolve())

import setup_skategm

with tempfile.TemporaryDirectory() as d:
    folder = players_folder(d)
    out = convert.convert_game(fake_game(d), folder)
    gmod = Path(d) / "GarrysMod"
    (gmod / "garrysmod" / "addons").mkdir(parents=True)
    lines = []
    setup_skategm.uninstall(gmod, folder, lines.append, remove_data=True)
    check("uninstall with 'delete my data', pointed at the player's folder: their files stay",
          untouched(folder) and not out.exists())
    check("... and says the converted data went", any("deleted too" in l for l in lines))
    folder2 = players_folder(Path(d) / "second")
    setup_skategm.uninstall(gmod, folder2, lines.append, remove_data=True)
    check("... pointed at a folder with no SkateGM data in it: nothing is deleted", untouched(folder2))
