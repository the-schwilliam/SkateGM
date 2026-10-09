//! Headless world-emitter scene: load several banks, post one `c_emitter` payload per emitter (as
//! `game_audio/emitters.rs` does), redeliver them every 60 Hz frame and log every voice's life
//! (open, end) with its bank, slot, gain and pitch, plus per-second RMS and the most voices per
//! bank that sounded at once. For listening reports like "doubling or restarting".
//!
//! usage: emitter_scene_probe <banks dir> <audio dir> <stem[,stem…]> <seconds> <payload>[;<payload>…]
//! A payload is `w0,w1,…,w8`; `@T` after it (`…,347@12.5`) releases that post at T seconds and
//! `+T` posts it only from T seconds (a re-entry). The utility is loaded and posted first.
use std::collections::HashMap;
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

struct Post {
    words: Vec<i32>,
    from: f64,
    until: f64,
    node: Option<skate_audio::eval::NodeId>,
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 6 {
        eprintln!("usage: emitter_scene_probe <banks dir> <audio dir> <stems> <seconds> <payload>[;…]");
        std::process::exit(2);
    }
    let (dir, audio) = (Path::new(&a[1]), Path::new(&a[2]));
    let seconds: f64 = a[4].parse().unwrap();
    let mut posts: Vec<Post> = a[5]
        .split(';')
        .map(|p| {
            let (mut words, mut from, mut until) = (p.to_string(), 0.0, f64::INFINITY);
            if let Some((w, t)) = words.clone().split_once('@') {
                until = t.parse().unwrap();
                words = w.to_string();
            }
            if let Some((w, t)) = words.clone().split_once('+') {
                from = t.parse().unwrap();
                words = w.to_string();
            }
            Post { words: words.split(',').map(|s| s.trim().parse().unwrap()).collect(), from, until, node: None }
        })
        .collect();
    let mut rt = Runtime::new();
    for name in std::fs::read_to_string(dir.join("csi_order.txt")).unwrap().lines() {
        rt.install_project(&Project::parse(name, &std::fs::read(dir.join(name)).unwrap()).unwrap());
    }
    let mut names: HashMap<usize, String> = HashMap::new();
    let mut stems: Vec<&str> = a[3].split(',').collect();
    stems.insert(0, "emitter_utility");
    for stem in stems {
        let bank = Bank::parse(stem, std::fs::read(dir.join(format!("{stem}.abk"))).unwrap()).unwrap();
        let pcm: Vec<Option<Arc<Pcm>>> = (0..bank.samples.len())
            .map(|i| std::fs::read(audio.join(format!("banks/{stem}/{i:04}.wav"))).ok().and_then(|b| wav_pcm(&b)).map(Arc::new))
            .collect();
        // The op-8 shuffle bags as authored (template): range, avoid flag, min, number set.
        let bytes = std::fs::read(dir.join(format!("{stem}.abk"))).unwrap();
        for (mi, m) in bank.modules.iter().enumerate() {
            let t = m.template(&bytes);
            for op in m.program.iter().filter(|op| op.opcode == 8) {
                let b = op.block as usize;
                let wide = t[b + 2] != 1;
                let range = u16::from_be_bytes([t[b + 10], t[b + 11]]) as usize;
                let set: Vec<u16> = (0..range)
                    .map(|k| if wide { u16::from_be_bytes([t[b + 16 + 2 * k], t[b + 17 + 2 * k]]) } else { u16::from(t[b + 16 + k]) })
                    .collect();
                println!(
                    "{stem} module {mi} shuffle @{b}: range {range}, avoid {}, min {}, index {}, set {set:?}",
                    t[b + 3] as i8,
                    i32::from_be_bytes(t[b + 4..b + 8].try_into().unwrap()),
                    u16::from_be_bytes([t[b + 8], t[b + 9]])
                );
            }
        }
        for (i, (_, h)) in bank.samples.iter().enumerate() {
            if let Some(h) = h {
                let seam = pcm[i].as_ref().zip(h.loop_start).map(|(p, l)| {
                    let c = &p.channels[0];
                    (c.last().copied().unwrap_or(0.0), c.get(l as usize).copied().unwrap_or(0.0))
                });
                println!("{stem} slot {i}: {} frames @ {} Hz, loop {:?}, wrap (last, loop start) {seam:?}", h.frames, h.rate, h.loop_start);
            }
        }
        let id = rt.load_bank(bank, pcm);
        names.insert(id, stem.to_string());
    }
    let utility = rt.eval.class_id("c_emitter_utility").unwrap();
    rt.post(utility, &[]);
    let class = rt.eval.class_id("c_emitter").expect("c_emitter");
    if std::env::var("PROBE_SHUFFLES").is_ok_and(|v| v == "1") {
        rt.eval.trace = Some(Vec::new());
    }
    let mut shuffles: HashMap<(u32, u32), i32> = HashMap::new();

    let block_s = skate_audio::BLOCK as f64 / 48000.0;
    let blocks = (seconds / block_s) as usize;
    let mut stereo = vec![0.0f32; 2 * skate_audio::BLOCK];
    let mut live: HashMap<u32, (f64, String, u16, f32, f32)> = HashMap::new();
    let mut most: HashMap<String, usize> = HashMap::new();
    let mut sec_sum = 0.0f64;
    let mut sec_n = 0usize;
    let mut next_frame = 0.0f64;
    for b in 0..blocks {
        let t = b as f64 * block_s;
        if t >= next_frame {
            next_frame += 1.0 / 60.0;
            for p in &mut posts {
                match p.node {
                    None if t >= p.from && t < p.until => p.node = Some(rt.post(class, &p.words)),
                    Some(n) if t >= p.until => {
                        rt.release(n);
                        p.node = None;
                        p.until = f64::INFINITY;
                        p.from = f64::INFINITY;
                    }
                    Some(n) => rt.redeliver(n, &p.words),
                    None => {}
                }
            }
        }
        rt.fill_stereo(&mut stereo);
        // PROBE_SHUFFLES=1: every change of a shuffle's output (a new draw) with its walk.
        if let Some(trace) = rt.eval.trace.as_mut() {
            for e in trace.drain(..) {
                if e.opcode == 8 && names.get(&e.bank).is_some_and(|n| n != "emitter_utility") {
                    let last = shuffles.entry((e.instance, e.block)).or_insert(i32::MIN);
                    if *last != e.result {
                        println!("{t:8.3}s DRAW  walk {} instance {} shuffle @{} = {}", e.walk, e.instance, e.block, e.result);
                        *last = e.result;
                    }
                }
            }
        }
        sec_sum += stereo.iter().map(|v| f64::from(*v).powi(2)).sum::<f64>();
        sec_n += stereo.len();
        let snap = rt.mixer.snapshot();
        let mut per: HashMap<String, usize> = HashMap::new();
        for v in &snap {
            let name = names.get(&v.bank).cloned().unwrap_or_else(|| format!("bank{}", v.bank));
            *per.entry(name.clone()).or_default() += 1;
            live.entry(v.id).or_insert_with(|| {
                println!("{t:8.3}s OPEN  v{:<5} {name} slot {} gain {:.3} pitch {:.3}", v.id, v.slot, v.gain, v.pitch);
                (t, name, v.slot, v.gain, v.pitch)
            });
            if let Some(e) = live.get_mut(&v.id) {
                e.3 = v.gain;
                e.4 = v.pitch;
            }
        }
        for (k, n) in per {
            let m = most.entry(k).or_default();
            *m = (*m).max(n);
        }
        let ids: Vec<u32> = snap.iter().map(|v| v.id).collect();
        live.retain(|id, (t0, name, slot, gain, pitch)| {
            let keep = ids.contains(id);
            if !keep {
                println!("{t:8.3}s END   v{id:<5} {name} slot {slot} after {:.3} s (gain {gain:.3} pitch {pitch:.3})", t - *t0);
            }
            keep
        });
        if sec_n >= 2 * 48000 {
            println!("{:8.3}s rms {:.1} dBFS", t, 10.0 * (sec_sum / sec_n as f64).max(1e-18).log10());
            sec_sum = 0.0;
            sec_n = 0;
        }
    }
    println!("most voices at once per bank: {most:?}");
}
