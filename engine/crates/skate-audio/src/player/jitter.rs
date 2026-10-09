//! `SFXObj_Jitter` (MixMap controller `0x400000E0`): bounded random walks written into the
//! Jitter inputs every frame (process `sub_824EF378`, step `sub_824EF4C8`, channels built by
//! `sub_824EF0B8` from the vault's leaf collections). Several Player sums scale small ducks with
//! them (e.g. A63: −300 mB at a crawl × Jitter.in0, the rolling bed's gain A), so leaving them at
//! 0 removes those ducks.
//!
//! Each frame, per channel: one draw r of the title generator; s = r mod 2001 − 1000;
//! d = (max − min)·(s·0.001); the step is d pushed away from zero by `min`; velocity += step,
//! clamped to ±max; value += velocity, reflected off centre ± range (the velocity flips), then
//! clamped there. Enabled channels write clamp(trunc(clamp(value, 0, 32767)), 0, 32767) to their
//! input id. Every channel starts at its centre with zero velocity.
//!
//! Retail draws from the title-wide generator (shared with ~100 call sites, seeded with the time
//! base), so sequences are not reproducible; we use our own instance of the same add-with-carry
//! generator, seeded with the image constants.
use super::tuning::JitterParams;
use crate::eval::rng::Rng;

/// `0x82063A48` 0.001.
const UNIT: f32 = f32::from_bits(0x3A83_126F);

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Channel {
    pub params: JitterParams,
    pub value: f32,
    pub velocity: f32,
}

impl Channel {
    pub fn new(params: JitterParams) -> Self {
        Self { params, value: params.centre, velocity: 0.0 }
    }

    /// One random-walk step with the draw `r`.
    pub fn step(&mut self, r: u32) {
        let p = self.params;
        let s = (r % 2001) as i32 - 1000;
        let d = (p.max_step - p.min_step) * (s as f32 * UNIT);
        let push = if d < 0.0 { d - p.min_step } else { p.min_step + d };
        let v = (push + self.velocity).clamp(-p.max_step, p.max_step);
        self.velocity = v;
        let (upper, lower) = (p.centre + p.range, p.centre - p.range);
        let mut x = v + self.value;
        if x > upper {
            self.velocity = -v;
            x = upper - (x - upper);
        } else if x < lower {
            self.velocity = -v;
            x = (lower - x) + lower;
        }
        self.value = x.clamp(lower, upper);
    }

    /// The input word: clamp(trunc(clamp(value, 0, 32767)), 0, 32767).
    pub fn word(&self) -> i32 {
        super::trunc_clamp(self.value.clamp(0.0, 32767.0), 0, 32767)
    }
}

#[derive(Clone, Debug)]
pub struct Jitter {
    pub channels: Vec<Channel>,
    pub rng: Rng,
}

impl Jitter {
    pub fn new(params: &[JitterParams], seed: [u32; 6]) -> Self {
        Self { channels: params.iter().map(|&p| Channel::new(p)).collect(), rng: Rng::new(seed) }
    }

    /// One frame: advance every channel, return the enabled ones' (input id, word) in order (a
    /// later channel on the same id overwrites an earlier one, as retail's writes do).
    pub fn process(&mut self) -> Vec<(usize, i32)> {
        let mut out = Vec::new();
        self.process_each(|id, word| out.push((id, word)));
        out
    }

    /// [`Jitter::process`] without the list: `write(input id, word)` per enabled channel, in the
    /// same order and with the same draws (the game's per-frame call; no allocation).
    pub fn process_each(&mut self, mut write: impl FnMut(usize, i32)) {
        for ch in &mut self.channels {
            let r = self.rng.draw();
            ch.step(r);
            if ch.params.enabled {
                write(ch.params.id, ch.word());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(centre: f32, range: f32, max: f32, min: f32) -> JitterParams {
        JitterParams { enabled: true, id: 2, centre, range, max_step: max, min_step: min }
    }

    #[test]
    fn the_walk_stays_inside_centre_plus_minus_range() {
        let mut j = Jitter::new(&[params(16384.0, 16383.0, 31000.0, 19000.0), params(16384.0, 16383.0, 100.0, 1.0)], [1, 2, 3, 4, 5, 6]);
        let mut seen = [i32::MAX, i32::MIN];
        for _ in 0..10_000 {
            for (id, w) in j.process() {
                assert_eq!(id, 2);
                assert!((1..=32767).contains(&w), "{w}");
                seen = [seen[0].min(w), seen[1].max(w)];
            }
            for c in &j.channels {
                assert!(c.velocity.abs() <= c.params.max_step);
            }
        }
        assert!(seen[0] < 2000 && seen[1] > 30000, "{seen:?}");
    }

    #[test]
    fn one_step_by_hand() {
        // r = 2001·k + 1500 → s = 500: d = (100 − 1)·0.5 = 49.5, push = 50.5 (from rest).
        let mut c = Channel::new(params(1000.0, 10.0, 100.0, 1.0));
        c.step(2001 * 7 + 1500);
        // 1000 + 50.5 > 1010: reflected to 1010 − 40.5 = 969.5 (velocity flipped), then clamped
        // into 990..1010.
        assert!((c.value - 990.0).abs() < 1e-3, "{}", c.value);
        assert!((c.velocity + 50.5).abs() < 1e-3);
        // s = −1000: d = −99, push = −100, velocity −150.5 → clamped −100; 890 is below 990:
        // reflected to 1090 (velocity +100), then clamped to the top, 1010.
        c.step(0);
        assert!((c.velocity - 100.0).abs() < 1e-3);
        assert!((c.value - 1010.0).abs() < 1e-3, "{}", c.value);
    }
}
