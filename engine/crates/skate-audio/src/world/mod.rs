//! World sound sources: retail's audio objects for things that are not the local player
//! (traffic vehicles, pedestrians), engine independent. A future ped or vehicle system only
//! publishes per-object state ([`traffic::VehicleState`], [`peds::PedState`]); this module turns
//! it into MixMap inputs, AEMS packets and Splice / speech starts exactly as retail's
//! `SFXObj_Traffic*` / `SFXObj_Pedestrian*` owners do.
//!
//! Layers:
//! - [`keys`]: the MixMap controller keys of the Traffic (slot 4) and Pedestrian (slot 5) owners
//!   and their 3-D input blocks;
//! - [`owners`]: the fixed instance pools (4 traffic, 15 pedestrian instances in free skate,
//!   `mixmap::RETAIL_INSTANCES`) and the per-instance 3DObjPos writers;
//! - [`traffic`]: `SFXObj_TrafficEngine` (the RPM model and the `TRAFFIC_CAR` packet),
//!   `SFXObj_TrafficHorn` (`TRAFFIC_HORN`, `c_car_alarm`) and `SFXObj_TrafficSkids`
//!   (`TRAFFIC_SKID`);
//! - [`peds`]: `SFXObj_PedestrianSFX`'s footsteps (`livingword_footstep` packets and the
//!   `sk8_foley` Splice steps), `SFXObj_PedestrianSpeech`'s speech requests (and its phone ring),
//!   `SFXObj_PedBodyFall`'s fall one-shots and `SFXObj_Tazer`'s `c_tazer` packet;
//! - [`skaters`]: NPC (AI) skaters' board sounds — the local player's components for the Player
//!   slot's second instance, which retail gives to one NPC skater within 30 m of the camera;
//! - [`speech`]: the streamed speech archives (`livingworldspeech.big`): the clip index and the
//!   reaction → speech event table measured in the recomp; [`speech_manager`]: speech value →
//!   event, the vault tuning gate and the request words; [`speech_rules`]: the speech library's
//!   `.evt` rules, line and take choice; [`speech_player`]: the channel's two streams, the
//!   interrupt / queue rules and the per-frame stream values from the speaker's MixMap owner;
//! - [`crossfade`]: the zone-ambience crossfade layers a crossfade bank's own program opens per
//!   group (`c_main_ambience_crossfade`).
//!
//! Like the player components (`crate::player::components`), every object is a pure state
//! machine with retail's split: `process` before the MixMap tick (posts, releases, owner
//! inputs), `update` after it (packets rewritten from the owner's MixMap outputs and
//! redelivered). They return [`WorldCommand`]s the host applies to the runtime.
//!
//! Read from the TU3 recompilation (addresses in each item's docs); reference only, our own code.
//! Spec notes: `audio-specs/world-traffic-audio.md`, `audio-specs/world-ped-audio.md`, `audio-specs/world-speech.md`.
pub mod ambience;
pub mod announcer;
pub mod crossfade;
pub mod keys;
pub mod owners;
pub mod peds;
pub mod skater_speech;
pub mod skaters;
pub mod speech;
pub mod speech_manager;
pub mod speech_player;
pub mod speech_rules;
pub mod traffic;

/// Which held packet of a world owner a command is about.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum WorldSlot {
    /// `TRAFFIC_CAR` (TrafficEngine `+44`).
    Engine,
    /// `TRAFFIC_HORN` (TrafficHorn `+36`).
    Horn,
    /// `c_car_alarm` (TrafficHorn `+40`, while the vehicle's horn state is 6).
    Alarm,
    /// `TRAFFIC_SKID` (TrafficSkids `+36`).
    Skid,
    /// `livingword_footstep`: foot A (PedestrianSFX `+40`) = 0, foot B (`+224`) = 1.
    PedFootstep(u8),
    /// `c_tazer` (SFXObj_Tazer `+36`, while the ped audio state's tazer byte `+80` is set).
    PedTazer,
}

/// A world owner: the game object (vehicle or ped id the engine system hands out) and the slot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WorldCommand {
    Post { owner: u64, slot: WorldSlot, class: &'static str, words: Vec<i32> },
    Redeliver { owner: u64, slot: WorldSlot, words: Vec<i32> },
    Release { owner: u64, slot: WorldSlot },
}

/// The AEMS banks the world owners post into. Retail loads all of them at once when the living
/// world starts (recomp `all_20261002_164620`: `AEMS_TRAFFIC.csi`, `fstep_livingworld`, `Tazer` at
/// 6.1 s; the eight engine banks, horn, skid and `car_alarms` at 8.8 s); a post reaches every bank
/// bound to its class and each program keeps or destroys its instance by the packet's patch word.
pub const TRAFFIC_BANKS: &[&str] = &[
    "C00_heavy01",
    "C01_family01",
    "C03_sports01",
    "C04_taxi01",
    "C05_truck01",
    "C06_sports02",
    "C07_family02",
    "C08_family03",
    "Traffic_Horn",
    "Traffic_Skid",
    "car_alarms",
];
pub const PED_BANKS: &[&str] = &["fstep_livingworld", "Tazer"];

/// Retail's `rand()` draws as the world owners use them (`sub_82A8AF10`, the C runtime's): the
/// host supplies the generator so tests can pin it. Not the AEMS evaluator's shared generator.
pub trait Draw {
    fn draw(&mut self) -> u32;
}

/// A small deterministic generator for hosts without their own (the MSVC-style LCG; which
/// generator retail's `sub_82A8AF10` runs is not identified, only its use is ported).
#[derive(Clone, Debug)]
pub struct Lcg(pub u32);

impl Draw for Lcg {
    fn draw(&mut self) -> u32 {
        self.0 = self.0.wrapping_mul(214_013).wrapping_add(2_531_011);
        (self.0 >> 16) & 0x7FFF
    }
}

impl<F: FnMut() -> u32> Draw for F {
    fn draw(&mut self) -> u32 {
        self()
    }
}

pub mod speech_queue;
