//! The audio thread's render must not allocate in steady state (optimisation pass 2026-10-03,
//! doc 11 "Optimisation pass"): an allocation in the device callback can wait on the process heap
//! behind the game thread. A counting allocator wraps the system one; only this thread's
//! allocations between the markers count. The scene: AEMS voices (mono and stereo, filters on,
//! azimuths and cutoffs moving every evaluator tick) routed into the eEQChain buses and the
//! FlangeSub returns, the env network on a preset, and a bound grain truck with its full chain.
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::sync::Arc;

use skate_audio::bus::env::{DEFAULT_PRESET, Preset};
use skate_audio::bus::flange::FlangePreset;
use skate_audio::eval::{OpenRequest, VoiceHost};
use skate_audio::formats::SampleHeader;
use skate_audio::grain::player::{GrainParams, GrainSource, Record};
use skate_audio::mixer::Pcm;
use skate_audio::runtime::Runtime;

struct Counting;

thread_local! {
    static COUNTING: Cell<bool> = const { Cell::new(false) };
    /// This thread's counted allocations (each test reads its own).
    static ALLOCATIONS: Cell<u64> = const { Cell::new(0) };
}

static BACKTRACES: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn count_one() {
    let _ = ALLOCATIONS.try_with(|n| n.set(n.get() + 1));
    // RENDER_ALLOC_BT=1 (read in `scene`, never inside the allocator): print where each counted
    // allocation comes from (counting off meanwhile).
    if BACKTRACES.load(std::sync::atomic::Ordering::Relaxed) {
        COUNTING.with(|c| c.set(false));
        eprintln!("counted allocation at:\n{}", std::backtrace::Backtrace::force_capture());
        COUNTING.with(|c| c.set(true));
    }
}

fn allocations() -> u64 {
    ALLOCATIONS.with(Cell::get)
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if COUNTING.try_with(Cell::get).unwrap_or(false) {
            count_one();
        }
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if COUNTING.try_with(Cell::get).unwrap_or(false) {
            count_one();
        }
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

fn reverb01() -> Preset {
    Preset([
        4000.0, 600.0, 1.0, 0.08, 0.0, 1.5, 70.0, 1.0, 0.7, 4000.0, 500.0, 1.0, 1.0, 0.25, 1.0, 1.0, 3.0, 0.1, 0.34, 1.0, 1161.0, 0.5,
        0.2, 0.6, 1.0, 1.0, 270.0, 5000.0, 0.5, 0.45, 500.0, 0.75, 0.3, 0.3, 1.0, 1.0, 90.0, 5000.0, 0.51, 0.5, 500.0, 0.75, 0.28, 0.25,
    ])
}

fn scene() -> (Runtime, Vec<u32>) {
    BACKTRACES.store(std::env::var_os("RENDER_ALLOC_BT").is_some(), std::sync::atomic::Ordering::Relaxed);
    let mut rt = Runtime::new();
    let frames = 44_100 * 4;
    let wave: Vec<f32> = (0..frames).map(|i| (i as f32 * 0.03).sin() * 0.3).collect();
    let mono = Arc::new(Pcm { rate: 44_100, channels: vec![wave.clone()] });
    let stereo = Arc::new(Pcm { rate: 44_100, channels: vec![wave.clone(), wave.clone()] });
    let header = |channels| SampleHeader { codec: 3, channels, rate: 44_100, frames: frames as u32, loop_start: Some(0) };
    rt.mixer.add_bank(0, vec![Some(header(1)), Some(header(2))], vec![Some(mono), Some(stereo)]);
    rt.mixer.buses.env.presets.insert(DEFAULT_PRESET, reverb01());
    rt.mixer.buses.env.request(DEFAULT_PRESET);
    rt.mixer.buses.flange.set_presets(
        FlangePreset([20.0, 0.3, 0.2, 0.1, 1500.0, 0.002, 0.5, 0.9, 0.03]),
        FlangePreset([1.7, 0.3, 0.0, 1.0, 250.0, 0.0005, 0.25, 0.6, 0.11]),
    );
    rt.mixer.buses.flange.frame([32692, 2313, 32692, 2313]);
    rt.mixer.buses.eq.clear(Some([5000.0, 1.5, 2.0, 2000.0, 0.8, 3.0]));
    let routes: Vec<[(u8, i32); 4]> = (0..8).map(|b| [(9u8, b), (10, 4096), (11, 1), (12, 1638)]).collect();
    let ids = (0..24)
        .filter_map(|k| {
            rt.mixer.open(&OpenRequest { bank: 0, slot: (k % 2) as u16, level: 100, azimuth: [224, 32, 0, 0, 0, 0], stream_offset: u32::MAX, inputs: &routes[k % 8] })
        })
        .collect();
    let source = Arc::new(GrainSource { name: "t".into(), duration: 4.0, pcm: Arc::new(Pcm { rate: 44_100, channels: vec![wave] }) });
    let a = GrainParams { attack: 0.1, sustain: 0.2, release: 0.1, window: 1.6, drift: 0.05 };
    let b = GrainParams { attack: 0.2, sustain: 0.1, release: 0.2, window: 1.5, drift: 0.05 };
    rt.grains.bind_truck(0, source, [a, b], [Record { gain: 0.5, pitch: 1.0, position: 0.3 }, Record { gain: 0.25, pitch: 1.0, position: 0.2 }]);
    (rt, ids)
}

#[test]
fn steady_state_render_does_not_allocate() {
    let (mut rt, ids) = scene();
    let before = allocations();
    let mut measured = 0;
    for block in 0..400usize {
        if block % 6 == 0 {
            for (k, &v) in ids.iter().enumerate() {
                rt.mixer.set_azimuth(v, ((block * 37 + k * 911) % 65536) as i32);
                rt.mixer.set(v, 6, 2000 + ((block + k * 13) % 20000) as i32);
                rt.mixer.set(v, 7, 77);
                rt.mixer.set(v, 2, 20000);
                rt.mixer.set(v, 5, 3000);
                rt.mixer.set(v, 0, 4096 + ((block + k) % 400) as i32);
            }
        }
        // Warm-up: the first blocks size the delay lines, reverb combs and the voices' caches.
        let count = block >= 100;
        COUNTING.with(|c| c.set(count));
        let _ = rt.render_block();
        COUNTING.with(|c| c.set(false));
        measured += usize::from(count);
    }
    let n = allocations() - before;
    eprintln!("{n} allocations in {measured} steady-state blocks ({} voices)", rt.mixer.voice_count());
    assert_eq!(n, 0, "render_block allocated {n} times in {measured} blocks");
}

/// The game thread's per-frame calls under the runtime lock must not allocate either (PR #32
/// review, 2026-10-03): with an installed (hand-built) AEMS bank and a posted program playing,
/// `redeliver` every console frame, `release` and the evaluator walks inside `render_block` run
/// without an allocation once warm (the walk reuses its order snapshot; `redeliver` / `release`
/// read their client lists in place; a destroy reads the module's object lists in place).
#[test]
fn installed_bank_redeliver_release_and_walks_do_not_allocate() {
    use skate_audio::eval::synthetic::{Ex, bank, player_module, project};
    let (mut rt, _) = scene();
    rt.eval.install_project(&project());
    let pcm = |frames: usize| Some(Arc::new(Pcm { rate: 48_000, channels: vec![(0..frames).map(|i| (i as f32 * 0.01).sin() * 0.2).collect()] }));
    let id = rt.load_bank(bank(&[player_module(4)], &[Ex { module: 0, kind: 1, name_id: 1, name: "c_test", at: None }], &[(48_000, true), (24_000, true)]), vec![pcm(48_000), pcm(24_000)]);
    let class = rt.eval.class_id("c_test").expect("the bank answers c_test");
    let node = rt.post(class, &[1, 4096, 1]);
    let doomed = rt.post(class, &[1, 4096, 0]);
    // A release during the warm-up too: the first destroy sizes the evaluator's free list.
    let warm = rt.post(class, &[1, 4096, 0]);
    let before = allocations();
    let mut measured = 0;
    for block in 0..600usize {
        // Warm-up: the first walks create the instances and open their voices (allocating).
        let count = block >= 120;
        COUNTING.with(|c| c.set(count));
        if block % 6 == 0 {
            rt.redeliver(node, &[1, 4096 + (block % 600) as i32, 1]);
        }
        if block == 30 {
            rt.release(warm);
        }
        if block == 300 {
            rt.release(doomed);
        }
        let _ = rt.render_block();
        COUNTING.with(|c| c.set(false));
        measured += usize::from(count);
    }
    assert!(rt.eval.bank(id).is_some(), "the bank stayed installed");
    let n = allocations() - before;
    eprintln!("{n} allocations in {measured} blocks with an installed bank ({} voices)", rt.mixer.voice_count());
    assert!(rt.mixer.voice_count() > 0, "the program plays");
    assert_eq!(n, 0, "redeliver / release / walks allocated {n} times in {measured} blocks");
}

/// A requester (`c_req`) whose program, per walk, constructs / redelivers / destructs a child post
/// through ControlClass (op 38: a `c_test` player instance created and destroyed inside the walk),
/// calls `f_msg` (op 5) with a changing parameter, and subscribes to `g_snd`; a utility (`c_util`)
/// answers the call (op 37) and publishes the parameter into `g_snd` (op 39 → `set_global`, which
/// notifies the requester). Layout: destructor @24, GlobalVariable @44, ClassData (7 values) @72,
/// ControlClass @120 (n 3), CallFunction @156 (n 1), Destroy @176. Payload: construct, destruct,
/// the child's play control / pitch / sample, the call trigger, the call parameter.
fn requester_modules() -> (Vec<skate_audio::eval::synthetic::Spec>, Vec<skate_audio::eval::synthetic::Ex>) {
    use skate_audio::be::{put_i32, put_u8};
    use skate_audio::eval::synthetic::{Ex, Spec, player_module, words};
    let mut t = words(48);
    put_u8(&mut t, 72 + 16, 7);
    put_u8(&mut t, 120 + 13, 3);
    put_u8(&mut t, 156 + 9, 1);
    let requester = Spec {
        max: 4,
        globals: 1,
        functions: 0,
        destructor: true,
        class_data: true,
        players: vec![],
        template: t,
        program: vec![
            (0, vec![(-1, 176 + 12 - 24)], 24),
            (2, vec![], 44),
            (1, vec![(20, 120 + 16 - 72), (24, 120 + 20 - 72), (28, 120 + 24 - 72), (32, 120 + 28 - 72), (36, 120 + 32 - 72), (40, 156 + 12 - 72), (44, 156 + 16 - 72)], 72),
            (38, vec![], 120),
            (5, vec![], 156),
            (4, vec![], 176),
        ],
        group_ptrs: vec![],
    };
    // Utility: function state @24 (n 1), op 39 @56 (min 0, max 1000), Destroy @80.
    let mut t = words(24);
    put_u8(&mut t, 24 + 24, 1);
    put_i32(&mut t, 56 + 12, 1000);
    put_i32(&mut t, 56 + 16, 0x7FFF_FFFE);
    put_i32(&mut t, 56 + 20, 0x7FFF_FFFE);
    let utility = Spec {
        max: 1,
        globals: 0,
        functions: 1,
        destructor: false,
        class_data: false,
        players: vec![],
        template: t,
        program: vec![(37, vec![(28, 56 + 20 - 24)], 24), (39, vec![], 56), (4, vec![], 80)],
        group_ptrs: vec![],
    };
    let exports = vec![
        Ex { module: 0, kind: 1, name_id: 3, name: "c_req", at: None },
        Ex { module: 0, kind: 0, name_id: 1, name: "g_snd", at: Some(44) },
        Ex { module: 0, kind: 1, name_id: 1, name: "c_test", at: Some(120) },
        Ex { module: 0, kind: 2, name_id: 1, name: "f_msg", at: Some(156) },
        Ex { module: 1, kind: 1, name_id: 1, name: "c_test", at: None },
        Ex { module: 2, kind: 1, name_id: 2, name: "c_util", at: None },
        Ex { module: 2, kind: 2, name_id: 1, name: "f_msg", at: Some(24) },
        Ex { module: 2, kind: 0, name_id: 1, name: "g_snd", at: Some(56) },
    ];
    (vec![requester, player_module(8), utility], exports)
}

/// The evaluator paths a real bank takes inside the render (opt pass 2, 2026-10-03): walks that
/// create and destroy instances (ControlClass posts / releases: pooled instance memory and client
/// lists), CallFunction and SetGlobalVariable fan-out (subscriber lists read in place), Player
/// opens (input records on the stack), plus game-side posts, redeliveries and releases between
/// blocks: no allocation once warm.
#[test]
fn walk_posts_calls_and_globals_do_not_allocate() {
    use skate_audio::eval::synthetic::{bank, project};
    let (mut rt, _) = scene();
    rt.eval.install_project(&project());
    let pcm = |frames: usize| Some(Arc::new(Pcm { rate: 48_000, channels: vec![(0..frames).map(|i| (i as f32 * 0.01).sin() * 0.2).collect()] }));
    let (modules, exports) = requester_modules();
    rt.load_bank(bank(&modules, &exports, &[(48_000, true), (24_000, true)]), vec![pcm(48_000), pcm(24_000)]);
    let (req, util) = (rt.eval.class_id("c_req").unwrap(), rt.eval.class_id("c_util").unwrap());
    let g = rt.eval.global_id("g_snd").unwrap();
    rt.post(util, &[]);
    let words = |block: usize| {
        let walk = block / 6;
        // Per 4 walks: construct, hold (redeliver), destruct, idle.
        let (construct, destruct) = match walk % 4 {
            0 | 1 => (1, 0),
            2 => (0, 1),
            _ => (0, 0),
        };
        [construct, destruct, 1, 4096 + (walk % 7) as i32 * 64, (walk % 2) as i32, 1, (walk % 50) as i32 + 1]
    };
    let node = rt.post(req, &words(0));
    let before = allocations();
    let (mut measured, mut extra, mut min_inst, mut max_inst) = (0, None, usize::MAX, 0);
    for block in 0..1500usize {
        let count = block >= 300;
        COUNTING.with(|c| c.set(count));
        if block % 6 == 0 {
            rt.redeliver(node, &words(block));
        }
        // Game-side posts of a second requester come and go too (calling, without a child: the
        // synthetic module record lists no ControlClass, so a destroyed requester would leave its
        // child behind).
        if block % 90 == 0 {
            let mut w = words(block);
            (w[0], w[1]) = (0, 0);
            extra = Some(rt.post(req, &w));
        }
        if block % 90 == 45
            && let Some(n) = extra.take()
        {
            rt.release(n);
        }
        let _ = rt.render_block();
        COUNTING.with(|c| c.set(false));
        if count {
            measured += 1;
            min_inst = min_inst.min(rt.eval.instance_count());
            max_inst = max_inst.max(rt.eval.instance_count());
        }
    }
    let n = allocations() - before;
    eprintln!("{n} allocations in {measured} blocks; instances {min_inst}..{max_inst}; g_snd {:?}", rt.eval.global(g));
    // The children come and go inside the walks, and the call → publish round trip ran.
    assert!(max_inst >= min_inst + 2, "instances {min_inst}..{max_inst}");
    assert_eq!(rt.eval.global(g), Some(1499 / 6 % 50 + 1));
    assert_eq!(n, 0, "walks / posts / calls / globals allocated {n} times in {measured} blocks");
}

mod private_data;

/// 16-bit PCM WAV → planar f32 (the install's bank WAVs).
fn wav_pcm(bytes: &[u8]) -> Option<Pcm> {
    let (mut channels, mut rate, mut bits) = (0usize, 0u32, 0u16);
    let mut at = 12;
    while at + 8 <= bytes.len() {
        let size = u32::from_le_bytes(bytes[at + 4..at + 8].try_into().ok()?) as usize;
        let body = at + 8;
        match &bytes[at..at + 4] {
            b"fmt " => {
                channels = usize::from(u16::from_le_bytes([bytes[body + 2], bytes[body + 3]]));
                rate = u32::from_le_bytes(bytes[body + 4..body + 8].try_into().ok()?);
                bits = u16::from_le_bytes([bytes[body + 14], bytes[body + 15]]);
            }
            b"data" if channels > 0 && bits == 16 => {
                let data = &bytes[body..(body + size).min(bytes.len())];
                let mut planar = vec![Vec::new(); channels];
                for (i, s) in data.chunks_exact(2).enumerate() {
                    planar[i % channels].push(f32::from(i16::from_le_bytes([s[0], s[1]])) / 32768.0);
                }
                return Some(Pcm { rate, channels: planar });
            }
            _ => {}
        }
        at = body + size + (size & 1);
    }
    None
}

/// A world host on the retail data (data-gated): the traffic engine banks and the ped footstep
/// bank on the real MixMap and AEMS programs, 4 cars and 15 peds (the full pools) moving around
/// the listener, posted / redelivered / released as `world_sources` does. The world objects' own
/// command lists allocate on the game thread (not counted here); the runtime calls they make
/// (post, redeliver, release) and every `render_block` (walks over the world programs, the voices
/// they open and close) must not, once warm.
#[test]
#[ignore = "needs the private install data"]
fn a_world_host_on_retail_banks_renders_without_allocating() {
    use skate_audio::eval::NodeId;
    use skate_audio::formats::{Bank, Project};
    use skate_audio::mixmap::{MixMap, keys as mkeys};
    use skate_audio::player::objpos::Listener;
    use skate_audio::world::owners::Positions;
    use skate_audio::world::peds::{PedFootstepTuning, PedSfx, PedState};
    use skate_audio::world::traffic::{EngineRecord, OutputsSnapshot, Vehicle, VehicleState};
    use skate_audio::world::{WorldCommand, WorldSlot, keys};
    use std::collections::HashMap;
    fn missing(what: &str) -> ! {
        panic!("missing private data: {what}")
    }
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let audio = root.join("assets/private/audio");
    let Ok(mxb) = std::fs::read(audio.join("aems/MixMapSK8.mxb")) else { missing("the install's MixMap") };
    let mut m = MixMap::from_bytes(&mxb).expect("MixMap");
    let Some(banks) = private_data::aems_banks() else { missing("SKATE_AEMS_BANKS / SKATE_AUDIO_RE_DIR") };
    let Ok(order) = std::fs::read_to_string(banks.join("csi_order.txt")) else { missing("csi_order.txt") };
    let mut rt = Runtime::new();
    for name in order.lines() {
        rt.install_project(&Project::parse(name, &std::fs::read(banks.join(name)).expect("csi")).expect("csi"));
    }
    let stems = [
        "emitter_utility",
        "C00_heavy01",
        "C01_family01",
        "C03_sports01",
        "C04_taxi01",
        "C05_truck01",
        "C06_sports02",
        "C07_family02",
        "C08_family03",
        "Traffic_Horn",
        "Traffic_Skid",
        "car_alarms",
        "fstep_livingworld",
    ];
    for stem in stems {
        let bank = Bank::parse(stem, std::fs::read(banks.join(format!("{stem}.abk"))).expect("abk")).expect("abk");
        let dir = audio.join("banks").join(stem);
        let pcm: Vec<_> = (0..bank.samples.len()).map(|i| std::fs::read(dir.join(format!("{i:04}.wav"))).ok().and_then(|b| wav_pcm(&b)).map(Arc::new)).collect();
        if stem != "emitter_utility" && pcm.iter().all(Option::is_none) {
            missing(&format!("{stem} WAVs (stage the world banks)"));
        }
        rt.load_bank(bank, pcm);
    }
    let utility = rt.eval.class_id("c_emitter_utility").expect("utility");
    rt.post(utility, &[]);
    let l = Listener { camera: [0.0, 1.8, 0.0], view: [0.0, 0.0, -1.0], camera_velocity: [0.0; 3], followed: [0.0, 1.0, -3.0], facing: [0.0, 0.0, -1.0], followed_velocity: [0.0; 3] };
    let (dt, frames) = (1.0f32 / 30.0, 1800usize);
    let tuning = PedFootstepTuning::default();
    let player_tuning = skate_audio::player::tuning::PlayerTuning::default();
    let mut cars: Vec<(Vehicle, Positions)> = (0..4u32).map(|g| (Vehicle::default(), Positions::new(&[keys::traffic_pos(g, 1), keys::traffic_pos(g, 2), keys::traffic_pos(g, 3)]))).collect();
    let mut peds: Vec<(PedSfx, Positions)> = (0..15u32).map(|g| (PedSfx::default(), Positions::new(&[keys::ped_pos(g)]))).collect();
    let mut nodes: HashMap<(u64, WorldSlot), NodeId> = HashMap::new();
    let mut seed = 7u32;
    let mut draw = move || {
        seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
        seed >> 8
    };
    // The runtime calls of a command list (counted when `count`; the node map's own inserts not).
    fn apply(rt: &mut Runtime, nodes: &mut HashMap<(u64, WorldSlot), NodeId>, cmds: Vec<WorldCommand>, count: bool) {
        for cmd in cmds {
            match cmd {
                WorldCommand::Post { owner, slot, class, words } => {
                    let id = rt.eval.class_id(class).expect("class bound");
                    COUNTING.with(|c| c.set(count));
                    let old = nodes.get(&(owner, slot)).copied();
                    if let Some(old) = old {
                        rt.release(old);
                    }
                    let node = rt.post(id, &words);
                    COUNTING.with(|c| c.set(false));
                    nodes.insert((owner, slot), node);
                }
                WorldCommand::Redeliver { owner, slot, words } => {
                    if let Some(&node) = nodes.get(&(owner, slot)) {
                        COUNTING.with(|c| c.set(count));
                        rt.redeliver(node, &words);
                        COUNTING.with(|c| c.set(false));
                    }
                }
                WorldCommand::Release { owner, slot } => {
                    if let Some(node) = nodes.remove(&(owner, slot)) {
                        COUNTING.with(|c| c.set(count));
                        rt.release(node);
                        COUNTING.with(|c| c.set(false));
                    }
                }
            }
        }
    }
    let car_state = |k: usize, t: f32| {
        let a = k as f32 * 1.6 + t * 0.3;
        let r = 6.0 + k as f32 * 7.0;
        let engine = EngineRecord { idle_rpm: 1400.0, max_rpm: 4000.0, patch: (k % 8) as i32, ..Default::default() };
        VehicleState { position: [r * a.cos(), 0.5, r * a.sin()], velocity: [-r * 0.3 * a.sin(), 0.0, r * 0.3 * a.cos()], direction: [1.0, 0.0, 0.0], speed: r * 0.3, engine, ..Default::default() }
    };
    let ped_state = |k: usize, t: f32| {
        let a = k as f32 * 0.4 + t * 0.1;
        let r = 3.0 + k as f32 * 2.0;
        let phase = (t + k as f32 * 0.13) % 1.1;
        PedState { position: [r * a.sin(), 0.0, r * a.cos()], velocity: [1.3, 0.0, 0.0], speed: 1.3, feet: [phase < 0.35, (0.55..0.9).contains(&phase)], materials: [3, 3], class: 2 + (k % 4) as i32, ..Default::default() }
    };
    let before = allocations();
    let (mut blocks, mut voices, mut owed) = (0usize, 0usize, 0.0f64);
    for f in 0..frames {
        // Warm-up: the first 20 s (every car / ped posts; the pools and lists reach their size).
        let count = f >= 600;
        let t = f as f32 * dt;
        for id in 1..=4 {
            m.set_input(mkeys::MASTER, id, 32767);
        }
        for id in [1, 2, 5] {
            m.set_input(mkeys::MUSIC, id, 32767);
        }
        m.set_input(mkeys::REVERB, 5, 32767);
        for (k, (car, pos)) in cars.iter_mut().enumerate() {
            let v = car_state(k, t);
            let p = Some((v.position, v.velocity));
            pos.write(&mut m, &l, &[p, p, p]);
            let cmds = car.process(k as u64, &v, &mut draw);
            apply(&mut rt, &mut nodes, cmds, count);
        }
        for (k, (sfx, pos)) in peds.iter_mut().enumerate() {
            let s = ped_state(k, t);
            pos.write(&mut m, &l, &[Some((s.position, s.velocity))]);
            let cmds = sfx.process(100 + k as u64, &s, &tuning, &mut rt.splice_host(), dt);
            apply(&mut rt, &mut nodes, cmds, count);
        }
        m.tick(dt);
        for (k, (car, _)) in cars.iter_mut().enumerate() {
            let cmds = car.update(k as u64, k as u32, &car_state(k, t), &mut m, l.camera, dt);
            apply(&mut rt, &mut nodes, cmds, count);
        }
        for (k, (sfx, _)) in peds.iter_mut().enumerate() {
            let out = OutputsSnapshot::take(&m, keys::ped_sfx(k as u32), &[7, 8]);
            let cmds = sfx.update(100 + k as u64, &ped_state(k, t), &tuning, &player_tuning, &out, &mut rt.splice_host(), dt);
            apply(&mut rt, &mut nodes, cmds, count);
        }
        owed += 48_000.0 / 256.0 * f64::from(dt);
        while owed >= 1.0 {
            owed -= 1.0;
            COUNTING.with(|c| c.set(count));
            let _ = rt.render_block();
            COUNTING.with(|c| c.set(false));
            if count {
                blocks += 1;
                voices += rt.mixer.voice_count();
            }
        }
    }
    let n = allocations() - before;
    eprintln!("{n} allocations in {blocks} blocks; {:.1} voices per block", voices as f64 / blocks as f64);
    assert!(voices > blocks * 4, "the world plays ({voices} voice-blocks in {blocks})");
    assert_eq!(n, 0, "the world host's runtime calls and renders allocated {n} times in {blocks} blocks");
}
