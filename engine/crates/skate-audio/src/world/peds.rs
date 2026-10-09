//! Pedestrians' sound objects (MixMap slot 5, `audio-specs/world-ped-audio.md`):
//! - [`PedSfx`] = `SFXObj_PedestrianSFX` (vtable `0x822FCCC8`, factory `sub_824D7E00`): process
//!   `sub_824D8078` (vfunc 9), update `sub_824D81A8` (vfunc 10). Its footsteps are two layers:
//!   - the held `livingword_footstep` packets (21 words, constructor `sub_824B77F0`, bank
//!     `fstep_livingworld`), one per foot, posted by `sub_824D81F8` and rewritten every frame by
//!     `sub_824D8658`: the program plays a step on the foot-down word;
//!   - a `sk8_foley` Splice one-shot per foot plant (`sub_824D8320`), walk / jog / run by the ped's
//!     speed (`sub_82494840`: Clothing thresholds 7.5 / 2.5 m/s → containers 64 / 63 / 62), kept
//!     up to date by `sub_824D84D0`. Retail's `sk8_foley` 62/63/64 starts by caller `824D8164` are
//!     these (recomp `all_20261002_164620`: 1017 events).
//! - [`PedSpeech`] = `SFXObj_PedestrianSpeech` (vtable `0x822FBF40`): process `sub_824D9908`
//!   hands the speech manager a request whenever the ped's speech value (`SendSpeechEvent`'s
//!   `speechvalue` in the state graphs) changes ([`super::speech`] resolves it to a clip); value
//!   49 rings a phone first and asks for 64 when the ring ends, value 29 repeats on a timer;
//! - [`PedBodyFall`] = `SFXObj_PedBodyFall`: a Skate_Collisions fall sound per `BodyFallType`
//!   animation event;
//! - [`PedTazer`] = `SFXObj_Tazer`: the `c_tazer` packet while the ped tazes.
//!
//! The ped side ([`PedState`]) is the record the objects read: the ped audio state `[object+32]`
//! (feet `+73`/`+74`, footsteps on `+68`, `BodyFallType` `+76`, tazer `+80`, kind `+96`, class
//! `+132`, speech value `+136`, materials `+140`/`+144`, the speech distance pair `+148`/`+156`)
//! and the owner `[object+28]` (speed `+128`, weight `+144`); the manager `sub_824F2890` fills it
//! from the packed ped audio entries (spec G2). A ped system fills [`PedState`] from its own
//! animation (foot plants, fall events) and AI (speech values, tazing).
use super::{WorldCommand, WorldSlot};
use crate::player::contacts::SpliceHost;
use crate::player::footsteps::{Curve, footstep_surface};
use crate::player::tuning::PlayerTuning;
use crate::player::{Outputs, trunc_clamp};
use crate::splice::SoundId;

pub const FOOTSTEP_CLASS: &str = "livingword_footstep";
pub const FOOTSTEP_BANK: &str = "fstep_livingworld";
pub const FOOTSTEP_WORDS: usize = 21;
/// Retail's Splice bank table index 7 (`crate::player::footsteps::splice_bank`).
pub const STEP_BANK: &str = "sk8_foley";
/// The "no material" value of the ped's material words; the poster substitutes 3.
pub const NO_MATERIAL: u32 = 143;

const LEVEL: f32 = f32::from_bits(0x3800_0100); // 1/32767 (0x822F8898)
const PITCH: f32 = f32::from_bits(0x3980_0000); // 1/4096 (0x822F890C)
const DEGREES: f32 = f32::from_bits(0x3BB4_00B4); // 360/65535 (0x822F8C64)

/// The ped footstep values from the audio vault (setup export `world_tuning.peds`; the defaults are
/// the shipped records, as `player::footsteps::FootstepTuning`'s are).
#[derive(Clone, Debug, PartialEq)]
pub struct PedFootstepTuning {
    /// OffBoard tuning `90B47430C4ED2CCC` (`Sk8::PointNegGraphData16`): ped speed → `+416` → w13.
    pub speed_curve: Curve,
    /// Clothing `E12AF885D3C3A168` [run above, jog above] (m/s), shared with the player's walking
    /// voices.
    pub speeds: [f32; 2],
    /// `sk8_foley` ids [walk `6B61C043E53C44CB`, jog `EC3399A49055DD8D`, run `9D6D2863CFE908C4`].
    pub step_ids: [i32; 3],
    /// OffBoard tuning `62A2E64238934734` → packet w17..w19.
    pub tail: [i32; 3],
    /// eEQChain `A9023782094771B5` (holder `42AFE160E647167C`): w20 = this + 10.
    pub eq_chain: i32,
}

impl Default for PedFootstepTuning {
    fn default() -> Self {
        Self {
            speed_curve: Curve::from_bits(
                [
                    0x0000_0000, 0x3F94_0358, 0x3F9E_6FBD, 0x4043_F5FD, 0x407D_4A38, 0x409C_5A0E, 0x40B3_488C, 0x40CC_D222, 0x40E0_A01B, 0x40F0_C821,
                    0x40FD_CFA2, 0x4104_E627, 0x410C_FA2A, 0x4113_7DEA, 0x4118_B41E, 0x411E_F529,
                ],
                [
                    0x0000_0000, 0x0000_0000, 0x42F7_EF0E, 0x4318_E481, 0x4339_F34D, 0x436B_8986, 0x438E_8FDF, 0x43A7_5AFB, 0x43BE_1529, 0x43DB_021D,
                    0x43FA_0000, 0x440F_9855, 0x4416_D392, 0x4421_2833, 0x4424_4196, 0x4424_4196,
                ],
            ),
            speeds: [7.5, 2.5],
            step_ids: [62, 63, 64],
            tail: [32767, 7000, 25000],
            eq_chain: 2,
        }
    }
}

/// What the ped objects read each frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PedState {
    pub position: [f32; 3],
    pub velocity: [f32; 3],
    /// Owner `+128`: the ped's speed (m/s).
    pub speed: f32,
    /// `+74` (foot A, packet w3 = 1000) and `+73` (foot B, w3 = 0): the foot is planted.
    pub feet: [bool; 2],
    /// `+68`: footsteps on (the ped is close / visible enough; who sets it is not traced).
    pub footsteps: bool,
    /// `+140` (foot A) / `+144` (foot B): the material under each foot (143 = none).
    pub materials: [u32; 2],
    /// `+136`: the speech value the ped's state graph last sent (`SendSpeechEvent`).
    pub speech_value: i32,
    /// `+132` → w14 (1..5); meaning not traced (ped class / shoe type).
    pub class: i32,
    /// Owner `+144` → w16 (1..5); meaning not traced (body weight).
    pub weight: i32,
    /// `+96 == 64`: the outputs read are the close-range variants (footstep level 2 / step level 4
    /// instead of 1 / 3; PedestrianSFX out4 rolls off over 3–8 m).
    pub close: bool,
    /// The speech manager's flag pair `+148` / `+156` (`flag = 1` when `+148 > +156`, else 2):
    /// the distance to the listener and the model's far threshold (recomp gap run G2).
    pub speech_measure: f32,
    pub speech_limit: f32,
    /// `S+84`: the model = the speech voice id (0 = none: no speech).
    pub voice: u32,
    /// The speaker words of the model (`aud_characteristics`: type / variant bits, gender; the
    /// speech manager's timers are kept per `index` = the voice).
    pub speaker: super::speech_manager::Speaker,
    /// Which PedestrianSpeech outputs a line plays at ([`super::speech_player::ped_level_ids`]).
    pub level_select: super::speech_player::PedLevelSelect,
    /// `S+80`: the ped is tazing (the manager's bit 17 of the ped audio entry `+4`; set while the
    /// state graph's `TazeEntity` state runs, `pedestrian_wanttotaze.xml`): SFXObj_Tazer holds its
    /// `c_tazer` packet while it is set ([`PedTazer`]).
    pub tazing: bool,
    /// `S+76`: the ped animation's `BodyFallType` event value (entry `+16`, a float; 0 = none). Each
    /// change to a non-zero value starts one PedBodyFall sound ([`PedBodyFall`]).
    pub body_fall: f32,
}

impl Default for PedState {
    fn default() -> Self {
        Self {
            position: [0.0; 3],
            velocity: [0.0; 3],
            speed: 0.0,
            feet: [false; 2],
            footsteps: true,
            materials: [NO_MATERIAL; 2],
            speech_value: 0,
            class: 1,
            weight: 1,
            close: false,
            speech_measure: 0.0,
            speech_limit: 0.0,
            voice: 0,
            speaker: super::speech_manager::Speaker::default(),
            level_select: super::speech_player::PedLevelSelect::default(),
            tazing: false,
            body_fall: 0.0,
        }
    }
}

/// The ped objects' one-shot values (setup export `world_tuning.ped_objects`; the defaults are the
/// shipped records and the image's constants, as [`PedFootstepTuning`]'s are). Mods can override
/// every field through the world tuning.
#[derive(Clone, Debug, PartialEq)]
pub struct PedObjectTuning {
    /// SFXObj_PedBodyFall's Skate_Collisions containers by `BodyFallType` [8, 9, any other]
    /// (vault class `923CCB46EF5BF5BA` record `DFEFC9212E0CBD2C`, fields `552899F3BF9927CC` /
    /// `A3E8A9381F4222E1` / `C0FFD1E535F218E2`; holder `*(0x830CFDA4)+124`).
    pub body_fall_ids: [u32; 3],
    /// Their Splice bank (retail's table index 0).
    pub body_fall_bank: String,
    /// The eEQChain bus they resolve (eEQChain holder field `B4C4F86A53963BA2`, absent from the
    /// shipped database: the lookup's default 0), created on resolve.
    pub body_fall_eq: u8,
    /// The phone ring of speech value 49 (`sub_824D9C70`): Splice bank index 6 and its container
    /// (class `C1831BDB6CB1B1EA` record `cellphone` field `031EFDF991638985`).
    pub ring_bank: String,
    pub ring_id: u32,
    /// The speech value requested when the ring ends (`sub_824D9AD8`: 64 → `4402_cell_greet`).
    pub ring_answer: i32,
    /// The photographer's repeat (value 29 while the game flag is set): the request repeats each
    /// time this many seconds have accumulated (the image's 1.0 at `0x8231A844`).
    pub photo_repeat: f32,
    /// How long a tazer hold lasts when the engine does not say (the state graph's `TazerCycTime`,
    /// `pedestrian_wanttotaze.xml` `TazeEntity`: 2.0 s; the recomp's bursts last 2.0 / 2.1 s).
    pub tazer_seconds: f32,
}

impl Default for PedObjectTuning {
    fn default() -> Self {
        Self {
            body_fall_ids: [1184, 948, 1183],
            body_fall_bank: "Skate_Collisions".into(),
            body_fall_eq: 0,
            ring_bank: "CellPhone_Rings".into(),
            ring_id: 5,
            ring_answer: 64,
            photo_repeat: 1.0,
            tazer_seconds: 2.0,
        }
    }
}

/// `SFXObj_PedestrianSFX`'s footstep state. Index 0 = foot A (`+40` packet, `+424` sound, flags
/// `+52`/`+54`, material `+56`), 1 = foot B (`+224`, `+420`, `+236`/`+238`, `+240`).
#[derive(Clone, Debug, Default)]
pub struct PedSfx {
    pub packets: [Option<[i32; FOOTSTEP_WORDS]>; 2],
    pub sounds: [Option<SoundId>; 2],
    /// `+416`: the speed curve's word.
    pub speed_word: i32,
    down: [bool; 2],
    prev: [bool; 2],
    materials: [u32; 2],
}

impl PedSfx {
    /// `sub_824B77F0` (foot 1000 = A, 0 = B).
    pub fn post_words(foot: i32, speed_word: i32, eq: i32) -> [i32; FOOTSTEP_WORDS] {
        let mut w = [0; FOOTSTEP_WORDS];
        w[0] = 32767;
        w[2] = 4096;
        w[3] = foot.clamp(0, 1000);
        w[4] = 25000;
        w[13] = speed_word.clamp(0, 1000);
        w[14] = 1;
        w[15] = 1;
        w[16] = 1;
        w[20] = eq.clamp(0, 32767);
        w
    }

    /// The Splice step for a speed (`sub_82494840`).
    pub fn step_id(t: &PedFootstepTuning, speed: f32) -> i32 {
        if speed > t.speeds[0] {
            t.step_ids[2]
        } else if speed > t.speeds[1] {
            t.step_ids[1]
        } else {
            t.step_ids[0]
        }
    }

    /// vfunc 9 (`sub_824D8078`), before the tick. `dt` is the frame time the Splice block carries.
    pub fn process(&mut self, owner: u64, s: &PedState, t: &PedFootstepTuning, host: &mut dyn SpliceHost, dt: f32) -> Vec<WorldCommand> {
        let mut out = Vec::new();
        self.speed_word = trunc_clamp(t.speed_curve.eval(s.speed), i32::MIN, i32::MAX);
        self.down = s.feet;
        if s.footsteps {
            // Poster (`sub_824D81F8`): materials (none → 3), then the held packets, B first.
            for i in 0..2 {
                self.materials[i] = if s.materials[i] == NO_MATERIAL { 3 } else { s.materials[i] };
            }
            let eq = t.eq_chain + 10;
            for (i, foot) in [(1usize, 0), (0usize, 1000)] {
                if self.packets[i].is_none() {
                    let words = Self::post_words(foot, self.speed_word, eq);
                    self.packets[i] = Some(words);
                    out.push(WorldCommand::Post { owner, slot: WorldSlot::PedFootstep(i as u8), class: FOOTSTEP_CLASS, words: words.to_vec() });
                }
            }
            // Splice steps on each plant (`sub_824D8320`): foot A, then B.
            for i in 0..2 {
                if self.down[i] && !self.prev[i] {
                    if let Some(old) = self.sounds[i].take() {
                        host.release(old);
                    }
                    let id = Self::step_id(t, s.speed);
                    self.sounds[i] = u32::try_from(id).ok().and_then(|id| host.start(STEP_BANK, id, [0.0, 1.0, 0.0, dt, 0.0, 1.0]));
                }
            }
            // `sub_824D8E60` (a one-shot flag `+412` by camera distance and a vault key) is not
            // ported: its result feeds nothing the footsteps read.
        }
        self.prev = self.down;
        out
    }

    /// vfunc 10 (`sub_824D81A8`), after the tick.
    pub fn update(&mut self, owner: u64, s: &PedState, t: &PedFootstepTuning, tuning: &PlayerTuning, out: &dyn Outputs, host: &mut dyn SpliceHost, dt: f32) -> Vec<WorldCommand> {
        let mut cmds = Vec::new();
        if s.footsteps {
            // `sub_824D8658`: both packets, A then B.
            let collision = matches!(s.speech_value, 6 | 7);
            let jump = matches!(s.speech_value, 4 | 5);
            let level = out.level(if s.close { 2 } else { 1 }).clamp(0, 32767);
            for i in 0..2 {
                let Some(mut w) = self.packets[i] else { continue };
                w[0] = 32767;
                w[1] = out.raw(0).clamp(0, 65535);
                w[2] = out.pitch(5).clamp(0, 8192);
                w[4] = out.level(7).clamp(0, 25001);
                w[5] = out.level(8).clamp(0, 25001);
                w[6] = out.level(9).clamp(0, 32767);
                w[7] = level;
                w[8] = i32::from(self.down[i]);
                w[9] = 0;
                w[10] = i32::from(jump);
                w[11] = 0;
                w[12] = i32::from(collision);
                w[13] = self.speed_word.clamp(0, 1000);
                w[14] = s.class.clamp(1, 5);
                w[15] = footstep_surface(tuning, self.materials[i]).clamp(1, 7);
                w[16] = s.weight.clamp(1, 5);
                for k in 0..3 {
                    w[17 + k] = t.tail[k].clamp(0, 32767);
                }
                self.packets[i] = Some(w);
                cmds.push(WorldCommand::Redeliver { owner, slot: WorldSlot::PedFootstep(i as u8), words: w.to_vec() });
            }
        }
        // `sub_824D84D0`: the Splice steps follow the owner (level, pitch, azimuth in degrees).
        let block = [
            out.level(if s.close { 4 } else { 3 }) as f32 * LEVEL,
            out.pitch(5) as f32 * PITCH,
            out.raw(0) as f32 * DEGREES,
            dt,
            0.0,
            1.0,
        ];
        for i in 0..2 {
            if let Some(sound) = self.sounds[i] {
                if host.alive(sound) {
                    host.update(sound, block);
                } else {
                    host.release(sound);
                    self.sounds[i] = None;
                }
            }
        }
        cmds
    }

    pub fn release(&mut self, owner: u64, host: &mut dyn SpliceHost) -> Vec<WorldCommand> {
        let mut out = Vec::new();
        for i in 0..2 {
            if self.packets[i].take().is_some() {
                out.push(WorldCommand::Release { owner, slot: WorldSlot::PedFootstep(i as u8) });
            }
            if let Some(sound) = self.sounds[i].take() {
                host.release(sound);
            }
        }
        out
    }
}

/// A request `SFXObj_PedestrianSpeech` hands the speech manager (`sub_824AB6C8` / `sub_824AC438`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SpeechRequest {
    pub owner: u64,
    /// The speech value after the object's remap (7 / 8 → 30 after 29, else 51).
    pub value: i32,
    /// 1 when the ped's `+148` exceeds `+156`, else 2.
    pub flag: i32,
}

/// `SFXObj_PedestrianSpeech`'s state.
#[derive(Clone, Debug)]
pub struct PedSpeech {
    /// `+36`: the speech value last handed on (the constructor `sub_824D90D8` sets 68).
    pub last: i32,
    /// `+160`: the photographer's repeat timer (seconds).
    pub photo_timer: f32,
    /// `+148`: the phone ring of value 49 (a Splice sound).
    pub ring: Option<SoundId>,
    /// Rings started (diagnostics).
    pub rings: u64,
}

impl Default for PedSpeech {
    fn default() -> Self {
        Self { last: 68, photo_timer: 0.0, ring: None, rings: 0 }
    }
}

impl PedSpeech {
    /// vfunc 9 (`sub_824D9908`): a request when the value changes.
    /// - **29** (the photographer, `PictureTaking`): while the game flag `photo` is set (system
    ///   byte `*(0x830CFDC4)+912`, meaning not traced) the timer `+160` accumulates `dt`; when it
    ///   has reached [`PedObjectTuning::photo_repeat`] it restarts at 0 and the request repeats.
    /// - **49** (the phone, sent by the code, not the state graphs): the old ring is stopped and
    ///   the ring Splice starts (`sub_824D9C70`; no request now: [`Self::update`] requests the
    ///   answer when it ends).
    /// - 7 / 8 → 30 after a 29, else 51.
    pub fn process(&mut self, owner: u64, s: &PedState, dt: f32, photo: bool, t: &PedObjectTuning, host: &mut dyn SpliceHost) -> Option<SpeechRequest> {
        let value = s.speech_value;
        let mut repeat = false;
        if photo && value == 29 {
            if self.photo_timer >= t.photo_repeat {
                repeat = true;
                self.photo_timer = 0.0;
            } else {
                self.photo_timer += dt;
            }
        }
        if value == self.last && !repeat {
            return None;
        }
        let previous = self.last;
        self.last = value;
        if value == 49 {
            if let Some(old) = self.ring.take() {
                host.release(old);
            }
            host.set_route(crate::bus::Route::default());
            self.ring = host.start(&t.ring_bank, t.ring_id, [0.0, 1.0, 0.0, dt, 1.0, 1.0]);
            self.rings += u64::from(self.ring.is_some());
            return None;
        }
        let value = if matches!(value, 7 | 8) { if previous == 29 { 30 } else { 51 } } else { value };
        Some(SpeechRequest { owner, value, flag: Self::flag(s) })
    }

    /// The near / far flag of a request (1 when `S+148` > `S+156`, else 2).
    pub fn flag(s: &PedState) -> i32 {
        if s.speech_measure > s.speech_limit { 1 } else { 2 }
    }

    /// The end of vfunc 10 (`sub_824D9AD8`): the ring follows the speaker's speech outputs (`main`
    /// = the main level PedestrianSpeech copies for its lines, `out` the owner's outputs: pitch 1,
    /// azimuth raw 0). When the ring has ended it is freed and the ped requests
    /// [`PedObjectTuning::ring_answer`] (64, `4402_cell_greet`) with its words.
    pub fn update(&mut self, owner: u64, s: &PedState, main: i32, out: &dyn Outputs, dt: f32, t: &PedObjectTuning, host: &mut dyn SpliceHost) -> Option<SpeechRequest> {
        let ring = self.ring?;
        if host.alive(ring) {
            host.update(ring, [main as f32 * LEVEL, out.pitch(1) as f32 * PITCH, out.raw(0) as f32 * DEGREES, dt, 0.0, 1.0]);
            return None;
        }
        host.release(ring);
        self.ring = None;
        Some(SpeechRequest { owner, value: t.ring_answer, flag: Self::flag(s) })
    }

    pub fn release(&mut self, host: &mut dyn SpliceHost) {
        if let Some(ring) = self.ring.take() {
            host.release(ring);
        }
    }
}

/// `SFXObj_PedBodyFall` (Pedestrian object 2, vtable `0x822FCB18`, factory `sub_824F0880`): process
/// `sub_824F0AB8`, update `sub_824F0E50`. When the ped's `BodyFallType` (`S+76`) changes to a
/// non-zero value, one Skate_Collisions sound starts through the collision Splice object
/// (`sub_82497F48`: a mono submix on the eEQChain bus, env send from the last update; each type
/// follows its own volume / pitch outputs, [`PedBodyFall::update`]): type 8 and
/// type 9 each round-robin two slots (`+40/+44`, index `+60`; `+48/+52`, index `+64`), any other
/// value one slot (`+56`); a slot's old sound is stopped first. The recomp shows the pattern of
/// retail's knock-down animations (sessions 163809 / 164620 / 214002 / 222155 / audiox: 75 starts,
/// 9 → 948, 8 → 1184, other → 1183, e.g. 9, +0.1 s other, +0.5 s 9, +0.16 s 9).
#[derive(Clone, Debug, Default)]
pub struct PedBodyFall {
    /// `+36`: the value last seen.
    last: f32,
    /// Type 8 / type 9 slot pairs and their next index.
    pairs: [[Option<SoundId>; 2]; 2],
    next: [usize; 2],
    /// The other types' slot.
    single: Option<SoundId>,
    /// level(7) as of the last update (the env send latched at a start).
    env: i32,
    /// Sounds started and the last container (diagnostics, checks).
    pub starts: u64,
    pub last_id: u32,
}

impl PedBodyFall {
    /// vfunc 9 (`sub_824F0AB8`).
    pub fn process(&mut self, s: &PedState, t: &PedObjectTuning, host: &mut dyn SpliceHost) {
        let v = s.body_fall;
        if v == self.last || v == 0.0 {
            self.last = v;
            return;
        }
        let kind = v as i32;
        let (id, sound) = match kind {
            8 => (t.body_fall_ids[0], &mut self.pairs[0][self.next[0]]),
            9 => (t.body_fall_ids[1], &mut self.pairs[1][self.next[1]]),
            _ => (t.body_fall_ids[2], &mut self.single),
        };
        if let Some(old) = sound.take() {
            host.release(old);
        }
        host.set_route(crate::bus::Route {
            output: crate::bus::Output::Eq(t.body_fall_eq),
            create: true,
            owner_env: self.env.clamp(0, 32767) as f32 * LEVEL,
            mono: true,
        });
        *sound = host.start(&t.body_fall_bank, id, [0.0, 1.0, 0.0, 0.0, 1.0, 1.0]);
        if sound.is_some() {
            self.starts += 1;
            self.last_id = id;
        }
        match kind {
            8 => self.next[0] = (self.next[0] + 1) % 2,
            9 => self.next[1] = (self.next[1] + 1) % 2,
            _ => {}
        }
        self.last = v;
    }

    /// vfunc 10 (`sub_824F0E50`): every live sound follows the owner with its type's own volume /
    /// pitch pair (type 8: out1 / out2, type 9: out3 / out4, other: out5 / out6; MixMap E23 / E24:
    /// −2511 / −2155 / −1844 mB at the source): [volume / 32767, pitch / 4096, raw(0) × 360/65535,
    /// dt, 0, 1], env send level(7) / 32767; an ended one is freed.
    pub fn update(&mut self, out: &dyn Outputs, dt: f32, host: &mut dyn SpliceHost) {
        self.env = out.level(7);
        let deg = out.raw(0) as f32 * DEGREES;
        let block = |v: usize, p: usize| [out.level(v) as f32 * LEVEL, out.pitch(p) as f32 * PITCH, deg, dt, 0.0, 1.0];
        let (a, b) = self.pairs.split_at_mut(1);
        let groups: [(&mut [Option<SoundId>], (usize, usize)); 3] = [(&mut a[0][..], (1, 2)), (&mut b[0][..], (3, 4)), (std::slice::from_mut(&mut self.single), (5, 6))];
        for (sounds, (v, p)) in groups {
            for sound in sounds.iter_mut() {
                let Some(id) = *sound else { continue };
                if host.alive(id) {
                    host.update(id, block(v, p));
                } else {
                    host.release(id);
                    *sound = None;
                }
            }
        }
    }

    /// A sound of this object is live (the host takes the outputs only then).
    pub fn sounding(&self) -> bool {
        self.single.is_some() || self.pairs.iter().flatten().any(Option::is_some)
    }

    /// The update without a live sound: only level(7) is kept (the next start's env send).
    pub fn latch_env(&mut self, level7: i32) {
        self.env = level7;
    }

    pub fn release(&mut self, host: &mut dyn SpliceHost) {
        for sound in self.pairs.iter_mut().flatten().chain(std::iter::once(&mut self.single)) {
            if let Some(id) = sound.take() {
                host.release(id);
            }
        }
    }
}

pub const TAZER_CLASS: &str = "c_tazer";
pub const TAZER_BANK: &str = "Tazer";
pub const TAZER_WORDS: usize = 9;

/// `SFXObj_Tazer` (Pedestrian object 3, vtable `0x822FCB60`, factory `sub_824F12D0`): process
/// `sub_824F1478` posts the `c_tazer` packet (`sub_824B7950`, 9 words) when the ped audio state's
/// tazer byte (`S+80`) is set and none is held, and releases it when the byte clears; update
/// `sub_824F1560` rewrites it from the owner's outputs. The program (`Tazer.abk`) owns a child post
/// to `c_tazer_grn_play` through AEMS op 38 and plays the zap burst while the packet is held: in
/// the recomp (session 164620) every post was followed by Tazer starts 8, 7, then shuffles of 0–6
/// at ~190 / 190 / 130 / 90–100 ms (49 starts over the session's three zaps).
#[derive(Clone, Debug, Default)]
pub struct PedTazer {
    pub packet: Option<[i32; TAZER_WORDS]>,
    /// Posts (diagnostics).
    pub posts: u64,
}

impl PedTazer {
    /// `sub_824B7950`: [32767, 0, 4096, 0, 25000, 0, 0, 0, the audio game block's G+4 byte (0 or 1)].
    pub fn post_words(game_flag: bool) -> [i32; TAZER_WORDS] {
        [32767, 0, 4096, 0, 25000, 0, 0, 0, i32::from(game_flag)]
    }

    /// vfunc 9 (`sub_824F1478`). `game_flag` = the audio game block's G+4 byte (`AudioState::global_224`,
    /// 0 in free skate).
    pub fn process(&mut self, owner: u64, s: &PedState, game_flag: bool) -> Vec<WorldCommand> {
        if s.tazing {
            if self.packet.is_none() {
                let words = Self::post_words(game_flag);
                self.packet = Some(words);
                self.posts += 1;
                return vec![WorldCommand::Post { owner, slot: WorldSlot::PedTazer, class: TAZER_CLASS, words: words.to_vec() }];
            }
        } else if self.packet.take().is_some() {
            return vec![WorldCommand::Release { owner, slot: WorldSlot::PedTazer }];
        }
        Vec::new()
    }

    /// vfunc 10 (`sub_824F1560`): w1 = raw 0, w2 = pitch 1 (≤ 8192), w6 = level 3, w7 = level 2.
    pub fn update(&mut self, owner: u64, out: &dyn Outputs) -> Vec<WorldCommand> {
        let Some(w) = self.packet.as_mut() else { return Vec::new() };
        w[1] = out.raw(0).clamp(0, 65535);
        w[2] = out.pitch(1).clamp(0, 8192);
        w[6] = out.level(3).clamp(0, 32767);
        w[7] = out.level(2).clamp(0, 32767);
        vec![WorldCommand::Redeliver { owner, slot: WorldSlot::PedTazer, words: w.to_vec() }]
    }

    pub fn release(&mut self, owner: u64) -> Vec<WorldCommand> {
        if self.packet.take().is_some() { vec![WorldCommand::Release { owner, slot: WorldSlot::PedTazer }] } else { Vec::new() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bus::Route;

    #[derive(Default)]
    struct Host {
        starts: Vec<(String, u32, [f32; 6])>,
        released: Vec<SoundId>,
        next: u32,
        dead: bool,
    }

    impl SpliceHost for Host {
        fn set_route(&mut self, _: Route) {}
        fn start(&mut self, bank: &str, id: u32, block: [f32; 6]) -> Option<SoundId> {
            self.starts.push((bank.into(), id, block));
            self.next += 1;
            Some(self.next as SoundId)
        }
        fn update(&mut self, _: SoundId, _: [f32; 6]) {}
        fn alive(&self, _: SoundId) -> bool {
            !self.dead
        }
        fn release(&mut self, s: SoundId) {
            self.released.push(s);
        }
    }

    struct Flat;
    impl Outputs for Flat {
        fn level(&self, id: usize) -> i32 {
            [0, 1000, 2000, 3000, 4000, 0, 0, 25000, 0, 900][id.min(9)]
        }
        fn raw(&self, _: usize) -> i32 {
            100
        }
        fn pitch(&self, _: usize) -> i32 {
            4096
        }
    }

    #[test]
    fn footsteps_post_both_feet_and_step_on_plants() {
        let t = PedFootstepTuning::default();
        let mut sfx = PedSfx::default();
        let mut host = Host::default();
        let mut s = PedState { speed: 1.3, ..Default::default() };
        let c = sfx.process(5, &s, &t, &mut host, 1.0 / 30.0);
        assert_eq!(c.len(), 2);
        let WorldCommand::Post { slot, words, .. } = &c[0] else { panic!() };
        assert_eq!(*slot, WorldSlot::PedFootstep(1));
        assert_eq!(words[3], 0);
        assert_eq!(words[20], 12);
        assert!(host.starts.is_empty());
        // Foot A plants: one walk step (62) from sk8_foley.
        s.feet = [true, false];
        sfx.process(5, &s, &t, &mut host, 1.0 / 30.0);
        assert_eq!(host.starts.len(), 1);
        assert_eq!((host.starts[0].0.as_str(), host.starts[0].1), ("sk8_foley", 62));
        // Held: no new step. Running speed on foot B's plant: 64.
        s.speed = 8.0;
        s.feet = [true, true];
        sfx.process(5, &s, &t, &mut host, 1.0 / 30.0);
        assert_eq!(host.starts.len(), 2);
        assert_eq!(host.starts[1].1, 64);
        // The update rewrites both packets with the foot flags.
        let tuning = PlayerTuning::default();
        let c = sfx.update(5, &s, &t, &tuning, &Flat, &mut host, 1.0 / 30.0);
        let WorldCommand::Redeliver { words, .. } = &c[0] else { panic!() };
        assert_eq!(words[8], 1);
        assert_eq!(words[7], 1000);
        assert_eq!(words[6], 900);
        assert_eq!(&words[17..20], &[32767, 7000, 25000]);
    }

    #[test]
    fn speech_requests_on_value_changes_with_the_remap() {
        let t = PedObjectTuning::default();
        let mut h = Host::default();
        let mut sp = PedSpeech::default();
        let mut s = PedState { speech_value: 10, speech_measure: 5.0, speech_limit: 3.0, ..Default::default() };
        assert_eq!(sp.process(1, &s, 0.033, false, &t, &mut h), Some(SpeechRequest { owner: 1, value: 10, flag: 1 }));
        assert_eq!(sp.process(1, &s, 0.033, false, &t, &mut h), None);
        s.speech_value = 29;
        sp.process(1, &s, 0.033, false, &t, &mut h);
        s.speech_value = 7;
        s.speech_measure = 1.0;
        assert_eq!(sp.process(1, &s, 0.033, false, &t, &mut h), Some(SpeechRequest { owner: 1, value: 30, flag: 2 }));
        s.speech_value = 8;
        assert_eq!(sp.process(1, &s, 0.033, false, &t, &mut h).map(|r| r.value), Some(51));
        // A fresh speaker starts from 68 (the constructor): value 0 is a change.
        assert_eq!(PedSpeech::default().process(1, &PedState::default(), 0.033, false, &t, &mut h).map(|r| r.value), Some(0));
    }

    #[test]
    fn the_photographer_repeats_while_the_flag_is_set() {
        let t = PedObjectTuning::default();
        let mut h = Host::default();
        let mut sp = PedSpeech::default();
        let s = PedState { speech_value: 29, ..Default::default() };
        let fired: Vec<usize> = (0..95).filter(|_| sp.process(1, &s, 1.0 / 30.0, true, &t, &mut h).is_some()).collect();
        // The change, then each time 1.0 s has accumulated: the frame that reaches it only adds,
        // the next one fires and restarts at 0.
        assert_eq!(fired.len(), 4, "{fired:?}");
        assert_eq!(fired[0], 0);
        assert!((30..=32).contains(&(fired[1] - fired[0])) && (30..=32).contains(&(fired[2] - fired[1])), "{fired:?}");
        let mut sp = PedSpeech::default();
        let n = (0..95).filter(|_| sp.process(1, &s, 1.0 / 30.0, false, &t, &mut h).is_some()).count();
        assert_eq!(n, 1, "no repeat without the flag");
    }

    #[test]
    fn value_49_rings_and_asks_for_the_answer_when_the_ring_ends() {
        let t = PedObjectTuning::default();
        let mut h = Host::default();
        let mut sp = PedSpeech::default();
        let s = PedState { speech_value: 49, speech_measure: 30.0, speech_limit: 20.0, ..Default::default() };
        assert_eq!(sp.process(3, &s, 0.033, false, &t, &mut h), None);
        assert_eq!(h.starts.len(), 1);
        assert_eq!((h.starts[0].0.as_str(), h.starts[0].1), ("CellPhone_Rings", 5));
        assert_eq!(sp.update(3, &s, 9000, &Flat, 0.033, &t, &mut h), None, "ringing");
        h.dead = true;
        assert_eq!(sp.update(3, &s, 9000, &Flat, 0.033, &t, &mut h), Some(SpeechRequest { owner: 3, value: 64, flag: 1 }));
        assert!(sp.ring.is_none());
    }

    #[test]
    fn body_falls_start_one_sound_per_event_and_round_robin_their_slots() {
        let t = PedObjectTuning::default();
        let mut h = Host::default();
        let mut b = PedBodyFall::default();
        // A knock-down pattern: 9, other, 9, 9 (with 0 between, or a repeat after a 0).
        for v in [9.0, 0.0, 1.0, 0.0, 9.0, 0.0, 9.0, 9.0, 0.0] {
            b.process(&PedState { body_fall: v, ..Default::default() }, &t, &mut h);
        }
        assert_eq!(h.starts.iter().map(|s| s.1).collect::<Vec<_>>(), vec![948, 1183, 948, 948]);
        assert!(h.starts.iter().all(|s| s.0 == "Skate_Collisions" && s.2 == [0.0, 1.0, 0.0, 0.0, 1.0, 1.0]));
        // The third 9 reuses the first type-9 slot: its sound (id 1) was stopped first.
        assert_eq!(h.released, vec![1]);
        b.update(&Flat, 0.033, &mut h);
        assert_eq!(b.env, 25000, "level(7) latched for the next start");
    }

    #[test]
    fn the_tazer_holds_its_packet_while_tazing() {
        let mut z = PedTazer::default();
        let mut s = PedState::default();
        assert!(z.process(4, &s, false).is_empty());
        s.tazing = true;
        let c = z.process(4, &s, false);
        assert_eq!(c, vec![WorldCommand::Post { owner: 4, slot: WorldSlot::PedTazer, class: TAZER_CLASS, words: vec![32767, 0, 4096, 0, 25000, 0, 0, 0, 0] }]);
        assert!(z.process(4, &s, false).is_empty(), "held");
        let u = z.update(4, &Flat);
        let WorldCommand::Redeliver { words, .. } = &u[0] else { panic!() };
        assert_eq!((words[1], words[2], words[6], words[7]), (100, 4096, 3000, 2000));
        s.tazing = false;
        assert_eq!(z.process(4, &s, false), vec![WorldCommand::Release { owner: 4, slot: WorldSlot::PedTazer }]);
    }
}
