//! The front-end sounds: retail's front-end audio object, which plays the `fe` records (class
//! `fe`, 237 records: the session marker's cellphone UI, menus, challenges, scores) as Splice
//! one-shots of `sk8_menu`.
//!
//! Written from our reading of the retail code (TU3; reference only, addresses are facts;
//! spec `audio-specs/world-audio-hookin-spec.md` §11 "Session marker sounds"):
//! - the game side asks by record key (`sub_825DFAF0` → the audio system's request, a queued
//!   message to the audio thread);
//! - `sub_824955B8` (on the audio thread) looks the record up: a sk8_menu sound id ≥ 1 at the
//!   record's level becomes a request (`sub_82495828`); level ≤ 0 plays nothing. (A HOM_Set_1 id
//!   and an eMomentSFX are handled on other paths; no front-end record of the session marker sets
//!   them.)
//! - `sub_82495828`: the first of 10 slots that is neither pending nor holding a sound takes it
//!   (none free → the request is dropped);
//! - `sub_824958F0` (each audio frame): a pending slot starts its Splice sound with the block
//!   `[level × volume, 1, 0, 0, 1, 1]`; a playing one is updated with `[level × volume, 1, 0, dt, 1,
//!   1]` until the Splice player says it ended, then released (and re-requested when the request
//!   asked to repeat). `volume` = `[[X+88]+40]` / 32767 for `sk8_menu` and `HOM_Set_1` (bank
//!   indices 5 and 2; `+44` for other banks), X = the audio system: the MixMap Master controller's
//!   output 0 (and 1), 14568 with free skate's Master inputs (a recomp watch run; the host reads
//!   it from its MixMap each frame).
//! - The output is retail's mastering graph (or, with the record's `alt_bus` flag, the front-end
//!   object's second bus): no environment send, no eEQChain. Here that is the default route (SFX
//!   Master, an identity in retail's traces, into the output stage).
use crate::player::contacts::SpliceHost;
use crate::splice::SoundId;

/// Retail's front-end slot count (`sub_82495828` walks 10 slots of 32 bytes).
pub const SLOTS: usize = 10;

/// One `fe` record as the front-end object reads it.
#[derive(Clone, Debug, PartialEq)]
pub struct FeSound {
    /// The record's name (`fe` record key = lookup8 of it), e.g. `cellphone_place_marker`.
    pub name: String,
    /// The `sk8_menu` sound (record or container id); < 1 plays nothing.
    pub id: i32,
    /// The record's level (block gain before the volume option).
    pub level: f32,
    /// A HOM_Set_1 sound and an eMomentSFX (carried, not played by this module).
    pub hom: i32,
    pub moment: i32,
    /// Output to the front-end object's second bus instead of the mastering graph.
    pub alt_bus: bool,
}

/// The `fe` records by key (the install's export) and the Splice bank they play from.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FeTable {
    /// `sk8_menu`.
    pub bank: String,
    pub sounds: std::collections::HashMap<u64, FeSound>,
}

impl FeTable {
    /// The record whose name is `name` (the key is the name's lookup8 hash).
    pub fn named(&self, name: &str) -> Option<(u64, &FeSound)> {
        let key = key(name);
        self.sounds.get(&key).map(|s| (key, s))
    }
}

/// An `fe` record's key: the vault's name hash of its name.
pub fn key(name: &str) -> u64 {
    crate::player::tuning::name_hash(name.as_bytes())
}

/// The records retail's session marker asks for (PlayerUI `sub_82898FC8` and the cellphone UI
/// `sub_826682B0`; recomp, TU3): stable identities, their sounds and levels come from the install.
pub mod marker {
    /// The cellphone (LB) menu opens (`sub_826682B0`, state 2, input 4).
    pub const ACTIVATE: &str = "cellphone_activate";
    /// Place Marker succeeded (`sub_82898FC8`: action 42, the place call returned true).
    pub const PLACE: &str = "cellphone_place_marker";
    /// Place Marker refused (action 42 where a marker can't go).
    pub const ERROR: &str = "cellphone_marker_error";
    /// Go To Marker: the hold completed and the skater is moved (the relocation tick).
    pub const GOTO: &str = "cellphone_goto_marker";
}

#[derive(Clone, Copy, Debug, Default)]
struct Slot {
    key: u64,
    id: u32,
    level: f32,
    pending: bool,
    repeat: bool,
    sound: Option<SoundId>,
}

/// What one frame of the front-end object did (tests, the host's log).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FrameReport {
    /// (record key, sk8_menu id) of each Splice sound started this frame.
    pub started: Vec<(u64, u32)>,
    /// Record keys whose sound ended (released) this frame.
    pub ended: Vec<u64>,
}

/// Retail's front-end audio object (the part that plays `fe` records).
#[derive(Clone, Debug)]
pub struct Frontend {
    slots: [Slot; SLOTS],
    /// The volume word / 32767 (the host sets it from the MixMap's Master output 0 each frame;
    /// 1 until then).
    pub volume: f32,
}

impl Default for Frontend {
    fn default() -> Self {
        Self { slots: [Slot::default(); SLOTS], volume: 1.0 }
    }
}

impl Frontend {
    /// `sub_824955B8` + `sub_82495828`: queue `sound` (record key `key`) for the next frame.
    /// Returns false when nothing will play (no sk8_menu id, level ≤ 0, or all 10 slots busy).
    pub fn request(&mut self, key: u64, sound: &FeSound, repeat: bool) -> bool {
        if sound.id < 1 || sound.level.is_nan() || sound.level <= 0.0 {
            return false;
        }
        let Some(slot) = self.slots.iter_mut().find(|s| !s.pending && s.sound.is_none()) else { return false };
        *slot = Slot { key, id: sound.id as u32, level: sound.level, pending: true, repeat, sound: None };
        true
    }

    /// Whether any slot is pending or playing (the host can skip [`Frontend::frame`] otherwise).
    pub fn busy(&self) -> bool {
        self.slots.iter().any(|s| s.pending || s.sound.is_some())
    }

    /// `sub_824958F0`: one audio frame of `dt` seconds; `bank` = the Splice bank (`sk8_menu`).
    pub fn frame(&mut self, dt: f32, bank: &str, host: &mut dyn SpliceHost) -> FrameReport {
        let mut report = FrameReport::default();
        for slot in &mut self.slots {
            let gain = slot.level * self.volume;
            if slot.pending {
                slot.pending = false;
                slot.sound = host.start(bank, slot.id, [gain, 1.0, 0.0, 0.0, 1.0, 1.0]);
                if slot.sound.is_some() {
                    report.started.push((slot.key, slot.id));
                }
                continue;
            }
            let Some(sound) = slot.sound else { continue };
            if !host.alive(sound) {
                host.release(sound);
                slot.sound = None;
                report.ended.push(slot.key);
                if slot.repeat {
                    slot.pending = true;
                }
                continue;
            }
            host.update(sound, [gain, 1.0, 0.0, dt, 1.0, 1.0]);
        }
        report
    }

    /// Stop everything (a runtime restart or a mod's cleanup): release every sound, drop requests.
    pub fn clear(&mut self, host: &mut dyn SpliceHost) {
        for slot in &mut self.slots {
            if let Some(sound) = slot.sound.take() {
                host.release(sound);
            }
            *slot = Slot::default();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Host {
        started: Vec<(String, u32, [f32; 6])>,
        updates: Vec<(SoundId, [f32; 6])>,
        live: Vec<bool>,
        released: Vec<SoundId>,
    }

    impl SpliceHost for Host {
        fn start(&mut self, bank: &str, id: u32, block: [f32; 6]) -> Option<SoundId> {
            self.started.push((bank.to_owned(), id, block));
            self.live.push(true);
            Some(self.live.len() - 1)
        }
        fn update(&mut self, sound: SoundId, block: [f32; 6]) {
            self.updates.push((sound, block));
        }
        fn alive(&self, sound: SoundId) -> bool {
            self.live[sound]
        }
        fn release(&mut self, sound: SoundId) {
            self.released.push(sound);
        }
    }

    fn fe(id: i32, level: f32) -> FeSound {
        FeSound { name: String::new(), id, level, hom: 0, moment: 0, alt_bus: false }
    }

    #[test]
    fn record_keys_are_the_name_hashes_retail_posts() {
        // The constants UpdateSessionMarker loads (lis/ori pairs at 82899170..82899194, 828994A8).
        assert_eq!(key(marker::PLACE), 0x0D6C_88A3_B91C_828F);
        assert_eq!(key(marker::ERROR), 0x66B3_AFE3_B602_918C);
        assert_eq!(key(marker::GOTO), 0x7F13_5F9F_D28F_7F21);
        assert_eq!(key(marker::ACTIVATE), 0x47FE_75BF_61F1_9941);
    }

    #[test]
    fn a_request_starts_next_frame_then_updates_until_it_ends() {
        let mut f = Frontend::default();
        let mut h = Host::default();
        assert!(f.request(7, &fe(237, 1.0), false));
        assert!(h.started.is_empty(), "nothing before the frame");
        let r = f.frame(1.0 / 30.0, "sk8_menu", &mut h);
        assert_eq!(r.started, [(7, 237)]);
        assert_eq!(h.started, [("sk8_menu".to_owned(), 237, [1.0, 1.0, 0.0, 0.0, 1.0, 1.0])]);
        f.frame(1.0 / 30.0, "sk8_menu", &mut h);
        assert_eq!(h.updates, [(0, [1.0, 1.0, 0.0, 1.0 / 30.0, 1.0, 1.0])]);
        h.live[0] = false;
        let r = f.frame(1.0 / 30.0, "sk8_menu", &mut h);
        assert_eq!(r.ended, [7]);
        assert_eq!(h.released, [0]);
        assert!(!f.busy());
    }

    #[test]
    fn level_and_volume_scale_the_block_gain() {
        let mut f = Frontend { volume: 0.5, ..Default::default() };
        let mut h = Host::default();
        f.request(1, &fe(235, 0.5), false);
        f.frame(0.0, "sk8_menu", &mut h);
        assert_eq!(h.started[0].2[0], 0.25);
    }

    #[test]
    fn silent_records_and_full_slots_play_nothing() {
        let mut f = Frontend::default();
        assert!(!f.request(1, &fe(0, 1.0), false), "no sk8_menu id");
        assert!(!f.request(1, &fe(-1, 1.0), false));
        assert!(!f.request(1, &fe(237, 0.0), false), "level 0");
        for k in 0..SLOTS as u64 {
            assert!(f.request(k, &fe(237, 1.0), false));
        }
        assert!(!f.request(99, &fe(237, 1.0), false), "an 11th request is dropped");
    }

    #[test]
    fn a_repeating_request_restarts_when_its_sound_ends() {
        let mut f = Frontend::default();
        let mut h = Host::default();
        f.request(3, &fe(264, 0.35), true);
        f.frame(0.0, "sk8_menu", &mut h);
        h.live[0] = false;
        f.frame(0.0, "sk8_menu", &mut h);
        f.frame(0.0, "sk8_menu", &mut h);
        assert_eq!(h.started.len(), 2);
    }

    #[test]
    fn clear_releases_and_forgets() {
        let mut f = Frontend::default();
        let mut h = Host::default();
        f.request(3, &fe(236, 1.0), false);
        f.request(4, &fe(237, 1.0), false);
        f.frame(0.0, "sk8_menu", &mut h);
        f.clear(&mut h);
        assert_eq!(h.released, [0, 1]);
        assert!(!f.busy());
    }
}
