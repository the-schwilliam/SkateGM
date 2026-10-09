//! The Tricks component (component vtable `0x822FC7B8`, owner = the Tricks controller
//! `0x40010050`): the trick whoosh `Class_Flips` (`Sk8_Air_Flip_Tricks.abk`) and the two clothing
//! rustles `cloth_trick` (`Foley_Cloth.abk`). Written from our reading of the retail code (TU3,
//! reference only); spec `audio-specs/aems-tricks-treatment-spec.md`.
//!
//! - constructor `sub_824CBD98`: `+48..+60` = −1 (last trick id, flips id, cloth id, second id),
//!   `+64` / `+68` / `+84` = 0.0, `+72` = 0, the held objects `+36` / `+40` / `+44` empty;
//! - process `sub_824CBEB0(dt)`, only for the local player (`[this+28]+72`): `+60 := +352` while
//!   `+348 ≠ −1`; the flip poster `sub_824CBFB8`; cloth A `sub_824CC590`; cloth B `sub_824CC680`;
//!   `+48 := +348`; `+68` counts down by dt to 0; the slew `sub_824CD170`; `sub_824CD390` (game
//!   events 24685…24697 to the trick-event system, no audio: not modelled);
//! - update `sub_824CBF78`: the flip keep/rewrite `sub_824CC7D8`, cloth A `sub_824CCE48`, cloth B
//!   `sub_824CCFE8`.
//!
//! When retail posts (recomp session 164620, 65 Class_Flips / 50 + 31 cloth_trick posts): cloth A
//! as soon as the scorable's audio trick (`+348`) is set — about 215 ms (13 frames) before the
//! board leaves the ground; Class_Flips on the first frame in the air (`+332`) with the trick active
//! (`+343`), one frame (median 16.7 ms) after the pop's jump-velocity write; it is held while in the
//! air with the same trick and released at the landing (or rewritten for a new trick in the air);
//! cloth B when `+348` returns to −1 (the trick's end), held for as long as the trick lasted.
use super::globals::Globals;
use super::{AudioState, Outputs, trunc_clamp};
use crate::player::components::{Command, Slot};

pub const FLIPS: &str = "Class_Flips";
pub const CLOTH: &str = "cloth_trick";
/// The banks the component posts into. `Foley_Cloth`'s `c_foley_utility` is posted once at boot
/// in retail (session posts: object 20 once), like `c_emitter_utility`.
pub const BANKS: &[&str] = &["Sk8_Air_Flip_Tricks", "Foley_Cloth"];
pub const FOLEY_UTILITY: &str = "c_foley_utility";

const FLIP_WORDS: usize = 28;
const CLOTH_WORDS: usize = 11;
/// `0x82256FE8` 1000.0 and `0x820BD5C4` 500.0 (the time-scale word).
const THOUSAND: f32 = f32::from_bits(0x447A_0000);
const TIME_SCALE_WORD: f32 = f32::from_bits(0x43FA_0000);

/// Vault words: the audio tuning holder `*(0x830CFDA4)+72` = class `0xC1831BDB6CB1B1EA` collection
/// `tricks` (`0x1FA8AC006CABEF59`), the slew collection `0x47EC76B4F9FC79F6` of the same class
/// (`sub_824CD170`), and eEQChain (`*(0x830CFDA4)+140` = class `0x42AFE160E647167C` `default`).
/// Defaults: the user's vault.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TricksTuning {
    /// Per deck axis (`+480` Ri, `+484` Up, `+488` At) the spin word threshold (int; below it the
    /// word is 0) and divisor (rad/s → 1000): Ri `5C73CF6A0D50C8D8` = 297 / `1494BB20854C155C` = 3.0,
    /// Up `EE157886DE5D3C97` = 703 / `02D39586635FB1A3` = 4.4, At `9A0316625B63CD99` = 603 /
    /// `8EDBACCBA6FE46AD` = 10.2.
    pub spin_threshold: [i32; 3],
    pub spin_divisor: [f32; 3],
    /// Class_Flips w17 `99E6FF024834E4C7` = 27646, w18 `D2D0EBAC43842F6D` = 14848, w19
    /// `13C155A181A55BA4` = 6656, w21 `B565D4D763128252` = 10000.
    pub levels: [i32; 4],
    /// The slew targets by `G+96` bit 15 / 14 / 13 (`B601DFAB3AF7DE66` = 250, `08441EA8E8019665` =
    /// 700, `36F8D12486A929D1` = 1000) and its rates per second down `6B57BD44C0E0B267` = 1000.0 and
    /// up `57AED5FBC374D8F1` = 10000.0.
    pub slew_targets: [i32; 3],
    pub slew_down: f32,
    pub slew_up: f32,
    /// eEQChain `D9BE1F2F1A72FEE8` (Class_Flips w27) = 6, `4B6E2D79A8452D9B` (cloth_trick w10) = 0.
    pub flips_eq: i32,
    pub cloth_eq: i32,
}

impl Default for TricksTuning {
    fn default() -> Self {
        Self {
            spin_threshold: [297, 703, 603],
            spin_divisor: [f32::from_bits(0x4040_0000), f32::from_bits(0x408C_CCCD), f32::from_bits(0x4123_3333)],
            levels: [27646, 14848, 6656, 10000],
            slew_targets: [250, 700, 1000],
            slew_down: 1000.0,
            slew_up: 10000.0,
            flips_eq: 6,
            cloth_eq: 0,
        }
    }
}

/// The audio trick ids Class_Flips is never posted for: none, 35 and 36 (grabs, coffin).
const NO_FLIPS: [i32; 3] = [-1, 35, 36];
/// The flip id while the off-board hold has run out on the ground (`+310`).
const OFFBOARD_TRICK: i32 = 34;

#[derive(Clone, Debug, PartialEq)]
pub struct Tricks {
    flips: Option<Vec<i32>>,
    cloth_a: Option<Vec<i32>>,
    cloth_b: Option<Vec<i32>>,
    /// `+48` last frame's `+348`, `+52` the posted flip id, `+56` cloth A's id, `+60` the latched
    /// `+352`.
    last_id: i32,
    flips_id: i32,
    cloth_a_id: i32,
    id_352: i32,
    /// `+64` the running trick's time, `+68` cloth B's remaining time.
    trick_time: f32,
    cloth_b_time: f32,
    /// `+72` the slewed w12.
    slew: i32,
}

impl Default for Tricks {
    fn default() -> Self {
        Self {
            flips: None,
            cloth_a: None,
            cloth_b: None,
            last_id: -1,
            flips_id: -1,
            cloth_a_id: -1,
            id_352: -1,
            trick_time: 0.0,
            cloth_b_time: 0.0,
            slew: 0,
        }
    }
}

/// One spin word of the deck's angular velocity about an axis: trunc(|v| / divisor × 1000), capped
/// at 1000, then 0 below the threshold (retail's subf / xoris / addc / subfe select).
pub fn spin_word(v: f32, divisor: f32, threshold: i32) -> i32 {
    let x = trunc_clamp((v.abs() / divisor) * THOUSAND, i32::MIN, i32::MAX).min(1000);
    let carry = (u64::from(x.wrapping_sub(threshold) as u32) + u64::from(threshold as u32 ^ 0x8000_0000)) >> 32;
    if carry != 0 { 0 } else { x }
}

/// The time-scale word (w10 of Class_Flips and Class_Treatment): trunc(`+220` × 500), 0..1000.
pub fn time_scale_word(s: &AudioState) -> i32 {
    trunc_clamp(s.time_scale * TIME_SCALE_WORD, i32::MIN, i32::MAX).clamp(0, 1000)
}

fn cloth_words(id: i32, eq: i32) -> Vec<i32> {
    // sub_824B71C0.
    let mut w = vec![0i32; CLOTH_WORDS];
    w[2] = 4096;
    w[4] = 25000;
    w[8] = 1;
    w[9] = id.clamp(0, 40);
    w[10] = eq.clamp(0, 32767);
    w
}

impl Tricks {
    fn spins(s: &AudioState, t: &TricksTuning) -> [i32; 3] {
        let v = [s.deck_spin_xy[0], s.deck_spin_xy[1], s.deck_spin];
        std::array::from_fn(|i| spin_word(v[i], t.spin_divisor[i], t.spin_threshold[i]))
    }

    /// `+310` on the ground for the local player: the flip id becomes 34.
    fn offboard(s: &AudioState) -> bool {
        !s.airborne && s.local && s.offboard_310
    }

    /// `sub_824CBFB8` + the constructor `sub_824AFAD8`.
    fn flip_poster(&mut self, s: &AudioState, t: &TricksTuning, out: &dyn Outputs, cmds: &mut Vec<Command>) {
        let off = Self::offboard(s);
        let go = if s.airborne { s.trick_active } else { off };
        if !go || self.flips.is_some() {
            return;
        }
        self.flips_id = if off { OFFBOARD_TRICK } else { s.audio_trick };
        if NO_FLIPS.contains(&self.flips_id) {
            return;
        }
        let [x, y, z] = Self::spins(s, t);
        let mut w = vec![0i32; FLIP_WORDS];
        w[1] = 32767;
        w[4] = 4096;
        w[5] = 25000;
        w[7] = z.clamp(0, 1000);
        w[8] = y.clamp(0, 1000);
        w[9] = x.clamp(0, 1000);
        w[10] = time_scale_word(s);
        w[11] = self.flips_id.clamp(0, 40);
        w[16] = i32::from(!s.global_224);
        w[17] = t.levels[0].clamp(0, 32767);
        w[18] = t.levels[1].clamp(0, 32767);
        w[19] = t.levels[2].clamp(0, 32767);
        w[21] = t.levels[3].clamp(0, 32767);
        w[23] = 0; // bool class 0x11A631878B239355 (global setting, not modelled)
        w[24] = i32::from(s.local); // local && [[owner+16]+64] == 0
        w[25] = i32::from(s.local);
        w[26] = if s.local { out.level(6).clamp(0, 32767) } else { 0 };
        w[27] = t.flips_eq.clamp(0, 32767);
        cmds.push(Command::Post { slot: Slot::Flips, class: FLIPS, words: w.clone() });
        self.flips = Some(w);
    }

    /// `sub_824CC590`: cloth A follows `+348` (a new id releases it; the next frame posts again).
    fn cloth_a(&mut self, id: i32, t: &TricksTuning, cmds: &mut Vec<Command>) {
        if id == -1 {
            return;
        }
        if self.cloth_a.is_none() {
            let w = cloth_words(id, t.cloth_eq);
            cmds.push(Command::Post { slot: Slot::Cloth(0), class: CLOTH, words: w.clone() });
            self.cloth_a = Some(w);
            self.cloth_a_id = id;
        } else if id != self.cloth_a_id {
            self.cloth_a = None;
            cmds.push(Command::Release { slot: Slot::Cloth(0) });
        }
    }

    /// `sub_824CC680`: cloth B with the latched second id when the trick ends, held for the
    /// trick's duration.
    fn cloth_b(&mut self, id: i32, dt: f32, t: &TricksTuning, cmds: &mut Vec<Command>) {
        let mut ended = false;
        if id != -1 {
            self.trick_time += dt;
        } else if self.last_id != -1 {
            self.cloth_b_time = self.trick_time;
            self.trick_time = 0.0;
            ended = true;
        }
        if self.cloth_b_time > 0.0 {
            if self.id_352 == -1 || !ended {
                return;
            }
            if self.cloth_b.take().is_some() {
                cmds.push(Command::Release { slot: Slot::Cloth(1) });
            }
            let w = cloth_words(self.id_352, t.cloth_eq);
            cmds.push(Command::Post { slot: Slot::Cloth(1), class: CLOTH, words: w.clone() });
            self.cloth_b = Some(w);
        } else if self.cloth_b.take().is_some() {
            cmds.push(Command::Release { slot: Slot::Cloth(1) });
        }
    }

    /// `sub_824CD170`: w12 slews toward the `G+96` target (down 1000/s, up 10000/s; 0 with dt ≤ 0).
    fn slew(&mut self, dt: f32, t: &TricksTuning, g: &Globals) {
        if dt <= 0.0 {
            self.slew = 0;
            return;
        }
        let target = if g.slew_full() {
            t.slew_targets[2]
        } else {
            super::globals::SLEW_BITS.iter().position(|&b| g.flags_96 & b != 0).map_or(0, |i| t.slew_targets[i])
        };
        let down = trunc_clamp(t.slew_down * dt, i32::MIN, i32::MAX);
        let up = trunc_clamp(t.slew_up * dt, i32::MIN, i32::MAX);
        let cur = self.slew;
        self.slew = if target < cur {
            if cur - target > down { cur - down } else { target }
        } else if target > cur && target - cur > up {
            cur + up
        } else {
            target
        };
    }

    /// Process (before the MixMap tick), `sub_824CBEB0`. `out` = the Tricks owner's outputs.
    pub fn process(&mut self, s: &AudioState, t: &TricksTuning, g: &Globals, out: &dyn Outputs) -> Vec<Command> {
        let mut cmds = Vec::new();
        if !s.local {
            return cmds;
        }
        let id = s.audio_trick;
        if id != -1 {
            self.id_352 = s.audio_trick_2;
        }
        self.flip_poster(s, t, out, &mut cmds);
        self.cloth_a(id, t, &mut cmds);
        self.cloth_b(id, s.dt, t, &mut cmds);
        self.last_id = id;
        self.cloth_b_time = if self.cloth_b_time > 0.0 { self.cloth_b_time - s.dt } else { 0.0 };
        self.slew(s.dt, t, g);
        cmds
    }

    fn cloth_update(w: &mut [i32], out: &dyn Outputs) {
        w[0] = 32767;
        w[4] = 25000;
        w[5] = 0;
        w[6] = 0;
        w[7] = out.level(4).clamp(0, 32767);
        w[1] = out.raw(0).clamp(0, 65535);
        w[2] = out.pitch(5).clamp(0, 8192);
    }

    /// Update (after the tick), `sub_824CBF78`.
    pub fn update(&mut self, s: &AudioState, t: &TricksTuning, out: &dyn Outputs) -> Vec<Command> {
        let mut cmds = Vec::new();
        // sub_824CC7D8: keep the flip while in the air (or off board) with the same id.
        let off = Self::offboard(s);
        let id = if off { OFFBOARD_TRICK } else { s.audio_trick };
        if !(s.airborne || off) || id != self.flips_id {
            if self.flips.take().is_some() {
                cmds.push(Command::Release { slot: Slot::Flips });
            }
        } else if let Some(w) = self.flips.as_mut() {
            let [x, y, z] = Self::spins(s, t);
            w[9] = x.clamp(0, 1000);
            w[8] = y.clamp(0, 1000);
            w[7] = z.clamp(0, 1000);
            w[10] = time_scale_word(s);
            w[4] = out.pitch(2).clamp(0, 8192);
            w[0] = out.level(1).clamp(0, 32767);
            w[3] = out.raw(0).clamp(0, 65536);
            w[1] = 32767;
            w[2] = 0;
            w[5] = out.level(3).clamp(0, 25000);
            w[6] = 0;
            w[16] = i32::from(!s.global_224);
            w[26] = if s.local { out.level(6).clamp(0, 32767) } else { 0 };
            w[20] = out.level(8).clamp(0, 32767);
            w[22] = out.level(7).clamp(0, 32767);
            w[12] = self.slew.clamp(0, 1000);
            cmds.push(Command::Redeliver { slot: Slot::Flips, words: w.clone() });
        }
        // sub_824CCE48: cloth A ends with a bail, or with no trick on the ground.
        if self.cloth_a.is_some() {
            if s.bail || (s.audio_trick == -1 && !s.airborne) {
                self.cloth_a = None;
                cmds.push(Command::Release { slot: Slot::Cloth(0) });
            } else if let Some(w) = self.cloth_a.as_mut() {
                Self::cloth_update(w, out);
                cmds.push(Command::Redeliver { slot: Slot::Cloth(0), words: w.clone() });
            }
        }
        // sub_824CCFE8: cloth B ends with a bail (or its time, in the process).
        if self.cloth_b.is_some() {
            if s.bail {
                self.cloth_b = None;
                cmds.push(Command::Release { slot: Slot::Cloth(1) });
            } else if let Some(w) = self.cloth_b.as_mut() {
                Self::cloth_update(w, out);
                cmds.push(Command::Redeliver { slot: Slot::Cloth(1), words: w.clone() });
            }
        }
        cmds
    }
}

#[cfg(test)]
mod tests;
