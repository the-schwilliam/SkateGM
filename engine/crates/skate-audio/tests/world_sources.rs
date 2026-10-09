//! World sound sources through the real MixMap, AEMS banks and Splice banks, headless: synthetic
//! owners (a car driving past the listener, a ped walking past and planting its feet) as a future
//! vehicle / ped system would publish them. Run with `--nocapture` for the per-0.5 s tables.
//!
//! Needs the install's MixMap and bank WAVs (`assets/private/audio`, with the world banks staged:
//! a setup run) and the extracted AEMS / SPLC banks (`SKATE_AEMS_BANKS`, `SKATE_SPLC_BANKS`; both
//! default under `SKATE_AUDIO_RE_DIR`); ignored, and fails loudly without them.
//!
//! Retail reference (recomp `all_20261002_164620`, `retail_voices.py`, GAIN × SEND per voice,
//! p50 / p90): C01_family01 0.002 / 0.049, C05_truck01 0.001 / 0.051, C04_taxi01 0.001 / 0.083,
//! fstep_livingworld 0.000 / 0.024 (4949 starts). The recomp's per-voice gains mix every distance
//! the session had; the checks here are the mechanism's (bank selection by patch, Doppler sign,
//! roll-off with distance, one step per plant), the tables are for reading against those numbers.
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::Arc;

use skate_audio::eval::NodeId;
use skate_audio::formats::{Bank, Project};
use skate_audio::mixer::Pcm;
use skate_audio::mixmap::{MixMap, keys as mkeys};
use skate_audio::player::objpos::Listener;
use skate_audio::player::tuning::PlayerTuning;
use skate_audio::runtime::Runtime;
use skate_audio::splice::{MIXER_BANK_BASE, SpliceBank};
use skate_audio::world::owners::Positions;
use skate_audio::world::peds::{PedFootstepTuning, PedSfx, PedState};
use skate_audio::world::traffic::{EngineRecord, OutputsSnapshot, Vehicle, VehicleState};
use skate_audio::world::{WorldCommand, WorldSlot, keys};

mod private_data;

const DT: f32 = 1.0 / 30.0;
/// Stereo samples per console frame at 48 kHz.
const FRAME: usize = 2 * 1600;

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

struct Harness {
    rt: Runtime,
    m: MixMap,
    names: HashMap<usize, String>,
    nodes: HashMap<(u64, WorldSlot), NodeId>,
    posts: Vec<(u64, WorldSlot, &'static str)>,
}

fn harness(aems: &[&str], splice: &[&str]) -> Option<Harness> {
    let r = root();
    let m = MixMap::from_bytes(&std::fs::read(r.join("assets/private/audio/aems/MixMapSK8.mxb")).ok()?).ok()?;
    let banks = private_data::aems_banks()?;
    let splc = private_data::splc_banks()?;
    let order = std::fs::read_to_string(banks.join("csi_order.txt")).ok()?;
    let mut rt = Runtime::new();
    for name in order.lines() {
        rt.install_project(&Project::parse(name, &std::fs::read(banks.join(name)).ok()?).ok()?);
    }
    let mut names = HashMap::new();
    for stem in std::iter::once("emitter_utility").chain(aems.iter().copied()) {
        let bank = Bank::parse(stem, std::fs::read(banks.join(format!("{stem}.abk"))).ok()?).ok()?;
        let count = bank.samples.len();
        let p = pcm(stem, count);
        if stem != "emitter_utility" && p.iter().all(Option::is_none) {
            eprintln!("skipped: {stem} has no WAVs in the install (stage the world banks)");
            return None;
        }
        let id = rt.load_bank(bank, p);
        names.insert(id, stem.to_owned());
    }
    let utility = rt.eval.class_id("c_emitter_utility")?;
    rt.post(utility, &[]);
    for stem in splice {
        let bank = SpliceBank::parse(&std::fs::read(splc.join(format!("{stem}.bnk"))).ok()?).ok()?;
        let count = bank.samples;
        let p = pcm(stem, count);
        if p.iter().all(Option::is_none) {
            return None;
        }
        let index = rt.splice.load_bank(stem, bank, p, &mut rt.mixer);
        names.insert(MIXER_BANK_BASE + index, (*stem).to_owned());
    }
    Some(Harness { rt, m, names, nodes: HashMap::new(), posts: Vec::new() })
}

impl Harness {
    fn globals(&mut self) {
        for id in 1..=4 {
            self.m.set_input(mkeys::MASTER, id, 32767);
        }
        for id in [1, 2, 5] {
            self.m.set_input(mkeys::MUSIC, id, 32767);
        }
        self.m.set_input(mkeys::REVERB, 5, 32767);
    }

    fn apply(&mut self, cmds: Vec<WorldCommand>) {
        for cmd in cmds {
            match cmd {
                WorldCommand::Post { owner, slot, class, words } => {
                    let id = self.rt.eval.class_id(class).unwrap_or_else(|| panic!("class {class} not bound"));
                    if let Some(old) = self.nodes.remove(&(owner, slot)) {
                        self.rt.release(old);
                    }
                    self.nodes.insert((owner, slot), self.rt.post(id, &words));
                    self.posts.push((owner, slot, class));
                }
                WorldCommand::Redeliver { owner, slot, words } => {
                    if let Some(&node) = self.nodes.get(&(owner, slot)) {
                        self.rt.redeliver(node, &words);
                    }
                }
                WorldCommand::Release { owner, slot } => {
                    if let Some(node) = self.nodes.remove(&(owner, slot)) {
                        self.rt.release(node);
                    }
                }
            }
        }
    }

    /// Render one console frame; return its stereo RMS and the voices per bank.
    fn render(&mut self, out: &mut [f32]) -> (f32, BTreeMap<String, (usize, f32)>) {
        self.rt.fill_stereo(out);
        let rms = (out.iter().map(|x| x * x).sum::<f32>() / out.len() as f32).sqrt();
        let mut voices: BTreeMap<String, (usize, f32)> = BTreeMap::new();
        for v in self.rt.mixer.snapshot() {
            let name = self.names.get(&v.bank).cloned().unwrap_or_else(|| format!("bank {}", v.bank));
            let e = voices.entry(name).or_default();
            e.0 += 1;
            e.1 = e.1.max(v.gain);
        }
        (rms, voices)
    }
}

fn db(x: f32) -> f32 {
    20.0 * x.max(1e-9).log10()
}

/// The listener: the camera at the origin looking down −z, the skater 3 m ahead of it.
fn listener() -> Listener {
    Listener { camera: [0.0, 1.8, 0.0], view: [0.0, 0.0, -1.0], camera_velocity: [0.0; 3], followed: [0.0, 1.0, -3.0], facing: [0.0, 0.0, -1.0], followed_velocity: [0.0; 3] }
}

const ENGINE_BANKS: [&str; 8] = ["C00_heavy01", "C01_family01", "C03_sports01", "C04_taxi01", "C05_truck01", "C06_sports02", "C07_family02", "C08_family03"];

struct Drive {
    /// Per frame: (t, x, distance to the camera, engine rpm word, engine pitch out6, front level out3, rms, voices).
    rows: Vec<(f32, f32, f32, i32, i32, i32, f32, BTreeMap<String, (usize, f32)>)>,
    posts: Vec<(u64, WorldSlot, &'static str)>,
}

/// A car of `record` drives along x at `speed` m/s, `lane` m in front of the camera, from x = −90.
fn drive(record: EngineRecord, speed: f32, lane: f32, seconds: f32) -> Option<Drive> {
    let mut banks: Vec<&str> = ENGINE_BANKS.to_vec();
    banks.extend(["Traffic_Horn", "Traffic_Skid", "car_alarms"]);
    let mut h = harness(&banks, &[])?;
    let l = listener();
    let g = 0u32;
    let owner = 1u64;
    let mut car = Vehicle::default();
    let mut pos = Positions::new(&[keys::traffic_pos(g, 1), keys::traffic_pos(g, 2), keys::traffic_pos(g, 3)]);
    let mut out = vec![0.0f32; FRAME];
    let mut rows = Vec::new();
    // No random override (the draw is ≥ 66 % for patch 1, ≥ 50 % for 3).
    let mut rng = || 99u32;
    let frames = (seconds / DT) as usize;
    for f in 0..frames {
        let t = f as f32 * DT;
        let x = -90.0 + speed * t;
        let v = VehicleState { position: [x, 0.5, -lane], velocity: [speed, 0.0, 0.0], direction: [1.0, 0.0, 0.0], speed, engine: record, ..Default::default() };
        h.globals();
        // Process (before the tick): positions, posts. All three blocks at the body (which points
        // retail binds them to is not traced).
        let p = Some((v.position, v.velocity));
        pos.write(&mut h.m, &l, &[p, p, p]);
        let cmds = car.process(owner, &v, &mut rng);
        h.apply(cmds);
        h.m.tick(DT);
        let snap = OutputsSnapshot::take(&h.m, keys::traffic_engine(g), &[7, 8]);
        let (pitch, front) = (skate_audio::player::Outputs::pitch(&snap, 6), skate_audio::player::Outputs::level(&snap, 3));
        let cmds = car.update(owner, g, &v, &mut h.m, l.camera, DT);
        let rpm = car.engine.words.map_or(0, |w| w[0]);
        h.apply(cmds);
        let (rms, voices) = h.render(&mut out);
        let d = ((x - l.camera[0]).powi(2) + (0.5f32 - l.camera[1]).powi(2) + lane * lane).sqrt();
        rows.push((t, x, d, rpm, pitch, front, rms, voices));
    }
    Some(Drive { rows, posts: h.posts })
}

fn print_drive(name: &str, d: &Drive) {
    println!("== {name}");
    println!("   t      x     dist   rpm  pitch out3     rms dBFS  voices (bank: count, max gain)");
    for r in d.rows.iter().step_by(15) {
        let voices: Vec<String> = r.7.iter().map(|(b, (n, g))| format!("{b}:{n},{g:.3}")).collect();
        println!("{:5.1} {:6.1} {:7.1} {:5} {:6} {:5} {:8.1}  {}", r.0, r.1, r.2, r.3, r.4, r.5, db(r.6), voices.join(" "));
    }
}

#[test]
#[ignore = "needs the private install data"]
fn a_car_drives_past_through_its_own_engine_bank() {
    // The `c01_family01` patch with an idle / max of the default record's order; the named
    // records' values come from the install's world tuning in game.
    let record = EngineRecord { idle_rpm: 1400.0, max_rpm: 4000.0, patch: 1, ..Default::default() };
    let Some(d) = drive(record, 12.0, 8.0, 15.0) else { panic!("missing private data: no world bank data") };
    print_drive("C01 at 12 m/s, lane 8 m", &d);
    // Bank selection: every engine voice that sounds is C01's (the other banks' programs destroy
    // their instances on the patch word).
    let engine_voices: BTreeMap<&str, usize> = d
        .rows
        .iter()
        .flat_map(|r| r.7.iter())
        .filter(|(b, _)| b.starts_with("C0"))
        .fold(BTreeMap::new(), |mut acc, (b, (n, _))| {
            *acc.entry(b.as_str()).or_insert(0) += n;
            acc
        });
    println!("engine voices by bank (voice-frames): {engine_voices:?}");
    assert!(engine_voices.get("C01_family01").copied().unwrap_or(0) > 0, "C01 never sounded");
    assert_eq!(engine_voices.len(), 1, "other engine banks sounded: {engine_voices:?}");
    assert_eq!(d.posts.iter().filter(|p| p.2 == "TRAFFIC_CAR").count(), 1);
    // Doppler on the engine pitch (out6 = B0's Doppler): above 4096 approaching, below receding.
    let near = d.rows.iter().enumerate().min_by(|a, b| a.1.2.total_cmp(&b.1.2)).unwrap().0;
    let approach = &d.rows[near - 45];
    let recede = &d.rows[near + 45];
    println!("closest at t {:.1}: pitch approaching {} receding {}", d.rows[near].0, approach.4, recede.4);
    assert!(approach.4 > 4096 && recede.4 < 4096, "Doppler: {} / {}", approach.4, recede.4);
    // Roll-off: the front layer's level is highest near the closest approach and gone beyond its
    // range (B1: 1–50 m).
    let peak = d.rows.iter().max_by_key(|r| r.5).unwrap();
    assert!((peak.0 - d.rows[near].0).abs() < 1.5, "level peaks at t {} (closest {})", peak.0, d.rows[near].0);
    assert_eq!(d.rows[0].5, 0, "out3 at 90 m");
    // RPM within [idle, max].
    assert!(d.rows.iter().skip(1).all(|r| (1400..=4000).contains(&r.3)));
}

#[test]
#[ignore = "needs the private install data"]
fn engine_banks_answer_only_their_patch() {
    // Each patch through all eight loaded banks: which bank keeps voices (retail: the eight
    // banks are loaded together and every post sounds in exactly one).
    let mut table = Vec::new();
    for patch in 0..=9 {
        let record = EngineRecord { patch, ..Default::default() };
        let Some(d) = drive(record, 8.0, 4.0, 1.0 + 90.0 / 8.0) else { panic!("missing private data: no world bank data") };
        let banks: std::collections::BTreeSet<String> = d.rows.iter().flat_map(|r| r.7.keys().filter(|b| b.starts_with("C0")).cloned()).collect();
        table.push((patch, banks));
    }
    for (p, b) in &table {
        println!("patch {p}: {b:?}");
    }
    for (p, b) in &table {
        assert!(b.len() <= 1, "patch {p} sounded in {b:?}");
        if let Some(bank) = b.iter().next() {
            assert_eq!(&bank[1..3], &format!("{p:02}"), "patch {p} → {bank}");
        }
    }
}

#[test]
#[ignore = "needs the private install data"]
fn a_ped_walks_past_and_steps_on_each_plant() {
    let Some(mut h) = harness(&["fstep_livingworld"], &["sk8_foley"]) else { panic!("missing private data: no ped bank data") };
    let l = listener();
    let tuning = PedFootstepTuning::default();
    let mut pt = PlayerTuning::default();
    pt.surface_table = vec![[0; 18]; 95];
    pt.surface_table[3][6] = 2; // concrete-like footstep surface for material 3
    let mut sfx = PedSfx::default();
    let mut pos = Positions::new(&[keys::ped_pos(0)]);
    let mut out = vec![0.0f32; FRAME];
    let mut steps_rms = Vec::new();
    let mut fstep_frames = 0;
    println!("   t      x  feet  fstep(n,g)  sk8_foley(n,g)  rms dBFS");
    for f in 0..(12.0 / DT) as usize {
        let t = f as f32 * DT;
        let x = -8.0 + 1.3 * t;
        // A step every 0.55 s, feet alternating, each planted for 0.35 s.
        let phase = t % 1.1;
        let feet = [phase < 0.35, (0.55..0.9).contains(&phase)];
        // Class 2: the `fstep_livingworld` program is silent for class 1 and plays a shoe set per
        // class 2..5 (retail's most played slots 19–21 / 51–54 are class 2's).
        let s = PedState { position: [x, 0.0, -4.0], velocity: [1.3, 0.0, 0.0], speed: 1.3, feet, materials: [3, 3], class: 2, ..Default::default() };
        h.globals();
        pos.write(&mut h.m, &l, &[Some((s.position, s.velocity))]);
        let cmds = sfx.process(9, &s, &tuning, &mut h.rt.splice_host(), DT);
        h.apply(cmds);
        h.m.tick(DT);
        let snap = OutputsSnapshot::take(&h.m, keys::ped_sfx(0), &[7, 8]);
        let cmds = sfx.update(9, &s, &tuning, &pt, &snap, &mut h.rt.splice_host(), DT);
        h.apply(cmds);
        let (rms, voices) = h.render(&mut out);
        fstep_frames += usize::from(voices.contains_key("fstep_livingworld"));
        if f % 10 == 0 {
            let fs = voices.get("fstep_livingworld").copied().unwrap_or_default();
            let sk = voices.get("sk8_foley").copied().unwrap_or_default();
            println!("{t:5.1} {x:6.1} {:?} {:2},{:.3}      {:2},{:.3}   {:7.1}", feet, fs.0, fs.1, sk.0, sk.1, db(rms));
        }
        steps_rms.push(rms);
    }
    let posts: Vec<_> = h.posts.iter().map(|p| p.2).collect();
    assert_eq!(posts, vec!["livingword_footstep", "livingword_footstep"]);
    assert!(steps_rms.iter().any(|r| *r > 1e-4), "nothing audible");
    assert!(fstep_frames > 0, "the livingword_footstep program never played");
}

/// The decoded speech takes of the dev install (`stage_world_audio.py --decode …`): an index built
/// from the folder names (`<clip stem>/<take>.wav`).
fn speech_from_install() -> Option<(skate_audio::world::speech::SpeechIndex, Vec<Vec<PathBuf>>)> {
    use skate_audio::world::speech::{Clip, SpeechIndex, Take, parse_name};
    let dir = root().join("assets/private/audio/speech/livingworld");
    let mut stems: Vec<String> = std::fs::read_dir(&dir).ok()?.filter_map(|e| e.ok()?.file_name().into_string().ok()).collect();
    stems.sort();
    let mut clips = Vec::new();
    let mut files = Vec::new();
    for stem in stems {
        let Some((event, voice, voice_name, line)) = parse_name(&stem) else { continue };
        let mut takes: Vec<PathBuf> = std::fs::read_dir(dir.join(&stem)).ok()?.filter_map(|e| Some(e.ok()?.path())).filter(|p| p.extension().is_some_and(|x| x == "wav")).collect();
        takes.sort();
        let info = takes.iter().map(|_| Take { offset: 0, size: 0, rate: 36000, samples: 0 }).collect();
        clips.push(Clip { name: format!("{stem}.dat"), event, voice, voice_name, line, takes: info });
        files.push(takes);
    }
    (!clips.is_empty()).then(|| (SpeechIndex::new(clips), files))
}

#[test]
#[ignore = "needs the private install data"]
fn a_bumped_ped_warns_with_a_line_of_its_voice() {
    use skate_audio::world::speech::{SPEECH_BANK, Want, choose, reaction_cues};
    let Some((index, files)) = speech_from_install() else { panic!("missing private data: no decoded speech (stage_world_audio.py --decode 501,104,205,101)") };
    // Which voices can say each measured reaction (the voice id comes from the ped's model).
    for want in [Want::Warn, Want::SlamReaction, Want::NearbyCollisionReaction, Want::NearbySkaterTrick] {
        for cue in reaction_cues(want) {
            let voices = index.voices_for(cue.event);
            if !voices.is_empty() {
                println!("{want:?} → {} ({:?}): {} voices {:?}", cue.event, cue.evidence, voices.len(), voices);
            }
        }
    }
    // A business man (voice 59, busm1) is bumped: warn → event 501.
    let mut last = HashMap::new();
    let mut n = 7u32;
    let mut rng = move || {
        n = n.wrapping_mul(1_103_515_245).wrapping_add(12345);
        n >> 8
    };
    let line = choose(&index, reaction_cues(Want::Warn), 59, &mut last, &mut rng).expect("busm1 has warn lines");
    let clip = &index.clips[line.clip];
    println!("busm1 warn: {} take {}", clip.name, line.take);
    assert_eq!(clip.event, 501);
    assert_eq!(clip.voice, 59);
    // Render the take as a direct voice (unity gain: the speech manager's level mapping is open).
    let bytes = std::fs::read(&files[line.clip][line.take]).unwrap();
    let pcm = Arc::new(wav_pcm(&bytes).unwrap());
    assert_eq!(pcm.rate, 36000);
    let seconds = pcm.channels[0].len() as f32 / 36000.0;
    let mut rt = Runtime::new();
    let header = skate_audio::formats::SampleHeader { codec: 3, channels: 1, rate: 36000, frames: pcm.channels[0].len() as u32, loop_start: None };
    rt.mixer.add_bank(SPEECH_BANK, vec![Some(header)], vec![Some(pcm)]);
    let voice = rt.mixer.open_direct(SPEECH_BANK, 0, 0.0, 1.0, 1.0, Some(0.0)).expect("voice");
    let mut out = vec![0.0f32; FRAME];
    let mut frames = 0;
    let mut peak = 0.0f32;
    while rt.mixer.direct_alive(voice) && frames < 30 * 20 {
        rt.fill_stereo(&mut out);
        peak = out.iter().fold(peak, |p, x| p.max(x.abs()));
        frames += 1;
    }
    println!("take {seconds:.2} s rendered over {:.2} s, peak {:.1} dBFS", frames as f32 * DT, db(peak));
    assert!(peak > 0.01);
    assert!((frames as f32 * DT - seconds).abs() < 0.2, "{} frames for {seconds} s", frames);
}

/// The phone ring of speech value 49 (data-gated: the disc's `CellPhone_Rings.bnk`): the
/// container (`PedObjectTuning::ring_id`, 5) picks one of its records; each plays its members at
/// their delays, so a ring lasts the record's latest member end (delay + length). The recomp's two
/// rings (session 164620) were answered (the `4402_*_HelCel` line's read) 1.00 s and 1.19 s after
/// the ring's start: inside the records' range.
#[test]
#[ignore = "needs the private disc banks"]
fn the_phone_ring_lasts_until_the_recomp_answers() {
    let Some(dir) = private_data::splc_banks() else { panic!("missing private data: no SPLC banks") };
    let t = skate_audio::world::peds::PedObjectTuning::default();
    let Ok(bytes) = std::fs::read(dir.join(format!("{}.bnk", t.ring_bank))) else { panic!("missing private data: no {}.bnk", t.ring_bank) };
    let bank = SpliceBank::parse(&bytes).unwrap();
    let id = t.ring_id as usize;
    let records: Vec<usize> = if id < bank.records.len() { vec![id] } else { bank.containers[id - bank.records.len()].ids.iter().map(|&r| usize::from(r)).collect() };
    let ends: Vec<f32> = records
        .iter()
        .map(|&r| bank.records[r].groups.iter().flat_map(|g| g.members.iter()).map(|m| m.delay + m.length).fold(0.0f32, f32::max))
        .collect();
    let (lo, hi) = (ends.iter().copied().fold(f32::MAX, f32::min), ends.iter().copied().fold(0.0f32, f32::max));
    eprintln!("ring container {id}: records {records:?}, ends {ends:?} s");
    for answered in [1.00f32, 1.19] {
        assert!(lo - 0.1 <= answered && answered <= hi + 0.15, "answer at {answered} s outside the rings' {lo:.2}..{hi:.2} s");
    }
}
