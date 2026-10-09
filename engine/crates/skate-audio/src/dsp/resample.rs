//! Resample (Rsp0): linear interpolation with a 16.16 phase, no anti-alias filter (spec §4.3).
//!
//! ratio = f32(f32(source rate / 48000) × pitch scale); step = ratio·65536 rounded half away from
//! zero, at most 2^18 (4×). Each output is a + (b − a)·(frac·W) as one fused multiply-add, with
//! W = f32 0x377FFC9C (not exactly 1/65536). The block structure of retail's pull (carried tail,
//! look-ahead) only splits the same continuous stream, so we interpolate the stream directly.

/// The interpolation weight constant (≈ 1/65536, about one part in 2^21 off).
pub const WEIGHT: f32 = skate_audio_fma::WEIGHT;
/// Step ceiling: 2^18 = ratio 4.0 (MAX_RESAMPLE_RATIO).
pub const MAX_STEP: u32 = 1 << 18;

/// The resample ratio for a source rate and pitch scale (two single roundings).
pub fn ratio(source_rate: u32, scale: f32) -> f32 {
    (source_rate as f32 / crate::MIX_RATE as f32) * scale
}

/// 16.16 step for a ratio: rounded half away from zero, clamped to [0, 2^18].
pub fn step(ratio: f32) -> u32 {
    let x = ratio * 65536.0;
    if x.is_nan() || x <= 0.0 {
        return 0;
    }
    let s = (x + 0.5) as u64; // positive: half away from zero
    s.min(u64::from(MAX_STEP)) as u32
}

#[derive(Clone, Debug)]
pub struct Resampler {
    /// Source frame index of the left interpolation point.
    pub position: u64,
    /// Fraction (low 16 bits used).
    pub frac: u32,
    pub step: u32,
    cached_ratio: f32,
}

impl Default for Resampler {
    fn default() -> Self {
        Self { position: 0, frac: 0, step: 65536, cached_ratio: f32::NAN }
    }
}

impl Resampler {
    /// Recompute the step when the ratio changes (exact compare, as retail).
    pub fn set_ratio(&mut self, ratio: f32) {
        if ratio.to_bits() != self.cached_ratio.to_bits() {
            self.cached_ratio = ratio;
            self.step = step(ratio);
        }
    }

    /// Render `out.len()` frames of one channel from `frame(index)`. Returns nothing; call
    /// [`Resampler::advance`] once per block after all channels.
    ///
    /// The loop (`a + (b − a)·(frac·W)` fused, the 16.16 phase stepping) is
    /// `skate_audio_fma::resample`: hardware FMA when the CPU has it, the same bits (doc 11
    /// "Hardware FMA dispatch").
    pub fn render(&self, out: &mut [f32], frame: impl FnMut(u64) -> f32) {
        skate_audio_fma::resample(out, self.position, self.frac, self.step, frame);
    }

    /// Advance the phase by `frames` output frames.
    pub fn advance(&mut self, frames: usize) {
        let total = u64::from(self.frac) + u64::from(self.step) * frames as u64;
        self.position += total >> 16;
        self.frac = (total & 0xFFFF) as u32;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ratio_and_step_rules() {
        // Measured in the recomp trace: 44100 Hz at scale 0.9749 → ratio 0.8956.
        let r = ratio(44100, 0.9749);
        assert!((r - 0.8956).abs() < 1e-4);
        assert_eq!(step(1.0), 65536);
        assert_eq!(step(0.5), 32768);
        assert_eq!(step(4.0), MAX_STEP);
        assert_eq!(step(7.5), MAX_STEP);
        assert_eq!(step(0.0), 0);
        // Half away from zero: 1.5/65536 → 2.
        assert_eq!(step(1.5 / 65536.0), 2);
    }

    #[test]
    fn unity_pitch_is_an_exact_copy() {
        let src: Vec<f32> = (0..600).map(|i| (i as f32 * 0.37).sin()).collect();
        let mut r = Resampler::default();
        r.set_ratio(ratio(48000, 1.0));
        let mut out = vec![0.0; 256];
        r.render(&mut out, |i| src.get(i as usize).copied().unwrap_or(0.0));
        assert_eq!(&out[..], &src[..256]);
        r.advance(256);
        r.render(&mut out, |i| src.get(i as usize).copied().unwrap_or(0.0));
        assert_eq!(&out[..], &src[256..512]);
    }

    #[test]
    fn half_rate_interpolates_with_the_retail_weight() {
        let src = [0.0f32, 1.0, 0.0, -1.0, 0.0];
        let mut r = Resampler::default();
        r.set_ratio(0.5);
        let mut out = vec![0.0; 6];
        r.render(&mut out, |i| src.get(i as usize).copied().unwrap_or(0.0));
        let half = (32768.0f32 * WEIGHT) * 1.0;
        assert_eq!(out, vec![0.0, half, 1.0, 1.0 - half, 0.0, -half]);
        // WEIGHT is just below 1/65536.
        assert!(half < 0.5 && half > 0.4999);
    }

    #[test]
    fn advance_matches_render_position() {
        let mut r = Resampler::default();
        r.set_ratio(ratio(44100, 1.1478));
        let step = u64::from(r.step);
        r.advance(256);
        assert_eq!(r.position, (step * 256) >> 16);
        assert_eq!(u64::from(r.frac), (step * 256) & 0xFFFF);
    }
}
