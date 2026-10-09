//! A Source map's collision as a Skate world: triangles and grind rails.
//!
//! Only brushes reachable from the world model's BSP tree are used (func_detail
//! is merged into the world at compile time; doors, func_brush and other brush
//! entities move, so they are left out). Solid, player-clip, window and grate
//! brushes block players, so they block the skater too. Displacements are
//! included. Brush faces come from their planes, as in the IW4L mashup
//! (crates/render_anim/src/skate/collision.rs, Apache-2.0).

use glam::{Mat3, Vec3};
use std::collections::HashSet;

/// CONTENTS_SOLID | WINDOW | GRATE | PLAYERCLIP (Source's MASK_PLAYERSOLID minus monsters)
const PLAYER_SOLID: u32 = 0x1 | 0x2 | 0x8 | 0x10000;

/// Brush entity classes that are solid to players (triggers, clip volumes for
/// physics only, areaportals and the like are not).
const SOLID_BRUSH_CLASSES: &[&str] = &[
    "func_brush", "func_wall", "func_wall_toggle", "func_door", "func_door_rotating", "func_movelinear",
    "func_rotating", "func_tracktrain", "func_tanktrain", "func_train", "func_plat", "func_platrot",
    "func_breakable", "func_breakable_surf", "func_button", "func_rot_button", "func_physbox",
    "func_physbox_multiplayer", "func_pushable", "func_lod", "func_monitor", "func_reflective_glass",
    "func_guntarget", "func_conveyor", "func_detail_blocker", "func_brush_advanced",
];

/// "key" "value" pairs of one entity block.
fn keyvalues(text: &str) -> std::collections::HashMap<String, String> {
    let mut out = std::collections::HashMap::new();
    for line in text.lines() {
        let parts: Vec<&str> = line.split('"').collect();
        // "key" "value" -> ["", key, " ", value, ""]
        if parts.len() >= 4 {
            out.insert(parts[1].to_ascii_lowercase(), parts[3].to_string());
        }
    }
    out
}

fn three(v: Option<&String>) -> [f32; 3] {
    let mut out = [0.0; 3];
    if let Some(v) = v {
        for (i, x) in v.split_whitespace().take(3).enumerate() {
            out[i] = x.parse().unwrap_or(0.0);
        }
    }
    out
}

/// Solid brush entities from the map's entity lump, placed as the map says.
fn solid_brush_entities(bsp: &vbsp::Bsp) -> Vec<Placed> {
    let mut out = Vec::new();
    for ent in bsp.entities.iter() {
        let kv = keyvalues(ent.as_str());
        let (Some(class), Some(model)) = (kv.get("classname"), kv.get("model")) else { continue };
        if !model.starts_with('*') || !SOLID_BRUSH_CLASSES.contains(&class.to_ascii_lowercase().as_str()) {
            continue;
        }
        let flag = |k: &str| kv.get(k).and_then(|v| v.trim().parse::<i64>().ok()).unwrap_or(0);
        // func_brush: Solidity 1 = never solid; StartDisabled = off (and not solid)
        if flag("solidity") == 1 || flag("startdisabled") != 0 || flag("disabled") != 0 {
            continue;
        }
        let class = class.to_ascii_lowercase();
        // func_lod: "Solid" 1 = nonsolid (players walk through it)
        if class == "func_lod" && flag("solid") == 1 {
            continue;
        }
        let spawnflags = flag("spawnflags");
        // func_wall_toggle starting invisible (1); doors that are "passable" (8)
        if (class == "func_wall_toggle" && spawnflags & 1 != 0) || (class.starts_with("func_door") && spawnflags & 8 != 0) {
            continue;
        }
        let o = three(kv.get("origin"));
        out.push(Placed { model: model.clone(), origin: Vec3::new(o[0], o[1], o[2]), angles: three(kv.get("angles")) });
    }
    out
}

pub const TAG_BRUSH: u8 = 0;
pub const TAG_DISPLACEMENT: u8 = 1;
pub const TAG_STATIC_PROP: u8 = 2;
pub const TAG_ENTITY: u8 = 3;
pub const TAG_PLAYER: u8 = 4;
pub const TAG_STEP_RAMP: u8 = 5;
/// a curve added in a crease or at a ramp's foot
pub const TAG_CURVE: u8 = 6;

/// What the conversion made of one world brush (for diagnostics).
#[derive(Clone, Debug)]
pub struct BrushInfo {
    pub index: usize,
    pub contents: u32,
    pub lo: Vec3,
    pub hi: Vec3,
    /// triangles made from its faces, and how many survived hidden-face removal
    pub faces: usize,
    pub kept: usize,
    pub note: &'static str,
}

/// A model placed in the map (static prop) or in the game (entity).
#[derive(Clone, Debug)]
pub struct Placed {
    pub model: String,
    pub origin: Vec3,
    /// pitch, yaw, roll in degrees (Source convention)
    pub angles: [f32; 3],
}

/// The map's collision in map units (inches, Z up).
pub struct World {
    /// world brushes and displacements, counter-clockwise outward faces
    pub triangles: Vec<[Vec3; 3]>,
    /// where each triangle came from: TAG_BRUSH or TAG_DISPLACEMENT
    pub tags: Vec<u8>,
    pub rails: Vec<Vec<Vec3>>,
    /// the map's solidity, to clean props and brush entities against
    pub solid: Option<std::sync::Arc<crate::cleanup::WorldSolid>>,
    /// how far curved transitions may reach (0 = none), for props and entities too
    pub fillet_reach: f32,
    /// the map's surfaces before the pipeline (brushes minus buried faces,
    /// terrain), so it can run again with the static props included
    pub base_tris: Vec<[Vec3; 3]>,
    pub base_tags: Vec<u8>,
    pub opts: Smoothing,
    /// solid static props (their shapes come from the game, via Lua)
    pub statics: Vec<Placed>,
    /// every static prop with the map's solidity setting, for diagnostics
    pub static_census: Vec<(Placed, &'static str)>,
    /// every world brush and what was made of it, for diagnostics
    pub brush_census: Vec<BrushInfo>,
    /// brush entities' shapes ("*1", "*2", ...) relative to their model origin
    pub brush_models: std::collections::HashMap<String, Vec<[Vec3; 3]>>,
    /// solid brush entities as the map places them (used when the game doesn't
    /// report them live: many are never sent to clients)
    pub brush_entities: Vec<Placed>,
    pub summary: String,
}

/// A leaf's brush list, in the map's own leaf order.
#[derive(Clone, Copy, Debug)]
pub struct LeafBrushes {
    pub contents: i32,
    /// the leaf's area (areas are sealed-off parts of the map, e.g. the 3D skybox)
    pub area: u16,
    pub mins: [i16; 3],
    pub maxs: [i16; 3],
    pub first: usize,
    pub count: usize,
}

/// The leaf table in the order the BSP tree refers to it. (vbsp's `Bsp::leaves`
/// is sorted by visibility cluster, so indexing it with a tree node's child
/// number gives the wrong leaf.) Layout per Source's dleaf_t: v1 is 32 bytes,
/// v0 is 56 (an ambient light cube follows); the brush list is at bytes 24..28
/// in both.
pub fn leaves_in_order(bytes: &[u8]) -> Result<Vec<LeafBrushes>, String> {
    const LEAVES: usize = 10; // LUMP_LEAFS
    let (data, version) = raw_lump(bytes, LEAVES)?;
    let size = match version {
        0 => 56,
        1 => 32,
        v => return Err(format!("unsupported leaf lump version {v}")),
    };
    if data.len() % size != 0 {
        return Err(format!("leaf lump size {} is not a multiple of {size}", data.len()));
    }
    Ok(data
        .chunks_exact(size)
        .map(|l| LeafBrushes {
            contents: i32::from_le_bytes([l[0], l[1], l[2], l[3]]),
            area: u16::from_le_bytes([l[6], l[7]]) & 0x1ff,
            mins: [i16::from_le_bytes([l[8], l[9]]), i16::from_le_bytes([l[10], l[11]]), i16::from_le_bytes([l[12], l[13]])],
            maxs: [i16::from_le_bytes([l[14], l[15]]), i16::from_le_bytes([l[16], l[17]]), i16::from_le_bytes([l[18], l[19]])],
            first: u16::from_le_bytes([l[24], l[25]]) as usize,
            count: u16::from_le_bytes([l[26], l[27]]) as usize,
        })
        .collect())
}

/// One lump's bytes (decompressed if needed) and its version. Source BSP header:
/// "VBSP", version, then 64 x { offset, length, version, uncompressed size }.
/// A lump with a nonzero uncompressed size is LZMA with Valve's 12-byte header
/// ("LZMA", actual size, lzma size) followed by the 5 LZMA property bytes.
fn raw_lump(bytes: &[u8], index: usize) -> Result<(Vec<u8>, u32), String> {
    let rd = |o: usize| -> Result<u32, String> {
        bytes.get(o..o + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]])).ok_or_else(|| "map header truncated".to_string())
    };
    if bytes.get(0..4) != Some(b"VBSP") {
        return Err("not a Source (VBSP) map".into());
    }
    let entry = 8 + index * 16;
    let (offset, length, version, unpacked) = (rd(entry)? as usize, rd(entry + 4)? as usize, rd(entry + 8)?, rd(entry + 12)? as usize);
    let raw = bytes.get(offset..offset + length).ok_or("lump outside the map file")?;
    if unpacked == 0 {
        return Ok((raw.to_vec(), version));
    }
    if raw.get(0..4) != Some(b"LZMA") || raw.len() < 17 {
        return Err("compressed lump without an LZMA header".into());
    }
    let actual = u32::from_le_bytes([raw[4], raw[5], raw[6], raw[7]]) as u64;
    let mut out = Vec::with_capacity(unpacked);
    let mut cursor = std::io::Cursor::new(&raw[12..]);
    lzma_rs::lzma_decompress_with_options(
        &mut cursor,
        &mut out,
        &lzma_rs::decompress::Options {
            unpacked_size: lzma_rs::decompress::UnpackedSize::UseProvided(Some(actual)),
            allow_incomplete: false,
            memlimit: None,
        },
    )
    .map_err(|e| format!("could not decompress a map lump: {e:?}"))?;
    Ok((out, version))
}

fn authored_world(a: crate::authored::Authored, opts: Smoothing) -> World {
    let n = a.triangles.len();
    let natives = crate::authored::native_rails(&a);
    let summary = format!("Skate 3 collision as authored: {} triangles, {} rails ({} as Skate 3's own splines)", n, a.rails.len(), natives.len());
    crate::engine::set_native_rails(natives);
    crate::engine::set_native_triangles(crate::authored::native_triangles(&a));
    World {
        base_tris: a.triangles.clone(),
        base_tags: vec![TAG_BRUSH; n],
        triangles: a.triangles,
        tags: vec![TAG_BRUSH; n],
        rails: a.rails,
        solid: None,
        fillet_reach: 16.0,
        opts,
        statics: Vec::new(),
        static_census: Vec::new(),
        brush_census: Vec::new(),
        brush_models: std::collections::HashMap::new(),
        brush_entities: Vec::new(),
        summary,
    }
}

pub fn from_bsp(bytes: &[u8]) -> Result<World, String> {
    from_bsp_with(bytes, 1)
}

/// `smooth`: 0 = displacements as authored, 1 = light smoothing, 2 = strong.
/// What the collision cleanup may do, feature by feature (the 0/1/2 smoothing
/// levels are presets of these).
#[derive(Clone, Copy, Debug)]
pub struct Smoothing {
    /// displacement terrain: 0 as built, 1 light (refine curvy ground, one
    /// smoothing pass), 2 strong
    pub terrain: u32,
    /// curves in concave creases (and ramp feet)
    pub creases: bool,
    /// ramps over ledges up to this height (units; 0 = none)
    pub max_step: f32,
}

impl Smoothing {
    pub fn preset(level: u32) -> Self {
        match level {
            0 => Self { terrain: 0, creases: false, max_step: 0.0 },
            1 => Self { terrain: 1, creases: true, max_step: 8.0 }, // curbs (Source curbs are 4-8 units)
            _ => Self { terrain: 2, creases: true, max_step: 12.0 },
        }
    }
}

pub fn from_bsp_with(bytes: &[u8], smooth: u32) -> Result<World, String> {
    from_bsp_opts(bytes, Smoothing::preset(smooth))
}

pub fn from_bsp_opts(bytes: &[u8], opts: Smoothing) -> Result<World, String> {
    let smooth = opts.terrain;
    let bsp = vbsp::Bsp::read(bytes).map_err(|e| format!("could not read the map: {e}"))?;
    if let Some(authored) = crate::authored::from_pack(&bsp) {
        return authored.map(|a| authored_world(a, opts));
    }
    crate::engine::set_native_rails(Vec::new());
    crate::engine::set_native_triangles(Vec::new());
    let leaves = leaves_in_order(bytes)?;
    if leaves.len() != bsp.leaves.len() {
        return Err(format!("leaf count mismatch ({} vs {})", leaves.len(), bsp.leaves.len()));
    }

    let mut tris: Vec<[Vec3; 3]> = Vec::new();
    // faces pressed against other brushes are invisible in-game; drop them
    let mut solid = crate::cleanup::WorldSolid::new(&bsp, &leaves, PLAYER_SOLID);
    let (brush_census, pieces) = world_brush_pieces(&bsp, &leaves);
    let brush_count = pieces.len();
    let mut buried = 0;
    let mut brush_census = brush_census;
    for (info_i, piece) in pieces {
        let made = piece.len();
        let (kept, gone) = crate::cleanup::remove_buried(piece, &solid);
        buried += gone;
        let info = &mut brush_census[info_i];
        info.faces = made;
        info.kept = kept.len();
        if made > 0 && kept.is_empty() { info.note = "all faces hidden inside other solids"; }
        tris.extend(kept);
    }
    // who owns each brush (for diagnostics): the world's tree, then each entity's
    for b in brush_indices(&bsp, &leaves, 0) {
        if let Some(o) = solid.owner.get_mut(b) { *o = 0; }
    }
    for n in 1..bsp.models.len() {
        for b in brush_indices(&bsp, &leaves, n) {
            if let Some(o) = solid.owner.get_mut(b) { if *o == -1 { *o = n as i32; } }
        }
    }
    for ent in bsp.entities.iter() {
        let kv = keyvalues(ent.as_str());
        if let (Some(m), Some(c)) = (kv.get("model"), kv.get("classname")) {
            if let Some(n) = m.strip_prefix('*').and_then(|n| n.parse::<i32>().ok()) {
                solid.classes.insert(n, c.clone());
            }
        }
    }
    let brush_tris = tris.len();

    let mut disp_count = 0;
    let mut refined = 0;
    for n in 0..bsp.displacements.len() {
        let Some(disp) = bsp.displacement(n) else { continue };
        // (a displacement made from water or another brush players pass
        // through isn't solid to the skater either - SK8_OFF=dispsolid)
        if (disp.contents as u32) & PLAYER_SOLID == 0 && !crate::cleanup::off("dispsolid") {
            continue;
        }
        // the displacement's own surface normal, to orient its triangles outward
        let up = disp
            .face()
            .and_then(|f| bsp.planes.get(f.plane_num as usize).map(|p| (p, f.side)))
            .map(|(p, side)| {
                let v = Vec3::new(p.normal.x, p.normal.y, p.normal.z);
                if side != 0 { -v } else { v }
            })
            .unwrap_or(Vec3::Z);
        // the displacement's own grid, optionally smoothed (border kept), then
        // triangulated in vbsp's pattern
        let grid: Vec<Vec3> = disp.displaced_vertices().map(|v| Vec3::new(v.x, v.y, v.z)).collect();
        let steps = 2usize.pow(disp.power.max(0) as u32);
        let size = steps + 1;
        // (No averaging of the original points any more: with the border held
        // fixed so seams stay closed, it lifted the inside of curved terrain
        // ramps and left a lip where they meet the ground - worse the stronger
        // it was. Refining below only adds points on a curve through the
        // originals, so the shape is kept.)
        if grid.len() != size * size {
            continue;
        }
        // curvy ground gets twice the resolution, with the new points on a
        // smooth curve: each crease is then about half as sharp. Flat
        // displacements and walls are left as they are.
        let (grid, size, steps) = if smooth >= 1 {
            let (rough, up) = crate::cleanup::grid_roughness(&grid, size);
            if rough > (if smooth >= 2 { 4.0 } else { 6.0 }) && up > 0.5 {
                refined += 1;
                let (g, n) = crate::cleanup::refine_grid(&grid, size);
                (g, n, n - 1)
            } else {
                (grid, size, steps)
            }
        } else {
            (grid, size, steps)
        };
        let idx = |x: usize, y: usize| y * size + x;
        // (SK8_ON=dispalt: the diagonals alternate, as Source's own
        // triangulation of a displacement does - the diamond pattern)
        let alternate = crate::cleanup::on("dispalt");
        let mut verts = Vec::with_capacity(steps * steps * 6);
        for x in 0..steps {
            for y in 0..steps {
                if alternate && (x + y) % 2 == 0 {
                    verts.extend([grid[idx(x, y)], grid[idx(x + 1, y)], grid[idx(x + 1, y + 1)],
                                  grid[idx(x, y)], grid[idx(x + 1, y + 1)], grid[idx(x, y + 1)]]);
                } else {
                    verts.extend([grid[idx(x, y)], grid[idx(x + 1, y)], grid[idx(x, y + 1)],
                                  grid[idx(x + 1, y)], grid[idx(x + 1, y + 1)], grid[idx(x, y + 1)]]);
                }
            }
        }
        disp_count += 1;
        // One facing for the whole displacement. Its triangles all come from
        // the same grid pattern, so they share a winding; deciding each one on
        // its own against the flat face it was built from goes wrong on the
        // steep parts (the wall of a quarter pipe stands at right angles to the
        // floor it was pulled up from), leaving triangles facing into the ramp.
        let net: f32 = verts.chunks_exact(3).map(|t| (t[1] - t[0]).cross(t[2] - t[0]).dot(up)).sum();
        let flip = net < 0.0;
        for t in verts.chunks_exact(3) {
            let (a, b, c) = (t[0], t[1], t[2]);
            push(&mut tris, if flip { [a, c, b] } else { [a, b, c] });
        }
    }
    let disp_tris = tris.len() - brush_tris;
    // meet vertex-to-vertex, so the engine can see seams between surfaces
    let mut tags = vec![TAG_BRUSH; brush_tris];
    tags.resize(tris.len(), TAG_DISPLACEMENT);
    // everything else (welding, hidden faces, seams, rails, ledge ramps,
    // curves) is the pipeline, run here on the map alone so you can skate at
    // once, and again with the static props once their shapes arrive
    // The 3D skybox: a miniature of distant scenery in its own sealed area,
    // which nobody can reach. Its surfaces would take up collision (and get
    // ramps and curves) for nothing - leave that area out.
    let sky_area = bsp.entities.iter().find_map(|e| {
        let kv = keyvalues(e.as_str());
        (kv.get("classname").map(String::as_str) == Some("sky_camera")).then(|| kv.get("origin").cloned()).flatten()
    }).filter(|_| !crate::cleanup::off("sky")).and_then(|o| {
        let v: Vec<f32> = o.split_whitespace().filter_map(|x| x.parse().ok()).collect();
        (v.len() == 3).then(|| solid.area_at(Vec3::new(v[0], v[1], v[2]))).flatten()
    });
    // (never where players spawn: a sky_camera left in the playable area
    // would otherwise take most of the map with it)
    let spawn_areas: Vec<Option<u16>> = bsp.entities.iter().filter_map(|e| {
        let kv = keyvalues(e.as_str());
        let class = kv.get("classname").map(|c| c.to_ascii_lowercase()).unwrap_or_default();
        if !matches!(class.as_str(), "info_player_start" | "info_player_deathmatch" | "info_player_terrorist" | "info_player_counterterrorist" | "gmod_player_start") {
            return None;
        }
        let o = three(kv.get("origin"));
        Some(solid.area_at(Vec3::new(o[0], o[1], o[2] + 16.0)))
    }).collect();
    let sky_area = sky_area.filter(|a| !spawn_areas.contains(&Some(*a)));
    let mut sky_left_out = 0;
    let (tris, tags) = match sky_area {
        Some(sky) => {
            let mut kept = (Vec::with_capacity(tris.len()), Vec::with_capacity(tags.len()));
            for (t, g) in tris.into_iter().zip(tags) {
                let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
                let probe = (t[0] + t[1] + t[2]) / 3.0 + n * 1.0;
                if solid.area_at(probe) == Some(sky) {
                    sky_left_out += 1;
                } else {
                    kept.0.push(t);
                    kept.1.push(g);
                }
            }
            kept
        }
        None => (tris, tags),
    };
    // (SK8_OFF=world: none of the map's own surfaces - infinite maps build
    // their world at runtime and hand it over as entities; their BSP is only
    // a container box)
    let world_left_out = if crate::cleanup::off("world") { tris.len() } else { 0 };
    let (tris, tags) = if world_left_out > 0 { (Vec::new(), Vec::new()) } else { (tris, tags) };
    let base_tris = tris.clone();
    let base_tags = tags.clone();
    let out = crate::pipeline::run(tris, tags, &opts);
    let (tris, tags, rails) = (out.tris, out.tags, out.rails);
    let fillet_reach = crate::pipeline::fillet_reach(&opts);
    let cleanup_report = format!("{} ({})", out.report, crate::pipeline::timing_line(&out.timings));

    let solid_name = |s: &vbsp::SolidType| match s {
        vbsp::SolidType::None => "not solid (the map says so)",
        vbsp::SolidType::Bsp => "solid (bsp)",
        vbsp::SolidType::Bbox => "solid (bounding box)",
        vbsp::SolidType::Obb => "solid (oriented box)",
        vbsp::SolidType::ObbYaw => "solid (oriented box, yaw)",
        vbsp::SolidType::Custom => "solid (custom)",
        vbsp::SolidType::Physics => "solid (physics model)",
        _ => "solid (unknown type)",
    };
    let static_census: Vec<(Placed, &'static str)> = bsp
        .static_props()
        .map(|p| (Placed {
            model: p.model().replace('\\', "/"),
            origin: Vec3::new(p.origin.x, p.origin.y, p.origin.z),
            angles: [p.angles.pitch, p.angles.yaw, p.angles.roll],
        }, solid_name(&p.solid)))
        .collect();
    // (static props in the 3D skybox are left out too)
    let in_sky = |o: Vec3| sky_area.is_some() && solid.area_at(o + Vec3::Z * 2.0) == sky_area;
    let sky_props = bsp.static_props().filter(|p| in_sky(Vec3::new(p.origin.x, p.origin.y, p.origin.z))).count();
    let statics: Vec<Placed> = bsp
        .static_props()
        .filter(|p| !matches!(p.solid, vbsp::SolidType::None))
        .filter(|p| !in_sky(Vec3::new(p.origin.x, p.origin.y, p.origin.z)))
        .map(|p| Placed {
            // "bbox" solidity collides as the model's bounding box, as in Source
            model: {
                let m = p.model().replace('\\', "/");
                if matches!(p.solid, vbsp::SolidType::Bbox | vbsp::SolidType::Obb | vbsp::SolidType::ObbYaw) { format!("{m}{}", crate::scene::BBOX_SUFFIX) } else { m }
            },
            origin: Vec3::new(p.origin.x, p.origin.y, p.origin.z),
            angles: [p.angles.pitch, p.angles.yaw, p.angles.roll],
        })
        .collect();

    let mut brush_models = std::collections::HashMap::new();
    for n in 1..bsp.models.len() {
        let origin = bsp.models[n].origin;
        // an entity's brushes, minus the faces hidden between them
        let pieces = brush_model_pieces(&bsp, &leaves, n, Vec3::new(origin.x, origin.y, origin.z));
        let (t, _) = crate::cleanup::remove_buried_between(pieces);
        if !t.is_empty() {
            brush_models.insert(format!("*{n}"), t);
        }
    }

    let summary = format!(
        "{} brushes -> {} triangles ({} buried faces removed), {} displacements -> {} triangles (smoothing {}, {} refined); 3D skybox left out ({} triangles, {} props); {}; {} solid static props, {} brush entities ({} solid, placed from the map)",
        brush_count, brush_tris, buried, disp_count, disp_tris, smooth, refined, sky_left_out, sky_props, cleanup_report,
        statics.len(), brush_models.len(), solid_brush_entities(&bsp).len()
    );
    let brush_entities = if world_left_out > 0 || crate::cleanup::off("world") { Vec::new() } else { solid_brush_entities(&bsp) };
    let solid = std::sync::Arc::new(solid);
    // (no world, no world solidity either: outside an infinite map's box the
    // BSP calls everything solid, which buried every terrain triangle there)
    let solid = if world_left_out > 0 || crate::cleanup::off("world") { None } else { Some(solid) };
    Ok(World { triangles: tris, tags, rails, solid, fillet_reach, base_tris, base_tags, opts, statics, static_census, brush_census, brush_models, brush_entities, summary })
}

/// The world's brush triangles before any cleanup (for diagnostics).
pub fn brush_triangles_for_tests(bytes: &[u8]) -> Result<Vec<[Vec3; 3]>, String> {
    let bsp = vbsp::Bsp::read(bytes).map_err(|e| e.to_string())?;
    let leaves = leaves_in_order(bytes)?;
    let mut tris = Vec::new();
    brush_model_triangles(&bsp, &leaves, 0, Vec3::ZERO, &mut tris);
    Ok(tris)
}

fn push(tris: &mut Vec<[Vec3; 3]>, t: [Vec3; 3]) {
    if t.iter().all(|v| v.is_finite()) && (t[1] - t[0]).cross(t[2] - t[0]).length_squared() > 0.001 {
        tris.push(t);
    }
}

/// Solid brushes of BSP model `model` (0 = world), triangulated, minus `origin`.
/// Returns the number of brushes used.
fn brush_model_triangles(bsp: &vbsp::Bsp, leaves: &[LeafBrushes], model: usize, origin: Vec3, tris: &mut Vec<[Vec3; 3]>) -> usize {
    let pieces = brush_model_pieces(bsp, leaves, model, origin);
    let n = pieces.len();
    tris.extend(pieces.into_iter().flatten());
    n
}

/// The world's brushes, each with what became of it, and the triangle pieces
/// of the ones that made faces: (census, [(census index, triangles)]).
fn world_brush_pieces(bsp: &vbsp::Bsp, leaves: &[LeafBrushes]) -> (Vec<BrushInfo>, Vec<(usize, Vec<[Vec3; 3]>)>) {
    let mut brushes = HashSet::new();
    let mut stack = vec![bsp.models.first().map_or(0, |m| m.head_node)];
    while let Some(n) = stack.pop() {
        if n >= 0 {
            if let Some(node) = bsp.nodes.get(n as usize) {
                stack.push(node.children[0]);
                stack.push(node.children[1]);
            }
        } else if let Some(leaf) = leaves.get((-1 - n) as usize) {
            for lb in bsp.leaf_brushes.iter().skip(leaf.first).take(leaf.count) {
                brushes.insert(lb.brush as usize);
            }
        }
    }
    let mut ordered: Vec<usize> = brushes.into_iter().collect();
    ordered.sort_unstable();
    let mut census = Vec::new();
    let mut pieces = Vec::new();
    for index in ordered {
        let Some(brush) = bsp.brushes.get(index) else { continue };
        let planes: Vec<[f32; 4]> = bsp.brush_sides.iter().skip(brush.brush_side as usize).take(brush.num_brush_sides as usize)
            .filter_map(|side| bsp.planes.get(side.plane as usize))
            .map(|p| [p.normal.x, p.normal.y, p.normal.z, p.dist])
            .collect();
        // bounds from the brush's axis-aligned planes (every brush has them)
        let mut lo = Vec3::splat(-1e9);
        let mut hi = Vec3::splat(1e9);
        for p in &planes {
            for k in 0..3 {
                if (p[k] - 1.0).abs() < 1e-4 { hi[k] = hi[k].min(p[3]); }
                if (p[k] + 1.0).abs() < 1e-4 { lo[k] = lo[k].max(-p[3]); }
            }
        }
        let contents = brush.flags.bits();
        let mut info = BrushInfo { index, contents, lo, hi, faces: 0, kept: 0, note: "" };
        if contents & PLAYER_SOLID == 0 {
            info.note = "not solid to players (left out)";
        } else if planes.len() < 4 {
            info.note = "fewer than 4 sides (left out)";
        } else {
            let mut piece = Vec::new();
            for face in brush_faces(&planes) {
                for i in 1..face.len() - 1 {
                    push(&mut piece, [face[0], face[i], face[i + 1]]);
                }
            }
            if piece.is_empty() {
                info.note = "no faces could be built from its sides";
            } else {
                pieces.push((census.len(), piece));
            }
        }
        census.push(info);
    }
    (census, pieces)
}

/// The brushes a BSP model's tree refers to.
fn brush_indices(bsp: &vbsp::Bsp, leaves: &[LeafBrushes], model: usize) -> Vec<usize> {
    let mut brushes = HashSet::new();
    if let Some(m) = bsp.models.get(model) {
        let mut stack = vec![m.head_node];
        while let Some(n) = stack.pop() {
            if n >= 0 {
                if let Some(node) = bsp.nodes.get(n as usize) {
                    stack.push(node.children[0]);
                    stack.push(node.children[1]);
                }
            } else if let Some(leaf) = leaves.get((-1 - n) as usize) {
                for lb in bsp.leaf_brushes.iter().skip(leaf.first).take(leaf.count) {
                    brushes.insert(lb.brush as usize);
                }
            }
        }
    }
    brushes.into_iter().collect()
}

/// The same, one triangle list per brush.
fn brush_model_pieces(bsp: &vbsp::Bsp, leaves: &[LeafBrushes], model: usize, origin: Vec3) -> Vec<Vec<[Vec3; 3]>> {
    let mut brushes = HashSet::new();
    if let Some(m) = bsp.models.get(model) {
        let mut stack = vec![m.head_node];
        while let Some(n) = stack.pop() {
            if n >= 0 {
                if let Some(node) = bsp.nodes.get(n as usize) {
                    stack.push(node.children[0]);
                    stack.push(node.children[1]);
                }
            } else if let Some(leaf) = leaves.get((-1 - n) as usize) {
                for lb in bsp.leaf_brushes.iter().skip(leaf.first).take(leaf.count) {
                    brushes.insert(lb.brush as usize);
                }
            }
        }
    }
    let mut ordered: Vec<usize> = brushes.into_iter().collect();
    ordered.sort_unstable();
    let mut pieces = Vec::new();
    for index in ordered {
        let Some(brush) = bsp.brushes.get(index) else { continue };
        if brush.flags.bits() & PLAYER_SOLID == 0 {
            continue;
        }
        let planes: Vec<[f32; 4]> = bsp
            .brush_sides
            .iter()
            .skip(brush.brush_side as usize)
            .take(brush.num_brush_sides as usize)
            .filter_map(|side| bsp.planes.get(side.plane as usize))
            .map(|p| [p.normal.x, p.normal.y, p.normal.z, p.dist])
            .collect();
        if planes.len() < 4 {
            continue;
        }
        let mut piece = Vec::new();
        for face in brush_faces(&planes) {
            for i in 1..face.len() - 1 {
                push(&mut piece, [face[0] - origin, face[i] - origin, face[i + 1] - origin]);
            }
        }
        if !piece.is_empty() {
            pieces.push(piece);
        }
    }
    pieces
}

/// A convex brush's faces from its planes ([normal, dist], inside is n.p <= dist),
/// each wound counter-clockwise seen from outside. From the IW4L mashup.
pub fn brush_faces(planes: &[[f32; 4]]) -> Vec<Vec<Vec3>> {
    let mut points = Vec::<Vec3>::new();
    for a in 0..planes.len() {
        for b in a + 1..planes.len() {
            for c in b + 1..planes.len() {
                let m = Mat3::from_cols(
                    Vec3::from_slice(&planes[a][..3]),
                    Vec3::from_slice(&planes[b][..3]),
                    Vec3::from_slice(&planes[c][..3]),
                )
                .transpose();
                if m.determinant().abs() < 1e-6 {
                    continue;
                }
                let p = m.inverse() * Vec3::new(planes[a][3], planes[b][3], planes[c][3]);
                if p.is_finite()
                    && planes.iter().all(|v| Vec3::from_slice(&v[..3]).dot(p) <= v[3] + 0.05)
                    && points.iter().all(|v| v.distance_squared(p) > 0.01)
                {
                    points.push(p);
                }
            }
        }
    }
    planes
        .iter()
        .filter_map(|plane| {
            let n = Vec3::from_slice(&plane[..3]);
            let mut face: Vec<_> = points.iter().copied().filter(|p| (n.dot(*p) - plane[3]).abs() < 0.1).collect();
            if face.len() < 3 {
                return None;
            }
            let center = face.iter().copied().sum::<Vec3>() / face.len() as f32;
            let x = n.normalize().any_orthonormal_vector();
            let y = n.cross(x).normalize();
            face.sort_by(|a, b| {
                let a = *a - center;
                let b = *b - center;
                a.dot(y).atan2(a.dot(x)).total_cmp(&b.dot(y).atan2(b.dot(x)))
            });
            Some(face)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cube_faces_point_outward() {
        let faces = brush_faces(&[
            [1., 0., 0., 16.], [-1., 0., 0., 16.],
            [0., 1., 0., 16.], [0., -1., 0., 16.],
            [0., 0., 1., 16.], [0., 0., -1., 16.],
        ]);
        assert_eq!(faces.len(), 6);
        for f in faces {
            let n = (f[1] - f[0]).cross(f[2] - f[0]).normalize();
            let centre = f.iter().copied().sum::<Vec3>() / f.len() as f32;
            assert!(n.dot(centre) > 0.9, "face must face away from the cube centre");
        }
    }
}

#[cfg(test)]
mod leaf_order_tests {
    use super::*;

    /// A minimal VBSP file with only a leaf lump (v1, 32-byte leaves).
    fn map_with_leaves(leaves: &[(i16, u16, u16)]) -> Vec<u8> {
        let mut data = Vec::new();
        for &(cluster, first, count) in leaves {
            let mut l = [0u8; 32];
            l[4..6].copy_from_slice(&cluster.to_le_bytes());
            l[24..26].copy_from_slice(&first.to_le_bytes());
            l[26..28].copy_from_slice(&count.to_le_bytes());
            data.extend_from_slice(&l);
        }
        let header = 8 + 64 * 16 + 4;
        let mut f = Vec::new();
        f.extend_from_slice(b"VBSP");
        f.extend_from_slice(&20i32.to_le_bytes());
        for i in 0..64 {
            let (off, len, ver) = if i == 10 { (header as u32, data.len() as u32, 1u32) } else { (0, 0, 0) };
            f.extend_from_slice(&off.to_le_bytes());
            f.extend_from_slice(&len.to_le_bytes());
            f.extend_from_slice(&ver.to_le_bytes());
            f.extend_from_slice(&0u32.to_le_bytes());
        }
        f.extend_from_slice(&1i32.to_le_bytes()); // map revision
        f.extend_from_slice(&data);
        f
    }

    #[test]
    fn leaves_keep_file_order_not_cluster_order() {
        // clusters out of order: a cluster sort would swap these
        let bytes = map_with_leaves(&[(5, 100, 1), (-1, 200, 2), (0, 300, 3)]);
        let leaves = leaves_in_order(&bytes).unwrap();
        let firsts: Vec<usize> = leaves.iter().map(|l| l.first).collect();
        assert_eq!(firsts, vec![100, 200, 300], "tree child indices refer to file order");
        assert_eq!(leaves[2].count, 3);
    }
}
