//! Traffic vehicles' sound objects (MixMap slot 4, `audio-specs/world-traffic-audio.md`):
//! - [`Engine`] = `SFXObj_TrafficEngine` (vtable `0x822FCBA8`): process `sub_824D6110` (vfunc 9),
//!   update `sub_824D6478` (vfunc 10), release `sub_824D6020`; packet `TRAFFIC_CAR` (18 words,
//!   constructor `sub_824D5B20`), banks `C00_heavy01` … `C08_family03`;
//! - [`Horn`] = `SFXObj_TrafficHorn` (vtable `0x822FCBF0`): process `sub_824D6E88`, update
//!   `sub_824D6F98`; packets `TRAFFIC_HORN` (9 words, `sub_824D5C30`, `Traffic_Horn`) and
//!   `c_car_alarm` (9 words, `sub_824D0D58`, `car_alarms`);
//! - [`Skids`] = `SFXObj_TrafficSkids` (vtable `0x822FCC38`): process `sub_824D7650`, update
//!   `sub_824D76B8`; packet `TRAFFIC_SKID` (11 words, `sub_824D5D20`, `Traffic_Skid`).
//!
//! The vehicle side ([`VehicleState`]) is the record the objects read through their owner
//! (`[object+28]`): position `+48`, the heading `+112`, the driver's acceleration `+144`, speed
//! `+148`, horn state `+156`, skid flag `+160`, the `aud_traffic_engine` record key `+168`. Its
//! writer `sub_824B2A28` fills it each frame from the traffic AI's vehicle-audio entry (recomp gap
//! run G1, spec `audio-specs/world-audio-hookin-spec.md` §7.3); a vehicle system fills [`VehicleState`].
//!
//! Every value below is read from the code (constants from the TU3 image); the record fields come
//! from `aud_traffic_engine` (setup export, [`EngineRecord`]). The RPM model in words: within each
//! "gear" (multiples of `gear_speed` m/s, `gears` of them) the target RPM rises linearly from 0 to
//! `max_rpm` at the gear's top speed, plus a ±`wobble_limit` triangle drifting at `wobble_rate`/s,
//! clamped to [idle, max]; the RPM follows within `slew` RPM/s and otherwise rises at
//! `rise`·slew and falls at `fall`·slew. A fall (an up-shift) holds w17 = 1 and a rise w17 = −1 for
//! three updates.
use super::{Draw, WorldCommand, WorldSlot};
use crate::mixmap::MixMap;
use crate::player::{Outputs, clamp01, trunc_clamp};

pub const ENGINE_CLASS: &str = "TRAFFIC_CAR";
pub const HORN_CLASS: &str = "TRAFFIC_HORN";
pub const ALARM_CLASS: &str = "c_car_alarm";
pub const SKID_CLASS: &str = "TRAFFIC_SKID";
pub const ENGINE_WORDS: usize = 18;
pub const HORN_WORDS: usize = 9;
pub const SKID_WORDS: usize = 11;

/// `0x82165A00`: speed → TrafficEngine.in0 (full scale at 20 m/s).
const IN0_SCALE: f32 = f32::from_bits(0x3D4C_CCCD);
/// `0x821747FC`.
const Q15: f32 = 32767.0;
/// `0x822F9124` = −1/32767 (the engine's front / rear split).
const NEG_INV_Q15: f32 = f32::from_bits(0xB800_0100);
/// `0x822F9120`: speed → w13 (engine) / w4 (skids), full scale at 16.38 m/s.
const SPEED_WORD: f32 = 2000.0;
/// `0x820997A8`: `+144` → w15 (engine) / w6 (skids).
const LOAD_WORD: f32 = 3000.0;
/// Updates the shift word stays set after a big RPM change.
const SHIFT_FRAMES: i32 = 3;

/// One `aud_traffic_engine` record (class `0x259095163B974174`), resolved through its parent. Field
/// hashes and the owner offsets they land in (`sub_824D6110`); the first three are read by offset
/// from the record (no hash site).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EngineRecord {
    /// `10C7F64B3253B21F` (record +0, owner `+72`).
    pub idle_rpm: f32,
    /// `DD02885FAFA71D6D` (record +4, owner `+76`).
    pub max_rpm: f32,
    /// `C436B6BC22BC023C` (record +8, u16): the engine bank's patch, packet w14.
    pub patch: i32,
    /// `2C1586C6D46B89DF` (`+80`): the RPM wobble's bound.
    pub wobble_limit: f32,
    /// `D048F5E809B070C0` (`+84`): the wobble's rate (per second).
    pub wobble_rate: f32,
    /// `E6B3BD54DF5AC0A5` (`+88`): rise as a fraction of the slew.
    pub rise: f32,
    /// `7EA0A89887B3746C` (`+92`): fall as a multiple of the slew.
    pub fall: f32,
    /// `7FD84F2C9C374F46` (`+96`): RPM per second the engine follows its target within.
    pub slew: f32,
    /// `E67C4A17326C555D` (`+100`): each gear's top speed step (m/s).
    pub gear_speed: f32,
    /// `07CE76F8BE0066C1` (u16 at the field, `+104`).
    pub gears: i32,
    /// `763DB0A168A49E93` (`+112`): the front / rear layer split by the car's heading.
    pub rear_bias: i32,
}

impl Default for EngineRecord {
    /// The `default` record (the named records override idle, max and patch only).
    fn default() -> Self {
        Self {
            idle_rpm: 850.0,
            max_rpm: 4000.0,
            patch: 2,
            wobble_limit: 8.0,
            wobble_rate: 4.0,
            rise: 0.5,
            fall: 2.0,
            slew: 2000.0,
            gear_speed: 7.0,
            gears: 4,
            rear_bias: 20000,
        }
    }
}

/// The patch the engine posts with (`sub_824D6110`): record patch 1 becomes 7 or 8 for a third of
/// the vehicles each, patch 3 becomes 6 for half (`rand() % 100` once per activation).
pub fn engine_patch(record_patch: i32, rng: &mut dyn Draw) -> i32 {
    match record_patch {
        1 => match rng.draw() % 100 {
            r if r < 33 => 7,
            r if r < 66 => 8,
            _ => 1,
        },
        3 if rng.draw() % 100 < 50 => 6,
        p => p,
    }
}

/// What the traffic objects read from their vehicle each frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VehicleState {
    /// `+48`: the vehicle's position (m, world).
    pub position: [f32; 3],
    /// For the 3DObjPos rates (m/s, world).
    pub velocity: [f32; 3],
    /// `+112`: the heading (the world matrix's forward row, normalised; G1: dot with the recomp's
    /// forward p50 1.0000), which the front / rear split measures against.
    pub direction: [f32; 3],
    /// `+148`: speed (m/s).
    pub speed: f32,
    /// `+144`: the driver's signed acceleration (m/s², G1: −15.64 through a hard stop … +3.02
    /// pulling away, 0 cruising), × 3000 into engine w15 / skid w6.
    pub load: f32,
    /// `+156`: 0 = no horn, 1–5 = the horn kind, 6 = the car alarm.
    pub horn: i32,
    /// `+160`: the tyres skid (skid w5).
    pub skid: i32,
    /// The vehicle's `aud_traffic_engine` record (`+168`).
    pub engine: EngineRecord,
}

impl Default for VehicleState {
    fn default() -> Self {
        Self {
            position: [0.0; 3],
            velocity: [0.0; 3],
            direction: [0.0, 0.0, 1.0],
            speed: 0.0,
            load: 0.0,
            horn: 0,
            skid: 0,
            engine: EngineRecord::default(),
        }
    }
}

fn level(out: &dyn Outputs, id: usize) -> i32 {
    out.level(id).clamp(0, 32767)
}

// ------------------------------------------------------------------------------------- engine

/// `SFXObj_TrafficEngine`'s state (owner offsets in the field docs).
#[derive(Clone, Debug, Default)]
pub struct Engine {
    /// The held `TRAFFIC_CAR` packet (`+44`).
    pub words: Option<[i32; ENGINE_WORDS]>,
    /// `+48`: the patch posted (after the random override).
    pub patch: i32,
    /// `+52`: the engine's RPM.
    pub rpm: f32,
    /// `+56`: the speed last read.
    pub speed: f32,
    /// `+60` / `+64`: the wobble and its direction (±1).
    pub wobble: f32,
    pub wobble_dir: f32,
    /// `+68`: the frame time last read.
    pub dt: f32,
    /// `+72` / `+76`: idle / max RPM of the record at activation.
    pub idle: f32,
    pub max: f32,
    /// `+80` … `+112`: the record's tuning at activation.
    pub record: EngineRecord,
    /// `+116` / `+120`: updates left with w17 = −1 (rise) / +1 (fall).
    pub rising: i32,
    pub falling: i32,
    /// The vehicle record's `+176`: the relative speed TrafficCarPhysics.in0 carries, slewed.
    pub relative: f32,
}

impl Engine {
    /// The constructor's words (`sub_824D5B20`).
    pub fn post_words(patch: i32) -> [i32; ENGINE_WORDS] {
        let mut w = [0; ENGINE_WORDS];
        w[8] = 4096;
        w[9] = 25000;
        w[11] = 32767;
        w[14] = patch.clamp(0, 9);
        w
    }

    /// vfunc 9 (`sub_824D6110`), every frame while the owner is active: post the packet once and
    /// take the record's tuning.
    pub fn process(&mut self, owner: u64, v: &VehicleState, rng: &mut dyn Draw) -> Vec<WorldCommand> {
        if self.words.is_some() {
            return Vec::new();
        }
        let r = v.engine;
        self.patch = engine_patch(r.patch, rng);
        let words = Self::post_words(self.patch);
        self.words = Some(words);
        self.speed = v.speed;
        self.dt = 0.0;
        self.wobble = 0.0;
        self.wobble_dir = 1.0;
        self.rpm = 0.0;
        self.idle = r.idle_rpm;
        self.max = r.max_rpm;
        self.record = r;
        vec![WorldCommand::Post { owner, slot: WorldSlot::Engine, class: ENGINE_CLASS, words: words.to_vec() }]
    }

    /// The target RPM for a speed (`sub_824D6478`'s gear search, before the slew).
    pub fn target_rpm(&self, speed: f32) -> f32 {
        let r = &self.record;
        let mut top = 0.0f32;
        let mut gear = 1;
        while gear <= r.gears {
            top = gear as f32 * r.gear_speed;
            if speed < top {
                break;
            }
            gear += 1;
        }
        let target = (speed * self.max) / top + self.wobble;
        if !(target > self.idle) {
            self.idle
        } else if !(target < self.max) {
            self.max
        } else {
            target
        }
    }

    /// vfunc 10 (`sub_824D6478`), after the tick: the RPM model, the owner input, the packet.
    /// `camera` is the listener record's position (`*(0x830CFDD4)` +0) the front / rear split
    /// measures from; `dt` the audio manager's frame time (`[+16]+60`).
    pub fn update(&mut self, owner: u64, v: &VehicleState, out: &dyn Outputs, camera: [f32; 3], dt: f32, m: Option<(&mut MixMap, u32)>) -> Vec<WorldCommand> {
        let Some(mut w) = self.words else { return Vec::new() };
        let speed = v.speed;
        self.speed = speed;
        // TrafficEngine.in0 = clamp01(speed · 0.05) · 32767 (the controller's set-input, id 0).
        let in0 = trunc_clamp(clamp01(speed * IN0_SCALE) * Q15, 0, 32767);
        if let Some((m, key)) = m {
            m.set_input(key, 0, in0);
        }
        // The wobble: a triangle between ±limit.
        let r = self.record;
        self.dt = dt;
        self.wobble = (r.wobble_rate * self.wobble_dir).mul_add(dt, self.wobble);
        if self.wobble > r.wobble_limit {
            self.wobble_dir = -1.0;
        } else if self.wobble < -r.wobble_limit {
            self.wobble_dir = 1.0;
        }
        let target = self.target_rpm(speed);
        let step = r.slew * self.dt;
        let diff = target - self.rpm;
        if diff > -step {
            if diff < step {
                self.rpm = target;
            } else {
                self.rpm = r.rise.mul_add(step, self.rpm);
                self.rising = SHIFT_FRAMES;
            }
        } else {
            self.rpm = (-r.fall).mul_add(step, self.rpm);
            self.falling = SHIFT_FRAMES;
        }
        if !(self.rpm > self.idle) {
            self.rpm = self.idle;
        } else if !(self.rpm < self.max) {
            self.rpm = self.max;
        }
        let (front, rear, near) = (out.level(3), out.level(4), out.level(5));
        w[0] = trunc_clamp(self.rpm, 0, 10000);
        // The front / rear split: cos of the angle between the vehicle's direction and the
        // listener → vehicle vector (both normalised; retail uses vrsqrtefp + two Newton steps).
        let dot = heading_dot(v.direction, v.position, camera);
        let bias = r.rear_bias as f32 * dot;
        let rear_cut = (rear as f32 * bias) * NEG_INV_Q15;
        let front_cut = ((bias * -1.0) * front as f32) * NEG_INV_Q15;
        w[2] = rear.wrapping_sub(trunc_clamp(rear_cut, i32::MIN, i32::MAX)).clamp(0, 32767);
        w[1] = front.wrapping_sub(trunc_clamp(front_cut, i32::MIN, i32::MAX)).clamp(0, 32767);
        w[3] = near.clamp(0, 32767);
        w[4] = near.clamp(0, 32767);
        w[12] = level(out, 9);
        w[5] = out.raw(0).clamp(0, 65536);
        w[6] = out.raw(1).clamp(0, 65536);
        w[7] = out.raw(2).clamp(0, 65535);
        w[8] = out.pitch(6).clamp(0, 16383);
        w[9] = out.level(7).clamp(0, 25000);
        w[10] = out.level(8).clamp(0, 25000);
        w[15] = trunc_clamp(v.load * LOAD_WORD, -32767, 32767);
        w[17] = if self.falling > 0 {
            self.falling -= 1;
            1
        } else if self.rising > 0 {
            self.rising -= 1;
            -1
        } else {
            0
        };
        w[13] = trunc_clamp(speed * SPEED_WORD, 0, 32767);
        self.words = Some(w);
        vec![WorldCommand::Redeliver { owner, slot: WorldSlot::Engine, words: w.to_vec() }]
    }

    /// vfunc 8 (`sub_824D6020`): the owner went inactive.
    pub fn release(&mut self, owner: u64) -> Vec<WorldCommand> {
        match self.words.take() {
            Some(_) => vec![WorldCommand::Release { owner, slot: WorldSlot::Engine }],
            None => Vec::new(),
        }
    }
}

/// `sub_824B2A28`'s tail (the vehicle audio record writer, every frame before the tick): the
/// record's `+128` (heading × speed) against the listener's velocity (`[listener+48]`), the
/// difference's length capped at 35 (`relative_velocity` record of class `0xC1831BDB6CB1B1EA`,
/// field `11FAA9AADDC78EC0`), slewed toward by 100 × dt (`AB85397C101B0752`) into `+176`, then
/// `+176 / 35 × 32767` → SFXCTL_TrafficCarPhysics input 0 (it opens A11, the +650 mB near boost of
/// B13). The same formula as the NPC skater's PlayerPhysics in13 (recomp gap run G1: `+176`
/// tracked the speed with the listener standing, max 24.6).
pub fn relative_speed_word(relative: &mut f32, v: &VehicleState, listener_velocity: [f32; 3], dt: f32) -> i32 {
    use crate::player::inputs::{RELATIVE_CAP, RELATIVE_SLEW};
    let n = (v.direction[0].powi(2) + v.direction[1].powi(2) + v.direction[2].powi(2)).sqrt();
    let h = if n > 0.0 && n.is_finite() { [v.direction[0] / n, v.direction[1] / n, v.direction[2] / n] } else { [0.0; 3] };
    let d = ((h[0] * v.speed - listener_velocity[0]).powi(2) + (h[1] * v.speed - listener_velocity[1]).powi(2) + (h[2] * v.speed - listener_velocity[2]).powi(2)).sqrt();
    let mut d = if d > RELATIVE_CAP { RELATIVE_CAP } else if d.is_finite() { d } else { 0.0 };
    let step = RELATIVE_SLEW * dt;
    let last = *relative;
    if d > last {
        if d - last > step {
            d = step + last;
        }
    } else if d < last && last - d > step {
        d = last - step;
    }
    *relative = d;
    trunc_clamp((d / RELATIVE_CAP) * Q15, 0, 32767)
}

/// The vehicle record's three points (`sub_824B2A28`): the body `+48`, `+80` = body + heading ×
/// 1 m and `+96` = body − heading × 1 m (constants `0x8231A844` = 1.0 / `0x8216DEE0` = −1.0). The
/// TrafficEngine's 3DObjPos blocks 1 / 2 / 3 take them in that order: block 2 feeds B1 (the
/// engine layer's Doppler, c 1557) → the front, block 3 feeds B2 (the exhaust layer, c 554) → the
/// rear. The record order and the layer roles give the binding; its writer is not read
/// (provisional).
pub fn record_points(v: &VehicleState) -> [[f32; 3]; 3] {
    let n = (v.direction[0].powi(2) + v.direction[1].powi(2) + v.direction[2].powi(2)).sqrt();
    let h = if n > 0.0 && n.is_finite() { [v.direction[0] / n, v.direction[1] / n, v.direction[2] / n] } else { [0.0; 3] };
    let p = v.position;
    [p, std::array::from_fn(|i| p[i] + h[i]), std::array::from_fn(|i| p[i] - h[i])]
}

/// cos of the angle between `direction` and `position − camera` (3-D, as retail's `vmsum3fp`);
/// 0 when either vector is zero.
pub fn heading_dot(direction: [f32; 3], position: [f32; 3], camera: [f32; 3]) -> f32 {
    let d = [position[0] - camera[0], position[1] - camera[1], position[2] - camera[2]];
    let len = |v: [f32; 3]| (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    let (a, b) = (len(direction), len(d));
    if a <= 0.0 || b <= 0.0 || !a.is_finite() || !b.is_finite() {
        return 0.0;
    }
    (direction[0] / a) * (d[0] / b) + (direction[1] / a) * (d[1] / b) + (direction[2] / a) * (d[2] / b)
}

// ------------------------------------------------------------------------------------- horn

/// `SFXObj_TrafficHorn`'s state.
#[derive(Clone, Debug, Default)]
pub struct Horn {
    /// `+36`: the held `TRAFFIC_HORN` packet; `+40` the `c_car_alarm` packet.
    pub horn: Option<[i32; HORN_WORDS]>,
    pub alarm: Option<[i32; HORN_WORDS]>,
    /// `+60`: the horn state last posted (0 when the record's patch is 0).
    pub last: i32,
}

impl Horn {
    /// `sub_824D5C30`: the horn packet with its variant (0..8 from the process's `rand() % 9`).
    pub fn horn_words(variant: i32) -> [i32; HORN_WORDS] {
        [0, variant.clamp(0, 10), 0, 4096, 0, 25000, 0, 32767, 0]
    }

    /// `sub_824D0D58`: the alarm packet with its variant (`rand() & 3`).
    pub fn alarm_words(variant: i32) -> [i32; HORN_WORDS] {
        [0, 32767, 32767, 0, 4096, 25000, 0, 0, variant.clamp(0, 4)]
    }

    /// vfunc 9 (`sub_824D6E88`).
    pub fn process(&mut self, owner: u64, v: &VehicleState, rng: &mut dyn Draw) -> Vec<WorldCommand> {
        let mut out = Vec::new();
        if self.horn.is_none() {
            let words = Self::horn_words((rng.draw() % 9) as i32);
            self.horn = Some(words);
            out.push(WorldCommand::Post { owner, slot: WorldSlot::Horn, class: HORN_CLASS, words: words.to_vec() });
        }
        if v.horn == 6 {
            if self.alarm.is_none() {
                let words = Self::alarm_words((rng.draw() & 3) as i32);
                self.alarm = Some(words);
                out.push(WorldCommand::Post { owner, slot: WorldSlot::Alarm, class: ALARM_CLASS, words: words.to_vec() });
            }
        } else if self.alarm.take().is_some() {
            out.push(WorldCommand::Release { owner, slot: WorldSlot::Alarm });
        }
        out
    }

    /// vfunc 10 (`sub_824D6F98`). `m`: the TrafficHorn controller for its input 0 (the horn on).
    pub fn update(&mut self, owner: u64, v: &VehicleState, out: &dyn Outputs, m: Option<(&mut MixMap, u32)>) -> Vec<WorldCommand> {
        let Some(mut h) = self.horn else { return Vec::new() };
        let mut cmds = Vec::new();
        if v.horn == 6 {
            if let Some((m, key)) = m {
                m.set_input(key, 0, 0);
            }
            h[2] = 0;
            self.horn = Some(h);
            cmds.push(WorldCommand::Redeliver { owner, slot: WorldSlot::Horn, words: h.to_vec() });
            if let Some(mut a) = self.alarm {
                a[0] = 32767;
                a[1] = level(out, 6);
                a[2] = level(out, 10);
                a[3] = out.raw(5).clamp(0, 65535);
                a[4] = out.pitch(7).clamp(0, 8192);
                a[5] = out.level(9).clamp(0, 25000);
                self.alarm = Some(a);
                cmds.push(WorldCommand::Redeliver { owner, slot: WorldSlot::Alarm, words: a.to_vec() });
            }
            return cmds;
        }
        // A horn kind sounds only when the vehicle's engine record has a non-zero patch.
        let state = if v.horn != 0 && v.engine.patch == 0 { 0 } else { v.horn };
        self.last = state;
        if let Some((m, key)) = m {
            m.set_input(key, 0, if state != 0 { 32767 } else { 0 });
        }
        h[0] = 32767;
        h[7] = level(out, 1);
        h[8] = level(out, 8);
        h[2] = state.clamp(0, 6);
        h[4] = out.raw(0).clamp(0, 65535);
        h[3] = out.pitch(2).clamp(0, 32767);
        h[5] = out.level(3).clamp(0, 25000);
        h[6] = out.level(4).clamp(0, 25000);
        self.horn = Some(h);
        cmds.push(WorldCommand::Redeliver { owner, slot: WorldSlot::Horn, words: h.to_vec() });
        cmds
    }

    pub fn release(&mut self, owner: u64) -> Vec<WorldCommand> {
        let mut out = Vec::new();
        if self.horn.take().is_some() {
            out.push(WorldCommand::Release { owner, slot: WorldSlot::Horn });
        }
        if self.alarm.take().is_some() {
            out.push(WorldCommand::Release { owner, slot: WorldSlot::Alarm });
        }
        out
    }
}

// ------------------------------------------------------------------------------------- skids

/// `SFXObj_TrafficSkids`' state.
#[derive(Clone, Debug, Default)]
pub struct Skids {
    /// `+36`: the held `TRAFFIC_SKID` packet.
    pub words: Option<[i32; SKID_WORDS]>,
}

impl Skids {
    /// `sub_824D5D20`.
    pub fn post_words() -> [i32; SKID_WORDS] {
        [0, 0, 0, 4096, 0, 0, 0, 0, 25000, 32767, 0]
    }

    /// vfunc 9 (`sub_824D7650`): post once while active (the program gates on w5).
    pub fn process(&mut self, owner: u64) -> Vec<WorldCommand> {
        if self.words.is_some() {
            return Vec::new();
        }
        let words = Self::post_words();
        self.words = Some(words);
        vec![WorldCommand::Post { owner, slot: WorldSlot::Skid, class: SKID_CLASS, words: words.to_vec() }]
    }

    /// vfunc 10 (`sub_824D76B8`).
    pub fn update(&mut self, owner: u64, v: &VehicleState, out: &dyn Outputs) -> Vec<WorldCommand> {
        let Some(mut w) = self.words else { return Vec::new() };
        w[0] = level(out, 1);
        w[10] = level(out, 6);
        w[2] = out.raw(0).clamp(0, 65535);
        w[5] = v.skid.clamp(0, 1);
        w[4] = trunc_clamp(v.speed * SPEED_WORD, 0, 32767);
        w[3] = out.pitch(3).clamp(0, 20000);
        w[7] = out.level(5).clamp(0, 25000);
        w[8] = out.level(4).clamp(0, 25000);
        w[1] = level(out, 2);
        w[6] = trunc_clamp(v.load * LOAD_WORD, -32767, 32767);
        self.words = Some(w);
        vec![WorldCommand::Redeliver { owner, slot: WorldSlot::Skid, words: w.to_vec() }]
    }

    pub fn release(&mut self, owner: u64) -> Vec<WorldCommand> {
        match self.words.take() {
            Some(_) => vec![WorldCommand::Release { owner, slot: WorldSlot::Skid }],
            None => Vec::new(),
        }
    }
}

// ------------------------------------------------------------------------------------- vehicle

/// One vehicle's three sound objects on a Traffic instance.
#[derive(Clone, Debug, Default)]
pub struct Vehicle {
    pub engine: Engine,
    pub horn: Horn,
    pub skids: Skids,
}

impl Vehicle {
    /// Every object's process (retail's object order on the instance: engine, skids, horn).
    pub fn process(&mut self, owner: u64, v: &VehicleState, rng: &mut dyn Draw) -> Vec<WorldCommand> {
        let mut out = self.engine.process(owner, v, rng);
        out.extend(self.skids.process(owner));
        out.extend(self.horn.process(owner, v, rng));
        out
    }

    /// The record's inputs before the tick (`sub_824B2A28`'s tail): TrafficCarPhysics.in0.
    pub fn write_inputs(&mut self, g: u32, v: &VehicleState, m: &mut MixMap, listener_velocity: [f32; 3], dt: f32) {
        let word = relative_speed_word(&mut self.engine.relative, v, listener_velocity, dt);
        m.set_input(super::keys::traffic_car_physics(g), 0, word);
    }

    /// Every object's update after the tick, on instance `g`'s outputs.
    pub fn update(&mut self, owner: u64, g: u32, v: &VehicleState, m: &mut MixMap, camera: [f32; 3], dt: f32) -> Vec<WorldCommand> {
        use super::keys;
        let engine_key = keys::traffic_engine(g);
        let mut out = {
            let snapshot = OutputsSnapshot::take(m, engine_key, &[7, 8]);
            self.engine.update(owner, v, &snapshot, camera, dt, Some((m, engine_key)))
        };
        out.extend(self.skids.update(owner, v, &OutputsSnapshot::take(m, keys::traffic_skids(g), &[4, 5])));
        let horn_key = keys::traffic_horn(g);
        let snapshot = OutputsSnapshot::take(m, horn_key, &[3, 4, 9]);
        out.extend(self.horn.update(owner, v, &snapshot, Some((m, horn_key))));
        out
    }

    pub fn release(&mut self, owner: u64) -> Vec<WorldCommand> {
        let mut out = self.engine.release(owner);
        out.extend(self.skids.release(owner));
        out.extend(self.horn.release(owner));
        out
    }
}

/// A copy of one owner's outputs (so the owner can write its MixMap inputs while reading them).
/// `filters` are the ids read through the filter reader.
pub struct OutputsSnapshot {
    level: [i32; 32],
    raw: [i32; 32],
    pitch: [i32; 32],
}

impl OutputsSnapshot {
    pub fn take(m: &MixMap, key: u32, filters: &[usize]) -> Self {
        let mut s = Self { level: [0; 32], raw: [0; 32], pitch: [0; 32] };
        for id in 0..32 {
            s.level[id] = if filters.contains(&id) { m.filter_hz(key, id) } else { m.level(key, id) };
            s.raw[id] = m.raw(key, id);
            s.pitch[id] = m.pitch_4096(key, id);
        }
        s
    }
}

impl Outputs for OutputsSnapshot {
    fn level(&self, id: usize) -> i32 {
        self.level.get(id).copied().unwrap_or(0)
    }
    fn raw(&self, id: usize) -> i32 {
        self.raw.get(id).copied().unwrap_or(0)
    }
    fn pitch(&self, id: usize) -> i32 {
        self.pitch.get(id).copied().unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Flat;
    impl Outputs for Flat {
        fn level(&self, id: usize) -> i32 {
            match id {
                3 => 20000,
                4 => 10000,
                5 => 5000,
                7 | 8 => 25000,
                9 => 300,
                _ => 0,
            }
        }
        fn raw(&self, _: usize) -> i32 {
            16384
        }
        fn pitch(&self, _: usize) -> i32 {
            4096
        }
    }

    fn record() -> EngineRecord {
        EngineRecord { idle_rpm: 800.0, max_rpm: 3500.0, patch: 0, ..Default::default() }
    }

    #[test]
    fn patch_override_follows_the_draw() {
        let d = |v: u32| move || v;
        assert_eq!(engine_patch(1, &mut d(32)), 7);
        assert_eq!(engine_patch(1, &mut d(65)), 8);
        assert_eq!(engine_patch(1, &mut d(166)), 1);
        assert_eq!(engine_patch(3, &mut d(49)), 6);
        assert_eq!(engine_patch(3, &mut d(50)), 3);
        assert_eq!(engine_patch(5, &mut d(0)), 5);
    }

    #[test]
    fn engine_posts_the_constructor_words_once() {
        let mut e = Engine::default();
        let v = VehicleState { engine: record(), ..Default::default() };
        let cmds = e.process(7, &v, &mut || 0u32);
        assert_eq!(cmds.len(), 1);
        let WorldCommand::Post { class, words, .. } = &cmds[0] else { panic!() };
        assert_eq!(*class, "TRAFFIC_CAR");
        assert_eq!(words, &vec![0, 0, 0, 0, 0, 0, 0, 0, 4096, 25000, 0, 32767, 0, 0, 0, 0, 0, 0]);
        assert!(e.process(7, &v, &mut || 0u32).is_empty());
    }

    #[test]
    fn rpm_rises_per_gear_and_shifts_down_on_the_next_gear() {
        let mut e = Engine::default();
        let mut v = VehicleState { engine: record(), ..Default::default() };
        e.process(1, &v, &mut || 0u32);
        // Idle at standstill.
        e.update(1, &v, &Flat, [0.0; 3], 1.0 / 30.0, None);
        assert_eq!(e.rpm, 800.0);
        // 6.9 m/s in gear 1 (top 7 m/s): target 6.9 · 3500 / 7 = 3450; rises 1000 RPM/s.
        v.speed = 6.9;
        let mut words = Vec::new();
        for _ in 0..120 {
            let c = e.update(1, &v, &Flat, [0.0; 3], 1.0 / 30.0, None);
            let WorldCommand::Redeliver { words: w, .. } = &c[0] else { panic!() };
            words = w.clone();
        }
        assert!((e.rpm - 3450.0).abs() < 10.0, "{}", e.rpm);
        assert_eq!(words[17], 0);
        // 7.25 m/s: gear 2 (top 14): target 7.25 · 3500 / 14 = 1812.5 → falls at 4000 RPM/s, w17 = 1.
        v.speed = 7.25;
        let c = e.update(1, &v, &Flat, [0.0; 3], 1.0 / 30.0, None);
        let WorldCommand::Redeliver { words: w, .. } = &c[0] else { panic!() };
        assert_eq!(w[17], 1);
        assert!(e.rpm < 3450.0 - 100.0);
        assert_eq!(w[13], 14500);
        assert_eq!(w[0], e.rpm as i32);
    }

    #[test]
    fn front_and_rear_split_by_heading() {
        let mut e = Engine::default();
        let v = VehicleState { engine: record(), position: [0.0, 0.0, 10.0], direction: [0.0, 0.0, 1.0], ..Default::default() };
        e.process(1, &v, &mut || 0u32);
        // Driving away from the camera (dot = 1): the front layer drops, the rear rises.
        let c = e.update(1, &v, &Flat, [0.0; 3], 1.0 / 30.0, None);
        let WorldCommand::Redeliver { words: w, .. } = &c[0] else { panic!() };
        // front 20000 − trunc(−20000 · 20000 · −1/32767) = 20000 − 12207; rear 10000 + 6103.
        assert_eq!(w[1], 7793);
        assert_eq!(w[2], 16103);
        assert_eq!(w[3], 5000);
        assert_eq!(w[12], 300);
    }

    #[test]
    fn horn_needs_a_patch_and_the_alarm_has_its_own_packet() {
        let mut h = Horn::default();
        let mut v = VehicleState { horn: 2, engine: EngineRecord { patch: 4, ..Default::default() }, ..Default::default() };
        let c = h.process(3, &v, &mut || 13u32);
        assert_eq!(c, vec![WorldCommand::Post { owner: 3, slot: WorldSlot::Horn, class: "TRAFFIC_HORN", words: vec![0, 4, 0, 4096, 0, 25000, 0, 32767, 0] }]);
        let c = h.update(3, &v, &Flat, None);
        let WorldCommand::Redeliver { words, .. } = &c[0] else { panic!() };
        assert_eq!(words[2], 2);
        assert_eq!(words[0], 32767);
        v.engine.patch = 0;
        let c = h.update(3, &v, &Flat, None);
        let WorldCommand::Redeliver { words, .. } = &c[0] else { panic!() };
        assert_eq!(words[2], 0, "patch-0 records never honk");
        v.horn = 6;
        let c = h.process(3, &v, &mut || 7u32);
        assert_eq!(c, vec![WorldCommand::Post { owner: 3, slot: WorldSlot::Alarm, class: "c_car_alarm", words: vec![0, 32767, 32767, 0, 4096, 25000, 0, 0, 3] }]);
        v.horn = 0;
        assert_eq!(h.process(3, &v, &mut || 7u32), vec![WorldCommand::Release { owner: 3, slot: WorldSlot::Alarm }]);
    }

    #[test]
    fn relative_speed_slews_toward_the_capped_difference() {
        let v = VehicleState { direction: [0.0, 0.0, 2.0], speed: 20.0, ..Default::default() };
        let mut r = 0.0;
        // 20 m/s against a still listener, 100/s × 0.1 s = 10 per call.
        assert_eq!(relative_speed_word(&mut r, &v, [0.0; 3], 0.1), ((10.0f32 / 35.0) * 32767.0) as i32);
        assert_eq!(relative_speed_word(&mut r, &v, [0.0; 3], 0.1), ((20.0f32 / 35.0) * 32767.0) as i32);
        // A listener moving with the car: the difference falls back.
        assert_eq!(relative_speed_word(&mut r, &v, [0.0, 0.0, 20.0], 0.1), ((10.0f32 / 35.0) * 32767.0) as i32);
        let fast = VehicleState { speed: 80.0, ..v };
        for _ in 0..5 {
            relative_speed_word(&mut r, &fast, [0.0; 3], 0.1);
        }
        assert_eq!(r, 35.0, "capped");
        let pts = record_points(&VehicleState { position: [1.0, 0.0, 1.0], direction: [0.0, 0.0, 3.0], ..Default::default() });
        assert_eq!(pts, [[1.0, 0.0, 1.0], [1.0, 0.0, 2.0], [1.0, 0.0, 0.0]]);
    }

    #[test]
    fn skids_carry_speed_flag_and_load() {
        let mut s = Skids::default();
        let v = VehicleState { speed: 10.0, skid: 1, load: -2.0, ..Default::default() };
        s.process(9);
        let c = s.update(9, &v, &Flat);
        let WorldCommand::Redeliver { words, .. } = &c[0] else { panic!() };
        assert_eq!(words[5], 1);
        assert_eq!(words[4], 20000);
        assert_eq!(words[6], -6000);
        assert_eq!(words[9], 32767);
    }
}
