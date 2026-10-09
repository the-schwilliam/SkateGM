//! `SFXObj_Wheels`: the free-spinning wheels — a spin-down recording started part-way in, so a
//! faster board starts nearer the full spin and a slow one near the end. Written from our reading
//! of the retail code (TU3, reference only):
//!
//! - constructor `sub_824CD6F8`: two streams from the wheels collection (class
//!   `0xC1831BDB6CB1B1EA` key `0x03B710C80E1AC13E`): `Whls_spins_Jump_1.snr` (field
//!   `0x044FB3ECB9FCB35F`, length word `0xFD874514FD49261E` = 14 s) and `Whls_spins_Man_1.snr`
//!   (`0x243117D2CD2EDC70`, `0x8CC31309D10F1763` = 14 s);
//! - update `sub_824CDC70` → `sub_824CDD28` per slot: slot 0 while in the air (`+332`), slot 1
//!   while balancing (`+340`), slot 2 for the local player on foot with the off-board byte `+308`
//!   or the loose-board slide `+760` (neither is published by our engine: slot 2 stays off);
//! - on a rising trigger: start the next stream of the two (they alternate, `+96`; the first is
//!   the manual one) at t0 = length × (1 − clamp01(|ground speed| × 3.6 / 50)) seconds (field
//!   `0x4890392C91829954` = 50 km/h; slot 2 clamps the fraction to 0.26), gain 0, pitch 1
//!   (`sub_824CEAF0` → `sub_824CEE00`);
//! - while the trigger holds: a stream that ended stops (and stays stopped); else gain = Wheels
//!   level(1) (level(5) while balancing, (6) with `+308`, (7) with `+760`) / 32767 and pitch =
//!   pitch(2) / 4096; when the trigger drops the stream stops (`sub_824CEF60`).
//!
//! Not modelled: the owner bus (`sub_824CEAF0`'s chain, send level(4)) — the voices mix dry.
use super::{AudioState, Outputs};

/// What the component needs from a stream player (the host plays the two recordings).
pub trait StreamHost {
    /// Start recording `stream` (0 = jump, 1 = manual) at `seek` seconds with gain 0, pitch 1.
    fn start(&mut self, stream: usize, seek: f64) -> Option<u32>;
    fn set(&mut self, voice: u32, gain: f32, pitch: f32);
    fn alive(&self, voice: u32) -> bool;
    fn stop(&mut self, voice: u32);
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WheelsTuning {
    /// `0x4890392C91829954`: the speed (km/h) at which a stream starts at its beginning.
    pub full_kmh: f32,
    /// Start-offset span (s) of the jump / manual streams.
    pub lengths: [f32; 2],
}

impl Default for WheelsTuning {
    fn default() -> Self {
        Self { full_kmh: 50.0, lengths: [14.0, 14.0] }
    }
}

const INV_32767: f32 = f32::from_bits(0x3800_0100);
const INV_4096: f32 = f32::from_bits(0x3980_0000);
/// `0x822F8628`: m/s → km/h.
const KMH: f32 = f32::from_bits(0x4066_6666);
/// `0x8208ECFC`: slot 2's cap on the speed fraction.
const SLOT2_CAP: f32 = f32::from_bits(0x3E85_1EB8);

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Wheels {
    /// `+60..+62` per-slot held flags, the slots' voices, `+96` the stream toggle.
    held: [bool; 3],
    voices: [Option<u32>; 3],
    toggle: bool,
    /// Streams started (diagnostics).
    pub starts: u64,
}

impl Wheels {
    /// The start offset (s) of a stream for a board at `speed` m/s.
    pub fn offset(t: &WheelsTuning, stream: usize, speed: f32, slot: usize) -> f32 {
        let x = speed.abs() / t.full_kmh * KMH;
        let x = if -x >= 0.0 { 0.0 } else { x };
        let mut x = if 1.0 - x >= 0.0 { x } else { 1.0 };
        if slot == 2 && x > SLOT2_CAP {
            x = SLOT2_CAP;
        }
        t.lengths[stream] * (1.0 - x)
    }

    /// `sub_824CDC70`, after the MixMap tick (Wheels owner outputs).
    pub fn update(&mut self, s: &AudioState, out: &dyn Outputs, t: &WheelsTuning, host: &mut dyn StreamHost) {
        let slot2 = s.local && s.on_foot && s.offboard_308;
        for (slot, trigger) in [s.airborne, s.balance, slot2].into_iter().enumerate() {
            self.slot(slot, trigger, s, out, t, host);
        }
    }

    fn slot(&mut self, slot: usize, trigger: bool, s: &AudioState, out: &dyn Outputs, t: &WheelsTuning, host: &mut dyn StreamHost) {
        if !self.held[slot] {
            if !trigger {
                return;
            }
            self.held[slot] = true;
            let stream = if self.toggle { 0 } else { 1 };
            self.toggle = !self.toggle;
            let seek = Self::offset(t, stream, s.ground_speed, slot);
            if self.voices[slot].is_none() {
                self.voices[slot] = host.start(stream, f64::from(seek));
                self.starts += u64::from(self.voices[slot].is_some());
            }
            return;
        }
        if !trigger {
            if let Some(v) = self.voices[slot].take() {
                host.stop(v);
            }
            self.held[slot] = false;
            return;
        }
        let Some(v) = self.voices[slot] else { return };
        if !host.alive(v) {
            host.stop(v);
            self.voices[slot] = None;
            return;
        }
        let id = if s.balance {
            5
        } else if s.offboard_308 {
            6
        } else {
            1
        };
        host.set(v, out.level(id) as f32 * INV_32767, out.pitch(2) as f32 * INV_4096);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Log {
        started: Vec<(usize, f64)>,
        live: Vec<u32>,
        sets: Vec<(u32, f32, f32)>,
    }
    impl StreamHost for Log {
        fn start(&mut self, stream: usize, seek: f64) -> Option<u32> {
            self.started.push((stream, seek));
            let id = self.started.len() as u32;
            self.live.push(id);
            Some(id)
        }
        fn set(&mut self, voice: u32, gain: f32, pitch: f32) {
            self.sets.push((voice, gain, pitch));
        }
        fn alive(&self, voice: u32) -> bool {
            self.live.contains(&voice)
        }
        fn stop(&mut self, voice: u32) {
            self.live.retain(|v| *v != voice);
        }
    }
    struct Out;
    impl Outputs for Out {
        fn level(&self, id: usize) -> i32 {
            1000 * id as i32
        }
        fn raw(&self, _: usize) -> i32 {
            0
        }
        fn pitch(&self, _: usize) -> i32 {
            4096
        }
    }

    #[test]
    fn the_offset_follows_the_speed() {
        let t = WheelsTuning::default();
        assert_eq!(Wheels::offset(&t, 0, 0.0, 0), 14.0);
        assert!((Wheels::offset(&t, 0, 25.0 / 3.6, 0) - 7.0).abs() < 1e-3);
        assert_eq!(Wheels::offset(&t, 0, 20.0, 0), 0.0, "above 50 km/h the spin starts at the top");
        assert!((Wheels::offset(&t, 0, 20.0, 2) - 14.0 * (1.0 - SLOT2_CAP)).abs() < 1e-5);
    }

    #[test]
    fn a_jump_spins_the_wheels_down_until_landing() {
        let t = WheelsTuning::default();
        let mut w = Wheels::default();
        let mut h = Log::default();
        let roll = AudioState { ground_speed: 25.0 / 3.6, wheel_count: 4, ..Default::default() };
        let air = AudioState { airborne: true, wheel_count: 0, ..roll };
        w.update(&roll, &Out, &t, &mut h);
        assert!(h.started.is_empty());
        w.update(&air, &Out, &t, &mut h);
        // The first stream is the manual one, 7 s in at 25 km/h.
        assert_eq!(h.started.len(), 1);
        assert_eq!(h.started[0].0, 1);
        assert!((h.started[0].1 - 7.0).abs() < 1e-3);
        w.update(&air, &Out, &t, &mut h);
        assert_eq!(h.sets.last().copied(), Some((1, 1000.0 * INV_32767, 1.0)), "level(1), pitch(2)");
        w.update(&roll, &Out, &t, &mut h);
        assert!(h.live.is_empty(), "landing stops it");
        w.update(&air, &Out, &t, &mut h);
        assert_eq!(h.started[1].0, 0, "the streams alternate");
    }

    #[test]
    fn a_manual_spins_the_lifted_wheels() {
        let t = WheelsTuning::default();
        let mut w = Wheels::default();
        let mut h = Log::default();
        let manual = AudioState { ground_speed: 4.0, wheel_count: 2, balance: true, ..Default::default() };
        w.update(&manual, &Out, &t, &mut h);
        w.update(&manual, &Out, &t, &mut h);
        assert_eq!(h.sets.last().map(|s| s.1), Some(5000.0 * INV_32767), "level(5) while balancing");
    }
}
