//! The off-board, clothing and hands-on-deck components through the real MixMap, AEMS banks and
//! Splice banks, headless: per scenario, the voice gains per (bank, sample) next to retail's
//! per-sample medians (recomp sessions `all_20261002_163809` / `_164620`, report levels, kept
//! locally). Needs the install's MixMap and WAVs (`assets/private/audio`), the extracted AEMS banks
//! (`SKATE_AEMS_BANKS`) and SPLC banks (`SKATE_SPLC_BANKS`; both default under `SKATE_AUDIO_RE_DIR`);
//! ignored, and fails loudly without them. Run with `--nocapture` for the table.
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::Arc;

use skate_audio::eval::NodeId;
use skate_audio::formats::{Bank, Project};
use skate_audio::mixer::Pcm;
use skate_audio::mixmap::{MixMap, keys};
use skate_audio::player::clothing::{Clothing, ClothingTuning};
use skate_audio::player::components::{Command, Slot};
use skate_audio::player::footsteps::{FootstepMaterial, FootstepTuning, Footsteps};
use skate_audio::player::objpos::{Listener, ObjPos};
use skate_audio::player::step_on::{StepOn, StepOnTuning};
use skate_audio::player::tuning::PlayerTuning;
use skate_audio::player::{AudioState, Owner, inputs};
use skate_audio::runtime::Runtime;
use skate_audio::splice::{MIXER_BANK_BASE, SpliceBank};

mod private_data;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
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

fn pcm(stem: &str, count: usize) -> Vec<Option<Arc<Pcm>>> {
    let dir = root().join("assets/private/audio/banks").join(stem);
    (0..count).map(|i| std::fs::read(dir.join(format!("{i:04}.wav"))).ok().and_then(|b| wav_pcm(&b)).map(Arc::new)).collect()
}

const AEMS: [&str; 3] = ["fstep_skateshoe1_sm", "Foley_Cloth", "Bodyslide"];
const SPLICE: [&str; 3] = ["sk8_foley", "Skate_Collisions", "Skate_Metal"];

struct Harness {
    rt: Runtime,
    mxb: Vec<u8>,
    names: HashMap<usize, String>,
}

fn harness() -> Option<Harness> {
    let r = root();
    let mxb = std::fs::read(r.join("assets/private/audio/aems/MixMapSK8.mxb")).ok()?;
    let banks = private_data::aems_banks()?;
    let splc = private_data::splc_banks()?;
    let order = std::fs::read_to_string(banks.join("csi_order.txt")).ok()?;
    let mut rt = Runtime::new();
    for name in order.lines() {
        rt.install_project(&Project::parse(name, &std::fs::read(banks.join(name)).ok()?).ok()?);
    }
    let mut names = HashMap::new();
    for stem in std::iter::once("emitter_utility").chain(AEMS) {
        let bank = Bank::parse(stem, std::fs::read(banks.join(format!("{stem}.abk"))).ok()?).ok()?;
        let count = bank.samples.len();
        let id = rt.load_bank(bank, pcm(stem, count));
        names.insert(id, stem.to_owned());
    }
    let utility = rt.eval.class_id("c_emitter_utility")?;
    rt.post(utility, &[]);
    for stem in SPLICE {
        let bank = SpliceBank::parse(&std::fs::read(splc.join(format!("{stem}.bnk"))).ok()?).ok()?;
        let count = bank.samples;
        let p = pcm(stem, count);
        if p.iter().all(Option::is_none) {
            return None;
        }
        let index = rt.splice.load_bank(stem, bank, p, &mut rt.mixer);
        names.insert(MIXER_BANK_BASE + index, stem.to_owned());
    }
    Some(Harness { rt, mxb, names })
}

#[derive(Default)]
struct Run {
    /// (bank, sample) → voice gains over the blocks it sounded.
    gains: BTreeMap<(String, u16), Vec<f32>>,
    posts: usize,
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

fn apply(rt: &mut Runtime, nodes: &mut HashMap<Slot, NodeId>, cmds: Vec<Command>, posts: &mut usize) {
    for cmd in cmds {
        match cmd {
            Command::Post { slot, class, words } => {
                let Some(id) = rt.eval.class_id(class) else { panic!("class {class} not bound") };
                if let Some(old) = nodes.remove(&slot) {
                    rt.release(old);
                }
                nodes.insert(slot, rt.post(id, &words));
                *posts += 1;
            }
            Command::Redeliver { slot, words } => {
                if let Some(&node) = nodes.get(&slot) {
                    rt.redeliver(node, &words);
                }
            }
            Command::Release { slot } => {
                if let Some(node) = nodes.remove(&slot) {
                    rt.release(node);
                }
            }
        }
    }
}

/// Footstep surface 2 (AudioSurfaceMap word 6) for material 3 (the engine's concrete tag 4),
/// surface 1 and the metal record for material 36; body slide type 2 for material 40.
fn tunings() -> (PlayerTuning, FootstepTuning, ClothingTuning, StepOnTuning) {
    let mut t = PlayerTuning::default();
    t.surface_table = vec![[0; 18]; 95];
    t.surface_table[3][6] = 2;
    t.surface_table[36][6] = 1;
    t.surface_table[40][10] = 2;
    let mut ft = FootstepTuning::default();
    ft.materials = vec![FootstepMaterial::default(); 143];
    // The vault's material 36 (Skate_Metal walk / run / landing 416, +48 6000, landing 20000).
    ft.materials[36] = FootstepMaterial { kind: 1, enabled: true, gain: 6000, landing_gain: 20000, ids: [416, 416, 416] };
    (t, ft, ClothingTuning::default(), StepOnTuning::default())
}

fn run(frames: usize, state: impl Fn(usize) -> AudioState) -> Run {
    // A fresh runtime per scenario: nothing of the last one keeps sounding.
    let mut h = harness().expect("data checked by the caller");
    let h = &mut h;
    let (t, ft, ct, st) = tunings();
    let mut m = MixMap::from_bytes(&h.mxb).unwrap();
    let mut physics = inputs::Physics::default();
    let mut positions = [ObjPos::default(), ObjPos::default()];
    let mut foot = Footsteps::default();
    let mut cloth = Clothing::default();
    let mut step = StepOn::default();
    let mut nodes = HashMap::new();
    let mut out = vec![0.0f32; 1600];
    let mut r = Run::default();
    for f in 0..frames {
        let s = state(f);
        globals(&mut m);
        physics.write(&mut m, &s);
        let l = Listener {
            camera: [s.com_position[0] - 3.5, 2.4, s.com_position[2]],
            view: [1.0, -0.3, 0.0],
            camera_velocity: s.com_velocity,
            followed: s.com_position,
            facing: s.com_velocity,
            followed_velocity: s.com_velocity,
        };
        positions[0].write(&mut m, keys::obj_pos(0), &l, Some((s.com_position, s.com_velocity)));
        positions[1].write(&mut m, keys::obj_pos2(0), &l, Some((s.board_position, s.board_velocity)));
        inputs::write_off_board(&mut m, &s);
        let mut cmds = foot.process(&s, &t, &ft, &mut h.rt.splice_host());
        cmds.extend(cloth.process(&s, &t, &ct, &mut h.rt.splice_host()));
        step.process(&s, &st, &mut h.rt.splice_host());
        apply(&mut h.rt, &mut nodes, cmds, &mut r.posts);
        m.tick(1.0 / 60.0);
        let off = Owner { mixmap: &m, key: keys::off_board(0) };
        let clothing = Owner { mixmap: &m, key: keys::clothing(0) };
        let contacts = Owner { mixmap: &m, key: keys::contacts(0) };
        let mut cmds = foot.update(&s, &t, &ft, &off, &mut h.rt.splice_host());
        cmds.extend(cloth.update(&s, &t, &ct, &clothing, &mut h.rt.splice_host()));
        step.update(&s, &st, &contacts, &mut h.rt.splice_host());
        apply(&mut h.rt, &mut nodes, cmds, &mut r.posts);
        h.rt.fill_stereo(&mut out);
        for v in h.rt.mixer.snapshot() {
            if let Some(name) = h.names.get(&v.bank) {
                if v.gain > 0.0 {
                    r.gains.entry((name.clone(), v.slot)).or_default().push(v.gain);
                }
            }
        }
    }
    r
}

fn q(v: &[f32], p: f32) -> f32 {
    let mut v = v.to_vec();
    v.sort_by(f32::total_cmp);
    if v.is_empty() { 0.0 } else { v[((v.len() - 1) as f32 * p) as usize] }
}

/// Walking: the feet alternate every `period` frames (A, then B).
fn walking(f: usize, kmh: f32, period: usize, material: u32) -> AudioState {
    let v = kmh / 3.6;
    let phase = (f / period) % 2;
    AudioState {
        on_foot: true,
        com_velocity: [v, 0.0, 0.0],
        com_position: [v * f as f32 / 60.0, 1.0, 0.0],
        board_position: [v * f as f32 / 60.0, 0.1, 0.0],
        foot_down: [phase == 0, phase == 1],
        foot_material: [material; 2],
        foot_xz_speed: if phase == 0 { [0.0, 2.0 * v] } else { [2.0 * v, 0.0] },
        foot_vertical_speed: [0.3, 0.3],
        // Retail's walking steps play the patch's w13 = 1 sets (samples 30..59, 119..167):
        // AudibleFootStepStrength below 2.
        footstep_strength: 1.5,
        ..Default::default()
    }
}

fn print(name: &str, r: &Run, banks: &[&str], retail: &str) {
    println!("--- {name} (posts {}; retail: {retail})", r.posts);
    for ((bank, slot), g) in &r.gains {
        if banks.contains(&bank.as_str()) {
            println!("  {bank:20} sample {slot:4}  blocks {:5}  gain median {:.3}  p90 {:.3}  max {:.3}", g.len(), q(g, 0.5), q(g, 0.9), q(g, 1.0));
        }
    }
}

fn bank_gains<'a>(r: &'a Run, bank: &str) -> Vec<f32> {
    r.gains.iter().filter(|((b, _), _)| b == bank).flat_map(|(_, g)| g.iter().copied()).collect()
}

#[test]
#[ignore = "needs the private install data"]
fn offboard_clothing_and_hands_play_their_retail_banks() {
    let Some(_) = harness() else { panic!("missing private data: no install MixMap / extracted banks / WAVs") };
    // Walking 5.4 km/h on concrete, board not in hand: step layer sk8_foley 82 (samples 69..75,
    // retail medians 0.21..0.26), walking foley 62 (samples 94..97, retail 0.387), the packets.
    let r = run(300, |f| walking(f, 5.4, 20, 3));
    print("walk 5.4 km/h concrete", &r, &["sk8_foley", "fstep_skateshoe1_sm"], "per-voice GAIN p50: 82 samples 69..75 0.011 0.015 0.024 0.022 0.056 0.076 0.110; 62 94..97 0.387; fstep 35..39 0.16-0.18, 50..54 0.16-0.20, 119..123 0.026-0.040, 141..145 0.062-0.073, 154..157 0.065-0.079, 163..167 0.080-0.10");
    let foley: Vec<u16> = r.gains.keys().filter(|(b, _)| b == "sk8_foley").map(|(_, s)| *s).collect();
    assert!(foley.iter().any(|s| (69..=75).contains(s)), "the step layer (82) plays: {foley:?}");
    assert!(foley.iter().any(|s| (94..=97).contains(s)), "the walking foley (62) plays: {foley:?}");
    assert!(bank_gains(&r, "sk8_foley").iter().all(|&g| g <= 1.0));
    // Walking 14.4 km/h with the board in hand: 63 (103..107, retail 0.244) and 1122 (Skate_Collisions).
    let r = run(300, |f| AudioState { offboard_308: true, ..walking(f, 14.4, 16, 3) });
    print("walk 14.4 km/h, board in hand", &r, &["sk8_foley", "Skate_Collisions"], "per-voice p50: 63 103..107 0.244; 1121-1123 Skate_Collisions 30..34 0.22-0.34, 94..100 0.169-0.190");
    assert!(!bank_gains(&r, "Skate_Collisions").is_empty(), "the board-in-hand layer plays");
    // Running 25 km/h: run mode, step 102 (72..75, retail 0.08..0.24).
    let r = run(300, |f| walking(f, 25.0, 12, 3));
    print("run 25 km/h concrete", &r, &["sk8_foley"], "per-voice p50: 72..75 0.022 0.056 0.076 0.110 (all step sets)");
    // Walking on metal (material 36): the Skate_Metal surface layer 416 at +48 6000 / 32767.
    let r = run(300, |f| walking(f, 5.4, 20, 36));
    print("walk 5.4 km/h metal 36", &r, &["Skate_Metal"], "416 at its 59 footstep starts (time-matched, 164620): p50 0.082 p90 0.281");
    assert!(!bank_gains(&r, "Skate_Metal").is_empty(), "the material's surface layer plays");
    // Pushing on the board: push stroke → 73, plant → 74 (retail 0.21..0.26), the plant's foot down.
    let r = run(300, |f| {
        let phase = f % 40;
        AudioState {
            com_velocity: [4.0, 0.0, 0.0],
            ground_speed: 4.0,
            wheel_count: 4,
            wheel_contact: [true; 4],
            push_stroke: (10..30).contains(&phase),
            push_trigger: phase == 20,
            push_planted: (20..28).contains(&phase),
            foot_down: [false, (20..28).contains(&phase)],
            foot_material: [3; 2],
            ..Default::default()
        }
    });
    print("pushing 14.4 km/h", &r, &["sk8_foley"], "per-voice p50: 73 4..7 0.176-0.260; 74 0..3 0.206-0.260");
    let foley: Vec<u16> = r.gains.keys().filter(|(b, _)| b == "sk8_foley").map(|(_, s)| *s).collect();
    assert!(foley.iter().any(|s| (0..=7).contains(s)), "the push foley plays: {foley:?}");
    // Hands on and off the deck (picking the board up on foot with it in hand): 1125 / 1126.
    let r = run(300, |f| AudioState {
        on_foot: true,
        offboard_308: true,
        hands_on_deck: [(f / 30) % 2 == 1, false],
        ..Default::default()
    });
    print("hand on / off the deck", &r, &["Skate_Collisions"], "per-voice p50: 1125 427..432 0.133-0.160; 1126 422..426 0.071-0.081");
    assert!(!bank_gains(&r, "Skate_Collisions").is_empty(), "the hand sounds play");
    // A bail sliding at 3 m/s: c_body_slide (Bodyslide, retail medians 0.001..0.035, max 0.47) and
    // c_cloth_falls (Foley_Cloth, medians ≤ 0.025, max 0.19).
    let r = run(240, |f| {
        let mut body_slide = [0.0; 6];
        let mut body_tag = [0; 6];
        if f > 10 {
            body_slide[0] = 2.0;
            body_tag[0] = 41;
        }
        AudioState {
            bail: f > 5,
            com_velocity: [3.0, 0.0, 0.0],
            body_speed: 3.0,
            limb_speed: 3.5,
            body_slide,
            body_tag,
            ..Default::default()
        }
    });
    print("bail sliding 3 m/s", &r, &["Bodyslide", "Foley_Cloth"], "per-voice p50: Bodyslide 0..4 0.000-0.035; Foley_Cloth 0..7 0.017-0.052 (pitch p50 1.81: Clothing out1 is a volume read as pitch)");
    assert!(!bank_gains(&r, "Bodyslide").is_empty(), "the body slide plays");
    assert!(bank_gains(&r, "Bodyslide").iter().chain(bank_gains(&r, "Foley_Cloth").iter()).all(|&g| g <= 1.0));
}

/// Which `fstep_skateshoe1_sm` samples the footstep patch opens per packet word (w8 toggling
/// every 20 frames, the other words as the updater writes them for a 5.4 km/h walk), to map the
/// patch's sample groups. `--ignored --nocapture`.
#[test]
#[ignore]
fn footstep_patch_sample_groups() {
    let Some(_) = harness() else { panic!("missing private data") };
    let base: Vec<i32> = vec![32767, 0, 4096, 0, 25000, 25000, 2456, 9200, 0, 2, 513, 0, 1, 2, 300, 1, 2, 1, 32767, 10000, 15000, 25000, 32767, 28000, 12];
    let variants: Vec<(&str, usize, Vec<i32>)> = vec![
        ("surface w16", 16, (1..=7).collect()),
        ("code w17", 17, (1..=5).collect()),
        ("bucket w12", 12, (1..=4).collect()),
        ("strength w13", 13, vec![1, 2, 3, 5, 10]),
        ("walk w14", 14, vec![0, 200, 400, 516]),
        ("vertical w9", 9, vec![0, 2, 5, 8]),
        ("xz w10", 10, vec![0, 300, 513]),
        ("flag w11", 11, vec![0, 1]),
    ];
    for (name, word, values) in variants {
        for v in values {
            let mut h = harness().unwrap();
            let class = h.rt.eval.class_id("playercharacter_footstep").unwrap();
            let mut w = base.clone();
            w[word] = v;
            let mut post = w.clone();
            post[8] = 0;
            let node = h.rt.post(class, &post);
            let mut out = vec![0.0f32; 1600];
            let mut seen: BTreeMap<u16, (usize, f32)> = BTreeMap::new();
            for f in 0..160 {
                w[8] = i32::from((f / 20) % 2 == 1);
                h.rt.redeliver(node, &w);
                h.rt.fill_stereo(&mut out);
                for vi in h.rt.mixer.snapshot() {
                    if h.names.get(&vi.bank).map(String::as_str) == Some("fstep_skateshoe1_sm") && vi.gain > 0.0 {
                        let e = seen.entry(vi.slot).or_insert((0, 0.0));
                        e.0 += 1;
                        e.1 = e.1.max(vi.gain);
                    }
                }
            }
            let list: Vec<String> = seen.iter().map(|(s, (n, g))| format!("{s}:{n}/{g:.3}")).collect();
            println!("{name:13} = {v:4}: {}", list.join(" "));
        }
    }
}

/// The OffBoard / Clothing / Contacts outputs the components read, on foot and on the board.
/// `--ignored --nocapture`.
#[test]
#[ignore]
fn owner_outputs_on_foot_and_on_board() {
    let Some(h) = harness() else { panic!("missing private data") };
    for (name, on_foot, kmh) in [("on foot 5.4 km/h", true, 5.4f32), ("on foot 14.4", true, 14.4), ("on board 14.4", false, 14.4), ("on board 0", false, 0.0)] {
        let mut m = MixMap::from_bytes(&h.mxb).unwrap();
        let mut physics = inputs::Physics::default();
        let mut positions = [ObjPos::default(), ObjPos::default()];
        for f in 0..120 {
            let mut s = walking(f, kmh, 20, 3);
            s.on_foot = on_foot;
            if !on_foot {
                s.ground_speed = kmh / 3.6;
                s.wheel_count = 4;
                s.wheel_contact = [true; 4];
            }
            globals(&mut m);
            physics.write(&mut m, &s);
            let l = Listener { camera: [s.com_position[0] - 3.5, 2.4, 0.0], view: [1.0, -0.3, 0.0], camera_velocity: s.com_velocity, followed: s.com_position, facing: s.com_velocity, followed_velocity: s.com_velocity };
            positions[0].write(&mut m, keys::obj_pos(0), &l, Some((s.com_position, s.com_velocity)));
            positions[1].write(&mut m, keys::obj_pos2(0), &l, Some((s.board_position, s.board_velocity)));
            inputs::write_off_board(&mut m, &s);
            m.tick(1.0 / 60.0);
        }
        let o = keys::off_board(0);
        let c = keys::clothing(0);
        let k = keys::contacts(0);
        let off: Vec<String> = (0..17).map(|i| format!("{i}:{}", m.level(o, i))).collect();
        let cl: Vec<String> = (0..8).map(|i| format!("{i}:{}", m.level(c, i))).collect();
        println!("{name:18} OffBoard {} | pitch1 {} raw0 {}", off.join(" "), m.pitch_4096(o, 1), m.raw(o, 0));
        println!("{:18} Clothing {} | pitch1 {} pitch3 {} pitch6 {} | Contacts 10:{} 11 pitch {}", "", cl.join(" "), m.pitch_4096(c, 1), m.pitch_4096(c, 3), m.pitch_4096(c, 6), m.level(k, 10), m.pitch_4096(k, 11));
    }
}
