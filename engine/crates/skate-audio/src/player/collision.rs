//! The collision manager (`CSTATEMGR_Collision` with ten `CSTATE_Collision` slots, each one
//! `SFXObj_Collision`): the contact one-shots of two materials meeting — a board landing on a
//! landing-flag surface, the board / truck hitting a rail or ledge at a grind start, deck impacts,
//! body impacts. Written from our reading of the retail code (TU3, reference only; addresses are
//! facts):
//!
//! - post `sub_82486EF0`: a 48-byte message (`+0/+4` materials A/B, `+8/+12` their impact tiers
//!   (3 = none), `+16` a world position, `+32/+36` the two 0..32767 contact levels, bytes
//!   `+40..+42`) goes to the router `sub_824F1818`: the first inactive slot in list order, else the
//!   slot with the oldest stamp (deactivated first, `sub_824F8B58`); `sub_824F8990` stamps it, parks
//!   the message and activates it (`sub_828DF6F0` → `sub_824D1DB8`: the slot's 3-D position
//!   controller takes the message position);
//! - process `sub_824D1E00` (before the MixMap tick): inputs 0 and 1 of the slot's controller
//!   (`0x40030000 | slot << 11`) cleared; while active and holding a voice, input 0 = 32767 and
//!   input 1 = 10000 / 20000 / 32767 for the larger message tier 0 / 1 / 2 (3 = "take the other");
//! - update `sub_824D2318` (after the tick): with no voice held, start them (`sub_824D1F68`: per
//!   material with a tier ≠ 3, the sample `sub_824965D0` → `sub_824967F8` picks from the
//!   material's AudioSurface record by its kind (the Splice bank family: Skate_Collisions /
//!   Skate_Metal / HOM_Set_1), its tier and the other material's collision class; gain record
//!   `+52`, pitch `+68`); else per held voice the block [gain, pitch, azimuth, dt, 0, 1] with gain
//!   = trunc(trunc(level_msg / 32767 × level(category output)) × gain_rec / 32767) / 32767, pitch
//!   = trunc(pitch output × pitch_rec / 4096) / 4096 (output 22 for category 9, else 1), azimuth
//!   raw(0); a voice that ended is released, and with both gone the slot deactivates;
//! - the contact level `sub_82496C58`: the material's window record (class `13E20D398E385A56`) by
//!   tier and the other material's class, interpolated over the poster's [low, high] range; the
//!   impact band `sub_82497088` (class `7DAFF70B3A91CD5D`).
//!
//! - the per-voice "Collision SubMix" `sub_824D25E0` (built before each voice starts, when
//!   [`CollisionManager::submix`] is on): a mono bus (order 4, `Sub0 → Sen0 → Sen0`) the voice's
//!   final Send sums into (6 → 1); Sen0 #1 → the env bus at the Collision output of the
//!   material's category (`sub_824D21D0`: outputs 2..11) / 32767, posted once at build; Sen0 #2
//!   (class default 1.0) → the eEQChain bus `sub_82497BF8` picks from the material's
//!   AudioSurfaceMap words 12..16 by tier and the other material's class (every shipped entry
//!   holds 8 = SFX Master), into the bus's centre.
//!
//! Not modelled: the Hall of Meat override in `sub_824965D0` (global `+564`, materials 97..100 → kind 8), the stamp's
//! global counter (`*(0x830CFD94)+16`, UNCERTAIN: we use the post order) and the flagged
//! (`+57` / `+56`) alternate window / band records, which no ported poster asks for.
use super::Outputs;
use super::contacts::SpliceHost;
use super::objpos::{Listener, ObjPos};
use crate::mixmap::{MixMap, keys};
use crate::splice::SoundId;

/// Slots `sub_824F17B8` builds.
pub const SLOTS: usize = 10;
/// No material (`+620` and the message words).
pub const NO_MATERIAL: i32 = 143;
/// The message's "no tier".
pub const NO_TIER: i32 = 3;
/// The Splice bank of each material kind (the image table's `+0` word).
pub const BANKS: [&str; 3] = ["Skate_Collisions", "Skate_Metal", "HOM_Set_1"];

const INV_32767: f32 = f32::from_bits(0x3800_0100);
const INV_4096: f32 = f32::from_bits(0x3980_0000);
const DEGREES: f32 = f32::from_bits(0x3BB4_00B4);

/// One material's AudioSurface record as the collision code reads it (exported by setup,
/// `audio_export.collision_tuning`).
#[derive(Clone, Debug, PartialEq)]
pub struct Material {
    /// The image table's kind word (Splice bank family; −1 = none).
    pub kind: i32,
    /// Sample ids [tier 2, tier 0 × class 0/1/2, tier 1 × class 0/1/2].
    pub ids: [i32; 7],
    /// `+52` gain (clamped 0..32767 at use), `+68` pitch (4096 = 1), `+56` pitch override flag
    /// and the optional override `0x3A3DD47E8DAFE796`, `+72` category, `+124` landing flag.
    pub gain: i32,
    pub pitch: i32,
    pub pitch_flag: bool,
    pub pitch_alt: i32,
    pub category: i32,
    pub landing: bool,
    /// The contact-level windows (record offsets +0..+36 and +44..+56, 14 words) and `+40` (the
    /// second deck post's level scale, `sub_82496F50`). Zero when the RefSpec does not resolve.
    pub windows: [i32; 14],
    pub scale: f32,
    /// Impact bands `+0`, `+4`, `+8`, `+12` (zero when unresolved).
    pub bands: [f32; 4],
}

impl Default for Material {
    fn default() -> Self {
        Self {
            kind: -1,
            ids: [0; 7],
            gain: 0,
            pitch: 4096,
            pitch_flag: false,
            pitch_alt: 0,
            category: 0,
            landing: false,
            windows: [0; 14],
            scale: 0.0,
            bands: [0.0; 4],
        }
    }
}

impl Material {
    /// The window word at record offset `off` (0..=56, not 40).
    fn window(&self, off: usize) -> i32 {
        let i = if off < 40 { off / 4 } else { off / 4 - 1 };
        self.windows.get(i).copied().unwrap_or(0)
    }
}

/// `sub_82497910`'s jump table for materials 95..=113 (`None` = the AudioSurfaceMap entry 94).
const CLASS_95: [Option<i32>; 19] = [
    Some(1), Some(2), Some(1), Some(0), Some(1), Some(1), Some(1), Some(1), Some(0), Some(1), Some(1), Some(1), Some(0),
    Some(0), Some(0), None, None, None, Some(1),
];

#[derive(Clone, Debug, Default, PartialEq)]
pub struct CollisionTuning {
    /// Materials 0..142.
    pub materials: Vec<Material>,
    /// The AudioSurfaceMap words 7 (+28: the collision class) of entries 0..94.
    pub surface_class: Vec<i32>,
    /// The AudioSurfaceMap words 12..16 (+48..+64: the collision voices' eEQChain bus at tier 0,
    /// tier 1 against class 0 / 1 / 2, tier 2) of entries 0..94; empty = 8 (SFX Master).
    pub surface_eq: Vec<[i32; 5]>,
}

impl CollisionTuning {
    pub fn material(&self, m: i32) -> Option<&Material> {
        usize::try_from(m).ok().and_then(|m| self.materials.get(m))
    }

    /// `sub_82497910`: the collision class (0..2) of a material.
    pub fn class(&self, m: i32) -> i32 {
        let entry = |i: usize| self.surface_class.get(i).copied().unwrap_or(0);
        if (95..=113).contains(&m) {
            if let Some(c) = CLASS_95[(m - 95) as usize] {
                return c;
            }
        }
        if (0..94).contains(&m) { entry(m as usize) } else { entry(94) }
    }

    /// `sub_82497BF8`: the eEQChain bus of a collision voice of `m` at `tier` against `other`
    /// (entry `m` for 0..93, else entry 94; 8 = SFX Master without a table).
    pub fn eq_bus(&self, m: i32, tier: i32, other: i32) -> i32 {
        let entry = if (0..94).contains(&m) { m as usize } else { 94 };
        let word = match tier {
            0 => 0,
            2 => 4,
            _ if other == NO_MATERIAL => 1,
            _ => match self.class(other) {
                0 => 1,
                1 => 2,
                _ => 3,
            },
        };
        self.surface_eq.get(entry).map_or(8, |e| e[word])
    }

    /// `sub_824D21D0`: the Collision output whose level is the Collision SubMix's env send for a
    /// voice of `m`.
    pub fn env_output(&self, m: i32) -> usize {
        let cat = if m >= NO_MATERIAL { 8 } else { self.category(m) };
        match cat {
            0 => 3,
            1 => 4,
            2 => 5,
            3 => 6,
            4 => 7,
            5 => 8,
            6 => 2,
            7 => 9,
            9 => 11,
            _ => 10,
        }
    }

    /// `sub_82496FD0`: the category (`+72`; 8 for a negative material or one without a record).
    pub fn category(&self, m: i32) -> i32 {
        if m < 0 {
            return 8;
        }
        self.material(m).map_or(0, |r| r.category)
    }

    /// `sub_82496C58`: the contact level of `m` against `other` at `tier`, interpolating its
    /// window over [low, high] at `value` (clamped to high).
    pub fn contact_level(&self, m: i32, other: i32, tier: i32, low: f32, high: f32, value: f32) -> i32 {
        if m < 0 || tier == NO_TIER {
            return 0;
        }
        let value = if value < high { value } else { high };
        let zero = Material::default();
        let rec = self.material(m).unwrap_or(&zero);
        let class = if m >= 97 || other == NO_MATERIAL { 0 } else { self.class(other) };
        let (lo, hi) = match tier {
            0 => match class {
                0 => (rec.window(8), rec.window(12)),
                1 => (rec.window(24), rec.window(28)),
                _ => (rec.window(52), rec.window(56)),
            },
            1 => match class {
                0 => (rec.window(0), rec.window(4)),
                1 => (rec.window(16), rec.window(20)),
                _ => (rec.window(44), rec.window(48)),
            },
            2 => (rec.window(32), rec.window(36)),
            _ => (0, 32767),
        };
        if high > low {
            let span = (hi - lo) as f32 / (high - low);
            span.mul_add(value - low, lo as f32) as i32
        } else {
            hi
        }
    }

    /// `sub_82497088`: (tier, low, high) of an impact against the material's bands; tier 3 under
    /// the floor.
    pub fn impact_band(&self, m: i32, impact: f32) -> (i32, f32, f32) {
        let Some(rec) = (m >= 0).then(|| self.material(m)).flatten() else { return (NO_TIER, 0.0, 0.0) };
        let [b0, b4, b8, b12] = rec.bands;
        if impact < b12 {
            return (NO_TIER, 0.0, 0.0);
        }
        if impact > b0 {
            (2, b0, b4)
        } else if impact > b8 {
            (1, b8, b0)
        } else {
            (0, b12, b8)
        }
    }

    /// `sub_82496F50`: the window record's `+40` scale (1 for a material without one).
    pub fn level_scale(&self, m: i32) -> f32 {
        if !(0..NO_MATERIAL).contains(&m) {
            return 1.0;
        }
        self.material(m).map_or(0.0, |r| r.scale)
    }

    /// `sub_824965D0` / `sub_824967F8`: (bank family, sound id, gain word, pitch word) of `m`
    /// against `other` at `tier`; `None` = no sound (id −1).
    pub fn sample(&self, m: i32, other: i32, tier: i32, local: bool) -> Option<(usize, u32, i32, i32)> {
        if !(0..NO_MATERIAL).contains(&m) {
            return None;
        }
        let rec = self.material(m)?;
        if rec.kind < 0 {
            return None;
        }
        let class = if other == NO_MATERIAL { 0 } else { self.class(other) };
        let id = match tier {
            2 => rec.ids[0],
            0 => match class {
                0..=2 => rec.ids[1 + class as usize],
                _ => 0,
            },
            _ => match class {
                0..=2 => rec.ids[4 + class as usize],
                _ => 0,
            },
        };
        if id == -1 {
            return None;
        }
        let gain = rec.gain.clamp(0, 32767);
        let pitch = if local && rec.pitch_flag { rec.pitch_alt } else { rec.pitch };
        Some((rec.kind as usize, id as u32, gain, pitch))
    }

    /// `sub_824D20E8`: the Collision output whose level scales a voice of `m`.
    pub fn level_output(&self, m: i32) -> usize {
        let cat = if m >= NO_MATERIAL { 8 } else { self.category(m) };
        match cat {
            0 => 13,
            1 => 14,
            2 => 15,
            3 => 16,
            4 => 17,
            5 => 18,
            6 => 12,
            7 => 19,
            9 => 21,
            _ => 20,
        }
    }

    /// `sub_824D22B8`: the Collision output whose pitch scales a voice of `m`.
    pub fn pitch_output(&self, m: i32) -> usize {
        if m >= NO_MATERIAL || self.category(m) != 9 { 1 } else { 22 }
    }
}

/// `sub_82486EF0`'s message.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Message {
    pub material: [i32; 2],
    pub tier: [i32; 2],
    pub position: [f32; 3],
    pub level: [i32; 2],
    /// Byte `+40`: the local player (owner `+72` set and `+64` = 0) — selects the pitch override.
    pub local: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct Voice {
    sound: SoundId,
    /// `+44` gain word, `+48` pitch word (`sub_824965D0`).
    gain: i32,
    pitch: i32,
}

#[derive(Clone, Debug, Default, PartialEq)]
struct Slot {
    active: bool,
    stamp: u64,
    message: Option<Message>,
    voices: [Option<Voice>; 2],
    position: ObjPos,
}

/// The manager and its ten slots.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CollisionManager {
    slots: [Slot; SLOTS],
    clock: u64,
    /// Messages posted / voices started (diagnostics).
    pub posts: u64,
    pub starts: u64,
    /// Play the voices through their Collision SubMix (`sub_824D25E0`: mono, env send, eEQChain
    /// bus); the game's host always turns it on (off = straight into SFX Master, the tests).
    pub submix: bool,
}

/// The Collision controller of slot `g`.
pub const fn controller(g: usize) -> u32 {
    keys::obj(keys::slot::COLLISION, 0, g as u32)
}

/// The slot's 3-D position block (SFXCTL slot 3 object 0).
pub const fn position_controller(g: usize) -> u32 {
    keys::ctl(keys::slot::COLLISION, 0, g as u32)
}

impl CollisionManager {
    /// Active slots (diagnostics, tests).
    pub fn active(&self) -> usize {
        self.slots.iter().filter(|s| s.active).count()
    }

    /// `sub_82486EF0` → router `sub_824F1818` → `sub_824F8990`.
    pub fn post(&mut self, msg: Message, host: &mut dyn SpliceHost) {
        let slot = match self.slots.iter().position(|s| !s.active) {
            Some(i) => i,
            None => {
                let mut best = 0;
                for (i, s) in self.slots.iter().enumerate() {
                    if s.stamp < self.slots[best].stamp {
                        best = i;
                    }
                }
                Self::deactivate(&mut self.slots[best], host);
                best
            }
        };
        self.clock += 1;
        let s = &mut self.slots[slot];
        s.stamp = self.clock;
        s.message = Some(msg);
        s.active = true;
        s.voices = [None, None];
        self.posts += 1;
    }

    /// `sub_828DF770` with the component's release: the voices stop, the message goes.
    fn deactivate(s: &mut Slot, host: &mut dyn SpliceHost) {
        for v in s.voices.iter_mut() {
            if let Some(v) = v.take() {
                host.release(v.sound);
            }
        }
        s.active = false;
        s.message = None;
    }

    /// `sub_824D1E00` for every slot, plus the 3-D position blocks (the message position for an
    /// active slot, inactive otherwise). Before the MixMap tick.
    pub fn process(&mut self, m: &mut MixMap, listener: Option<&Listener>) {
        for (g, s) in self.slots.iter_mut().enumerate() {
            let key = controller(g);
            m.set_input(key, 0, 0);
            m.set_input(key, 1, 0);
            let msg = s.message.filter(|_| s.active);
            match (msg, listener) {
                (Some(msg), Some(l)) => s.position.write(m, position_controller(g), l, Some((msg.position, [0.0; 3]))),
                _ => s.position.write(m, position_controller(g), &Listener::default(), None),
            }
            let Some(msg) = msg else { continue };
            if s.voices.iter().all(Option::is_none) {
                continue;
            }
            m.set_input(key, 0, 32767);
            let [a, b] = msg.tier;
            let tier = if a == NO_TIER {
                b
            } else if b == NO_TIER || a > b {
                a
            } else {
                b
            };
            let weight = match tier {
                1 => 20000,
                2 => 32767,
                _ => 10000,
            };
            m.set_input(key, 1, weight);
        }
    }

    /// `sub_824D2318` for every slot (after the tick).
    pub fn update(&mut self, m: &MixMap, t: &CollisionTuning, dt: f32, host: &mut dyn SpliceHost) {
        for g in 0..SLOTS {
            let s = &mut self.slots[g];
            if !s.active {
                continue;
            }
            let Some(msg) = s.message else { continue };
            let out = super::Owner { mixmap: m, key: controller(g) };
            if s.voices.iter().all(Option::is_none) {
                let routes = self.submix.then(|| Self::submix_routes(&msg, t, &out));
                self.starts += Self::start(s, &msg, t, dt, routes, host);
                continue;
            }
            let level = [out.level(t.level_output(msg.material[0])), out.level(t.level_output(msg.material[1]))];
            let pitch = [out.pitch(t.pitch_output(msg.material[0])), out.pitch(t.pitch_output(msg.material[1]))];
            for i in 0..2 {
                let Some(v) = s.voices[i] else { continue };
                if !host.alive(v.sound) {
                    host.release(v.sound);
                    s.voices[i] = None;
                    continue;
                }
                let first = ((msg.level[i] as f32 * INV_32767) * level[i] as f32) as i32;
                let gain = (first as f32 * (v.gain as f32 * INV_32767)) as i32;
                let p = (pitch[i] as f32 * (v.pitch as f32 * INV_4096)) as i32;
                let block = [gain as f32 * INV_32767, p as f32 * INV_4096, out.raw(0) as f32 * DEGREES, dt, 0.0, 1.0];
                host.update(v.sound, block);
            }
            if s.voices.iter().all(Option::is_none) {
                Self::deactivate(s, host);
            }
        }
    }

    /// `sub_824D25E0` per material: the Collision SubMix route of its voice (env level read now,
    /// after this frame's tick; the bus resolved with the message's create byte, UNCERTAIN: byte
    /// `+41`, taken as the local flag — irrelevant while every entry is 8).
    fn submix_routes(msg: &Message, t: &CollisionTuning, out: &dyn Outputs) -> [crate::bus::Route; 2] {
        std::array::from_fn(|i| {
            let (mat, other) = (msg.material[i], msg.material[1 - i]);
            let bus = t.eq_bus(mat, msg.tier[i], other);
            crate::bus::Route {
                output: if (0..8).contains(&bus) { crate::bus::Output::Eq(bus as u8) } else { crate::bus::Output::Master },
                create: msg.local,
                owner_env: out.level(t.env_output(mat)) as f32 * INV_32767,
                mono: true,
            }
        })
    }

    /// `sub_824D1F68`: one voice per material with a tier.
    fn start(s: &mut Slot, msg: &Message, t: &CollisionTuning, dt: f32, routes: Option<[crate::bus::Route; 2]>, host: &mut dyn SpliceHost) -> u64 {
        let mut started = 0;
        for i in 0..2 {
            let (mat, other) = (msg.material[i], msg.material[1 - i]);
            if mat == NO_MATERIAL || msg.tier[i] == NO_TIER {
                continue;
            }
            let Some((kind, id, gain, pitch)) = t.sample(mat, other, msg.tier[i], msg.local) else { continue };
            let Some(bank) = BANKS.get(kind) else { continue };
            if let Some(r) = routes {
                host.set_route(r[i]);
            }
            if let Some(sound) = host.start(bank, id, [0.0, 1.0, 0.0, dt, 1.0, 1.0]) {
                s.voices[i] = Some(Voice { sound, gain, pitch });
                started += 1;
            }
        }
        started
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[derive(Default)]
    struct Log {
        started: Vec<(String, u32)>,
        live: HashMap<SoundId, u32>,
        next: SoundId,
        updates: Vec<(u32, [f32; 6])>,
        route: Option<crate::bus::Route>,
        routes: Vec<Option<crate::bus::Route>>,
    }
    impl SpliceHost for Log {
        fn set_route(&mut self, route: crate::bus::Route) {
            self.route = Some(route);
        }
        fn start(&mut self, bank: &str, id: u32, _: [f32; 6]) -> Option<SoundId> {
            self.started.push((bank.to_owned(), id));
            self.routes.push(self.route.take());
            self.next += 1;
            self.live.insert(self.next, id);
            Some(self.next)
        }
        fn update(&mut self, sound: SoundId, block: [f32; 6]) {
            self.updates.push((self.live[&sound], block));
        }
        fn alive(&self, sound: SoundId) -> bool {
            self.live.contains_key(&sound)
        }
        fn release(&mut self, sound: SoundId) {
            self.live.remove(&sound);
        }
    }

    fn tuning() -> CollisionTuning {
        let mut materials = vec![Material::default(); 143];
        // A concrete-like surface (kind 0) and a metal (kind 1), the board (95) and truck (96).
        materials[2] = Material {
            kind: 0,
            ids: [991, 958, 958, 0, 1047, 1047, 871],
            gain: 30000,
            pitch: 2096,
            windows: [12000, 26000, 6000, 22000, 12000, 26000, 6000, 22000, 16000, 24000, 8000, 20000, 8000, 18000],
            bands: [1.85, 2.0, 1.0, 0.12],
            ..Material::default()
        };
        materials[9] = Material { kind: 1, ids: [400, 401, 402, 403, 404, 405, 406], gain: 32767, category: 3, landing: true, ..Material::default() };
        materials[95] = Material {
            kind: 0,
            ids: [993, 876, 878, 878, 877, 879, 879],
            gain: 28000,
            category: 6,
            windows: [10000, 23000, 10000, 2000, 12000, 24000, 9000, 22000, 11000, 16000, 12000, 24000, 9000, 22000],
            bands: [0.4, 2.0, 0.15, 0.025],
            ..Material::default()
        };
        let mut surface_class = vec![2; 95];
        surface_class[2] = 2;
        surface_class[9] = 1;
        CollisionTuning { materials, surface_class, surface_eq: Vec::new() }
    }

    #[test]
    fn classes_follow_the_jump_table_and_the_surface_map() {
        let t = tuning();
        assert_eq!(t.class(95), 1);
        assert_eq!(t.class(96), 2);
        assert_eq!(t.class(98), 0);
        assert_eq!(t.class(110), 2, "110..112 read entry 94");
        assert_eq!(t.class(9), 1);
    }

    #[test]
    fn the_contact_level_interpolates_the_window() {
        let t = tuning();
        // Board 95 against material 2 (class 2), tier 1 over [0.25, 0.5] at 0.375: (+44, +48) =
        // (12000, 24000) → 18000.
        assert_eq!(t.contact_level(95, 2, 1, 0.25, 0.5, 0.375), 18000);
        // Clamped to high.
        assert_eq!(t.contact_level(95, 2, 1, 0.25, 0.5, 5.0), 24000);
        // Tier 3 is silent; materials ≥ 97 read class 0: tier 0 (+8, +12).
        assert_eq!(t.contact_level(95, 2, 3, 0.0, 1.0, 0.5), 0);
        assert_eq!(t.contact_level(2, 95, 2, 0.0, 0.0, 0.5), 24000, "high ≤ low → the window's high word (+36)");
    }

    #[test]
    fn the_impact_band_tiles_the_record() {
        let t = tuning();
        assert_eq!(t.impact_band(95, 0.01).0, NO_TIER);
        assert_eq!(t.impact_band(95, 0.1), (0, 0.025, 0.15));
        assert_eq!(t.impact_band(95, 0.3), (1, 0.15, 0.4));
        assert_eq!(t.impact_band(95, 1.0), (2, 0.4, 2.0));
    }

    #[test]
    #[ignore = "needs the private install data"]
    fn a_message_starts_two_voices_then_follows_the_outputs() {
        let t = tuning();
        let bytes = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../../assets/private/audio/aems/MixMapSK8.mxb"));
        let Ok(bytes) = bytes else { panic!("missing private data: no MixMap") };
        let mut m = MixMap::from_bytes(&bytes).unwrap();
        let mut c = CollisionManager::default();
        let mut h = Log::default();
        let msg = Message { material: [95, 9], tier: [1, 1], position: [0.0; 3], level: [20000, 30000], local: true };
        c.post(msg, &mut h);
        let l = Listener { camera: [-3.0, 1.5, 0.0], view: [1.0, 0.0, 0.0], ..Listener::default() };
        for id in 1..=4 {
            m.set_input(keys::MASTER, id, 32767);
        }
        c.process(&mut m, Some(&l));
        assert_eq!(m.input(controller(0), 0), 0, "no voice held yet: the gate stays 0");
        m.tick(1.0 / 60.0);
        c.update(&m, &t, 1.0 / 60.0, &mut h);
        // Board 95 against metal 9 (class 1), tier 1 → id 879; metal 9 against the board (class 1) → 405.
        assert_eq!(h.started, [("Skate_Collisions".to_owned(), 879), ("Skate_Metal".to_owned(), 405)]);
        c.process(&mut m, Some(&l));
        assert_eq!((m.input(controller(0), 0), m.input(controller(0), 1)), (32767, 20000));
        m.tick(1.0 / 60.0);
        c.update(&m, &t, 1.0 / 60.0, &mut h);
        let out = super::super::Owner { mixmap: &m, key: controller(0) };
        let lv = out.level(12);
        let expect = ((20000.0f32 * INV_32767 * lv as f32) as i32 as f32 * (28000.0 * INV_32767)) as i32 as f32 * INV_32767;
        let board = h.updates.iter().find(|u| u.0 == 879).unwrap().1;
        assert!((board[0] - expect).abs() < 1e-6, "gain {} vs {expect}", board[0]);
        assert!(board[0] > 0.0, "the category output is open with the gate up");
        // Both voices end → the slot deactivates.
        h.live.clear();
        c.update(&m, &t, 1.0 / 60.0, &mut h);
        assert_eq!(c.active(), 0);
    }

    #[test]
    fn the_submix_picks_its_bus_and_env_output_like_the_retail_tables() {
        let mut t = tuning();
        assert_eq!(t.eq_bus(2, 1, 9), 8, "no table: SFX Master");
        t.surface_eq = (0..95).map(|e| [e * 10, e * 10 + 1, e * 10 + 2, e * 10 + 3, e * 10 + 4]).collect();
        assert_eq!(t.eq_bus(2, 0, 9), 20);
        assert_eq!(t.eq_bus(2, 2, 9), 24);
        assert_eq!(t.eq_bus(2, 1, NO_MATERIAL), 21);
        assert_eq!(t.eq_bus(2, 1, 9), 22, "metal 9 is class 1");
        assert_eq!(t.eq_bus(2, 1, 96), 23, "the truck is class 2");
        assert_eq!(t.eq_bus(95, 1, 2), 943, "materials ≥ 94 read entry 94");
        // Categories 0..9 → outputs 3, 4, 5, 6, 7, 8, 2, 9, 10, 11; none (143) → 10.
        assert_eq!(t.env_output(9), 6);
        assert_eq!(t.env_output(95), 2);
        assert_eq!(t.env_output(2), 3);
        assert_eq!(t.env_output(NO_MATERIAL), 10);
    }

    #[test]
    #[ignore = "needs the private install data"]
    fn with_the_submix_each_voice_starts_on_its_mono_bus_at_the_category_send() {
        let t = tuning();
        let bytes = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../../assets/private/audio/aems/MixMapSK8.mxb"));
        let Ok(bytes) = bytes else { panic!("missing private data: no MixMap") };
        let l = Listener { camera: [-3.0, 1.5, 0.0], view: [1.0, 0.0, 0.0], ..Listener::default() };
        let msg = Message { material: [95, 9], tier: [1, 1], position: [0.0; 3], level: [20000, 30000], local: true };
        let run = |submix: bool| {
            let (mut c, mut h) = (CollisionManager { submix, ..Default::default() }, Log::default());
            let mut m = MixMap::from_bytes(&bytes).unwrap();
            for id in 1..=4 {
                m.set_input(keys::MASTER, id, 32767);
            }
            // The game's MixMap has been running long before the first collision.
            for _ in 0..30 {
                c.process(&mut m, Some(&l));
                m.tick(1.0 / 60.0);
            }
            c.post(msg, &mut h);
            c.process(&mut m, Some(&l));
            m.tick(1.0 / 60.0);
            c.update(&m, &t, 1.0 / 60.0, &mut h);
            let out = super::super::Owner { mixmap: &m, key: controller(0) };
            (h.routes, [out.level(2), out.level(6)])
        };
        assert_eq!(run(false).0, vec![None, None], "off: no route, SFX Master as before");
        let (routes, [board, metal]) = run(true);
        // Board 95 (category 6 → output 2), metal 9 (category 3 → output 6): −2000 mB near the
        // camera, the retail trace's 0.100 cluster.
        let r: Vec<_> = routes.into_iter().map(Option::unwrap).collect();
        assert!(r.iter().all(|r| r.mono && r.output == crate::bus::Output::Master));
        assert_eq!(r[0].owner_env, board as f32 * INV_32767);
        assert_eq!(r[1].owner_env, metal as f32 * INV_32767);
        assert!((r[0].owner_env - 0.1).abs() < 0.02, "{}", r[0].owner_env);
    }

    #[test]
    fn the_router_reuses_the_oldest_slot() {
        let mut c = CollisionManager::default();
        let mut h = Log::default();
        let msg = Message { material: [95, 2], tier: [0, 0], position: [0.0; 3], level: [1, 1], local: true };
        for _ in 0..SLOTS {
            c.post(msg, &mut h);
        }
        assert_eq!(c.active(), SLOTS);
        c.post(Message { level: [7, 7], ..msg }, &mut h);
        assert_eq!(c.active(), SLOTS);
        assert_eq!(c.slots[0].message.unwrap().level, [7, 7], "slot 0 had the oldest stamp");
    }
}

