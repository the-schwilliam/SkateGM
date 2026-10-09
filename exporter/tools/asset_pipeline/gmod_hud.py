"""Skate 3's own trick display, laid out the way Garry's Mod reads it
(gm_sk8 addition, from the contributor's prepare_gmod_hud.py in GitHub PR #4).

prepare_hud.py (SK8-ENGINE/skate-3-rust-engine) writes the movie and its raw
RGBA textures; this turns them into:
  runtime/trickdisplay.json        the movie, for skategm.HudLoad
  <texture path>.png               each texture
  <texture path>.mask.png          its alpha as white (for the colour-add pass)
"""
import json
import shutil
import struct
import zlib
from pathlib import Path


def png(path, width, height, rgba):
    rows = b"".join(b"\x00" + rgba[y * width * 4:(y + 1) * width * 4] for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def lay_out(work, out, report=print):
    work, out = Path(work), Path(out)
    movie = json.loads((work / "runtime/trickdisplay.json").read_text(encoding="utf-8"))
    (out / "runtime").mkdir(parents=True, exist_ok=True)
    shutil.copyfile(work / "runtime/trickdisplay.json", out / "runtime/trickdisplay.json")
    textures = {}
    for shapes in movie["shapes"].values():
        for s in shapes:
            t = s["texture"]
            textures[t["rgba"]] = (t["width"], t["height"])
    for asset in movie.get("fonts", {}).values():
        if asset and asset.get("texture") and asset.get("preview"):
            head = (work / asset["preview"]).read_bytes()[16:24]
            textures.setdefault(asset["texture"], struct.unpack(">II", head))
    count = 0
    for rel, (w, h) in sorted(textures.items()):
        raw = (work / rel).read_bytes()
        if len(raw) != w * h * 4:
            report(f"trick display: skipped {rel}: {len(raw)} bytes for {w}x{h}")
            continue
        base = out / rel[:-len(".rgba")]
        png(base.with_name(base.name + ".png"), w, h, raw)
        mask = bytearray(raw)
        for i in range(0, len(mask), 4):
            mask[i] = mask[i + 1] = mask[i + 2] = 255
        png(base.with_name(base.name + ".mask.png"), w, h, bytes(mask))
        count += 1
    return count
