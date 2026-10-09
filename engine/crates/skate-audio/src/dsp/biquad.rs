//! HighPassIir2 / LowPassIir2 (spec §4.4, §4.5): RBJ cookbook biquads at fixed Q = 1, single
//! precision, Direct Form I with a 1e-18 denormal bias. The cutoff is raw Hz; the filter bypasses
//! (bit-exact pass-through) outside 24 Hz … 0.999·Nyquist, so a raw 25000 Hz low-pass is "open"
//! because it lies past 0.999·Nyquist, not because of a special case.

/// 2π as f32 (6.2831855).
pub const TWO_PI: f32 = std::f32::consts::TAU;
/// ω floor π/1000 (≈ 24 Hz at 48 kHz) and ceiling 0.999π (≈ 23976 Hz), image constants.
pub const FLOOR: f32 = 0.003_141_593;
pub const CEIL: f32 = 3.138_451_1;
/// Denormal guard added to the feed-forward sum (cell 0x822F87B0).
pub const BIAS: f32 = skate_audio_fma::BIAS;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    LowPass,
    HighPass,
}

/// Normalised coefficients {a1, a2, b0, b1, b2} (defined next to the kernel in `skate-audio-fma`).
pub use skate_audio_fma::Coefficients;

/// RBJ low/high-pass at Q = 1 from ω, every step in f32 (sin/cos in f64, rounded once).
pub fn coefficients(kind: Kind, omega: f32) -> Coefficients {
    let s = (omega as f64).sin() as f32;
    let c = (omega as f64).cos() as f32;
    let alpha = 0.5 * s;
    let a0 = 1.0 + alpha;
    let inv = 1.0 / a0;
    let a1 = (-2.0 * c) * inv;
    let a2 = (1.0 - alpha) * inv;
    let (n, sign) = match kind {
        Kind::LowPass => (1.0 - c, 1.0f32),
        Kind::HighPass => (1.0 + c, -1.0f32),
    };
    let b0 = n / (2.0 * a0);
    Coefficients { a1, a2, b0, b1: sign * (n * inv), b2: b0 }
}

/// ω for a cutoff at the block rate: f32(f32(fc / fs) × 2π).
pub fn omega(cutoff: f32, rate: f32) -> f32 {
    (cutoff / rate) * TWO_PI
}

#[derive(Clone, Debug)]
pub struct Iir2 {
    pub kind: Kind,
    /// Parameter 0: cutoff in Hz.
    pub cutoff: f32,
    cached: f32,
    coefficients: Coefficients,
    /// Per channel {x1, x2, y1, y2}.
    history: [[f32; 4]; 8],
    filtering: bool,
}

impl Iir2 {
    /// Class defaults: HPF 0 Hz, LPF 96000 Hz (both bypass).
    pub fn new(kind: Kind) -> Self {
        let cutoff = match kind {
            Kind::LowPass => 96_000.0,
            Kind::HighPass => 0.0,
        };
        // The constructor caches the raw Hz, so the first filtering block always rebuilds.
        Self { kind, cutoff, cached: cutoff, coefficients: Coefficients::default(), history: [[0.0; 4]; 8], filtering: false }
    }

    /// True when this block will pass through untouched.
    pub fn bypassed(&self, rate: f32) -> bool {
        let w = omega(self.cutoff, rate);
        match self.kind {
            Kind::LowPass => w.is_nan() || w >= CEIL,
            Kind::HighPass => w.is_nan() || w <= FLOOR,
        }
    }

    /// Process one block in place (planar channels).
    pub fn process(&mut self, channels: &mut [&mut [f32]], rate: f32) {
        let w = omega(self.cutoff, rate);
        let bypass = match self.kind {
            Kind::LowPass => w.is_nan() || w >= CEIL,
            Kind::HighPass => w.is_nan() || w <= FLOOR,
        };
        if bypass {
            if self.filtering {
                self.history = [[0.0; 4]; 8];
            }
            self.filtering = false;
            self.cached = w;
            return;
        }
        let w = match self.kind {
            Kind::LowPass => w.max(FLOOR),
            Kind::HighPass => w.min(CEIL),
        };
        if w.to_bits() != self.cached.to_bits() || !self.filtering && self.coefficients == Coefficients::default() {
            self.coefficients = coefficients(self.kind, w);
            self.cached = w;
        }
        self.filtering = true;
        for (ch, samples) in channels.iter_mut().enumerate().take(8) {
            kernel_block(&self.coefficients, &mut self.history[ch], samples);
        }
    }
}

/// Direct Form I in place over one block of one channel, history {x1, x2, y1, y2}.
///
/// Feed-forward b0·x + b1·x1 + b2·x2 + 1e-18 and feedback y = (t − a1·y1) − a2·y2 in single
/// precision. Retail processes 8 samples at a time and associates the feed-forward sum by the
/// sample's position in its group of 8 (groups aligned to the block start). The order below was
/// fitted black-box against the PoC's replay-verified kernel (`tests/dsp_oracle.rs`
/// `fit_biquad_association`: every position 100 % bit-exact) — the innermost product is a plain
/// multiply plus the bias, the outer two are fused multiply-adds:
/// - position 0: b1·x1 + (b2·x2 + (b0·x + bias));
/// - position 1: b2·x2 + (b1·x1 + (b0·x + bias));
/// - positions 2..7: b0·x + (b2·x2 + (b1·x1 + bias));
/// - feedback: two fused negative multiply-subtracts, a1 first.
///
/// The loop lives in `skate-audio-fma` (`body::biquad`, the same source), which runs it with
/// hardware FMA when the CPU has it: the same bits (doc 11 "Hardware FMA dispatch").
pub fn kernel(k: &Coefficients, history: &mut [f32; 4], samples: &mut [f32]) {
    skate_audio_fma::biquad(k, history, samples);
}

/// The block holds only `+0.0` samples (bit pattern 0).
pub fn silent(samples: &[f32]) -> bool {
    samples.iter().all(|v| v.to_bits() == 0)
}

/// Every group of 8 samples is bit-identical to the first (a silent or constant block, e.g. a bus
/// nothing plays into, or the 1e-18 bias settling a filter ahead). False for blocks whose length is
/// not a multiple of 8 or shorter than 16.
pub fn periodic8(samples: &[f32]) -> bool {
    if samples.len() < 16 || samples.len() % 8 != 0 {
        return false;
    }
    let (first, rest) = samples.split_at(8);
    rest.chunks_exact(8).all(|c| c.iter().zip(first).all(|(a, b)| a.to_bits() == b.to_bits()))
}

/// [`kernel`], bit-identical, with a shortcut for a settled filter on an 8-periodic block
/// ([`periodic8`]; optimisation pass 2026-10-03, doc 11 "Optimisation pass").
///
/// The kernel is a pure function of the coefficients, the history and the input, and its sample
/// arithmetic depends on the position only through `n % 8`. On an 8-periodic block it runs the
/// first group of 8 for real; when the history after it is bit-identical to the history before (a
/// settled filter: the 1e-18 bias at its fixed point, or a cycle whose length divides 8), every
/// later group starts in the same state with the same input and produces the same 8 outputs, and
/// the final history is the starting one. Otherwise the rest of the block runs through [`kernel`]
/// from the state after the group (`samples[8..]` starts at position 0 mod 8 again), so nothing is
/// computed twice. Any other block takes [`kernel`] directly.
///
/// A silent block (all `+0.0`) that has not settled continues with [`kernel_silent_tail`].
pub fn kernel_block(k: &Coefficients, history: &mut [f32; 4], samples: &mut [f32]) {
    if !periodic8(samples) {
        return kernel(k, history, samples);
    }
    let zero = silent(&samples[..8]);
    let before = history.map(f32::to_bits);
    let (group, rest) = samples.split_at_mut(8);
    kernel(k, history, group);
    if history.map(f32::to_bits) == before {
        for chunk in rest.chunks_exact_mut(8) {
            chunk.copy_from_slice(group);
        }
    } else if zero {
        kernel_silent_tail(k, history, rest);
    } else {
        kernel(k, history, rest);
    }
}

/// [`kernel`] on silent input (all `+0.0`) once the history's inputs are `+0.0` too (x1 = x2 = 0,
/// i.e. from the third silent sample on), bit-identical to it.
///
/// With x = x1 = x2 = +0 each of the kernel's three feed-forward forms reduces to the bias: every
/// product of a finite coefficient with +0 is ±0, and ±0 + 1e-18 (or a fused ±0 + 1e-18) is exactly
/// 1e-18. That is checked at run time with the kernel's own expressions (a non-finite coefficient
/// makes it fail, and the plain kernel runs), so only the two feedback multiply-adds remain per
/// sample. Falls back to [`kernel`] when the history's inputs are not +0.
pub fn kernel_silent_tail(k: &Coefficients, history: &mut [f32; 4], samples: &mut [f32]) {
    debug_assert!(silent(samples));
    let [x1, x2, y1, y2] = *history;
    let z = 0.0f32;
    let t = [
        k.b1.mul_add(z, k.b2.mul_add(z, k.b0 * z + BIAS)),
        k.b2.mul_add(z, k.b1.mul_add(z, k.b0 * z + BIAS)),
        k.b0.mul_add(z, k.b2.mul_add(z, k.b1 * z + BIAS)),
    ];
    if x1.to_bits() != 0 || x2.to_bits() != 0 || t.iter().any(|t| t.to_bits() != BIAS.to_bits()) {
        return kernel(k, history, samples);
    }
    // y = (−a2)·y2 + ((−a1)·y1 + bias) per sample (`skate-audio-fma`, `body::biquad_feedback`).
    let mut y = [y1, y2];
    skate_audio_fma::biquad_feedback(k, &mut y, samples);
    *history = [z, z, y[0], y[1]];
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(a: f32, b: f32) -> bool {
        (a - b).abs() <= 2.0 * f32::EPSILON * b.abs().max(1.0)
    }

    #[test]
    fn worked_coefficients_from_the_spec() {
        for (kind, fc, want) in [
            (Kind::LowPass, 5000.0, [-1.2164445, 0.53329474, 0.079212569, 0.15842514]),
            (Kind::LowPass, 1000.0, [-1.8614084, 0.87747043, 0.0040154932, 0.0080309864]),
            (Kind::HighPass, 77.0, [-1.9898703, 0.98997140, 0.99496043, -1.9899209]),
        ] {
            let c = coefficients(kind, omega(fc, 48000.0));
            for (got, want) in [c.a1, c.a2, c.b0, c.b1].into_iter().zip(want) {
                assert!(close(got, want), "{kind:?} {fc}: {got} vs {want}");
            }
            assert_eq!(c.b0, c.b2);
        }
        assert_eq!(omega(5000.0, 48000.0), 0.654_498_46);
    }

    #[test]
    fn bypass_edges() {
        let mut lpf = Iir2::new(Kind::LowPass);
        for (fc, bypass) in [(25000.0, true), (23976.0, true), (23975.0, false), (96000.0, true)] {
            lpf.cutoff = fc;
            assert_eq!(lpf.bypassed(48000.0), bypass, "LPF {fc}");
        }
        let mut hpf = Iir2::new(Kind::HighPass);
        for (fc, bypass) in [(0.0, true), (24.0, true), (25.0, false), (77.0, false)] {
            hpf.cutoff = fc;
            assert_eq!(hpf.bypassed(48000.0), bypass, "HPF {fc}");
        }
        // Bypass is a bit-exact pass-through.
        let mut x: Vec<f32> = (0..256).map(|i| (i as f32 * 0.1).sin()).collect();
        let before = x.clone();
        lpf.cutoff = 25000.0;
        lpf.process(&mut [&mut x[..]], 48000.0);
        assert_eq!(x, before);
    }

    #[test]
    fn low_pass_attenuates_above_cutoff_and_passes_below() {
        let rms = |fc: f32, f: f32| {
            let mut lpf = Iir2::new(Kind::LowPass);
            lpf.cutoff = fc;
            let mut x: Vec<f32> = (0..48000).map(|i| (std::f32::consts::TAU * f * i as f32 / 48000.0).sin()).collect();
            for chunk in x.chunks_mut(256) {
                lpf.process(&mut [chunk], 48000.0);
            }
            let tail = &x[24000..];
            (tail.iter().map(|v| v * v).sum::<f32>() / tail.len() as f32).sqrt() * std::f32::consts::SQRT_2
        };
        // 0 dB at fc for Q = 1 (RBJ), strong cut two octaves above, flat well below.
        assert!((rms(1000.0, 1000.0) - 1.0).abs() < 0.02);
        assert!(rms(1000.0, 4000.0) < 0.08);
        assert!((rms(1000.0, 100.0) - 1.0).abs() < 0.02);
    }

    #[test]
    fn history_clears_when_switching_to_bypass() {
        let mut lpf = Iir2::new(Kind::LowPass);
        lpf.cutoff = 1000.0;
        let mut x = vec![1.0f32; 256];
        lpf.process(&mut [&mut x[..]], 48000.0);
        lpf.cutoff = 25000.0;
        lpf.process(&mut [&mut x[..]], 48000.0);
        assert_eq!(lpf.history[0], [0.0; 4]);
    }

    /// Coefficient sets for the shortcut checks: low/high-pass across the range, peaking EQs, the
    /// FSS allpass sections, and degenerate ones (zero, NaN, infinite).
    fn coefficient_sets() -> Vec<Coefficients> {
        let mut v = Vec::new();
        for fc in [30.0, 77.0, 400.0, 2500.0, 12000.0, 23000.0] {
            v.push(coefficients(Kind::LowPass, omega(fc, 48000.0)));
            v.push(coefficients(Kind::HighPass, omega(fc, 48000.0)));
        }
        for (f, g, q) in [(150.0, 1.5, 3.0), (5000.0, 0.75, 0.25), (450.0, 20.0, 20.0), (96000.0, 0.1, 0.2), (1500.0, 1.0000001, 3.0)] {
            v.push(crate::dsp::peaking::coefficients(f, g, q, 48000.0));
        }
        v.extend(crate::dsp::fss::SECTIONS);
        v.push(Coefficients::default());
        v.push(Coefficients { b1: f32::NAN, ..coefficients(Kind::LowPass, 0.3) });
        v.push(Coefficients { b0: f32::INFINITY, ..coefficients(Kind::HighPass, 0.3) });
        v.push(Coefficients { a1: f32::NAN, ..coefficients(Kind::HighPass, 0.3) });
        v
    }

    fn bits(x: &[f32]) -> Vec<u32> {
        x.iter().map(|v| v.to_bits()).collect()
    }

    /// The optimisation pass's [`kernel_block`] (settled-filter and silent-tail shortcuts) against
    /// the plain kernel, bit for bit: every coefficient set, block lengths around the group of 8,
    /// silent / -0.0 / constant / 8-periodic / noisy blocks, from fresh, noisy, settled and
    /// non-finite histories, over long silences so that the filters settle (and the shortcut is
    /// shown to run).
    #[test]
    fn kernel_block_matches_the_plain_kernel() {
        let mut seed = 0x2545_F491u32;
        let mut noise = move || {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            (seed >> 8) as f32 / (1u32 << 23) as f32 - 1.0
        };
        let (mut settled, mut tails) = (0usize, 0usize);
        for k in coefficient_sets() {
            for len in [0usize, 1, 7, 8, 9, 15, 16, 24, 255, 256, 264] {
                let blocks: Vec<Vec<f32>> = vec![
                    vec![0.0; len],
                    vec![-0.0; len],
                    vec![0.25; len],
                    (0..len).map(|i| [0.0, 1e-20, -3.0, 0.5, 0.0, -0.0, 7.0, 1.0][i % 8]).collect(),
                    (0..len).map(|_| noise()).collect(),
                    (0..len).map(|i| if i == len / 2 { 1e-30 } else { 0.0 }).collect(),
                ];
                let starts = [[0.0f32; 4], [0.5, -0.25, 0.125, 1.0], [0.0, 0.0, 1e-18, 1e-18], [-0.0, 0.0, 0.0, -0.0], [f32::NAN, 0.0, 1.0, 0.0], [0.0, 0.0, f32::INFINITY, 0.0]];
                for start in starts {
                    for b in &blocks {
                        let (mut ha, mut hb) = (start, start);
                        let (mut xa, mut xb) = (b.clone(), b.clone());
                        kernel(&k, &mut ha, &mut xa);
                        kernel_block(&k, &mut hb, &mut xb);
                        assert_eq!(bits(&xa), bits(&xb), "{k:?} len {len} start {start:?}");
                        assert_eq!(bits(&ha), bits(&hb), "{k:?} len {len} start {start:?}");
                    }
                }
            }
            // A burst, then a long silence: the filter decays (silent tail), then settles (the
            // repeated group), block by block identical to the plain kernel.
            let (mut ha, mut hb) = ([0.0f32; 4], [0.0f32; 4]);
            for block in 0..3000 {
                let input: Vec<f32> = if block < 3 { (0..256).map(|_| noise()).collect() } else { vec![0.0; 256] };
                let (mut xa, mut xb) = (input.clone(), input);
                let before = hb;
                kernel(&k, &mut ha, &mut xa);
                kernel_block(&k, &mut hb, &mut xb);
                assert_eq!(bits(&xa), bits(&xb), "{k:?} block {block}");
                assert_eq!(bits(&ha), bits(&hb), "{k:?} block {block}");
                if block >= 3 {
                    if bits(&before) == bits(&hb) {
                        settled += 1;
                    } else {
                        tails += 1;
                    }
                }
            }
        }
        assert!(settled > 1000 && tails > 100, "both shortcuts ran: settled {settled}, tails {tails}");
    }
}
