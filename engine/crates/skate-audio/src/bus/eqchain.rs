//! The eight eEQChain ("material") buses (spec `audio-specs/aems-eqchain-buses-spec.md`): per bus
//! `Sub0 → DCl0 → PeakingIir2 → PeakingIir2 → Sen0 (→ SFX Master)`, 6 channels, order 253.
//!
//! - Buses with the record's enable flag (0–4): the first create-flagged resolve after a clear
//!   re-rolls the six EQ values (`sub_824916E8`): each = b + (k·(a − b))·0.1 with k = r mod 11 from
//!   the title generator (no draw when a == b), in the order PI20#1 freq, gain, Q, PI20#2 freq,
//!   gain, Q, then the clip level.
//! - Buses without it (5–7): every clear posts the shared jitter walk's values (`sub_82491180`):
//!   freq clamped 0..96000, gain 0.1..20, Q 0.2..20, clip 0..1000.
//! - The clear (`sub_82491180`) runs on every second game frame (both halves on frames longer than
//!   20 ms) and resets every created flag.
//! - Index 8 = SFX Master (no EQ).
use crate::BLOCK;
use crate::dsp::peaking::{PeakingIir2, clip};
use crate::eval::rng::Rng;

/// One bus's vault record (class `AA801D9FC0ADBBBF`, collection from the image table 0x8224DC78).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EqRecord {
    pub enabled: bool,
    pub clip: f32,
    /// (a, b) per value: PI20#1 freq, gain, Q, PI20#2 freq, gain, Q.
    pub ranges: [[f32; 2]; 6],
}

#[derive(Clone, Debug)]
pub struct EqBus {
    pub record: Option<EqRecord>,
    pub created: bool,
    pub level: f32,
    pub eq: [PeakingIir2; 2],
}

impl Default for EqBus {
    fn default() -> Self {
        Self { record: None, created: false, level: 100.0, eq: [PeakingIir2::default(), PeakingIir2::default()] }
    }
}

/// `sub_82491DF0`: one value on the 11-point grid between b and a.
pub fn pick(a: f32, b: f32, rng: &mut Rng) -> f32 {
    if a == b {
        return b;
    }
    let k = (rng.draw() % 11) as f32;
    (k * (a - b)).mul_add(f32::from_bits(0x3DCC_CCCD), b)
}

pub struct EqBuses {
    pub buses: [EqBus; 8],
    pub rng: Rng,
    /// Re-rolls so far (diagnostics).
    pub rolls: u64,
}

impl Default for EqBuses {
    fn default() -> Self {
        // Our own instance of the title generator, seeded like the evaluator's.
        Self { buses: Default::default(), rng: Rng::new([0x0F1E_2D3C, 0x4B5A_6978, 0x8796_A5B4, 0xC3D2_E1F0, 0x1357_9BDF, 0x2468_ACE0]), rolls: 0 }
    }
}

impl EqBuses {
    pub fn set_records(&mut self, records: &[EqRecord]) {
        for (bus, r) in self.buses.iter_mut().zip(records) {
            bus.record = Some(*r);
        }
    }

    /// `sub_82491108`: a voice or owner resolves bus `idx`; `create` re-rolls a fresh preset on the
    /// first use since the last clear.
    pub fn resolve(&mut self, idx: u8, create: bool) {
        let Some(bus) = self.buses.get_mut(usize::from(idx)) else { return };
        if !create || bus.created {
            return;
        }
        bus.created = true;
        let Some(r) = bus.record.filter(|r| r.enabled) else { return };
        let mut v = [0.0f32; 6];
        for (v, [a, b]) in v.iter_mut().zip(r.ranges) {
            *v = pick(a, b, &mut self.rng);
        }
        for (k, eq) in bus.eq.iter_mut().enumerate() {
            eq.freq = v[3 * k];
            eq.gain = v[3 * k + 1];
            eq.q = v[3 * k + 2];
        }
        bus.level = r.clip;
        self.rolls += 1;
    }

    /// `sub_82491180` (every second game frame): post the jitter values (PI20#1 freq, gain, Q,
    /// PI20#2 freq, gain, Q) to the buses without the enable flag, then clear every created flag.
    pub fn clear(&mut self, jitter: Option<[f32; 6]>) {
        for bus in &mut self.buses {
            if let (Some(r), Some(j)) = (bus.record, jitter) {
                if !r.enabled {
                    for (k, eq) in bus.eq.iter_mut().enumerate() {
                        eq.freq = j[3 * k].clamp(0.0, 96_000.0);
                        eq.gain = j[3 * k + 1].clamp(0.1, 20.0);
                        eq.q = j[3 * k + 2].clamp(0.2, 20.0);
                    }
                    bus.level = r.clip.clamp(0.0, 1000.0);
                }
            }
            bus.created = false;
        }
    }

    /// Process the eight bus inputs and add them into SFX Master.
    pub fn render(&mut self, inputs: &mut [[[f32; BLOCK]; 6]; 8], master: &mut [[f32; BLOCK]; 6]) {
        for (bus, input) in self.buses.iter_mut().zip(inputs.iter_mut()) {
            {
                let mut planes = input.each_mut().map(|c| &mut c[..]);
                clip(&mut planes, bus.level);
                bus.eq[0].process(&mut planes, 48000.0);
                bus.eq[1].process(&mut planes, 48000.0);
            }
            for (m, s) in master.iter_mut().zip(input.iter()) {
                for (a, b) in m.iter_mut().zip(s.iter()) {
                    *a += b;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rerolls_sit_on_the_11_point_grid_once_per_clear() {
        let mut eq = EqBuses::default();
        let bus0 = EqRecord { enabled: true, clip: 100.0, ranges: [[450.0, 150.0], [1.5, 0.75], [3.0, 0.25], [5000.0, 1500.0], [1.25, 0.9], [2.0, 0.25]] };
        let jittered = EqRecord { enabled: false, ..bus0 };
        eq.set_records(&[bus0, bus0, bus0, bus0, bus0, jittered, jittered, jittered]);
        for _ in 0..50 {
            eq.resolve(0, true);
            let f = eq.buses[0].eq[0].freq;
            let k = (f - 150.0) / 30.0;
            assert!((k - k.round()).abs() < 1e-4 && (0.0..=10.0).contains(&k), "{f}");
            let before = eq.buses[0].eq[0].freq;
            eq.resolve(0, true);
            assert_eq!(eq.buses[0].eq[0].freq, before, "one roll per clear");
            eq.clear(None);
        }
        assert_eq!(eq.rolls, 50);
        eq.resolve(1, false);
        assert_eq!(eq.buses[1].eq[0].gain, 1.0, "no create: class defaults (bypass)");
        eq.clear(Some([5000.0, 30.0, 0.1, 2000.0, 1.75, 3.0]));
        assert_eq!((eq.buses[5].eq[0].freq, eq.buses[5].eq[0].gain, eq.buses[5].eq[0].q), (5000.0, 20.0, 0.2));
        assert_eq!(eq.buses[0].eq[0].gain, eq.buses[0].eq[0].gain);
    }
}
