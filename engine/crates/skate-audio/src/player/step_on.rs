//! `SFXObj_Contacts`' hand-on-deck sounds (`sub_824B85B0`, run by the Contacts process after the
//! deck impact; spec `audio-specs/aems-offboard-clothing-spec.md`). Written from our reading of
//! the retail code (TU3, reference only):
//!
//! - inputs: state `+688` / `+689` = Skeleton `+602` / `+603` (`sub_82BF20C8`, Skeleton::FillPhysOut
//!   `sub_82BE1AE8`): the IK's animated target of hand limb 2 (part 3) / limb 3 (part 7) relative to
//!   the animated board (SkeletonIK `+1792` / `+1856`, translation at `+1840` / `+1904`) strictly
//!   inside the deck box (DeckWidth / 2, 0, DeckFrontEndSize + DeckMidLength / 2) padded by
//!   `physics_skeleton` `A28E50D30B0506A4` = (0.03, 0.03, 0); the bridge clears both while on foot
//!   (category 500) without the board in hand (OffBoard 311) — see [`hands_on_deck`];
//! - a hand coming onto the deck (`sub_824B8310`): the slot's sound restarts, `Skate_Collisions`
//!   1124 in the air (`+332`) or 1125 on the ground (class `923CCB46EF5BF5BA` collection
//!   `E0C3B44AB44F7B90`: `A7B32EC5FF4997F5` / `F17EEB71F18CEAF3`); a hand leaving it
//!   (`sub_824B8448`): 1126 (`A7B7AE2A6C25670F`); both on eEQChain bus 2 (`ED52262DABB5DE4C`,
//!   created by the local player), start block [0, 1, 0, dt, 1, 1];
//! - update (`sub_824BF728`, Contacts): per hand, the on sound at trunc(level(10) × 0.5) / 32767,
//!   the off sound at trunc(level(10) × 0.3) / 32767 (`25DCB888413D570D` = [0.5, 0.3]), pitch(11),
//!   raw(0), no pan spread; a sound that ended is freed.
use super::contacts::SpliceHost;
use super::{AudioState, Outputs, trunc_clamp};
use crate::splice::SoundId;

pub const BANK: &str = "Skate_Collisions";
const LEVEL: f32 = f32::from_bits(0x3800_0100); // 1/32767
const PITCH: f32 = f32::from_bits(0x3980_0000); // 1/4096
const DEGREES: f32 = f32::from_bits(0x3BB4_00B4); // 360/65535

/// The vault values (defaults = retail).
#[derive(Clone, Debug, PartialEq)]
pub struct StepOnTuning {
    /// [in the air, on the ground, hand off].
    pub ids: [u32; 3],
    /// Level scales of the on / off sounds.
    pub levels: [f32; 2],
    pub eq: u8,
}

impl Default for StepOnTuning {
    fn default() -> Self {
        Self { ids: [1124, 1125, 1126], levels: [0.5, 0.3], eq: 2 }
    }
}

/// The bridge's `+688` / `+689` from Skeleton `+602` / `+603` (`sub_824B0DA8`: cleared while on
/// foot (state 500) unless the board is held, OffBoard 311).
pub fn hands_on_deck(skeleton_602_603: [bool; 2], on_foot: bool, board_held: bool) -> [bool; 2] {
    if on_foot && !board_held { [false; 2] } else { skeleton_602_603 }
}

/// Skeleton `+602` / `+603` (`sub_82BF20C8`) from the hands' board-relative IK targets: strict
/// containment in the deck box padded by `physics_skeleton` `A28E50D30B0506A4`.
pub fn hand_in_deck_box(position: [f32; 3], deck_half_width: f32, deck_half_length: f32, padding: [f32; 3]) -> bool {
    let bounds = [deck_half_width + padding[0], 0.0 + padding[1], deck_half_length + padding[2]];
    (0..3).all(|i| bounds[i] > position[i] && position[i] > -bounds[i])
}

/// The default padding (`physics_skeleton` `default` `A28E50D30B0506A4`).
pub const HAND_PADDING: [f32; 3] = [f32::from_bits(0x3CF5_C28F), f32::from_bits(0x3CF5_C28F), 0.0];

#[derive(Clone, Debug, Default, PartialEq)]
pub struct StepOn {
    /// `+376` / `+384` (and the identical `+392` / `+400`): last frame's `+688` / `+689`.
    was: [bool; 2],
    /// `+372` / `+380` the on sounds, `+388` / `+396` the off sounds.
    on: [Option<SoundId>; 2],
    off: [Option<SoundId>; 2],
    pub starts: u64,
}

impl StepOn {
    /// `sub_824B85B0` (rising `+689`, rising `+688`, falling `+689`, falling `+688`).
    pub fn process(&mut self, s: &AudioState, c: &StepOnTuning, host: &mut dyn SpliceHost) {
        let now = s.hands_on_deck;
        let route = crate::bus::Route { output: crate::bus::Output::Eq(c.eq), create: s.local, owner_env: 0.0, mono: false };
        let block = [0.0, 1.0, 0.0, s.dt, 1.0, 1.0];
        for hand in [1usize, 0] {
            if now[hand] && !self.was[hand] {
                if let Some(old) = self.on[hand].take() {
                    host.release(old);
                }
                let id = if s.airborne { c.ids[0] } else { c.ids[1] };
                host.set_route(route);
                self.on[hand] = host.start(BANK, id, block);
                self.starts += u64::from(self.on[hand].is_some());
            }
        }
        for hand in [1usize, 0] {
            if !now[hand] && self.was[hand] {
                if let Some(old) = self.off[hand].take() {
                    host.release(old);
                }
                host.set_route(route);
                self.off[hand] = host.start(BANK, c.ids[2], block);
                self.starts += u64::from(self.off[hand].is_some());
            }
        }
        self.was = now;
    }

    /// `sub_824BF728` (after the MixMap tick; `out` = the Contacts outputs).
    pub fn update(&mut self, s: &AudioState, c: &StepOnTuning, out: &dyn Outputs, host: &mut dyn SpliceHost) {
        let block = |k: f32| -> [f32; 6] {
            let level = trunc_clamp(out.level(10) as f32 * k, i32::MIN, i32::MAX) as f32 * LEVEL;
            [level, out.pitch(11) as f32 * PITCH, out.raw(0) as f32 * DEGREES, s.dt, 0.0, 1.0]
        };
        for hand in 0..2 {
            for (slot, k) in [(&mut self.on[hand], c.levels[0]), (&mut self.off[hand], c.levels[1])] {
                let Some(sound) = *slot else { continue };
                if host.alive(sound) {
                    host.update(sound, block(k));
                } else {
                    host.release(sound);
                    *slot = None;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Log {
        started: Vec<u32>,
        updates: Vec<[f32; 6]>,
    }
    impl SpliceHost for Log {
        fn start(&mut self, _: &str, id: u32, _: [f32; 6]) -> Option<SoundId> {
            self.started.push(id);
            Some(self.started.len())
        }
        fn update(&mut self, _: SoundId, block: [f32; 6]) {
            self.updates.push(block);
        }
        fn alive(&self, _: SoundId) -> bool {
            true
        }
        fn release(&mut self, _: SoundId) {}
    }

    struct Out;
    impl Outputs for Out {
        fn level(&self, id: usize) -> i32 {
            if id == 10 { 20001 } else { 0 }
        }
        fn raw(&self, _: usize) -> i32 {
            0
        }
        fn pitch(&self, _: usize) -> i32 {
            4096
        }
    }

    #[test]
    fn a_hand_on_the_deck_plays_1125_on_the_ground_1124_in_the_air_and_1126_off() {
        let c = StepOnTuning::default();
        let mut k = StepOn::default();
        let mut h = Log::default();
        let mut s = AudioState { hands_on_deck: [false, true], ..Default::default() };
        k.process(&s, &c, &mut h);
        s.airborne = true;
        s.hands_on_deck = [true, true];
        k.process(&s, &c, &mut h);
        s.hands_on_deck = [false, false];
        k.process(&s, &c, &mut h);
        assert_eq!(h.started, [1125, 1124, 1126, 1126]);
        k.update(&s, &c, &Out, &mut h);
        // trunc(20001 × 0.5) = 10000; trunc(20001 × 0.3) = 6000.
        assert_eq!(h.updates[0][0], 10000.0 * LEVEL);
        assert!(h.updates.iter().any(|b| b[0] == 6000.0 * LEVEL));
        assert!(h.updates.iter().all(|b| b[4] == 0.0));
    }

    #[test]
    fn the_bridge_clears_the_hands_on_foot_without_the_board() {
        assert_eq!(hands_on_deck([true, true], true, false), [false; 2]);
        assert_eq!(hands_on_deck([true, false], true, true), [true, false]);
        // 3 cm above the deck plane is still on it; 4 cm is not.
        assert!(hand_in_deck_box([0.0, 0.029, 0.0], 0.1, 0.4, HAND_PADDING));
        assert!(!hand_in_deck_box([0.0, 0.04, 0.0], 0.1, 0.4, HAND_PADDING));
    }
}
