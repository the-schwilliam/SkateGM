//! The board's rolling layers (`player::rolling`: Class_rolling, Rolling_Rattle_Class,
//! c_board_slide) through the real banks. Data-gated: needs the disc banks extracted
//! (`SKATE_AEMS_BANKS`, else `$SKATE_AUDIO_RE_DIR/aems-banks`; `bank_layout_check.py --extract`) and,
//! for the rendered levels, their samples decoded to `$SKATE_AUDIO_RE_DIR/bank-wavs/<stem>/NNNN.wav`
//! (`tools/audio-file-inspect/decode_bank_samples.py`; else the install's) plus the install's MixMap;
//! ignored, and fails loudly otherwise (retail data is never committed).
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use skate_audio::eval::{Evaluator, OpenRequest, VoiceHost, VoiceStatus};
use skate_audio::formats::{Bank, Project};
use skate_audio::mixer::Pcm;
use skate_audio::mixmap::{MixMap, keys};
use skate_audio::player::objpos::{Listener, ObjPos};
use skate_audio::player::rolling::{self, BoardSlide, Rattle, Rolling, RollingInputs};
use skate_audio::player::components::Command;
use skate_audio::player::tuning::PlayerTuning;
use skate_audio::player::{AudioState, Owner};
use skate_audio::runtime::Runtime;

mod private_data;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn banks_dir() -> Option<PathBuf> {
    let dir = private_data::aems_banks()?;
    dir.join("csi_order.txt").is_file().then_some(dir)
}

fn projects(dir: &Path) -> Vec<Project> {
    let order = std::fs::read_to_string(dir.join("csi_order.txt")).unwrap();
    order.lines().map(|n| Project::parse(n, &std::fs::read(dir.join(n)).unwrap()).unwrap()).collect()
}

fn bank(dir: &Path, stem: &str) -> Bank {
    Bank::parse(stem, std::fs::read(dir.join(format!("{stem}.abk"))).unwrap()).unwrap()
}

/// Every bank bound to `Class_rolling` (a post reaches each, spec §1.10).
const ROLLING_BANKS: [&str; 4] = ["PatchBank_Rolling_Surfaces", "PatchBank_SpiderCracks", "PatchBank_Objects", "PatchBank_RocksBounce"];

#[derive(Default)]
struct Opens {
    next: u32,
    left: BTreeMap<u32, u32>,
    seen: BTreeMap<usize, BTreeSet<u16>>,
}

impl VoiceHost for Opens {
    fn open(&mut self, r: &OpenRequest) -> Option<u32> {
        self.next += 1;
        self.left.insert(self.next, 30);
        self.seen.entry(r.bank).or_default().insert(r.slot);
        Some(self.next)
    }
    fn release(&mut self, v: u32) {
        self.left.remove(&v);
    }
    fn pause(&mut self, _: u32) {}
    fn resume(&mut self, _: u32) {}
    fn set(&mut self, _: u32, _: u8, _: i32) {}
    fn set_azimuth(&mut self, _: u32, _: i32) {}
    fn query(&mut self, v: u32) -> VoiceStatus {
        match self.left.get_mut(&v) {
            Some(n) if *n > 0 => {
                *n -= 1;
                VoiceStatus { alive: true, remaining_ms: 32 * *n as i32, elapsed_ms: 0 }
            }
            _ => VoiceStatus::default(),
        }
    }
}

/// Which Class_rolling module answers which selector (w4) and surface (w6): post one held packet
/// per (selector, surface) at speed word 5000 with open levels, run 8 s of evaluator blocks and
/// list the bank slots opened. Diagnostic print (`--nocapture`).
#[test]
#[ignore = "needs the private install data"]
fn class_rolling_selector_census() {
    let Some(dir) = banks_dir() else { panic!("missing private data: no extracted banks") };
    println!("selector surface speed: bank slots…");
    for selector in 0..16 {
        for surface in [3, 7, 8, 10, 11, 12, 13] {
            for speed in [1500, 5000, 9000] {
                let mut eval = Evaluator::new();
                for p in projects(&dir) {
                    eval.install_project(&p);
                }
                let mut names = BTreeMap::new();
                for stem in ROLLING_BANKS {
                    names.insert(eval.load_bank(bank(&dir, stem)), stem);
                }
                let class = eval.class_id(rolling::CLASS).unwrap();
                let mut w = rolling::class_rolling_words(speed, selector, surface);
                w[0] = 32767;
                w[11] = 32767;
                w[8] = 32767;
                eval.post(class, &w);
                let mut host = Opens::default();
                for _ in 0..(8 * 48000 / 256) {
                    eval.block(&mut host);
                }
                if host.seen.is_empty() {
                    continue;
                }
                let list: Vec<String> = host.seen.iter().map(|(b, s)| format!("{} {:?}", names[b], s)).collect();
                println!("{selector:2} {surface:2} {speed:4}: {}", list.join(" | "));
            }
        }
    }
}

// --------------------------------------------------------------------------------- rendered

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

/// The samples of a bank: the decoded copies in `$SKATE_AUDIO_RE_DIR/bank-wavs`, else the install's.
fn pcm(stem: &str, count: usize) -> Option<Vec<Option<Arc<Pcm>>>> {
    for base in private_data::audio_re("bank-wavs").into_iter().chain([root().join("assets/private/audio/banks")]) {
        let d = base.join(stem);
        if d.join("0000.wav").is_file() {
            return Some((0..count).map(|i| std::fs::read(d.join(format!("{i:04}.wav"))).ok().and_then(|b| wav_pcm(&b)).map(Arc::new)).collect());
        }
    }
    None
}

fn mixmap() -> Option<Vec<u8>> {
    std::fs::read(root().join("assets/private/audio/aems/MixMapSK8.mxb")).ok()
}

/// The install's AudioSurfaceMap (`audio_manifest.json` `grain_player.surface_map`: word 1 per
/// material) as a surface table with word 1 filled (the other words are not needed here).
fn surface_table() -> Vec<[i32; 18]> {
    let Ok(text) = std::fs::read_to_string(root().join("assets/private/audio/audio_manifest.json")) else { return Vec::new() };
    let Some(at) = text.find("\"surface_map\"") else { return Vec::new() };
    let rest = &text[at..];
    let (Some(a), Some(b)) = (rest.find('['), rest.find(']')) else { return Vec::new() };
    rest[a + 1..b]
        .split(',')
        .filter_map(|x| x.trim().parse::<i32>().ok())
        .map(|s| {
            let mut row = [0i32; 18];
            row[1] = s;
            row
        })
        .collect()
}

fn globals(m: &mut MixMap) {
    for id in 1..=4 {
        m.set_input(keys::MASTER, id, 32767);
    }
    for id in [1, 2, 5] {
        m.set_input(keys::MUSIC, id, 32767);
    }
    m.set_input(keys::REVERB, 5, 32767);
}

/// Straight rolling at `kmh` on `material` (tag − 1): the skater along +x, the board 0.9 m below
/// the COM, the camera 3.5 m behind and 1.4 m above; four wheels down.
fn rolling_state(kmh: f32, material: u32, f: usize) -> AudioState {
    let v = kmh / 3.6;
    let x = v * f as f32 / 60.0;
    AudioState {
        ground_speed: v,
        com_velocity: [v, 0.0, 0.0],
        com_position: [x, 1.0, 0.0],
        board_position: [x, 0.1, 0.0],
        board_velocity: [v, 0.0, 0.0],
        wheel_count: 4,
        wheel_contact: [true; 4],
        wheel_material: [material; 4],
        ..Default::default()
    }
}

/// The two position blocks (skater COM, board) seen from a camera 3.5 m behind and 1.4 m above.
fn positions(m: &mut MixMap, pos: &mut [ObjPos; 2], s: &AudioState) {
    let l = Listener {
        camera: [s.com_position[0] - 3.5, 2.4, s.com_position[2]],
        view: [1.0, -0.3, 0.0],
        camera_velocity: s.com_velocity,
        followed: s.com_position,
        facing: s.com_velocity,
        followed_velocity: s.com_velocity,
    };
    pos[0].write(m, keys::obj_pos(0), &l, Some((s.com_position, s.com_velocity)));
    pos[1].write(m, keys::obj_pos2(0), &l, Some((s.board_position, s.board_velocity)));
}

struct Rig {
    rt: Runtime,
    names: BTreeMap<usize, &'static str>,
    nodes: BTreeMap<String, skate_audio::eval::NodeId>,
}

impl Rig {
    fn new(dir: &Path, stems: &[&'static str]) -> Option<Self> {
        let mut rt = Runtime::new();
        for p in projects(dir) {
            rt.install_project(&p);
        }
        let mut names = BTreeMap::new();
        for &stem in std::iter::once(&"emitter_utility").chain(stems) {
            let b = bank(dir, stem);
            let n = b.samples.len();
            let p = if stem == "emitter_utility" { vec![None; n] } else { pcm(stem, n)? };
            names.insert(rt.load_bank(b, p), stem);
        }
        let utility = rt.eval.class_id("c_emitter_utility").unwrap();
        rt.post(utility, &[]);
        Some(Self { rt, names, nodes: BTreeMap::new() })
    }

    fn apply(&mut self, cmds: Vec<Command>, posts: &mut u32) {
        for c in cmds {
            match c {
                Command::Post { slot, class, words } => {
                    let id = self.rt.eval.class_id(class).expect(class);
                    if let Some(old) = self.nodes.remove(&format!("{slot:?}")) {
                        self.rt.release(old);
                    }
                    self.nodes.insert(format!("{slot:?}"), self.rt.post(id, &words));
                    *posts += 1;
                }
                Command::Redeliver { slot, words } => {
                    if let Some(&n) = self.nodes.get(&format!("{slot:?}")) {
                        self.rt.redeliver(n, &words);
                    }
                }
                Command::Release { slot } => {
                    if let Some(n) = self.nodes.remove(&format!("{slot:?}")) {
                        self.rt.release(n);
                    }
                }
            }
        }
    }
}

struct Run {
    gains: BTreeMap<&'static str, Vec<f32>>,
    slots: BTreeMap<&'static str, BTreeSet<u16>>,
    posts: u32,
    first_gain: BTreeMap<&'static str, f32>,
    /// Per voice start: the peak gain in its first 0.4 s (retail's per-start level,
    /// `analyse_session.py` GAIN_WINDOW), by bank.
    starts: BTreeMap<&'static str, Vec<f32>>,
}

/// Drive [`Rolling`] (+ the rattle and slide owners) frame by frame through the real MixMap and
/// banks: PlayerPhysics + the two position blocks + the SkateBoard inputs the routing writes.
fn run(dir: &Path, mxb: &[u8], frames: usize, tuning: &PlayerTuning, state: impl Fn(usize) -> (AudioState, bool)) -> Option<Run> {
    let stems: Vec<&'static str> = ROLLING_BANKS.iter().copied().chain(["Rolling_Rattles"]).collect();
    let mut rig = Rig::new(dir, &stems)?;
    let mut m = MixMap::from_bytes(mxb).ok()?;
    let mut physics = skate_audio::player::inputs::Physics::default();
    let mut pos = [ObjPos::default(); 2];
    let mut r = Rolling::default();
    let mut rattle = Rattle::default();
    let mut out = vec![0.0f32; 1600];
    let mut run = Run { gains: BTreeMap::new(), slots: BTreeMap::new(), posts: 0, first_gain: BTreeMap::new(), starts: BTreeMap::new() };
    let mut voice_start: BTreeMap<u32, (&'static str, usize, f32)> = BTreeMap::new();
    let owner = keys::skateboard(0);
    for f in 0..frames {
        let (s, push) = state(f);
        globals(&mut m);
        physics.write(&mut m, &s);
        positions(&mut m, &mut pos, &s);
        let s = AudioState { push_trigger: push, push_planted: push, ..s };
        let inp = RollingInputs { speed_scale: None };
        let (mut cmds, routed) = r.process(&s, tuning, &inp);
        m.set_input(owner, 0, if routed.surface_pulse { 32767 } else { 0 });
        m.set_input(owner, 6, if routed.on_metal { 32767 } else { 0 });
        m.set_input(owner, 4, if s.push_planted { 32767 } else { 0 });
        cmds.extend(rattle.process(&s, &r, &tuning.rolling));
        rig.apply(cmds, &mut run.posts);
        m.tick(1.0 / 60.0);
        let o = Owner { mixmap: &m, key: owner };
        let mut cmds = r.update(&s, tuning, &inp, &o);
        cmds.extend(rattle.update(&o));
        rig.apply(cmds, &mut run.posts);
        rig.rt.fill_stereo(&mut out);
        for v in rig.rt.mixer.snapshot() {
            if let Some(&stem) = rig.names.get(&v.bank) {
                if v.gain > 0.0 {
                    run.first_gain.entry(stem).or_insert(v.gain);
                }
                run.gains.entry(stem).or_default().push(v.gain);
                run.slots.entry(stem).or_default().insert(v.slot);
                let e = voice_start.entry(v.id).or_insert((stem, f, 0.0));
                if f < e.1 + 24 {
                    e.2 = e.2.max(v.gain);
                }
            }
        }
    }
    for (stem, _, peak) in voice_start.into_values() {
        run.starts.entry(stem).or_default().push(peak);
    }
    Some(run)
}

fn quantiles(v: &[f32]) -> (f32, f32, f32) {
    let mut v: Vec<f32> = v.to_vec();
    v.sort_by(f32::total_cmp);
    let q = |p: f32| if v.is_empty() { 0.0 } else { v[((v.len() - 1) as f32 * p) as usize] };
    (q(0.5), q(0.9), q(1.0))
}

/// Class_rolling (held layers 0/3, the per-surface patch on the non-grain surfaces, the
/// spidercrack layer) and the rattle through the real banks and MixMap, per speed and surface:
/// voices (bank slots) and per-voice gains (master × dry) next to retail's per-voice levels
/// (163809 report: PatchBank_Rolling_Surfaces median 0.007 / p90 0.044 / max 0.074,
/// Rolling_Rattles 0.007 / 0.301 / 0.366; 164620: Rolling_Surfaces 0.010 / 0.121 / 0.388).
/// Asserts that something plays and that no voice exceeds unity.
#[test]
#[ignore = "needs the private install data"]
fn rolling_layers_play_their_retail_banks() {
    let (Some(dir), Some(mxb)) = (banks_dir(), mixmap()) else { panic!("missing private data: no extracted banks or MixMap") };
    let mut tuning = PlayerTuning { surface_table: surface_table(), ..Default::default() };
    if tuning.surface_table.len() < 95 {
        panic!("missing private data: no surface map in the install manifest");
    }
    tuning.surface_table.truncate(95);
    // Materials (tag − 1) per rolling surface: 3 asphalt_smooth (tag 1), 7 (tag 10), 8 (tag 8),
    // 10 (tag 67), 12 (tag 68), 13 (tag 37).
    let cases: [(&str, u32); 6] = [("surface 3 (tag 1)", 0), ("surface 7 (tag 10)", 9), ("surface 8 (tag 8)", 7), ("surface 10 (tag 67)", 66), ("surface 12 (tag 68)", 67), ("surface 13 (tag 37)", 36)];
    println!("case                  km/h push  posts  bank                        frames slots                    gain first / median / p90 / max   starts n: median / p90 / max (peak in 0.4 s)");
    let mut any = false;
    for (name, material) in cases {
        for kmh in [8.0f32, 20.0, 35.0] {
            for pushes in [false, true] {
                let Some(r) = run(&dir, &mxb, 360, &tuning, |f| {
                    let mut s = rolling_state(kmh, material, f);
                    if f >= 300 {
                        s.seam_pattern = [1; 4]; // the last second over the spidercrack pattern
                    }
                    (s, pushes && f % 90 == 30)
                }) else {
                    panic!("missing private data: bank samples not decoded (decode_bank_samples.py)");
                };
                for (bank, g) in &r.gains {
                    let audible: Vec<f32> = g.iter().copied().filter(|&x| x > 0.0).collect();
                    let (med, p90, max) = quantiles(&audible);
                    let st = r.starts.get(bank).cloned().unwrap_or_default();
                    let (smed, sp90, smax) = quantiles(&st);
                    println!(
                        "{name:21} {kmh:4.0} {pushes:5} {:5}  {bank:27} {:6} {:24} {:.3} / {med:.3} / {p90:.3} / {max:.3}   starts {:3}: {smed:.3} / {sp90:.3} / {smax:.3}",
                        r.posts,
                        audible.len(),
                        format!("{:?}", r.slots[bank]),
                        r.first_gain.get(bank).copied().unwrap_or(0.0),
                        st.len()
                    );
                    assert!(max <= 1.0, "{name} {kmh}: {bank} above unity");
                    // First-trigger rule: the first rattle of a run peaks like the later ones (the
                    // bank's PCM is decoded before use, the same path plays every push).
                    if *bank == "Rolling_Rattles" && st.len() > 1 {
                        assert!((st[0] - st[1..].iter().copied().fold(0.0f32, f32::max)).abs() < 2e-3, "{name} {kmh}: first rattle {} vs later {:?}", st[0], &st[1..]);
                    }
                    any |= !audible.is_empty();
                }
            }
        }
    }
    assert!(any, "no rolling layer sounded");
}

/// c_board_slide: the loose board (state `+780`) through `board_scrapes`.
#[test]
#[ignore = "needs the private install data"]
fn board_slide_plays_board_scrapes() {
    let (Some(dir), Some(mxb)) = (banks_dir(), mixmap()) else { panic!("missing private data: no extracted banks or MixMap") };
    let Some(mut rig) = Rig::new(&dir, &["board_scrapes"]) else { panic!("missing private data: board_scrapes not decoded") };
    let mut m = MixMap::from_bytes(&mxb).unwrap();
    let mut physics = skate_audio::player::inputs::Physics::default();
    let mut slide = BoardSlide::default();
    let mut pos = [ObjPos::default(); 2];
    let tuning = rolling::RollingTuning::default();
    let mut out = vec![0.0f32; 1600];
    let mut posts = 0;
    println!("loose  km/h  voices  gain median / max");
    for (loose, kmh) in [(1u32, 6.0f32), (2, 6.0), (2, 15.0)] {
        let mut gains = Vec::new();
        for f in 0..240 {
            let s = AudioState { wheel_count: 0, ..rolling_state(kmh, 3, f) };
            globals(&mut m);
            physics.write(&mut m, &s);
            positions(&mut m, &mut pos, &s);
            let l = if f < 180 { loose } else { 0 };
            rig.apply(slide.process(l, &tuning), &mut posts);
            m.tick(1.0 / 60.0);
            let o = Owner { mixmap: &m, key: keys::skateboard(0) };
            rig.apply(slide.update(&s, l, &tuning, &o), &mut posts);
            rig.rt.fill_stereo(&mut out);
            gains.extend(rig.rt.mixer.snapshot().iter().filter(|v| rig.names.get(&v.bank) == Some(&"board_scrapes") && v.gain > 0.0).map(|v| v.gain));
        }
        let (med, _, max) = quantiles(&gains);
        println!("{loose:5}  {kmh:4.0}  {:6}  {med:.3} / {max:.3}", gains.len());
        assert!(max <= 1.0);
    }
    assert!(posts > 0);
}

/// The rattle bank per surface code (w4) and speed word (w3): which sample a push plays and its
/// peak gain in 0.4 s, with the MixMap outputs of straight rolling at 20 km/h. Diagnostic print
/// next to retail's per-sample levels (164620: slot 8 median 0.322, 7 0.107, 0 0.050, 2 0.037,
/// 11 0.035, 1 0.026, 9 0.027, 6 0.022, 10 0.018).
#[test]
#[ignore = "needs the private install data"]
fn rattle_samples_by_surface_and_speed() {
    let (Some(dir), Some(mxb)) = (banks_dir(), mixmap()) else { panic!("missing private data: no extracted banks or MixMap") };
    println!("surface speed: slot peak …");
    for surface in 0..6 {
        let mut line = String::new();
        for speed in [0, 1500, 4000, 7000, 10000] {
            let Some(mut rig) = Rig::new(&dir, &["Rolling_Rattles"]) else { panic!("missing private data: not decoded") };
            let mut m = MixMap::from_bytes(&mxb).unwrap();
            let mut physics = skate_audio::player::inputs::Physics::default();
            let mut posts = 0;
            let mut out = vec![0.0f32; 1600];
            let mut pos = [ObjPos::default(); 2];
            let mut peak: BTreeMap<u16, f32> = BTreeMap::new();
            for f in 0..30 {
                let s = rolling_state(20.0, 0, f);
                globals(&mut m);
                physics.write(&mut m, &s);
                positions(&mut m, &mut pos, &s);
                if f == 1 {
                    rig.apply(vec![Command::Post { slot: skate_audio::player::components::Slot::RollingRattle, class: rolling::RATTLE_CLASS, words: rolling::rattle_words(speed, surface, 8) }], &mut posts);
                }
                m.tick(1.0 / 60.0);
                // Redeliver as `Rattle::update` would (the held packet lives in the rig here).
                let mut w = rolling::rattle_words(speed, surface, 8);
                w[0] = 32767;
                w[10] = m.level(keys::skateboard(0), 6);
                w[1] = m.raw(keys::skateboard(0), 0).clamp(0, 65535);
                w[2] = m.pitch_4096(keys::skateboard(0), 3).clamp(0, 8192);
                w[7] = m.level(keys::skateboard(0), 16);
                w[8] = m.level(keys::skateboard(0), 14).clamp(0, 25000);
                w[9] = m.level(keys::skateboard(0), 15).clamp(0, 25000);
                rig.apply(vec![Command::Redeliver { slot: skate_audio::player::components::Slot::RollingRattle, words: w }], &mut posts);
                rig.rt.fill_stereo(&mut out);
                for v in rig.rt.mixer.snapshot() {
                    if rig.names.get(&v.bank) == Some(&"Rolling_Rattles") {
                        let e = peak.entry(v.slot).or_insert(0.0);
                        *e = e.max(v.gain);
                    }
                }
            }
            line += &format!(" | w3 {speed:5}: {}", peak.iter().map(|(s, g)| format!("{s} {g:.3}")).collect::<Vec<_>>().join(", "));
        }
        println!("w4 {surface}{line}");
    }
}

/// The SkateBoard outputs these layers read, by speed (straight rolling, 4 wheels; and in the air).
#[test]
#[ignore = "needs the private install data"]
fn skateboard_outputs_by_speed() {
    let Some(mxb) = mixmap() else { panic!("missing private data: no MixMap") };
    println!("km/h  air  l1    l6    l7    l9    l10   l13   l16   l19   p3    p8    f11   f12   f14   f15   f17   f18   l24 l27 f25 f26 p23");
    for air in [false, true] {
        for kmh in [0.0f32, 3.0, 8.0, 15.0, 25.0, 40.0] {
            let mut m = MixMap::from_bytes(&mxb).unwrap();
            let mut physics = skate_audio::player::inputs::Physics::default();
            let mut pos = [ObjPos::default(); 2];
            for f in 0..90 {
                let mut s = rolling_state(kmh, 0, f);
                if air {
                    s.wheel_count = 0;
                    s.wheel_contact = [false; 4];
                    s.airborne = true;
                }
                globals(&mut m);
                physics.write(&mut m, &s);
                positions(&mut m, &mut pos, &s);
                m.tick(1.0 / 60.0);
            }
            let k = keys::skateboard(0);
            let l = |i| m.level(k, i);
            let fz = |i| m.filter_hz(k, i);
            println!(
                "{kmh:4.0} {air:5} {:5} {:5} {:5} {:5} {:5} {:5} {:5} {:5} {:5} {:5} {:5} {:5} {:5} {:5} {:5} {:5} {} {} {} {} {}",
                l(1), l(6), l(7), l(9), l(10), l(13), l(16), l(19), m.pitch_4096(k, 3), m.pitch_4096(k, 8),
                fz(11), fz(12), fz(14), fz(15), fz(17), fz(18), l(24), l(27), fz(25), fz(26), m.pitch_4096(k, 23)
            );
        }
    }
}

/// Diagnostic: SenseOfSpeed level(1) (rattle gain) and level(4) (wind) on the ground and in the
/// air at the same speed (listening report: rolling continues in jumps).
#[test]
#[ignore = "needs the private install data"]
fn sense_of_speed_levels_ground_vs_air() {
    let Some(mxb) = mixmap() else { panic!("missing private data: no MixMap") };
    for air in [false, true] {
        for kmh in [25.0f32, 31.0, 40.0] {
            let mut m = MixMap::from_bytes(&mxb).unwrap();
            let mut physics = skate_audio::player::inputs::Physics::default();
            let mut pos = [ObjPos::default(); 2];
            for f in 0..90 {
                let mut s = rolling_state(kmh, 0, f);
                if air {
                    s.wheel_count = 0;
                    s.wheel_contact = [false; 4];
                    s.airborne = true;
                }
                globals(&mut m);
                physics.write(&mut m, &s);
                positions(&mut m, &mut pos, &s);
                m.tick(1.0 / 60.0);
            }
            let k = keys::sense_of_speed(0);
            println!("air {air:5} {kmh:4.0} km/h: SoS level(1) {} level(4) {} level(5) {}; board level(1) {}", m.level(k, 1), m.level(k, 4), m.level(k, 5), m.level(keys::skateboard(0), 1));
        }
    }
}

/// Listening report "rolling continues in jumps": push at 30 km/h, take off 10 frames later; the
/// native layers (rattle, held layers, patch) must go quiet in the air through the MixMap words
/// (level(6)/(7)/(9)/(1) are 0 without wheels). Prints the per-bank gain before / after takeoff.
#[test]
#[ignore = "needs the private install data"]
fn layers_go_quiet_after_takeoff() {
    let (Some(dir), Some(mxb)) = (banks_dir(), mixmap()) else { panic!("missing private data: no extracted banks or MixMap") };
    let mut tuning = PlayerTuning { surface_table: surface_table(), ..Default::default() };
    if tuning.surface_table.len() < 95 {
        panic!("missing private data: no surface map");
    }
    tuning.surface_table.truncate(95);
    for material in [0u32, 7] {
        let mut ground = BTreeMap::<&str, f32>::new();
        let mut air = BTreeMap::<&str, f32>::new();
        let stems: Vec<&'static str> = ROLLING_BANKS.iter().copied().chain(["Rolling_Rattles"]).collect();
        let Some(mut rig) = Rig::new(&dir, &stems) else { panic!("missing private data: not decoded") };
        let mut m = MixMap::from_bytes(&mxb).unwrap();
        let mut physics = skate_audio::player::inputs::Physics::default();
        let mut pos = [ObjPos::default(); 2];
        let (mut r, mut k) = (Rolling::default(), Rattle::default());
        let mut out = vec![0.0f32; 1600];
        let mut posts = 0;
        for f in 0..200 {
            let mut s = rolling_state(30.0, material, f);
            s.push_trigger = f == 100;
            s.push_planted = f == 100;
            let airborne = f >= 110;
            if airborne {
                s.wheel_count = 0;
                s.wheel_contact = [false; 4];
                s.wheel_material = [skate_audio::player::state::NO_MATERIAL; 4];
                s.airborne = true;
            }
            globals(&mut m);
            physics.write(&mut m, &s);
            positions(&mut m, &mut pos, &s);
            let inp = RollingInputs::default();
            let (mut cmds, routed) = r.process(&s, &tuning, &inp);
            m.set_input(keys::skateboard(0), 0, if routed.surface_pulse { 32767 } else { 0 });
            cmds.extend(k.process(&s, &r, &tuning.rolling));
            rig.apply(cmds, &mut posts);
            m.tick(1.0 / 60.0);
            let o = Owner { mixmap: &m, key: keys::skateboard(0) };
            let mut cmds = r.update(&s, &tuning, &inp, &o);
            cmds.extend(k.update(&o));
            rig.apply(cmds, &mut posts);
            rig.rt.fill_stereo(&mut out);
            let target = if (100..110).contains(&f) { Some(&mut ground) } else if f >= 120 { Some(&mut air) } else { None };
            if let Some(t) = target {
                for v in rig.rt.mixer.snapshot() {
                    if let Some(&stem) = rig.names.get(&v.bank) {
                        let e = t.entry(stem).or_insert(0.0);
                        *e = e.max(v.gain);
                    }
                }
            }
        }
        println!("material {material}: peak gain on the ground (push..takeoff) {ground:?}");
        println!("material {material}: peak gain from 10 frames after takeoff   {air:?}");
        assert!(air.values().all(|&g| g < 0.01), "a layer keeps sounding in the air: {air:?}");
    }
}
