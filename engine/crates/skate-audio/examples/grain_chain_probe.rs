//! The grain bus chain headless (spec `audio-specs/aems-grain-chain-spec.md` §6): the retail
//! MixMap + the bed on `concrete_rough_hard` through the runtime, a 12 s run — 30 km/h with a
//! manual (special latch) from 2 to 4 s, a ramp to 85 km/h (graph-3 send, wobble, level ramp),
//! back down to 35 km/h (the level hold) — with a push every 1.5 s.
//!
//! - `--mode old`: `chain_extras` off and the older chain values (level 1.0): must be bit-identical
//!   to the same run of the code before the full chain (`baseline` copy, same file).
//! - `--mode full` (default): the full chain with the owner state machines (`grain::chain`).
//! - `--raw out.f32`: the interleaved stereo output; prints an FNV-1a hash of the output bits and
//!   the per-block render time (p50 / p99 / max µs; real time = 5333 µs), plus per-phase RMS and
//!   the bed's spectral centroid.
//!
//! usage: cargo run --release --example grain_chain_probe -- <assets/private/audio> <MixMapSK8.mxb> [--mode old|full] [--raw out.f32]
#![allow(unexpected_cfgs)] // `--cfg baseline` builds this file against the code before the full chain.
use std::sync::Arc;
use std::time::Instant;

use skate_audio::BLOCK;
use skate_audio::dsp::routes::output_stereo;
use skate_audio::grain::board::{self, BoardInputs, PushTuning, SurfaceTuning};
use skate_audio::grain::{GrainFile, GrainParams, GrainSource};
use skate_audio::mixer::Pcm;
use skate_audio::mixmap::{MixMap, keys};
use skate_audio::runtime::Runtime;

const SPEED_SCALES: [u32; 4] = [0x46B8_507A, 0x4575_C0A3, 0x4513_7395, 0x44D2_A51E];

fn wav_mono(bytes: &[u8]) -> Pcm {
    let mut at = 12;
    let (mut rate, mut channels) = (0u32, 1usize);
    while at + 8 <= bytes.len() {
        let size = u32::from_le_bytes(bytes[at + 4..at + 8].try_into().unwrap()) as usize;
        let body = at + 8;
        if &bytes[at..at + 4] == b"fmt " {
            channels = usize::from(u16::from_le_bytes([bytes[body + 2], bytes[body + 3]]));
            rate = u32::from_le_bytes(bytes[body + 4..body + 8].try_into().unwrap());
        } else if &bytes[at..at + 4] == b"data" {
            let data = &bytes[body..(body + size).min(bytes.len())];
            let mono = data.chunks_exact(2 * channels).map(|f| f32::from(i16::from_le_bytes([f[0], f[1]])) / 32768.0).collect();
            return Pcm { rate, channels: vec![mono] };
        }
        at = body + size + (size & 1);
    }
    panic!("not a PCM16 WAV");
}

fn word(v: f32, bits: u32) -> i32 {
    (v * f32::from_bits(bits)).clamp(0.0, 32767.0) as i32
}

fn kmh_at(t: f32) -> f32 {
    if t < 4.0 {
        30.0
    } else if t < 8.0 {
        30.0 + (t - 4.0) / 4.0 * 55.0
    } else if t < 10.0 {
        85.0 - (t - 8.0) / 2.0 * 50.0
    } else {
        35.0
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let audio = std::path::Path::new(args.get(1).expect("usage: grain_chain_probe <audio dir> <mxb> [--mode old|full] [--raw out]"));
    let mxb = std::fs::read(args.get(2).expect("mxb")).expect("read mxb");
    let opt = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    let full = opt("--mode").as_deref() != Some("old");
    let header = GrainFile::parse(&std::fs::read(audio.join("grains/concrete_rough_hard.grain")).expect("grain")).expect("parse grain");
    let pcm = wav_mono(&std::fs::read(audio.join("grains/concrete_rough_hard.wav")).expect("wav"));
    let source = Arc::new(GrainSource { name: "concrete_rough_hard".into(), duration: header.duration, pcm: Arc::new(pcm) });
    let a = GrainParams { attack: 0.1, sustain: 0.2, release: 0.1, window: 1.6, drift: 0.05 };
    let b = GrainParams { attack: 0.2, sustain: 0.1, release: 0.2, window: 1.5, drift: 0.05 };
    let tuning = SurfaceTuning {
        max_kmh: 60.0,
        bezier: [0, 0x3D0D_3DCB, 0x3F69_EE58, 0x3F80_0000].map(f32::from_bits),
        params: [a, b],
        turn_cap: 0.6,
        turn_rise_step: 0.06,
        turn_fall_step: 0.06,
        special_gain: 0.65,
        special_shift_hz: 150.0,
        b_slope_gain: 2.0,
        b_slope_ramp_kmh: 10.0,
        a_shift_per_slope_hz: -100.0,
        b_base_shift_hz: -10.0,
        b_shift_per_slope_hz: 50.0,
        slope_divisors: (-10.0, 10.0),
        push: PushTuning { ramp_kmh: 45.0, scale_low: 1.4, scale_high: 1.1, shift_low_hz: -52.0, shift_high_hz: -20.0, scale_ms: [35.0, 200.0, 600.0], shift_ms: [30.0, 200.0, 600.0] },
    };
    let mut m = MixMap::from_bytes(&mxb).expect("mxb");
    let mut rt = Runtime::new();
    rt.grains.chain_extras = full;
    let mut owner = OwnerSide::default();
    let frames = 12 * 60;
    let mut out: Vec<f32> = Vec::with_capacity(2 * 48000 * 12);
    let mut stereo = vec![0.0f32; 2 * BLOCK];
    let mut times = Vec::new();
    let mut rendered = 0usize;
    let mut push = board::PushEnvelope::default();
    for f in 0..frames {
        let t = f as f32 / 60.0;
        let v = kmh_at(t) / 3.6;
        let special = (2.0..4.0).contains(&t);
        let pushed = f % 90 == 45 && v < 40.0 / 3.6;
        for id in 1..=4 {
            m.set_input(keys::MASTER, id, 32767);
        }
        for id in [1, 2, 5] {
            m.set_input(keys::MUSIC, id, 32767);
        }
        m.set_input(keys::REVERB, 5, 32767);
        let p = keys::player_physics(0);
        for (id, s) in [(0, 0), (1, 1), (7, 2), (8, 3), (14, 3)] {
            m.set_input(p, id, word(v, SPEED_SCALES[s]));
        }
        m.set_input(p, 10, (4.0 * 8191.75) as i32);
        for key in [keys::obj_pos(0), keys::obj_pos2(0)] {
            m.set_input_f32(key, keys::pos::DIST_CAMERA, 3.5);
            m.set_input(key, keys::pos::FLAGS, 1);
        }
        m.tick(1.0 / 60.0);
        let o = keys::skateboard(0);
        if pushed {
            let (scale, _) = board::push_peaks(&tuning.push, v);
            push.trigger(scale, 1.0, tuning.push.scale_ms);
        }
        push.advance(1.0 / 60.0);
        let records = board::records(&tuning, &BoardInputs {
            speed: v, speed_scale: push.value(), level_a: m.level(o, 1), level_b: m.level(o, 2), pitch: m.pitch_4096(o, 3),
            turn: 0.0, brake: 0.0, special, downhill: 0.0, seam: None,
        });
        if f == 0 {
            owner.rebuilt();
            rt.grains.bind_truck(0, source.clone(), [a, b], records);
        } else {
            rt.grains.set_records(0, records);
        }
        let chains = if full {
            owner.frame(&tuning, &m, v, special, pushed, 1.0 / 60.0)
        } else {
            let c = skate_audio::grain::ChainValues {
                highpass_hz: m.filter_hz(o, 12) as f32,
                lowpass_hz: m.filter_hz(o, 11) as f32,
                pan_degrees: m.raw(o, 0) as f32 * (360.0 / 65535.0),
                level: 1.0,
                ..Default::default()
            };
            [c; 2]
        };
        if full && [60, 180, 450, 540, 660].contains(&f) {
            let [ca, cb] = chains;
            println!(
                "t {t:5.2}s {:5.1} km/h  FSS A {:7.2} B {:7.2} Hz  g1 A {:.4} B {:.4}  g3 A {:.4} B {:.4}  send3 {:.3}  env {:.4}  flange A {:.4} B {:.4}",
                v * 3.6, ca.fss_hz, cb.fss_hz, ca.level, cb.level, ca.graph3_gain, cb.graph3_gain, ca.graph3_send, ca.env_send, ca.flange_send, cb.flange_send
            );
        }
        rt.grains.set_chains(0, chains);
        let needed = (f + 1) * 800;
        while rendered < needed {
            let start = Instant::now();
            let bus = *rt.render_block();
            times.push(start.elapsed().as_secs_f64() * 1e6);
            output_stereo(&bus, &mut stereo);
            out.extend_from_slice(&stereo);
            rendered += BLOCK;
        }
    }
    let mut hash = 0xCBF2_9CE4_8422_2325u64;
    for s in &out {
        for byte in s.to_bits().to_le_bytes() {
            hash = (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01B3);
        }
    }
    times.sort_by(f64::total_cmp);
    let q = |p: f64| times[((times.len() - 1) as f64 * p) as usize];
    println!("mode {}  blocks {}  hash {hash:016X}", if full { "full" } else { "old" }, times.len());
    println!("render µs/block: p50 {:.1}  p99 {:.1}  max {:.1}", q(0.5), q(0.99), q(1.0));
    for (name, from, to) in [("30 km/h", 0.5f32, 2.0f32), ("30 km/h manual", 2.2, 4.0), ("60-85 km/h", 6.5, 8.0), ("35 km/h after", 10.5, 12.0)] {
        let (i, j) = ((from * 48000.0) as usize * 2, (to * 48000.0) as usize * 2);
        let seg = &out[i..j.min(out.len())];
        let rms = (seg.iter().map(|s| s * s).sum::<f32>() / seg.len() as f32).sqrt();
        println!("{name:16} RMS {:7.2} dBFS  centroid {:7.0} Hz", 20.0 * rms.max(1e-9).log10(), centroid(seg));
    }
    if let Some(path) = opt("--raw") {
        let bytes: Vec<u8> = out.iter().flat_map(|s| s.to_le_bytes()).collect();
        std::fs::write(path, bytes).expect("write raw");
    }
}

/// Spectral centroid (Hz) of the left channel: mean of 4096-point DFT magnitudes (naive, Hann).
fn centroid(seg: &[f32]) -> f32 {
    let n = 4096;
    let left: Vec<f32> = seg.iter().step_by(2).copied().collect();
    let (mut num, mut den) = (0.0f64, 0.0f64);
    for start in (0..left.len().saturating_sub(n)).step_by(n * 4) {
        let w: Vec<f64> = (0..n).map(|k| left[start + k] as f64 * (0.5 - 0.5 * (std::f64::consts::TAU * k as f64 / n as f64).cos())).collect();
        for bin in (1..n / 2).step_by(4) {
            let (mut re, mut im) = (0.0, 0.0);
            let dw = std::f64::consts::TAU * bin as f64 / n as f64;
            for (k, x) in w.iter().enumerate() {
                re += x * (dw * k as f64).cos();
                im -= x * (dw * k as f64).sin();
            }
            let mag = (re * re + im * im).sqrt();
            num += mag * bin as f64 * 48000.0 / n as f64;
            den += mag;
        }
    }
    (num / den.max(1e-30)) as f32
}

/// The host side of the full chain: the owner's chain state, the push shift and the FSS values.
#[derive(Default)]
struct OwnerSide {
    #[cfg(not(baseline))]
    state: skate_audio::grain::chain::ChainState,
    #[cfg(not(baseline))]
    shift: skate_audio::grain::chain::PushShift,
    rng: Option<skate_audio::eval::rng::Rng>,
}

impl OwnerSide {
    fn rebuilt(&mut self) {
        #[cfg(not(baseline))]
        self.state.rebuilt(0);
    }

    #[allow(unused_variables)]
    fn frame(&mut self, t: &SurfaceTuning, m: &MixMap, v: f32, special: bool, pushed: bool, dt: f32) -> [skate_audio::grain::ChainValues; 2] {
        #[cfg(not(baseline))]
        {
            use skate_audio::grain::chain::{self, ChainFrame, ChainTuning};
            let rng = self.rng.get_or_insert_with(|| skate_audio::eval::rng::Rng::new(skate_audio::grain::GrainBed::SEED));
            if pushed {
                let (_, peak) = board::push_peaks(&t.push, v);
                self.shift.trigger(peak, t.push.shift_ms);
            }
            self.shift.advance(dt);
            self.state.frame(&ChainTuning::default(), v, dt, [true, false], || rng.draw());
            let o = keys::skateboard(0);
            let frame = ChainFrame {
                highpass_hz: m.filter_hz(o, 12) as f32,
                lowpass_hz: m.filter_hz(o, 11) as f32,
                pan_degrees: m.raw(o, 0) as f32 * chain::DEGREES_PER_RAW,
                env_send: m.level(o, 13) as f32 * chain::PER_LEVEL,
                flange_send: [m.level(o, 21) as f32 * chain::PER_LEVEL, m.level(o, 22) as f32 * chain::PER_LEVEL],
                fss_hz: chain::fss_shifts(t, t, special, self.shift.value(), 0.0),
            };
            self.state.values(0, &frame)
        }
        #[cfg(baseline)]
        unreachable!()
    }
}
