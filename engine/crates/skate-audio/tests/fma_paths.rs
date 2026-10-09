//! The hardware-FMA and the plain copies of the DSP loops (`skate-audio-fma`, doc 11 "Hardware FMA
//! dispatch") through the whole runtime: the same scene rendered block by block on each path, the
//! master output and the voice counts compared.
//! - A finite scene (AEMS voices on every bus with moving filters and azimuths, the eEQChain buses,
//!   the FlangeSub returns, the env reverb, a grain truck with its FSS chain): every output bit
//!   identical.
//! - NaN scenes (a NaN / −NaN-with-payload / ∞ / denormal in a voice's PCM; a NaN eEQChain gain,
//!   which makes NaN biquad coefficients): NaNs in the same places, every non-NaN bit identical, the
//!   same voices. Only a NaN's sign / payload may differ (counted and printed).
//!
//! One test in its own binary: it switches the process-wide path, which no other test may see.
use std::sync::Arc;

use skate_audio::bus::env::{DEFAULT_PRESET, Preset};
use skate_audio::bus::flange::FlangePreset;
use skate_audio::dsp::{FmaPath, force_fma};
use skate_audio::eval::{OpenRequest, VoiceHost};
use skate_audio::formats::SampleHeader;
use skate_audio::grain::player::{GrainParams, GrainSource, Record};
use skate_audio::mixer::Pcm;
use skate_audio::runtime::Runtime;

fn reverb01() -> Preset {
    Preset([
        4000.0, 600.0, 1.0, 0.08, 0.0, 1.5, 70.0, 1.0, 0.7, 4000.0, 500.0, 1.0, 1.0, 0.25, 1.0, 1.0, 3.0, 0.1, 0.34, 1.0, 1161.0, 0.5,
        0.2, 0.6, 1.0, 1.0, 270.0, 5000.0, 0.5, 0.45, 500.0, 0.75, 0.3, 0.3, 1.0, 1.0, 90.0, 5000.0, 0.51, 0.5, 500.0, 0.75, 0.28, 0.25,
    ])
}

#[derive(Clone, Copy, PartialEq)]
enum Poison {
    None,
    Pcm,
    EqGain,
}

fn scene(poison: Poison) -> (Runtime, Vec<u32>) {
    let mut rt = Runtime::new();
    let frames = 44_100 * 4;
    let wave: Vec<f32> = (0..frames).map(|i| (i as f32 * 0.03).sin() * 0.3).collect();
    let mut odd = wave.clone();
    if poison == Poison::Pcm {
        for (at, v) in [(30_000, f32::NAN), (60_000, f32::from_bits(0xFFC1_2345)), (90_000, f32::INFINITY), (120_000, 1e-40), (150_000, -0.0)] {
            odd[at] = v;
        }
    }
    let mono = Arc::new(Pcm { rate: 44_100, channels: vec![wave.clone()] });
    let stereo = Arc::new(Pcm { rate: 44_100, channels: vec![odd, wave.clone()] });
    let header = |channels| SampleHeader { codec: 3, channels, rate: 44_100, frames: frames as u32, loop_start: Some(0) };
    rt.mixer.add_bank(0, vec![Some(header(1)), Some(header(2))], vec![Some(mono), Some(stereo)]);
    rt.mixer.buses.env.presets.insert(DEFAULT_PRESET, reverb01());
    rt.mixer.buses.env.request(DEFAULT_PRESET);
    rt.mixer.buses.flange.set_presets(
        FlangePreset([20.0, 0.3, 0.2, 0.1, 1500.0, 0.002, 0.5, 0.9, 0.03]),
        FlangePreset([1.7, 0.3, 0.0, 1.0, 250.0, 0.0005, 0.25, 0.6, 0.11]),
    );
    rt.mixer.buses.flange.frame([32692, 2313, 32692, 2313]);
    // The eEQChain PI20 pairs set directly (no vault records here): both filters run on every bus.
    // A NaN gain on bus 3 makes NaN coefficients (√max(NaN, 0) = 0 → α/A = ∞ → a2 = NaN).
    for (k, bus) in rt.mixer.buses.eq.buses.iter_mut().enumerate() {
        bus.eq[0].freq = 5000.0 - 400.0 * k as f32;
        bus.eq[0].gain = if poison == Poison::EqGain && k == 3 { f32::NAN } else { 1.5 };
        bus.eq[0].q = 2.0;
        bus.eq[1].freq = 2000.0;
        bus.eq[1].gain = 0.8;
        bus.eq[1].q = 3.0;
    }
    let routes: Vec<[(u8, i32); 4]> = (0..8).map(|b| [(9u8, b), (10, 4096), (11, 1), (12, 1638)]).collect();
    let ids = (0..24)
        .filter_map(|k| {
            rt.mixer.open(&OpenRequest { bank: 0, slot: (k % 2) as u16, level: 100, azimuth: [224, 32, 0, 0, 0, 0], stream_offset: u32::MAX, inputs: &routes[k % 8] })
        })
        .collect();
    let source = Arc::new(GrainSource { name: "t".into(), duration: 4.0, pcm: Arc::new(Pcm { rate: 44_100, channels: vec![wave] }) });
    let a = GrainParams { attack: 0.1, sustain: 0.2, release: 0.1, window: 1.6, drift: 0.05 };
    let b = GrainParams { attack: 0.2, sustain: 0.1, release: 0.2, window: 1.5, drift: 0.05 };
    rt.grains.bind_truck(0, source, [a, b], [Record { gain: 0.5, pitch: 1.0, position: 0.3 }, Record { gain: 0.25, pitch: 1.0, position: 0.2 }]);
    (rt, ids)
}

fn drive(rt: &mut Runtime, ids: &[u32], block: usize) {
    if block.is_multiple_of(6) {
        for (k, &v) in ids.iter().enumerate() {
            rt.mixer.set_azimuth(v, ((block * 37 + k * 911) % 65536) as i32);
            rt.mixer.set(v, 6, 2000 + ((block + k * 13) % 20000) as i32);
            rt.mixer.set(v, 7, 77);
            rt.mixer.set(v, 2, 20000);
            rt.mixer.set(v, 5, 3000);
            rt.mixer.set(v, 0, 4096 + ((block + k) % 400) as i32);
        }
    }
}

/// Renders `blocks` blocks of the scene on each path; returns (NaN samples, NaN samples whose bits
/// differ). Asserts NaN positions, every non-NaN bit and the voice counts equal.
fn compare(poison: Poison, fma: FmaPath, blocks: usize) -> (usize, usize) {
    let (mut a, ids_a) = scene(poison);
    let (mut b, ids_b) = scene(poison);
    assert_eq!(ids_a, ids_b);
    let (mut nans, mut payloads) = (0, 0);
    for block in 0..blocks {
        drive(&mut a, &ids_a, block);
        drive(&mut b, &ids_b, block);
        force_fma(FmaPath::PLAIN);
        let out_a = *a.render_block();
        force_fma(fma);
        let out_b = *b.render_block();
        for (ch, (ca, cb)) in out_a.iter().zip(&out_b).enumerate() {
            for (n, (x, y)) in ca.iter().zip(cb).enumerate() {
                assert_eq!(x.is_nan(), y.is_nan(), "block {block} ch {ch} sample {n}: {x} vs {y}");
                if x.is_nan() {
                    nans += 1;
                    payloads += usize::from(x.to_bits() != y.to_bits());
                } else {
                    assert_eq!(x.to_bits(), y.to_bits(), "block {block} ch {ch} sample {n}: {x:e} vs {y:e}");
                }
            }
        }
        assert_eq!(a.mixer.voice_count(), b.mixer.voice_count(), "block {block}");
    }
    (nans, payloads)
}

#[test]
fn both_paths_render_the_same_scene() {
    let Some(fma) = FmaPath::fma() else {
        eprintln!("this CPU has no FMA: only the plain copy exists, comparison skipped");
        return;
    };
    let (nans, _) = compare(Poison::None, fma, 1500);
    assert_eq!(nans, 0, "the finite scene stays finite: every bit compared exactly");
    for poison in [Poison::Pcm, Poison::EqGain] {
        let (nans, payloads) = compare(poison, fma, 1500);
        assert!(nans > 0, "the poison reached the output");
        eprintln!("NaN scene: {nans} NaN output samples, {payloads} with a different sign / payload; all else bit-identical");
    }
    force_fma(skate_audio::dsp::init_fma().path);
}
