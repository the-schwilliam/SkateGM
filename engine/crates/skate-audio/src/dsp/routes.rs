//! Channel routes (spec §6.1) and the output stage's downmix tables (spec §6.3).
//!
//! Internal 6-channel order: L, C, R, Ls, Rs, LFE. The 0.707 gain is the f32 nearest to 0.707
//! (0.7070000172), not 1/√2.

pub const G707: f32 = 0.707;

/// One route: (source channel, destination channel, gain).
pub type Route = (usize, usize, f32);

/// Routes converting a `src`-channel signal into 6 channels (the voice-graph Send into a 6-channel
/// bus). Unlisted gains are 1. Counts 3, 5 and 7 have no routes (retail executes garbage there).
pub fn to_six(src: usize) -> &'static [Route] {
    match src {
        1 => &[(0, 1, 1.0)],                                  // centre only
        2 => &[(0, 0, 1.0), (1, 2, 1.0)],                     // L→L, R→R
        4 => &[(0, 0, 1.0), (1, 2, 1.0), (2, 3, 1.0), (3, 4, 1.0)], // FL, FR, SL, SR
        6 => &[(0, 0, 1.0), (1, 1, 1.0), (2, 2, 1.0), (3, 3, 1.0), (4, 4, 1.0), (5, 5, 1.0)],
        _ => &[],
    }
}

/// The output stage's stereo table (N = 2) applied to the 6 planes we keep (L, C, R, Ls, Rs,
/// LFE; Lx/Rx are empty in our mix): Lo = 0.707·L + 0.5·C + 0.5·Ls, Ro mirrored, LFE dropped.
/// Every sample is then clamped to ±1 (NaN passes), with no master gain.
pub fn output_stereo(six: &[[f32; crate::BLOCK]; 6], out: &mut [f32]) {
    for k in 0..crate::BLOCK {
        let l = G707 * six[0][k] + 0.5 * six[1][k] + 0.5 * six[3][k];
        let r = G707 * six[2][k] + 0.5 * six[1][k] + 0.5 * six[4][k];
        out[2 * k] = clamp(l);
        out[2 * k + 1] = clamp(r);
    }
}

/// The recomp host's capture conversion (rex): Lc = 0.4·(FL + SL + 0.5·C), Rc mirrored. Only for
/// comparing levels with `SKATE3_AUDIO_CAPTURE` recordings; not the game's own fold.
pub fn capture_stereo(six: &[[f32; crate::BLOCK]; 6], out: &mut [f32]) {
    for k in 0..crate::BLOCK {
        out[2 * k] = 0.4 * (six[0][k] + six[3][k] + 0.5 * six[1][k]);
        out[2 * k + 1] = 0.4 * (six[2][k] + six[4][k] + 0.5 * six[1][k]);
    }
}

/// Clamp out-of-range values to ±1; NaN passes through as retail.
#[inline]
pub fn clamp(v: f32) -> f32 {
    if v > 1.0 {
        1.0
    } else if v < -1.0 {
        -1.0
    } else {
        v
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stereo_fold_and_clamp() {
        let mut six = [[0.0f32; crate::BLOCK]; 6];
        six[1][0] = 1.0; // centre
        six[0][1] = 1.0; // left
        six[3][2] = 1.0; // left surround
        six[5][3] = 1.0; // LFE dropped
        six[0][4] = 3.0; // clipped
        six[0][5] = f32::NAN;
        let mut out = vec![0.0f32; 2 * crate::BLOCK];
        output_stereo(&six, &mut out);
        assert_eq!(&out[0..2], &[0.5, 0.5]);
        assert_eq!(&out[2..4], &[G707, 0.0]);
        assert_eq!(&out[4..6], &[0.5, 0.0]);
        assert_eq!(&out[6..8], &[0.0, 0.0]);
        assert_eq!(out[8], 1.0);
        assert!(out[10].is_nan());
        assert_eq!(G707.to_bits(), 0.707f32.to_bits());
    }
}
