//! Headless end-to-end render: install the projects, load banks with their decoded WAVs, post one
//! message and render through the voice graph and the output stage's stereo fold. Prints per-second
//! RMS / peak (dBFS), voice counts and the render speed; optionally writes a 48 kHz stereo WAV.
//!
//! usage: aems_render <banks dir (.abk/.csi + csi_order.txt)> <audio dir (has banks/<stem>/NNNN.wav)>
//!        <bank stem[,stem…]> <class> <w0,w1,…> <seconds> [out.wav]
//! The utility (`emitter_utility`) is always loaded and posted first, as at boot.
//! `AEMS_FLANGE="a0,…,a8;b0,…,b8"` (the vault records of the FlangeSub returns by offset, from
//! your install) enables the effect returns at the free-skate Reverb levels.
use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

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

fn db(v: f64) -> f64 {
    20.0 * v.max(1e-9).log10()
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 7 {
        eprintln!("usage: aems_render <banks dir> <audio dir> <stems> <class> <payload> <seconds> [out.wav]");
        std::process::exit(2);
    }
    let (dir, audio) = (Path::new(&a[1]), Path::new(&a[2]));
    let payload: Vec<i32> = a[5].split(',').filter(|s| !s.is_empty()).map(|s| s.parse().unwrap()).collect();
    let seconds: f64 = a[6].parse().unwrap();
    let mut rt = Runtime::new();
    for name in std::fs::read_to_string(dir.join("csi_order.txt")).unwrap().lines() {
        rt.install_project(&Project::parse(name, &std::fs::read(dir.join(name)).unwrap()).unwrap());
    }
    let mut stems: Vec<&str> = a[3].split(',').collect();
    stems.insert(0, "emitter_utility");
    for stem in stems {
        let bank = Bank::parse(stem, std::fs::read(dir.join(format!("{stem}.abk"))).unwrap()).unwrap();
        let pcm: Vec<Option<Arc<Pcm>>> = (0..bank.samples.len())
            .map(|i| std::fs::read(audio.join(format!("banks/{stem}/{i:04}.wav"))).ok().and_then(|b| wav_pcm(&b)).map(Arc::new))
            .collect();
        let found = pcm.iter().filter(|p| p.is_some()).count();
        println!("bank {stem}: {} samples, {found} with PCM", bank.samples.len());
        rt.load_bank(bank, pcm);
    }
    if let Ok(v) = std::env::var("AEMS_FLANGE") {
        use skate_audio::bus::flange::FlangePreset;
        let rec = |s: &str| {
            let v: Vec<f32> = s.split(',').map(|x| x.trim().parse().unwrap()).collect();
            FlangePreset(v.try_into().expect("9 values"))
        };
        let (a, b) = v.split_once(';').expect("a;b");
        rt.mixer.buses.flange.set_presets(rec(a), rec(b));
        rt.mixer.buses.flange.frame([32692, 2313, 32692, 2313]);
    }
    let utility = rt.eval.class_id("c_emitter_utility").unwrap();
    rt.post(utility, &[]);
    let class = rt.eval.class_id(&a[4]).expect("class");
    rt.post(class, &payload);
    let frames = (seconds * 48000.0) as usize;
    let mut out = vec![0.0f32; 2 * frames];
    let started = Instant::now();
    let mut max_voices = 0;
    for chunk in out.chunks_mut(2 * 4800) {
        rt.fill_stereo(chunk);
        max_voices = max_voices.max(rt.mixer.voice_count());
    }
    let took = started.elapsed().as_secs_f64();
    for (s, sec) in out.chunks(2 * 48000).enumerate() {
        let rms = (sec.iter().map(|v| f64::from(*v).powi(2)).sum::<f64>() / sec.len() as f64).sqrt();
        let peak = sec.iter().fold(0.0f64, |m, v| m.max(f64::from(v.abs())));
        println!("{s:>3}s rms {:>7.1} dBFS peak {:>7.1} dBFS", db(rms), db(peak));
    }
    println!(
        "rendered {seconds} s in {:.3} s ({:.0}x real time); voices max {max_voices}; opens refused {}; walks {}",
        took,
        seconds / took,
        rt.mixer.refused,
        rt.eval.walks
    );
    if let Some(path) = a.get(7) {
        let mut w = Vec::new();
        let data = (out.len() * 2) as u32;
        w.extend(b"RIFF");
        w.extend((36 + data).to_le_bytes());
        w.extend(b"WAVEfmt ");
        w.extend(16u32.to_le_bytes());
        w.extend(1u16.to_le_bytes());
        w.extend(2u16.to_le_bytes());
        w.extend(48000u32.to_le_bytes());
        w.extend((48000u32 * 4).to_le_bytes());
        w.extend(4u16.to_le_bytes());
        w.extend(16u16.to_le_bytes());
        w.extend(b"data");
        w.extend(data.to_le_bytes());
        for v in &out {
            w.extend(((v.clamp(-1.0, 1.0) * 32767.0).round() as i16).to_le_bytes());
        }
        std::fs::write(path, w).unwrap();
        println!("wrote {path}");
    }
}
