import os
import struct
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "exporter"))
from mapgen import bake, clip, models, regions, skatecol, vmf
from mapgen.coords import Frame
from mapgen.install import region_key
from mapgen.scene import Collision, Mesh, Rail, Scene, _segment_points
from mapgen.source import GameSource


def check(label, ok):
    print("%-74s %s" % (label, "OK" if ok else "<-- WRONG"))


f = Frame()
p = f.point(np.array([[1.0, 2.0, 3.0]]))[0]
check("Skate space (metres, Y up) -> Source (inches, Z up): x, -z, y", np.allclose(p, np.array([1.0, -3.0, 2.0]) / 0.0254))
check("... and directions keep their length", np.allclose(f.direction(np.array([[0.0, 1.0, 0.0]]))[0], [0.0, 0.0, 1.0]))
c = Frame.centred(np.array([-10.0, 0.0, -20.0]), np.array([10.0, 4.0, 20.0]))
mid = c.point(np.array([[0.0, 2.0, 0.0]]))[0]
check("a centred frame puts the middle of the area at the origin", np.allclose(mid, 0.0))
a, b = np.array([[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]]), np.array([[0.0, 0.0], [0.0, 1.0], [1.0, 0.0]])
check("2D cross product (numpy 2 has none)", bake.cross2(a[1] - a[0], a[2] - a[0]) == 1.0 and bake.cross2(b[1] - b[0], b[2] - b[0]) == -1.0)

area = clip.Area(((0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)), (-5.0, 5.0))
inside = area.contains(np.array([[5.0, 0.0, 5.0], [15.0, 0.0, 5.0], [5.0, 9.0, 5.0], [-1.0, 0.0, -1.0]]))
check("region: inside the four corners and the height range", list(inside) == [True, False, False, False])
diamond = clip.Area(((5.0, 0.0), (10.0, 5.0), (5.0, 10.0), (0.0, 5.0)))
check("... any four corners, not only boxes", list(diamond.contains(np.array([[5.0, 0.0, 5.0], [1.0, 0.0, 1.0]]))) == [True, False])

positions = np.array([[1.0, 0.0, 1.0], [2.0, 0.0, 1.0], [1.0, 0.0, 2.0], [20.0, 0.0, 20.0], [21.0, 0.0, 20.0], [20.0, 0.0, 21.0]], np.float32)
mesh = Mesh("m", positions, np.array([[0, 1, 2], [3, 4, 5]]), np.zeros((6, 2), np.float32), np.tile([0.0, 1.0, 0.0], (6, 1)).astype(np.float32),
            np.zeros((6, 2), np.float32), "m", np.ones((6, 2), np.float32))
rail = Rail(np.array([[1.0, 0.5, 1.0], [5.0, 0.5, 1.0], [15.0, 0.5, 1.0], [16.0, 0.5, 1.0]], np.float32))
tris = np.array([positions[[0, 1, 2]], positions[[3, 4, 5]]])
scene = Scene(Path("."), "D", {}, {"m": object()}, [mesh], Collision(tris, np.array([1, 2], np.uint32)), [rail])
cropped = clip.crop(scene, area)
check("crop keeps the triangles inside (render and collision)", len(cropped.meshes) == 1 and len(cropped.meshes[0].faces) == 1 and len(cropped.collision.triangles) == 1)
check("... with their vertices, UVs and decal UVs re-indexed", len(cropped.meshes[0].positions) == 3 and cropped.meshes[0].decal_uvs.shape == (3, 2))
check("... and cuts rails at the edge", len(cropped.rails) == 1 and len(cropped.rails[0].points) == 2)

payload = struct.pack(">30f", *([-2.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 3.0, 1.0] + [0.0] * 14))
pts = _segment_points(payload, 4)
check("grind rail segments are cubic: P(t) = ((A t + B) t + C) t + D", np.allclose(pts[0], [1, 2, 3]) and np.allclose(pts[-1], [2, 2, 3]))

tri = np.array([[[0.0, 0.0, 0.0], [10.0, 0.0, 0.0], [0.0, 10.0, 0.0]]], np.float32)
data = skatecol.encode(tri, np.array([5]), [(np.array([[0.0, 0.0, 1.0], [9.0, 0.0, 1.0]]), False)])
t2, s2, r2 = skatecol.decode(data)
check("the packed skate collision reads back exactly", np.array_equal(t2, tri) and list(s2) == [5] and np.allclose(r2[0][0][1], [9, 0, 1]))
check("... and the module's reader agrees on the layout (magic, version, counts)", data[:4] == b"SK3C" and struct.unpack_from("<III", data, 4) == (1, 1, 1))

from mapgen import tone
check("tone curve: dark kept, bright compressed below white, monotonic", tone.filmic(0.0) == 0.0 and tone.filmic(10.0) < 1.0 and np.all(np.diff(tone.filmic(np.linspace(0, 8, 50))) > 0))
check("... per vertex: light x mean albedo goes through the same curve", abs(float(tone.vertex_light(np.array([2.0]), np.array([0.5]))[0]) * 0.5 - float(tone.filmic(1.0))) < 1e-12)
check("sRGB <-> linear through tables (same result on every CPU)", all(int(bake.linear_to_srgb8(bake.srgb_to_linear(np.array([v], np.uint8)))[0]) == v for v in range(256)))
check("mip level choice without log2", bake.half_log2_floor(1.0) == 0 and bake.half_log2_floor(4.0) == 1 and bake.half_log2_floor(15.9) == 1 and bake.half_log2_floor(16.0) == 2)
diffuse = np.zeros((8, 8, 4), np.uint8)
diffuse[...] = (200, 100, 50, 255)
lightmap = np.zeros((4, 4, 4), np.uint8)
lightmap[...] = (64, 64, 64, 255)
lm_uv = np.array([[0.0, 0.0], [1.0, 0.0], [0.0, 1.0], [1.0, 1.0]])
faces = np.array([[0, 1, 2], [1, 3, 2]])
entry = bake.Entry(diffuse, lm_uv, lm_uv * 2, faces)
page = bake.bake_page("0x1", lightmap, [entry], False)
lit = bake.linear_to_srgb8(bake.filmic(bake.srgb_to_linear(np.array([200, 100, 50], np.uint8)) * (64 / 255.0) * bake.LIGHTMAP_SCALE))
check("baking: diffuse x lightmap x 4 through the tone curve, filled edge to edge", np.all(page.rgba[..., :3] == lit))
again = bake.bake_page("0x1", lightmap, [entry], False)
check("... and the same every time", np.array_equal(page.rgba, again.rgba))
decal = np.zeros((4, 4, 4), np.uint8)
decal[...] = (0, 0, 255, 255)
with_decal = bake.bake_page("0x1", lightmap, [bake.Entry(diffuse, lm_uv, lm_uv, faces, False, decal, lm_uv)], False)
check("... a decal layer covers the surface where its alpha is", with_decal.rgba[0, 0, 2] > with_decal.rgba[0, 0, 0])

v = vmf.Vmf()
v.shell(np.array([-100.0, -100.0, 0.0]), np.array([100.0, 100.0, 200.0]))
v.entity("info_player_start", origin=(0, 0, 16))
text = v.text("sky_day01_01")
check("the map is sealed by a sky shell (6 brushes) with entities after the world", text.count("solid\n") == 6 and text.index("world") < text.index("info_player_start"))
check("... and stays inside Source's limits", "16384" not in text and all(abs(float(x)) <= 16000 for x in __import__("re").findall(r"\((-?[\d.]+) ", text)))

prism = models.prism(np.array([[0.0, 0.0, 0.0], [64.0, 0.0, 0.0], [0.0, 64.0, 0.0]]))
check("Source collision: each triangle becomes a thin convex prism under it", prism is not None and np.allclose(prism[1][0][2], -models.PIECE_THICKNESS))
check("... slivers are skipped (they break studiomdl's hulls)", models.prism(np.array([[0.0, 0.0, 0.0], [64.0, 0.0, 0.0], [32.0, 0.01, 0.0]])) is None)

r = regions.REGIONS[0]
check("every region has a unique sgm_ map name", len({x.map_name for x in regions.REGIONS}) == len(regions.REGIONS) and all(x.map_name.startswith("sgm_") for x in regions.REGIONS))
check("regions are found by name, with or without sgm_", regions.by_name(r.map_name) is r and regions.by_name(r.name) is r)
check("a region's build key changes when its definition does", region_key(r) != region_key(regions.Region(r.name, r.title, r.district, corners=((0, 0), (1, 0), (1, 1), (0, 1)))))

with tempfile.TemporaryDirectory() as tmp:
    game = Path(tmp) / "Skate 3"
    (game / "data" / "content").mkdir(parents=True)
    (game / "data" / "content" / "worldDIST_X.big").write_bytes(b"x")
    (game / "default.xex").write_bytes(b"x")
    src = GameSource(game / "default.xex", Path(tmp) / "cache")
    check("game source: default.xex or its folder, files found under data/", src.district("DIST_X").name == "worldDIST_X.big")
    try:
        GameSource(Path(tmp) / "nothing", Path(tmp) / "cache")
        check("... and a wrong path is refused", False)
    except FileNotFoundError:
        check("... and a wrong path is refused", True)

from mapgen import skybox
from mapgen.environment import Sky

ring = []
uvs = []
steps = 32
for i in range(steps + 1):
    az = 2 * np.pi * i / steps
    for el, v in ((0.0, 0.9), (0.6, 0.1)):
        ring.append([np.cos(az) * np.cos(el), np.sin(el), np.sin(az) * np.cos(el)])
        uvs.append([i / steps + 0.125, v])
faces = []
for i in range(steps):
    a, b, c, d = 2 * i, 2 * i + 1, 2 * i + 2, 2 * i + 3
    faces += [[a, c, b], [b, c, d]]
bands = np.zeros((8, 64, 4), np.uint8)
bands[..., 3] = 255
palette = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
for k, colour in enumerate(palette):
    bands[:, k * 16:(k + 1) * 16, :3] = colour
sky = Sky(np.array([0.0, 1.0, 0.0]), 100.0, 2000.0, (0.1, 0.1, 0.1), 0.5, np.array(ring) * 5000, np.array(uvs), np.array(faces), bands)
rendered = skybox.render(sky, Frame(), size=64)


def colour_at(face_name):
    image = rendered[face_name]
    return tuple(int(c) for c in image[30, 32, :3])


check("skybox: Source's rt face looks along +X (Skate +X)", colour_at("rt")[0] > 200 and colour_at("rt")[1] < 60)
check("... bk along +Y (Skate -Z), lf along -X, ft along -Y", colour_at("bk")[0] > 200 and colour_at("bk")[1] > 200
      and colour_at("lf")[2] > 200 and colour_at("ft")[1] > 200 and colour_at("ft")[0] < 60)
check("... below the dome is filled with the horizon colour", tuple(rendered["dn"][32, 32, :3]) != (0, 0, 0))
again = skybox.render(sky, Frame(), size=64)
check("... and the same every time", all(np.array_equal(rendered[k], again[k]) for k in rendered))

from mapgen import props, surfaces

identity = np.eye(4)
check("movable objects: Skate's identity becomes Source yaw -90 (studiomdl turns models 90 degrees)", props.angles(props.placed_rotation(identity)) == (0.0, -90.0, 0.0))
turn = np.eye(4)
c, s_ = np.cos(np.radians(90)), np.sin(np.radians(90))
turn[:3, :3] = np.array([[c, 0, -s_], [0, 1, 0], [s_, 0, c]])
check("... a turn about Skate's up axis is a yaw in Source", abs(props.angles(props.source_rotation(turn))[0]) < 1e-6 and abs(props.angles(props.source_rotation(turn))[2]) < 1e-6
      and abs(abs(props.angles(props.source_rotation(turn))[1]) - 90) < 1e-6)
check("... mass grows with size, within limits", props.mass(props.Template("a", [], np.array([0.5, 0.5, 0.5]))) < props.mass(props.Template("b", [], np.array([2.0, 1.0, 2.0])))
      and props.mass(props.Template("c", [], np.array([50.0, 50.0, 50.0]))) == props.MAX_MASS)


builder = surfaces.Builder.__new__(surfaces.Builder)
builder.budget = 3 * 1024 * 1024
big = np.zeros((64, 64, 4), np.uint8)
uv = np.array([[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]])
entry = bake.Entry(np.zeros((2048, 2048, 4), np.uint8), uv, uv * 1.0, np.array([[0, 1, 2]]))
fitted = builder._fit_budget([(f"0x{i}", big, [entry], False, 2048) for i in range(3)])
caps = [job[4] for job in fitted]
check("texture budget: the biggest pages are halved until the map fits", sum(c * c for c in caps) <= 3 * 1024 * 1024 and max(caps) <= 1024)

from mapgen import vertexlight
import struct as _struct

lm_img = np.zeros((16, 16, 4), np.uint8)
lm_img[..., :3] = 60
lm_img[:, 8:, :3] = 240
light = vertexlight.Lightmap(lm_img)
quad = Mesh("m", np.array([[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]], np.float32), np.array([[0, 1, 2], [0, 2, 3]]),
            np.array([[0, 0], [1, 0], [1, 1], [0, 1]], np.float32), np.tile([0.0, 1.0, 0.0], (4, 1)).astype(np.float32),
            np.array([[0, 0], [1, 0], [1, 1], [0, 1]], np.float32))
pos, uvs_, nrm, cols, faces_ = vertexlight.subdivide(quad, light)
check("vertex lighting: a shadow edge inside a face splits it there", len(faces_) > 2 and faces_.max() < len(pos))
flat = np.zeros((16, 16, 4), np.uint8)
flat[..., :3] = 120
check("... flat light leaves the face alone", len(vertexlight.subdivide(quad, vertexlight.Lightmap(flat))[4]) == 2)
check("... colours are Skate's lightmap x 4, linear", np.allclose(vertexlight.Lightmap(flat).sample(np.array([[0.5, 0.5]])), 120 / 255 * bake.LIGHTMAP_SCALE))
vp = np.random.RandomState(5).rand(50, 3) * 100
vu = np.random.RandomState(6).rand(50, 2)
vc = np.random.RandomState(7).rand(50, 3)
perm = np.random.RandomState(8).permutation(50)
out, mask = vertexlight.match_colours(vp[perm], vu[perm], vp, vu, vc)
check("... compiled vertices find their colours in any order", mask.all() and np.allclose(out, vc[perm]))
with tempfile.TemporaryDirectory() as tmp:
    mdl = Path(tmp) / "m.mdl"
    mdl.write_bytes(b"IDST" + _struct.pack("<iI", 48, 0xDEADBEEF) + bytes(400))
    vhv = Path(tmp) / "sp_0.vhv"
    vertexlight.write_vhv(vhv, mdl, [3, 2], np.full((5, 3), 2.0))
    data = vhv.read_bytes()
    head = _struct.unpack_from("<IIIIIi", data, 0)
    first = _struct.unpack_from("<III", data, 40)
    check("... vhv files: version 2, the model's checksum, 4-byte colours, padded to 512", head[:5] == (2, 0xDEADBEEF, 4, 4, 5)
          and head[5] == 2 and first == (0, 3, 512) and len(data) % 512 == 0 and data[512:516] == bytes([128, 128, 128, 255]))

import tempfile
from mapgen import install
with tempfile.TemporaryDirectory() as tmp:
    maps = Path(tmp)
    (maps / 'thumb').mkdir()
    for n in ('sgm_maloof', 'sgm_megapark', 'sgm_skate3_maloof', 'sgm_warehouse_other'):
        (maps / f'{n}.bsp').write_bytes(b'x')
        (maps / 'thumb' / f'{n}.png').write_bytes(b'x')
    state = {'sgm_maloof': {}, 'sgm_skate3_maloof': {}}
    install.retire(maps, state, report=lambda *_: None)
    left = sorted(p.stem for p in maps.glob('*.bsp'))
    thumbs = sorted(p.stem for p in (maps / 'thumb').glob('*.png'))
check("maps that are no longer offered (old names, removed parks) are cleaned up", left == ['sgm_skate3_maloof'] and thumbs == ['sgm_skate3_maloof'] and list(state) == ['sgm_skate3_maloof'])
check("game maps are named sgm_skate3_*", all(r.map_name.startswith('sgm_skate3_') for r in regions.REGIONS) and regions.by_name('sgm_skate3_maloof').name == 'maloof')

from mapgen import mdlwrite, vertexlight
from mapgen.models import Chunk, Part
with tempfile.TemporaryDirectory() as tmp:
    tri = np.array([[[0, 0, 0], [10, 0, 0], [0, 10, 0]], [[10, 0, 0], [10, 10, 0], [0, 10, 0]]], np.float64)
    part = Part('skategm/t/mat', tri, np.tile([0.0, 0.0, 1.0], (2, 3, 1)), np.array([[[0, 0], [1, 0], [0, 1]], [[1, 0], [1, 1], [0, 1]]], np.float64))
    chunk = Chunk('m', np.zeros(3))
    chunk.parts = [part]
    mdlwrite.write(chunk, tmp, 'skategm/t', 'skategm/t', lambda p: p)
    pos, uv = vertexlight.read_vvd(Path(tmp) / 'm.vvd')
    groups = vertexlight.vtx_order(Path(tmp) / 'm.dx90.vtx', vertexlight.mdl_meshes(Path(tmp) / 'm.mdl'))
    check("models written directly: shared vertices once, turned like studiomdl, the readers find them", len(pos) == 4 and sorted(map(tuple, pos.round(3))) == sorted(map(tuple, mdlwrite.turn(tri.reshape(-1, 3)).round(3)[[0, 1, 2, 4]])) and len(groups) == 1 and len(groups[0]) == 4)
    dup = Part('skategm/t/mat', np.concatenate([tri, tri[:1]]), np.tile([0.0, 0.0, 1.0], (3, 3, 1)), np.concatenate([part.uvs, part.uvs[:1]]))
    v, f = mdlwrite._mesh(dup, np.zeros(3), lambda p: p)
    check("... duplicate triangles collapse (as studiomdl does)", len(f) == 2)
