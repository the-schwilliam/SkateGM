//! gmcl_skategm: runs the Skate 3 simulation inside Garry's Mod (x86-64 branch).
//!
//! Lua:  require("skategm")  ->  global table `skategm`
//!   skategm.Load(dataPath, x, y, z, yaw [, mapBytes [, worldScale [, smooth [, creases [, maxStep]]]]])
//!                                              start the engine; with the map's .bsp bytes it
//!                                              skates the real map, otherwise a flat floor at x,y,z
//!   skategm.Activate(x, y, z, yaw)           put the skater there
//!   skategm.Step(dt, usePad, buttons, lt, rt, lx, ly, rx, ry)
//!   skategm.Poll([withNames]) -> table       newest status and pose (Source coordinates)
//!   skategm.Stop()
//!   skategm.Version() -> string
//!
//! The simulation runs on its own thread (as in the IW4L mashup); Lua only posts
//! jobs and reads the newest reply, so a slow tick never stalls the game.

pub mod coords;
mod engine;
#[cfg(feature = "engine")]
pub mod hud; // gm_sk8 addition: Skate 3's own trick display
#[cfg_attr(not(feature = "engine"), allow(dead_code))]
mod pad;
mod picker;
pub mod mux;
mod lua;
mod memory;
pub mod rails;
pub mod authored;
pub mod world;
pub mod scene;
pub mod cleanup;
pub mod pipeline;
pub mod language;
pub mod phy;

use engine::{Builder, Controls, Input, Pose, Prepared, Sim};
use glam::Vec3;
use scene::Scene;
use world::Placed;
use lua::{Lua, State};
use std::ffi::c_int;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, Sender, TryRecvError};
use std::sync::Mutex;
use std::time::Instant;

enum Job {
    /// back to Skate 3's automatic checkpoint (water)
    Checkpoint,
    /// add this velocity (skate space, m/s): the testing boost
    Push([f32; 3]),
    Wipeout,
    /// into the ragdoll with this momentum (skate space)
    Activate { spawn: [f32; 3], heading: f32 },
    Step { dt: f32, pad: bool, controls: Controls },
    /// the moving collision layer (skate space): other players, moving
    /// things; swapped in whole, without touching the static collision; and
    /// the pieces that carry what stands on them (lifts, platforms)
    Moving(Vec<[[f32; 3]; 3]>, Vec<Carrier>),
}

/// A moving piece something can stand on and be carried by: its up-facing
/// triangles and velocity (map units, per second)
#[derive(Clone)]
struct Carrier {
    tops: Vec<[Vec3; 3]>,
    velocity: Vec3,
    /// turning about `pivot`: its angles now (pitch, yaw, roll, as placed) and
    /// how fast each changes (degrees a second: a turntable, a seesaw)
    pivot: Vec3,
    angles: [f32; 3],
    rates: [f32; 3],
}

impl Carrier {
    /// The rotation it turns through in `t` seconds (map space, as a matrix
    /// acting on offsets from the pivot), and its angles advanced by it
    fn turn(&mut self, t: f32) -> glam::Mat3 {
        if self.rates == [0.0; 3] {
            return glam::Mat3::IDENTITY;
        }
        let now = scene::rotation(self.angles);
        for (a, r) in self.angles.iter_mut().zip(self.rates) {
            *a += r * t;
        }
        scene::rotation(self.angles) * now.transpose()
    }
}

/// A map-space rotation as the skate world sees it (rows): skate = (x, z, -y)
fn rotation_to_skate(m: glam::Mat3) -> [[f32; 3]; 3] {
    let s = glam::Mat3::from_cols(Vec3::new(1.0, 0.0, 0.0), Vec3::new(0.0, 0.0, -1.0), Vec3::new(0.0, 1.0, 0.0));
    let k = s * m * s.transpose();
    std::array::from_fn(|r| std::array::from_fn(|c| k.col(c)[r]))
}

/// Which carrier the skater at `at` (map units) is standing on: one whose top
/// is right under it (a few units below to a hair above)
fn carried_by(carriers: &mut [Carrier], at: Vec3) -> Option<&mut Carrier> {
    for c in carriers.iter_mut() {
        for t in &c.tops {
            let (a, b, d) = (t[0], t[1], t[2]);
            let den = (b.y - d.y) * (a.x - d.x) + (d.x - b.x) * (a.y - d.y);
            if den.abs() < 1e-6 {
                continue;
            }
            let l1 = ((b.y - d.y) * (at.x - d.x) + (d.x - b.x) * (at.y - d.y)) / den;
            let l2 = ((d.y - a.y) * (at.x - d.x) + (a.x - d.x) * (at.y - d.y)) / den;
            let l3 = 1.0 - l1 - l2;
            if l1 < 0.0 || l2 < 0.0 || l3 < 0.0 {
                continue;
            }
            let z = l1 * a.z + l2 * b.z + l3 * d.z;
            if at.z - z >= -2.0 && at.z - z <= 10.0 {
                return Some(c);
            }
        }
    }
    None
}

/// Messages for the collision builder thread.
enum BuildMsg {
    /// a model's collision hulls (local space, map units)
    /// a model's shape: convex hulls, or (mesh = true) a visible mesh's
    /// triangles, already facing outward
    Define(String, Vec<Vec<Vec3>>, bool),
    /// entities that are solid right now
    Dynamic(Vec<Placed>),
    /// the skater moved; rebuild the region around here (map units)
    Centre(Vec3),
    /// send back the collision for the current region (to rebuild the engine)
    Snapshot(Sender<(Vec<[[f32; 3]; 3]>, Vec<Vec<[f32; 3]>>)>),
}

enum Reply {
    /// Skate 3's English text table (trick names), when found
    Language(std::collections::HashMap<String, String>, String),
    /// model shapes the builder still needs from Lua
    Wanted(Vec<String>),
    /// summary of the collision now installed
    Collision(String),
    /// a collision rebuild finished, taking this many ms
    Built(f32),
    Ready { load_ms: u128, period: f32, world: String },
    Activated(Pose),
    Stepped { pose: Option<Pose>, ticks: u32, micros: u128, pad: bool, pad_state: (u16, [u8; 2]) },
    /// the skater is held (true) until collision where it was put is in, or
    /// released (false)
    Held(bool),
    /// an engine error the worker recovered from by re-placing the skater
    Recovered(String),
    Error(String),
}

#[derive(Default)]
struct Stats {
    load_ms: u128,
    period: f32,
    // rolling one-second window
    window_start: Option<Instant>,
    window_ticks: u32,
    window_micros: u128,
    window_max: u128,
    ticks_per_sec: u32,
    avg_tick_ms: f64,
    max_step_ms: f64,
}

struct Host {
    jobs: Sender<Job>,
    replies: Receiver<Reply>,
    status: &'static str,
    error: Option<String>,
    pose: Option<Pose>,
    pad: bool,
    /// the controller's buttons and triggers (0-255) as of the latest step
    pad_state: (u16, [u8; 2]),
    /// the skater is held until collision where it was put is in (and how many
    /// times that's happened)
    held: bool,
    holds: u32,
    world: Option<String>,
    collision: Option<String>,
    wanted: Vec<String>,
    build: Sender<BuildMsg>,
    language: std::collections::HashMap<String, String>,
    language_from: Option<String>,
    /// collision rebuilds in the last 10 s (when, ms)
    builds: Vec<(Instant, f32)>,
    /// signalled when the worker (and its collision builder) have finished
    done: Receiver<()>,
    warning: Option<String>,
    recovered: u32,
    stats: Stats,
}

static HOST: Mutex<Option<Host>> = Mutex::new(None);
/// Every defined shape, as outward-facing triangles (map units, local space),
/// for placing moving pieces on the Lua thread without asking the builder.
static SHAPES: std::sync::LazyLock<Mutex<std::collections::HashMap<String, std::sync::Arc<Vec<[Vec3; 3]>>>>> =
    std::sync::LazyLock::new(|| Mutex::new(std::collections::HashMap::new()));
/// Triangles in the moving layer right now (Poll: moving)
static MOVING_COUNT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// The collision most recently handed to the engine (map units), with a grid
/// over it so lookups near a point don't scan every triangle.
struct Remembered {
    tris: Vec<[[f32; 3]; 3]>,
    tags: Vec<u8>,
    cells: std::collections::HashMap<(i32, i32), Vec<u32>>,
}
const CELL: f32 = 64.0;
impl Remembered {
    /// Calls f with each triangle index whose cell is within r of p (x, y);
    /// f returns false to stop early.
    fn near(&self, p: [f32; 3], r: f32, mut f: impl FnMut(usize) -> bool) {
        let (x0, x1) = (((p[0] - r) / CELL).floor() as i32, ((p[0] + r) / CELL).floor() as i32);
        let (y0, y1) = (((p[1] - r) / CELL).floor() as i32, ((p[1] + r) / CELL).floor() as i32);
        let mut seen = std::collections::HashSet::new();
        for x in x0..=x1 {
            for y in y0..=y1 {
                for &i in self.cells.get(&(x, y)).map(Vec::as_slice).unwrap_or(&[]) {
                    if seen.insert(i) && !f(i as usize) {
                        return;
                    }
                }
            }
        }
    }
}

/// Distance from p to a triangle (closest point, the standard construction).
fn point_triangle_distance(p: Vec3, t: &[[f32; 3]; 3]) -> f32 {
    let (a, b, c) = (Vec3::from_array(t[0]), Vec3::from_array(t[1]), Vec3::from_array(t[2]));
    let (ab, ac, ap) = (b - a, c - a, p - a);
    let (d1, d2) = (ab.dot(ap), ac.dot(ap));
    if d1 <= 0.0 && d2 <= 0.0 { return (p - a).length(); }
    let bp = p - b;
    let (d3, d4) = (ab.dot(bp), ac.dot(bp));
    if d3 >= 0.0 && d4 <= d3 { return (p - b).length(); }
    let vc = d1 * d4 - d3 * d2;
    if vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0 { return (p - (a + ab * (d1 / (d1 - d3)))).length(); }
    let cp = p - c;
    let (d5, d6) = (ab.dot(cp), ac.dot(cp));
    if d6 >= 0.0 && d5 <= d6 { return (p - c).length(); }
    let vb = d5 * d2 - d1 * d6;
    if vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0 { return (p - (a + ac * (d2 / (d2 - d6)))).length(); }
    let va = d3 * d6 - d5 * d4;
    if va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0 {
        return (p - (b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))))).length();
    }
    let denom = 1.0 / (va + vb + vc);
    (p - (a + ab * (vb * denom) + ac * (vc * denom))).length()
}
/// Every static prop and what the collision did with it (for skategm_why and the
/// pass-through detector).
type StaticStatus = std::sync::Arc<Vec<(Vec3, String, &'static str, &'static str)>>;
static STATIC_STATUS: Mutex<Option<StaticStatus>> = Mutex::new(None);
/// The map's solidity and brush owners, for skategm.Diagnose.
static DIAG_WORLD: Mutex<Option<std::sync::Arc<cleanup::WorldSolid>>> = Mutex::new(None);

/// Does the collision now in the engine have a surface at p facing roughly n?
fn collision_surface_at(p: Vec3, n: Vec3) -> bool {
    let rem = LAST_COLLISION.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let Some(rem) = rem else { return false };
    let mut found = false;
    rem.near(p.to_array(), 4.0, |i| {
        let t = &rem.tris[i];
        let (a, b, c) = (Vec3::from_array(t[0]), Vec3::from_array(t[1]), Vec3::from_array(t[2]));
        let tn = (b - a).cross(c - a);
        if tn.length_squared() >= 1e-6 {
            let tn = tn.normalize();
            if tn.dot(n).abs() >= 0.8 && (p - a).dot(tn).abs() <= 2.0 {
                let q = p - tn * (p - a).dot(tn);
                let inside = |u: Vec3, v: Vec3| (v - u).cross(q - u).dot(tn) >= -0.5;
                found = inside(a, b) && inside(b, c) && inside(c, a);
            }
        }
        !found
    });
    found
}
static BRUSH_STATUS: Mutex<Option<std::sync::Arc<Vec<world::BrushInfo>>>> = Mutex::new(None);
static LAST_COLLISION: Mutex<Option<std::sync::Arc<Remembered>>> = Mutex::new(None);

fn remember_collision(tris: &[[[f32; 3]; 3]], tags: &[u8]) {
    let map: Vec<[[f32; 3]; 3]> = tris.iter().map(|t| t.map(coords::from_skate)).collect();
    let mut cells: std::collections::HashMap<(i32, i32), Vec<u32>> = std::collections::HashMap::new();
    for (i, t) in map.iter().enumerate() {
        let (lx, hx) = (t[0][0].min(t[1][0]).min(t[2][0]), t[0][0].max(t[1][0]).max(t[2][0]));
        let (ly, hy) = (t[0][1].min(t[1][1]).min(t[2][1]), t[0][1].max(t[1][1]).max(t[2][1]));
        let (x0, x1) = ((lx / CELL).floor() as i32, (hx / CELL).floor() as i32);
        let (y0, y1) = ((ly / CELL).floor() as i32, (hy / CELL).floor() as i32);
        if ((x1 - x0 + 1) as i64) * ((y1 - y0 + 1) as i64) > 16384 {
            continue;
        }
        for x in x0..=x1 {
            for y in y0..=y1 {
                cells.entry((x, y)).or_default().push(i as u32);
            }
        }
    }
    *LAST_COLLISION.lock().unwrap_or_else(|e| e.into_inner()) =
        Some(std::sync::Arc::new(Remembered { tris: map, tags: tags.to_vec(), cells }));
}

fn flush_denormals() {
    #[cfg(target_arch = "x86_64")]
    if cleanup::env_var("SK8_DENORMALS").is_err() {
        #[allow(deprecated)]
        unsafe {
            use std::arch::x86_64::{_mm_getcsr, _mm_setcsr};
            _mm_setcsr(_mm_getcsr() | 0x8040);
        }
    }
}

fn worker(
    root: PathBuf,
    floor: [f32; 3],
    yaw: f32,
    map: Option<Vec<u8>>,
    smooth: world::Smoothing,
    jobs: Receiver<Job>,
    build_rx: Receiver<BuildMsg>,
    build_tx: Sender<BuildMsg>,
    replies: Sender<Reply>,
    done: Sender<()>,
) {
    flush_denormals();
    let (builder_done_tx, builder_done) = channel::<()>();
    let run = || -> Result<(), String> {
        let start = Instant::now();
        // (a little above the floor, as for every teleport: see SPAWN_LIFT)
        let spawn = coords::to_skate([floor[0], floor[1], floor[2] + SPAWN_LIFT]);
        let heading = coords::heading_from_yaw(yaw);
        let centre = Vec3::from_array(floor);
        *DIAG_WORLD.lock().unwrap_or_else(|e| e.into_inner()) = None;
        let (mut scene, summary) = match map {
            Some(bytes) => {
                let t = Instant::now();
                let parsed = catch_unwind(AssertUnwindSafe(|| world::from_bsp_opts(&bytes, smooth)))
                    .unwrap_or_else(|_| Err("the map reader crashed on this file".into()));
                drop(bytes);
                match parsed {
                    Ok(mut w) => {
                        *DIAG_WORLD.lock().unwrap_or_else(|e| e.into_inner()) = w.solid.clone();
                        *BRUSH_STATUS.lock().unwrap_or_else(|e| e.into_inner()) = Some(std::sync::Arc::new(std::mem::take(&mut w.brush_census)));
                        let summary = format!("map: {} in {} ms", w.summary, t.elapsed().as_millis());
                        {
                            let mut shapes = SHAPES.lock().unwrap_or_else(|e| e.into_inner());
                            shapes.retain(|k, _| !k.starts_with('*'));
                            for (k, v) in &w.brush_models {
                                shapes.insert(k.clone(), std::sync::Arc::new(v.clone()));
                            }
                        }
                        (Scene::new(w), summary)
                    }
                    // skate anyway, and say why, rather than refusing to start
                    Err(e) => (
                        Scene::flat(centre, 8000.0),
                        format!("MAP NOT READABLE ({e}); skating on a flat floor at your feet instead"),
                    ),
                }
            }
            None => (Scene::flat(centre, 8000.0), "flat test floor".to_string()),
        };
        let (triangles, rails, first_stats, tags) = scene.build_tagged(centre);
        remember_collision(&triangles, &tags);
        let mut sim = Sim::new(&root, triangles, rails, spawn, heading)?;
        let _ = replies.send(Reply::Ready { load_ms: start.elapsed().as_millis(), period: sim.period(), world: summary });
        let _ = replies.send(Reply::Wanted(scene.wanted()));
        // Skate 3's English trick names, if present: looked for on its own
        // thread so a slow disk never delays skating
        {
            let root = root.clone();
            let replies = replies.clone();
            let _ = std::thread::Builder::new().name("gm-skategm-language".into()).spawn(move || {
                if let Some(path) = language::find(&root) {
                    match language::load(&path) {
                        Ok(table) => { let _ = replies.send(Reply::Language(table, path.display().to_string())); }
                        Err(e) => { let _ = replies.send(Reply::Language(Default::default(), format!("{}: {e}", path.display()))); }
                    }
                }
            });
        }

        // collision builds run on their own thread; finished ones come back here
        // (each build comes with the region it covers: centre and half size)
        let (prepared_tx, prepared_rx) = channel::<(Option<Prepared>, Vec3, f32)>();
        let builder = sim.builder();
        let builder_replies = replies.clone();
        std::thread::Builder::new()
            .name("gm-skategm-collision".into())
            .stack_size(16 * 1024 * 1024)
            .spawn(move || {
                cleanup::run_in_background();
                collision_builder(scene, builder, build_rx, prepared_tx, builder_replies);
                let _ = builder_done_tx.send(());
            })
            .map_err(|e| e.to_string())?;
        let mut region_centre = centre;
        let _ = build_tx.send(BuildMsg::Centre(centre));

        let mut last_spawn = spawn;
        let mut last_heading = heading;
        // the region the installed collision covers, and a skater held (not
        // simulated) until collision covering it is in
        let mut installed: Option<(Vec3, f32)> = Some((centre, first_stats.half));
        let mut hold: Option<([f32; 3], f32, Instant)> = None;
        // gm_sk8: a build that came in mid-grind waits for the grind to end
        // (a new region's rails replace the one under the board, and the
        // skater fell off a long rail halfway); at most a few seconds
        let mut deferred: Option<(Prepared, Option<(Vec3, f32)>, Instant)> = None;
        let mut paused: Option<Instant> = None;
        let mut last_here = centre;
        let mut recoveries: Vec<Instant> = Vec::new();
        let mut carriers: Vec<Carrier> = Vec::new();
        // (where the skater was after the last tick, if on the ground: to carry it)
        let mut standing: Option<Vec3> = None;
        while let Ok(job) = jobs.recv() {
            match job {
                Job::Checkpoint => {
                    if let Err(e) = sim.return_to_checkpoint() {
                        let _ = replies.send(Reply::Recovered(format!("return to checkpoint: {e}")));
                    }
                }
                Job::Push(dv) => {
                    let _ = sim.push(dv);
                }
                Job::Wipeout => sim.force_wipeout(),
                Job::Moving(tris, c) => {
                    carriers = c;
                    match sim.set_moving(tris) {
                        Ok(n) => MOVING_COUNT.store(n, std::sync::atomic::Ordering::Relaxed),
                        Err(e) => { let _ = replies.send(Reply::Recovered(format!("moving collision: {e}"))); }
                    }
                }
                Job::Activate { spawn, heading } => {
                    last_spawn = spawn;
                    last_heading = heading;
                    if paused.take().is_some() {
                        let _ = replies.send(Reply::Held(false));
                    }
                    region_centre = Vec3::from_array(coords::from_skate(spawn));
                    let _ = build_tx.send(BuildMsg::Centre(region_centre));
                    // Somewhere the installed collision doesn't reach (a race
                    // start across the map): hold the skater there, not
                    // simulated, until collision covering it is in - otherwise
                    // it falls through while the region is built.
                    if !covers(installed, region_centre) {
                        hold = Some((spawn, heading, Instant::now()));
                        let _ = replies.send(Reply::Held(true));
                    }
                    let pose = sim.activate(spawn, heading)?;
                    if let Some(r) = pose.root.get(12..15) {
                        last_spawn = [r[0], r[1], r[2]];
                    }
                    if replies.send(Reply::Activated(pose)).is_err() {
                        break;
                    }
                }
                Job::Step { mut dt, mut pad, mut controls } => {
                    // Coalesce any steps that queued up while we were busy, so
                    // the simulation never falls behind real time.
                    loop {
                        match jobs.try_recv() {
                            Ok(Job::Step { dt: d, pad: p, controls: c }) => {
                                dt += d;
                                pad = p;
                                controls = c;
                            }
                            Ok(Job::Moving(tris, c)) => {
                                carriers = c;
                                match sim.set_moving(tris) {
                                    Ok(n) => MOVING_COUNT.store(n, std::sync::atomic::Ordering::Relaxed),
                                    Err(e) => { let _ = replies.send(Reply::Recovered(format!("moving collision: {e}"))); }
                                }
                            }
                            Ok(Job::Checkpoint) => {
                                if let Err(e) = sim.return_to_checkpoint() {
                                    let _ = replies.send(Reply::Recovered(format!("return to checkpoint: {e}")));
                                }
                            }
                            Ok(Job::Push(dv)) => {
                                let _ = sim.push(dv);
                            }
                            Ok(Job::Wipeout) => sim.force_wipeout(),
                            Ok(Job::Activate { spawn, heading }) => {
                                last_spawn = spawn;
                                last_heading = heading;
                                if paused.take().is_some() {
                                    let _ = replies.send(Reply::Held(false));
                                }
                                region_centre = Vec3::from_array(coords::from_skate(spawn));
                                let _ = build_tx.send(BuildMsg::Centre(region_centre));
                                if !covers(installed, region_centre) {
                                    hold = Some((spawn, heading, Instant::now()));
                                    let _ = replies.send(Reply::Held(true));
                                }
                                let pose = sim.activate(spawn, heading)?;
                                if let Some(r) = pose.root.get(12..15) {
                                    last_spawn = [r[0], r[1], r[2]];
                                }
                                let _ = replies.send(Reply::Activated(pose));
                                dt = 0.0;
                            }
                            Err(_) => break,
                        }
                    }
                    // newest finished collision build, if any
                    // (a build skipped as identical still moves the installed
                    // region's centre: the same triangles now cover a new spot)
                    let mut newest = None;
                    let mut covering = None;
                    while let Ok((p, c, h)) = prepared_rx.try_recv() {
                        if p.is_some() {
                            newest = p;
                        }
                        covering = Some((c, h));
                    }
                    if let Some(p) = newest {
                        let since = deferred.take().map_or_else(Instant::now, |d| d.2);
                        deferred = Some((p, covering.take(), since));
                    } else if let (Some(d), Some(c)) = (deferred.as_mut(), covering) {
                        d.1 = Some(c);
                        covering = None;
                    }
                    let grinding = !cleanup::off("grinddefer") && sim.last_state().contains("Grind");
                    if deferred.as_ref().is_some_and(|d| !grinding || d.2.elapsed() > std::time::Duration::from_secs(6)) {
                        if let Some((p, c, _)) = deferred.take() {
                            sim.install(p)?;
                            if c.is_some() {
                                installed = c;
                            }
                        }
                    }
                    if covering.is_some() {
                        installed = covering;
                    }
                    if let Some((hs, hh, since)) = hold {
                        let here = Vec3::from_array(coords::from_skate(hs));
                        if covers(installed, here) || since.elapsed().as_secs() >= 20 {
                            // the floor is there now: put the skater down on it
                            hold = None;
                            let _ = replies.send(Reply::Held(false));
                            let pose = sim.activate(hs, hh)?;
                            if replies.send(Reply::Activated(pose)).is_err() {
                                break;
                            }
                        } else {
                            let _ = replies.send(Reply::Stepped { pose: None, ticks: 0, micros: 0, pad: pad && sim.poll_connected(), pad_state: sim.pad_state() });
                            continue;
                        }
                    }
                    if FROZEN.load(std::sync::atomic::Ordering::Relaxed) {
                        sim.poll_pad();
                        *PAD_STICKS.lock().unwrap_or_else(|e| e.into_inner()) = sim.pad_sticks();
                        let _ = replies.send(Reply::Stepped { pose: None, ticks: 0, micros: 0, pad: pad && sim.controller_connected(), pad_state: sim.pad_state() });
                        continue;
                    }
                    if let Some(since) = paused {
                        if covers(installed, last_here) || since.elapsed().as_secs() >= 20 {
                            paused = None;
                            let _ = replies.send(Reply::Held(false));
                        } else {
                            let _ = replies.send(Reply::Stepped { pose: None, ticks: 0, micros: 0, pad: pad && sim.poll_connected(), pad_state: sim.pad_state() });
                            continue;
                        }
                    }
                    let t = Instant::now();
                    // Standing on a moving piece (a lift, a platform): carried with it,
                    // before the tick - the piece is already where it's moved to, and a
                    // tick with the wheels inside a rising lift threw the skater off or
                    // through it (`SK8_OFF=carry`)
                    if let Some(at) = standing {
                        if !carriers.is_empty() && !cleanup::off("carry") {
                            if let Some(c) = carried_by(&mut carriers, at) {
                                let t = dt.min(0.1);
                                let d = coords::to_skate((c.velocity * t).to_array());
                                let pivot = coords::to_skate(c.pivot.to_array());
                                let m = rotation_to_skate(c.turn(t));
                                if d.iter().chain(pivot.iter()).chain(m.iter().flatten()).all(|x| x.is_finite()) {
                                    sim.carry(d, pivot, m);
                                }
                            }
                        }
                    }
                    let input = if pad { Input::Controller } else { Input::Synthetic(controls) };
                    // Some stock Skate 3 graph paths aren't implemented by the engine
                    // yet (e.g. "AirDismounting"). Rather than ending the session,
                    // put the skater back down where it was and carry on.
                    let stepped = catch_unwind(AssertUnwindSafe(|| sim.step(dt, input)))
                        .unwrap_or_else(|_| Err("engine panicked during a tick".into()));
                    let (pose, ticks) = match stepped {
                        Ok(r) => r,
                        Err(e) => {
                            // (with the state it happened in and what was pressed:
                            // e.g. which in-air cases the dismount fails in)
                            let e = format!("{e} [in {}, buttons {:#06x}]", sim.last_state(), sim.last_buttons());
                            let now = Instant::now();
                            recoveries.retain(|t: &Instant| now.duration_since(*t).as_secs_f32() < 10.0);
                            if recoveries.len() >= 3 {
                                return Err(format!("{e} (repeated; stopped after 3 recoveries in 10 s)"));
                            }
                            recoveries.push(now);
                            // 1. clean up the half-finished tick, then put the skater back
                            sim.recover();
                            let pose = match sim.activate(last_spawn, last_heading) {
                                Ok(p) => p,
                                Err(e2) => {
                                    // 2. still refused: a fresh engine session with the
                                    // collision we have now, rather than giving up
                                    let (tx, rx) = channel();
                                    let _ = build_tx.send(BuildMsg::Snapshot(tx));
                                    let (tris, rails) = rx
                                        .recv_timeout(std::time::Duration::from_secs(20))
                                        .map_err(|_| format!("{e}; recovery failed: {e2}; no collision to rebuild with"))?;
                                    sim = Sim::new(&root, tris, rails, last_spawn, last_heading)
                                        .map_err(|e3| format!("{e}; recovery failed: {e2}; rebuilding the engine failed: {e3}"))?;
                                    let _ = replies.send(Reply::Recovered(format!("{e} (the engine was restarted)")));
                                    let pose = sim.activate(last_spawn, last_heading)?;
                                    let _ = replies.send(Reply::Activated(pose));
                                    continue;
                                }
                            };
                            let _ = replies.send(Reply::Recovered(e));
                            let _ = replies.send(Reply::Activated(pose));
                            continue;
                        }
                    };
                    if let Some(p) = &pose {
                        standing = (p.state.contains("Ground") && !p.state.contains("Wipeout"))
                            .then(|| Vec3::from_array(coords::from_skate([p.root[12], p.root[13], p.root[14]])));
                    }
                    if let Some(p) = &pose {
                        last_spawn = [p.root[12], p.root[13], p.root[14]];
                        let here = Vec3::from_array(coords::from_skate(last_spawn));
                        last_here = here;
                        let reach = scene::recentre_distance();
                        let ahead = if cleanup::off("lookahead") {
                            here
                        } else {
                            let v = Vec3::from_array(coords::dir_from_skate(p.velocity)) / coords::metres_per_unit();
                            let lead = (v.truncate() * LOOKAHEAD_SECONDS).clamp_length_max(reach);
                            here + lead.extend(0.0)
                        };
                        if (ahead - region_centre).truncate().length() > reach {
                            region_centre = ahead;
                            let _ = build_tx.send(BuildMsg::Centre(ahead));
                        }
                        if !covers(installed, here) {
                            UNCOVERED_TICKS.fetch_add(ticks.max(1), std::sync::atomic::Ordering::Relaxed);
                            if paused.is_none() && !cleanup::off("pause") {
                                paused = Some(Instant::now());
                                let _ = replies.send(Reply::Held(true));
                                if (here - region_centre).truncate().length() > reach * 0.5 {
                                    region_centre = here;
                                    let _ = build_tx.send(BuildMsg::Centre(here));
                                }
                            }
                        }
                    }
                    let connected = pad && sim.controller_connected();
                    if let Some(p) = &pose {
                        if !p.root.iter().all(|v| v.is_finite()) || p.bones.iter().any(|b| !b.iter().all(|v| v.is_finite())) {
                            return Err("the simulation published a non-finite pose".into());
                        }
                    }
                    let micros = t.elapsed().as_micros();
                    // the top-speed limit: take off whatever is over it (riding or in
                    // the air; push itself refuses on foot or in a bail)
                    let limit = f32::from_bits(SPEED_LIMIT.load(std::sync::atomic::Ordering::Relaxed));
                    if let (true, Some(p)) = (limit > 0.0, &pose) {
                        let v = Vec3::from_array(p.velocity);
                        let speed = v.length();
                        if speed > limit && speed.is_finite() {
                            let _ = sim.push((v * (limit / speed - 1.0)).to_array());
                        }
                    }
                    *PAD_STICKS.lock().unwrap_or_else(|e| e.into_inner()) = sim.pad_sticks();
                    if replies.send(Reply::Stepped { pose, ticks, micros, pad: connected, pad_state: sim.pad_state() }).is_err() {
                        break;
                    }
                }
            }
        }
        Ok(())
    };
    let result = catch_unwind(AssertUnwindSafe(run));
    // let the collision builder finish (its channels are closing), briefly
    drop(build_tx);
    let _ = builder_done.recv_timeout(std::time::Duration::from_secs(3));
    let _ = done.send(());
    let msg = match result {
        Ok(Ok(())) => return,
        Ok(Err(e)) => e,
        Err(panic) => {
            if let Some(s) = panic.downcast_ref::<&str>() {
                format!("engine panicked: {s}")
            } else if let Some(s) = panic.downcast_ref::<String>() {
                format!("engine panicked: {s}")
            } else {
                "engine panicked".into()
            }
        }
    };
    let _ = replies.send(Reply::Error(msg));
}

/// Owns the collision scene. Coalesces requests (waiting for a short quiet
/// spell, so a burst of model shapes becomes one rebuild), builds the region
/// with the engine's CollisionBuilder, and hands the result to the worker.
fn collision_builder(
    mut scene: Scene,
    builder: Builder,
    rx: Receiver<BuildMsg>,
    prepared: Sender<(Option<Prepared>, Vec3, f32)>,
    replies: Sender<Reply>,
) {
    let run = || -> Result<(), String> {
        let mut centre = Vec3::ZERO;
        let mut first = true;
        let mut last_fingerprint: Option<u64> = None;
        let mut last_input: Option<u64> = None;
        loop {
            // wait for a request - or, if the static layer is waiting for shapes
            // to stop arriving, until it's due (then rebuild with it)
            let msg = match scene.layer_wait() {
                Some(w) => match rx.recv_timeout(w.max(std::time::Duration::from_millis(50))) {
                    Ok(m) => Some(m),
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => None,
                    Err(_) => return Ok(()),
                },
                None => match rx.recv() {
                    Ok(m) => Some(m),
                    Err(_) => return Ok(()),
                },
            };
            let apply = |m: BuildMsg, scene: &mut Scene, centre: &mut Vec3| match m {
                BuildMsg::Define(name, hulls, mesh) => scene.define_shape(name, hulls, mesh),
                BuildMsg::Dynamic(v) => scene.set_dynamic(v),
                BuildMsg::Centre(c) => *centre = c,
                BuildMsg::Snapshot(reply) => {
                    let (t, r, _) = scene.build_input(*centre);
                    let _ = reply.send((t, r));
                }
            };
            if let Some(m) = msg {
                apply(m, &mut scene, &mut centre);
            }
            // quiet spell: keep absorbing messages until 150 ms pass without one -
            // but rebuild at least once a second while shapes stream in, so
            // moving things and the region around the skater stay current
            let absorb_start = Instant::now();
            loop {
                if absorb_start.elapsed() >= std::time::Duration::from_secs(1) {
                    break;
                }
                match rx.recv_timeout(std::time::Duration::from_millis(if first { 20 } else { 150 })) {
                    Ok(m) => apply(m, &mut scene, &mut centre),
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => break,
                    Err(_) => return Ok(()),
                }
            }
            first = false;
            let _ = replies.send(Reply::Wanted(scene.wanted()));
            let (input, input_half) = scene.input_key(centre);
            if last_input == Some(input) && !cleanup::off("sameskip") && !cleanup::off("inputskip") {
                if prepared.send((None, centre, input_half)).is_err() {
                    return Ok(());
                }
                continue;
            }
            last_input = Some(input);
            let t = Instant::now();
            let (tris, rails, st, tags) = scene.build_tagged(centre);
            // The same collision as the one installed: don't swap the engine's
            // world for nothing (a teleport, an unchanged entity list, a
            // position update inside the region all used to - and a swap
            // mid-ride may cost the skater its contact with the ground).
            let fingerprint = {
                let mut h: u64 = 0xcbf2_9ce4_8422_2325;
                let mut mix = |x: u32| h = (h ^ x as u64).wrapping_mul(0x0100_0000_01b3);
                for t in &tris { for v in t { for x in v { mix(x.to_bits()); } } }
                for r in &rails { mix(r.len() as u32); for v in r { for x in v { mix(x.to_bits()); } } }
                h
            };
            if last_fingerprint == Some(fingerprint) && !cleanup::off("sameskip") {
                if prepared.send((None, centre, st.half)).is_err() {
                    return Ok(());
                }
                continue;
            }
            last_fingerprint = Some(fingerprint);
            remember_collision(&tris, &tags);
            *STATIC_STATUS.lock().unwrap_or_else(|e| e.into_inner()) = Some(std::sync::Arc::new(scene.static_status()));
            let t_engine = Instant::now();
            let built = builder.build(tris, rails)?;
            if cleanup::env_var("SK8_BUILDTIME").is_ok() {
                eprintln!("BUILDTIME total {:?}, engine build {:?}", t.elapsed(), t_engine.elapsed());
            }
            if prepared.send((Some(built), centre, st.half)).is_err() {
                return Ok(());
            }
            let _ = replies.send(Reply::Built(t.elapsed().as_secs_f32() * 1000.0));
            let _ = replies.send(Reply::Collision(format!(
                "collision: {} triangles, {} rails within {:.0} m, {} static props, {} entities, {} shapes pending, {} degenerate slivers left out, built in {} ms",
                st.triangles, st.rails, st.half * 2.0 * coords::metres_per_unit(), st.statics_placed, st.entities_placed, st.missing_models, st.dropped, t.elapsed().as_millis()
            )));
        }
    };
    match catch_unwind(AssertUnwindSafe(run)) {
        Ok(Ok(())) => {}
        Ok(Err(e)) => { let _ = replies.send(Reply::Error(format!("collision builder: {e}"))); }
        Err(_) => { let _ = replies.send(Reply::Error("collision builder panicked".into())); }
    }
}

fn drain(host: &mut Host) {
    loop {
        match host.replies.try_recv() {
            Ok(Reply::Ready { load_ms, period, world }) => {
                host.status = "ready";
                host.world = Some(world);
                host.stats.load_ms = load_ms;
                host.stats.period = period;
            }
            Ok(Reply::Activated(p)) => {
                host.status = "active";
                host.pose = Some(p);
            }
            Ok(Reply::Stepped { pose, ticks, micros, pad, pad_state }) => {
                if let Some(p) = pose {
                    // Skate 3's own trick display runs a frame per engine tick
                    #[cfg(feature = "engine")]
                    {
                        let s = &p.score;
                        hud::feed(p.tick, &hud::Feed {
                            sequence_score: s.sequence,
                            line_score: s.line,
                            sequence_timer: s.sequence_timer,
                            line_time: s.line_time,
                            line_capacity: s.hud_line_capacity,
                            multiplier: s.multiplier,
                            clean: s.clean,
                            sketchy: s.sketchy,
                            stance: s.stance,
                            trick_name: s.trick_label.clone(),
                            new_trick: s.new_trick,
                            modified_trick: s.modified_trick,
                            close_tricks: s.close_tricks,
                        });
                    }
                    host.pose = Some(p);
                }
                host.pad = pad;
                host.pad_state = pad_state;
                let s = &mut host.stats;
                let now = Instant::now();
                let start = *s.window_start.get_or_insert(now);
                s.window_ticks += ticks;
                s.window_micros += micros;
                s.window_max = s.window_max.max(micros);
                if now.duration_since(start).as_secs_f32() >= 1.0 {
                    s.ticks_per_sec = s.window_ticks;
                    s.avg_tick_ms = if s.window_ticks > 0 { s.window_micros as f64 / s.window_ticks as f64 / 1000.0 } else { 0.0 };
                    s.max_step_ms = s.window_max as f64 / 1000.0;
                    s.window_start = Some(now);
                    s.window_ticks = 0;
                    s.window_micros = 0;
                    s.window_max = 0;
                }
            }
            Ok(Reply::Wanted(w)) => host.wanted = w,
            Ok(Reply::Held(h)) => {
                host.held = h;
                if h { host.holds += 1; }
            }
            Ok(Reply::Language(t, from)) => {
                host.language_from = Some(from);
                host.language = t;
            }
            Ok(Reply::Collision(c)) => host.collision = Some(c),
            Ok(Reply::Built(ms)) => {
                host.builds.push((Instant::now(), ms));
                host.builds.retain(|(t, _)| t.elapsed().as_secs_f32() < 10.0);
            }
            Ok(Reply::Recovered(e)) => {
                host.recovered += 1;
                host.warning = Some(e);
            }
            Ok(Reply::Error(e)) => {
                host.status = "error";
                host.error = Some(e);
            }
            Err(TryRecvError::Empty) => break,
            Err(TryRecvError::Disconnected) => {
                if host.status != "error" {
                    host.status = "error";
                    host.error = Some("the engine thread stopped".into());
                }
                break;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Lua functions. Each one catches panics and never raises a Lua error: problems
// come back as (false/nil, message), or as `status = "error"` from Poll.

fn col(m: &[f32; 16], c: usize) -> [f32; 3] {
    [m[c * 4], m[c * 4 + 1], m[c * 4 + 2]]
}

/// Column-major 4x4 product a * b.
fn mul(a: &[f32; 16], b: &[f32; 16]) -> [f32; 16] {
    let mut o = [0.0; 16];
    for c in 0..4 {
        for r in 0..4 {
            o[c * 4 + r] = (0..4).map(|k| a[k * 4 + r] * b[c * 4 + k]).sum();
        }
    }
    o
}

fn dist(a: [f32; 3], b: [f32; 3]) -> f32 {
    ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)).sqrt()
}

/// render_pose is the composed skeleton hierarchy; depending on the engine path
/// it can be in world space or relative to the animation root. Pick whichever
/// puts the hips near the (always world-space) camera, else near the root.
/// Within `SAME_SPACE_NEAR` (metres) of the world origin both land near the
/// camera and the guess flipped (the whole skater drawn at the map's origin
/// from then on): there the last answer stands.
fn world_bones(p: &Pose) -> (Vec<[f32; 16]>, &'static str) {
    let last = match BONES_SPACE.load(std::sync::atomic::Ordering::Relaxed) {
        1 => Some(false),
        2 => Some(true),
        _ => None,
    };
    let (bones, relative) = world_bones_with(p, last);
    if let Some(r) = relative {
        BONES_SPACE.store(if r { 2 } else { 1 }, std::sync::atomic::Ordering::Relaxed);
    }
    let space = match relative {
        Some(true) => "root-relative",
        Some(false) => "world",
        None => "none",
    };
    (bones, space)
}
static BONES_SPACE: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);
const SAME_SPACE_NEAR: f32 = 8.0;

fn world_bones_with(p: &Pose, last: Option<bool>) -> (Vec<[f32; 16]>, Option<bool>) {
    let hips = p.names.iter().position(|n| n == "HIPS").unwrap_or(1).min(p.bones.len().saturating_sub(1));
    if p.bones.is_empty() {
        return (vec![], None);
    }
    let raw = col(&p.bones[hips], 3);
    let composed = col(&mul(&p.root, &p.bones[hips]), 3);
    let reference = p.camera.as_ref().map(|c| c.0).unwrap_or(col(&p.root, 3));
    let relative = match last {
        Some(r) if dist(col(&p.root, 3), [0.0; 3]) < SAME_SPACE_NEAR && !cleanup::off("bonespace") => r,
        _ => dist(composed, reference) + 0.01 < dist(raw, reference),
    };
    if relative {
        (p.bones.iter().map(|b| mul(&p.root, b)).collect(), Some(true))
    } else {
        (p.bones.clone(), Some(false))
    }
}
fn stick(v: f64) -> i16 {
    (v.clamp(-1.0, 1.0) * 32767.0) as i16
}
fn trigger(v: f64) -> u8 {
    (v.clamp(0.0, 1.0) * 255.0) as u8
}

fn host() -> std::sync::MutexGuard<'static, Option<Host>> {
    HOST.lock().unwrap_or_else(|e| e.into_inner())
}

/// Runs a Lua function body; a Rust panic becomes (nil, message) instead of a crash.
fn guarded(l: State, f: impl FnOnce(Lua) -> c_int) -> c_int {
    let lua = Lua(l);
    match catch_unwind(AssertUnwindSafe(|| f(lua))) {
        Ok(n) => n,
        Err(_) => {
            lua.push_nil();
            lua.push_str("skategm: internal error (panic) in the native module");
            2
        }
    }
}

fn fail(lua: Lua, msg: &str) -> c_int {
    lua.push_bool(false);
    lua.push_str(msg);
    2
}

/// skategm.Load(dataPath, x, y, z, yaw) -> true | false, message
unsafe extern "C" fn load(l: State) -> c_int {
    guarded(l, |lua| {
        let Some(path) = lua.string(1) else { return fail(lua, "Load: first argument must be the data folder path") };
        if !(2..=5).all(|i| lua.is_number(i)) {
            return fail(lua, "Load: expected (path, x, y, z, yaw)");
        }
        let floor = [lua.number(2, 0.0) as f32, lua.number(3, 0.0) as f32, lua.number(4, 0.0) as f32];
        let yaw = lua.number(5, 0.0) as f32;
        let map = lua.bytes(6);
        let world_scale = lua.number(7, 1.0) as f32;
        let smooth = lua.number(8, 1.0).clamp(0.0, 2.0) as u32;
        // optional per-feature overrides of the preset (negative = preset)
        let mut opts = world::Smoothing::preset(smooth);
        let creases = lua.number(9, -1.0);
        if creases >= 0.0 {
            opts.creases = creases != 0.0;
        }
        let step = lua.number(10, -1.0);
        if step >= 0.0 {
            opts.max_step = step as f32;
        }
        {
            let mut guard = host();
            if let Some(h) = guard.as_mut() {
                drain(h);
                if h.status != "error" {
                    return fail(lua, "already loaded; call skategm.Stop() first");
                }
            }
        }
        shutdown(); // a previous engine that stopped with an error
        coords::set_world_scale(world_scale);
        let mut guard = host();
        let (job_tx, job_rx) = channel();
        let (reply_tx, reply_rx) = channel();
        let (build_tx, build_rx) = channel();
        let worker_build_tx = build_tx.clone();
        let (done_tx, done_rx) = channel();
        let root = PathBuf::from(path);
        let spawned = std::thread::Builder::new()
            .name("gm-skategm".into())
            .stack_size(32 * 1024 * 1024) // the engine needs the mashup's 32 MB stack
            .spawn(move || worker(root, floor, yaw, map, opts, job_rx, build_rx, worker_build_tx, reply_tx, done_tx));
        if let Err(e) = spawned {
            return fail(lua, &format!("could not start the engine thread: {e}"));
        }
        *guard = Some(Host {
            jobs: job_tx,
            replies: reply_rx,
            status: "loading",
            error: None,
            pose: None,
            pad: false,
            pad_state: (0, [0, 0]),
            held: false,
            holds: 0,
            world: None,
            collision: None,
            wanted: Vec::new(),
            build: build_tx,
            language: Default::default(),
            language_from: None,
            builds: Vec::new(),
            done: done_rx,
            warning: None,
            recovered: 0,
            stats: Stats::default(),
        });
        lua.push_bool(true);
        1
    })
}

/// skategm.Activate(x, y, z, yaw) -> bool
/// Does the installed collision (centre, half size) cover a spot, with room to
/// spare - at least 400 units in from its edge?
const LOOKAHEAD_SECONDS: f32 = 0.75;
pub static FROZEN: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static PAD_STICKS: Mutex<[[i16; 2]; 2]> = Mutex::new([[0, 0], [0, 0]]);

unsafe extern "C" fn set_input_blocked(l: State) -> c_int {
    guarded(l, |lua| {
        engine::INPUT_BLOCKED.store(lua.number(1, 0.0) != 0.0, std::sync::atomic::Ordering::Relaxed);
        lua.push_bool(true);
        1
    })
}

unsafe extern "C" fn pick_image(l: State) -> c_int {
    guarded(l, |lua| {
        let dir = pad::module_dir().and_then(|d| d.parent().and_then(|p| p.parent()).map(|g| g.join("data").join("skategm").join("boards")));
        match dir {
            Some(dir) => lua.push_bool(picker::start(dir)),
            None => lua.push_bool(false),
        }
        1
    })
}

unsafe extern "C" fn open_folder(l: State) -> c_int {
    guarded(l, |lua| {
        let name = lua.string(1).unwrap_or_default();
        let garrysmod = pad::module_dir().and_then(|d| d.parent().and_then(|p| p.parent()).map(|g| g.to_path_buf()));
        let ok = garrysmod.and_then(|g| picker::folder(&g, &name)).map(|p| picker::open_folder(&p)).unwrap_or(false);
        lua.push_bool(ok);
        1
    })
}

unsafe extern "C" fn mux_webm(l: State) -> c_int {
    guarded(l, |lua| {
        let names = [lua.string(1).unwrap_or_default(), lua.string(2).unwrap_or_default(), lua.string(3).unwrap_or_default()];
        let offset = lua.number(4, 0.0);
        let videos = pad::module_dir()
            .and_then(|d| d.parent().and_then(|p| p.parent()).map(|g| g.to_path_buf()))
            .and_then(|g| picker::folder(&g, "videos"));
        let result = match videos {
            None => Err("can't find the videos folder".to_string()),
            Some(_) if !names.iter().all(|n| mux::safe_name(n)) => Err("bad video name".to_string()),
            Some(dir) => {
                let file = |n: &str| dir.join(format!("{n}.webm"));
                mux::mux_files(&file(&names[0]), &file(&names[1]), &file(&names[2]), offset).map(|_| {
                    for n in &names[..2] {
                        let _ = std::fs::remove_file(file(n));
                        let _ = std::fs::remove_file(dir.join(format!("{n}.raw")));
                    }
                })
            }
        };
        match result {
            Ok(()) => {
                lua.push_bool(true);
                1
            }
            Err(e) => {
                lua.push_bool(false);
                lua.push_str(&e);
                2
            }
        }
    })
}

unsafe extern "C" fn picked_image(l: State) -> c_int {
    guarded(l, |lua| match picker::take() {
        picker::Picked::Idle => {
            lua.push_str("idle");
            1
        }
        picker::Picked::Open => {
            lua.push_str("open");
            1
        }
        picker::Picked::Cancelled => {
            lua.push_str("cancelled");
            1
        }
        picker::Picked::Done(name) => {
            lua.push_str("done");
            lua.push_str(&name);
            2
        }
        picker::Picked::Failed(why) => {
            lua.push_str("failed");
            lua.push_str(&why);
            2
        }
    })
}

unsafe extern "C" fn set_marker_blocked(l: State) -> c_int {
    guarded(l, |lua| {
        engine::MARKER_BLOCKED.store(lua.number(1, 0.0) != 0.0, std::sync::atomic::Ordering::Relaxed);
        lua.push_bool(true);
        1
    })
}

/// skategm.SetBoardFriction(units per second^2): slows a board nobody rides
/// (after a bail, on foot) along the ground; 0 = the game's own rolling.
unsafe extern "C" fn set_board_friction(l: State) -> c_int {
    guarded(l, |lua| {
        let v = lua.number(1, 0.0) as f32 * coords::metres_per_unit();
        let v = if v.is_finite() { v.max(0.0) } else { 0.0 };
        engine::BOARD_FRICTION.store(v.to_bits(), std::sync::atomic::Ordering::Relaxed);
        lua.push_bool(true);
        1
    })
}

/// skategm.SetButtonMask(bits): XInput buttons the engine doesn't see.
unsafe extern "C" fn set_button_mask(l: State) -> c_int {
    guarded(l, |lua| {
        engine::MASKED_BUTTONS.store(lua.number(1, 0.0) as u16, std::sync::atomic::Ordering::Relaxed);
        lua.push_bool(true);
        1
    })
}

unsafe extern "C" fn set_frozen(l: State) -> c_int {
    guarded(l, |lua| {
        FROZEN.store(lua.number(1, 0.0) != 0.0, std::sync::atomic::Ordering::Relaxed);
        lua.push_bool(true);
        1
    })
}
pub static UNCOVERED_TICKS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

fn covers(installed: Option<(Vec3, f32)>, at: Vec3) -> bool {
    installed.is_some_and(|(c, h)| {
        let d = (at - c).truncate().abs();
        d.x < h - 400.0 && d.y < h - 400.0
    })
}

/// How far above the given spot the skater is put (map units): a spot on the
/// floor puts the wheels level with it - or a hair into it - and collision is
/// one-sided, so from there it can fall straight through. From a little above
/// it just drops onto the ground.
const SPAWN_LIFT: f32 = 16.0;

unsafe extern "C" fn activate(l: State) -> c_int {
    guarded(l, |lua| {
        let at = [lua.number(1, 0.0) as f32, lua.number(2, 0.0) as f32, lua.number(3, 0.0) as f32 + SPAWN_LIFT];
        let yaw = lua.number(4, 0.0) as f32;
        let ok = host().as_ref().is_some_and(|h| {
            h.jobs.send(Job::Activate { spawn: coords::to_skate(at), heading: coords::heading_from_yaw(yaw) }).is_ok()
        });
        lua.push_bool(ok);
        1
    })
}

/// skategm.Step(dt, usePad, buttons, lt, rt, lx, ly, rx, ry)
unsafe extern "C" fn step(l: State) -> c_int {
    guarded(l, |lua| {
        let dt = lua.number(1, 0.0).clamp(0.0, 0.25) as f32;
        let pad = lua.boolean(2);
        let controls = Controls {
            buttons: lua.number(3, 0.0).clamp(0.0, 65535.0) as u16,
            triggers: [trigger(lua.number(4, 0.0)), trigger(lua.number(5, 0.0))],
            left: [stick(lua.number(6, 0.0)), stick(lua.number(7, 0.0))],
            right: [stick(lua.number(8, 0.0)), stick(lua.number(9, 0.0))],
        };
        if let Some(h) = host().as_ref() {
            let _ = h.jobs.send(Job::Step { dt, pad, controls });
        }
        0
    })
}

/// skategm.Poll([withNames]) -> table (positions in Source units)
unsafe extern "C" fn poll(l: State) -> c_int {
    guarded(l, |lua| {
        let names = lua.boolean(1);
        let mut guard = host();
        lua.new_table(0, 16);
        lua.field_str("engine", engine::ENGINE);
        lua.field_num("memoryMB", memory::resident_mb());
        let Some(h) = guard.as_mut() else {
            lua.field_str("status", "idle");
            return 1;
        };
        drain(h);
        lua.field_str("status", h.status);
        if let Some(e) = &h.error {
            lua.field_str("error", e);
        }
        lua.field_bool("pad", h.pad);
        // the controller, for the add-on's own features (XInput button bits;
        // triggers 0-1)
        lua.field_bool("held", h.held);
        lua.field_num("uncovered", f64::from(UNCOVERED_TICKS.load(std::sync::atomic::Ordering::Relaxed)));
        lua.field_num("holds", f64::from(h.holds));
        lua.field_num("padButtons", f64::from(h.pad_state.0));
        lua.field_num("padLT", f64::from(h.pad_state.1[0]) / 255.0);
        lua.field_num("padRT", f64::from(h.pad_state.1[1]) / 255.0);
        let sticks = *PAD_STICKS.lock().unwrap_or_else(|e| e.into_inner());
        let axis = |v: i16| (f64::from(v) / 32767.0).clamp(-1.0, 1.0);
        lua.field_num("padLX", axis(sticks[0][0]));
        lua.field_num("padLY", axis(sticks[0][1]));
        lua.field_num("padRX", axis(sticks[1][0]));
        lua.field_num("padRY", axis(sticks[1][1]));
        lua.field_bool("frozen", FROZEN.load(std::sync::atomic::Ordering::Relaxed));
        lua.field_num("moving", MOVING_COUNT.load(std::sync::atomic::Ordering::Relaxed) as f64);
        lua.field_bool("inputBlocked", engine::INPUT_BLOCKED.load(std::sync::atomic::Ordering::Relaxed));
        lua.field_bool("markerBlocked", engine::MARKER_BLOCKED.load(std::sync::atomic::Ordering::Relaxed));
        lua.field_str("padName", &engine::PAD_NAME.lock().unwrap_or_else(|e| e.into_inner()));
        lua.field_str("padType", &engine::PAD_KIND.lock().unwrap_or_else(|e| e.into_inner()));
        if let Some(w) = &h.world {
            lua.field_str("world", w);
        }
        if let Some(c) = &h.collision {
            lua.field_str("collision", c);
        }
        if let Some(l) = &h.language_from {
            lua.field_str("language", &format!("{} ({} names)", l, h.language.len()));
        }
        lua.new_table(h.wanted.len() as i32, 0);
        for (i, n) in h.wanted.iter().enumerate() {
            lua.push_str(n);
            lua.seti(i as i32 + 1);
        }
        lua.set("needModels");
        if let Some(p) = &h.pose {
            let sc = &p.score;
            lua.new_table(0, 10);
            lua.field_num("sequence", sc.sequence as f64);
            lua.field_num("line", sc.line as f64);
            lua.field_num("total", sc.total as f64);
            lua.field_num("lineTime", sc.line_time as f64);
            lua.field_num("lineCapacity", sc.line_capacity as f64);
            lua.field_num("multiplier", sc.multiplier as f64);
            lua.field_bool("clean", sc.clean);
            lua.field_bool("sketchy", sc.sketchy);
            lua.field_bool("switch", sc.stance[0]);
            // Skate 3's own English name when we have the language table
            let name = h.language.get(sc.trick.trim()).cloned().unwrap_or_else(|| sc.trick.clone());
            lua.field_str("trick", &name);
            lua.field_num("tricksNamed", f64::from(sc.tricks_named));
            lua.set("score");
            let m = &p.marker;
            lua.new_table(0, 5);
            lua.field_bool("active", m.active);
            lua.field_bool("canPlace", m.can_place);
            lua.field_bool("canReturn", m.can_return);
            lua.field_num("progress", m.progress as f64);
            if let Some(pos) = m.position {
                lua.field_vec("pos", coords::from_skate(pos));
            }
            lua.set("marker");
        }
        h.builds.retain(|(t, _)| t.elapsed().as_secs_f32() < 10.0);
        lua.field_num("builds10s", h.builds.len() as f64);
        lua.field_num("buildMs", h.builds.last().map_or(0.0, |b| b.1) as f64);
        lua.field_num("recovered", h.recovered as f64);
        if let Some(w) = &h.warning {
            lua.field_str("warning", w);
        }
        let s = &h.stats;
        lua.field_num("loadMs", s.load_ms as f64);
        lua.field_num("period", s.period as f64);
        lua.field_num("ticksPerSec", s.ticks_per_sec as f64);
        lua.field_num("avgTickMs", s.avg_tick_ms);
        lua.field_num("maxStepMs", s.max_step_ms);
        if let Some(p) = &h.pose {
            lua.field_num("tick", p.tick as f64);
            lua.field_str("state", &p.state);
            for (i, name) in ["audioWheel0", "audioWheel1", "audioWheel2", "audioWheel3", "audioGrind"].iter().enumerate() {
                lua.field_num(name, f64::from(p.audio[i]));
            }
            lua.field_bool("christAir", p.christ_air);
            lua.field_bool("bodyFlip", p.body_flip);
            lua.field_vec("pos", coords::from_skate(col(&p.root, 3)));
            lua.field_vec("axisX", coords::dir_from_skate(col(&p.root, 0)));
            lua.field_vec("axisY", coords::dir_from_skate(col(&p.root, 1)));
            lua.field_vec("axisZ", coords::dir_from_skate(col(&p.root, 2)));
            lua.field_vec("vel", coords::dir_from_skate(p.velocity).map(|v| v / coords::metres_per_unit()));
            let (bones, space) = world_bones(p);
            lua.field_str("boneSpace", space);
            lua.new_table(bones.len() as i32, 0);
            for (i, b) in bones.iter().enumerate() {
                lua.push_vec(coords::from_skate(col(b, 3)));
                lua.seti(i as i32 + 1);
            }
            lua.set("bones");
            if names {
                lua.new_table(p.names.len() as i32, 0);
                for (i, n) in p.names.iter().enumerate() {
                    lua.push_str(n);
                    lua.seti(i as i32 + 1);
                }
                lua.set("names");
            }
            if let Some((pos, basis, fov)) = &p.camera {
                lua.new_table(0, 4);
                lua.field_vec("pos", coords::from_skate(*pos));
                // the mashup looks along the camera basis z axis, with y as up
                lua.field_vec("fwd", coords::dir_from_skate(basis[2]));
                lua.field_vec("up", coords::dir_from_skate(basis[1]));
                lua.field_num("fov", *fov as f64);
                lua.set("cam");
            }
        }
        1
    })
}

/// skategm.DefineModel(name, hulls [, mesh]) where hulls = { {x,y,z, ...}, ... }:
/// a model's collision convexes in local space (triangle soup per hull), or
/// with mesh = 1 its visible mesh's triangles, already facing outward.
/// An empty hulls table marks the model as having no collision.
unsafe extern "C" fn define_model(l: State) -> c_int {
    guarded(l, |lua| {
        let Some(name) = lua.string(1) else { return fail(lua, "DefineModel: expected (name, hulls)") };
        // (mode 1: a mesh as given; 2: a mesh of either winding - map-made
        // collision - turned up-facing, see orient_up)
        let mode = lua.number(3, 0.0);
        let mesh = mode != 0.0;
        let mut hulls: Vec<Vec<Vec3>> = Vec::new();
        if lua.is_table(2) {
            for k in 1..=lua.len(2) as i32 {
                lua.geti(2, k);
                let top = lua.top();
                if lua.is_table(top) {
                    let n = lua.numbers(top);
                    hulls.push(n.chunks_exact(3).map(|c| Vec3::new(c[0] as f32, c[1] as f32, c[2] as f32)).collect());
                }
                lua.pop(1);
            }
        }
        if mode == 2.0 {
            hulls = hulls.into_iter().map(orient_up).collect();
        }
        {
            let tris: Vec<[Vec3; 3]> = if mesh {
                hulls.iter().flat_map(|h| h.chunks_exact(3).map(|t| [t[0], t[1], t[2]])).collect()
            } else {
                scene::orient_hulls(hulls.clone())
            };
            SHAPES.lock().unwrap_or_else(|e| e.into_inner()).insert(name.clone(), std::sync::Arc::new(tris));
        }
        let ok = host().as_ref().is_some_and(|h| h.build.send(BuildMsg::Define(name, hulls, mesh)).is_ok());
        lua.push_bool(ok);
        1
    })
}

/// skategm.SetEntities(list) where list = { {model, x, y, z, pitch, yaw, roll}, ... }:
/// the solid entities near the skater right now.
unsafe extern "C" fn set_entities(l: State) -> c_int {
    guarded(l, |lua| {
        if !lua.is_table(1) {
            return fail(lua, "SetEntities: expected a list");
        }
        let mut placed = Vec::new();
        for k in 1..=lua.len(1) as i32 {
            lua.geti(1, k);
            let e = lua.top();
            if lua.is_table(e) {
                lua.geti(e, 1);
                let model = lua.string(lua.top());
                lua.pop(1);
                let mut v = [0.0f32; 6];
                for (j, slot) in v.iter_mut().enumerate() {
                    lua.geti(e, j as i32 + 2);
                    *slot = lua.number(lua.top(), 0.0) as f32;
                    lua.pop(1);
                }
                if let Some(model) = model {
                    placed.push(Placed { model, origin: Vec3::new(v[0], v[1], v[2]), angles: [v[3], v[4], v[5]] });
                }
            }
            lua.pop(1);
        }
        let ok = host().as_ref().is_some_and(|h| h.build.send(BuildMsg::Dynamic(placed)).is_ok());
        lua.push_bool(ok);
        1
    })
}

/// skategm.SetMovers(list) where list = { {model, x, y, z, pitch, yaw, roll}, ... }:
/// things that move all the time (other players): they go into the moving
/// collision layer, placed now and swapped in on the next tick, instead of a
/// whole collision rebuild. Models must be defined (DefineModel) already;
/// unknown ones are skipped. Returns the triangle count sent.
unsafe extern "C" fn set_movers(l: State) -> c_int {
    guarded(l, |lua| {
        if !lua.is_table(1) {
            return fail(lua, "SetMovers: expected a list");
        }
        let shapes = SHAPES.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let mut tris: Vec<[[f32; 3]; 3]> = Vec::new();
        let mut carriers: Vec<Carrier> = Vec::new();
        for k in 1..=lua.len(1) as i32 {
            lua.geti(1, k);
            let e = lua.top();
            if lua.is_table(e) {
                lua.geti(e, 1);
                let model = lua.string(lua.top());
                lua.pop(1);
                // (x, y, z, pitch, yaw, roll, and optionally its velocity vx, vy,
                // vz and how fast its angles change - yaw, pitch, roll - in
                // degrees a second)
                let mut v = [0.0f32; 12];
                for (j, slot) in v.iter_mut().enumerate() {
                    lua.geti(e, j as i32 + 2);
                    *slot = lua.number(lua.top(), 0.0) as f32;
                    lua.pop(1);
                }
                if let Some(shape) = model.and_then(|m| shapes.get(&m).cloned()) {
                    let origin = Vec3::new(v[0], v[1], v[2]);
                    let r = scene::rotation([v[3], v[4], v[5]]);
                    if origin.is_finite() && tris.len() + shape.len() <= 20_000 {
                        for t in shape.iter() {
                            tris.push(t.map(|p| coords::to_skate((origin + r * p).to_array())));
                        }
                        let velocity = Vec3::new(v[6], v[7], v[8]);
                        let rates = [v[10], v[9], v[11]];
                        let turning = rates.iter().any(|r| r.abs() > 0.5);
                        if velocity.is_finite() && rates.iter().all(|r| r.is_finite()) && (velocity.length() > 1.0 || turning) {
                            let tops: Vec<[Vec3; 3]> = shape.iter().map(|t| t.map(|p| origin + r * p))
                                .filter(|t| (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero().z > 0.5).collect();
                            if !tops.is_empty() {
                                carriers.push(Carrier { tops, velocity, pivot: origin, angles: [v[3], v[4], v[5]], rates: if turning { rates } else { [0.0; 3] } });
                            }
                        }
                    }
                }
            }
            lua.pop(1);
        }
        let n = tris.len();
        let ok = host().as_ref().is_some_and(|h| h.jobs.send(Job::Moving(tris, carriers)).is_ok());
        if ok { lua.push_number(n as f64) } else { lua.push_bool(false) }
        1
    })
}

/// A mesh of either winding made upward-facing (the engine's collision is
/// one-sided; GMod's physics isn't, so map-made meshes come both ways):
/// floors and slopes (|nz| > 0.2) turned to face up, walls given both sides.
/// As the add-on's IM.Orient "up".
fn orient_up(points: Vec<Vec3>) -> Vec<Vec3> {
    let mut out = Vec::with_capacity(points.len() + points.len() / 2);
    for t in points.chunks_exact(3) {
        let (a, b, c) = (t[0], t[1], t[2]);
        let n = (b - a).cross(c - a);
        let l = n.length();
        if l <= 0.0 || (n.z / l).abs() <= 0.2 {
            out.extend([a, b, c, a, c, b]);
        } else if n.z < 0.0 {
            out.extend([a, c, b]);
        } else {
            out.extend([a, b, c]);
        }
    }
    out
}

/// skategm.MeshModes() -> the highest DefineModel mesh mode this module knows
unsafe extern "C" fn mesh_modes(l: State) -> c_int {
    guarded(l, |lua| {
        lua.push_number(2.0);
        1
    })
}

/// skategm.HasShape(model) -> whether SetMovers can place this model (defined
/// with DefineModel, or one of the loaded map's brush models "*N"), then its
/// bounds in its own space (min x, y, z, max x, y, z)
unsafe extern "C" fn has_shape(l: State) -> c_int {
    guarded(l, |lua| {
        let name = lua.string(1).unwrap_or_default();
        let shape = SHAPES.lock().unwrap_or_else(|e| e.into_inner()).get(&name).cloned();
        let Some(shape) = shape else {
            lua.push_bool(false);
            return 1;
        };
        let (mut lo, mut hi) = (Vec3::splat(f32::MAX), Vec3::splat(f32::MIN));
        for p in shape.iter().flatten() {
            lo = lo.min(*p);
            hi = hi.max(*p);
        }
        lua.push_bool(true);
        for v in lo.to_array().into_iter().chain(hi.to_array()) {
            lua.push_number(v as f64);
        }
        7
    })
}

/// Ends the engine threads: closing the channels makes them return, and we
/// wait (up to a few seconds) so nothing is still running when the game moves on.
fn shutdown() {
    let taken = host().take();
    if let Some(h) = taken {
        let Host { jobs, build, done, .. } = h;
        drop(jobs);
        drop(build);
        let _ = done.recv_timeout(std::time::Duration::from_secs(5));
    }
}

/// skategm.CollisionNear(x, y, z, radius [, max]) -> { x,y,z, x,y,z, x,y,z, ... }, { tag, ... }
/// Triangles of the current collision near a point (map units), for debugging,
/// and where each came from: 0 brush, 1 displacement, 2 static prop, 3 entity, 4 player.
unsafe extern "C" fn collision_near(l: State) -> c_int {
    guarded(l, |lua| {
        let c = [lua.number(1, 0.0) as f32, lua.number(2, 0.0) as f32, lua.number(3, 0.0) as f32];
        let r = lua.number(4, 512.0) as f32;
        let max = lua.number(5, 3000.0).max(0.0) as usize;
        let tris = LAST_COLLISION.lock().unwrap_or_else(|e| e.into_inner()).clone();
        lua.new_table(0, 0);
        let mut k = 1;
        let mut picked: Vec<u8> = Vec::new();
        if let Some(rem) = tris {
            let (tris, tags) = (&rem.tris, &rem.tags);
            let r2 = r * r;
            let mut hits: Vec<usize> = Vec::new();
            rem.near(c, r, |i| { hits.push(i); true });
            hits.sort_unstable();
            for ti in hits {
                let t = &tris[ti];
                if (k - 1) / 9 >= max {
                    break;
                }
                // distance from the point to the triangle's box (not its centre:
                // a big face's centre can be far from where you touch it)
                let mut d2 = 0.0f32;
                for k in 0..3 {
                    let lo = t[0][k].min(t[1][k]).min(t[2][k]);
                    let hi = t[0][k].max(t[1][k]).max(t[2][k]);
                    let d = (lo - c[k]).max(c[k] - hi).max(0.0);
                    d2 += d * d;
                }
                if d2 <= r2 {
                    for v in t {
                        for x in v {
                            lua.push_number(*x as f64);
                            lua.seti(k as i32);
                            k += 1;
                        }
                    }
                    picked.push(tags.get(ti).copied().unwrap_or(0));
                }
            }
        }
        lua.new_table(picked.len() as i32, 0);
        for (i, g) in picked.iter().enumerate() {
            lua.push_number(*g as f64);
            lua.seti(i as i32 + 1);
        }
        2
    })
}

/// skategm.ReturnToCheckpoint() - back to Skate 3's automatic checkpoint,
/// the last safe spot the engine recorded (as after falling into water).
unsafe extern "C" fn return_to_checkpoint(l: State) -> c_int {
    guarded(l, |lua| {
        let ok = host().as_ref().is_some_and(|h| h.jobs.send(Job::Checkpoint).is_ok());
        lua.push_bool(ok);
        1
    })
}


/// skategm.SetTuning(name, value | nil): set (or clear) one of the collision
/// tuning switches (SK8_OFF, SK8_CURVE_CAP, SK8_TAPER, ...) before a Load -
/// how the add-on's "collision style" setting picks classic or experimental.
unsafe extern "C" fn set_tuning(l: State) -> c_int {
    guarded(l, |lua| {
        let Some(name) = lua.string(1) else { return fail(lua, "SetTuning: expected (name, value)") };
        if !name.starts_with("SK8_") {
            return fail(lua, "SetTuning: only SK8_ switches");
        }
        match lua.string(2) {
            Some(v) if !v.is_empty() => cleanup::set_env(&name, Some(&v)),
            _ => cleanup::set_env(&name, None),
        }
        lua.push_bool(true);
        1
    })
}

/// The skater's top speed (m/s, 0 = none): the engine keeps accelerating down a
/// long drop, past what any collision handles smoothly (at 70 m/s a tick is
/// 50 units).
static SPEED_LIMIT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// skategm.SetAirDismountBlock(on): keep Y from the engine while airborne
/// (off by default: Y works in the air; on if its in-air dismount fails).
unsafe extern "C" fn set_air_dismount_block(l: State) -> c_int {
    guarded(l, |lua| {
        let on = lua.number(1, 0.0) != 0.0;
        engine::BLOCK_AIR_DISMOUNT.store(on, std::sync::atomic::Ordering::Relaxed);
        lua.push_bool(true);
        1
    })
}

/// skategm.SetAirReset(seconds): how long in the air before the engine sends
/// the skater back to a checkpoint (retail 5; 0 = never).
unsafe extern "C" fn set_air_reset(l: State) -> c_int {
    guarded(l, |lua| {
        engine::set_air_reset(lua.number(1, 30.0) as f32);
        lua.push_bool(true);
        1
    })
}

/// skategm.SetStyle(regular, style, posture, up, down, left, right): the
/// skater's natural stance (1 regular, 0 goofy), animation style ("" standard,
/// "Loose", "Gonzo", "Aggressive", "MikeCarroll", ...), posture (0-3) and the
/// D-pad gestures (0-36 each). Applied before the next step, and kept for
/// later sessions.
unsafe extern "C" fn set_style(l: State) -> c_int {
    guarded(l, |lua| {
        let g = |i: i32, d: f64| (lua.number(i, d).max(0.0) as u32).min(36);
        engine::set_style(engine::Style {
            natural: u32::from(lua.number(1, 1.0) != 0.0),
            style: lua.string(2).unwrap_or_default().chars().filter(char::is_ascii_alphanumeric).take(31).collect(),
            posture: (lua.number(3, 0.0).max(0.0) as u32).min(3),
            gestures: [g(4, 0.0), g(5, 1.0), g(6, 2.0), g(7, 3.0)],
        });
        lua.push_bool(true);
        1
    })
}

/// skategm.SetDifficulty(index): Skate 3's difficulty, 0 easy, 1 normal,
/// 2 hardcore (the game's own physics_mode tables). Kept for later sessions.
unsafe extern "C" fn set_difficulty(l: State) -> c_int {
    guarded(l, |lua| {
        let d = (lua.number(1, 0.0).max(0.0) as u32).min(2);
        engine::DIFFICULTY.store(d, std::sync::atomic::Ordering::Relaxed);
        lua.push_bool(true);
        1
    })
}

/// skategm.Punch([seconds]): swing Skate 3's shove straight ahead (riding on
/// the ground or on foot), held this long (default 0.35 s). Returns whether
/// the last punch could start (it's taken by the next step).
unsafe extern "C" fn punch(l: State) -> c_int {
    guarded(l, |lua| {
        let ticks = (lua.number(1, 0.35).clamp(0.05, 2.0) * 60.0) as u32;
        engine::PUNCH.store(ticks.max(1), std::sync::atomic::Ordering::Relaxed);
        lua.push_bool(engine::PUNCH_OK.load(std::sync::atomic::Ordering::Relaxed));
        1
    })
}

/// skategm.KnockDown(vx, vy, vz): knock the skater into a bail with this
/// velocity (map units per second, Source axes): hit by another player.
unsafe extern "C" fn knock_down(l: State) -> c_int {
    guarded(l, |lua| {
        let v = [lua.number(1, 0.0) as f32, lua.number(2, 0.0) as f32, lua.number(3, 0.0) as f32];
        let dv = coords::to_skate(v);
        let ok = dv.iter().all(|x| x.is_finite());
        if ok {
            *engine::KNOCK.lock().unwrap_or_else(|e| e.into_inner()) = Some(dv);
        }
        lua.push_bool(ok);
        1
    })
}

/// skategm.HudLoad(folder) -> true | false, error: Skate 3's own trick display,
/// from a folder prepared by SK8-ENGINE/skate-3-rust-engine's
/// tools/prepare_hud.py (it reads runtime/trickdisplay.json).
unsafe extern "C" fn hud_load(l: State) -> c_int {
    guarded(l, |lua| {
        #[cfg(feature = "engine")]
        {
            let path = lua.string(1).unwrap_or_default();
            match hud::load(std::path::Path::new(&path)) {
                Ok(()) => {
                    lua.push_bool(true);
                    1
                }
                Err(e) => fail(lua, &e),
            }
        }
        #[cfg(not(feature = "engine"))]
        {
            fail(lua, "built without the engine")
        }
    })
}

/// skategm.HudDraws() -> { { tex, mul = {r,g,b,a}, add = {r,g,b,a}, v = { x,y,u,v, ... } }, ... }
/// in the movie's 1280x720 space, three vertices per triangle; or nil, error.
unsafe extern "C" fn hud_draws(l: State) -> c_int {
    guarded(l, |lua| {
        #[cfg(feature = "engine")]
        {
            let guard = hud::HUD.lock().unwrap_or_else(|e| e.into_inner());
            let Some(s) = guard.as_ref() else { return fail(lua, "the trick display isn't loaded") };
            if let Some(e) = &s.failed {
                return fail(lua, e);
            }
            let draws = match hud::apt_scene::draw(&s.runtime.bindings.movie, &s.runtime.vm, &s.shapes) {
                Ok(d) => d,
                Err(e) => return fail(lua, &e),
            };
            lua.new_table(draws.len() as i32, 0);
            for (i, d) in draws.iter().enumerate() {
                lua.new_table(0, 5);
                lua.field_str("tex", &d.texture);
                lua.field_num("mask", f64::from(d.mask));
                for (name, c) in [("mul", d.multiply), ("add", d.add)] {
                    lua.new_table(4, 0);
                    for (k, v) in c.iter().enumerate() {
                        lua.push_number(f64::from(*v));
                        lua.seti(k as i32 + 1);
                    }
                    lua.set(name);
                }
                lua.new_table((d.vertices.len() * 4) as i32, 0);
                for (k, v) in d.vertices.iter().enumerate() {
                    for (j, x) in [v.position[0], v.position[1], v.uv[0], v.uv[1]].iter().enumerate() {
                        lua.push_number(f64::from(*x));
                        lua.seti((k * 4 + j) as i32 + 1);
                    }
                }
                lua.set("v");
                // a text field: its string and box (corners x,y ×4), for other fonts
                if let Some(t) = &d.text {
                    lua.field_str("text", &t.value);
                    lua.field_num("th", f64::from(t.height));
                    lua.field_num("talign", f64::from(t.alignment));
                    lua.field_num("tshadow", if t.shadow { 1.0 } else { 0.0 });
                    lua.new_table(8, 0);
                    for (k, x) in t.corners.iter().flatten().enumerate() {
                        lua.push_number(f64::from(*x));
                        lua.seti(k as i32 + 1);
                    }
                    lua.set("tbox");
                }
                lua.seti(i as i32 + 1);
            }
            1
        }
        #[cfg(not(feature = "engine"))]
        {
            fail(lua, "built without the engine")
        }
    })
}

/// skategm.SetLandingSettle(seconds): how long a landing must hold before its
/// trick sequence is banked (a bail or run-out within it loses the sequence).
unsafe extern "C" fn set_landing_settle(l: State) -> c_int {
    guarded(l, |lua| {
        #[cfg(feature = "engine")]
        skate_host::scoring_runtime::LANDING_SETTLE_MS.store(
            (lua.number(1, 0.25).clamp(0.0, 3.0) * 1000.0) as u32,
            std::sync::atomic::Ordering::Relaxed,
        );
        lua.push_bool(true);
        1
    })
}

unsafe extern "C" fn set_camera_shake(l: State) -> c_int {
    guarded(l, |lua| {
        engine::set_camera_shake(lua.number(1, 1.0) != 0.0);
        lua.push_bool(true);
        1
    })
}

/// skategm.SetCameraType(0 low | 1 high): Skate 3's two stock camera graphs.
unsafe extern "C" fn set_camera_type(l: State) -> c_int {
    guarded(l, |lua| {
        engine::set_camera_type(if lua.number(1, 1.0) == 0.0 { 0 } else { 1 });
        lua.push_bool(true);
        1
    })
}

/// skategm.SetSpeedLimit(m/s): hold the skater to this top speed (0 = none).
unsafe extern "C" fn set_speed_limit(l: State) -> c_int {
    guarded(l, |lua| {
        let v = lua.number(1, 0.0).max(0.0) as f32;
        SPEED_LIMIT.store(v.to_bits(), std::sync::atomic::Ordering::Relaxed);
        lua.push_bool(true);
        1
    })
}

/// skategm.Push(vx, vy, vz): add this velocity to the skater (map units per
/// second, Source axes) - a boost for testing ramps without building speed.
/// Only while riding or in the air.
/// skategm.Wipeout(): knock my skater off the board (a minigame item's hit).
unsafe extern "C" fn wipeout(l: State) -> c_int {
    guarded(l, |lua| {
        let ok = host().as_ref().is_some_and(|h| h.jobs.send(Job::Wipeout).is_ok());
        lua.push_bool(ok);
        1
    })
}

unsafe extern "C" fn push(l: State) -> c_int {
    guarded(l, |lua| {
        let v = [lua.number(1, 0.0) as f32, lua.number(2, 0.0) as f32, lua.number(3, 0.0) as f32];
        let dv = coords::to_skate(v); // linear (scale and axes), so right for velocities too
        let ok = dv.iter().all(|x| x.is_finite()) && host().as_ref().is_some_and(|h| h.jobs.send(Job::Push(dv)).is_ok());
        lua.push_bool(ok);
        1
    })
}

/// skategm.StaticPropsNear(x, y, z, radius) -> { { model, solid, status, distance }, ... }
/// The map's static props near a point, and what the collision did with each.
unsafe extern "C" fn static_props_near(l: State) -> c_int {
    guarded(l, |lua| {
        let p = Vec3::new(lua.number(1, 0.0) as f32, lua.number(2, 0.0) as f32, lua.number(3, 0.0) as f32);
        let r = lua.number(4, 128.0) as f32;
        let list = STATIC_STATUS.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let mut near: Vec<(f32, &(Vec3, String, &'static str, &'static str))> = Vec::new();
        if let Some(list) = &list {
            for e in list.iter() {
                let d = (e.0 - p).length();
                if d <= r {
                    near.push((d, e));
                }
            }
        }
        near.sort_by(|a, b| a.0.total_cmp(&b.0));
        near.truncate(8);
        lua.new_table(near.len() as i32, 0);
        for (i, (d, e)) in near.iter().enumerate() {
            lua.new_table(0, 4);
            lua.field_str("model", &e.1);
            lua.field_str("solid", e.2);
            lua.field_str("status", e.3);
            lua.field_num("distance", *d as f64);
            lua.seti(i as i32 + 1);
        }
        1
    })
}

/// skategm.PhyHulls(bytes) -> { {x,y,z, x,y,z, ...}, ... } | nil, error
/// A model's collision pieces read from its .phy file (for models GMod won't
/// build physics for).
unsafe extern "C" fn phy_hulls(l: State) -> c_int {
    guarded(l, |lua| {
        let Some(bytes) = lua.bytes(1) else { return fail(lua, "PhyHulls: expected the .phy file's bytes") };
        match phy::hulls(&bytes) {
            Ok(hulls) => {
                lua.new_table(hulls.len() as i32, 0);
                for (i, h) in hulls.iter().enumerate() {
                    lua.new_table((h.len() * 9) as i32, 0);
                    let mut k = 1;
                    for t in h {
                        for v in t {
                            for x in [v.x, v.y, v.z] {
                                lua.push_number(x as f64);
                                lua.seti(k);
                                k += 1;
                            }
                        }
                    }
                    lua.seti(i as i32 + 1);
                }
                1
            }
            Err(e) => fail(lua, &format!("PhyHulls: {e}")),
        }
    })
}

/// skategm.BrushesNear(x, y, z, radius) -> { { index, contents, faces, kept, note }, ... }
/// The map's world brushes near a point and what the conversion made of each.
unsafe extern "C" fn brushes_near(l: State) -> c_int {
    guarded(l, |lua| {
        let p = Vec3::new(lua.number(1, 0.0) as f32, lua.number(2, 0.0) as f32, lua.number(3, 0.0) as f32);
        let r = lua.number(4, 16.0) as f32;
        let list = BRUSH_STATUS.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let mut near: Vec<(f32, world::BrushInfo)> = Vec::new();
        if let Some(list) = &list {
            for b in list.iter() {
                let d = (b.lo - p).max(p - b.hi).max(Vec3::ZERO).length();
                if d <= r {
                    near.push((d, b.clone()));
                }
            }
        }
        near.sort_by(|a, b| a.0.total_cmp(&b.0));
        near.truncate(6);
        lua.new_table(near.len() as i32, 0);
        for (i, (_, b)) in near.iter().enumerate() {
            lua.new_table(0, 5);
            lua.field_num("index", b.index as f64);
            lua.field_str("contents", &format!("0x{:x}", b.contents));
            lua.field_num("faces", b.faces as f64);
            lua.field_num("kept", b.kept as f64);
            lua.field_str("note", b.note);
            lua.seti(i as i32 + 1);
        }
        1
    })
}

/// skategm.CollisionHas(x, y, z, radius) -> bool: is any collision surface
/// within radius of the point? (Cheap: the pass-through detector's check.)
unsafe extern "C" fn collision_has(l: State) -> c_int {
    guarded(l, |lua| {
        let p = Vec3::new(lua.number(1, 0.0) as f32, lua.number(2, 0.0) as f32, lua.number(3, 0.0) as f32);
        let r = lua.number(4, 16.0) as f32;
        let rem = LAST_COLLISION.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let mut found = false;
        if let Some(rem) = rem {
            rem.near(p.to_array(), r, |i| {
                found = point_triangle_distance(p, &rem.tris[i]) <= r;
                !found
            });
        }
        lua.push_bool(found);
        1
    })
}

/// skategm.Diagnose(x, y, z, nx, ny, nz) -> { line, ... }
/// For a map surface the game says is solid (a point on it and its normal):
/// which brush is there, who owns it, and what the collision did with it.
unsafe extern "C" fn diagnose(l: State) -> c_int {
    guarded(l, |lua| {
        let v = |i| lua.number(i, 0.0) as f32;
        let (p, n) = (Vec3::new(v(1), v(2), v(3)), Vec3::new(v(4), v(5), v(6)).normalize_or_zero());
        let has = collision_surface_at(p, n);
        let world = DIAG_WORLD.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let lines = match world {
            Some(w) => w.diagnose(p, n, has),
            None => vec!["no map data (flat floor, or still loading)".to_string()],
        };
        lua.new_table(lines.len() as i32, 0);
        for (i, line) in lines.iter().enumerate() {
            lua.push_str(line);
            lua.seti(i as i32 + 1);
        }
        1
    })
}

/// Engine warm-up: 0 idle, 1 running, 2 done, 3 failed (message in WARM_ERROR).
static WARM_STATE: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);
static WARM_ERROR: Mutex<Option<String>> = Mutex::new(None);
static WARM_MS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// skategm.Preload(dataPath) -> started: load Skate 3's data in the
/// background now (joining a map), so switching Skate 3 mode on later doesn't
/// wait for it. Harmless to call again; a Load meanwhile just waits its turn
/// for the same data rather than loading it twice.
unsafe extern "C" fn preload(l: State) -> c_int {
    guarded(l, |lua| {
        let Some(path) = lua.string(1) else { return fail(lua, "Preload: expected (dataPath)") };
        use std::sync::atomic::Ordering;
        let started = WARM_STATE.compare_exchange(0, 1, Ordering::SeqCst, Ordering::SeqCst).is_ok()
            || WARM_STATE.compare_exchange(3, 1, Ordering::SeqCst, Ordering::SeqCst).is_ok();
        if started {
            let root = PathBuf::from(path);
            let spawned = std::thread::Builder::new().name("skategm-warm".into()).spawn(move || {
                let t = Instant::now();
                let r = catch_unwind(AssertUnwindSafe(|| engine::Sim::preload(&root)))
                    .unwrap_or_else(|_| Err("the engine's data loader crashed".into()));
                WARM_MS.store(t.elapsed().as_millis() as u32, Ordering::SeqCst);
                match r {
                    Ok(()) => WARM_STATE.store(2, Ordering::SeqCst),
                    Err(e) => {
                        *WARM_ERROR.lock().unwrap_or_else(|e| e.into_inner()) = Some(e);
                        WARM_STATE.store(3, Ordering::SeqCst);
                    }
                }
            });
            if spawned.is_err() {
                WARM_STATE.store(3, Ordering::SeqCst);
            }
        }
        lua.push_bool(started);
        1
    })
}

/// skategm.WarmStatus() -> "idle" | "warming" | "warm" | "failed", ms, error
unsafe extern "C" fn warm_status(l: State) -> c_int {
    guarded(l, |lua| {
        use std::sync::atomic::Ordering;
        lua.push_str(match WARM_STATE.load(Ordering::SeqCst) { 0 => "idle", 1 => "warming", 2 => "warm", _ => "failed" });
        lua.push_number(f64::from(WARM_MS.load(Ordering::SeqCst)));
        match WARM_ERROR.lock().unwrap_or_else(|e| e.into_inner()).clone() {
            Some(e) => lua.push_str(&e),
            None => lua.push_nil(),
        }
        3
    })
}

/// skategm.Stop()
unsafe extern "C" fn stop(l: State) -> c_int {
    guarded(l, |_| {
        shutdown();
        0
    })
}

/// skategm.Version() -> string
unsafe extern "C" fn version(l: State) -> c_int {
    guarded(l, |lua| {
        lua.push_str(&format!("gm_skategm {} ({})", env!("CARGO_PKG_VERSION"), engine::ENGINE));
        1
    })
}

#[no_mangle]
pub unsafe extern "C" fn gmod13_open(l: State) -> c_int {
    if let Err(e) = lua::init() {
        // no Lua API, so nothing we can safely call; the error shows as a
        // missing `skategm` table on the Lua side
        eprintln!("gm_skategm: {e}");
        return 0;
    }
    pin_module();
    let lua = Lua(l);
    lua.new_table(0, 6);
    for (name, f) in [
        ("Load", load as lua::CFunction),
        ("Activate", activate),
        ("Step", step),
        ("Poll", poll),
        ("Stop", stop),
        ("DefineModel", define_model),
        ("SetEntities", set_entities),
        ("SetMovers", set_movers),
        ("HasShape", has_shape),
        ("MeshModes", mesh_modes),
        ("CollisionNear", collision_near),
        ("StaticPropsNear", static_props_near),
        ("Diagnose", diagnose),
        ("Push", push),
        ("Wipeout", wipeout),
        ("SetTuning", set_tuning),
        ("SetSpeedLimit", set_speed_limit),
        ("SetAirDismountBlock", set_air_dismount_block),
        ("SetCameraShake", set_camera_shake),
        ("SetCameraType", set_camera_type),
        ("SetStyle", set_style),
        ("SetDifficulty", set_difficulty),
        ("Punch", punch),
        ("SetLandingSettle", set_landing_settle),
        ("HudLoad", hud_load),
        ("HudDraws", hud_draws),
        ("KnockDown", knock_down),
        ("SetInputBlocked", set_input_blocked),
        ("SetMarkerBlocked", set_marker_blocked),
        ("SetButtonMask", set_button_mask),
        ("SetAirReset", set_air_reset),
        ("SetBoardFriction", set_board_friction),
        ("PickImage", pick_image),
        ("PickedImage", picked_image),
        ("OpenFolder", open_folder),
        ("MuxWebm", mux_webm),
        ("SetFrozen", set_frozen),
        ("CollisionHas", collision_has),
        ("PhyHulls", phy_hulls),
        ("BrushesNear", brushes_near),
        ("ReturnToCheckpoint", return_to_checkpoint),
        ("Version", version),
        ("Preload", preload),
        ("WarmStatus", warm_status),
    ] {
        lua.push_fn(f);
        lua.set(name);
    }
    lua.set_global("skategm");
    0
}

#[no_mangle]
pub unsafe extern "C" fn gmod13_close(_l: State) -> c_int {
    // called when you disconnect or change map
    let _ = catch_unwind(shutdown);
    0
}

/// Keep this DLL loaded for the rest of the game's life. Garry's Mod unloads
/// binary modules when a map ends; if an engine thread were still inside our
/// code at that moment, the game would crash. Pinned, the code stays mapped,
/// and the next map simply gets the same module again.
#[cfg(windows)]
fn pin_module() {
    extern "system" {
        fn GetModuleHandleExW(flags: u32, name: *const u16, module: *mut *mut std::ffi::c_void) -> i32;
    }
    const PIN: u32 = 0x1;
    const FROM_ADDRESS: u32 = 0x4;
    let mut handle = std::ptr::null_mut();
    unsafe {
        GetModuleHandleExW(PIN | FROM_ADDRESS, pin_module as *const () as *const u16, &mut handle);
    }
}
#[cfg(not(windows))]
fn pin_module() {}

#[cfg(test)]
mod tests {
    use super::*;
    fn translate(x: f32, y: f32, z: f32) -> [f32; 16] {
        let mut m = [0.0; 16];
        m[0] = 1.0; m[5] = 1.0; m[10] = 1.0; m[15] = 1.0;
        m[12] = x; m[13] = y; m[14] = z;
        m
    }
    fn pose(root: [f32; 16], hips: [f32; 16], cam: [f32; 3]) -> Pose {
        Pose { root, bones: vec![translate(0.0, 0.0, 0.0), hips], names: vec!["TRAJECTORY".into(), "HIPS".into()],
            camera: Some((cam, [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]], 70.0)), ..Default::default() }
    }
    #[test]
    fn detects_root_relative_bones() {
        // skater 100 m away; hips 1 m above the root in local space; camera 3 m behind
        let p = pose(translate(100.0, 0.0, 50.0), translate(0.0, 1.0, 0.0), [100.0, 2.0, 53.0]);
        let (b, space) = world_bones(&p);
        assert_eq!(space, "root-relative");
        assert!(dist(col(&b[1], 3), [100.0, 1.0, 50.0]) < 1e-4);
    }
    #[test]
    fn keeps_world_bones() {
        let p = pose(translate(100.0, 0.0, 50.0), translate(100.0, 1.0, 50.0), [100.0, 2.0, 53.0]);
        assert_eq!(world_bones_with(&p, None).1, Some(false));
    }
    #[test]
    fn bone_space_holds_near_the_world_origin() {
        // root-relative bones, the skater riding past the origin with the camera
        // 3 m behind: on its own the guess picks "world" (the raw hips sit nearer)
        let p = pose(translate(-0.7, 0.0, -0.6), translate(0.0, 1.0, 0.0), [1.5, 2.0, 1.5]);
        assert_eq!(world_bones_with(&p, None).1, Some(false), "the old guess, alone, is wrong here");
        let (b, space) = world_bones_with(&p, Some(true));
        assert_eq!(space, Some(true));
        assert!(dist(col(&b[1], 3), [-0.7, 1.0, -0.6]) < 1e-4);
        let far = pose(translate(100.0, 0.0, 50.0), translate(100.0, 1.0, 50.0), [100.0, 2.0, 53.0]);
        assert_eq!(world_bones_with(&far, Some(true)).1, Some(false), "away from the origin it decides afresh");
    }
}

#[cfg(test)]
mod orient_tests {
    use super::*;

    #[test]
    fn standing_on_a_carrier_is_found_just_above_its_top() {
        let v = Vec3::new;
        let c = Carrier { tops: vec![[v(0., 0., 100.), v(100., 0., 100.), v(0., 100., 100.)]], velocity: v(50., 0., 0.), pivot: v(0., 0., 100.), angles: [0.0; 3], rates: [0.0; 3] };
        let mut cs = vec![c];
        assert_eq!(carried_by(&mut cs, v(10., 10., 104.)).map(|c| c.velocity), Some(v(50., 0., 0.)), "on it");
        assert!(carried_by(&mut cs, v(10., 10., 140.)).is_none(), "well above it (in the air)");
        assert!(carried_by(&mut cs, v(10., 10., 90.)).is_none(), "under it");
        assert!(carried_by(&mut cs, v(90., 90., 104.)).is_none(), "beside it");
    }

    #[test]
    fn a_carriers_turn_follows_its_angles() {
        let v = Vec3::new;
        let mut c = Carrier { tops: Vec::new(), velocity: Vec3::ZERO, pivot: Vec3::ZERO, angles: [0.0, 0.0, 0.0], rates: [0.0, 90.0, 0.0] };
        let m = c.turn(1.0);
        assert!((m * v(1., 0., 0.) - v(0., 1., 0.)).length() < 1e-4, "yaw 90: +x to +y");
        assert!((c.angles[1] - 90.0).abs() < 1e-4, "its angles move on");
        let mut tilt = Carrier { tops: Vec::new(), velocity: Vec3::ZERO, pivot: Vec3::ZERO, angles: [0.0; 3], rates: [0.0, 0.0, 90.0] };
        let r = tilt.turn(1.0);
        assert!((r * v(0., 1., 0.) - v(0., 0., 1.)).length() < 1e-4, "roll 90: +y up to +z");
        // in the skate world (x, z, -y): the same turn
        let k = rotation_to_skate(m);
        let sx = [1.0f32, 0.0, 0.0];
        let out: Vec<f32> = (0..3).map(|i| k[i][0] * sx[0] + k[i][1] * sx[1] + k[i][2] * sx[2]).collect();
        assert!((out[0]).abs() < 1e-4 && (out[2] + 1.0).abs() < 1e-4, "map +y is skate -z");
    }

    #[test]
    fn map_meshes_are_turned_up_and_walls_doubled() {
        let v = Vec3::new;
        let down = vec![v(0., 0., 0.), v(0., 100., 0.), v(100., 0., 0.)];
        let o = orient_up(down);
        assert_eq!(o.len(), 3);
        assert!((o[1] - o[0]).cross(o[2] - o[0]).z > 0.0, "a floor wound downwards faces up");
        let wall = vec![v(0., 0., 0.), v(100., 0., 0.), v(0., 0., 100.)];
        assert_eq!(orient_up(wall).len(), 6, "a wall gets both sides");
        let up = vec![v(0., 0., 0.), v(100., 0., 0.), v(0., 100., 0.)];
        assert_eq!(orient_up(up.clone()), up, "an up-facing floor stays");
    }
}
