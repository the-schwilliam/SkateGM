import json
import math
import shutil
import time
from pathlib import Path

import numpy as np

from .mathutil import norm

from . import boundary, clip, decode, environment, models, pack, props, scene, skatecol, skybox, skyroom, surfaces, textures, thumbnail, vertexlight, views, vmf
from .coords import Frame
from .source import GameSource
from .sourcetools import Tools

SHELL_MARGIN = 768.0
SHELL_HEADROOM = 4096.0
MAP_FORMAT = 1
PROP_YAW = -90


class Timer:
    def __init__(self, report):
        self.report = report
        self.start = time.perf_counter()
        self.phases = {}

    def done(self, phase):
        now = time.perf_counter()
        self.phases[phase] = round(now - self.start, 2)
        self.report(f'{phase}: {self.phases[phase]:.1f} s')
        self.start = now


def spawn_point(triangles, region, frame):
    if region.spawn:
        return frame.point(np.asarray([region.spawn]))[0] + np.array([0, 0, 16.0])
    n = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
    length = norm(n)
    up = (length > 1e-6) & (n[:, 2] / np.maximum(length, 1e-12) > 0.95) & (length > 200.0)
    if not up.any():
        up = length > 1e-6
    centres = triangles[up].mean(1)
    middle = np.median(centres[:, :2], axis=0)
    distance = norm(centres[:, :2] - middle)
    tris = views.indexed(triangles)
    good = []
    for k in np.argsort(distance, kind='stable')[:SPAWN_TRIES]:
        point = centres[k].astype(np.float64)
        if views.clear_above(point, tris, SPAWN_HEADROOM) and views.outlook(point + np.array([0, 0, views.EYE]), tris,
                                                                         np.append(middle, point[2])):
            good.append(point)
            if len(good) == SPAWN_CHOICES:
                break
    if good:
        return min(enumerate(good), key=lambda e: (round(float(e[1][2]) / 32.0), e[0]))[1] + np.array([0, 0, 16.0])
    near = distance <= distance.min() + 64.0
    best = centres[near][np.argmin(centres[near][:, 2])]
    return best + np.array([0, 0, 16.0])


SPAWN_TRIES = 400
SPAWN_CHOICES = 24
SPAWN_HEADROOM = 160.0
SPAWN_OFFSETS = ((0, 0), (64, 0), (-64, 0), (0, 64), (0, -64), (64, 64), (-64, -64), (64, -64), (-64, 64))


def spawn_spots(spawn, triangles):
    tris = views.indexed(triangles)
    spots = []
    for dx, dy in SPAWN_OFFSETS:
        spot = spawn + np.array([dx, dy, 0.0])
        if (dx or dy) and not views.spot_ok(spawn, spot, tris):
            continue
        spots.append(spot)
    return spots


def spawn_heading(region, spawn, lo, hi, triangles=None):
    if region.spawn:
        return region.spawn_heading
    centre = (np.asarray(lo) + np.asarray(hi)) / 2
    if triangles is not None and len(triangles):
        look = views.outlook(spawn + np.array([0, 0, views.EYE - 16.0]), views.indexed(triangles), centre)
        if look:
            return round(look[0])
    d = centre - spawn
    if abs(d[0]) < 1 and abs(d[1]) < 1:
        return 0.0
    return round(float(np.degrees(np.arctan2(d[1], d[0]))))


def sun_angles(region, sky, frame):
    if sky is None:
        return region.sun[0], region.sun[1]
    s = frame.direction(sky.sun)
    d = -s / math.sqrt(float(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]))
    return round(math.degrees(math.asin(max(-1.0, min(1.0, float(d[2]))))), 1), round(math.degrees(math.atan2(float(d[1]), float(d[0]))), 1)


def fog_entity(v, sky, origin):
    colour = skybox.linear_to_srgb8(np.asarray(sky.fog_colour))
    v.entity('env_fog_controller', origin=origin, angles=(0, 0, 0), spawnflags=1, fogenable=1, fogblend=0,
             fogcolor=f'{colour[0]} {colour[1]} {colour[2]}', fogcolor2=f'{colour[0]} {colour[1]} {colour[2]}',
             fogstart=round(sky.fog_near / 0.0254), fogend=round(sky.fog_far / 0.0254),
             fogmaxdensity=round(sky.fog_max, 3), farz=-1, foglerptime=0, use_angles=0, targetname='fog')


def movable_props(source, cache, area, frame, prefix, work, report):
    try:
        loaded = props.load(source, cache, area, work / 'dmo', report)
    except (OSError, KeyError, ValueError, IndexError) as error:
        report(f'movable objects not available ({error})')
        return None, [], []
    if not loaded.instances:
        return None, [], []
    holder = scene.Scene(cache, '', loaded.textures, loaded.materials, [])
    builder = surfaces.Builder(holder, props.local_frame(), prefix, report=report)
    templates = []
    for key, template in loaded.templates.items():
        before = len(builder.out.meshes)
        for mesh in template.meshes:
            if loaded.materials[mesh.material].textures.get('diffuse'):
                builder._direct(mesh)
        made = builder.out.meshes[before:]
        if made:
            templates.append((key, made))
    chunks = models.physics_props(templates, 'm')
    by_key = {}
    for key, chunk in chunks:
        chunk.mass = props.mass(loaded.templates[key])
        by_key[key] = chunk
    placed = []
    for instance in loaded.instances:
        chunk = by_key.get(instance.template)
        if chunk is None:
            continue
        placed.append((chunk.name, props.origin(instance, frame), props.angles(props.placed_rotation(instance.matrix))))
    report(f'{len(placed)} movable objects ({len(by_key)} kinds)')
    return builder.out, [c for _, c in chunks], placed


def sky_camera(v, room, sky):
    v.shell(room.lo, room.hi)
    keys = {'origin': room.origin, 'angles': (0, 0, 0), 'scale': skyroom.SCALE, 'use_angles': 0, 'fogenable': 0}
    if sky is not None:
        colour = skybox.linear_to_srgb8(np.asarray(sky.fog_colour))
        keys.update(fogenable=1, fogblend=0, fogcolor=f'{colour[0]} {colour[1]} {colour[2]}',
                    fogcolor2=f'{colour[0]} {colour[1]} {colour[2]}', fogstart=round(sky.fog_near / 0.0254),
                    fogend=round(sky.fog_far / 0.0254), fogmaxdensity=round(sky.fog_max, 3))
    v.entity('sky_camera', **keys)


def write_vmf(path, region, chunks, model_dir, lo, hi, spawn, sky=None, frame=None, skyname=None, placed=(), room=None,
              brushes=(), collision=None, water=None):
    heading = spawn_heading(region, spawn, lo, hi, collision)
    v = vmf.Vmf()
    v.shell(lo - SHELL_MARGIN, hi + np.array([SHELL_MARGIN, SHELL_MARGIN, SHELL_HEADROOM]))
    if room is not None:
        sky_camera(v, room, sky)
    pitch, yaw = sun_angles(region, sky, frame)
    if sky is not None:
        fog_entity(v, sky, spawn + np.array([0, 0, 540.0]))
    v.entity('light_environment', origin=spawn + np.array([0, 0, 512.0]), angles=(0, yaw, 0), pitch=pitch,
             _light='255 238 214 300', _ambient='170 190 220 120', _lightHDR='-1 -1 -1 1', _ambientHDR='-1 -1 -1 1')
    v.entity('shadow_control', origin=spawn + np.array([0, 0, 520.0]), angles=(pitch, yaw, 0), color='90 90 100',
             distance=96, disableallshadows=0)
    for spot in (spawn_spots(spawn, collision) if collision is not None and len(collision) else [spawn]):
        v.entity('info_player_start', origin=spot, angles=(0, heading, 0))
    info = {'skategm_title': region.title}
    if len(region.corners) and region.walls and frame is not None:
        edge = frame.point(np.array([[x, 0.0, z] for x, z in region.corners], np.float64))
        info['skategm_boundary'] = ';'.join(f'{p[0]:.0f},{p[1]:.0f}' for p in edge)
    v.entity('info_target', origin=spawn, targetname='skategm_info', **info)
    for name, position, angle in placed:
        v.entity('prop_physics', origin=position, angles=angle, model=f'models/{model_dir}/{name}.mdl', spawnflags=9,
                 physdamagescale=0, fademindist=-1, fadescale=0)
    for chunk in chunks:
        if chunk.mass > 0:
            continue
        v.entity('prop_static', origin=chunk.origin, angles=(0, PROP_YAW, 0), model=f'models/{model_dir}/{chunk.name}.mdl',
                 solid=6 if chunk.collision is not None else 0, disableshadows=1, disablevertexlighting=0,
                 screenspacefade=0, fadescale=0, **(HIDDEN_FADE if not chunk.parts else {'fademindist': -1}))
    solids = [v.convex(faces, 'TOOLS/TOOLSINVISIBLE') for faces in (models.prism_faces(t) for t in brushes) if faces]
    if solids:
        v.brush_entity('func_detail', solids)
    if water is not None:
        top, material = water
        x0, y0 = float(lo[0]) - SHELL_MARGIN + 8, float(lo[1]) - SHELL_MARGIN + 8
        x1, y1 = float(hi[0]) + SHELL_MARGIN - 8, float(hi[1]) + SHELL_MARGIN - 8
        bottom = float(lo[2]) - SHELL_MARGIN + 8
        if top - bottom >= 8:
            v.solids.append(v.convex(box_faces((x0, y0, bottom), (x1, y1, top)), [material] + [NODRAW] * 5))
    Path(path).write_text(v.text(skyname or region.sky), encoding='ascii')


NODRAW = 'TOOLS/TOOLSNODRAW'


def box_faces(lo, hi):
    x0, y0, z0 = lo
    x1, y1, z1 = hi
    top = [np.array(p, np.float64) for p in ((x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1))]
    low = [np.array(p, np.float64) for p in ((x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0))]
    sides = [(top[i], top[(i + 1) % 4], low[(i + 1) % 4], low[i]) for i in range(4)]
    return [tuple(top), tuple(low)] + sides


def water_material(prefix, colour):
    r, g, b = colour
    return surfaces.SourceMaterial(f'{prefix}/water', 'Water', {
        '%compilewater': 1, '$abovewater': 1, '$forcecheap': 1, '$bottommaterial': 'nature/water_coast01_beneath',
        '$normalmap': 'nature/water_coast01_normal', '$envmap': 'env_cubemap', '$envmaptint': '[.5 .55 .6]',
        '$fogenable': 1, '$fogcolor': f'{{{r} {g} {b}}}', '$fogstart': 0, '$fogend': 600,
        '$reflecttint': f'{{{r} {g} {b}}}', '$surfaceprop': 'water'}, None)


WATER_REACH = 5500.0
HIDDEN_FADE = {'fademindist': 0, 'fademaxdist': 1}


def with_water(backdrop, sea, corners, work, report):
    if sea is None:
        return backdrop
    texture, material, meshes = environment.sea_plane(sea[0], sea[1], corners.mean(0), WATER_REACH, work)
    report(f'sea in the 3D skybox at {sea[0]} m')
    return scene.Scene(backdrop.root, backdrop.district, {**backdrop.textures, texture.id: texture},
                       {**backdrop.materials, material.key: material}, backdrop.meshes + meshes)


def build(region, game_root, gmod, out_dir, work_dir, report=print, workers=None, keep=False, fast=False):
    timer = Timer(report)
    work = Path(work_dir)
    name = region.map_name
    build_dir = work / 'build' / name
    if build_dir.exists():
        shutil.rmtree(build_dir)
    game = build_dir / 'game'
    src = build_dir / 'src'
    src.mkdir(parents=True)
    tools = Tools(gmod, game, log=build_dir / 'tools.log')
    source = game_root if isinstance(game_root, GameSource) else GameSource(game_root, work / 'disc')
    cache = decode.decode(source, region.district, work / 'districts', report)
    timer.done('decode')
    full = scene.load(cache)
    area = clip.Area(region.corners, region.y_range)
    cropped = clip.crop(full, area)
    corners = boundary.outline(region, cropped.collision.triangles)
    margin = boundary.scenery_margin(corners, region.scenery) if len(region.corners) else 0.0
    outer = area
    if margin > 0:
        outer = clip.Area(boundary.expanded(corners, margin), region.y_range)
        extra = clip.ring(full, outer, area)
        cropped.meshes += extra
        for mesh in extra:
            if mesh.material not in cropped.materials:
                cropped.materials[mesh.material] = full.materials[mesh.material]
    if region.walls and len(cropped.collision.triangles):
        ys = cropped.collision.triangles[:, :, 1]
        fence = boundary.walls(corners, float(ys.min()), float(ys.max()))
        cropped.collision = scene.Collision(np.concatenate([cropped.collision.triangles, fence]),
                                            np.concatenate([cropped.collision.surfaces, np.zeros(len(fence), np.uint32)]))
    lo, hi = cropped.bounds()
    if len(region.corners):
        edge = boundary.expanded(corners, margin)
        lo, hi = lo.copy(), hi.copy()
        lo[0], lo[2] = edge[:, 0].min(), edge[:, 1].min()
        hi[0], hi[2] = edge[:, 0].max(), edge[:, 1].max()
    frame = Frame.centred(lo, hi)
    timer.done('scene')
    prefix = f'skategm/{name}'
    surf = surfaces.Builder(cropped, frame, prefix, workers, report, work / 'bakecache' / region.district,
                            vertex_lighting=region.vertex_lighting,
                            light_detail=tuple(region.light_detail) or None).build()
    timer.done('bake')
    moving, prop_chunks, placed = movable_props(source, cache, area, frame, prefix, work, report)
    room = None
    sea = None
    if len(region.corners):
        try:
            sea = environment.sea(source, region.district, work / 'env')
        except (OSError, KeyError, ValueError, IndexError) as error:
            report(f'water not available ({error})')
    if len(region.corners) and region.skybox:
        if region.backdrop:
            proxy = decode.decode_proxy(source, region.district, work / 'districts', report)
            backdrop = scene.load(proxy, collision=False, fallback_textures=full.textures) if proxy else full
        else:
            backdrop = scene.Scene(full.root, full.district)
        backdrop = with_water(backdrop, sea, corners, work / 'env', report)
        main = [m.positions for m in surf.meshes] + [frame.point(cropped.collision.triangles.reshape(-1, 3))]
        main_top = float(np.concatenate(main)[:, 2].max()) + SHELL_HEADROOM + 16
        room = skyroom.build(backdrop, outer, frame, main_top, prefix, report,
                             cache=work / 'bakecache' / (region.district + '_sky'), workers=workers)
        if room is not None:
            surf.textures.update(room.surfaces.textures)
            surf.materials.update(room.surfaces.materials)
            report(f'3D skybox: {sum(len(m.faces) for m in room.surfaces.meshes)} triangles')
    if moving is not None:
        surf.textures.update(moving.textures)
        surf.materials.update(moving.materials)
    try:
        sky = environment.load(source, region.district, work / 'env')
    except (OSError, KeyError, ValueError, IndexError) as error:
        report(f'sky not available ({error}); using a stock one')
        sky = None
    skyname = None
    if sky is not None:
        skyname = f'{name}_sky'
        for face_name, rgba in skybox.render(sky, frame, sea_colour=sea[1] if sea else None).items():
            texture = surfaces.SourceTexture(f'skybox/{skyname}{face_name}', rgba, False, False, sky=True)
            surf.textures[f'skybox_{face_name}'] = texture
            surf.materials[f'skybox_{face_name}'] = surfaces.SourceMaterial(
                f'skybox/{skyname}{face_name}', 'UnlitGeneric',
                {'$basetexture': f'skybox/{skyname}{face_name}', '$nofog': 1, '$ignorez': 1}, None)
    textures.compile_textures(tools, textures.write_sources(surf, game), report)
    surf.materials['nodraw'] = surfaces.SourceMaterial(f'{prefix}/nodraw', 'UnlitGeneric',
                                                       {'$basetexture': 'tools/toolsnodraw', '$no_draw': 1})
    water = None
    if sea is not None:
        surf.materials['water'] = water_material(prefix, sea[1])
        water = (float(frame.point(np.array([[0.0, sea[0], 0.0]]))[0, 2]), f'{prefix}/water')
    textures.write_materials(surf, game)
    timer.done('textures')
    collision = frame.point(cropped.collision.triangles.reshape(-1, 3)).reshape(-1, 3, 3)
    within = (np.abs(collision) <= surfaces.LIMIT).all(2).all(1)
    if not within.all():
        report(f'left out {int((~within).sum())} collision triangles beyond the map size limit')
        collision = collision[within]
        cropped.collision = scene.Collision(cropped.collision.triangles[within], cropped.collision.surfaces[within])
    collision_models, brushes = models.split_brushes(collision)
    if len(brushes):
        report(f'{len(brushes)} big collision triangles as brushes')
    chunks = models.build_chunks(surf, collision_models, 'p') + prop_chunks
    if room is not None:
        chunks += models.build_chunks(room.surfaces, None, 's')
    chunks = models.compile_all(tools, chunks, src, prefix, prefix, report)
    timer.done('models')
    all_points = np.concatenate([m.positions for m in surf.meshes] + [collision.reshape(-1, 3)])
    s_lo, s_hi = all_points.min(0), all_points.max(0)
    spawn = spawn_point(collision, region, frame) if len(collision) else (s_lo + s_hi) / 2
    spawn = np.round(spawn)
    s_lo, s_hi = np.floor(s_lo), np.ceil(s_hi)
    vmf_path = src / f'{name}.vmf'
    write_vmf(vmf_path, region, chunks, prefix, s_lo, s_hi, spawn, sky, frame, skyname, placed, room, brushes, collision,
              water)
    base = src / name
    split = []
    for tool, args, check in (('vbsp', ['-game', game, base], lambda o: '**** leaked ****' not in o),
                              ('vvis', ['-fast', '-game', game, base], None),
                              ('vrad', (['-fast'] if fast else []) + ['-ldr', '-game', game, base], None)):
        start = time.perf_counter()
        tools.run(tool, args, check=check)
        split.append(f'{tool} {time.perf_counter() - start:.1f} s')
    report(', '.join(split))
    timer.done('compile')
    if region.vertex_lighting:
        vertexlight.mark_baked_props(base.with_suffix('.bsp'))
    lit_files = vertexlight.light_props(base.with_suffix('.bsp'), chunks, game, prefix, build_dir / 'vhv',
                                        lambda bsp, out: pack.extract(tools, bsp, out), report)
    timer.done('lighting')
    rails = [(frame.point(r.points), r.closed) for r in cropped.rails]
    sk3c = build_dir / 'skate3.sk3c'
    sk3c.write_bytes(skatecol.encode(collision, cropped.collision.surfaces, rails))
    shots = views.plan(collision, s_lo, s_hi, spawn=spawn)
    timer.done('views')
    info = {'format': MAP_FORMAT, 'map': name, 'title': region.title, 'district': region.district,
            'frame': frame.to_dict(), 'triangles': int(len(collision)), 'rails': len(rails),
            'spawn': [float(x) for x in spawn], 'views': views.plan_text(shots).splitlines()}
    info_path = build_dir / 'skate3.json'
    info_path.write_text(json.dumps(info, indent=1))
    thumb = build_dir / f'{name}.png'
    overviews = [v for v in shots if v[0].startswith('overview')]
    if overviews:
        thumbnail.render(surf, overviews[0]).save(thumb)
    timer.done('icon')
    files = pack.game_files(game, ['materials', 'models'])
    files[skatecol.PACK_PATH] = sk3c
    files.update(lit_files)
    files['skategm/skate3.json'] = info_path
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    final = out / f'{name}.bsp'
    pack.pack(tools, base.with_suffix('.bsp'), files, final)
    if thumb.is_file():
        (out / 'thumb').mkdir(exist_ok=True)
        shutil.copy(thumb, out / 'thumb' / thumb.name)
    timer.done('pack')
    if not keep:
        shutil.rmtree(build_dir, ignore_errors=True)
    report(f'built {final} ({final.stat().st_size // 1024} KB)')
    return final, timer.phases, views.plan_text(shots)
