//! Which Seams_Bank samples the Class_Seams program opens for a given sequence of the trigger word
//! w7 as the held packet carries it, one value per 256-frame block (5.33 ms; the evaluator walks
//! every 6 blocks and sees the latest value). Real runtime with the decoded samples, so voice
//! lifetimes are the samples' own. Headless.
//!
//! usage: seam_pulse_probe <banks dir> <audio dir> <w0,w1,…,w19> <w7 per block, e.g. 2,0,0> [seconds]
//!        seam_pulse_probe <banks dir> <audio dir> <words> model:<calls per 60 Hz step>:<hit p>:<double p> [seconds]
//! The model form simulates the host: the physics state steps at 60 Hz, the component's process
//! runs `calls` times per step (1 = our 60 Hz host; the recomp ~5), a step has a hit with
//! probability p (on its first call only), a hit fires twice (both axes: w7 toggles back) with
//! probability q, and every call clears w7 first; each block sees the latest call's value.
//! The banks dir is `tools/audio-file-inspect/bank_layout_check.py --extract`'s; the audio dir holds
//! `banks/<stem>/NNNN.wav` (the install's `assets/private/audio`). Boots `c_emitter_utility` and
//! `Common.abk`'s `Start_up_Play_ctl` (the seams' sample shuffle) first. Prints voice starts per
//! second and by eight-sample block.
use std::collections::{BTreeMap, HashSet};
use std::path::Path;
use std::sync::Arc;

use skate_audio::formats::{Bank, Project};
use skate_audio::mixer::Pcm;
use skate_audio::runtime::Runtime;

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

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (dir, audio) = (Path::new(&a[1]), Path::new(&a[2]));
    let mut w: Vec<i32> = a[3].split(',').map(|s| s.trim().parse().unwrap()).collect();
    let seq: Vec<i32> = if a[4].starts_with("model:") { Vec::new() } else { a[4].split(',').map(|s| s.trim().parse().unwrap()).collect() };
    let seconds: f64 = a.get(5).map_or(10.0, |v| v.parse().unwrap());
    let mut rt = Runtime::new();
    for name in std::fs::read_to_string(dir.join("csi_order.txt")).expect("csi_order.txt").lines() {
        rt.install_project(&Project::parse(name, &std::fs::read(dir.join(name)).unwrap()).unwrap());
    }
    let mut seams = 0;
    for stem in ["emitter_utility", "Seams_Bank", "Common"] {
        let bank = Bank::parse(stem, std::fs::read(dir.join(format!("{stem}.abk"))).unwrap()).unwrap();
        let pcm: Vec<Option<Arc<Pcm>>> = (0..bank.samples.len())
            .map(|i| std::fs::read(audio.join(format!("banks/{stem}/{i:04}.wav"))).ok().and_then(|b| wav_pcm(&b)).map(Arc::new))
            .collect();
        let id = rt.load_bank(bank, pcm);
        if stem == "Seams_Bank" {
            seams = id;
        }
    }
    rt.post(rt.eval.class_id("c_emitter_utility").unwrap(), &[]);
    rt.post(rt.eval.class_id("Start_up_Play_ctl").expect("utility"), &[]);
    let node = rt.post(rt.eval.class_id("Class_Seams").expect("class"), &w);
    let blocks = (seconds * 48000.0 / 256.0) as usize;
    // model:<calls>:<p>:<q> → the per-block sequence from the host model (fixed-seed LCG).
    let seq: Vec<i32> = match a[4].strip_prefix("model:") {
        None => seq,
        Some(m) => {
            let f: Vec<f64> = m.split(':').map(|x| x.parse().unwrap()).collect();
            let (calls, p, q) = (f[0], f[1], f[2]);
            let mut rng = 0x2545_F491_4F6C_DD1Du64;
            let mut next = || {
                rng = rng.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                (rng >> 11) as f64 / (1u64 << 53) as f64
            };
            let (step, call) = (1.0 / 60.0, 1.0 / 60.0 / calls);
            let mut toggle = true;
            let (mut t_call, mut value) = (0.0f64, 0);
            let mut out = Vec::with_capacity(blocks);
            for b in 0..blocks {
                let t = b as f64 * 256.0 / 48000.0;
                while t_call <= t {
                    let first = (t_call / step).fract() < call / step * 0.5 || (t_call / step).fract() > 1.0 - 1e-9;
                    value = 0;
                    if first && next() < p {
                        let fires = if next() < q { 2 } else { 1 };
                        for _ in 0..fires {
                            value = if toggle { 1 } else { 2 };
                            toggle = !toggle;
                        }
                    }
                    t_call += call;
                }
                out.push(value);
            }
            out
        }
    };
    let mut seen = HashSet::new();
    let mut by_block: BTreeMap<u16, u32> = BTreeMap::new();
    let mut pulses = 0;
    let mut prev = 0;
    for b in 0..blocks {
        let v = seq[b % seq.len()];
        pulses += usize::from(v != 0 && v != prev);
        prev = v;
        w[7] = v;
        rt.redeliver(node, &w);
        rt.render_block();
        for vi in rt.mixer.snapshot() {
            if vi.bank == seams && seen.insert(vi.id) {
                *by_block.entry(vi.slot / 8 * 8).or_default() += 1;
            }
        }
    }
    let n: u32 = by_block.values().sum();
    let base: u32 = by_block.iter().filter(|(k, _)| **k < 48).map(|(_, v)| v).sum();
    println!(
        "{seconds} s: {:.1} pulses/s (value changes to non-zero), {:.1} voices/s, base share {:.0}%, by block {by_block:?}",
        pulses as f64 / seconds,
        f64::from(n) / seconds,
        100.0 * f64::from(base) / f64::from(n.max(1))
    );
}
