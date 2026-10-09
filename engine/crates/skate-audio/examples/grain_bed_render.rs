//! Whole-bed check, headless: the retail MixMap + the grain bed on `concrete_rough_hard` at
//! constant speeds, through the runtime's block clock and stereo output stage. Prints per speed:
//! grain starts per second (both players), the most voices at once, the record (gain A, position
//! A/B, pitch) and the stereo RMS / peak in dBFS — next to retail's numbers (grain-player-spec
//! §2.4: ~6 starts/s for one sounding truck; §3.4: rolling bed −22.9 dBFS in PR #4's 6-ch capture,
//! position A 0.12 at 10 km/h → 0.63 at 40 km/h). Optional `--wav out.wav` writes the 30 km/h run.
//!
//! The member's tuning is concrete_rough_hard's vault values (max 60 km/h, P1 0.0345, P2 0.9138;
//! GrainParams A 0.1/0.2/0.1/1.6/0.05, B 0.2/0.1/0.2/1.5/0.05), staged by
//! setup's `audio` group (`python setup.py`).
//!
//! usage: cargo run -p skate-audio --release --example grain_bed_render -- <assets/private/audio> <MixMapSK8.mxb> [--wav out.wav]
use std::sync::Arc;

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

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let audio = std::path::Path::new(args.get(1).expect("usage: grain_bed_render <audio dir> <mxb> [--wav out]"));
    let mxb = std::fs::read(args.get(2).expect("mxb")).expect("read mxb");
    let wav_out = args.iter().position(|a| a == "--wav").and_then(|i| args.get(i + 1));
    let header = GrainFile::parse(&std::fs::read(audio.join("grains/concrete_rough_hard.grain")).expect("grain")).expect("parse grain");
    let pcm = wav_mono(&std::fs::read(audio.join("grains/concrete_rough_hard.wav")).expect("wav"));
    assert_eq!(pcm.rate, header.stream.rate);
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
    println!("km/h  starts/s  max voices  gainA   posA    posB    pitch   RMS dBFS  peak dBFS");
    for kmh in [5.0f32, 10.0, 20.0, 30.0, 40.0] {
        let v = kmh / 3.6;
        let mut m = MixMap::from_bytes(&mxb).expect("mxb");
        let mut rt = Runtime::new();
        let seconds = 10.0f32;
        let frames = (seconds * 60.0) as usize;
        let mut stereo = vec![0.0f32; 2 * 800];
        let mut out = Vec::with_capacity(2 * 48000 * seconds as usize);
        let mut max_voices = 0;
        let mut rec = Default::default();
        for f in 0..frames {
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
            let records = board::records(&tuning, &BoardInputs {
                speed: v, speed_scale: None, level_a: m.level(o, 1), level_b: m.level(o, 2), pitch: m.pitch_4096(o, 3),
                turn: 0.0, brake: 0.0, special: false, downhill: 0.0, seam: None,
            });
            rec = records;
            if f == 0 {
                rt.grains.bind_truck(0, source.clone(), [a, b], records);
            } else {
                rt.grains.set_records(0, records);
            }
            let chain = skate_audio::grain::ChainValues {
                highpass_hz: m.filter_hz(o, 12) as f32,
                lowpass_hz: m.filter_hz(o, 11) as f32,
                pan_degrees: m.raw(o, 0) as f32 * (360.0 / 65535.0),
                level: 1.0,
                ..Default::default()
            };
            rt.grains.set_chains(0, [chain; 2]);
            rt.fill_stereo(&mut stereo);
            out.extend_from_slice(&stereo);
            max_voices = max_voices.max(rt.grains.voices());
        }
        let starts: u64 = rt.grains.trucks[0].players.iter().map(|p| p.starts).sum();
        let tail = &out[out.len() / 5..];
        let rms = (tail.iter().map(|s| s * s).sum::<f32>() / tail.len() as f32).sqrt();
        let peak = tail.iter().fold(0.0f32, |m, s| m.max(s.abs()));
        println!(
            "{kmh:4.0}  {:8.2}  {max_voices:10}  {:.4}  {:.4}  {:.4}  {:.4}  {:8.1}  {:9.1}",
            starts as f32 / seconds,
            rec[0].gain,
            rec[0].position,
            rec[1].position,
            rec[0].pitch,
            20.0 * rms.max(1e-9).log10(),
            20.0 * peak.max(1e-9).log10()
        );
        if let (Some(path), true) = (wav_out, kmh == 30.0) {
            let mut w = Vec::new();
            let data_len = (out.len() * 2) as u32;
            w.extend_from_slice(b"RIFF");
            w.extend_from_slice(&(36 + data_len).to_le_bytes());
            w.extend_from_slice(b"WAVEfmt ");
            w.extend_from_slice(&16u32.to_le_bytes());
            w.extend_from_slice(&1u16.to_le_bytes());
            w.extend_from_slice(&2u16.to_le_bytes());
            w.extend_from_slice(&48000u32.to_le_bytes());
            w.extend_from_slice(&(48000u32 * 4).to_le_bytes());
            w.extend_from_slice(&4u16.to_le_bytes());
            w.extend_from_slice(&16u16.to_le_bytes());
            w.extend_from_slice(b"data");
            w.extend_from_slice(&data_len.to_le_bytes());
            for s in &out {
                w.extend_from_slice(&((s.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes());
            }
            std::fs::write(path, w).expect("write wav");
        }
    }
}
