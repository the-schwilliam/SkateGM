//! Gain (Gai0, spec §4.6): a 64-sample linear de-click on every target change, then flat.
//! On the graph's first block the applied gain jumps to the target (no ramp).

#[derive(Clone, Debug)]
pub struct Gain {
    /// Parameter 0: target gain (linear amplitude).
    pub target: f32,
    applied: f32,
    started: bool,
}

impl Default for Gain {
    fn default() -> Self {
        Self { target: 1.0, applied: 1.0, started: false }
    }
}

impl Gain {
    pub fn applied(&self) -> f32 {
        self.applied
    }

    pub fn process(&mut self, channels: &mut [&mut [f32]]) {
        if !self.started {
            self.applied = self.target;
            self.started = true;
        }
        let start = self.applied;
        // Two roundings, never fused.
        let step = (self.target - start) * (1.0 / 64.0);
        if step == 0.0 {
            if start != 1.0 {
                for ch in channels.iter_mut() {
                    for s in ch.iter_mut() {
                        *s *= start;
                    }
                }
            }
        } else {
            for ch in channels.iter_mut() {
                ramp(ch, start, step);
            }
        }
        self.applied = self.target;
    }
}

/// TU3 `82B3C098`: four initial lanes, advanced in two groups of 32 samples.
/// The seeds for lanes 2/3, group advances and flat gain use fused operations.
/// Each lane's first addition and the final sample multiply round separately.
/// Expected samples are obtained by executing the native instruction translation,
/// not by another implementation of this formula (`tests/retail_gain.rs`).
pub fn ramp(samples: &mut [f32], start: f32, step: f32) {
    skate_audio_fma::gain_ramp(samples, start, step);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_block_jumps_then_changes_ramp_over_64_samples() {
        let mut g = Gain { target: 0.5, ..Gain::default() };
        let mut x = vec![1.0f32; 256];
        g.process(&mut [&mut x[..]]);
        assert!(x.iter().all(|&v| v == 0.5));
        g.target = 0.0;
        let mut x = vec![1.0f32; 256];
        g.process(&mut [&mut x[..]]);
        assert_eq!(x[0], 0.5);
        assert_eq!(x[32], 0.5 + 32.0 * (-0.5 / 64.0));
        assert_eq!(x[63], (0.5 + 56.0 * (-0.5 / 64.0)) + 7.0 * (-0.5 / 64.0));
        assert!(x[64..].iter().all(|&v| v == 0.0));
        assert_eq!(g.applied(), 0.0);
    }
}
