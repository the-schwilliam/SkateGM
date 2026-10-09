//! Send (Sen0, spec §4.8): a tap that adds the signal into a bus through the route table. A level
//! change ramps over 64 samples to 64/65 of the way (step = Δ·(1/65)) and the next block jumps
//! the last 1/65 (retail arithmetic). A removed voice leaves its last contributed values, which
//! the bus fades into its next block's first 16 samples (taps 16/17 … 1/17).
use super::routes::Route;

/// 1/65 as the retail cell holds it (0x822F8A00).
pub const RAMP_STEP: f32 = 0.015_384_615;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Ramp current → target (or flat).
    Normal,
    /// Ramp current → 0 (fade out).
    FadeOut,
    /// Ramp 0 → target (fade in).
    FadeIn,
}

#[derive(Clone, Debug)]
pub struct Send {
    pub target: f32,
    current: f32,
    started: bool,
    /// Per bus channel: the last sample contributed (for the release de-click).
    pub last: [f32; 6],
}

impl Default for Send {
    fn default() -> Self {
        Self { target: 1.0, current: 1.0, started: false, last: [0.0; 6] }
    }
}

impl Send {
    /// Add `src` (planar) into `bus` through `routes`.
    pub fn process(&mut self, src: &[&[f32]], routes: &[Route], bus: &mut [[f32; crate::BLOCK]; 6], mode: Mode) {
        if !self.started {
            self.current = self.target;
            self.started = true;
        }
        let (from, to) = match mode {
            Mode::Normal => (self.current, self.target),
            Mode::FadeOut => (self.current, 0.0),
            Mode::FadeIn => (0.0, self.target),
        };
        self.last = [0.0; 6];
        for &(s, d, g) in routes {
            let Some(input) = src.get(s) else { continue };
            let out = &mut bus[d];
            if from == to {
                let level = g * to;
                for (o, &x) in out.iter_mut().zip(input.iter()) {
                    *o += level * x;
                }
            } else {
                let start = g * from;
                let step = g * (to - from) * RAMP_STEP;
                let flat = start + 64.0 * step;
                for (k, (o, &x)) in out.iter_mut().zip(input.iter()).enumerate() {
                    *o += if k < 64 { start + k as f32 * step } else { flat } * x;
                }
            }
            if let Some(&x) = input.last() {
                self.last[d] += g * to * x;
            }
        }
        self.current = to;
    }
}

/// Fold a removed contributor's last values into the first 16 samples of a bus block.
pub fn fold_release(bus: &mut [[f32; crate::BLOCK]; 6], last: &[f32; 6]) {
    for (ch, &v) in last.iter().enumerate() {
        if v != 0.0 {
            for k in 0..16 {
                bus[ch][k] += v * ((16 - k) as f32 / 17.0);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dsp::routes::to_six;

    #[test]
    fn ramp_lands_at_64_of_65() {
        let mut s = Send::default();
        let x = vec![1.0f32; crate::BLOCK];
        let mut bus = [[0.0f32; crate::BLOCK]; 6];
        s.process(&[&x], to_six(1), &mut bus, Mode::Normal);
        assert!(bus[1].iter().all(|&v| v == 1.0));
        s.target = 0.0;
        let mut bus = [[0.0f32; crate::BLOCK]; 6];
        s.process(&[&x], to_six(1), &mut bus, Mode::Normal);
        assert_eq!(bus[1][0], 1.0);
        let landed = 1.0 + 64.0 * (-RAMP_STEP);
        assert_eq!(bus[1][200], landed);
        assert!((landed - 1.0 / 65.0).abs() < 1e-6);
        // Next block: flat at the target.
        let mut bus = [[0.0f32; crate::BLOCK]; 6];
        s.process(&[&x], to_six(1), &mut bus, Mode::Normal);
        assert!(bus[1].iter().all(|&v| v == 0.0));
    }

    #[test]
    fn release_fold_taps() {
        let mut bus = [[0.0f32; crate::BLOCK]; 6];
        fold_release(&mut bus, &[0.0, 1.7, 0.0, 0.0, 0.0, 0.0]);
        assert_eq!(bus[1][0], 1.7 * 16.0 / 17.0);
        assert_eq!(bus[1][15], 1.7 / 17.0);
        assert_eq!(bus[1][16], 0.0);
    }
}
