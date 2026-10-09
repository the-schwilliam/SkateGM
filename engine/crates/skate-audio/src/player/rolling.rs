//! `SFXObj_SkateBoard`'s rolling layers besides the grain bed, skid and squeaks, as pure state
//! machines (process before the MixMap tick, update after it, [`Command`]s for the host). Spec:
//! `audio-specs/aems-board-layers-spec.md`. Written from our reading of the retail code (TU3
//! recompilation, reference only):
//!
//! - [`Rolling`]: the owner's **surface routing** (`sub_824C5CA8`, two trucks, one sounding truck
//!   per distinct surface; surface of a truck `sub_824C82A8`, member key `sub_824C8370`) with its
//!   `Class_rolling` patch for the non-grain rolling surfaces 7, 8, 10, 11, 12, 13 (constructor
//!   `sub_824C4C18`, selectors 1, 2, 10, 12, 11, 9; updater in `sub_824C6BD8`), the grain binds and
//!   stops it asks the bed for ([`GrainEvent`]), SkateBoard inputs 0 (surface-change pulse) and 6
//!   (truck 0 on metal); the **held layers** 0 and 3 of the local player (start `sub_824C9830`,
//!   update `sub_824C9948`); **layer 5** while wheel 0 is on the spidercrack pattern (`sub_824C9F68`
//!   / `sub_824CA038`).
//! - [`Rattle`]: `Rolling_Rattle_Class` (`Rolling_Rattles.abk`), re-posted on every push plant
//!   while the primary truck routes a grain surface (`sub_824C6198`, constructor `sub_824B0248`,
//!   updater `sub_824C80C0`).
//! - [`BoardSlide`]: `c_board_slide` (`board_scrapes.abk`), held while the loose-board state
//!   (`+780`) is set (`sub_824CB3C8`, constructor `sub_824B0670`, updater `sub_824CB4C0`).
//!
//! Every Class_rolling post reaches all four banks bound to the class (`PatchBank_Rolling_Surfaces`,
//! `_SpiderCracks`, `_Objects`, `_RocksBounce`); the selector word decides which program plays.
use super::components::{Command, Slot};
use super::state::NO_MATERIAL;
use super::tuning::PlayerTuning;
use super::{AudioState, Outputs, clamp01, trunc_clamp};

pub const CLASS: &str = "Class_rolling";
pub const RATTLE_CLASS: &str = "Rolling_Rattle_Class";
pub const SLIDE_CLASS: &str = "c_board_slide";
/// The banks these classes bind in (all four Class_rolling banks must be loaded: a post reaches each).
pub const BANKS: &[&str] = &["PatchBank_Rolling_Surfaces", "PatchBank_SpiderCracks", "PatchBank_Objects", "PatchBank_RocksBounce", "Rolling_Rattles", "board_scrapes"];
/// "No contact" rolling surface: the truck's sound stops.
pub const NO_SURFACE: i32 = 14;

/// The vault values these layers read (setup exports them; the defaults are the user's vault).
#[derive(Clone, Debug, PartialEq)]
pub struct RollingTuning {
    /// Class_rolling max km/h per selector 0..15 (`sub_824C97B8`: holder `[0x830CFDA4]+56`, class
    /// `C1831BDB6CB1B1EA` collection `7B0ED922C779B74C` field `880C82E8EF647EC4`, 16 floats).
    pub layer_kmh: [f32; 16],
    /// The rattle's speed range (grain class `7AB23C11B6ADA2DE` of the primary truck's collection,
    /// field `12275AA8AC4A63FB`; 30 in `default`, no member overrides it).
    pub rattle_kmh: f32,
    /// eEQChain tweaks (class `42AFE160E647167C` `default`): rattle `C04832978CDED925` = 8, board
    /// slide `F2B44F93BD91662E` = 7.
    pub rattle_eq: i32,
    pub slide_eq: i32,
    /// The board slide's speed range and level words (class `C1831BDB6CB1B1EA` collection
    /// `621090620F4F936A`: `9635B780C7472A6E` = 15 (m/s·3.6 divisor), loose mode 1
    /// `662CEE73D2E3FE2F` = 15000, mode 2 `AB87C3D1EDDDDCBC` = 15000).
    pub slide_kmh: f32,
    pub slide_level: [i32; 2],
}

impl Default for RollingTuning {
    fn default() -> Self {
        Self {
            layer_kmh: [70.0, 65.0, 65.0, 70.0, 100.0, 45.0, 45.0, 45.0, 45.0, 35.0, 45.0, 45.0, 45.0, 45.0, 45.0, 45.0],
            rattle_kmh: 30.0,
            rattle_eq: 8,
            slide_eq: 7,
            slide_kmh: 15.0,
            slide_level: [15000, 15000],
        }
    }
}

impl RollingTuning {
    fn kmh(&self, selector: i32) -> f32 {
        self.layer_kmh[selector.clamp(0, 15) as usize]
    }
}

/// What the owner's other modulators hand in.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RollingInputs {
    /// The push speed-scale envelope's value while it runs (owner `+912`, idle byte `+1032`,
    /// value `+1028`; `grain::board::PushEnvelope::value`): scales the speed of the per-surface
    /// patch and layer 5 (`sub_824C6B30`), not of the held layers 0 / 3.
    pub speed_scale: Option<f32>,
}

/// A grain the routing binds or stops on a truck (the bed does the binding, spec §1.4 / §2.5).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrainEvent {
    /// Bind both players of `truck` to [`member`]`(surface, soft)` (surfaces 1..6, 9 their own
    /// member; 0 asphalt_rough_hard with the `default` tuning).
    Bind { truck: usize, surface: i32, soft: bool },
    Stop { truck: usize },
}

/// The routing's per-frame outputs for the host.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Routed {
    /// SkateBoard input 0 = 32767 this frame (a truck left a real surface).
    pub surface_pulse: bool,
    /// SkateBoard input 6 = 32767 (truck 0 on rolling surface 9, metal).
    pub on_metal: bool,
    pub grains: Vec<GrainEvent>,
    /// `+1500` the primary truck (reads wheel 0; the other reads wheel 3).
    pub primary: usize,
}

/// `sub_824C8370`'s grain member of a rolling surface: (stem, owner slots A/B) and its tuning
/// collection (`None` = the member's own; the vault keys are listed in the grain spec §1.4).
/// Surfaces without a member (0, and 7, 8, 10..13 which post Class_rolling instead) return the
/// `default` key with the caller's slots left at 0 / 1: a grain bind there plays
/// **asphalt_rough_hard** (slots 0 / 1) with the `default` collection's tuning — what retail does
/// on rolling surface 0 (tag 90).
pub fn member(surface: i32, soft: bool) -> Member {
    let (stem, slots) = match (surface, soft) {
        (1, true) => ("asphalt_rough_soft", [14, 15]),
        (1, false) => ("asphalt_rough_hard", [0, 1]),
        (2, true) => ("concrete_rough_soft", [16, 17]),
        (2, false) => ("concrete_rough_hard", [2, 3]),
        (3, true) => ("asphalt_smooth_soft", [18, 19]),
        (3, false) => ("asphalt_smooth_hard", [4, 5]),
        (4, true) => ("concrete_smooth_soft", [20, 21]),
        (4, false) => ("concrete_smooth_hard", [6, 7]),
        (5, true) => ("wood_ramp_soft", [22, 23]),
        (5, false) => ("wood_ramp_hard", [8, 9]),
        (6, true) => ("concrete_aggregate_soft", [24, 25]),
        (6, false) => ("concrete_aggregate_hard", [10, 11]),
        (9, _) => ("metal_smooth_hard", [12, 13]),
        _ => return Member { stem: "asphalt_rough_hard", slots: [0, 1], default_tuning: true },
    };
    Member { stem, slots, default_tuning: false }
}

/// A grain member as the owner binds it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Member {
    pub stem: &'static str,
    pub slots: [u32; 2],
    /// The key is `default` (`D7EDBD362D7D2152`): the `default` collection's tuning.
    pub default_tuning: bool,
}

/// Whether a rolling surface plays a grain (`sub_824C5CA8`'s switch: 7, 8, 10..13 post Class_rolling).
pub fn grain_surface(surface: i32) -> bool {
    !matches!(surface, 7 | 8 | 10..=13)
}

/// The Class_rolling selector (w4) of a non-grain surface: 7 → 1, 8 → 2, 10 → 10, 11 → 12, 12 → 11,
/// 13 → 9 (−1 elsewhere, never posted).
pub fn selector(surface: i32) -> i32 {
    match surface {
        7 => 1,
        8 => 2,
        10 => 10,
        11 => 12,
        12 => 11,
        13 => 9,
        _ => -1,
    }
}

/// `sub_824C4C18`: a Class_rolling packet (12 words).
pub fn class_rolling_words(speed: i32, selector: i32, surface: i32) -> Vec<i32> {
    let mut w = vec![0i32; 12];
    w[2] = 4096;
    w[3] = speed.clamp(0, 10000);
    w[4] = selector.clamp(0, 15);
    w[6] = surface.clamp(0, 13);
    w[9] = 25000;
    w[11] = 32767;
    w
}

/// `sub_824C6B30`: trunc(clamp01((v·scale / max km/h)·3.6)·10000), v = state `+208` (signed),
/// scaled by the push envelope while it runs.
fn scaled_speed(s: &AudioState, t: &RollingTuning, selector: i32, scale: Option<f32>) -> i32 {
    let v = scale.map_or(s.ground_speed, |k| k * s.ground_speed);
    trunc_clamp(clamp01((v / t.kmh(selector)) * 3.6) * 10000.0, i32::MIN, i32::MAX)
}

/// The held layers' speed (`sub_824C9830` / `sub_824C9948`): as [`scaled_speed`] without the
/// push scale.
fn layer_speed(s: &AudioState, t: &RollingTuning, layer: i32) -> i32 {
    trunc_clamp(clamp01((s.ground_speed / t.kmh(layer)) * 3.6) * 10000.0, i32::MIN, i32::MAX)
}

/// The bridge's per-wheel landed latch (`+464` wheel 0, `+467` wheel 3; the conditioner
/// `sub_82772FD8`): set at a touchdown after more than 5 frames in the air, cleared once in the air
/// for more than 5 frames. Starts clear.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct Landed {
    prev: bool,
    air: u32,
    latch: bool,
}

impl Landed {
    fn step(&mut self, now: bool) {
        if !self.prev && self.air > 5 {
            self.latch = now;
        }
        self.prev = now;
        self.air = if now { 0 } else { self.air + 1 };
    }
}

/// The routing and the Class_rolling layers of one board owner.
#[derive(Clone, Debug, PartialEq)]
pub struct Rolling {
    /// `+768 + 4·truck` the routed surface (14 at start).
    surface: [i32; 2],
    /// `+1320 + 4·truck` the truck's sound kind: true = grain (1, the start value), false =
    /// Class_rolling (0). Kept when the surface becomes 14.
    grain: [bool; 2],
    /// `+1496 + truck` a sound was started on the truck.
    live: [bool; 2],
    /// `+1328 + truck` its grain players run.
    playing: [bool; 2],
    /// `+1500`.
    primary: usize,
    /// `+760` the member key of the last routed surface (`None` = `default`): (surface, soft).
    key: Option<(i32, bool)>,
    /// `+1488 + 4·truck` the posted selector, `+1312 + 4·truck` the per-surface patch.
    selector: [i32; 2],
    patch: [Option<Vec<i32>>; 2],
    /// `+1304` layer 0, `+1308` layer 3 (local player, posted at create).
    held: [Option<Vec<i32>>; 2],
    created: bool,
    /// `+1332` layer 5 (spidercrack).
    spider: Option<Vec<i32>>,
    /// `+1504` the manual latch (`sub_824CA688`).
    manual: bool,
    landed: [Landed; 2],
}

impl Default for Rolling {
    fn default() -> Self {
        Self {
            surface: [NO_SURFACE; 2],
            grain: [true; 2],
            live: [false; 2],
            playing: [false; 2],
            primary: 0,
            key: None,
            selector: [0; 2],
            patch: [None, None],
            held: [None, None],
            created: false,
            spider: None,
            manual: false,
            landed: [Landed::default(); 2],
        }
    }
}

/// The held layers' slots: layer 0, layer 3, layer 5.
const LAYERS: [i32; 2] = [0, 3];

impl Rolling {
    /// `+1500` the primary truck.
    pub fn primary(&self) -> usize {
        self.primary
    }

    /// The primary truck routes a grain surface (`+1320 + 4·primary` == 1; the rattle's gate).
    pub fn primary_is_grain(&self) -> bool {
        self.grain[self.primary]
    }

    /// `+760`: the member key of the last routed surface.
    pub fn last_key(&self) -> Option<(i32, bool)> {
        self.key
    }

    /// `sub_824CA688` (idempotent within a frame).
    fn manual_latch(&mut self, s: &AudioState) -> bool {
        if s.balance {
            self.manual = true;
        } else if self.manual && (s.wheel_count == 0 || s.wheel_count == 4) {
            self.manual = false;
        }
        self.manual
    }

    /// `sub_824C82A8`: the rolling surface under `truck` (the primary truck reads wheel 0's
    /// material, the other wheel 3's): 14 while grinding, or for the local player while the manual
    /// latch holds and the truck's wheel has not landed; material 143 → 3; else AudioSurfaceMap
    /// word 1 (3 without a table).
    pub fn surface_of(&self, s: &AudioState, t: &PlayerTuning, truck: usize) -> i32 {
        let primary = truck == self.primary;
        if s.local && self.manual && !self.landed[usize::from(!primary)].latch {
            return NO_SURFACE;
        }
        if s.grinding {
            return NO_SURFACE;
        }
        let material = s.wheel_material[if primary { 0 } else { 3 }];
        if material >= NO_MATERIAL {
            return 3;
        }
        t.surface_entry(material).map_or(3, |e| e[1])
    }

    /// The held layers' / layer 5's surface word w6 (`sub_824C9948`): the primary truck's surface,
    /// else the other's, else (both 14) 13 while grinding, else unchanged.
    fn layer_surface(&self, s: &AudioState, t: &PlayerTuning, w6: i32) -> i32 {
        let p = self.surface_of(s, t, self.primary);
        let p = if p == NO_SURFACE { self.surface_of(s, t, 1 - self.primary) } else { p };
        if p != NO_SURFACE {
            p.clamp(0, 13)
        } else if s.grinding {
            13
        } else {
            w6
        }
    }

    /// `sub_824C5CA8` (process): the routing of both trucks.
    fn route(&mut self, s: &AudioState, t: &PlayerTuning, cmds: &mut Vec<Command>, out: &mut Routed) {
        let passes = if s.local { 2 } else { 1 };
        for pass in 0..passes {
            let mut truck = if pass == 0 { self.primary } else { 1 - self.primary };
            let mut other = 1 - truck;
            let new = self.surface_of(s, t, truck);
            if new == self.surface[truck] {
                continue;
            }
            if self.surface[truck] != NO_SURFACE {
                out.surface_pulse = true;
                if s.local && !self.live[other] {
                    // Hand the sound to the other truck: it becomes the primary one.
                    self.primary = 1 - self.primary;
                    std::mem::swap(&mut truck, &mut other);
                } else {
                    if !self.grain[truck] {
                        if self.patch[truck].take().is_some() {
                            cmds.push(Command::Release { slot: Slot::RollingSurface(truck as u8) });
                        }
                    } else if self.playing[truck] {
                        out.grains.push(GrainEvent::Stop { truck });
                        self.playing[truck] = false;
                    }
                    self.live[truck] = false;
                }
            }
            self.surface[truck] = new;
            if new == NO_SURFACE {
                continue;
            }
            let m = member(new, s.soft_wheels);
            self.key = (!m.default_tuning).then_some((new, s.soft_wheels));
            let grain = grain_surface(new);
            if new != self.surface[other] {
                if !grain {
                    let sel = selector(new);
                    self.selector[truck] = sel;
                    let w = class_rolling_words(0, sel, new);
                    cmds.push(Command::Post { slot: Slot::RollingSurface(truck as u8), class: CLASS, words: w.clone() });
                    self.patch[truck] = Some(w);
                } else {
                    out.grains.push(GrainEvent::Bind { truck, surface: new, soft: s.soft_wheels });
                    self.playing[truck] = true;
                }
                self.live[truck] = true;
            }
            self.grain[truck] = grain;
        }
    }

    /// Process (before the tick): the held layers' create (first call, local player), the
    /// routing (`sub_824C5CA8`) and layer 5 (`sub_824C9F68`). The host writes SkateBoard input 0
    /// / 6 from [`Routed`] and hands its grain events to the bed.
    pub fn process(&mut self, s: &AudioState, t: &PlayerTuning, inp: &RollingInputs) -> (Vec<Command>, Routed) {
        let r = &t.rolling;
        let mut cmds = Vec::new();
        if !self.created {
            self.created = true;
            if s.local {
                for (i, layer) in LAYERS.into_iter().enumerate() {
                    let w = class_rolling_words(layer_speed(s, r, layer), layer, 3);
                    cmds.push(Command::Post { slot: Slot::RollingLayer(layer as u8), class: CLASS, words: w.clone() });
                    self.held[i] = Some(w);
                }
            }
        }
        self.landed[0].step(s.wheel_contact[0]);
        self.landed[1].step(s.wheel_contact[3]);
        self.manual_latch(s);
        let mut out = Routed::default();
        self.route(s, t, &mut cmds, &mut out);
        out.on_metal = self.surface_of(s, t, 0) == 9;
        out.primary = self.primary;
        // Layer 5 (sub_824C9F68): wheel 0's seam pattern (wheel 3's while the manual latch holds
        // and wheel 0 has not landed); 1 = spidercrack.
        let pattern = if self.manual && !self.landed[0].latch { s.seam_pattern[3] } else { s.seam_pattern[0] };
        if self.spider.is_none() {
            if pattern == 1 {
                let w = class_rolling_words(scaled_speed(s, r, 5, inp.speed_scale), 5, 3);
                cmds.push(Command::Post { slot: Slot::RollingLayer(5), class: CLASS, words: w.clone() });
                self.spider = Some(w);
            }
        } else if pattern != 1 {
            self.spider = None;
            cmds.push(Command::Release { slot: Slot::RollingLayer(5) });
        }
        (cmds, out)
    }

    /// Update (after the tick): the per-surface patches (in `sub_824C6BD8`'s truck loop), layers 0
    /// / 3 (`sub_824C9948`) and layer 5 (`sub_824CA038`), from the SkateBoard owner's outputs.
    pub fn update(&mut self, s: &AudioState, t: &PlayerTuning, inp: &RollingInputs, out: &dyn Outputs) -> Vec<Command> {
        let r = &t.rolling;
        let mut cmds = Vec::new();
        let manual_flag = i32::from(s.balance || s.manual_brake);
        for truck in 0..2 {
            if !self.live[truck] || self.grain[truck] {
                continue;
            }
            let sel = self.selector[truck];
            let Some(w) = self.patch[truck].as_mut() else { continue };
            let speed = scaled_speed(s, r, sel, inp.speed_scale);
            w[0] = 32767;
            w[11] = out.level(1).clamp(0, 32767);
            w[1] = out.raw(0).clamp(0, 65536);
            w[2] = out.pitch(3).clamp(0, 8192);
            w[3] = speed.clamp(0, 10000);
            w[5] = 0;
            w[8] = if sel == 1 { 0 } else { out.level(13).clamp(0, 32767) };
            w[9] = out.level(11).clamp(0, 25000);
            w[10] = out.level(12).clamp(0, 25000);
            w[7] = manual_flag;
            cmds.push(Command::Redeliver { slot: Slot::RollingSurface(truck as u8), words: w.clone() });
        }
        for (i, layer) in LAYERS.into_iter().enumerate() {
            let Some(w6) = self.held[i].as_ref().map(|w| w[6]) else { continue };
            let surface = self.layer_surface(s, t, w6);
            let w = self.held[i].as_mut().unwrap();
            w[0] = 32767;
            w[11] = out.level(if layer == 0 { 7 } else { 9 }).clamp(0, 32767);
            w[1] = out.raw(0).clamp(0, 65536);
            w[2] = out.pitch(8).clamp(0, 8192);
            w[3] = layer_speed(s, r, layer).clamp(0, 10000);
            w[5] = 0;
            w[6] = surface;
            w[7] = manual_flag;
            w[8] = out.level(19).clamp(0, 32767);
            w[9] = out.level(17).clamp(0, 25000);
            w[10] = out.level(18).clamp(0, 25000);
            cmds.push(Command::Redeliver { slot: Slot::RollingLayer(layer as u8), words: w.clone() });
        }
        if let Some(w6) = self.spider.as_ref().map(|w| w[6]) {
            let surface = self.layer_surface(s, t, w6);
            let w = self.spider.as_mut().unwrap();
            w[0] = 32767;
            w[11] = out.level(10).clamp(0, 32767);
            w[1] = out.raw(0).clamp(0, 65536);
            w[2] = out.pitch(8).clamp(0, 8192);
            w[3] = scaled_speed(s, r, 5, inp.speed_scale).clamp(0, 10000);
            w[5] = 0;
            w[6] = surface;
            w[7] = manual_flag;
            w[8] = out.level(19).clamp(0, 32767);
            w[9] = out.level(17).clamp(0, 25000);
            w[10] = out.level(18).clamp(0, 25000);
            cmds.push(Command::Redeliver { slot: Slot::RollingLayer(5), words: w.clone() });
        }
        cmds
    }
}

// ------------------------------------------------------------------------------------- rattle

/// `Rolling_Rattle_Class` (12 words), owner holder `+1300`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Rattle {
    held: Option<Vec<i32>>,
}

/// The rattle's surface code from the last routed member key (`+760`): the hard members of
/// asphalt_smooth 1, concrete_rough 2, concrete_smooth 3, wood_ramp 4, concrete_aggregate 5;
/// anything else (soft members, asphalt_rough, metal, `default`) 0.
pub fn rattle_surface(key: Option<(i32, bool)>) -> i32 {
    match key {
        Some((3, false)) => 1,
        Some((2, false)) => 2,
        Some((4, false)) => 3,
        Some((5, false)) => 4,
        Some((6, false)) => 5,
        _ => 0,
    }
}

/// `sub_824B0248`: w2 4096, w3 speed (0..10000), w4 surface (0..8), w6 1, w8 25000, w10 32767, w11
/// the eEQChain tweak (0..32767).
pub fn rattle_words(speed: i32, surface: i32, eq: i32) -> Vec<i32> {
    let mut w = vec![0i32; 12];
    w[2] = 4096;
    w[3] = speed.clamp(0, 10000);
    w[4] = surface.clamp(0, 8);
    w[6] = 1;
    w[8] = 25000;
    w[10] = 32767;
    w[11] = eq.clamp(0, 32767);
    w
}

impl Rattle {
    /// In `sub_824C6198` (process, after the routing): on a push plant (`+335`) the held rattle is
    /// released; if the primary truck routes a grain surface a new one is posted with speed
    /// trunc(clamp01(((v − 1)·3.6) / 30)·10000).
    pub fn process(&mut self, s: &AudioState, routing: &Rolling, t: &RollingTuning) -> Vec<Command> {
        let mut cmds = Vec::new();
        if !s.push_trigger {
            return cmds;
        }
        if self.held.take().is_some() {
            cmds.push(Command::Release { slot: Slot::RollingRattle });
        }
        if routing.primary_is_grain() {
            let speed = trunc_clamp(clamp01(((s.ground_speed - 1.0) * 3.6) / t.rattle_kmh) * 10000.0, i32::MIN, i32::MAX);
            let w = rattle_words(speed, rattle_surface(routing.last_key()), t.rattle_eq);
            cmds.push(Command::Post { slot: Slot::RollingRattle, class: RATTLE_CLASS, words: w.clone() });
            self.held = Some(w);
        }
        cmds
    }

    /// `sub_824C80C0`: w0 32767, w10 level(6), w1 raw(0), w2 pitch(3), w7 level(16), w8 / w9
    /// filters 14 / 15.
    pub fn update(&mut self, out: &dyn Outputs) -> Vec<Command> {
        let Some(w) = self.held.as_mut() else { return Vec::new() };
        w[0] = 32767;
        w[10] = out.level(6).clamp(0, 32767);
        w[1] = out.raw(0).clamp(0, 65535);
        w[2] = out.pitch(3).clamp(0, 8192);
        w[7] = out.level(16).clamp(0, 32767);
        w[8] = out.level(14).clamp(0, 25000);
        w[9] = out.level(15).clamp(0, 25000);
        vec![Command::Redeliver { slot: Slot::RollingRattle, words: w.clone() }]
    }
}

// --------------------------------------------------------------------------------- board slide

/// `c_board_slide` (12 words), owner holder `+1884`: held while the loose-board state (`+780`:
/// 0 none, 1 or 2; written by the conditioner `sub_827A1B78`, see the spec) is set.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct BoardSlide {
    held: Option<Vec<i32>>,
}

/// The conditioner's loose-board state (audio record `+156` bits 5–6 → state `+780`;
/// `sub_827A1B78` at `0x827A2A60..0x827A2B14`, cleared every frame): with the rider bailing (State
/// `+59` → record `+148` bit 5) or on foot (state 500 → `+152` bit 30), the deck contact byte
/// (`[rec+24]+3475` → `+148` bit 8) and a deck material below 94 (`[rec+24]+12` − 1 → `+476`):
/// 1 when `up_dot` < −0.9 (upside down), 2 when −0.1 < `up_dot` < 0.1 (on its side), else 0.
/// `up_dot` = `[rec+0]+80` · `[rec+32]+80` (copied to `+496`): taken as the deck's up axis against
/// the contact's up — which two vectors these are is UNCERTAIN (spec §4).
pub fn loose_board(bail_or_on_foot: bool, deck_contact: bool, deck_material: u32, up_dot: f32) -> u32 {
    if !(bail_or_on_foot && deck_contact && deck_material < 94) {
        return 0;
    }
    if up_dot < f32::from_bits(0xBF66_6666) {
        1
    } else if up_dot < f32::from_bits(0x3DCC_CCCD) && up_dot > f32::from_bits(0xBDCC_CCCD) {
        2
    } else {
        0
    }
}

/// `sub_824B0670`: w2 4096, w4 25000, w8 the eEQChain tweak, w10 the mode (`+780` == 2).
pub fn slide_words(eq: i32, mode: i32) -> Vec<i32> {
    let mut w = vec![0i32; 12];
    w[2] = 4096;
    w[4] = 25000;
    w[8] = eq.clamp(0, 32767);
    w[10] = mode.clamp(0, 3);
    w
}

impl BoardSlide {
    /// `sub_824CB3C8` (process).
    pub fn process(&mut self, loose: u32, t: &RollingTuning) -> Vec<Command> {
        if self.held.is_none() {
            if loose != 0 {
                let w = slide_words(t.slide_eq, i32::from(loose == 2));
                self.held = Some(w.clone());
                return vec![Command::Post { slot: Slot::BoardSlide, class: SLIDE_CLASS, words: w }];
            }
        } else if loose == 0 {
            self.held = None;
            return vec![Command::Release { slot: Slot::BoardSlide }];
        }
        Vec::new()
    }

    /// `sub_824CB4C0`: w0 32767, w1 raw(0), w2 pitch(23), w3 trunc(clamp01(((v − 0.5) / 15)·3.6)·
    /// 10000), w4 / w5 filters 25 / 26, w6 level(27), w7 level(24), w11 the mode's level word.
    pub fn update(&mut self, s: &AudioState, loose: u32, t: &RollingTuning, out: &dyn Outputs) -> Vec<Command> {
        let Some(w) = self.held.as_mut() else { return Vec::new() };
        w[0] = 32767;
        w[1] = out.raw(0).clamp(0, 65535);
        w[2] = out.pitch(23).clamp(0, 8192);
        w[3] = trunc_clamp(clamp01(((s.ground_speed - 0.5) / t.slide_kmh) * 3.6) * 10000.0, i32::MIN, i32::MAX).clamp(0, 10000);
        w[4] = out.level(25).clamp(0, 25000);
        w[5] = out.level(26).clamp(0, 25000);
        w[6] = out.level(27).clamp(0, 32767);
        w[7] = out.level(24).clamp(0, 32767);
        w[11] = t.slide_level[usize::from(loose == 2)].clamp(0, 32767);
        vec![Command::Redeliver { slot: Slot::BoardSlide, words: w.clone() }]
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

    /// A surface table with word 1 = the rolling surface per material: material m → surface
    /// `map[m]` for the listed ones, 3 otherwise.
    fn tuning(map: &[(u32, i32)]) -> PlayerTuning {
        let mut rows = vec![[0i32; 18]; 95];
        for r in rows.iter_mut() {
            r[1] = 3;
        }
        for &(m, s) in map {
            rows[m as usize][1] = s;
        }
        PlayerTuning { surface_table: rows, ..Default::default() }
    }

    fn roll(kmh: f32, front: u32, rear: u32) -> AudioState {
        AudioState {
            ground_speed: kmh / 3.6,
            wheel_count: 4,
            wheel_contact: [true; 4],
            wheel_material: [front, front, rear, rear],
            ..Default::default()
        }
    }

    fn posts(cmds: &[Command]) -> Vec<(Slot, Vec<i32>)> {
        cmds.iter().filter_map(|c| match c {
            Command::Post { slot, words, .. } => Some((*slot, words.clone())),
            _ => None,
        }).collect()
    }

    #[test]
    fn held_layers_post_at_create_with_the_layer_speed() {
        let t = tuning(&[]);
        let mut r = Rolling::default();
        let (cmds, routed) = r.process(&roll(35.0, 0, 0), &t, &RollingInputs::default());
        let p = posts(&cmds);
        // Layer 0: 35 / 70 → 5000; layer 3: 35 / 70 → 5000 (both max 70 km/h); surface word 3.
        assert_eq!(p[0], (Slot::RollingLayer(0), vec![0, 0, 4096, 5000, 0, 0, 3, 0, 0, 25000, 0, 32767]));
        assert_eq!(p[1].0, Slot::RollingLayer(3));
        assert_eq!((p[1].1[3], p[1].1[4]), (5000, 3));
        // Asphalt smooth (surface 3): a grain bind on the primary truck, no Class_rolling patch.
        assert_eq!(routed.grains, vec![GrainEvent::Bind { truck: 0, surface: 3, soft: false }]);
        assert_eq!(p.len(), 2);
        assert!(!routed.surface_pulse, "from 14: no pulse");
        // Not created twice.
        let (cmds, _) = r.process(&roll(35.0, 0, 0), &t, &RollingInputs::default());
        assert!(posts(&cmds).is_empty());
        // Update: w11 level(7) / level(9), w2 pitch(8), w8 level(19), filters 17/18, raw clamped to 65536.
        let up = r.update(&roll(35.0, 0, 0), &t, &RollingInputs::default(), &Fixed);
        let Command::Redeliver { words, .. } = &up[0] else { panic!() };
        assert_eq!(words, &vec![32767, 65536, 4096, 5000, 0, 0, 3, 0, 1019, 1017, 1018, 1007]);
        let Command::Redeliver { words, .. } = &up[1] else { panic!() };
        assert_eq!(words[11], 1009);
    }

    #[test]
    fn non_grain_surfaces_post_their_patch_and_release_it_on_leaving() {
        // Material 9 (tag 10) → surface 7, material 36 (tag 37) → 13.
        let t = tuning(&[(9, 7), (36, 13)]);
        let mut r = Rolling::default();
        let inp = RollingInputs::default();
        let (cmds, routed) = r.process(&roll(20.0, 9, 9), &t, &inp);
        let p = posts(&cmds);
        assert_eq!(p[2], (Slot::RollingSurface(0), vec![0, 0, 4096, 0, 1, 0, 7, 0, 0, 25000, 0, 32767]));
        assert!(routed.grains.is_empty());
        assert!(!r.primary_is_grain());
        // Update with a push scale: speed (v·1.4 / 65)·3.6.
        let inp = RollingInputs { speed_scale: Some(1.4) };
        let up = r.update(&roll(20.0, 9, 9), &t, &inp, &Fixed);
        let Command::Redeliver { slot, words } = &up[0] else { panic!() };
        let speed = (((20.0f32 / 3.6 * 1.4) / 65.0) * 3.6 * 10000.0) as i32;
        assert_eq!(*slot, Slot::RollingSurface(0));
        // Selector 1: the env send word w8 stays 0.
        assert_eq!(words, &vec![32767, 65536, 4096, speed, 1, 0, 7, 0, 0, 1011, 1012, 1001]);
        // Rear truck (local, second pass) also on 7: same surface as the primary → no second patch.
        // Front onto surface 13: the rear truck has no live sound → the sound is handed over: the
        // other truck becomes primary and posts selector 9, the old patch keeps playing on the rear.
        let (cmds, routed) = r.process(&roll(20.0, 36, 9), &t, &RollingInputs::default());
        assert!(routed.surface_pulse);
        assert_eq!(routed.primary, 1);
        let p = posts(&cmds);
        assert_eq!(p.len(), 1);
        assert_eq!((p[0].0, p[0].1[4], p[0].1[6]), (Slot::RollingSurface(1), 9, 13));
        assert!(!cmds.iter().any(|c| matches!(c, Command::Release { .. })));
        // The rear reaches 13: the rear (now non-primary truck 0) stops its patch, nothing new.
        let (cmds, _) = r.process(&roll(20.0, 36, 36), &t, &RollingInputs::default());
        assert_eq!(cmds, vec![Command::Release { slot: Slot::RollingSurface(0) }]);
        // Grinding: both trucks route 14. The live truck hands its sound to the silent one (which
        // stores 14), then the second pass hands it back: retail never stops the local player's
        // last sounding truck (the MixMap mutes it). Layers report 13.
        let mut g = roll(20.0, 36, 36);
        g.grinding = true;
        let (cmds, routed) = r.process(&g, &t, &RollingInputs::default());
        assert!(cmds.is_empty(), "{cmds:?}");
        assert!(routed.surface_pulse);
        assert_eq!(routed.primary, 1);
        assert!(r.live[1] && r.patch[1].is_some());
        let up = r.update(&g, &t, &RollingInputs::default(), &Fixed);
        let layers: Vec<&Command> = up.iter().filter(|c| matches!(c, Command::Redeliver { slot: Slot::RollingLayer(_), .. })).collect();
        assert_eq!(layers.len(), 2);
        assert!(layers.iter().all(|c| matches!(c, Command::Redeliver { words, .. } if words[6] == 13)));
        assert!(up.iter().any(|c| matches!(c, Command::Redeliver { slot: Slot::RollingSurface(1), .. })), "the patch keeps updating");
    }

    #[test]
    fn a_grain_change_stops_and_binds_and_metal_sets_input_6() {
        // Material 8 (tag 9) → metal 9; material 3 (tag 4) → 2.
        let t = tuning(&[(8, 9), (3, 2)]);
        let mut r = Rolling::default();
        let inp = RollingInputs::default();
        let (_, routed) = r.process(&roll(20.0, 3, 3), &t, &inp);
        assert_eq!(routed.grains, vec![GrainEvent::Bind { truck: 0, surface: 2, soft: false }]);
        // Both trucks change at once to metal: the primary hands over to truck 1 (not live).
        let (_, routed) = r.process(&roll(20.0, 8, 8), &t, &inp);
        assert_eq!(routed.grains, vec![GrainEvent::Bind { truck: 1, surface: 9, soft: false }, GrainEvent::Stop { truck: 0 }]);
        assert!(routed.surface_pulse);
        // Truck 0 now reads wheel 3 (non-primary): metal → input 6.
        assert!(routed.on_metal);
        assert_eq!(r.last_key(), Some((9, false)));
        assert_eq!(member(9, true), Member { stem: "metal_smooth_hard", slots: [12, 13], default_tuning: false });
        assert_eq!(member(0, false), Member { stem: "asphalt_rough_hard", slots: [0, 1], default_tuning: true });
        assert_eq!(member(3, true).stem, "asphalt_smooth_soft");
    }

    #[test]
    fn spidercrack_layer_follows_wheel_0_pattern() {
        let t = tuning(&[]);
        let mut r = Rolling::default();
        let mut s = roll(20.0, 0, 0);
        s.seam_pattern = [1, 0, 0, 0];
        let (cmds, _) = r.process(&s, &t, &RollingInputs::default());
        let p = posts(&cmds);
        // Layer 5 max 45 km/h: (20 / 3.6 / 45)·3.6 → 4444.
        assert_eq!(p.last().unwrap(), &(Slot::RollingLayer(5), vec![0, 0, 4096, 4444, 5, 0, 3, 0, 0, 25000, 0, 32767]));
        let up = r.update(&s, &t, &RollingInputs::default(), &Fixed);
        let Command::Redeliver { words, .. } = up.last().unwrap() else { panic!() };
        assert_eq!(words[11], 1010);
        s.seam_pattern = [11, 1, 1, 1];
        let (cmds, _) = r.process(&s, &t, &RollingInputs::default());
        assert!(cmds.contains(&Command::Release { slot: Slot::RollingLayer(5) }));
    }

    #[test]
    fn manual_lifts_the_front_truck_and_its_sound_follows_wheel_3() {
        let t = tuning(&[]);
        let mut r = Rolling::default();
        let inp = RollingInputs::default();
        // Land first so the latches are set (more than 5 frames in the air, then down).
        let mut air = roll(20.0, 0, 0);
        air.wheel_contact = [false; 4];
        air.wheel_count = 0;
        for _ in 0..8 {
            r.process(&air, &t, &inp);
        }
        r.process(&roll(20.0, 0, 0), &t, &inp);
        assert!(r.landed[0].latch && r.landed[1].latch);
        assert_eq!(r.primary(), 0);
        // A manual on the rear wheels: wheel 0 lifts; after > 5 frames its latch clears → the
        // primary truck routes 14. The silent truck 1 becomes primary (storing 14) and truck 0
        // keeps its grain, now reading wheel 3: no stop, no rebind.
        let mut manual = roll(20.0, 0, 0);
        manual.balance = true;
        manual.wheel_contact = [false, false, true, true];
        manual.wheel_count = 2;
        let mut events = Vec::new();
        let mut pulses = 0;
        for _ in 0..8 {
            let (_, routed) = r.process(&manual, &t, &inp);
            events.extend(routed.grains);
            pulses += usize::from(routed.surface_pulse);
        }
        assert_eq!(r.primary(), 1);
        assert!(events.is_empty(), "{events:?}");
        assert_eq!(pulses, 1);
        assert_eq!(r.surface, [3, NO_SURFACE]);
        // Back on four wheels: truck 1 (wheel 0) stores 3 again without a pulse; truck 0 still sounds.
        let (_, routed) = r.process(&roll(20.0, 0, 0), &t, &inp);
        assert!(routed.grains.is_empty() && !routed.surface_pulse);
        assert_eq!(r.surface, [3, 3]);
    }

    #[test]
    fn rattle_reposts_on_each_push_on_a_grain_surface() {
        let t = tuning(&[(9, 7)]);
        let mut r = Rolling::default();
        let mut k = Rattle::default();
        let mut s = roll(20.0, 0, 0);
        r.process(&s, &t, &RollingInputs::default());
        assert!(k.process(&s, &r, &t.rolling).is_empty(), "no push");
        s.push_trigger = true;
        let cmds = k.process(&s, &r, &t.rolling);
        // ((20/3.6 − 1)·3.6 / 30)·10000 = 5466; asphalt_smooth hard → 1; eq 8.
        let speed = (clamp01(((20.0f32 / 3.6 - 1.0) * 3.6) / 30.0) * 10000.0) as i32;
        assert_eq!(cmds, vec![Command::Post { slot: Slot::RollingRattle, class: RATTLE_CLASS, words: vec![0, 0, 4096, speed, 1, 0, 1, 0, 25000, 0, 32767, 8] }]);
        let up = k.update(&Fixed);
        let Command::Redeliver { words, .. } = &up[0] else { panic!() };
        assert_eq!(words, &vec![32767, 65535, 4096, speed, 1, 0, 1, 1016, 1014, 1015, 1006, 8]);
        let cmds = k.process(&s, &r, &t.rolling);
        assert!(matches!(cmds[0], Command::Release { .. }) && matches!(cmds[1], Command::Post { .. }));
        // Soft wheels: the soft member key → surface code 0.
        assert_eq!(rattle_surface(Some((3, true))), 0);
        // On a Class_rolling surface the primary truck is not grain: released, not reposted.
        let mut c = roll(20.0, 9, 9);
        r.process(&c, &t, &RollingInputs::default());
        c.push_trigger = true;
        assert_eq!(k.process(&c, &r, &t.rolling), vec![Command::Release { slot: Slot::RollingRattle }]);
    }

    #[test]
    fn loose_board_needs_a_bail_or_on_foot_deck_contact_and_an_orientation() {
        assert_eq!(loose_board(true, true, 3, -0.95), 1);
        assert_eq!(loose_board(true, true, 3, 0.05), 2);
        assert_eq!(loose_board(true, true, 3, 0.95), 0, "wheels down");
        assert_eq!(loose_board(false, true, 3, -0.95), 0);
        assert_eq!(loose_board(true, false, 3, -0.95), 0);
        assert_eq!(loose_board(true, true, NO_MATERIAL, -0.95), 0);
    }

    #[test]
    fn board_slide_holds_while_loose() {
        let t = RollingTuning::default();
        let mut b = BoardSlide::default();
        assert!(b.process(0, &t).is_empty());
        assert_eq!(b.process(2, &t), vec![Command::Post { slot: Slot::BoardSlide, class: SLIDE_CLASS, words: vec![0, 0, 4096, 0, 25000, 0, 0, 0, 7, 0, 1, 0] }]);
        let s = AudioState { ground_speed: 5.0, ..Default::default() };
        let up = b.update(&s, 2, &t, &Fixed);
        let Command::Redeliver { words, .. } = &up[0] else { panic!() };
        // ((5 − 0.5) / 15)·3.6 → 10000 (clamped); filters 25/26, levels 27/24, level word 15000.
        assert_eq!(words, &vec![32767, 65535, 4096, 10000, 1025, 1026, 1027, 1024, 7, 0, 1, 15000]);
        assert_eq!(b.process(0, &t), vec![Command::Release { slot: Slot::BoardSlide }]);
    }
}
