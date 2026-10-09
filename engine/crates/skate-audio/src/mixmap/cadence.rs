//! The console's audio-manager cadence for the MixMap host, in our own words from the retail code
//! (TU3, reference only).
//!
//! Retail's audio manager `sub_82485190` runs once per rendered frame with that frame's dt and
//! splits its work into two halves:
//! - half 1: `sub_82491180` (the eEQChain clear and the jitter post), the listener, then every
//!   state manager's process (vtable +16 → each SFX object's process: input writers, `SFXObj_Jitter`'s
//!   random-walk step, component posts);
//! - half 2: the MixMap tick (`sub_8294BAE8`, with the halves' summed dt), then every update
//!   (vtable +20 → each SFX object's update).
//!
//! When the frame's dt is above 0.02 s (`0x822F8DE8`) both halves run on every call; at or below it
//! they alternate between calls, each with the sum of the last two dts. So the shipped game,
//! rendering at about 30 fps, evaluates the MixMap, steps the Jitter and clears the eEQChain buses
//! **once per 1/30 s**, with dt ≈ 1/30 (and so would it at 60 fps: halves alternating, 30 Hz each).
//! Envelopes use dt; the Doppler slew (`D += trunc(0.2 · (target − D))`) and the jitter walk are per
//! evaluation, so their speed depends on this rate. (The recomp, rendering uncapped at ~345 fps,
//! alternates the halves at ~170 Hz each: not the console's rate.)
//!
//! Our host writes inputs and runs the components per 60 Hz physics step; [`Cadence`] picks the
//! steps that carry a console evaluation: every second step on a fixed grid of real time, so the
//! result does not depend on the real frame rate. Flag inputs written on the steps in between are
//! held to the next evaluation ([`super::MixMap::hold_input`]).

/// One console frame (retail's dt at 30 fps).
pub const CONSOLE_DT: f32 = 1.0 / 30.0;

/// The 60 Hz steps per console evaluation.
pub const STEPS_PER_CALL: u64 = 2;

/// Which 60 Hz host steps carry a console evaluation.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Cadence {
    /// 60 Hz steps run so far.
    pub steps: u64,
    /// Console evaluations so far.
    pub calls: u64,
}

impl Cadence {
    /// The host ran `steps` more 60 Hz steps (in one pass): the console evaluations they complete
    /// (0 or 1 at 60 fps and above, 1 at 30 fps, 1 or 2 at 20 fps).
    pub fn advance(&mut self, steps: usize) -> usize {
        let before = self.steps / STEPS_PER_CALL;
        self.steps += steps as u64;
        let n = (self.steps / STEPS_PER_CALL - before) as usize;
        self.calls += n as u64;
        n
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every second 60 Hz step evaluates, however the steps are grouped into real frames.
    #[test]
    fn evaluations_follow_the_steps_not_the_frames() {
        for groups in [vec![1usize; 600], vec![2; 300], vec![3; 200], vec![1, 0, 0, 1, 0, 2, 3, 1, 0, 0].repeat(60)] {
            let mut c = Cadence::default();
            let mut at = Vec::new();
            for g in &groups {
                let n = c.advance(*g);
                if n > 0 {
                    at.push((c.steps, n));
                }
            }
            let total: u64 = groups.iter().map(|&g| g as u64).sum();
            assert_eq!(c.calls, total / 2, "{groups:?}");
            assert!(at.iter().all(|&(s, n)| n <= 2 && s >= 2 * n as u64));
        }
        let mut c = Cadence::default();
        let seq: Vec<usize> = (0..6).map(|_| c.advance(1)).collect();
        assert_eq!(seq, [0, 1, 0, 1, 0, 1]);
    }
}
