//! The player components that post AEMS classes (the board, grind, foot-drag and speed sounds),
//! as pure state machines: `process` (before the MixMap tick: posts and releases) and `update`
//! (after it: rewrite the held packets from the owner's MixMap outputs and redeliver) return
//! [`Command`]s the host applies to the runtime. Each packet is the class's payload words (the
//! object minus its 4-byte header), built exactly as retail's constructor and updater write them.
//!
//! Ported so far (retail functions read in the TU3 recompilation, word tables cross-checked with
//! upstream PR #4's driver notes):
//! - [`Grind`] `Class_grind` (`GRINDS.abk`), owner `SFXObj_Rail`: poster `sub_824C28B0`, constructor
//!   `sub_824AF8C8`, updater `sub_824C39E0`, levels `sub_824C2E48` / `sub_824C2D00`.
//! - [`SenseOfSpeed`] `SenseOfSpeed_rattle` / `SenseOfSpeed_wind` (`sense_of_speed.abk`), owner
//!   `SFXObj_SenseOfSpeed`: process `sub_824E7980`, update `sub_824E7CB0`, constructors
//!   `sub_824B0520` / `sub_824B0388`.
//! - [`FootDrag`] `Class_foot_drag` (`FOOT_DRAG.abk`), owner `SFXObj_Contacts`: trigger
//!   `sub_824BB540`, constructor `sub_824AF498`, updater `sub_824BEEE8`, surface `sub_824BA390`.
//!
//! Not modelled (marked in the words): the bool-class word (`0x11A631878B239355` through a global
//! setting; 0 in free skate as far as we know) and `[[owner+16]+64]` (taken as 0 for the local
//! player).
use super::state::NO_MATERIAL;
use super::tuning::PlayerTuning;
use super::{AudioState, Outputs, clamp01, trunc_clamp};

/// Which held packet a command is about.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Slot {
    /// Class_grind main layer (`+36`) and the layer-1 companion of grind family 0 (`+40`).
    Grind(u8),
    Rattle,
    Wind,
    FootDrag,
    Skid,
    Squeaks,
    /// `Class_Seams`' per-wheel packet (`player::seams`).
    Seam(u8),
    /// `Class_rolling`'s per-truck surface patch (`player::rolling`, owner `+1312 + 4·truck`).
    RollingSurface(u8),
    /// `Class_rolling`'s held layers 0 / 3 (`+1304` / `+1308`) and the spidercrack layer 5 (`+1332`).
    RollingLayer(u8),
    /// `Rolling_Rattle_Class` (`+1300`).
    RollingRattle,
    /// `c_board_slide` (`+1884`).
    BoardSlide,
    /// The Tricks component (`player::tricks`): `Class_Flips` (`+36`) and the two `cloth_trick`
    /// packets, 0 = the trick's (`+40`), 1 = the one after it ends (`+44`).
    Flips,
    Cloth(u8),
    /// `Class_Treatment` (`player::treatment`, `+36`) and its `hall_of_meat_slo_mo` companion (`+40`).
    Treatment,
    HomSloMo,
    /// `playercharacter_footstep`: foot A (OffBoard `+36`) = 0, foot B (`+220`) = 1
    /// (`player::footsteps`).
    Footstep(u8),
    /// `c_cloth_falls` and `c_body_slide` (`player::clothing`).
    ClothFalls,
    BodySlide,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Command {
    Post { slot: Slot, class: &'static str, words: Vec<i32> },
    Redeliver { slot: Slot, words: Vec<i32> },
    Release { slot: Slot },
}

/// The banks the components post into (loaded at start so their classes bind).
pub const BANKS: &[&str] =
    &["GRINDS", "sense_of_speed", "FOOT_DRAG", "WHEEL_SKID_BANK", "Brd_Squeaks", "Seams_Bank", "fstep_skateshoe1_sm", "Foley_Cloth", "Bodyslide"];

fn speed_word(v: f32, offset: f32, divisor: f32) -> i32 {
    // trunc(clamp01((v − offset) / divisor · 3.6) · 10000), retail's operation order.
    trunc_clamp(clamp01(((v - offset) / divisor) * 3.6) * 10000.0, i32::MIN, i32::MAX)
}

fn intensity(value: f32, low: f32, high: f32) -> i32 {
    // trunc(clamp01((value − low) / (high − low)) · 1000), 0..1000.
    trunc_clamp(clamp01((value - low) / (high - low)) * 1000.0, 0, 1000)
}

// ------------------------------------------------------------------------------------- grind

/// `Class_grind` (17 words). Speed divisor: grind material class `default`, field
/// `0x4890392C91829954` = 45; offset 0.5 m/s (image); the speed word is capped at 9000.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Grind {
    held: [Option<Vec<i32>>; 2],
    /// `+56`: the family the packets were posted for (−1 = none).
    family: Option<i32>,
    /// `+140`: the speed word.
    speed: i32,
    surface: i32,
    layer: i32,
    /// The grind on / off contact sounds (Splice; [`Grind::sounds`]): per packet slot the on
    /// (`+60 + 4k`) and off (`+68 + 4k`) sound, and the starts queued by `process` / `update`.
    hits: [GrindHits; 2],
    pending: Vec<GrindHit>,
    /// Rail level(5) as of the last update: the sounds' env send (`sub_82498140`).
    env_level: i32,
    /// `sub_824C3FC8` / `sub_824C4138`. The game's host always turns it on; off only isolates the
    /// rest in tests.
    pub onoff: bool,
    /// On / off sounds started (diagnostics).
    pub hit_starts: u64,
}

/// One grind contact sound start: on (`sub_824C3FC8`) with the grind surface and layer it was
/// posted for, or off (`sub_824C4138`, which reads them back from the slot).
#[derive(Clone, Copy, Debug, PartialEq)]
struct GrindHit {
    on: bool,
    slot: usize,
    surface: i32,
    layer: i32,
}

/// A packet slot's contact sounds: `+92` surface / `+96` layer as of the on post, `+100` / `+104`
/// the on / off level and `+108` / `+112` their pitches (fixed at each start).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct GrindHits {
    on: Option<crate::splice::SoundId>,
    off: Option<crate::splice::SoundId>,
    surface: i32,
    layer: i32,
    level: [f32; 2],
    pitch: [f32; 2],
}

/// `sub_824C2FA0` / `sub_824C3190` / `sub_824C3380` / `sub_824C34A8`: ((10000 − speed word) ×
/// 0.0001 × (B − A) + A), the grind speed word lerping from B at rest to A at the cap.
fn grind_lerp(speed: i32, [a, b]: [f32; 2]) -> f32 {
    let f8 = f32::from_bits(0x461C_4000) - speed as f32; // 10000
    let f7 = f8 * f32::from_bits(0x38D1_B717); // 0.0001
    f7.mul_add(b - a, a)
}

pub const GRIND_SPEED_DIVISOR: f32 = 45.0;
/// The image's grind speed offset (`0x8209975C` region, 0.5 m/s).
pub const GRIND_SPEED_OFFSET: f32 = 0.5;
/// eEQChain `default`, field `0xD489344CEDEE5036`.
pub const GRIND_EQ_TWEAK: i32 = 5;

impl Grind {
    /// Layer of a grind family (`+192`): 1, 2, 4 → 0; 5 → 3; anything else → 2.
    pub fn layer(family: i32) -> i32 {
        match family {
            1 | 2 | 4 => 0,
            5 => 3,
            _ => 2,
        }
    }

    fn post_words(&self, t: &PlayerTuning, layer: i32, s: &AudioState, out: &dyn Outputs) -> Vec<i32> {
        let v = t.grind_levels(self.surface).v[layer as usize];
        let mut w = vec![0i32; 17];
        w[1] = 32767;
        w[5] = 25000;
        w[7] = self.speed.clamp(0, 10000);
        w[8] = 1024;
        w[9] = self.surface.clamp(0, 14);
        w[10] = layer;
        w[11] = trunc_clamp(v * 32767.0, i32::MIN, i32::MAX);
        w[12] = 0; // bool class 0x11A631878B239355 (global setting, not modelled)
        w[13] = i32::from(s.local); // local && [[owner+16]+64] == 0
        w[14] = i32::from(s.local);
        w[15] = if s.local { out.level(6) } else { 0 };
        w[16] = GRIND_EQ_TWEAK;
        w
    }

    /// The poster (before the tick). Rail inputs are written by [`super::inputs::write_rail`].
    pub fn process(&mut self, s: &AudioState, t: &PlayerTuning, out: &dyn Outputs) -> Vec<Command> {
        let mut cmds = Vec::new();
        if s.grinding {
            self.speed = speed_word(s.ground_speed.abs(), GRIND_SPEED_OFFSET, GRIND_SPEED_DIVISOR).min(9000);
        }
        if self.held[0].is_none() {
            if !s.grinding {
                return cmds;
            }
            let surface = t.grind_surface(s.grind_material);
            if surface == 14 {
                return cmds; // no grind sound on this material
            }
            self.surface = surface;
            self.layer = Self::layer(s.grind_family);
            self.family = Some(s.grind_family);
            let words = self.post_words(t, self.layer, s, out);
            cmds.push(Command::Post { slot: Slot::Grind(0), class: "Class_grind", words: words.clone() });
            self.held[0] = Some(words);
            self.hit(true, 0, surface, self.layer);
            if s.grind_family == 0 {
                let words = self.post_words(t, 1, s, out);
                cmds.push(Command::Post { slot: Slot::Grind(1), class: "Class_grind", words: words.clone() });
                self.held[1] = Some(words);
                self.hit(true, 1, surface, 1);
            }
        } else if !s.grinding {
            for i in 0..2 {
                if self.held[i].take().is_some() {
                    cmds.push(Command::Release { slot: Slot::Grind(i as u8) });
                    self.hit(false, i, 0, 0);
                }
            }
            self.family = None;
        }
        cmds
    }

    fn hit(&mut self, on: bool, slot: usize, surface: i32, layer: i32) {
        if self.onoff {
            self.pending.push(GrindHit { on, slot, surface, layer });
        }
    }

    /// The grind contact sounds queued by this frame's `process` / `update` (call after each):
    /// `sub_824C3FC8` at a grind packet's post — unless state `+810` (not published: false) —
    /// releases the slot's on sound, stores the surface / layer, the level and pitch, and starts
    /// the surface's on id (`sub_824C35D0`: Skate_Metal on a metal surface, else
    /// Skate_Collisions; per layer) through the eEQChain bus of field `D1A87641CCB98787`; at the
    /// release `sub_824C4138` does the same with the off id (`sub_824C37D8`), level and pitch for
    /// the stored surface / layer. Start block [0, 1, 0, 0, 1, 1].
    pub fn sounds(&mut self, s: &AudioState, t: &PlayerTuning, host: &mut dyn super::contacts::SpliceHost) {
        for h in std::mem::take(&mut self.pending) {
            let slot = &mut self.hits[h.slot];
            let k = usize::from(!h.on);
            let old = if h.on { slot.on.take() } else { slot.off.take() };
            if let Some(old) = old {
                host.release(old);
            }
            if h.on {
                slot.surface = h.surface;
                slot.layer = h.layer;
            }
            let g = t.grind_levels(slot.surface);
            let layer = usize::try_from(slot.layer).unwrap_or(0).min(3);
            let c = if h.on { &g.on } else { &g.off };
            slot.level[k] = grind_lerp(self.speed, c.level) * c.gain[layer];
            slot.pitch[k] = grind_lerp(self.speed, c.pitch);
            let Some(id) = u32::try_from(c.ids[layer]).ok() else { continue };
            host.set_route(crate::bus::Route {
                output: crate::bus::Output::Eq(t.grind_contact_eq),
                create: s.local,
                owner_env: self.env_level as f32 * crate::dsp::INV_32767,
                mono: true,
            });
            let bank = if g.metal { "Skate_Metal" } else { "Skate_Collisions" };
            let sound = host.start(bank, id, [0.0, 1.0, 0.0, 0.0, 1.0, 1.0]);
            self.hit_starts += u64::from(sound.is_some());
            if h.on {
                slot.on = sound;
            } else {
                slot.off = sound;
            }
        }
    }

    /// `sub_824C42A8` (the end of the Rail updater): per slot the on and the off sound, gain =
    /// level(1) / 32767 × its level, pitch = pitch(2) / 4096 × its pitch, azimuth raw(0), the env
    /// send level(5); a sound that ended is released.
    pub fn update_sounds(&mut self, s: &AudioState, out: &dyn Outputs, host: &mut dyn super::contacts::SpliceHost) {
        self.env_level = out.level(5);
        const INV_32767: f32 = f32::from_bits(0x3800_0100);
        const INV_4096: f32 = f32::from_bits(0x3980_0000);
        const DEGREES: f32 = f32::from_bits(0x3BB4_00B4);
        for slot in self.hits.iter_mut() {
            for k in 0..2 {
                let sound = if k == 0 { &mut slot.on } else { &mut slot.off };
                let Some(id) = *sound else { continue };
                if !host.alive(id) {
                    host.release(id);
                    *sound = None;
                    continue;
                }
                let gain = slot.level[k] * (out.level(1) as f32 * INV_32767);
                let pitch = slot.pitch[k] * (out.pitch(2) as f32 * INV_4096);
                host.update(id, [gain, pitch, out.raw(0) as f32 * DEGREES, s.dt, 0.0, 1.0]);
            }
        }
    }

    /// The updater (after the tick).
    pub fn update(&mut self, s: &AudioState, t: &PlayerTuning, out: &dyn Outputs) -> Vec<Command> {
        let mut cmds = Vec::new();
        if !s.grinding || self.held[0].is_none() {
            return cmds;
        }
        let family = s.grind_family;
        let layer = Self::layer(family);
        if self.family != Some(family) {
            // A family change: family 0 gains the layer-1 companion, any other loses it.
            if family == 0 && self.held[1].is_none() {
                let surface = t.grind_surface(s.grind_material);
                self.surface = surface.clamp(0, 13);
                let words = self.post_words(t, 1, s, out);
                cmds.push(Command::Post { slot: Slot::Grind(1), class: "Class_grind", words: words.clone() });
                self.held[1] = Some(words);
                // sub_824C39E0 posts the on sound with the new family's layer (2 for family 0).
                self.hit(true, 1, surface, layer);
            } else if family != 0 && self.held[1].take().is_some() {
                cmds.push(Command::Release { slot: Slot::Grind(1) });
                self.hit(false, 1, 0, 0);
            }
            self.family = Some(family);
        }
        let surface = if s.grind_material == NO_MATERIAL { 4 } else { t.grind_surface(s.grind_material) };
        let f = t.grind_levels(surface).f[layer as usize];
        let w1 = trunc_clamp(out.level(1) as f32 * f, 0, 32767);
        for i in 0..2 {
            let Some(w) = self.held[i].as_mut() else { continue };
            w[7] = self.speed.clamp(0, 10000);
            w[0] = 32767;
            w[1] = w1;
            w[2] = out.level(5).clamp(0, 32767);
            if s.local {
                w[15] = out.level(6).clamp(0, 32767);
            }
            w[5] = out.level(3).clamp(0, 25000);
            w[6] = out.level(4).clamp(0, 25000);
            w[3] = out.raw(0).clamp(0, 65536);
            w[4] = out.pitch(2).clamp(0, 8192);
            if i == 0 {
                w[10] = layer.clamp(0, 3);
            }
            if family == 0 {
                w[10] = 1;
            }
            cmds.push(Command::Redeliver { slot: Slot::Grind(i as u8), words: w.clone() });
        }
        cmds
    }
}

// ------------------------------------------------------------------------------- sense of speed

/// `SFXObj_SenseOfSpeed`'s rattle and wind (local player only). Tuning: owner class
/// `0x6E878344774A7999` `default` (rattle 30 → 80 km/h of ground speed, wind 15 → 55 km/h of COM
/// speed, 1 → 10 km/h while bailing; rattle w0 32767, wind w0 27000) and eEQChain tweaks 7.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SenseOfSpeed {
    rattle: Option<Vec<i32>>,
    wind: Option<Vec<i32>>,
}

pub const RATTLE_KMH: (f32, f32) = (30.0, 80.0);
pub const WIND_KMH: (f32, f32) = (15.0, 55.0);
pub const WIND_BAIL_KMH: (f32, f32) = (1.0, 10.0);
const RATTLE_WORDS: (i32, i32, i32) = (7, 32767, 23000);
const WIND_WORDS: (i32, [i32; 4]) = (7, [32767, 17000, 17000, 6750]);
const RATTLE_W0: i32 = 32767;
const WIND_W0: i32 = 27000;

impl SenseOfSpeed {
    fn wind_range(s: &AudioState) -> (f32, f32) {
        if s.bail { WIND_BAIL_KMH } else { WIND_KMH }
    }

    pub fn process(&mut self, s: &AudioState) -> Vec<Command> {
        let mut cmds = Vec::new();
        if !s.local {
            return cmds;
        }
        let kmh = s.ground_speed.abs() * 3.6;
        if kmh >= RATTLE_KMH.0 {
            if self.rattle.is_none() {
                let mut w = vec![0i32; 11];
                w[2] = 4096;
                w[3] = intensity(kmh, RATTLE_KMH.0, RATTLE_KMH.1);
                w[4] = 25000;
                (w[8], w[9], w[10]) = RATTLE_WORDS;
                cmds.push(Command::Post { slot: Slot::Rattle, class: "SenseOfSpeed_rattle", words: w.clone() });
                self.rattle = Some(w);
            }
        } else if self.rattle.take().is_some() {
            cmds.push(Command::Release { slot: Slot::Rattle });
        }
        let (low, high) = Self::wind_range(s);
        let com = s.com_speed() * 3.6;
        if com >= low {
            if self.wind.is_none() {
                let mut w = vec![0i32; 13];
                w[2] = 4096;
                w[3] = intensity(com, low, high);
                w[4] = 25000;
                w[8] = WIND_WORDS.0;
                w[9..13].copy_from_slice(&WIND_WORDS.1);
                cmds.push(Command::Post { slot: Slot::Wind, class: "SenseOfSpeed_wind", words: w.clone() });
                self.wind = Some(w);
            }
        } else if self.wind.take().is_some() {
            cmds.push(Command::Release { slot: Slot::Wind });
        }
        cmds
    }

    pub fn update(&mut self, s: &AudioState, out: &dyn Outputs) -> Vec<Command> {
        let mut cmds = Vec::new();
        if !s.local {
            return cmds;
        }
        if let Some(w) = self.rattle.as_mut() {
            w[0] = RATTLE_W0;
            w[1] = out.raw(0).clamp(0, 65535);
            w[2] = out.pitch(2).clamp(0, 8192);
            w[6] = 0;
            w[7] = out.level(1).clamp(0, 32767);
            w[3] = intensity(s.ground_speed.abs() * 3.6, RATTLE_KMH.0, RATTLE_KMH.1);
            cmds.push(Command::Redeliver { slot: Slot::Rattle, words: w.clone() });
        }
        if let Some(w) = self.wind.as_mut() {
            let (low, high) = Self::wind_range(s);
            w[0] = WIND_W0;
            w[2] = out.pitch(3).clamp(0, 8192);
            w[6] = 0;
            w[7] = out.level(4).clamp(0, 32767);
            w[3] = intensity(s.com_speed() * 3.6, low, high);
            cmds.push(Command::Redeliver { slot: Slot::Wind, words: w.clone() });
        }
        cmds
    }
}

// ----------------------------------------------------------------------------------- foot drag

/// `Class_foot_drag` (15 words), fired while braking (`+336`), manual-braking (`+339`) or the
/// off-board hold has expired (`+310`, not modelled: 0). Tuning: class `0xC26949FCB638A2CA`
/// `default` (speed offset 0.5 / divisor 50 m/s·3.6; w9..w12 = 4000, 4500, 4000, 22500) and
/// eEQChain tweak 7 (both the brake and the manual-brake key).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FootDrag {
    held: Option<Vec<i32>>,
}

pub const FOOT_DRAG_SPEED: (f32, f32) = (0.5, 50.0);
const FOOT_DRAG_WORDS: [i32; 4] = [4000, 4500, 4000, 22500];
const FOOT_DRAG_TWEAK: i32 = 7;

impl FootDrag {
    /// `sub_824BA390`: the foot-drag surface of wheel 0's material (wheel 2's while manual
    /// braking): 0 without contact; AudioSurfaceMap `+20`; 1 → 0 while manual braking.
    pub fn surface(s: &AudioState, t: &PlayerTuning) -> i32 {
        let material = if s.manual_brake { s.wheel_material[2] } else { s.wheel_material[0] };
        if material >= NO_MATERIAL {
            return 0;
        }
        let surface = t.surface_entry(material).map_or(0, |e| e[5]);
        if s.manual_brake && surface == 1 { 0 } else { surface }
    }

    fn active(s: &AudioState) -> bool {
        s.brake || s.manual_brake
    }

    pub fn process(&mut self, s: &AudioState, t: &PlayerTuning) -> Vec<Command> {
        if !Self::active(s) || self.held.is_some() {
            return Vec::new();
        }
        let mut w = vec![0i32; 15];
        w[1] = 32767;
        w[5] = 25000;
        w[7] = speed_word(s.ground_speed.abs(), FOOT_DRAG_SPEED.0, FOOT_DRAG_SPEED.1).clamp(0, 10000);
        w[8] = Self::surface(s, t).clamp(0, 10);
        w[9..13].copy_from_slice(&FOOT_DRAG_WORDS);
        w[13] = i32::from(!s.brake);
        w[14] = FOOT_DRAG_TWEAK;
        self.held = Some(w.clone());
        vec![Command::Post { slot: Slot::FootDrag, class: "Class_foot_drag", words: w }]
    }

    pub fn update(&mut self, s: &AudioState, t: &PlayerTuning, out: &dyn Outputs) -> Vec<Command> {
        if self.held.is_none() {
            return Vec::new();
        }
        if !Self::active(s) {
            self.held = None;
            return vec![Command::Release { slot: Slot::FootDrag }];
        }
        let w = self.held.as_mut().unwrap();
        w[7] = speed_word(s.ground_speed.abs(), FOOT_DRAG_SPEED.0, FOOT_DRAG_SPEED.1).clamp(0, 10000);
        w[0] = 32767;
        w[1] = out.level(if s.brake { 4 } else { 5 }).clamp(0, 32767);
        w[2] = out.level(18).clamp(0, 32767);
        w[5] = out.level(16).clamp(0, 25000);
        w[6] = out.level(17).clamp(0, 25000);
        w[3] = out.raw(0).clamp(0, 65536);
        w[4] = out.pitch(22).clamp(0, 8192);
        w[8] = Self::surface(s, t).clamp(0, 10);
        vec![Command::Redeliver { slot: Slot::FootDrag, words: w.clone() }]
    }
}

// ------------------------------------------------------------------------------------------ skid

/// `Class_wheels_skid` (18 words, `WHEEL_SKID_BANK`), owner `SFXObj_SkateBoard` (holder `+1288`):
/// poster `sub_824C7438`, predicate `sub_824C72F0`, constructor `sub_824AF678`, updater
/// `sub_824C7A20`, surface `sub_824C7388`. Held while the predicate holds — with any slip (`+232`,
/// which is ≥ 0.75/45 whenever a wheel is down): grinding → only grind family 4; on foot with
/// `+308` → no; else only without an audio trick (−1) or with a grab (35); without slip: the
/// revert flag `+690` or the revert counter (+5 per frame while `+690`, cap 45, else −15) > 0. The
/// slip word w10 = clamp(counter + trunc(90 × slip), 0, 90) carries the skid intensity. Tuning:
/// holder `0xBA9837A6CF4C26ED` (w11 `0xFB10048CCDD6ADFA` = 23000, w12 `0x8CE42E5A9388A4C8` = 32767),
/// eEQChain `0xF52450E504250254` = 5.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Skid {
    held: Option<Vec<i32>>,
    /// `+1516` the revert counter.
    counter: i32,
}

const SKID_WORDS: (i32, i32, i32) = (23000, 32767, 5);

impl Skid {
    fn predicate(&self, s: &AudioState) -> bool {
        if s.slip > 0.0 {
            if s.grinding {
                return s.grind_family == 4;
            }
            if s.on_foot && s.offboard_308 {
                return false;
            }
            return matches!(s.audio_trick, -1 | 35);
        }
        s.revert || self.counter > 0
    }

    /// `sub_824C7388`: AudioSurfaceMap word 3 (`+12`) of wheel 0's material, 0 without one.
    pub fn surface(s: &AudioState, t: &PlayerTuning) -> i32 {
        let m = s.wheel_material[0];
        if m >= NO_MATERIAL { 0 } else { t.surface_entry(m).map_or(0, |e| e[3]) }
    }

    fn speed(s: &AudioState) -> i32 {
        trunc_clamp(clamp01(s.ground_speed * f32::from_bits(0x3DA3_D70A)) * 10000.0, 0, 10000)
    }

    /// The poster (before the tick); SkateBoard input 1 = 32767 while the predicate holds (no
    /// MixMap output reads it).
    pub fn process(&mut self, s: &AudioState, t: &PlayerTuning, out: &dyn Outputs) -> Vec<Command> {
        if !self.predicate(s) || self.held.is_some() {
            return Vec::new();
        }
        let mut w = vec![0i32; 18];
        w[1] = 32767;
        w[5] = 25000;
        w[7] = Self::speed(s);
        w[8] = i32::from(s.soft_wheels); // sub_824B23C8 (NPCs: world::skaters)
        w[9] = Self::surface(s, t).clamp(0, 4);
        w[10] = trunc_clamp(s.slip * 90.0, 0, 90);
        (w[11], w[12]) = (SKID_WORDS.0, SKID_WORDS.1);
        w[13] = 0; // bool class 0x11A631878B239355 (global setting, not modelled)
        w[14] = i32::from(s.local);
        w[15] = i32::from(s.local);
        w[16] = if s.local { out.level(20).clamp(0, 32767) } else { 0 };
        w[17] = SKID_WORDS.2;
        self.held = Some(w.clone());
        vec![Command::Post { slot: Slot::Skid, class: "Class_wheels_skid", words: w }]
    }

    /// The updater (after the tick).
    pub fn update(&mut self, s: &AudioState, t: &PlayerTuning, out: &dyn Outputs) -> Vec<Command> {
        if self.held.is_none() {
            return Vec::new();
        }
        if !self.predicate(s) {
            self.held = None;
            return vec![Command::Release { slot: Slot::Skid }];
        }
        if s.revert {
            self.counter = (self.counter + 5).min(45);
        } else if self.counter > 0 {
            self.counter = (self.counter - 15).max(0);
        }
        let counter = self.counter;
        let w = self.held.as_mut().unwrap();
        w[7] = Self::speed(s);
        w[4] = out.pitch(3).clamp(0, 8192);
        w[0] = 32767;
        w[1] = out.level(4).clamp(0, 32767);
        w[3] = out.raw(0).clamp(0, 65536);
        w[2] = out.level(13).clamp(0, 32767);
        w[5] = out.level(11).clamp(0, 25000);
        w[6] = out.level(12).clamp(0, 25000);
        w[10] = (counter - trunc_clamp(s.slip * -90.0, i32::MIN, i32::MAX)).clamp(0, 90);
        w[9] = Self::surface(s, t).clamp(0, 4);
        w[16] = if s.local { out.level(20).clamp(0, 32767) } else { 0 };
        vec![Command::Redeliver { slot: Slot::Skid, words: w.clone() }]
    }
}

// ---------------------------------------------------------------------------------------- squeaks

/// `Class_Squeaks` (11 words, `Brd_Squeaks`), owner `SFXObj_SkateBoard` (holder `+1292`): trigger
/// `sub_824C7738`, constructor `sub_824AFF48`, updater `sub_824C7DD0`. Gate: both feet in the deck
/// box (`+615/+616`) and more than one wheel down, else released. Posted once the deck tilt
/// trunc(|`+264`| × 114.59155) reaches the grain class's `0xA129B33B4A2C7961` = 15 (degrees); a tilt
/// sign change releases it (and the next frame over the threshold posts again); below the
/// threshold a held squeak stays. Words: w7 = trunc(clamp01(v × 0.08) × 1000), w9 = the deck spin
/// word trunc(|`+488`| / 1.5 × 1000) (`0xAC87D592E7601134` = 1.5; < 50 → 0, cap 1000), w8 15, w10
/// eEQChain `0x22D0D4A5A14FFF7D` = 0; update w1 = level(5), w4 = pitch(3), w5/w6 = filters
/// 11/12, w3 = raw(0), w2 0.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Squeaks {
    held: Option<Vec<i32>>,
    /// `+1296` the tilt sign of the held squeak (true = non-negative).
    sign: bool,
}

pub const SQUEAK_TILT_DEGREES: i32 = 15;
pub const SQUEAK_SPIN_DIVISOR: f32 = 1.5;

impl Squeaks {
    fn speed(s: &AudioState) -> i32 {
        trunc_clamp(clamp01(s.ground_speed * f32::from_bits(0x3DA3_D70A)) * 1000.0, 0, 1000)
    }

    fn spin(s: &AudioState) -> i32 {
        let x = trunc_clamp((s.deck_spin.abs() / SQUEAK_SPIN_DIVISOR) * 1000.0, i32::MIN, i32::MAX);
        if x > 1000 { 1000 } else if x >= 50 { x } else { 0 }
    }

    pub fn process(&mut self, s: &AudioState) -> Vec<Command> {
        let mut cmds = Vec::new();
        if !(s.feet_in_deck_box[0] && s.feet_in_deck_box[1] && s.wheel_count > 1) {
            if self.held.take().is_some() {
                cmds.push(Command::Release { slot: Slot::Squeaks });
            }
            return cmds;
        }
        let tilt = trunc_clamp(s.deck_tilt.abs() * f32::from_bits(0x42E5_2EE0), i32::MIN, i32::MAX);
        if tilt < SQUEAK_TILT_DEGREES {
            return cmds;
        }
        let sign = s.deck_tilt >= 0.0;
        if sign != self.sign && self.held.take().is_some() {
            cmds.push(Command::Release { slot: Slot::Squeaks });
        }
        self.sign = sign;
        if self.held.is_none() {
            let mut w = vec![0i32; 11];
            w[1] = 32767;
            w[4] = 4096;
            w[5] = 25000;
            w[7] = Self::speed(s);
            w[8] = 15;
            w[9] = Self::spin(s);
            w[10] = 0;
            cmds.push(Command::Post { slot: Slot::Squeaks, class: "Class_Squeaks", words: w.clone() });
            self.held = Some(w);
        }
        cmds
    }

    pub fn update(&mut self, s: &AudioState, out: &dyn Outputs) -> Vec<Command> {
        let Some(w) = self.held.as_mut() else { return Vec::new() };
        w[7] = Self::speed(s);
        w[9] = Self::spin(s);
        w[4] = out.pitch(3).clamp(0, 8192);
        w[0] = 32767;
        w[1] = out.level(5).clamp(0, 32767);
        w[2] = 0;
        w[5] = out.level(11).clamp(0, 25000);
        w[6] = out.level(12).clamp(0, 25000);
        w[3] = out.raw(0).clamp(0, 65536);
        vec![Command::Redeliver { slot: Slot::Squeaks, words: w.clone() }]
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
            16384
        }
        fn pitch(&self, _: usize) -> i32 {
            4096
        }
    }

    fn grinding(family: i32, material: u32) -> AudioState {
        AudioState { grinding: true, grind_family: family, grind_material: material, ground_speed: 6.0, ..Default::default() }
    }

    #[derive(Default)]
    struct Splice {
        started: Vec<(String, u32)>,
        routes: Vec<crate::bus::Route>,
        blocks: Vec<(usize, [f32; 6])>,
        live: Vec<usize>,
    }
    impl super::super::contacts::SpliceHost for Splice {
        fn set_route(&mut self, route: crate::bus::Route) {
            self.routes.push(route);
        }
        fn start(&mut self, bank: &str, id: u32, _: [f32; 6]) -> Option<crate::splice::SoundId> {
            self.started.push((bank.to_owned(), id));
            self.live.push(id as usize);
            Some(id as usize)
        }
        fn update(&mut self, sound: crate::splice::SoundId, block: [f32; 6]) {
            self.blocks.push((sound, block));
        }
        fn alive(&self, sound: crate::splice::SoundId) -> bool {
            self.live.contains(&sound)
        }
        fn release(&mut self, sound: crate::splice::SoundId) {
            self.live.retain(|s| *s != sound);
        }
    }

    #[test]
    fn grind_on_and_off_sounds_follow_the_rail_posts() {
        use super::super::tuning::{GrindContact, GrindSurface};
        let contact = |base: i32| GrindContact { ids: [base, base + 1, base + 2, base + 3], gain: [0.5, 1.0, 1.0, 1.0], level: [0.1, 1.25], pitch: [0.8, 1.0] };
        let mut t = PlayerTuning::default();
        t.grind = vec![GrindSurface::default(); 14];
        t.grind[4] = GrindSurface { metal: true, on: contact(525), off: contact(530), ..GrindSurface::default() };
        let mut g = Grind { onoff: true, ..Grind::default() };
        let mut h = Splice::default();
        g.process(&grinding(1, NO_MATERIAL), &t, &Fixed);
        g.sounds(&grinding(1, NO_MATERIAL), &t, &mut h);
        // Surface 4 (no material), layer 0 (family 1): Skate_Metal on id 525, eEQChain bus 0, mono.
        assert_eq!(h.started, [("Skate_Metal".to_owned(), 525)]);
        assert_eq!((h.routes[0].output, h.routes[0].mono), (crate::bus::Output::Eq(0), true));
        g.update_sounds(&grinding(1, NO_MATERIAL), &Fixed, &mut h);
        // Level = lerp(speed 4400) × layer gain 0.5 × level(1); pitch = lerp × pitch(2).
        let lerp = |s: i32, a: f32, b: f32| ((10000.0f32 - s as f32) * f32::from_bits(0x38D1_B717)).mul_add(b - a, a);
        let (_, block) = h.blocks[0];
        assert!((block[0] - lerp(4400, 0.1, 1.25) * 0.5 * (1001.0 * f32::from_bits(0x3800_0100))).abs() < 1e-6);
        assert!((block[1] - lerp(4400, 0.8, 1.0)).abs() < 1e-6);
        g.process(&AudioState::default(), &t, &Fixed);
        g.sounds(&AudioState::default(), &t, &mut h);
        assert_eq!(h.started[1], ("Skate_Metal".to_owned(), 530), "the off sound at the release");
        // Off: nothing.
        let mut g = Grind::default();
        g.process(&grinding(1, NO_MATERIAL), &t, &Fixed);
        g.sounds(&grinding(1, NO_MATERIAL), &t, &mut h);
        assert_eq!(h.started.len(), 2);
    }

    #[test]
    fn grind_posts_one_layer_or_two_for_family_zero_and_releases_both() {
        let t = PlayerTuning::default();
        let mut g = Grind::default();
        let cmds = g.process(&grinding(1, NO_MATERIAL), &t, &Fixed);
        assert_eq!(cmds.len(), 1);
        let Command::Post { class, words, .. } = &cmds[0] else { panic!() };
        assert_eq!(*class, "Class_grind");
        // speed = trunc(clamp01((6 − 0.5)/45·3.6)·10000) = 4400; surface 4 (no material); layer 0.
        assert_eq!((words[7], words[9], words[10], words[11], words[16]), (4400, 4, 0, 32767, 5));
        assert!(g.process(&grinding(1, NO_MATERIAL), &t, &Fixed).is_empty(), "held: no repost");
        let up = g.update(&grinding(1, NO_MATERIAL), &t, &Fixed);
        let Command::Redeliver { words, .. } = &up[0] else { panic!() };
        assert_eq!((words[0], words[1], words[2], words[3], words[4], words[5], words[6]), (32767, 1001, 1005, 16384, 4096, 1003, 1004));
        assert_eq!(g.process(&AudioState::default(), &t, &Fixed), vec![Command::Release { slot: Slot::Grind(0) }]);
        // Family 0: layer 2 plus the layer-1 companion; the updater writes w10 = 1 on both.
        let cmds = g.process(&grinding(0, NO_MATERIAL), &t, &Fixed);
        assert_eq!(cmds.len(), 2);
        let up = g.update(&grinding(0, NO_MATERIAL), &t, &Fixed);
        assert!(up.iter().all(|c| matches!(c, Command::Redeliver { words, .. } if words[10] == 1)));
        assert_eq!(g.process(&AudioState::default(), &t, &Fixed).len(), 2);
    }

    #[test]
    fn skid_is_held_while_rolling_and_its_slip_word_follows_the_slip() {
        use crate::player::state::slip;
        let t = PlayerTuning::default();
        let mut k = Skid::default();
        // Straight rolling: slip = 0.75/45 (the vault's −0.75 offset), word trunc(90 × slip) = 1.
        let mut s = AudioState { ground_speed: 5.0, wheel_count: 4, slip: slip(0.0), ..Default::default() };
        let Command::Post { class, words, .. } = &k.process(&s, &t, &Fixed)[0] else { panic!() };
        let speed = ((5.0f32 * f32::from_bits(0x3DA3_D70A)) * 10000.0) as i32;
        assert_eq!((*class, words[7], words[10], words[11], words[12], words[17]), ("Class_wheels_skid", speed, 1, 23000, 32767, 5));
        // A powerslide: 3 m/s lateral → (3 + 0.75) / 45 → word 7.
        s.slip = slip(3.0);
        let Command::Redeliver { words, .. } = &k.update(&s, &t, &Fixed)[0] else { panic!() };
        assert_eq!((words[10], words[1], words[2], words[4]), (7, 1004, 1013, 4096));
        // In the air (no wheel: slip 0) without a revert → released.
        s.slip = 0.0;
        assert_eq!(k.update(&s, &t, &Fixed), vec![Command::Release { slot: Slot::Skid }]);
        // An audio trick other than a grab blocks it.
        s.slip = slip(0.0);
        s.audio_trick = 28;
        assert!(k.process(&s, &t, &Fixed).is_empty());
    }

    #[test]
    fn squeaks_post_past_15_degrees_and_repost_on_a_tilt_sign_change() {
        let mut q = Squeaks::default();
        let mut s = AudioState { ground_speed: 5.0, wheel_count: 4, feet_in_deck_box: [true; 2], deck_tilt: 0.2, deck_spin: 0.75, ..Default::default() };
        // 0.2 rad × 114.59 = 22° ≥ 15: post; spin 0.75 / 1.5 → 500.
        let Command::Post { class, words, .. } = &q.process(&s)[0] else { panic!() };
        assert_eq!((*class, words[8], words[9], words[10]), ("Class_Squeaks", 15, 500, 0));
        assert!(q.process(&s).is_empty(), "held");
        s.deck_tilt = 0.1; // below 15°: stays held
        assert!(q.process(&s).is_empty());
        s.deck_tilt = -0.3; // sign change: release and repost
        let cmds = q.process(&s);
        assert!(matches!(cmds[0], Command::Release { .. }) && matches!(cmds[1], Command::Post { .. }));
        s.feet_in_deck_box = [true, false];
        assert_eq!(q.process(&s), vec![Command::Release { slot: Slot::Squeaks }]);
        s.feet_in_deck_box = [true; 2];
        s.deck_spin = 0.05; // 33 < 50 → 0
        let Command::Post { words, .. } = &q.process(&s)[0] else { panic!() };
        assert_eq!(words[9], 0);
    }

    #[test]
    fn grind_speed_caps_at_9000() {
        let t = PlayerTuning::default();
        let mut g = Grind::default();
        let mut s = grinding(1, NO_MATERIAL);
        s.ground_speed = 30.0;
        let Command::Post { words, .. } = &g.process(&s, &t, &Fixed)[0] else { panic!() };
        assert_eq!(words[7], 9000);
    }

    #[test]
    fn rattle_and_wind_post_above_their_speeds() {
        let mut sos = SenseOfSpeed::default();
        let mut s = AudioState { ground_speed: 20.0 / 3.6, com_velocity: [20.0 / 3.6, 0.0, 0.0], ..Default::default() };
        let cmds = sos.process(&s);
        assert_eq!(cmds.len(), 1, "wind only at 20 km/h");
        let Command::Post { class, words, .. } = &cmds[0] else { panic!() };
        assert_eq!((*class, words[3], &words[8..]), ("SenseOfSpeed_wind", 125, &[7, 32767, 17000, 17000, 6750][..]));
        s.ground_speed = 55.0 / 3.6;
        let cmds = sos.process(&s);
        let Command::Post { class, words, .. } = &cmds[0] else { panic!() };
        assert_eq!((*class, words[3], &words[8..]), ("SenseOfSpeed_rattle", 500, &[7, 32767, 23000][..]));
        let up = sos.update(&s, &Fixed);
        assert_eq!(up.len(), 2);
        s.ground_speed = 1.0;
        s.com_velocity = [1.0, 0.0, 0.0];
        assert_eq!(sos.process(&s), vec![Command::Release { slot: Slot::Rattle }, Command::Release { slot: Slot::Wind }]);
    }

    #[test]
    fn foot_drag_fires_on_brake_and_reads_contacts_outputs() {
        let t = PlayerTuning::default();
        let mut f = FootDrag::default();
        let s = AudioState { brake: true, ground_speed: 5.0, ..Default::default() };
        let Command::Post { words, .. } = &f.process(&s, &t)[0] else { panic!() };
        // trunc(clamp01((5 − 0.5)/50·3.6)·10000) = 3240.
        assert_eq!((words[7], words[8], &words[9..15]), (3240, 0, &[4000, 4500, 4000, 22500, 0, 7][..]));
        let Command::Redeliver { words, .. } = &f.update(&s, &t, &Fixed)[0] else { panic!() };
        assert_eq!((words[1], words[2], words[5], words[6], words[4]), (1004, 1018, 1016, 1017, 4096));
        assert_eq!(f.update(&AudioState::default(), &t, &Fixed), vec![Command::Release { slot: Slot::FootDrag }]);
    }
}
