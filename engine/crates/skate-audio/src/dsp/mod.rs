//! Voice-graph modules (spec: `audio-specs/aems-voice-graph-spec.md` §4, §6).
//!
//! Each module processes one 256-frame block of planar f32 channels at the block's rate.
pub mod biquad;
pub mod delay;
pub mod fss;
pub mod gain;
pub mod pan;
pub mod peaking;
pub mod resample;
pub mod reverb;
pub mod routes;
pub mod send;
pub mod shelf;

/// Hardware-FMA dispatch of the per-sample fused-multiply-add loops (biquad kernel, FSS oscillator,
/// resampler; crate `skate-audio-fma`, doc 11 "Hardware FMA dispatch"). [`init_fma`] picks the
/// copy once (FMA when the CPU has it; `SKATE_AUDIO_FMA=0` forces the plain copy) and says what it
/// picked; call it at audio start, before rendering. Both copies give the same output bits.
pub use skate_audio_fma::{Choice as FmaChoice, Path as FmaPath, active as fma_path, force as force_fma, init as init_fma};

/// 1/32767 as the retail cell holds it (0x822F8898): converts 15-bit levels to linear gain.
pub const INV_32767: f32 = 0.000_030_518_509;

/// `i % len` for ring-buffer indices, without the integer division in the common cases (`i` below
/// `2·len`, as every caller's index is): the same value for every `i` and `len > 0` (optimisation
/// pass 2026-10-03; test `wrap_is_the_remainder`).
#[inline]
pub fn wrap(i: usize, len: usize) -> usize {
    if i < len {
        i
    } else if i - len < len {
        i - len
    } else {
        i % len
    }
}

/// Degrees per azimuth unit (65536 = 360°), cell 0x822F88E8.
pub const DEGREES_PER_UNIT: f32 = 360.0 / 65536.0;

#[cfg(test)]
mod tests {
    #[test]
    fn wrap_is_the_remainder() {
        for len in 1..40usize {
            for i in 0..(5 * len + 3) {
                assert_eq!(super::wrap(i, len), i % len, "{i} % {len}");
            }
        }
        for (i, len) in [(usize::MAX, 7), (usize::MAX, usize::MAX), (usize::MAX - 1, usize::MAX), (usize::MAX / 2 + 5, usize::MAX / 2 + 1)] {
            assert_eq!(super::wrap(i, len), i % len);
        }
    }
}
