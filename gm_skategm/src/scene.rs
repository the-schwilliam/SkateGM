//! Everything solid to the skater: the map's brushes and displacements, its
//! static props, and entities (spawned props, doors, platforms). Built into a
//! region around the skater, like the IW4L mashup streams Minecraft blocks, so
//! a moving door or a new prop only costs a regional rebuild.
//!
//! All geometry here is in map units (inches, Z up); it becomes skate space
//! only in `build_input`.

use crate::coords;
use crate::cleanup::{self, WorldSolid};
use crate::world::{Placed, World, TAG_ENTITY, TAG_PLAYER, TAG_STATIC_PROP};
use glam::{Mat3, Vec3};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

/// Half size of the collision region around the skater, in map units (~120 m),
/// on ordinary maps. Dense maps get a smaller region (down to ~40 m): what the
/// engine is given is what it has to search every tick.
pub const REGION_HALF: f32 = 4800.0;
const REGION_STEPS: [f32; 4] = [4800.0, 3600.0, 2400.0, 1600.0];
/// Most triangles a region may hold before it's made smaller.
pub const REGION_BUDGET: usize = 150_000;
/// An entity this big (raw triangles, or across) is cleaned up on its own and cached
const BIG_ENTITY: usize = 5_000;
const BIG_ENTITY_SIZE: f32 = 4096.0;
const BIG_CACHE_KEEP: usize = 40;
/// Rebuild the region when the skater is this far from its centre (~40 m on
/// ordinary maps; a third of the region's half size).
pub const RECENTRE: f32 = 1600.0;
static CURRENT_HALF: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0x4596_0000); // 4800.0
/// How far the skater may move before the region is rebuilt around it.
pub fn recentre_distance() -> f32 {
    f32::from_bits(CURRENT_HALF.load(std::sync::atomic::Ordering::Relaxed)) / 3.0
}

type Tris = Vec<[Vec3; 3]>;

/// A model name with this suffix asks Lua for the model's bounding box instead
/// of its physics mesh (props with "bbox" solidity, as Source collides them).
pub const BBOX_SUFFIX: &str = "#bbox";
/// A brush entity the game moves right now: in the moving layer (SetMovers),
/// so neither placed here nor put back where the map has it.
pub const MOVING_SUFFIX: &str = "#moving";

/// Shapes Lua defines itself (e.g. "skategm/player", a person-sized block for other
/// players). They are solid but never grindable, and never requested.
pub fn is_internal(model: &str) -> bool {
    model.starts_with("skategm/")
}

/// Source's AngleMatrix: columns are forward, left, up for (pitch, yaw, roll).
pub fn rotation(angles: [f32; 3]) -> Mat3 {
    let (sp, cp) = angles[0].to_radians().sin_cos();
    let (sy, cy) = angles[1].to_radians().sin_cos();
    let (sr, cr) = angles[2].to_radians().sin_cos();
    Mat3::from_cols(
        Vec3::new(cp * cy, cp * sy, -sp),
        Vec3::new(sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, sr * cp),
        Vec3::new(cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp),
    )
}

/// Model convex hulls (local space) as outward-facing triangles: each triangle
/// is wound so it faces away from its hull's centre, whatever order the
/// physics mesh listed its vertices in.
pub fn orient_hulls(hulls: Vec<Vec<Vec3>>) -> Tris {
    orient_hull_pieces(hulls).into_iter().flatten().collect()
}

/// The same, one outward triangle list per hull.
pub fn orient_hull_pieces(hulls: Vec<Vec<Vec3>>) -> Vec<Tris> {
    let mut pieces = Vec::new();
    for hull in hulls {
        let mut out = Vec::new();
        if hull.len() < 3 {
            continue;
        }
        let centre = hull.iter().copied().sum::<Vec3>() / hull.len() as f32;
        for t in hull.chunks_exact(3) {
            let (a, b, c) = (t[0], t[1], t[2]);
            let n = (b - a).cross(c - a);
            if n.length_squared() < 1e-6 {
                continue;
            }
            let mid = (a + b + c) / 3.0;
            if n.dot(mid - centre) >= 0.0 {
                out.push([a, b, c]);
            } else {
                out.push([a, c, b]);
            }
        }
        if !out.is_empty() {
            pieces.push(out);
        }
    }
    pieces
}

/// Place a model's triangles, dropping faces pressed into the world (a ramp's
/// base on the floor, a crate's side against a wall): to the engine those make
/// sharp corners where the prop meets the map.
fn place(tris: &[[Vec3; 3]], p: &Placed, world: Option<&WorldSolid>, out: &mut Tris) {
    let r = rotation(p.angles);
    for t in tris {
        let placed = t.map(|v| p.origin + r * v);
        if let Some(w) = world {
            if cleanup::buried(&placed, |q| w.solid(q)) {
                continue;
            }
        }
        out.push(placed);
    }
}

fn brush_entity_near(m: &Tris, p: &Placed, centre: Vec3, half: f32) -> bool {
    let (lo, hi) = m.iter().flatten().fold((Vec3::splat(f32::MAX), Vec3::splat(f32::MIN)), |(a, b), v| (a.min(*v), b.max(*v)));
    let at = p.origin + rotation(p.angles) * ((lo + hi) * 0.5);
    let reach = (hi - lo).length() * 0.5;
    (at.x - centre.x).abs() <= half + reach && (at.y - centre.y).abs() <= half + reach
}

fn rail_near(r: &[Vec3], centre: Vec3, half: f32) -> bool {
    r.iter().any(|p| (p.x - centre.x).abs() <= half && (p.y - centre.y).abs() <= half)
}

fn in_region(t: &[Vec3; 3], centre: Vec3, half: f32) -> bool {
    let min = t[0].min(t[1]).min(t[2]);
    let max = t[0].max(t[1]).max(t[2]);
    max.x >= centre.x - half && min.x <= centre.x + half && max.y >= centre.y - half && min.y <= centre.y + half
}

/// Narrower than this (map units, across the longest edge), a big triangle
/// isn't cut into pieces.
const THIN: f32 = 24.0;

pub fn split_large(tris: Tris, tags: Vec<u8>, max: f32) -> (Tris, Vec<u8>) {
    let (t, g, _) = split_large_weighted(tris, tags, max);
    (t, g)
}

pub fn split_large_weighted(tris: Tris, tags: Vec<u8>, max: f32) -> (Tris, Vec<u8>, Vec<f32>) {
    let mut out = Vec::with_capacity(tris.len());
    let mut out_tags = Vec::with_capacity(tris.len());
    let mut weights = Vec::with_capacity(tris.len());
    let mut stack: Vec<([Vec3; 3], u8, u32)> = Vec::new();
    for (t, g) in tris.into_iter().zip(tags.into_iter().chain(std::iter::repeat(0))) {
        let first = out.len();
        stack.push((t, g, 0));
        while let Some((t, g, depth)) = stack.pop() {
            let ext = (t[0].max(t[1]).max(t[2]) - t[0].min(t[1]).min(t[2])).max_element();
            // gm_sk8: a long thin one (a handrail's tube, a coping's edge) stays
            // whole: cut at its edges' middles it left a seam halfway along
            // the rail that the board caught on (Skate 3's long stair rails)
            let longest = (t[1] - t[0]).length().max((t[2] - t[1]).length()).max((t[0] - t[2]).length());
            let width = (t[1] - t[0]).cross(t[2] - t[0]).length() / longest.max(1e-6);
            if ext <= max || depth >= 8 || (width < THIN && crate::cleanup::on("thinwhole")) {
                out.push(t);
                out_tags.push(g);
                continue;
            }
            let (ab, bc, ca) = ((t[0] + t[1]) * 0.5, (t[1] + t[2]) * 0.5, (t[2] + t[0]) * 0.5);
            for piece in [[t[0], ab, ca], [ab, t[1], bc], [ca, bc, t[2]], [ab, bc, ca]] {
                stack.push((piece, g, depth + 1));
            }
        }
        let pieces = out.len() - first;
        weights.extend(std::iter::repeat(1.0 / pieces as f32).take(pieces));
    }
    (out, out_tags, weights)
}

fn morton_order(tris: &[[Vec3; 3]]) -> Vec<usize> {
    let centre = |t: &[Vec3; 3]| (t[0] + t[1] + t[2]) / 3.0;
    let (lo, hi) = tris.iter().fold((Vec3::splat(f32::MAX), Vec3::splat(f32::MIN)), |(a, b), t| {
        let c = centre(t);
        (a.min(c), b.max(c))
    });
    let span = Vec3::splat((hi - lo).max_element().max(1.0));
    fn spread(mut v: u64) -> u64 {
        v &= 0x1f_ffff;
        v = (v | v << 32) & 0x1f_0000_0000_ffff;
        v = (v | v << 16) & 0x1f_0000_ff00_00ff;
        v = (v | v << 8) & 0x100f_00f0_0f00_f00f;
        v = (v | v << 4) & 0x10c3_0c30_c30c_30c3;
        v = (v | v << 2) & 0x1249_2492_4924_9249;
        v
    }
    let key = |t: &[Vec3; 3]| {
        let q = (centre(t) - lo) / span * 2_097_151.0;
        spread(q.x as u64) | spread(q.y as u64) << 1 | spread(q.z as u64) << 2
    };
    let mut order: Vec<(u64, usize)> = tris.iter().enumerate().map(|(i, t)| (key(t), i)).collect();
    order.sort_unstable();
    order.into_iter().map(|(_, i)| i).collect()
}

pub fn presort_layer(tris: Tris, tags: Vec<u8>) -> (Tris, Vec<u8>, Vec<f32>) {
    let (tris, tags, weights) = split_large_weighted(tris, tags, 384.0);
    let order = morton_order(&tris);
    let t = order.iter().map(|&i| tris[i]).collect();
    let g = order.iter().map(|&i| tags.get(i).copied().unwrap_or(0)).collect();
    let w = order.iter().map(|&i| weights[i]).collect();
    (t, g, w)
}

/// The engine's own tests for a collision triangle (skate-host's collision
/// world and WorldTriangle::from_vertices): finite corners, every edge longer
/// than zero, and a normal that can be normalised - computed the same way, in
/// 32-bit floats in metres. A small margin on top so rounding inside the
/// engine can't tip a borderline one over.
pub fn engine_accepts(t: &[[f32; 3]; 3]) -> bool {
    if t.iter().flatten().any(|x| !x.is_finite()) {
        return false;
    }
    let (a, b, c) = (Vec3::from_array(t[0]), Vec3::from_array(t[1]), Vec3::from_array(t[2]));
    let edges = [(b - a).length(), (c - b).length(), (a - c).length()];
    if edges.iter().any(|&e| !e.is_finite() || e <= 1e-6) {
        return false;
    }
    let n = (b - a).cross(c - a);
    n.try_normalize().is_some() && n.length() > 1e-10
}

/// A rail the engine can take: finite points, no repeats or zero-length pieces.
pub fn clean_rail(points: Vec<[f32; 3]>) -> Option<Vec<[f32; 3]>> {
    let mut out: Vec<[f32; 3]> = Vec::with_capacity(points.len());
    for p in points {
        if p.iter().any(|x| !x.is_finite()) {
            continue;
        }
        if out.last().is_some_and(|q| (Vec3::from_array(*q) - Vec3::from_array(p)).length() <= 1e-4) {
            continue;
        }
        out.push(p);
    }
    (out.len() >= 2).then_some(out)
}

/// Sort triangles (and their tags) along a Morton (Z-order) curve through
/// their centres, so neighbouring triangles end up next to each other.
pub fn spatial_order(tris: Tris, tags: Vec<u8>) -> (Tris, Vec<u8>) {
    if tris.is_empty() {
        return (tris, tags);
    }
    // No triangle much bigger than a cluster should be: a big floor face makes
    // its cluster's box big, and every query near it tests the whole cluster.
    // Cut big ones into four through the edge midpoints (same plane, so the
    // wheels feel no difference) until each is under 256 units across.
    let (tris, tags) = split_large(tris, tags, 384.0);
    let (tris, tags) = if crate::cleanup::on("tjsplit") { let (t, g, _) = crate::cleanup::fix_t_junctions(tris, tags, 0.05); (t, g) } else { (tris, tags) };
    let order = morton_order(&tris);
    let tags_out = order.iter().map(|&i| tags.get(i).copied().unwrap_or(0)).collect();
    let tris_out = order.iter().map(|&i| tris[i]).collect();
    (tris_out, tags_out)
}

pub struct Stats {
    /// half size of the region built (map units)
    pub half: f32,
    /// triangles the engine wouldn't accept (degenerate slivers), left out
    pub dropped: usize,
    pub triangles: usize,
    pub rails: usize,
    pub statics_placed: usize,
    pub entities_placed: usize,
    pub missing_models: usize,
}

pub struct Scene {
    /// the map's surfaces before the pipeline, and the settings for it
    base: Tris,
    base_tags: Vec<u8>,
    opts: crate::world::Smoothing,
    /// everything static, made skateable: the map and its static props,
    /// through the pipeline together (at first the map alone)
    layer: Tris,
    layer_tags: Vec<u8>,
    layer_rails: Vec<Vec<Vec3>>,
    /// a static prop's shape arrived: the layer is rebuilt with it
    layer_dirty: bool,
    /// when the latest static prop shape arrived, and since when the layer has
    /// been waiting (it's rebuilt once shapes stop arriving - it's the whole
    /// pipeline over the whole map, so not for every shape)
    last_define: Option<std::time::Instant>,
    /// the static layer being rebuilt on its own thread (the collision thread
    /// keeps serving the current one meanwhile), and how many props it holds
    layer_job: Option<(std::thread::JoinHandle<crate::pipeline::Output>, usize)>,
    /// rebuild the static layer in the background (the game) or inline (tests,
    /// measuring tools)
    pub background_layer: bool,
    dirty_since: Option<std::time::Instant>,
    statics_placed: usize,
    /// what the last pipeline run did, and how long each step took
    pub layer_report: String,
    solid: Option<std::sync::Arc<WorldSolid>>,
    fillet_reach: f32,
    statics: Vec<Placed>,
    /// model shapes, local space: from Lua (props) or the map (brush entities)
    models: HashMap<String, Arc<Tris>>,
    /// models Lua said have no collision shape
    shapeless: HashSet<String>,
    dynamic: Vec<Placed>,
    /// solid brush entities as the map places them; a live report from the game
    /// (same model) takes over, so moving doors follow the game
    map_brush_entities: Vec<Placed>,
    static_census: Vec<(Placed, &'static str)>,
    layer_gen: u64,
    ent_cache: Option<(u64, Arc<(Tris, Vec<Vec<Vec3>>)>)>,
    big_cache: HashMap<u64, (u64, Arc<(Tris, Vec<Vec<Vec3>>)>)>,
    big_gen: u64,
    layer_weights: Option<Vec<f32>>,
}

impl Scene {
    pub fn new(w: World) -> Self {
        let models = w.brush_models.into_iter().map(|(k, v)| (k, Arc::new(v))).collect();
        let mut scene = Self {
            layer_tags: if w.tags.len() == w.triangles.len() { w.tags } else { vec![0; w.triangles.len()] },
            layer: w.triangles,
            layer_rails: w.rails,
            layer_dirty: false,
            last_define: None,
            dirty_since: None,
            layer_job: None,
            background_layer: true,
            statics_placed: 0,
            layer_report: String::new(),
            base_tags: if w.base_tags.len() == w.base_tris.len() { w.base_tags } else { vec![0; w.base_tris.len()] },
            base: w.base_tris,
            opts: w.opts,
            solid: w.solid,
            fillet_reach: w.fillet_reach,
            statics: w.statics,
            map_brush_entities: w.brush_entities,
            static_census: w.static_census,
            layer_gen: 0,
            ent_cache: None,
            big_cache: HashMap::new(),
            big_gen: 0,
            layer_weights: None,
            models,
            shapeless: HashSet::new(),
            dynamic: Vec::new(),
        };
        scene.presort();
        scene
    }

    /// A flat test floor (no map file).
    pub fn flat(centre: Vec3, half: f32) -> Self {
        let (x, y, z) = (centre.x, centre.y, centre.z);
        let a = Vec3::new(x - half, y - half, z);
        let b = Vec3::new(x + half, y - half, z);
        let c = Vec3::new(x + half, y + half, z);
        let d = Vec3::new(x - half, y + half, z);
        let mut scene = Self::new(World {
            triangles: vec![[a, b, c], [a, c, d]],
            tags: vec![0, 0],
            solid: None,
            fillet_reach: 16.0,
            base_tris: vec![[a, b, c], [a, c, d]],
            base_tags: vec![0, 0],
            opts: crate::world::Smoothing::preset(1),
            rails: vec![],
            statics: vec![],
            static_census: vec![],
            brush_census: vec![],
            brush_models: HashMap::new(),
            brush_entities: Vec::new(),
            summary: String::new(),
        });
        scene.background_layer = false;
        scene
    }

    /// Model shapes still needed from Lua, for static props and current entities.
    pub fn wanted(&self) -> Vec<String> {
        let mut seen = HashSet::new();
        self.statics
            .iter()
            .chain(self.dynamic.iter())
            .map(|p| &p.model)
            .filter(|m| !m.starts_with('*') && !is_internal(m) && !self.models.contains_key(*m) && !self.shapeless.contains(*m))
            .filter(|m| seen.insert((*m).clone()))
            .cloned()
            .collect()
    }

    /// A model's shape from Lua: convex hulls, or a visible mesh (triangles
    /// already facing outward; used when a model has no physics mesh).
    pub fn define_shape(&mut self, name: String, hulls: Vec<Vec<Vec3>>, mesh: bool) {
        if !mesh {
            return self.define(name, hulls);
        }
        let mut tris: Tris = Vec::new();
        for part in hulls {
            for t in part.chunks_exact(3) {
                if (t[1] - t[0]).cross(t[2] - t[0]).length_squared() > 1e-6 {
                    tris.push([t[0], t[1], t[2]]);
                }
                if tris.len() >= 30_000 {
                    break;
                }
            }
        }
        let tris = cleanup::simplify_mesh(tris, 8000);
        if tris.is_empty() {
            self.shapeless.insert(name.clone());
        } else {
            self.models.insert(name.clone(), Arc::new(tris));
        }
        self.mark_if_static(&name);
    }

    /// A shape arrived: if static props use it, the static layer is rebuilt.
    fn mark_if_static(&mut self, name: &str) {
        if self.statics.iter().any(|p| p.model == name) {
            self.layer_dirty = true;
            let now = std::time::Instant::now();
            self.last_define = Some(now);
            self.dirty_since.get_or_insert(now);
        }
    }

    pub fn define(&mut self, name: String, hulls: Vec<Vec<Vec3>>) {
        // a model's convex pieces overlap; faces inside other pieces are hidden
        let (tris, _) = cleanup::remove_buried_between(orient_hull_pieces(hulls));
        if tris.is_empty() {
            self.shapeless.insert(name.clone());
        } else {
            self.models.insert(name.clone(), Arc::new(tris));
        }
        self.mark_if_static(&name);
    }

    /// Every static prop with what the collision did with it, for diagnostics:
    /// (position, model, the map's solidity, status)
    pub fn static_status(&self) -> Vec<(Vec3, String, &'static str, &'static str)> {
        let boxed: HashSet<(i64, i64, i64)> = self
            .statics
            .iter()
            .filter(|s| s.model.ends_with(BBOX_SUFFIX))
            .map(|s| ((s.origin.x * 4.0) as i64, (s.origin.y * 4.0) as i64, (s.origin.z * 4.0) as i64))
            .collect();
        self.static_census
            .iter()
            .map(|(pl, solid)| {
                let key = ((pl.origin.x * 4.0) as i64, (pl.origin.y * 4.0) as i64, (pl.origin.z * 4.0) as i64);
                let name = if boxed.contains(&key) { format!("{}{}", pl.model, BBOX_SUFFIX) } else { pl.model.clone() };
                let status = if solid.starts_with("not solid") {
                    "left out: not solid in the map"
                } else if self.models.contains_key(&name) {
                    "in the skater's collision"
                } else if self.shapeless.contains(&name) {
                    "left out: no collision shape (tiny clutter, or none at all)"
                } else {
                    "waiting for its shape from the game"
                };
                (pl.origin, pl.model.clone(), *solid, status)
            })
            .collect()
    }

    pub fn set_dynamic(&mut self, placed: Vec<Placed>) {
        self.dynamic = placed;
    }

    /// Rebuild the static layer when static props' shapes have arrived: the
    /// props are placed into the map's surfaces and everything goes through the
    /// pipeline together, so wherever a prop meets the map gets the same care.
    /// How long until the static layer should be rebuilt: None if it's up to
    /// date, zero if now. Now = every static prop's shape is in, or none has
    /// arrived for 1.5 s, or it's been waiting 20 s (shapes still streaming in).
    pub fn layer_wait(&self) -> Option<std::time::Duration> {
        use std::time::Duration;
        if self.layer_job.is_some() {
            return Some(Duration::from_millis(100)); // check back for the result
        }
        if !self.layer_dirty {
            return None;
        }
        let pending = self.statics.iter().any(|p| !self.models.contains_key(&p.model) && !self.shapeless.contains(&p.model));
        if !pending {
            return Some(Duration::ZERO);
        }
        let quiet = self.last_define.map_or(Duration::MAX, |t| t.elapsed());
        let waited = self.dirty_since.map_or(Duration::ZERO, |t| t.elapsed());
        let q = Duration::from_millis(1500).saturating_sub(quiet);
        let w = Duration::from_secs(20).saturating_sub(waited);
        Some(q.min(w))
    }

    fn refresh_layer(&mut self) {
        // a rebuild running in the background: adopt it once it's done
        if let Some((job, _)) = &self.layer_job {
            if !job.is_finished() {
                return;
            }
            let (job, placed) = self.layer_job.take().unwrap();
            match job.join() {
                Ok(out) => self.adopt_layer(out, placed),
                Err(_) => {
                    self.layer_report = "the static prop layer failed to build; props are left out of the collision".into();
                    eprintln!("gm_skategm: {}", self.layer_report);
                }
            }
        }
        if self.layer_wait() != Some(std::time::Duration::ZERO) {
            return;
        }
        self.layer_dirty = false;
        self.dirty_since = None;
        let mut tris = self.base.clone();
        let mut tags = self.base_tags.clone();
        let world = self.solid.as_deref();
        let mut placed = 0;
        for p in &self.statics {
            if let Some(m) = self.models.get(&p.model) {
                let before = tris.len();
                place(m, p, world, &mut tris);
                tags.extend(std::iter::repeat(TAG_STATIC_PROP).take(tris.len() - before));
                placed += 1;
            }
        }
        let (base_n, opts) = (self.base.len(), self.opts);
        let run = move || {
        // (measuring: SK8_OFF=props - the map through the pipeline, props added raw after, as in 5.16)
        if cleanup::off("props") {
            let (props, ptags) = (tris.split_off(base_n), tags.split_off(base_n));
            let mut o = crate::pipeline::run(tris, tags, &opts);
            o.tris.extend(props);
            o.tags.extend(ptags);
            o
        } else {
            crate::pipeline::run(tris, tags, &opts)
        }
        };
        if self.background_layer {
            match std::thread::Builder::new().name("skategm-layer".into()).spawn(move || {
                cleanup::run_in_background();
                run()
            }) {
                Ok(job) => self.layer_job = Some((job, placed)),
                Err(_) => self.layer_dirty = true, // try again next time
            }
        } else {
            let out = run();
            self.adopt_layer(out, placed);
        }
    }

    fn adopt_layer(&mut self, out: crate::pipeline::Output, placed: usize) {
        self.layer_report = format!("{} static props in: {} ({})", placed, out.report, crate::pipeline::timing_line(&out.timings));
        self.layer = out.tris;
        self.layer_tags = out.tags;
        self.layer_gen += 1;
        self.presort();
        self.layer_rails = out.rails;
        self.statics_placed = placed;
    }

    /// Collision for the engine, in skate space: everything within the region
    /// around `centre` (map units).
    /// The biggest region (half size) around `centre` within the triangle budget.
    fn region_half(&mut self, centre: Vec3) -> f32 {
        self.refresh_layer();
        // (measuring: SK8_REGION_HALF holds the region's size fixed, so changes
        // to the collision don't also move what's measured)
        if let Some(h) = cleanup::env_var("SK8_REGION_HALF").ok().and_then(|v| v.parse::<f32>().ok()) {
            return h;
        }
        for &half in &REGION_STEPS {
            let n = match self.layer_weights.as_ref().filter(|w| w.len() == self.layer.len()) {
                Some(w) => self.layer.iter().zip(w.iter()).filter(|(t, _)| in_region(t, centre, half)).map(|(_, &w)| w).sum::<f32>().round() as usize,
                None => self.layer.iter().filter(|t| in_region(t, centre, half)).count(),
            };
            if n <= REGION_BUDGET {
                return half;
            }
        }
        *REGION_STEPS.last().unwrap()
    }

    pub fn build_input(&mut self, centre: Vec3) -> (Vec<[[f32; 3]; 3]>, Vec<Vec<[f32; 3]>>, Stats) {
        let (t, r, s, _) = self.build_tagged(centre);
        (t, r, s)
    }

    pub fn presort(&mut self) {
        if cleanup::off("presort") || cleanup::on("tjsplit") {
            self.layer_weights = None;
            return;
        }
        let tris = std::mem::take(&mut self.layer);
        let tags = std::mem::take(&mut self.layer_tags);
        let (t, g, w) = presort_layer(tris, tags);
        (self.layer, self.layer_tags, self.layer_weights) = (t, g, Some(w));
    }

    pub fn input_key(&mut self, centre: Vec3) -> (u64, f32) {
        let half = self.region_half(centre);
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        let mut mix = |x: u64| h = (h ^ x).wrapping_mul(0x0100_0000_01b3);
        mix(self.layer_gen);
        mix(u64::from(half.to_bits()));
        mix(u64::from(self.fillet_reach.to_bits()));
        for (i, t) in self.layer.iter().enumerate() {
            if in_region(t, centre, half) {
                mix(i as u64);
            }
        }
        for (i, r) in self.layer_rails.iter().enumerate() {
            if rail_near(r, centre, half) {
                mix(i as u64 | 1 << 40);
            }
        }
        let placement = |p: &Placed, m: &Arc<Tris>, mix: &mut dyn FnMut(u64)| {
            for b in p.model.bytes() {
                mix(u64::from(b));
            }
            mix(Arc::as_ptr(m) as usize as u64);
            for x in p.origin.to_array().iter().chain(p.angles.iter()) {
                mix(u64::from(x.to_bits()));
            }
        };
        for p in &self.dynamic {
            if let Some(m) = self.models.get(&p.model) {
                placement(p, m, &mut mix);
            }
        }
        let live: HashSet<&str> = self.dynamic.iter().map(|p| p.model.strip_suffix(MOVING_SUFFIX).unwrap_or(&p.model)).collect();
        for p in &self.map_brush_entities {
            if live.contains(p.model.as_str()) {
                continue;
            }
            if let Some(m) = self.models.get(&p.model) {
                if brush_entity_near(m, p, centre, half) {
                    placement(p, m, &mut mix);
                }
            }
        }
        (h, half)
    }

    /// As build_input, plus where each triangle came from (world::TAG_*).
    /// The map's cleanup on a set of placed entities (see build_tagged):
    /// placed, welded, hidden faces and T-junctions, ledge ramps, undersides,
    /// covered risers, curves; and their rails.
    fn clean_entities(&self, selected: &[(&Placed, &Arc<Tris>)], world: Option<&WorldSolid>) -> (Tris, Vec<Vec<Vec3>>) {
        let mut ent_tris = Vec::new();
        for (p, m) in selected {
            place(m, p, world, &mut ent_tris);
        }
        // the static collision around the entities (the map, props): the
        // floor beside a platform, what a ramp runs down to
        let near: Tris = if ent_tris.is_empty() { Vec::new() } else {
            let lo = ent_tris.iter().flatten().fold(Vec3::splat(f32::MAX), |a, v| a.min(*v)) - Vec3::splat(64.0);
            let hi = ent_tris.iter().flatten().fold(Vec3::splat(f32::MIN), |a, v| a.max(*v)) + Vec3::splat(64.0);
            self.layer.iter().filter(|t| {
                let (a, b) = (t[0].min(t[1]).min(t[2]), t[0].max(t[1]).max(t[2]));
                b.x >= lo.x && a.x <= hi.x && b.y >= lo.y && a.y <= hi.y
            }).copied().collect()
        };
        // The map's cleanup, on the entities too (brush entities used as
        // floors, platforms and ramps; props placed as entities): welded,
        // faces hidden under floors - theirs or the map's beside them -
        // gone, T-junctions fixed, ledge ramps and the faces they cover.
        // Without it the engine's limits apply raw: a 0.1-unit step stops
        // the board, a face buried flush at a seam catches it (lip tests).
        // SK8_OFF=entclean: curves only, as before.
        if !cleanup::off("entclean") && !ent_tris.is_empty() {
            const MINE: u8 = 200;
            let n = ent_tris.len();
            let (t, g, _, _) = cleanup::weld_and_dedupe(ent_tris, vec![MINE; n], 0.15);
            // (hidden faces judged with the map's floors beside them; only
            // the entities' own faces are taken out)
            let mut comb: Tris = near.clone();
            let mut ctag = vec![0u8; comb.len()];
            comb.extend(t);
            ctag.extend(g);
            let (t, g, _) = if cleanup::off("hidden") { (comb, ctag, 0) } else { cleanup::remove_hidden_under_floor(comb, ctag) };
            let mine: Tris = t.into_iter().zip(g).filter(|(_, g)| *g == MINE).map(|(t, _)| t).collect();
            let n = mine.len();
            let (mine, _, _) = cleanup::fix_t_junctions(mine, vec![MINE; n], 0.05);
            ent_tris = mine;
        }
        let (ent_rails, _) = crate::rails::find(&ent_tris);
        if !cleanup::off("entclean") && !cleanup::off("ledges") && !ent_tris.is_empty() && self.opts.max_step > 0.0 {
            let mut all = near.clone();
            all.extend_from_slice(&ent_tris);
            let ground = cleanup::Heights::new(&all);
            let (ramps, covered) = cleanup::step_ramps_spans(&ent_tris, &ground, 0.05, self.opts.max_step.clamp(0.0, 12.0));
            if !cleanup::off("undersides") {
                let low = cleanup::low_undersides(&ent_tris, &ground, 3.0);
                let mut out = Vec::with_capacity(ent_tris.len());
                for (t, c) in ent_tris.into_iter().zip(low) {
                    match c { None => out.push(t), Some(pieces) => out.extend(pieces) }
                }
                ent_tris = out;
            }
            if !cleanup::off("coverrisers") {
                let clipped = cleanup::clip_covered_risers(&ent_tris, &covered);
                let mut out = Vec::with_capacity(ent_tris.len());
                for (t, c) in ent_tris.into_iter().zip(clipped) {
                    match c { None => out.push(t), Some(pieces) => out.extend(pieces) }
                }
                ent_tris = out;
            }
            ent_tris.extend(ramps);
        }
        if self.fillet_reach > 0.0 && !ent_tris.is_empty() {
            let mut all = near.clone();
            all.extend_from_slice(&ent_tris);
            let ground = cleanup::Heights::new(&all);
            let fillets = cleanup::transition_fillets(&ent_tris, &ground, self.fillet_reach);
            ent_tris.extend(fillets);
        }
        (ent_tris, ent_rails)
    }

    pub fn build_tagged(&mut self, centre: Vec3) -> (Vec<[[f32; 3]; 3]>, Vec<Vec<[f32; 3]>>, Stats, Vec<u8>) {
        let timing = cleanup::env_var("SK8_BUILDTIME").is_ok();
        let t0 = std::time::Instant::now();
        let mut half = self.region_half(centre);
        let t_half = t0.elapsed();
        CURRENT_HALF.store(half.to_bits(), std::sync::atomic::Ordering::Relaxed);
        let mut tris: Tris = Vec::new();
        let mut tags: Vec<u8> = Vec::new();
        self.refresh_layer();
        for (t, &g) in self.layer.iter().zip(self.layer_tags.iter()) {
            if in_region(t, centre, half) {
                tris.push(*t);
                tags.push(g);
            }
        }
        let mut rails: Vec<Vec<Vec3>> = self
            .layer_rails
            .iter()
            .filter(|r| rail_near(r, centre, half))
            .cloned()
            .collect();
        let statics_placed = self.statics_placed;
        let mut region_len = tris.len();
        let t_region = t0.elapsed();

        let mut blocks = Vec::new(); // solid, not grindable
        let mut entities_placed = 0;
        let world = self.solid.as_deref();
        let mut selected: Vec<(&Placed, &Arc<Tris>)> = Vec::new();
        for p in &self.dynamic {
            if let Some(m) = self.models.get(&p.model) {
                if is_internal(&p.model) {
                    place(m, p, None, &mut blocks);
                } else {
                    selected.push((p, m));
                }
                entities_placed += 1;
            }
        }
        // brush entities the game didn't report live: as the map places them
        let live: HashSet<&str> = self.dynamic.iter().map(|p| p.model.strip_suffix(MOVING_SUFFIX).unwrap_or(&p.model)).collect();
        for p in &self.map_brush_entities {
            if live.contains(p.model.as_str()) {
                continue;
            }
            // (by where its brushes are: most brush entities sit at the map's
            // origin with their geometry in map coordinates, so far from the
            // origin a test on `origin` alone left every one of them out)
            if let Some(m) = self.models.get(&p.model) {
                if !brush_entity_near(m, p, centre, half) {
                    continue;
                }
                selected.push((p, m));
                entities_placed += 1;
            }
        }
        // Big entities (a map's chunk of terrain as one mesh) are cleaned up on
        // their own and kept per entity: a new chunk coming into the set costs
        // its own cleanup once, not everyone's again (9 chunk meshes of an
        // infinite map, 1-2M triangles together, took 3-44 s a rebuild). The
        // rest together, as one set (they work on each other: a platform on a
        // ramp). `SK8_OFF=bigents`: all as one set, as before.
        let split = !cleanup::off("bigents");
        let is_big = |m: &Arc<Tris>| {
            if m.len() >= BIG_ENTITY {
                return true;
            }
            let (lo, hi) = m.iter().flatten().fold((Vec3::splat(f32::MAX), Vec3::splat(f32::MIN)), |(a, b), v| (a.min(*v), b.max(*v)));
            m.len() > 0 && (hi - lo).length() >= BIG_ENTITY_SIZE
        };
        let (big, small): (Vec<_>, Vec<_>) = selected.iter().copied().partition(|(_, m)| split && is_big(m));
        let key_of = |set: &[(&Placed, &Arc<Tris>)]| {
            let mut h: u64 = 0xcbf2_9ce4_8422_2325;
            let mut mix = |x: u64| h = (h ^ x).wrapping_mul(0x0100_0000_01b3);
            mix(self.layer_gen);
            mix(u64::from(self.fillet_reach.to_bits()));
            mix(u64::from(world.is_some()));
            mix(u64::from(cleanup::off("entclean")));
            for (p, m) in set {
                for b in p.model.bytes() {
                    mix(u64::from(b));
                }
                mix(Arc::as_ptr(m) as usize as u64);
                for x in p.origin.to_array().iter().chain(p.angles.iter()) {
                    mix(u64::from(x.to_bits()));
                }
            }
            h
        };
        let key = key_of(&small);
        let cached = match &self.ent_cache {
            Some((k, v)) if *k == key && !cleanup::off("entcache") => Some(Arc::clone(v)),
            _ => None,
        };
        let small_done = match cached {
            Some(v) => v,
            None => {
                let v = Arc::new(self.clean_entities(&small, world));
                self.ent_cache = Some((key, Arc::clone(&v)));
                v
            }
        };
        self.big_gen += 1;
        let t_small = t0.elapsed();
        let mut misses = 0usize;
        let mut parts = vec![small_done];
        for one in &big {
            let k = key_of(std::slice::from_ref(one));
            let hit = if cleanup::off("entcache") { None } else { self.big_cache.get_mut(&k).map(|(used, v)| { *used = self.big_gen; Arc::clone(v) }) };
            let v = match hit {
                Some(v) => v,
                None => {
                    misses += 1;
                    let v = Arc::new(self.clean_entities(std::slice::from_ref(one), world));
                    self.big_cache.insert(k, (self.big_gen, Arc::clone(&v)));
                    v
                }
            };
            parts.push(v);
        }
        // (kept for chunks that come back soon; the oldest go past a few dozen)
        while self.big_cache.len() > BIG_CACHE_KEEP {
            let Some(oldest) = self.big_cache.iter().min_by_key(|(_, (used, _))| *used).map(|(k, _)| *k) else { break };
            self.big_cache.remove(&oldest);
        }
        // The region's budget counts the entities too: on an infinite map the
        // ground is all entities (the map's own layer is empty), and a whole
        // 3 x 3 of chunks went to the engine (1-2M triangles, seconds a build).
        // `SK8_OFF=entbudget`: the layer alone sizes it, as before.
        let t_budget0 = t0.elapsed();
        let trim = !cleanup::off("enttrim");
        if trim && !cleanup::off("entbudget") && cleanup::env_var("SK8_REGION_HALF").is_err() && parts.iter().any(|p| !p.0.is_empty()) {
            let weights = self.layer_weights.as_ref().filter(|w| w.len() == self.layer.len());
            let layer_in = |h: f32| match weights {
                Some(w) => self.layer.iter().zip(w.iter()).filter(|(t, _)| in_region(t, centre, h)).map(|(_, &w)| w).sum::<f32>().round() as usize,
                None => self.layer.iter().filter(|t| in_region(t, centre, h)).count(),
            };
            let ent_in = |h: f32| parts.iter().map(|p| p.0.iter().filter(|t| in_region(t, centre, h)).count()).sum::<usize>();
            let mut fit = half;
            for &h in REGION_STEPS.iter().filter(|&&h| h <= half) {
                fit = h;
                if layer_in(h) + ent_in(h) <= REGION_BUDGET {
                    break;
                }
            }
            if fit != half {
                half = fit;
                CURRENT_HALF.store(half.to_bits(), std::sync::atomic::Ordering::Relaxed);
                tris.clear();
                tags.clear();
                for (t, &g) in self.layer.iter().zip(self.layer_tags.iter()) {
                    if in_region(t, centre, half) {
                        tris.push(*t);
                        tags.push(g);
                    }
                }
                rails = self.layer_rails.iter().filter(|r| rail_near(r, centre, half)).cloned().collect();
                region_len = tris.len();
            }
        }
        if timing {
            eprintln!("BUILDTIME entities: {} small {:?}, {} big ({} cleaned now) {:?}, budget {:?}", small.len(), t_small - t_region, big.len(), misses, t_budget0 - t_small, t0.elapsed() - t_budget0);
        }
        // only what's in the region goes to the engine (an entity can be far
        // bigger than the region: a whole chunk of terrain)
        let mut ent_tris: Tris = Vec::new();
        let mut ent_rails: Vec<Vec<Vec3>> = Vec::new();
        for part in &parts {
            if trim {
                ent_tris.extend(part.0.iter().filter(|t| in_region(t, centre, half)).copied());
                ent_rails.extend(part.1.iter().filter(|r| rail_near(r, centre, half)).cloned());
            } else {
                ent_tris.extend_from_slice(&part.0);
                ent_rails.extend(part.1.iter().cloned());
            }
        }
        let entities = (ent_tris, ent_rails);
        let (ent_tris, ent_rails) = (&entities.0, &entities.1);
        tags.extend(std::iter::repeat(TAG_ENTITY).take(ent_tris.len()));
        tris.extend_from_slice(ent_tris);
        tags.extend(std::iter::repeat(TAG_PLAYER).take(blocks.len()));
        tris.extend(blocks);
        rails.extend(ent_rails.iter().cloned());
        rails.truncate(u16::MAX as usize);

        let stats = Stats {
            half,
            dropped: 0,
            triangles: tris.len(),
            rails: rails.len(),
            statics_placed,
            entities_placed,
            missing_models: self.wanted().len(),
        };
        // The engine groups consecutive runs of 64 triangles into the clusters
        // its query tree culls with, in the order it's given them. Handed over
        // in whatever order they were made, those clusters span the whole map
        // and nothing can be culled: every wheel query tests most triangles.
        // Sorted along a space-filling curve, each run is a small patch.
        let t_entities = t0.elapsed();
        let (tris, tags) = if self.layer_weights.as_ref().is_some_and(|w| w.len() == self.layer.len()) {
            let tail_tris = tris.split_off(region_len);
            let tail_tags = tags.split_off(region_len);
            let (tail_tris, tail_tags) = spatial_order(tail_tris, tail_tags);
            let (mut tris, mut tags) = (tris, tags);
            tris.extend(tail_tris);
            tags.extend(tail_tags);
            (tris, tags)
        } else {
            spatial_order(tris, tags)
        };
        let t_order = t0.elapsed();
        // In the engine's own units and precision, keep only triangles it will
        // accept: far from the map's centre a very thin sliver can round to
        // exactly nothing ("Invalid SKATE collision triangle normal").
        let mut stats = stats;
        let mut out = Vec::with_capacity(tris.len());
        let mut out_tags = Vec::with_capacity(tags.len());
        for (t, g) in tris.iter().zip(tags) {
            let st = t.map(|v| coords::to_skate(v.to_array()));
            if engine_accepts(&st) {
                out.push(st);
                out_tags.push(g);
            } else {
                stats.dropped += 1;
            }
        }
        let rails = rails.iter().filter_map(|r| clean_rail(r.iter().map(|v| coords::to_skate(v.to_array())).collect())).collect();
        if timing {
            eprintln!("BUILDTIME scene: half {:?}, region {:?}, entities {:?}, order {:?}, accept {:?}; {} triangles of {} in the layer",
                t_half, t_region - t_half, t_entities - t_region, t_order - t_entities, t0.elapsed() - t_order, out.len(), self.layer.len());
        }
        (out, rails, stats, out_tags)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// (test helper) the triangles of one kind from a build, and how many
    fn of_kind(s: &mut Scene, centre: Vec3, tag: u8) -> Vec<[[f32; 3]; 3]> {
        let (t, _, _, g) = s.build_tagged(centre);
        t.into_iter().zip(g).filter(|(_, k)| *k == tag).map(|(t, _)| t).collect()
    }

    #[test]
    fn source_angles() {
        // yaw 90: forward is +y, left is -x
        let r = rotation([0.0, 90.0, 0.0]);
        assert!((r * Vec3::X - Vec3::Y).length() < 1e-5);
        assert!((r * Vec3::Y + Vec3::X).length() < 1e-5);
        // pitch 90 looks straight down in Source
        let r = rotation([90.0, 0.0, 0.0]);
        assert!((r * Vec3::X + Vec3::Z).length() < 1e-5);
    }

    pub fn cube_hull_scrambled() -> Vec<Vec3> {
        // a 2x2x2 cube's 12 triangles with deliberately mixed winding
        let v = |x: f32, y: f32, z: f32| Vec3::new(x, y, z);
        let q = [
            [v(-1., -1., 1.), v(1., -1., 1.), v(1., 1., 1.), v(-1., 1., 1.)],
            [v(-1., -1., -1.), v(-1., 1., -1.), v(1., 1., -1.), v(1., -1., -1.)],
            [v(1., -1., -1.), v(1., 1., -1.), v(1., 1., 1.), v(1., -1., 1.)],
            [v(-1., -1., -1.), v(-1., -1., 1.), v(-1., 1., 1.), v(-1., 1., -1.)],
            [v(-1., 1., -1.), v(-1., 1., 1.), v(1., 1., 1.), v(1., 1., -1.)],
            [v(-1., -1., -1.), v(1., -1., -1.), v(1., -1., 1.), v(-1., -1., 1.)],
        ];
        let mut out = Vec::new();
        for (i, f) in q.iter().enumerate() {
            if i % 2 == 0 {
                out.extend([f[0], f[1], f[2], f[0], f[2], f[3]]);
            } else {
                out.extend([f[0], f[2], f[1], f[0], f[3], f[2]]);
            }
        }
        out
    }

    #[test]
    fn hull_triangles_face_outward() {
        let tris = orient_hulls(vec![cube_hull_scrambled()]);
        assert_eq!(tris.len(), 12);
        for t in &tris {
            let n = (t[1] - t[0]).cross(t[2] - t[0]);
            let mid = (t[0] + t[1] + t[2]) / 3.0;
            assert!(n.dot(mid) > 0.0, "every face must point away from the centre");
        }
    }

    #[test]
    fn region_placement_and_wanted() {
        // (placement only: the box's sides, which the ledge ramps cover, would
        // otherwise be taken out by the covered-riser step)
        crate::cleanup::set_env("SK8_OFF", Some("coverrisers,entclean"));
        let mut s = Scene::flat(Vec3::ZERO, 10000.0);
        s.statics.push(Placed { model: "models/box.mdl".into(), origin: Vec3::new(100., 0., 0.), angles: [0., 90., 0.] });
        s.statics.push(Placed { model: "models/far.mdl".into(), origin: Vec3::new(90000., 0., 0.), angles: [0., 0., 0.] });
        assert_eq!(s.wanted().len(), 2);
        s.define("models/box.mdl".into(), vec![cube_hull_scrambled()]);
        s.define("models/far.mdl".into(), vec![]); // no collision shape
        assert!(s.wanted().is_empty());
        let (_, _, st) = s.build_input(Vec3::ZERO);
        assert_eq!(st.statics_placed, 1);
        let props = of_kind(&mut s, Vec3::ZERO, crate::world::TAG_STATIC_PROP);
        assert_eq!(props.len(), 12, "the one nearby box (the far one is out of the region)");
        // the box sits at x=100 in, i.e. 2.54 m along skate x
        let xs: Vec<f32> = props.iter().flat_map(|t| t.iter().map(|v| v[0])).collect();
        assert!(xs.iter().all(|x| (x - 2.54).abs() < 0.03));
        // an entity (door) from a brush model moves with its position
        s.models.insert("*1".into(), Arc::new(orient_hulls(vec![cube_hull_scrambled()])));
        s.set_dynamic(vec![Placed { model: "*1".into(), origin: Vec3::new(0., 200., 0.), angles: [0., 0., 0.] }]);
        let (_, _, st) = s.build_input(Vec3::ZERO);
        assert_eq!(st.entities_placed, 1);
        assert_eq!(of_kind(&mut s, Vec3::ZERO, crate::world::TAG_ENTITY).len(), 12);
        assert_eq!(of_kind(&mut s, Vec3::ZERO, crate::world::TAG_STATIC_PROP).len(), 12);
        crate::cleanup::set_env("SK8_OFF", None);
    }

    #[test]
    fn a_thin_brush_entity_on_the_floor_gets_ramps_and_loses_its_covered_sides() {
        // a 64 x 64 slab 2 high on the floor (a platform made of a brush entity)
        const SLAB_H: f32 = 2.0;
        let slab = || {
            // the 2x2x2 cube's triangles, scaled to the slab
            let pts: Vec<Vec3> = cube_hull_scrambled().into_iter().map(|p| Vec3::new(p.x * 32.0, p.y * 32.0, (p.z + 1.0) * 0.5 * SLAB_H)).collect();
            Arc::new(orient_hulls(vec![pts]))
        };
        let up = (Vec3::from_array(crate::coords::to_skate([0.0, 0.0, 1.0])) - Vec3::from_array(crate::coords::to_skate([0.0, 0.0, 0.0]))).normalize();
        let count = |off: Option<&str>| {
            crate::cleanup::set_env("SK8_OFF", off);
            let mut s = Scene::flat(Vec3::ZERO, 10000.0);
            s.models.insert("*2".into(), slab());
            s.set_dynamic(vec![Placed { model: "*2".into(), origin: Vec3::new(0., 0., 0.), angles: [0., 0., 0.] }]);
            let tris = of_kind(&mut s, Vec3::ZERO, crate::world::TAG_ENTITY);
            let sides = tris.iter().filter(|t| {
                let t = t.map(Vec3::from_array);
                (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero().dot(up).abs() < 0.3
            }).count();
            crate::cleanup::set_env("SK8_OFF", None);
            (tris.len(), sides)
        };
        let (before, before_sides) = count(Some("entclean"));
        let (after, after_sides) = count(None);
        assert!(after > before + 8, "ramps around the slab: {before} -> {after} triangles");
        assert!(after_sides < before_sides, "its sides under the ramps go: {before_sides} -> {after_sides}");
    }

    /// A 64-unit ramp prop as two overlapping convex pieces (a wedge and a
    /// base slab), like a physics model, sitting on a world floor.
    #[test]
    fn ramp_prop_on_the_floor_has_no_fake_corners() {
        let v = Vec3::new;
        // wedge: slope rising along +x from (0,*,0) to (64,*,32), 48 wide
        let (w, h, l) = (24.0, 32.0, 64.0);
        let wedge = vec![
            v(0., -w, 0.), v(l, -w, 0.), v(l, -w, h), // side
            v(0., w, 0.), v(l, w, h), v(l, w, 0.),    // side
            v(0., -w, 0.), v(l, w, h), v(l, -w, h),   // slope
            v(0., -w, 0.), v(0., w, 0.), v(l, w, h),  // slope
            v(l, -w, 0.), v(l, w, 0.), v(l, w, h),    // back
            v(l, -w, 0.), v(l, w, h), v(l, -w, h),    // back
            v(0., -w, 0.), v(l, w, 0.), v(0., w, 0.), // bottom
            v(0., -w, 0.), v(l, -w, 0.), v(l, w, 0.), // bottom
        ];
        // base slab overlapping the wedge's back half (a second convex piece)
        let mut slab = Vec::new();
        let (a, b) = (v(32., -w, 0.), v(l, w, 8.));
        for t in super::tests::cube_hull_scrambled() {
            slab.push(a + (t + Vec3::ONE) * 0.5 * (b - a));
        }
        let mut s = Scene::flat(Vec3::ZERO, 10000.0);
        // the world's floor: solid below z = 0
        s.solid = Some(std::sync::Arc::new(WorldSolid::from_boxes(&[(v(-5000., -5000., -64.), v(5000., 5000., 0.))])));
        s.statics.push(Placed { model: "models/ramp.mdl".into(), origin: v(0., 0., 0.), angles: [0., 0., 0.] });
        s.define("models/ramp.mdl".into(), vec![wedge, slab]);
        let (_, _, st, tags) = s.build_tagged(Vec3::ZERO);
        assert_eq!(st.statics_placed, 1);
        let prop: Vec<[Vec3; 3]> = s.layer.iter().zip(&s.layer_tags)
            .filter(|(_, &g)| g == TAG_STATIC_PROP || g == crate::world::TAG_STEP_RAMP || g == crate::world::TAG_CURVE)
            .map(|(t, _)| *t).collect();
        assert!(tags.iter().any(|&g| g == TAG_STATIC_PROP), "the prop is in what the engine gets");
        // no face points down at floor level (the base is pressed into the floor)
        assert!(prop.iter().all(|t| {
            let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
            !(n.z < -0.9 && t.iter().all(|p| p.z.abs() < 0.01))
        }), "the ramp's base against the floor is removed");
        // the slope is still there
        assert!(prop.iter().any(|t| {
            let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
            n.z > 0.5 && n.x < -0.2
        }), "the slope stays");
        // nothing left inside the other piece: faces between wedge and slab gone
        let inner = prop.iter().filter(|t| {
            let c = (t[0] + t[1] + t[2]) / 3.0;
            c.x > 32.5 && c.x < 63.5 && c.z > 0.5 && c.z < 7.5 && c.y.abs() < 23.5
        }).count();
        assert_eq!(inner, 0, "hidden faces between the model's pieces are removed");
        // the engine pairs edges by shared vertices: the slope's front edge
        // (at x=0, z=0) must not pair with a face at a sharp angle any more
        let slope_front_sharp = prop.iter().any(|t| {
            let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
            let front = t.iter().filter(|p| p.x.abs() < 0.01 && p.z.abs() < 0.01).count() >= 2;
            front && n.z < -0.5
        });
        assert!(!slope_front_sharp, "no wedge corner where the ramp meets the floor");
        // and a curved transition was added at the ramp's foot, between the
        // floor (flat) and the slope (about 27 degrees)
        let curve = prop.iter().filter(|t| {
            let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
            let c = (t[0] + t[1] + t[2]) / 3.0;
            n.z > 0.9 && n.z < 0.999 && c.x.abs() < 20.0 && c.z < 8.0
        }).count();
        assert!(curve > 0, "a transition curve at the prop ramp's foot");
    }

    #[test]
    fn map_brush_entities_are_solid_until_the_game_reports_them_live() {
        let mut s = Scene::flat(Vec3::ZERO, 10000.0);
        s.models.insert("*7".into(), Arc::new(orient_hulls(vec![cube_hull_scrambled()])));
        s.map_brush_entities.push(Placed { model: "*7".into(), origin: Vec3::new(0., 100., 50.), angles: [0.; 3] });
        let (_, _, st) = s.build_input(Vec3::ZERO);
        assert_eq!(st.entities_placed, 1, "placed from the map when the game hasn't reported it");
        assert_eq!(of_kind(&mut s, Vec3::ZERO, crate::world::TAG_ENTITY).len(), 12);
        // the game reports the same entity (a door, moved): only the live one counts
        s.set_dynamic(vec![Placed { model: "*7".into(), origin: Vec3::new(0., 300., 50.), angles: [0.; 3] }]);
        let (_, _, st) = s.build_input(Vec3::ZERO);
        assert_eq!(st.entities_placed, 1);
        let ents = of_kind(&mut s, Vec3::ZERO, crate::world::TAG_ENTITY);
        assert_eq!(ents.len(), 12, "not doubled");
        let ys: Vec<f32> = ents.iter().flat_map(|t| t.iter().map(|v| v[2])).collect();
        assert!(ys.iter().all(|z| (-z - 7.62).abs() < 0.03), "at the live position (y = 300 in = 7.62 m)");
    }

    #[test]
    fn big_entities_are_trimmed_to_the_region_and_cleaned_once_each() {
        // a 20000-unit square of terrain as one mesh (a chunk of an infinite
        // map), 160 x 160 cells
        let mut t = Vec::new();
        let (n, step) = (160, 125.0);
        for i in 0..n {
            for j in 0..n {
                let (x, y) = (-10000.0 + i as f32 * step, -10000.0 + j as f32 * step);
                let (a, b, c, d) = (Vec3::new(x, y, 0.), Vec3::new(x + step, y, 0.), Vec3::new(x + step, y + step, 0.), Vec3::new(x, y + step, 0.));
                t.push([a, b, c]);
                t.push([a, c, d]);
            }
        }
        assert!(t.len() >= BIG_ENTITY);
        let mut s = Scene::flat(Vec3::new(0., 0., -5000.), 100.0);
        s.models.insert("chunk".into(), Arc::new(t.clone()));
        s.models.insert("chunk2".into(), Arc::new(t.clone()));
        s.set_dynamic(vec![Placed { model: "chunk".into(), origin: Vec3::ZERO, angles: [0.; 3] }]);
        let ents = of_kind(&mut s, Vec3::ZERO, crate::world::TAG_ENTITY);
        assert!(!ents.is_empty() && ents.len() < t.len() / 2, "only the part in the region: {} of {}", ents.len(), t.len());
        assert_eq!(s.big_cache.len(), 1);
        // a second chunk comes in: the first is reused, the second cleaned
        s.set_dynamic(vec![
            Placed { model: "chunk".into(), origin: Vec3::ZERO, angles: [0.; 3] },
            Placed { model: "chunk2".into(), origin: Vec3::new(20000., 0., 0.), angles: [0.; 3] },
        ]);
        let _ = of_kind(&mut s, Vec3::new(10000., 0., 0.), crate::world::TAG_ENTITY);
        assert_eq!(s.big_cache.len(), 2);
    }

    #[test]
    fn a_brush_entity_in_the_moving_layer_leaves_no_copy_where_the_map_put_it() {
        let mut s = Scene::flat(Vec3::ZERO, 10000.0);
        s.models.insert("*7".into(), Arc::new(orient_hulls(vec![cube_hull_scrambled()])));
        s.map_brush_entities.push(Placed { model: "*7".into(), origin: Vec3::new(0., 100., 50.), angles: [0.; 3] });
        s.set_dynamic(vec![Placed { model: format!("*7{MOVING_SUFFIX}"), origin: Vec3::new(0., 300., 50.), angles: [0.; 3] }]);
        let (_, _, st) = s.build_input(Vec3::ZERO);
        assert_eq!(st.entities_placed, 0);
        assert!(of_kind(&mut s, Vec3::ZERO, crate::world::TAG_ENTITY).is_empty());
    }

    #[test]
    fn identical_inputs_give_the_same_key_and_changes_a_different_one() {
        let centre = Vec3::new(0., 0., 0.);
        let mut s = Scene::flat(centre, 10000.0);
        let (k1, _) = s.input_key(centre);
        let (k2, _) = s.input_key(centre);
        assert_eq!(k1, k2, "nothing changed");
        let (k3, _) = s.input_key(centre + Vec3::new(10.0, 0.0, 0.0));
        assert_eq!(k1, k3, "a small move with the same triangles in range");
        s.models.insert("box".into(), Arc::new(orient_hulls(vec![cube_hull_scrambled()])));
        s.set_dynamic(vec![Placed { model: "box".into(), origin: Vec3::new(5., 0., 0.), angles: [0.; 3] }]);
        let (k4, _) = s.input_key(centre);
        assert_ne!(k1, k4, "an entity appeared");
        s.set_dynamic(vec![Placed { model: "box".into(), origin: Vec3::new(6., 0., 0.), angles: [0.; 3] }]);
        let (k5, _) = s.input_key(centre);
        assert_ne!(k4, k5, "the entity moved");
        s.set_dynamic(vec![Placed { model: "box".into(), origin: Vec3::new(6., 0., 0.), angles: [0.; 3] }]);
        assert_eq!(k5, s.input_key(centre).0, "the same list again");
    }

    #[test]
    fn map_brush_entities_far_from_the_maps_origin_are_placed_by_their_brushes() {
        // (gm_fork: a func_lod floor at origin 0 0 0, its brushes 11000 units out)
        let shifted = |dx: f32| -> Vec<Vec3> { cube_hull_scrambled().into_iter().map(|v| v + Vec3::new(dx, 0., 0.)).collect() };
        let centre = Vec3::new(11000., 0., 0.);
        let mut s = Scene::flat(centre, 10000.0);
        s.models.insert("*3".into(), Arc::new(orient_hulls(vec![shifted(11000.)])));
        s.models.insert("*4".into(), Arc::new(orient_hulls(vec![shifted(-11000.)])));
        s.map_brush_entities.push(Placed { model: "*3".into(), origin: Vec3::ZERO, angles: [0.; 3] });
        s.map_brush_entities.push(Placed { model: "*4".into(), origin: Vec3::ZERO, angles: [0.; 3] });
        let (_, _, st) = s.build_input(centre);
        assert_eq!(st.entities_placed, 1, "the one whose brushes are here, not the one across the map");
    }

    #[test]
    fn bbox_props_ask_for_their_box() {
        let mut s = Scene::flat(Vec3::ZERO, 10000.0);
        s.statics.push(Placed { model: format!("models/car.mdl{BBOX_SUFFIX}"), origin: Vec3::ZERO, angles: [0.; 3] });
        assert_eq!(s.wanted(), vec![format!("models/car.mdl{BBOX_SUFFIX}")]);
    }

    #[test]
    fn big_faces_are_cut_and_the_order_is_spatial() {
        let v = Vec3::new;
        // one 2000-unit floor triangle, and small ones scattered in a mixed-up order
        // (dense like a real map: 2,500 small triangles over the same area, in a scrambled order)
        let mut tris = vec![[v(0., 0., 0.), v(2000., 0., 0.), v(0., 2000., 0.)]];
        for i in 0..2500 {
            let k = (i * 7919) % 2500;
            let (x, y) = ((k % 50) as f32 * 40.0, (k / 50) as f32 * 40.0);
            tris.push([v(x, y, 5.), v(x + 5., y, 5.), v(x, y + 5., 5.)]);
        }
        let n = tris.len();
        let (out, tags) = spatial_order(tris, vec![0; n]);
        assert_eq!(out.len(), tags.len());
        assert!(out.iter().all(|t| (t[0].max(t[1]).max(t[2]) - t[0].min(t[1]).min(t[2])).max_element() <= 384.0), "no piece over 384 units");
        // consecutive runs of 64 are compact: almost all their boxes are small
        // next to the map (the curve's rare jumps make the odd wide one)
        let mut widths: Vec<f32> = out.chunks(64).map(|c| {
            let lo = c.iter().flatten().fold(Vec3::splat(f32::MAX), |a, p| a.min(*p));
            let hi = c.iter().flatten().fold(Vec3::splat(f32::MIN), |a, p| a.max(*p));
            (hi - lo).max_element()
        }).collect();
        widths.sort_by(f32::total_cmp);
        // (at this test's density 64 triangles need at least ~320 units)
        let median = widths[widths.len() / 2];
        assert!(median < 600.0, "a typical engine cluster is a patch, not the whole map: {median}");
    }

    #[test]
    fn dense_maps_get_a_smaller_region() {
        let v = Vec3::new;
        // a dense field: a triangle every 20 units over 8000 x 8000 (160,000 triangles)
        let mut s = Scene::flat(Vec3::ZERO, 100.0);
        for i in 0..400 {
            for j in 0..400 {
                let (x, y) = (i as f32 * 20.0 - 4000.0, j as f32 * 20.0 - 4000.0);
                s.layer.push([v(x, y, 0.), v(x + 10., y, 0.), v(x, y + 10., 0.)]);
                s.layer_tags.push(0);
            }
        }
        let (_, _, st) = s.build_input(Vec3::ZERO);
        assert!(st.half < REGION_HALF, "a smaller region on a dense map: half size {}", st.half);
        assert!(recentre_distance() < RECENTRE, "and it recentres sooner");
    }

    #[test]
    fn nothing_the_engine_would_refuse_gets_through() {
        let v = Vec3::new;
        let mut s = Scene::flat(Vec3::ZERO, 1000.0);
        let good = [v(100., 100., 5.), v(140., 100., 5.), v(100., 140., 5.)];
        // corners in a line, a repeated corner, a non-number
        s.layer.push([v(0., 0., 1.), v(10., 0., 1.), v(20., 0., 1.)]);
        s.layer.push([v(5., 5., 1.), v(5., 5., 1.), v(9., 9., 1.)]);
        s.layer.push([v(f32::NAN, 0., 1.), v(10., 0., 1.), v(0., 10., 1.)]);
        // a sliver far out on a big map: fine in map units, nothing once it's
        // 32-bit metres (the corners round onto one line)
        s.layer.push([v(16000., 16000., 1.), v(16000.0001, 16000., 1.), v(16000., 16000.00001, 1.)]);
        s.layer.push(good);
        s.layer_tags.extend([0, 0, 0, 0, 0]);
        let (tris, _, st) = s.build_input(Vec3::ZERO);
        assert!(tris.iter().all(engine_accepts), "everything handed over passes the engine's own checks");
        assert!(st.dropped >= 3, "the degenerate ones were left out: {}", st.dropped);
        let far = tris.iter().any(|t| t[0][0] > 400.0);
        assert!(!far, "the far sliver is gone");
        assert!(tris.iter().any(|t| (t[0][1] - 5.0 * 0.0254).abs() < 1e-3), "the good triangle is kept");
        // rails: repeats and non-numbers removed, too-short ones dropped
        assert_eq!(clean_rail(vec![[0., 0., 0.], [0., 0., 0.], [1., 0., 0.]]).unwrap().len(), 2);
        assert!(clean_rail(vec![[0., 0., 0.], [f32::NAN, 0., 0.]]).is_none());
    }

    #[test]
    fn a_prop_kicker_short_of_a_map_platform_is_bridged() {
        let v = Vec3::new;
        // the map: floor at 0 and a platform at z = 20 for x > 0
        let mut s = Scene::flat(Vec3::ZERO, 2000.0);
        let q = |a: Vec3, b: Vec3, c: Vec3, d: Vec3| [[a, b, c], [a, c, d]];
        for t in q(v(0., -200., 20.), v(300., -200., 20.), v(300., 200., 20.), v(0., 200., 20.)) {
            s.base.push(t);
            s.base_tags.push(0);
        }
        // a wooden kicker prop: 15 degrees, up to 15 units high at x = -2
        // (2 units short of the platform's edge, and 5 units below its top)
        let rise = 15f32.to_radians().tan();
        let len = 15.0 / rise;
        let top = |x: f32| (x + len + 2.0) * rise;
        let (x0, x1) = (-len - 2.0, -2.0);
        let hull = vec![
            v(x0, -40., 0.), v(x1, -40., 0.), v(x1, -40., top(x1)),
            v(x0, 40., 0.), v(x1, 40., top(x1)), v(x1, 40., 0.),
            v(x0, -40., 0.), v(x1, 40., top(x1)), v(x1, -40., top(x1)),
            v(x0, -40., 0.), v(x0, 40., 0.), v(x1, 40., top(x1)),
            v(x1, -40., 0.), v(x1, 40., 0.), v(x1, 40., top(x1)),
            v(x1, -40., 0.), v(x1, 40., top(x1)), v(x1, -40., top(x1)),
        ];
        s.statics.push(Placed { model: "models/kicker.mdl".into(), origin: Vec3::ZERO, angles: [0.; 3] });
        s.define("models/kicker.mdl".into(), vec![hull]);
        let _ = s.build_tagged(Vec3::ZERO);
        // something added by the pipeline now spans the gap between the
        // kicker's top and the platform, near the platform's edge
        let bridge: Vec<[Vec3; 3]> = s.layer.iter().zip(&s.layer_tags)
            .filter(|(t, &g)| g == crate::world::TAG_STEP_RAMP && t.iter().any(|p| p.x > -1.0 && p.x < 1.0 && (p.z - 20.0).abs() < 0.5))
            .map(|(t, _)| *t).collect();
        assert!(!bridge.is_empty(), "the curb between the prop kicker and the map platform is bridged");
        let lowest = bridge.iter().flatten().map(|p| p.z).fold(f32::MAX, f32::min);
        assert!(lowest < 16.0, "it comes down onto the kicker (lowest point {lowest})");
    }

    #[test]
    fn the_static_layer_waits_for_shapes_to_stop_arriving() {
        let v = Vec3::new;
        let mut s = Scene::flat(Vec3::ZERO, 1000.0);
        s.statics = vec![
            Placed { model: "models/a.mdl".into(), origin: v(100., 0., 0.), angles: [0.; 3] },
            Placed { model: "models/b.mdl".into(), origin: v(-100., 0., 0.), angles: [0.; 3] },
        ];
        // a 20-unit cube standing on the floor
        let cube = |_h: f32| vec![cube_hull_scrambled().into_iter().map(|p| p * 10.0 + v(0., 0., 10.)).collect::<Vec<_>>()];
        let props = |s: &mut Scene| of_kind(s, Vec3::ZERO, crate::world::TAG_STATIC_PROP).len();
        s.define("models/a.mdl".into(), cube(10.));
        assert!(s.layer_wait().is_some_and(|w| !w.is_zero()), "one shape of two in: wait for the other");
        assert_eq!(props(&mut s), 0, "the layer isn't rebuilt for every shape");
        s.define("models/b.mdl".into(), cube(10.));
        assert_eq!(s.layer_wait(), Some(std::time::Duration::ZERO), "all shapes in: due now");
        let both = props(&mut s);
        assert!(both >= 20, "both props in, in one rebuild (sides and tops): {both}");
        assert_eq!(s.layer_wait(), None, "and then it's up to date");
        // a stream that stalls with shapes still missing: rebuilt after 1.5 s quiet
        s.statics.push(Placed { model: "models/c.mdl".into(), origin: v(0., 300., 0.), angles: [0.; 3] });
        s.statics.push(Placed { model: "models/d.mdl".into(), origin: v(0., -300., 0.), angles: [0.; 3] });
        s.define("models/c.mdl".into(), cube(10.));
        assert_eq!(props(&mut s), both, "c waits (d still missing)");
        std::thread::sleep(std::time::Duration::from_millis(1600));
        assert!(props(&mut s) > both, "after a quiet 1.5 s it's rebuilt with what has arrived");
    }

    #[test]
    fn the_static_layer_rebuilds_in_the_background() {
        let v = Vec3::new;
        let mut s = Scene::flat(Vec3::ZERO, 1000.0);
        s.background_layer = true;
        s.statics = vec![Placed { model: "models/a.mdl".into(), origin: v(100., 0., 0.), angles: [0.; 3] }];
        s.define("models/a.mdl".into(), vec![cube_hull_scrambled().into_iter().map(|p| p * 10.0 + v(0., 0., 10.)).collect()]);
        let props = |s: &mut Scene| of_kind(s, Vec3::ZERO, crate::world::TAG_STATIC_PROP).len();
        // the first build starts the rebuild and carries on with what it has
        let first = props(&mut s);
        assert!(s.layer_job.is_some() || first > 0, "a background rebuild was started");
        let t = std::time::Instant::now();
        let mut got = first;
        while got == 0 && t.elapsed().as_secs() < 10 {
            std::thread::sleep(std::time::Duration::from_millis(20));
            got = props(&mut s);
        }
        assert!(got > 0, "a later build picks up the finished layer");
        assert!(s.layer_job.is_none() && s.layer_wait().is_none(), "and then nothing is pending");
    }

    #[test]
    fn player_blocks_are_solid_but_not_grindable() {
        let mut s = Scene::flat(Vec3::ZERO, 10000.0);
        s.define("skategm/player".into(), vec![cube_hull_scrambled()]);
        s.set_dynamic(vec![Placed { model: "skategm/player".into(), origin: Vec3::new(0., 300., 40.), angles: [0.; 3] }]);
        assert!(s.wanted().is_empty(), "internal shapes are never requested from Lua");
        let (_, rails, st) = s.build_input(Vec3::ZERO);
        assert_eq!(st.entities_placed, 1);
        assert_eq!(of_kind(&mut s, Vec3::ZERO, crate::world::TAG_PLAYER).len(), 12);
        assert!(rails.is_empty(), "no grinding on other players");
        // the same box as a normal prop does get grindable edges
        // (a 32-unit crate: the rail finder ignores edges under 24 units)
        s.define("models/crate.mdl".into(), vec![cube_hull_scrambled().into_iter().map(|v| v * 16.0).collect()]);
        s.set_dynamic(vec![Placed { model: "models/crate.mdl".into(), origin: Vec3::new(0., 300., 16.), angles: [0.; 3] }]);
        assert!(!s.build_input(Vec3::ZERO).1.is_empty(), "a crate's top edges are grindable");
    }
}
