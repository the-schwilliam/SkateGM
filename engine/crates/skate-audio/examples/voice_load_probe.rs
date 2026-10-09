//! Render cost of the mixer under load: N looping voices (mono and stereo) with filters on and the
//! azimuth / cutoff changing every 6 blocks (an evaluator tick), as world emitters do. Prints the
//! per-block render time (p50 / p99 / max, µs; real time = 5333 µs per 256-frame block).
//! usage: cargo run -p skate-audio --release --example voice_load_probe [voices] [blocks] [fx]
//! `fx`: the FlangeSub returns enabled and every voice routed into one (A / B alternating, Send B
//! 0.05) — the cost of Send B and the returns.
use std::sync::Arc;
use std::time::Instant;

use skate_audio::BLOCK;
use skate_audio::eval::{OpenRequest, VoiceHost};
use skate_audio::formats::SampleHeader;
use skate_audio::mixer::{Mixer, Pcm};

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let n: usize = a.get(1).and_then(|v| v.parse().ok()).unwrap_or(96);
    let blocks: usize = a.get(2).and_then(|v| v.parse().ok()).unwrap_or(2000);
    let fx = a.get(3).is_some_and(|v| v == "fx");
    let frames = 44_100 * 4;
    let mono = Arc::new(Pcm { rate: 44_100, channels: vec![(0..frames).map(|i| (i as f32 * 0.03).sin() * 0.3).collect()] });
    let stereo = Arc::new(Pcm { rate: 44_100, channels: vec![mono.channels[0].clone(), mono.channels[0].clone()] });
    let header = |channels| SampleHeader { codec: 3, channels, rate: 44_100, frames: frames as u32, loop_start: Some(0) };
    let mut m = Mixer::new();
    m.max_voices = n.max(1);
    m.add_bank(0, vec![Some(header(1)), Some(header(2))], vec![Some(mono), Some(stereo)]);
    if fx {
        use skate_audio::bus::flange::FlangePreset;
        m.buses.flange.set_presets(
            FlangePreset([20.0, 0.3, 0.2, 0.1, 1500.0, 0.002, 0.5, 0.9, 0.03]),
            FlangePreset([1.7, 0.3, 0.0, 1.0, 250.0, 0.0005, 0.25, 0.6, 0.11]),
        );
        m.buses.flange.frame([32692, 2313, 32692, 2313]);
    }
    let routes = [[(9u8, 4096i32), (10, 1), (11, 1638)], [(9u8, 16384i32), (10, 1), (11, 1638)]];
    let ids: Vec<u32> = (0..n)
        .filter_map(|k| {
            let inputs: &[(u8, i32)] = if fx { &routes[k % 2] } else { &[] };
            m.open(&OpenRequest { bank: 0, slot: (k % 2) as u16, level: 100, azimuth: [224, 32, 0, 0, 0, 0], stream_offset: u32::MAX, inputs })
        })
        .collect();
    let mut bus = [[0.0f32; BLOCK]; 6];
    let mut times = Vec::with_capacity(blocks);
    for b in 0..blocks {
        if b % 6 == 0 {
            for (k, &v) in ids.iter().enumerate() {
                m.set_azimuth(v, ((b * 37 + k * 911) % 65536) as i32);
                m.set(v, 6, 2000 + ((b + k * 13) % 20000) as i32);
                m.set(v, 7, 77);
                m.set(v, 2, 20000);
                m.set(v, 0, 4096 + ((b + k) % 400) as i32);
            }
        }
        let t = Instant::now();
        m.render(&mut bus);
        times.push(t.elapsed().as_secs_f64() * 1e6);
    }
    times.sort_by(f64::total_cmp);
    let q = |p: f64| times[((times.len() - 1) as f64 * p) as usize];
    println!("{} voices: render per block p50 {:.0} us, p99 {:.0} us, max {:.0} us (real time 5333 us)", ids.len(), q(0.5), q(0.99), q(1.0));
}
