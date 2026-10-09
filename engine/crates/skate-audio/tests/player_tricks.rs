//! The Tricks component (`player::tricks`: Class_Flips, cloth_trick) and `Class_Treatment`
//! through the real banks, MixMap and runtime, headless, against the retail recomp sessions'
//! per-voice gains (`tools/recomp-trace/retail_voices.py`, sessions
//! all_20261002_163809 / 164620; spec `audio-specs/aems-tricks-treatment-spec.md` §6).
//!
//! Data-gated: skipped without the install's `assets/private/audio` (banks, WAVs, MixMap). The
//! `Treatments` bank is not exported by setup yet; it is read from `assets/private/audio` when
//! present, else from `$SKATE_AUDIO_RE_DIR/tricks` (a local decode of `Treatments`). Run with
//! `cargo test --release --test player_tricks -- --nocapture` for the tables.
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

mod private_data;

use skate_audio::eval::NodeId;
use skate_audio::formats::{Bank, Project};
use skate_audio::mixer::Pcm;
use skate_audio::mixmap::{MixMap, keys};
use skate_audio::player::components::{Command, Slot};
use skate_audio::player::globals::Globals;
use skate_audio::player::inputs::Physics;
use skate_audio::player::objpos::{Listener, ObjPos};
use skate_audio::player::treatment::{Treatment, TreatmentGlobals, TreatmentTuning};
use skate_audio::player::tricks::{FOLEY_UTILITY, Tricks, TricksTuning};
use skate_audio::player::{AudioState, Owner};
use skate_audio::runtime::Runtime;

/// The disc's project order (audiofiles.big archive order, as setup installs them).
const PROJECTS: &[&str] = &[
    "SK8_AEMS_Foley.csi",
    "Sk8_moments.csi",
    "Sk8_Emitters_Project.csi",
    "SK8_AEMS_rolling.csi",
    "SK8_AEMS_Crowds.csi",
    "Sk8_AEMS_MoveableObjects.csi",
    "AEMS_TRAFFIC.csi",
    "AEMS_Calibrate.csi",
    "SK8_AEMS_skateboard.csi",
];

fn root() -> PathBuf {
    Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/../../")).to_path_buf()
}

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

/// Where a bank's `.abk` and decoded WAVs are: the install, or the local research copy
/// (`$SKATE_AUDIO_RE_DIR/tricks`).
fn bank_dirs(stem: &str) -> Option<(PathBuf, PathBuf)> {
    let install = root().join("assets/private/audio");
    let local = private_data::audio_re("tricks").map(|l| (l.clone(), l));
    std::iter::once((install.join("aems"), install.clone()))
        .chain(local)
        .find(|(abk, wavs)| abk.join(format!("{stem}.abk")).is_file() && wavs.join(format!("banks/{stem}/0000.wav")).is_file())
}

struct Rig {
    rt: Runtime,
    names: HashMap<usize, &'static str>,
    mixmap: MixMap,
    physics: Physics,
    positions: [ObjPos; 2],
    nodes: HashMap<Slot, NodeId>,
    posts: Vec<(usize, &'static str, Vec<i32>)>,
    frame: usize,
}

impl Rig {
    fn new(banks: &[&'static str]) -> Option<Self> {
        let aems = root().join("assets/private/audio/aems");
        let mxb = std::fs::read(aems.join("MixMapSK8.mxb")).ok()?;
        let mut rt = Runtime::new();
        for name in PROJECTS {
            rt.install_project(&Project::parse(name, &std::fs::read(aems.join(name)).ok()?).ok()?);
        }
        let mut names = HashMap::new();
        for &stem in std::iter::once(&"emitter_utility").chain(banks) {
            let (abk, wavs) = bank_dirs(stem).or_else(|| (stem == "emitter_utility").then(|| (aems.clone(), root().join("assets/private/audio"))))?;
            let bank = Bank::parse(stem, std::fs::read(abk.join(format!("{stem}.abk"))).ok()?).ok()?;
            let pcm: Vec<Option<Arc<Pcm>>> = (0..bank.samples.len())
                .map(|i| std::fs::read(wavs.join(format!("banks/{stem}/{i:04}.wav"))).ok().and_then(|b| wav_pcm(&b)).map(Arc::new))
                .collect();
            names.insert(rt.load_bank(bank, pcm), stem);
        }
        let utility = rt.eval.class_id("c_emitter_utility")?;
        rt.post(utility, &[]);
        if let Some(foley) = rt.eval.class_id(FOLEY_UTILITY) {
            rt.post(foley, &[]); // retail posts it once at boot
        }
        let mixmap = MixMap::from_bytes(&mxb).ok()?;
        Some(Self { rt, names, mixmap, physics: Physics::default(), positions: [ObjPos::default(); 2], nodes: HashMap::new(), posts: Vec::new(), frame: 0 })
    }

    fn inputs(&mut self, s: &AudioState) {
        let m = &mut self.mixmap;
        for id in 1..=4 {
            m.set_input(keys::MASTER, id, 32767);
        }
        for id in [1, 2, 5] {
            m.set_input(keys::MUSIC, id, 32767);
        }
        m.set_input(keys::REVERB, 5, 32767);
        self.physics.write(m, s);
        let camera = [s.com_position[0] - 3.5, s.com_position[1] + 1.4, s.com_position[2]];
        let l = Listener { camera, view: [1.0, -0.3, 0.0], camera_velocity: s.com_velocity, followed: s.com_position, facing: s.com_velocity, followed_velocity: s.com_velocity };
        self.positions[0].write(m, keys::obj_pos(0), &l, Some((s.com_position, s.com_velocity)));
        self.positions[1].write(m, keys::obj_pos2(0), &l, Some((s.board_position, s.board_velocity)));
    }

    fn apply(&mut self, cmds: Vec<Command>) {
        for cmd in cmds {
            match cmd {
                Command::Post { slot, class, words } => {
                    let id = self.rt.eval.class_id(class).unwrap_or_else(|| panic!("no class {class}"));
                    if let Some(old) = self.nodes.remove(&slot) {
                        self.rt.release(old);
                    }
                    self.posts.push((self.frame, class, words.clone()));
                    let node = self.rt.post(id, &words);
                    self.nodes.insert(slot, node);
                }
                Command::Redeliver { slot, words } => {
                    if let Some(&node) = self.nodes.get(&slot) {
                        self.rt.redeliver(node, &words);
                    }
                }
                Command::Release { slot } => {
                    if let Some(node) = self.nodes.remove(&slot) {
                        self.rt.release(node);
                    }
                }
            }
        }
    }

    /// Render one 60 Hz frame (800 stereo frames at 48 kHz); per live voice (bank, slot, id, gain).
    fn render(&mut self) -> Vec<(&'static str, u16, u32, f32)> {
        self.render_frames(800)
    }

    /// Render `frames` stereo frames at 48 kHz; per live voice (bank, slot, id, gain).
    fn render_frames(&mut self, frames: usize) -> Vec<(&'static str, u16, u32, f32)> {
        let mut out = vec![0.0f32; 2 * frames];
        self.rt.fill_stereo(&mut out);
        self.frame += 1;
        self.rt.mixer.snapshot().into_iter().filter_map(|v| Some((*self.names.get(&v.bank)?, v.slot, v.id, v.gain))).collect()
    }
}

/// A trick: rolling at 20 km/h along +x, `pre` frames with the trick registered on the ground
/// (retail: cloth A ~13 frames before the air), `air` frames in the air with the deck spinning at
/// `spin` rad/s about its Ri / Up / At rows (`+480` / `+484` / `+488`), the jump height (`+260`) the
/// highest point so far of a ballistic hop over the air time, then rolling again.
fn trick_state(f: usize, id: i32, id2: i32, pre: usize, air: usize, spin: [f32; 3]) -> AudioState {
    let v = 20.0 / 3.6;
    let x = v * f as f32 / 60.0;
    let start = 30;
    let in_air = f >= start + pre && f < start + pre + air;
    let registered = f >= start && f < start + pre + air;
    let t_air = (f as f32 - (start + pre) as f32) / 60.0;
    let total = air as f32 / 60.0;
    let v0 = 9.81 * total / 2.0;
    let rise = t_air.min(total / 2.0);
    let height = v0 * rise - 0.5 * 9.81 * rise * rise;
    AudioState {
        ground_speed: v,
        com_velocity: [v, 0.0, 0.0],
        com_position: [x, 1.0, 0.0],
        board_position: [x, 0.1, 0.0],
        board_velocity: [v, 0.0, 0.0],
        wheel_count: if in_air { 0 } else { 4 },
        wheel_contact: [!in_air; 4],
        wheel_material: [if in_air { 143 } else { 3 }; 4],
        airborne: in_air,
        air_time: if in_air { t_air } else { 0.0 },
        air_until_landing: if in_air { total - t_air } else { 0.0 },
        jump_height: if in_air { height } else { 0.0 },
        trick_active: registered,
        audio_trick: if registered { id } else { -1 },
        audio_trick_2: if registered { id2 } else { -1 },
        scorable: if registered { 1 } else { -1 },
        deck_spin_xy: if in_air { [spin[0], spin[1]] } else { [0.0; 2] },
        deck_spin: if in_air { spin[2] } else { 0.0 },
        ..Default::default()
    }
}

struct Stats {
    /// Per bank: per voice id, (slot, start frame, gains while it sounded).
    voices: HashMap<&'static str, std::collections::BTreeMap<u32, (u16, usize, Vec<f32>)>>,
    posts: Vec<(usize, &'static str, Vec<i32>)>,
}

fn run_tricks(frames: usize, state: impl Fn(usize) -> AudioState) -> Option<Stats> {
    let mut rig = Rig::new(&["Sk8_Air_Flip_Tricks", "Foley_Cloth"])?;
    let (t, g) = (TricksTuning::default(), Globals::default());
    let mut k = Tricks::default();
    let mut voices: HashMap<&'static str, std::collections::BTreeMap<u32, (u16, usize, Vec<f32>)>> = HashMap::new();
    for f in 0..frames {
        let s = state(f);
        rig.inputs(&s);
        let cmds = k.process(&s, &t, &g, &Owner { mixmap: &rig.mixmap, key: keys::tricks(0) });
        rig.apply(cmds);
        rig.mixmap.tick(s.dt);
        let cmds = k.update(&s, &t, &Owner { mixmap: &rig.mixmap, key: keys::tricks(0) });
        rig.apply(cmds);
        for (bank, slot, id, gain) in rig.render() {
            voices.entry(bank).or_default().entry(id).or_insert((slot, f, Vec::new())).2.push(gain);
        }
    }
    Some(Stats { voices, posts: rig.posts })
}

fn peak(g: &[f32]) -> f32 {
    g.iter().copied().fold(0.0, f32::max)
}

/// Kickflip, heelflip, pop shove-it, 360 flip and ollie through the real banks: what posts, which
/// samples open and at which (peak) gain, against retail's Sk8_Air_Flip_Tricks per-stream medians
/// (164620: streams 0–3 0.35–0.37, 5 0.134, 10–13 ~0.04) and the cloth_trick samples (8–24:
/// 0.21–0.31). Asserts: Class_Flips posts once on the first air frame and opens a voice; the
/// voices stay within unity and the flip whooshes land within 3 dB of retail's 0.35.
#[test]
#[ignore = "needs the private install data"]
fn tricks_play_their_retail_banks() {
    // Flips spin about the deck's At row, shove-its about Up, the ollie pitches about Ri.
    let cases = [
        ("kickflip", 0, 28, [0.0, 0.0, 25.0]),
        ("heelflip", 1, 28, [0.0, 0.0, -25.0]),
        ("popshuvit", 2, 28, [0.0, 12.0, 0.0]),
        ("360flip", 10, 28, [0.0, 12.0, 25.0]),
        ("ollie", 28, -1, [2.0, 0.0, 0.0]),
    ];
    println!("trick       posts (frame class w11)              Flips voices slot:peak            cloth voices slot:peak");
    let mut whooshes = Vec::new();
    for (name, id, id2, spin) in cases {
        let Some(r) = run_tricks(150, |f| trick_state(f, id, id2, 13, 36, spin)) else {
            panic!("missing private data: no install with the trick banks and MixMap");
        };
        let posts: Vec<String> = r.posts.iter().map(|(f, c, w)| format!("{f}:{c}:{}", if *c == "Class_Flips" { w[11] } else { w[9] })).collect();
        let list = |bank: &str| -> String {
            r.voices.get(bank).map_or(String::new(), |v| v.values().map(|(slot, _, g)| format!("{slot}:{:.3}", peak(g))).collect::<Vec<_>>().join(" "))
        };
        println!("{name:10}  {:40} {:30} {}", posts.join(" "), list("Sk8_Air_Flip_Tricks"), list("Foley_Cloth"));
        let flips: Vec<_> = r.posts.iter().filter(|p| p.1 == "Class_Flips").collect();
        assert_eq!(flips.len(), 1, "{name}: one Class_Flips post");
        assert_eq!(flips[0].0, 30 + 13, "{name}: posted on the first air frame");
        let fv = r.voices.get("Sk8_Air_Flip_Tricks").cloned().unwrap_or_default();
        assert!(!fv.is_empty(), "{name}: no Sk8_Air_Flip_Tricks voice");
        for (bank, v) in &r.voices {
            for (slot, _, g) in v.values() {
                assert!(peak(g) <= 1.0, "{name}: {bank}:{slot} above unity");
            }
        }
        whooshes.extend(fv.values().filter(|(slot, ..)| *slot <= 3).map(|(.., g)| peak(g)));
    }
    if !whooshes.is_empty() {
        whooshes.sort_by(f32::total_cmp);
        let med = whooshes[whooshes.len() / 2];
        let db = 20.0 * (med / 0.35).log10();
        println!("flip whooshes (slots 0-3): {} voices, median peak gain {med:.3} vs retail 0.35 ({db:+.1} dB)", whooshes.len());
        assert!(db.abs() < 3.0, "flip whoosh {db:+.1} dB from retail");
    }
}

/// First-trigger rule: the same kickflip twice; every voice of the first trick (the bank's first
/// use) peaks at the gain the same sample reaches in the second.
#[test]
#[ignore = "needs the private install data"]
fn the_first_flip_sounds_like_the_second() {
    let Some(r) = run_tricks(300, |f| trick_state(f % 150, 0, 28, 13, 36, [0.0, 0.0, 25.0])) else {
        panic!("missing private data: no install with the trick banks and MixMap");
    };
    for bank in ["Sk8_Air_Flip_Tricks", "Foley_Cloth"] {
        let v = &r.voices[bank];
        let first: Vec<(u16, f32)> = v.values().filter(|x| x.1 < 150).map(|(slot, _, g)| (*slot, peak(g))).collect();
        let second: Vec<(u16, f32)> = v.values().filter(|x| x.1 >= 150).map(|(slot, _, g)| (*slot, peak(g))).collect();
        println!("{bank}: first trick {first:?}, second {second:?}");
        assert!(!first.is_empty() && !second.is_empty(), "{bank}: both tricks play");
        for (slot, gain) in &first {
            if let Some((_, later)) = second.iter().find(|(s, _)| s == slot) {
                assert!((20.0 * (gain / later).log10()).abs() < 0.1, "{bank} slot {slot}: first {gain} vs later {later}");
            }
        }
    }
}

/// Two 0.6 s airs (retail's scripted hops are 0.61–0.64 s): returns per Treatments voice (start
/// frame, slot, peak gain) and the Class_Treatment post count.
fn run_treatment(b: TreatmentGlobals) -> Option<(Vec<(usize, u16, f32)>, usize)> {
    run_treatment_with(b, |f| trick_state(f % 200, 0, 28, 13, 36, [0.0, 0.0, 25.0]))
}

fn run_treatment_with(b: TreatmentGlobals, state: impl Fn(usize) -> AudioState) -> Option<(Vec<(usize, u16, f32)>, usize)> {
    let mut rig = Rig::new(&["Treatments"])?;
    let (t, g) = (TreatmentTuning::default(), Globals::default());
    let mut k = Treatment::default();
    let mut voices: HashMap<u32, (u16, usize, Vec<f32>)> = HashMap::new();
    for f in 0..400 {
        let s = state(f);
        rig.inputs(&s);
        let cmds = k.process(&s, &t, &g, &Owner { mixmap: &rig.mixmap, key: keys::treatments(0) });
        rig.apply(cmds);
        rig.mixmap.tick(s.dt);
        let cmds = k.update(&s, &b, &t, &Owner { mixmap: &rig.mixmap, key: keys::treatments(0) });
        rig.apply(cmds);
        for (_, slot, id, gain) in rig.render() {
            voices.entry(id).or_insert((slot, f, Vec::new())).2.push(gain);
        }
    }
    let mut starts: Vec<(usize, u16, f32)> = voices.values().map(|(slot, f, g)| (*f, *slot, peak(g))).collect();
    starts.sort_by_key(|x| (x.0, x.1));
    Some((starts, rig.posts.iter().filter(|p| p.1 == "Class_Treatment").count()))
}

/// Class_Treatment through the real bank: posted once, its streams 13 and 14 start in each air at
/// retail's gains (164620: 54 × 0.0746 and 50 × 0.0186 — within 0.5 dB) when the predicted time to
/// the landing (`+240`, w8) falls through ~0.37 s (retail: 14–326 ms before the touchdown contact,
/// the prediction being approximate). Slots 16 / 17 (the long-air layer that follows w8 from
/// takeoff) play too, as in the recomp (see `treatment_replay_of_the_recomp_capture`). Also prints,
/// with the `B+164` flag of PR #4's capture set, slots 0–12 (retail never plays them: the reset
/// values stay).
#[test]
#[ignore = "needs the private install data"]
fn treatment_plays_before_the_landing_at_the_retail_level() {
    let Some((starts, posts)) = run_treatment(TreatmentGlobals::default()) else {
        panic!("missing private data: no Treatments bank (decode_bank.py Treatments) or no install");
    };
    let landings = [30 + 13 + 36, 230 + 13 + 36];
    println!("Treatments voices (start frame, slot, peak gain), landings at frames {landings:?}:\n  {starts:?}");
    assert_eq!(posts, 1, "posted once");
    for land in landings {
        for (slot, retail) in [(13u16, 0.0746f32), (14, 0.0186)] {
            let v = starts.iter().find(|v| v.1 == slot && v.0 < land && v.0 + 30 > land);
            let Some(&(f, _, gain)) = v else { panic!("slot {slot} did not start before the landing at {land}") };
            let db = 20.0 * (gain / retail).log10();
            println!("  slot {slot}: {} frames before the landing, gain {gain:.4} vs retail {retail} ({db:+.2} dB)", land - f);
            assert!(db.abs() < 0.5, "slot {slot}: {db:+.2} dB");
        }
    }
    if let Some((with_flag, _)) = run_treatment(TreatmentGlobals { flag_164: true, value_168: 1.0, ..Default::default() }) {
        let extra: Vec<_> = with_flag.iter().filter(|v| v.1 <= 12).collect();
        println!("with B+164 set and B+168 = 1.0 (PR #4's capture): slots 0-12 open {} times: {extra:?}", extra.len());
    }
}

/// The teleport static: `B+164` / `B+168` are the VisualDirector's teleport effect amount
/// (`cMsgTeleportEffectAmount`, decoded by `sub_827AB790` from the presentation packet; present only
/// on frames that received the message). A Go To Marker hold of `hold_ticks` UI ticks (60 Hz) with the
/// amount ramping `t / hold_ticks`, the relocation in the last tick and two more ticks at 1.0, the
/// skater standing still. Returns per Treatments voice of slots 0–12 (start in ms from the hold's
/// first tick, slot, peak gain) and the relocation tick's time in ms.
fn teleport_hold(hold_ticks: usize, seed_frames: usize) -> Option<(Vec<(f32, u16, f32)>, f32)> {
    teleport_hold_audio(hold_ticks, seed_frames, None).map(|(v, jump, _)| (v, jump))
}

/// [`teleport_hold`] plus the rendered stereo output from the hold's first tick (48 kHz,
/// interleaved); `released`: the stick is let go after that many ticks (no relocation, no tail).
fn teleport_hold_audio(hold_ticks: usize, seed_frames: usize, released: Option<usize>) -> Option<(Vec<(f32, u16, f32)>, f32, Vec<f32>)> {
    let mut rig = Rig::new(&["Treatments"])?;
    let (t, g) = (TreatmentTuning::default(), Globals::default());
    let mut k = Treatment::default();
    let start = 30 + seed_frames;
    let relocate = start + hold_ticks; // the tick in which elapsed passes the hold's duration
    let mut voices: HashMap<u32, (u16, usize, Vec<f32>)> = HashMap::new();
    let mut audio = Vec::new();
    for f in 0..relocate + 90 {
        let s = AudioState::default();
        let b = if released.is_some_and(|r| f > start + r) {
            TreatmentGlobals::default()
        } else if f > start && f <= relocate {
            TreatmentGlobals { flag_164: true, value_168: ((f - start) as f32 / hold_ticks as f32).min(1.0), ..Default::default() }
        } else if f > relocate && f <= relocate + 2 {
            TreatmentGlobals { flag_164: true, value_168: 1.0, ..Default::default() }
        } else {
            TreatmentGlobals::default()
        };
        rig.inputs(&s);
        let cmds = k.process(&s, &t, &g, &Owner { mixmap: &rig.mixmap, key: keys::treatments(0) });
        rig.apply(cmds);
        rig.mixmap.tick(s.dt);
        let cmds = k.update(&s, &b, &t, &Owner { mixmap: &rig.mixmap, key: keys::treatments(0) });
        rig.apply(cmds);
        let mut out = vec![0.0f32; 1600];
        rig.rt.fill_stereo(&mut out);
        rig.frame += 1;
        if f > start {
            audio.extend_from_slice(&out);
        }
        for v in rig.rt.mixer.snapshot() {
            if rig.names.contains_key(&v.bank) {
                voices.entry(v.id).or_insert((v.slot, f, Vec::new())).2.push(v.gain);
            }
        }
    }
    let ms = |f: usize| (f as f32 - (start + 1) as f32) * 1000.0 / 60.0;
    let mut out: Vec<(f32, u16, f32)> = voices.values().filter(|v| v.0 <= 12).map(|(slot, f, g)| (ms(*f), *slot, peak(g))).collect();
    out.sort_by(|a, b| a.0.total_cmp(&b.0));
    Some((out, ms(relocate), audio))
}

/// The teleport crackle (Class_Treatment's teleport layer, `Treatments` slots 1–12 while the
/// effect is on, slot 0 when it reaches 1.0) against the recomp (the user's session of 2026-10-04
/// 12:53 with the marker hooks, plus three earlier sessions; voice gains from
/// `tools/recomp-trace/retail_voices.py`): the 1559 m return holds 1.0 s (61 effect messages), its
/// first crackle starts 40 ms after the first message (24 and 68 ms on two other holds), 15 crackles
/// sound through the hold, the last 0.18 s before the jump, slot 0 starts 5–33 ms after the jump (12
/// of 12 completed holds; gain 0.1229 on 10), none after a released hold (0.43 s to 0.70); short
/// holds (0.2 s, ≤ 100 m) sound 3–5 crackles. Crackle peak gains over 68 voices: median 0.1870,
/// max 0.2842.
#[test]
#[ignore = "needs the private install data"]
fn teleport_crackle_follows_the_recomp() {
    let mut gains = Vec::new();
    for seed in [0usize, 7, 23, 41] {
        let Some((v, jump)) = teleport_hold(60, seed) else {
            panic!("missing private data: no install with the Treatments bank and MixMap");
        };
        let crackles: Vec<_> = v.iter().filter(|x| x.1 >= 1).collect();
        let ends: Vec<_> = v.iter().filter(|x| x.1 == 0).collect();
        println!("1.0 s hold (seed {seed}): {} crackles, first at {:.0} ms, last {:.0} ms, slot 0 {:?}, jump {jump:.0} ms", crackles.len(), crackles[0].0, crackles.last().unwrap().0, ends);
        assert!(crackles[0].0 <= 70.0, "onset {} ms", crackles[0].0);
        assert!((10..=24).contains(&crackles.len()), "{} crackles in 1.0 s (recomp 15)", crackles.len());
        assert!(crackles.iter().all(|c| c.0 < jump + 1.0), "a crackle after the jump");
        assert!(crackles.last().unwrap().0 > 0.6 * jump, "the crackle lasts through the hold");
        let [end] = ends[..] else { panic!("slot 0 once at the end: {ends:?}") };
        assert!(end.0 >= jump && end.0 <= jump + 50.0, "slot 0 at {} ms, jump {jump} ms", end.0);
        assert!((end.2 / 0.1229 - 1.0).abs() < 0.01, "slot 0 gain {}", end.2);
        gains.extend(crackles.iter().map(|c| c.2).filter(|g| *g > 0.0));
    }
    gains.sort_by(f32::total_cmp);
    let (median, max) = (gains[gains.len() / 2], *gains.last().unwrap());
    println!("crackle peak gains: median {median:.4} (recomp 0.1870), max {max:.4} (recomp 0.2842), {} voices", gains.len());
    assert!((20.0 * (median / 0.1870).log10()).abs() < 1.5, "median {median}");
    assert!(max < 0.2842 * 1.12, "max {max}");
    // A 0.2 s hold (≤ 100 m): a few crackles, then slot 0.
    let (v, jump) = teleport_hold(12, 0).unwrap();
    let n = v.iter().filter(|x| x.1 >= 1).count();
    println!("0.2 s hold: {n} crackles, slot 0 at {:?} (jump {jump:.0} ms)", v.iter().find(|x| x.1 == 0).map(|x| x.0));
    assert!((2..=6).contains(&n) && v.iter().any(|x| x.1 == 0), "{v:?}");
    // A released hold (to 0.70 of 1.0 s, as the recomp's 433275): crackles, no slot 0.
    let (v, _, _) = teleport_hold_audio(60, 0, Some(42)).unwrap();
    println!("released at 0.70: {} crackles, slot 0: {}", v.iter().filter(|x| x.1 >= 1).count(), v.iter().any(|x| x.1 == 0));
    assert!(v.iter().any(|x| x.1 >= 1) && !v.iter().any(|x| x.1 == 0), "{v:?}");
}

/// Diagnostic (`--nocapture`): the teleport static for 0.2 s / 0.638 s / 1.0 s holds.
#[test]
#[ignore = "diagnostic"]
fn teleport_static_by_hold() {
    for (ticks, seed) in [(12usize, 0usize), (38, 0), (60, 0), (60, 7), (60, 23)] {
        let Some((v, jump)) = teleport_hold(ticks, seed) else { panic!("missing private data") };
        println!("hold {ticks} ticks (seed {seed}), jump at {jump:.0} ms: {} voices", v.len());
        if let (Ok(dir), Some((_, _, audio))) = (std::env::var("TELEPORT_STATIC_OUT"), teleport_hold_audio(ticks, seed, None)) {
            let bytes: Vec<u8> = audio.iter().flat_map(|x| x.to_le_bytes()).collect();
            std::fs::write(Path::new(&dir).join(format!("hold{ticks}_seed{seed}.f32")), bytes).unwrap();
        }
        for (ms, slot, gain) in v {
            println!("  {ms:7.1} slot {slot:2} peak {gain:.4}");
        }
    }
}

/// Diagnostic (ignored; `--nocapture`): which packet word starts Treatments slots 16 / 17. The
/// fixture's air words are varied one at a time over the same two 0.6 s airs. (Written when 16 / 17
/// seemed absent from the recomp; they are not — their samples equal sense_of_speed 3 / 4.)
#[test]
#[ignore = "diagnostic"]
fn treatment_slots_16_17_by_word() {
    let base = |f: usize| trick_state(f % 200, 0, 28, 13, 36, [0.0, 0.0, 25.0]);
    let profiles: Vec<(&str, Box<dyn Fn(usize) -> AudioState>)> = vec![
        ("fixture", Box::new(base)),
        ("w9 height 0", Box::new(move |f| AudioState { jump_height: 0.0, ..base(f) })),
        ("w7 air time 0", Box::new(move |f| AudioState { air_time: 0.0, ..base(f) })),
        ("w8 to landing 0", Box::new(move |f| AudioState { air_until_landing: 0.0, ..base(f) })),
        ("w8 10 s on the ground", Box::new(move |f| {
            let s = base(f);
            AudioState { air_until_landing: if s.airborne { s.air_until_landing } else { 10.0 }, ..s }
        })),
        ("w8 4 s on the first air frame", Box::new(move |f| {
            let s = base(f);
            let first = s.airborne && s.air_time < 0.02;
            AudioState { air_until_landing: if first { 4.0 } else { s.air_until_landing }, ..s }
        })),
        ("w8 delayed 1 frame", Box::new(move |f| {
            let s = base(f);
            let prev = base(f.saturating_sub(1));
            AudioState { air_until_landing: if prev.airborne { s.air_until_landing } else { 0.0 }, ..s }
        })),
    ];
    for (name, p) in profiles {
        let Some((starts, _)) = run_treatment_with(TreatmentGlobals::default(), p) else {
            panic!("missing private data: no Treatments bank or install");
        };
        let slots: Vec<_> = starts.iter().filter(|v| v.1 >= 15).collect();
        println!("{name:32} slots ≥ 15: {slots:?}");
    }
}

/// Diagnostic (ignored; `--nocapture`): Treatments slots 16 / 17 against a w8 step from 0 to a
/// constant (s) at frame 40, held on the ground (no air flags).
#[test]
#[ignore = "diagnostic"]
fn treatment_slots_16_17_by_w8_step() {
    for v in [0.05f32, 0.1, 0.2, 0.3, 0.37, 0.4, 0.5, 0.7, 1.0, 2.0, 5.0, 10.0] {
        let p = move |f: usize| AudioState { air_until_landing: if (40..160).contains(&f) { v } else { 0.0 }, ..AudioState::default() };
        let Some((starts, _)) = run_treatment_with(TreatmentGlobals::default(), p) else {
            panic!("missing private data: no Treatments bank or install");
        };
        println!("w8 {v:5.2} s: {:?}", starts);
    }
}

/// Diagnostic (ignored; `--nocapture`): the fixture's two airs with one Class_Treatment packet word
/// forced (post and every redelivery): which slots each word drives, with peak gains
/// (`SWEEP_WORDS`, `SWEEP_VALUES`). 13 / 14 scale with w0; w7 ≥ 1 s keeps them silent.
#[test]
#[ignore = "diagnostic"]
fn treatment_slots_16_17_by_forced_word() {
    let mut cases: Vec<(usize, i32)> = vec![(99, 0)];
    let words: Vec<usize> = std::env::var("SWEEP_WORDS").ok().map_or(vec![0, 1, 2, 3, 5, 6, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21], |s| s.split(',').map(|w| w.parse().unwrap()).collect());
    let values: Vec<i32> = std::env::var("SWEEP_VALUES").ok().map_or(vec![0, 1, 2, 8, 500, 1000, 32767], |s| s.split(',').map(|w| w.parse().unwrap()).collect());
    for &w in &words {
        for &v in &values {
            cases.push((w, v));
        }
    }
    for (word, value) in cases {
        let Some(mut rig) = Rig::new(&["Treatments"]) else { panic!("missing private data: no Treatments bank or install") };
        let (t, g) = (TreatmentTuning::default(), Globals::default());
        let mut k = Treatment::default();
        let mut starts: Vec<(usize, u16)> = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let mut peaks: HashMap<u16, f32> = HashMap::new();
        let force = |cmds: Vec<Command>| -> Vec<Command> {
            cmds.into_iter()
                .map(|c| match c {
                    Command::Post { slot, class, mut words } if word < words.len() => {
                        words[word] = value;
                        Command::Post { slot, class, words }
                    }
                    Command::Redeliver { slot, mut words } if word < words.len() => {
                        words[word] = value;
                        Command::Redeliver { slot, words }
                    }
                    c => c,
                })
                .collect()
        };
        for f in 0..400 {
            let s = trick_state(f % 200, 0, 28, 13, 36, [0.0, 0.0, 25.0]);
            rig.inputs(&s);
            let cmds = k.process(&s, &t, &g, &Owner { mixmap: &rig.mixmap, key: keys::treatments(0) });
            rig.apply(force(cmds));
            rig.mixmap.tick(s.dt);
            let cmds = k.update(&s, &TreatmentGlobals::default(), &t, &Owner { mixmap: &rig.mixmap, key: keys::treatments(0) });
            if word == 99 && f % 50 == 0 {
                if let Some(Command::Redeliver { words, .. }) = cmds.first() {
                    println!("  frame {f}: fixture words {words:?}");
                }
            }
            rig.apply(force(cmds));
            for (_, slot, id, gain) in rig.render() {
                if seen.insert(id) {
                    starts.push((f, slot));
                }
                let p = peaks.entry(slot).or_default();
                *p = p.max(gain);
            }
        }
        let has = |s: u16| starts.iter().filter(|x| x.1 == s).count();
        let pk = |s: u16| peaks.get(&s).copied().unwrap_or(0.0);
        println!("w{word:<2} = {value:5}: 13/14 {}/{} (peak {:.4}/{:.4}), 16/17 {}/{} (peak {:.4}/{:.4}), other {:?}", has(13), has(14), pk(13), pk(14), has(16), has(17), pk(16), pk(17),
            starts.iter().filter(|x| ![13, 14, 16, 17].contains(&x.1)).collect::<Vec<_>>());
    }
}

/// One `TREAT` row of a recomp session (hook on `sub_824DD6F0`, after the call): ms, `+236`,
/// `+240`, `+260`, `+224`, `+332`, `+200`.
#[derive(Clone, Copy, Debug)]
struct TreatRow {
    ms: f64,
    air_time: f32,
    to_land: f32,
    height: f32,
    g224: bool,
    air: bool,
}

/// The `TREAT` rows of one object of a recomp session (`TREAT_SESSION`, default the TREAT
/// session `$SKATE_RECOMP_SESSIONS/all_20261002_223306`; `TREAT_OBJECT`, default the local player's object there).
fn treat_rows() -> Option<Vec<TreatRow>> {
    let session = private_data::recomp_session("TREAT_SESSION", "all_20261002_223306")?;
    let object = std::env::var("TREAT_OBJECT").unwrap_or_else(|_| "40C581A0".into());
    let text = std::fs::read_to_string(session.join("trace.tsv")).ok()?;
    let rows: Vec<TreatRow> = text
        .lines()
        .filter(|l| l.starts_with("TREAT\t"))
        .map(|l| l.split('\t').collect::<Vec<_>>())
        .filter(|f| f.len() >= 10 && f[8] == object)
        .map(|f| TreatRow {
            ms: f[1].parse().unwrap(),
            air_time: f[2].parse().unwrap(),
            to_land: f[3].parse().unwrap(),
            height: f[4].parse().unwrap(),
            g224: f[5] != "0",
            air: f[6] != "0",
        })
        .collect();
    (!rows.is_empty()).then_some(rows)
}

/// The recomp's air spans (first and last air row ms) of [`treat_rows`].
fn treat_airs(rows: &[TreatRow]) -> Vec<(f64, f64)> {
    let mut airs = Vec::new();
    let mut start = None;
    for (i, r) in rows.iter().enumerate() {
        match (r.air, start) {
            (true, None) => start = Some(r.ms),
            (false, Some(s)) => {
                airs.push((s, rows[i - 1].ms));
                start = None;
            }
            _ => {}
        }
    }
    airs
}

/// One Treatments voice of a replay: start / last sounding ms on the capture's clock, slot, peak gain.
#[derive(Clone, Copy, Debug, PartialEq)]
struct ReplayVoice {
    start: f64,
    end: f64,
    slot: u16,
    peak: f32,
}

/// Replays a recomp TREAT capture through Class_Treatment on the real bank, one update per 60 Hz
/// frame from the last row at or before the frame's time (`shape` may rewrite each frame's state).
fn replay_treat(rows: &[TreatRow], shape: impl Fn(&AudioState, f64) -> AudioState) -> Option<Vec<ReplayVoice>> {
    let mut rig = Rig::new(&["Treatments"])?;
    let (t, g) = (TreatmentTuning::default(), Globals::default());
    let mut k = Treatment::default();
    let mut voices: HashMap<u32, ReplayVoice> = HashMap::new();
    let (t0, t1) = (rows[0].ms, rows[rows.len() - 1].ms);
    let mut at = 0;
    let mut f = 0usize;
    loop {
        let ms = t0 + f as f64 * 1000.0 / 60.0;
        if ms > t1 {
            break;
        }
        while at + 1 < rows.len() && rows[at + 1].ms <= ms {
            at += 1;
        }
        let r = rows[at];
        let base = AudioState {
            airborne: r.air,
            air_time: r.air_time,
            air_until_landing: r.to_land,
            jump_height: r.height,
            global_224: r.g224,
            wheel_count: if r.air { 0 } else { 4 },
            wheel_contact: [!r.air; 4],
            ..Default::default()
        };
        let s = shape(&base, ms);
        rig.inputs(&s);
        let cmds = k.process(&s, &t, &g, &Owner { mixmap: &rig.mixmap, key: keys::treatments(0) });
        rig.apply(cmds);
        rig.mixmap.tick(s.dt);
        let cmds = k.update(&s, &TreatmentGlobals::default(), &t, &Owner { mixmap: &rig.mixmap, key: keys::treatments(0) });
        rig.apply(cmds);
        for (_, slot, id, gain) in rig.render() {
            let v = voices.entry(id).or_insert(ReplayVoice { start: ms, end: ms, slot, peak: 0.0 });
            v.peak = v.peak.max(gain);
            v.end = ms;
        }
        f += 1;
    }
    let mut out: Vec<ReplayVoice> = voices.into_values().collect();
    out.sort_by(|a, b| a.start.total_cmp(&b.start).then(a.slot.cmp(&b.slot)));
    Some(out)
}

/// Diagnostic (ignored; `--nocapture`): the recomp's own Class_Treatment inputs (TREAT capture)
/// replayed through our Class_Treatment, bank and evaluator: which slots open per air, when they
/// end, and whether `+236` on the landing tick matters.
#[test]
#[ignore = "diagnostic"]
fn treatment_replays_the_recomp_capture() {
    let Some(rows) = treat_rows() else { panic!("missing private data: no TREAT session") };
    let Some(voices) = replay_treat(&rows, |s, _| s.clone()) else { panic!("missing private data: no Treatments bank") };
    let airs = treat_airs(&rows);
    for &(a, b) in &airs {
        let inside: Vec<_> = voices
            .iter()
            .filter(|v| v.start >= a - 100.0 && v.start <= b + 300.0)
            .map(|v| (v.slot, (v.start - a).round(), (v.end - a).round(), (v.peak * 1e4).round() / 1e4))
            .collect();
        println!("air {a:9.1} ({:4.0} ms): (slot, start, end, peak) {inside:?}", b - a);
    }
    let count = |s: u16| voices.iter().filter(|v| v.slot == s).count();
    println!("totals: 13 {} 14 {} 15 {} 16 {} 17 {}", count(13), count(14), count(15), count(16), count(17));
    // The engine before 2026-10-02 dropped `+236` to 0 on the landing tick (the recomp holds it
    // one tick, like `+240`): does that tick change anything?
    let Some(zeroed) = replay_treat(&rows, |s, _| AudioState { air_time: if s.airborne { s.air_time } else { 0.0 }, ..s.clone() }) else { return };
    println!("+236 zeroed on the landing tick: identical voices = {}", zeroed == voices);
}

/// Replays the TREAT rows between `from` and `to` ms row by row: each row's state is delivered
/// (process, MixMap tick, update) and then the audio up to the next row is rendered, starting the
/// render clock `phase_ms` before the first row (which moves the evaluator's 32 ms walks against
/// the rows). `stall` = a capture interval in which no audio is rendered (the recomp's audio thread
/// stopped while the game ran on: no walks, no voice starts); the audio clock then jumps to its end.
/// Returns the Treatments voices on the capture's clock.
fn replay_treat_rows(rows: &[TreatRow], from: f64, to: f64, phase_ms: f64, stall: Option<(f64, f64)>) -> Option<Vec<ReplayVoice>> {
    let mut rig = Rig::new(&["Treatments"])?;
    let (t, g) = (TreatmentTuning::default(), Globals::default());
    let mut k = Treatment::default();
    let mut voices: HashMap<u32, ReplayVoice> = HashMap::new();
    let window: Vec<TreatRow> = rows.iter().copied().filter(|r| r.ms >= from && r.ms <= to).collect();
    let deliver = |rig: &mut Rig, k: &mut Treatment, s: &AudioState| {
        rig.inputs(s);
        let cmds = k.process(s, &t, &g, &Owner { mixmap: &rig.mixmap, key: keys::treatments(0) });
        rig.apply(cmds);
        rig.mixmap.tick(s.dt);
        let cmds = k.update(s, &TreatmentGlobals::default(), &t, &Owner { mixmap: &rig.mixmap, key: keys::treatments(0) });
        rig.apply(cmds);
    };
    // The audio clock (capture ms the rendered audio has reached); 48 frames per ms.
    let mut audio = window[0].ms - 300.0 - phase_ms;
    let render_to = |rig: &mut Rig, audio: &mut f64, until: f64, voices: &mut HashMap<u32, ReplayVoice>| {
        if let Some((a, b)) = stall {
            if until > a && *audio < b {
                // Render up to the stall, then skip it.
                if *audio < a {
                    let frames = ((a - *audio) * 48.0).floor() as usize;
                    if frames > 0 {
                        rig.render_frames(frames);
                    }
                }
                *audio = (*audio).max(until.min(b));
                if until <= b {
                    return;
                }
            }
        }
        let frames = ((until - *audio) * 48.0).floor().max(0.0) as usize;
        if frames == 0 {
            return;
        }
        *audio += frames as f64 / 48.0;
        let ms = *audio;
        for (_, slot, id, gain) in rig.render_frames(frames) {
            let v = voices.entry(id).or_insert(ReplayVoice { start: ms, end: ms, slot, peak: 0.0 });
            v.peak = v.peak.max(gain);
            v.end = ms;
        }
    };
    // Settle the program on the ground for 300 ms plus the phase.
    let ground = AudioState { wheel_count: 4, wheel_contact: [true; 4], ..Default::default() };
    let mut clock = audio;
    while clock < window[0].ms {
        deliver(&mut rig, &mut k, &ground);
        clock += 1000.0 / 60.0;
        render_to(&mut rig, &mut audio, clock.min(window[0].ms), &mut voices);
    }
    for (i, r) in window.iter().enumerate() {
        let next = window.get(i + 1).map_or(r.ms + 1000.0 / 60.0, |n| n.ms);
        let s = AudioState {
            airborne: r.air,
            air_time: r.air_time,
            air_until_landing: r.to_land,
            jump_height: r.height,
            global_224: r.g224,
            wheel_count: if r.air { 0 } else { 4 },
            wheel_contact: [!r.air; 4],
            dt: ((next - r.ms) / 1000.0) as f32,
            ..Default::default()
        };
        deliver(&mut rig, &mut k, &s);
        render_to(&mut rig, &mut audio, next, &mut voices);
    }
    let mut out: Vec<ReplayVoice> = voices.into_values().collect();
    out.sort_by(|a, b| a.start.total_cmp(&b.start).then(a.slot.cmp(&b.slot)));
    Some(out)
}

/// Diagnostic (ignored; `--nocapture`): the TREAT rows of chosen airs replayed row by row (the
/// recomp's own update cadence, ~345 Hz) at every walk phase (0..32 ms in 2 ms steps): which slots
/// open, when (ms after the air's first row) and how loud. `TREAT_AIRS=a-b,…` (capture ms) picks the
/// windows; the default is the ~2 s ramp air with its 30 ms blip and the short airs. The ramp air
/// is also replayed with the recomp's audio stall (no audio lines 101499–102500 in the capture).
#[test]
#[ignore = "diagnostic"]
fn treatment_airs_by_walk_phase() {
    let Some(rows) = treat_rows() else { panic!("missing private data: no TREAT session") };
    let windows: Vec<(f64, f64, Option<(f64, f64)>)> = std::env::var("TREAT_AIRS").ok().map_or(
        vec![
            (101_400.0, 104_500.0, None),
            (101_400.0, 104_500.0, Some((101_499.1, 102_500.2))),
            (24_400.0, 25_200.0, None),
            (116_800.0, 117_600.0, None),
            (106_450.0, 107_600.0, None),
            (113_350.0, 114_300.0, None),
            (67_900.0, 68_600.0, None),
            (71_750.0, 72_500.0, None),
        ],
        |s| s.split(',').map(|w| { let (a, b) = w.split_once('-').unwrap(); (a.parse().unwrap(), b.parse().unwrap(), None) }).collect(),
    );
    for (from, to, stall) in windows {
        let first_air = rows.iter().find(|r| r.ms >= from && r.air).map_or(from, |r| r.ms);
        println!("window {from}..{to} (first air row {first_air}), audio stall {stall:?}:");
        for p in (0..32).step_by(2) {
            let Some(v) = replay_treat_rows(&rows, from, to, p as f64, stall) else { panic!("missing private data: no Treatments bank") };
            let list: Vec<_> = v.iter().map(|v| (v.slot, (v.start - first_air).round() as i64, (v.peak * 1e4).round() / 1e4)).collect();
            println!("  phase {p:2} ms: {list:?}");
        }
    }
}

/// The recomp's Treatments voices in the TREAT session all_20261002_223306 (University: plain
/// ollies, one ~2 s air off a ramp), from `retail_voices.py` with the sample-address
/// disambiguation: Treatments 16 / 17 are byte-identical to sense_of_speed 3 / 4, so they read as
/// sense_of_speed before it. Slots 13 / 14 / 15 / 16 / 17: 18 / 18 / 1 / 18 / 18 voices. In the 15
/// airs of 0.6–1.0 s, 16 and 17 each open once per air (median 87 ms after takeoff), peak gains
/// 0.0042–0.0287, median 0.0149.
const RECOMP_TREATMENT_VOICES: [(u16, usize); 5] = [(13, 18), (14, 18), (15, 1), (16, 18), (17, 18)];
const RECOMP_LONG_AIR_GAIN_MEDIAN: f32 = 0.0149;

/// The recomp's own Class_Treatment inputs (`+236` / `+240` / `+260` / `+224` / `+332` per frame,
/// TREAT capture) through our Class_Treatment, bank and evaluator give the recomp's Treatments
/// voices: 13 / 14 / 15 exactly, 16 / 17 in every 0.6–1.0 s air at the recomp's level. Data-gated
/// (the session and the Treatments bank).
#[test]
#[ignore = "needs the private install data"]
fn treatment_replay_of_the_recomp_capture() {
    let Some(rows) = treat_rows() else { panic!("missing private data: no TREAT session") };
    let Some(voices) = replay_treat(&rows, |s, _| s.clone()) else { panic!("missing private data: no Treatments bank") };
    let count = |slot: u16| voices.iter().filter(|v| v.slot == slot).count();
    for (slot, recomp) in RECOMP_TREATMENT_VOICES {
        println!("slot {slot}: {} voices (recomp {recomp})", count(slot));
    }
    for (slot, recomp) in &RECOMP_TREATMENT_VOICES[..3] {
        assert_eq!(count(*slot), *recomp, "slot {slot}");
    }
    for (slot, recomp) in &RECOMP_TREATMENT_VOICES[3..] {
        assert!(count(*slot).abs_diff(*recomp) <= 3, "slot {slot}: {} vs the recomp's {recomp}", count(*slot));
    }
    let mut gains = Vec::new();
    for (a, b) in treat_airs(&rows).into_iter().filter(|(a, b)| (600.0..=1000.0).contains(&(b - a))) {
        for slot in [16u16, 17] {
            let v: Vec<_> = voices.iter().filter(|v| v.slot == slot && v.start >= a - 100.0 && v.start <= b).collect();
            assert!(!v.is_empty(), "slot {slot} did not open in the {:.0} ms air at {a}", b - a);
            gains.extend(v.iter().map(|v| v.peak));
        }
    }
    gains.sort_by(f32::total_cmp);
    let median = gains[gains.len() / 2];
    let db = 20.0 * (median / RECOMP_LONG_AIR_GAIN_MEDIAN).log10();
    println!("16 / 17 in the 0.6-1.0 s airs: {} voices, peak gains {:.4}..{:.4}, median {median:.4} vs the recomp's {RECOMP_LONG_AIR_GAIN_MEDIAN} ({db:+.1} dB)",
        gains.len(), gains[0], gains[gains.len() - 1]);
    assert!(db.abs() < 3.0, "16 / 17 median {db:+.1} dB from the recomp");
}

/// Diagnostic (ignored; `--nocapture`): `SFXObj_SenseOfSpeed` (rattle + wind) driven by a recomp
/// session's per-update ground speed and air flag (GREC lines of the local board, `GREC_SESSION`,
/// default `$SKATE_RECOMP_SESSIONS/all_20261002_223613`; `GREC_OBJECT`, default `40C33020`), one update
/// per 60 Hz frame, through the real `sense_of_speed` bank, MixMap and evaluator. The COM speed stands in as the
/// ground speed (GREC has no COM velocity), so the wind is approximate in the air. Prints voices
/// per stream and their peak-gain quantiles, to compare with the recomp's own sense_of_speed voices
/// in the same session (a local script `sos_figures.py`, which attributes the shared samples
/// by address: Treatments 16 / 17 = sense_of_speed 3 / 4).
#[test]
#[ignore = "diagnostic"]
fn sense_of_speed_replay_of_the_recomp_speeds() {
    use skate_audio::player::components::SenseOfSpeed;
    let Some(session) = private_data::recomp_session("GREC_SESSION", "all_20261002_223613") else {
        panic!("missing private data: no GREC session (GREC_SESSION or SKATE_RECOMP_SESSIONS)")
    };
    let object = std::env::var("GREC_OBJECT").unwrap_or_else(|_| "40C33020".into());
    let Ok(text) = std::fs::read_to_string(session.join("trace.tsv")) else { panic!("missing private data: no GREC session") };
    // (ms, ground speed m/s, air)
    let rows: Vec<(f64, f32, bool)> = text
        .lines()
        .filter(|l| l.starts_with("GREC\t"))
        .map(|l| l.split('\t').collect::<Vec<_>>())
        .filter(|f| f.len() >= 7 && f[2] == object)
        .filter_map(|f| {
            let s: Vec<&str> = f[6].split_whitespace().collect();
            Some((f[1].parse().ok()?, s.get(1)?.parse().ok()?, s.get(3)? != &"0"))
        })
        .collect();
    if rows.is_empty() {
        panic!("missing private data: no GREC rows for {object}");
    }
    let Some(mut rig) = Rig::new(&["sense_of_speed"]) else { panic!("missing private data: no sense_of_speed bank") };
    let mut k = SenseOfSpeed::default();
    let mut voices: HashMap<u32, (u16, f64, f32)> = HashMap::new();
    let (t0, t1) = (rows[0].0, rows[rows.len() - 1].0);
    let (mut at, mut f) = (0usize, 0usize);
    let mut riding = 0.0f64;
    loop {
        let ms = t0 + f as f64 * 1000.0 / 60.0;
        if ms > t1 {
            break;
        }
        while at + 1 < rows.len() && rows[at + 1].0 <= ms {
            at += 1;
        }
        let (_, v, air) = rows[at];
        if v.abs() * 3.6 >= 15.0 {
            riding += 1.0 / 60.0;
        }
        let s = AudioState {
            ground_speed: v,
            com_velocity: [v, 0.0, 0.0],
            board_velocity: [v, 0.0, 0.0],
            airborne: air,
            wheel_count: if air { 0 } else { 4 },
            wheel_contact: [!air; 4],
            ..Default::default()
        };
        rig.inputs(&s);
        let cmds = k.process(&s);
        rig.apply(cmds);
        rig.mixmap.tick(s.dt);
        let cmds = k.update(&s, &Owner { mixmap: &rig.mixmap, key: keys::sense_of_speed(0) });
        rig.apply(cmds);
        for (_, slot, id, gain) in rig.render() {
            let e = voices.entry(id).or_insert((slot, ms, 0.0));
            e.2 = e.2.max(gain);
        }
        f += 1;
    }
    let q = |v: &mut Vec<f32>, p: f64| {
        v.sort_by(f32::total_cmp);
        v.get(((v.len().max(1) - 1) as f64 * p).round() as usize).copied().unwrap_or(f32::NAN)
    };
    let mut all: Vec<f32> = voices.values().map(|v| v.2).collect();
    println!("{} s at >= 15 km/h; sense_of_speed voices {}: peak gain p50 {:.4} p90 {:.4} max {:.4}", riding.round(), all.len(), q(&mut all, 0.5), q(&mut all, 0.9), q(&mut all, 1.0));
    let mut slots: Vec<u16> = voices.values().map(|v| v.0).collect();
    slots.sort();
    slots.dedup();
    for slot in slots {
        let mut g: Vec<f32> = voices.values().filter(|v| v.0 == slot).map(|v| v.2).collect();
        println!("  stream {slot:2}: {:4} voices, peak gain p50 {:.4} p90 {:.4} max {:.4}", g.len(), q(&mut g, 0.5), q(&mut g, 0.9), q(&mut g, 1.0));
    }
}
