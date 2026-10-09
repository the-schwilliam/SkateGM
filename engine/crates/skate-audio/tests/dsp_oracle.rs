//! Legacy comparisons against the PoC's replay-verified kernels (oracle vectors written by the
//! local PoC probe `dsp_vectors.rs` (local, not published) into a vectors file: `SKATE_DSP_VECTORS`,
//! else `$SKATE_AUDIO_RE_DIR/golden/dsp/vectors.txt`; ignored, and fails loudly when absent). Prints the
//! agreement numbers. These vectors come from another port, not direct TU3 instruction
//! execution. Independent native Gain vectors are checked in `retail_gain.rs`.
use std::path::PathBuf;

use skate_audio::dsp::biquad::{Coefficients, Kind, coefficients, kernel, omega};
use skate_audio::dsp::gain::ramp;
use skate_audio::dsp::resample::Resampler;

mod private_data;

fn vectors() -> Option<String> {
    let path: PathBuf = private_data::file("SKATE_DSP_VECTORS", "golden/dsp/vectors.txt")?;
    std::fs::read_to_string(path).ok()
}

/// The probe's test signal (same formula, same f32 libm).
fn signal(n: usize, seed: u32) -> Vec<f32> {
    let mut x = seed;
    (0..n)
        .map(|i| {
            x = x.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let noise = (x >> 8) as f32 / (1u32 << 24) as f32 - 0.5;
            (i as f32 * 0.130_899_7).sin() * 0.6 + noise * 0.3
        })
        .collect()
}

fn floats(words: &[&str]) -> Vec<f32> {
    words.iter().map(|w| f32::from_bits(u32::from_str_radix(w, 16).unwrap())).collect()
}

#[test]
#[ignore = "needs the private install data"]
fn resample_is_bit_exact_with_the_retail_kernel() {
    let Some(text) = vectors() else {
        panic!("missing private data: no oracle vectors");
    };
    let src = signal(16384, 7);
    let (mut cases, mut samples, mut exact) = (0, 0, 0);
    for line in text.lines().filter(|l| l.starts_with("resample ")) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        let step: u32 = parts[1].parse().unwrap();
        let want = floats(&parts[2..]);
        let mut r = Resampler::default();
        r.step = step;
        let mut got = Vec::new();
        for _ in 0..8 {
            let mut out = vec![0.0f32; 256];
            r.render(&mut out, |i| src.get(i as usize).copied().unwrap_or(0.0));
            r.advance(256);
            got.extend(out);
        }
        cases += 1;
        samples += want.len();
        exact += got.iter().zip(&want).filter(|(a, b)| a.to_bits() == b.to_bits()).count();
    }
    eprintln!("resample: {cases} steps, {exact}/{samples} samples bit-exact");
    assert!(cases > 0);
    assert_eq!(exact, samples);
}

#[test]
#[ignore = "needs the private install data"]
fn lowpass_coefficients_and_kernel_agree() {
    let Some(text) = vectors() else {
        panic!("missing private data: no oracle vectors");
    };
    let mut poc_coeffs = std::collections::HashMap::new();
    let (mut words, mut exact_words, mut max_ulps) = (0, 0, 0u32);
    for line in text.lines().filter(|l| l.starts_with("lpfcoef ")) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        let fc: f32 = parts[1].parse().unwrap();
        let c = floats(&parts[2..]);
        let want = Coefficients { a1: c[0], a2: c[1], b0: c[2], b1: c[3], b2: c[4] };
        let got = coefficients(Kind::LowPass, omega(fc, 48000.0));
        for (a, b) in [(got.a1, want.a1), (got.a2, want.a2), (got.b0, want.b0), (got.b1, want.b1), (got.b2, want.b2)] {
            words += 1;
            let ulps = (a.to_bits() as i64 - b.to_bits() as i64).unsigned_abs() as u32;
            exact_words += usize::from(ulps == 0);
            max_ulps = max_ulps.max(ulps);
        }
        poc_coeffs.insert(parts[1].to_string(), want);
    }
    eprintln!("lpf coefficients: {exact_words}/{words} words bit-exact, max {max_ulps} ulp");
    assert!(words > 0);
    assert!(max_ulps <= 1, "coefficients differ by {max_ulps} ulp");

    let input = signal(2048, 11);
    let (mut samples, mut exact, mut worst) = (0, 0, 0.0f32);
    for line in text.lines().filter(|l| l.starts_with("biquad ")) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        let want = floats(&parts[2..]);
        let k = poc_coeffs[parts[1]];
        let mut history = [0.0f32; 4];
        let mut got = input.clone();
        for block in got.chunks_mut(256) {
            kernel(&k, &mut history, block);
        }
        let peak = want.iter().fold(0.0f32, |m, v| m.max(v.abs())).max(1e-9);
        let (mut case_exact, mut case_worst, mut first) = (0, 0.0f32, None);
        for (i, (a, b)) in got.iter().zip(&want).enumerate() {
            samples += 1;
            case_exact += usize::from(a.to_bits() == b.to_bits());
            if a.to_bits() != b.to_bits() && first.is_none() {
                first = Some(i);
            }
            case_worst = case_worst.max((a - b).abs() / peak);
        }
        eprintln!("  biquad {} Hz: {case_exact}/{} bit-exact, first diff at {first:?}, max {case_worst:.3e} of peak", parts[1], want.len());
        exact += case_exact;
        worst = worst.max(case_worst);
    }
    eprintln!("biquad kernel: {exact}/{samples} samples bit-exact, max error {worst:.3e} of peak");
    assert_eq!(exact, samples, "biquad not bit-exact (max error {worst} of peak)");
}

/// Fit the feed-forward association per sample position (n mod 8) against the oracle, black box:
/// each sample is computed from the oracle's own previous outputs (teacher forcing), and every
/// candidate order of the fused multiply-adds is scored. `cargo test … fit_biquad -- --ignored
/// --nocapture`. Its result is what `biquad::kernel` implements.
#[test]
#[ignore]
fn fit_biquad_association() {
    let Some(text) = vectors() else { return };
    let input = signal(2048, 11);
    let mut coeffs = std::collections::HashMap::new();
    for line in text.lines().filter(|l| l.starts_with("lpfcoef ")) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        let c = floats(&parts[2..]);
        coeffs.insert(parts[1].to_string(), Coefficients { a1: c[0], a2: c[1], b0: c[2], b1: c[3], b2: c[4] });
    }
    // Feed-forward candidates: (order of the three products, bias placement).
    // bias 0: innermost addend; 1: plain add after the sum; 2: plain mul innermost, bias after.
    let perms: [[usize; 3]; 6] = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
    let ff = |k: &Coefficients, x: [f32; 3], perm: [usize; 3], bias: u8| -> f32 {
        let b = [k.b0, k.b1, k.b2];
        let (o, m, i) = (perm[0], perm[1], perm[2]);
        match bias {
            0 => b[o].mul_add(x[o], b[m].mul_add(x[m], b[i].mul_add(x[i], 1e-18))),
            1 => b[o].mul_add(x[o], b[m].mul_add(x[m], b[i] * x[i])) + 1e-18,
            _ => b[o].mul_add(x[o], b[m].mul_add(x[m], b[i] * x[i] + 1e-18)),
        }
    };
    let fb = |k: &Coefficients, t: f32, y1: f32, y2: f32, order: u8| -> f32 {
        match order {
            0 => (-k.a2).mul_add(y2, (-k.a1).mul_add(y1, t)),
            1 => (-k.a1).mul_add(y1, (-k.a2).mul_add(y2, t)),
            _ => t - k.a1.mul_add(y1, k.a2 * y2),
        }
    };
    let mut score = vec![vec![0usize; 6 * 3 * 3]; 8];
    let mut total = [0usize; 8];
    for line in text.lines().filter(|l| l.starts_with("biquad ")) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        let want = floats(&parts[2..]);
        let k = coeffs[parts[1]];
        for n in 2..want.len() {
            let x = [input[n], input[n - 1], input[n - 2]];
            total[n % 8] += 1;
            for (pi, perm) in perms.iter().enumerate() {
                for bias in 0..3u8 {
                    for order in 0..3u8 {
                        let y = fb(&k, ff(&k, x, *perm, bias), want[n - 1], want[n - 2], order);
                        if y.to_bits() == want[n].to_bits() {
                            score[n % 8][(pi * 3 + bias as usize) * 3 + order as usize] += 1;
                        }
                    }
                }
            }
        }
    }
    for pos in 0..8 {
        let best = (0..score[pos].len()).max_by_key(|&c| score[pos][c]).unwrap();
        let (pi, rest) = (best / 9, best % 9);
        eprintln!(
            "position {pos}: products {:?} bias {} feedback {} → {}/{} exact",
            perms[pi].map(|i| ["b0·x", "b1·x1", "b2·x2"][i]),
            rest / 3,
            rest % 3,
            score[pos][best],
            total[pos]
        );
    }
}

#[test]
#[ignore = "needs the private install data"]
fn gain_ramp_matches_legacy_probe_within_one_ulp() {
    let Some(text) = vectors() else {
        panic!("missing private data: no oracle vectors");
    };
    let input = signal(256, 23);
    let (mut samples, mut exact, mut max_ulps) = (0, 0, 0u64);
    for line in text.lines().filter(|l| l.starts_with("gainramp ")) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        let (g, s) = parts[1].split_once(':').unwrap();
        let start = f32::from_bits(u32::from_str_radix(g, 16).unwrap());
        let step = f32::from_bits(u32::from_str_radix(s, 16).unwrap());
        let want = floats(&parts[2..]);
        let mut got = input.clone();
        ramp(&mut got, start, step);
        samples += want.len();
        exact += got.iter().zip(&want).filter(|(a, b)| a.to_bits() == b.to_bits()).count();
        for (a, b) in got.iter().zip(&want) {
            max_ulps = max_ulps.max((a.to_bits() as i64 - b.to_bits() as i64).unsigned_abs());
        }
    }
    eprintln!("gain ramp: {exact}/{samples} samples bit-exact, max {max_ulps} ulp");
    assert!(samples > 0);
    // The lane arithmetic of irregular steps is not fully recovered (fit_gain_ramp): ≤ 1 ulp.
    assert!(max_ulps <= 1, "gain ramp off by {max_ulps} ulp");
}

/// Fit the gain-ramp lane arithmetic black-box against the oracle (`--ignored --nocapture`).
/// Candidates map (src, start, step, k) to the output sample; k ≥ 64 uses k = 64.
#[test]
#[ignore]
fn fit_gain_ramp() {
    let Some(text) = vectors() else { return };
    let input = signal(256, 23);
    type F = fn(f32, f32, f32, usize) -> f32;
    let candidates: [(&str, F); 8] = [
        ("src·(start + k·step)", |x, s, d, k| x * (s + k as f32 * d)),
        ("src·((start + 8g·step) + m·step)", |x, s, d, k| x * ((s + (8 * (k / 8)) as f32 * d) + (k % 8) as f32 * d)),
        ("fma(src, k·step, src·start)", |x, s, d, k| x.mul_add(k as f32 * d, x * s)),
        ("fma(src·step, k, src·start)", |x, s, d, k| (x * d).mul_add(k as f32, x * s)),
        ("src·start + src·(k·step)", |x, s, d, k| x * s + x * (k as f32 * d)),
        ("src·(f64 start + k·step)", |x, s, d, k| x * (f64::from(s) + k as f64 * f64::from(d)) as f32),
        ("f64 src·(start + k·step)", |x, s, d, k| (f64::from(x) * (f64::from(s) + k as f64 * f64::from(d))) as f32),
        ("src·fma(k, step, start) f64", |x, s, d, k| x * ((k as f64).mul_add(f64::from(d), f64::from(s)) as f32)),
    ];
    for (name, f) in candidates {
        let (mut n, mut exact) = (0, 0);
        for line in text.lines().filter(|l| l.starts_with("gainramp ")) {
            let parts: Vec<&str> = line.split_whitespace().collect();
            let (g, s) = parts[1].split_once(':').unwrap();
            let start = f32::from_bits(u32::from_str_radix(g, 16).unwrap());
            let step = f32::from_bits(u32::from_str_radix(s, 16).unwrap());
            let want = floats(&parts[2..]);
            for k in 0..256 {
                n += 1;
                exact += usize::from(f(input[k], start, step, k.min(64)).to_bits() == want[k].to_bits());
            }
        }
        eprintln!("{name}: {exact}/{n}");
    }
}
