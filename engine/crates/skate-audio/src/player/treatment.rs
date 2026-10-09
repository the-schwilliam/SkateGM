//! `Class_Treatment` (component vtable `0x822FCDA0`, owner = the Treatments controller
//! `0x40010070`, `Treatments.abk`): one packet posted for the player's life that streams the air
//! words (time in the air, predicted time to the landing, jump height); its program plays the
//! pre-landing treatment (retail session 164620: Treatments streams 13 and 14 start a median ~230 ms
//! before the wheels touch down). Written from our reading of the retail code (TU3, reference only);
//! spec `audio-specs/aems-tricks-treatment-spec.md`.
//!
//! - process `sub_824DD408`, local player only (`[this+28]+72`): while `+36` is empty, the
//!   constructor `sub_824B0080` builds and posts the 92-byte object (never released); then the
//!   `hall_of_meat_slo_mo` companion (`+40`, constructor `sub_824AF368`, 15 words) is held while
//!   (`G+96` bit 26 and not `sub_8279E180(G)` and the time scale `+220` < 1.0) or the game-flow mode
//!   `X+1060` ≠ 7, and released otherwise — never in free skate (no retail session posts it);
//! - update `sub_824DD6F0`: rewrites the Treatment packet (and the companion) from the Treatments
//!   owner's outputs and redelivers them.
use super::globals::{Globals, SLO_MO_BIT};
use super::tricks::time_scale_word;
use super::{AudioState, Outputs, clamp01, trunc_clamp};
use crate::player::components::{Command, Slot};

pub const CLASS: &str = "Class_Treatment";
pub const HOM_CLASS: &str = "hall_of_meat_slo_mo";
/// The bank `Class_Treatment` binds to (not exported by setup before this port; add it to
/// `audio_export.BANKS`). The companion's bank was not identified (not posted in free skate).
pub const BANKS: &[&str] = &["Treatments"];

const WORDS: usize = 22;
const HOM_WORDS: usize = 15;
/// `0x82256FE8` 1000.0, `0x821161A0` 10000.0, `0x822F9408` 166.66667 (jump height → 1000 at 6 m),
/// `0x8231A844` 1.0.
const THOUSAND: f32 = f32::from_bits(0x447A_0000);
const TEN_THOUSAND: f32 = f32::from_bits(0x461C_4000);
const HEIGHT_SCALE: f32 = f32::from_bits(0x4326_AAAB);
const ONE: f32 = f32::from_bits(0x3F80_0000);

/// Vault words: the audio tuning holder `*(0x830CFDA4)+68` = class `0xC1831BDB6CB1B1EA`
/// collection `0xEE7B8A8A893A4E30`. Defaults: the user's vault.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TreatmentTuning {
    /// w15 `32F9111CBF746F34` = 7000, w16 `E4BC6FE030A553C4` = 28000, w17 `1F11951C2AF58CC7` = 32767.
    pub levels: [i32; 3],
    /// The companion's speed divisor `5A49D603680EE3FF` = 40.0 (m/s of `+212` → w12).
    pub hom_speed: f32,
}

impl Default for TreatmentTuning {
    fn default() -> Self {
        Self { levels: [7000, 28000, 32767], hom_speed: 40.0 }
    }
}

/// The block `B = *(*(0x83083C38) + 0x2FCB4)` whose `+16` sub-object (reset by `sub_827AB6E0`)
/// the updater reads: `B+16` (the byte PlayerPhysics.in11 also reads, set for a while after a bail
/// in upstream PR #4's capture), `B+24` (f32), `B+164` (byte), `B+168` (f32). The sub-object is the
/// VisualDirector's decoded presentation packet (`sub_827AB790`, one field per header slot):
/// `B+164` / `B+168` = the teleport effect field (present on frames whose packet carried
/// `cMsgTeleportEffectAmount`, the amount): the session marker's Go To Marker hold ramps it 0 → 1
/// and the Treatments program answers with its teleport crackle (slots 1–12 while on, slot 0 at
/// 1.0). `B+16` / `B+24` keep their reset values (that field's writer is not ported). Defaults: the
/// reset values (w11 = w12 = 0, w13 keeps 0). (Upstream PR #4's capture reported `B+164` set with
/// `B+168` ≈ 1.0 for most of play: not what the recomp shows; it is set only during the hold.)
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TreatmentGlobals {
    pub flag_16: bool,
    pub value_24: f32,
    pub flag_164: bool,
    pub value_168: f32,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Treatment {
    held: Option<Vec<i32>>,
    hom: Option<Vec<i32>>,
}

impl Treatment {
    /// `sub_824B0080`.
    fn words(s: &AudioState, t: &TreatmentTuning) -> Vec<i32> {
        let mut w = vec![0i32; WORDS];
        w[1] = 32767;
        w[4] = 4096;
        w[5] = 25000;
        w[10] = 500;
        w[15] = t.levels[0].clamp(0, 32767);
        w[16] = t.levels[1].clamp(0, 32767);
        w[17] = t.levels[2].clamp(0, 32767);
        w[18] = 0; // bool class 0x11A631878B239355 through sub_82484460 (global setting, not modelled)
        w[19] = i32::from(s.local); // local && [[owner+28]+64] == 0
        w[20] = i32::from(s.local);
        w[21] = 8;
        w
    }

    fn hom_words(level3: i32, mode: i32) -> Vec<i32> {
        // sub_824AF368.
        let mut w = vec![0i32; HOM_WORDS];
        w[2] = 4096;
        w[3] = 25000;
        w[6] = 32767;
        w[9] = 1;
        w[10] = level3.clamp(0, 32767);
        w[11] = 8;
        w[14] = (mode - 7).clamp(0, 3);
        w
    }

    /// Process (before the MixMap tick). `out` = the Treatments owner's outputs.
    pub fn process(&mut self, s: &AudioState, t: &TreatmentTuning, g: &Globals, out: &dyn Outputs) -> Vec<Command> {
        let mut cmds = Vec::new();
        if !s.local {
            return cmds;
        }
        if self.held.is_none() {
            let w = Self::words(s, t);
            cmds.push(Command::Post { slot: Slot::Treatment, class: CLASS, words: w.clone() });
            self.held = Some(w);
        }
        // sub_8279E180(G) (the world's +112 child through its vfunc 16) is taken as false.
        let slo_mo = g.flags_96 & SLO_MO_BIT != 0 && s.time_scale < ONE;
        if slo_mo || g.mode_1060 != 7 {
            if self.hom.is_none() {
                let w = Self::hom_words(out.level(3), g.mode_1060);
                cmds.push(Command::Post { slot: Slot::HomSloMo, class: HOM_CLASS, words: w.clone() });
                self.hom = Some(w);
            }
        } else if self.hom.take().is_some() {
            cmds.push(Command::Release { slot: Slot::HomSloMo });
        }
        cmds
    }

    /// Update (after the tick), `sub_824DD6F0`.
    pub fn update(&mut self, s: &AudioState, b: &TreatmentGlobals, t: &TreatmentTuning, out: &dyn Outputs) -> Vec<Command> {
        let mut cmds = Vec::new();
        if let Some(w) = self.held.as_mut() {
            w[0] = out.level(2).clamp(0, 32767);
            w[3] = out.raw(0).clamp(0, 65535);
            w[4] = out.pitch(1).clamp(0, 8192);
            w[10] = time_scale_word(s);
            w[14] = i32::from(!s.global_224);
            w[7] = trunc_clamp(s.air_time * THOUSAND, i32::MIN, i32::MAX).clamp(0, 10000);
            w[8] = trunc_clamp(s.air_until_landing * THOUSAND, i32::MIN, i32::MAX).clamp(0, 10000);
            // trunc(min(max(h × 166.67, 0), 1000)): fsel pairs, NaN passes through.
            let h = s.jump_height * HEIGHT_SCALE;
            let h = if -h >= 0.0 { 0.0 } else { h };
            let h = if THOUSAND - h >= 0.0 { h } else { THOUSAND };
            w[9] = trunc_clamp(h, i32::MIN, i32::MAX).clamp(0, 10000);
            w[12] = 0;
            w[11] = 0;
            if b.flag_16 {
                w[11] = trunc_clamp(b.value_24 * THOUSAND, i32::MIN, i32::MAX).clamp(0, 1000);
            }
            if b.flag_164 {
                w[12] = 1;
                w[13] = trunc_clamp(b.value_168 * TEN_THOUSAND, i32::MIN, i32::MAX).clamp(0, 10000);
            }
            cmds.push(Command::Redeliver { slot: Slot::Treatment, words: w.clone() });
        }
        if let Some(w) = self.hom.as_mut() {
            w[0] = 32767;
            w[7] = out.level(4).clamp(0, 32767);
            w[8] = out.level(5).clamp(0, 32767);
            w[13] = out.level(6).clamp(0, 32767);
            w[10] = out.level(3).clamp(0, 32767);
            w[12] = trunc_clamp(clamp01(s.com_speed() / t.hom_speed) * TEN_THOUSAND, i32::MIN, i32::MAX).clamp(0, 10000);
            cmds.push(Command::Redeliver { slot: Slot::HomSloMo, words: w.clone() });
        }
        cmds
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixed;
    impl Outputs for Fixed {
        fn level(&self, id: usize) -> i32 {
            1000 + id as i32
        }
        fn raw(&self, _: usize) -> i32 {
            70000
        }
        fn pitch(&self, _: usize) -> i32 {
            4096
        }
    }

    #[test]
    fn posts_once_for_the_local_player_and_never_releases() {
        let (t, g) = (TreatmentTuning::default(), Globals::default());
        let mut k = Treatment::default();
        let s = AudioState::default();
        let cmds = k.process(&s, &t, &g, &Fixed);
        let [Command::Post { slot: Slot::Treatment, class, words }] = &cmds[..] else { panic!("{cmds:?}") };
        assert_eq!(*class, "Class_Treatment");
        assert_eq!(words.len(), 22);
        assert_eq!(
            words[..],
            [0, 32767, 0, 0, 4096, 25000, 0, 0, 0, 0, 500, 0, 0, 0, 0, 7000, 28000, 32767, 0, 1, 1, 8]
        );
        for _ in 0..10 {
            assert!(k.process(&s, &t, &g, &Fixed).is_empty(), "held, no companion in free skate");
        }
        let remote = AudioState { local: false, ..Default::default() };
        assert!(Treatment::default().process(&remote, &t, &g, &Fixed).is_empty());
    }

    #[test]
    fn update_streams_the_air_words() {
        let (t, g) = (TreatmentTuning::default(), Globals::default());
        let mut k = Treatment::default();
        let s = AudioState { airborne: true, air_time: 0.4, air_until_landing: 0.25, jump_height: 1.2, ..Default::default() };
        k.process(&s, &t, &g, &Fixed);
        let cmds = k.update(&s, &TreatmentGlobals::default(), &t, &Fixed);
        let [Command::Redeliver { words: w, .. }] = &cmds[..] else { panic!() };
        // 1.2 m × 166.67 = 200; 0.4 s → 400; 0.25 s → 250.
        assert_eq!((w[0], w[3], w[4], w[7], w[8], w[9], w[10], w[14]), (1002, 65535, 4096, 400, 250, 200, 500, 1));
        assert_eq!((w[11], w[12], w[13]), (0, 0, 0));
        // The height word saturates at 1000 (6 m); the time words at 10000.
        let s = AudioState { jump_height: 9.0, air_time: 20.0, ..s };
        let cmds = k.update(&s, &TreatmentGlobals { flag_16: true, value_24: 0.5, flag_164: true, value_168: 1.0 }, &t, &Fixed);
        let [Command::Redeliver { words: w, .. }] = &cmds[..] else { panic!() };
        assert_eq!((w[7], w[9], w[11], w[12], w[13]), (10000, 1000, 500, 1, 10000));
    }

    #[test]
    fn the_slow_motion_companion_follows_mode_and_time_scale() {
        let t = TreatmentTuning::default();
        let mut k = Treatment::default();
        let mut s = AudioState::default();
        let slo = Globals { flags_96: SLO_MO_BIT, mode_1060: 7 };
        k.process(&s, &t, &slo, &Fixed);
        s.time_scale = 0.25;
        let cmds = k.process(&s, &t, &slo, &Fixed);
        let [Command::Post { slot: Slot::HomSloMo, class, words }] = &cmds[..] else { panic!("{cmds:?}") };
        assert_eq!((*class, words[10], words[14]), ("hall_of_meat_slo_mo", 1003, 0));
        s.time_scale = 1.0;
        assert_eq!(k.process(&s, &t, &slo, &Fixed), vec![Command::Release { slot: Slot::HomSloMo }]);
        let hom = Globals { flags_96: 0, mode_1060: 9 };
        let cmds = k.process(&s, &t, &hom, &Fixed);
        let [Command::Post { words, .. }] = &cmds[..] else { panic!() };
        assert_eq!(words[14], 2);
        s.com_velocity = [20.0, 0.0, 0.0];
        let up = k.update(&s, &TreatmentGlobals::default(), &t, &Fixed);
        let Command::Redeliver { slot: Slot::HomSloMo, words } = &up[1] else { panic!() };
        assert_eq!((words[0], words[7], words[8], words[10], words[12], words[13]), (32767, 1004, 1005, 1003, 5000, 1006));
    }
}
