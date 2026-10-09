//! `Class_Seams` (`Seams_Bank.abk`, owner = the Cracks controller `0x40010040`): the per-wheel
//! seam and crack hits as the wheels roll over the pattern of the surface under them. Written from
//! our reading of the retail code (TU3, reference only):
//!
//! - constructor `sub_824C1198`: grid cells `+72..+100` = `0x7FFFFFFF`, front/rear distance
//!   accumulators `+104` = 0 / `+108` = 999, previous materials `+112..+124` = 143, latch `+128`,
//!   frame counter `+132` and last-hit frames `+136..+148` = 0;
//! - create `sub_824C13D0`: one 20-word packet per wheel (`sub_824AFDD0`: w1 32767, w4 4096, w5
//!   25000, w10 = the wheel's seam surface 0..8, w11 = soft wheels, w14 = wheel, w19 = eEQChain
//!   `5A837C613E3F41DC` = 8), held for the component's life, toggle bytes `+68..+71` = 1;
//! - process `sub_824C14C8`: Cracks.in0 := 0 and w7 := 0 on every packet; the material history is
//!   cleared in the air; a wheel whose material (`+620`) changed fires a hit with the transition
//!   surface (AudioSurfaceMap word 9 + 5); otherwise, above the pattern's speed threshold (state
//!   `+208`, signed), the pattern trigger `sub_824C1698` runs for axis 0 then axis 1; then every
//!   packet is redelivered;
//! - pattern trigger: wheel 0's seam pattern (`+636`; wheel 3's `+648` while balancing or
//!   manual-braking with wheel 0's landed latch clear) selects the pattern record (none → w13 := 0);
//!   mode 1 (grid): a wheel crossing a grid line on this axis (`sub_824C1CA0`: its world position
//!   `+384 + 16·w` rotated by the record's angle, ÷ (grid × scale), floored, against the stored
//!   cell; never in the air or grinding) fires — per axle one hit (the left wheel's when it crossed,
//!   else the right's) when more than the record's minimum frames passed since the other wheel's
//!   last hit, single (w9 = 1) unless both crossed; the rear axle is skipped while balancing or
//!   manual-braking. Mode 2 (distance; axis 0, on the ground): ground speed × 100 × dt accumulates
//!   front and (below 50) rear distance; past the spacing both front wheels fire and the rear
//!   counter restarts at 50, at 0 both rear wheels fire;
//! - hit `sub_824C1DF8`: w9 = single, w7 = 2 or 1 by the wheel's toggle (flipped each hit: the
//!   program sees a change), w10 = the surface (word 8 of the material's AudioSurfaceMap entry, or
//!   word 9 + 5 for a material change), w11 = soft wheels, Cracks.in0 := 32767;
//! - update `sub_824C1F18` (each packet): w0 32767, w1 = level(1) (level(6) on soft wheels), w2 =
//!   level(5), w3 = raw(0), w4 = pitch(2), w5/w6 = filters 3/4, w8 = clamp01((v − 0.5)·0.08)·10000,
//!   w11 soft, w12 push planted, w13 = the record's class, w15 = |turn·1000| slewed ±100 per packet
//!   write, w16 = record gain × 32767, w17 = balancing or manual-braking, w18 = record level ×
//!   32767; redelivered.
//!
//! Inputs not in the engine: the global time scale of the distance mode (1.0 here) and the
//! owner's active byte (always on). Retail gates the process and the update on that byte
//! (`[record+52]`), not on the local byte: Class_Seams runs for an NPC skater's Player instance too
//! (`world::skaters`; [`Seams::instance`]). The soft word is `sub_824B23C8`'s value, which the state
//! carries in `soft_wheels` (the local player's `+684`; for an NPC see `world::skaters`).
use super::state::NO_MATERIAL;
use super::tuning::{PlayerTuning, SeamPattern};
use super::{AudioState, Outputs, clamp01, trunc_clamp};
use crate::mixmap::{MixMap, keys};

/// The four held packets' slot ids are 0..3 (one per wheel).
pub const CLASS: &str = "Class_Seams";
/// The boot utility the Seams program needs (`Common.abk`, class `Start_up_Play_ctl`, posted once at
/// audio boot after `c_emitter_utility` and before `c_foley_utility`): it implements the function
/// `rnd_call` that the Seams program calls on a hit and answers with three RandomShuffle draws
/// (0..9) into the globals `send_random_0_to_9a` / `9b` / `9c`. The program adds those globals to
/// every player's sample index, so without the utility each (surface, speed, soft) word set plays
/// one sample (index 0 of its eight); with it a hit picks among the eight, as retail does
/// (Listening test 8).
pub const UTILITY_BANK: &str = "Common";
pub const UTILITY: &str = "Start_up_Play_ctl";
/// eEQChain `default` field `5A837C613E3F41DC` (the user's vault: 8 = SFX Master).
pub const EQ_CHAIN: i32 = 8;
const WORDS: usize = 20;
const IDLE_CELL: i32 = i32::MAX;
/// `0x82324510` 999.0 and `0x8220E13C` 50.0 (rear distance), `0x820ED57C` 100.0 (distance scale).
const REAR_IDLE: f32 = 999.0;
const REAR_START: f32 = 50.0;
const DISTANCE_SCALE: f32 = 100.0;
/// `0x8206D110` degrees → radians.
const DEG: f32 = f32::from_bits(0x3C8E_FA35);

/// What a step asks of the host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SeamCommand {
    Post { wheel: usize, words: Vec<i32> },
    Redeliver { wheel: usize, words: Vec<i32> },
    /// Redeliver at an audio block (the end of a hit's one-console-frame pulse,
    /// `Runtime::redeliver_at`).
    RedeliverAt { wheel: usize, words: Vec<i32>, block: u64 },
}

#[derive(Clone, Debug)]
pub struct Seams {
    held: [Option<Vec<i32>>; 4],
    toggle: [bool; 4],
    /// Grid cells per (axis, wheel): `+72 + 4·(wheel + 4·axis)`.
    cells: [i32; 8],
    front: f32,
    rear: f32,
    prev_material: [u32; 4],
    latch: bool,
    frame: i32,
    last: [i32; 4],
    turn: i32,
    /// The pattern record in use (`+36` / `+40`).
    record: SeamPattern,
    /// Wheel 0's landed latch (`+464`, the Contacts conditioner `sub_82772FD8`): set at a touchdown
    /// after more than 5 frames in the air.
    landed0: bool,
    prev0: bool,
    air0: u32,
    /// A hit fired since the last MixMap write (Cracks.in0).
    cracks: bool,
    /// Packets that fired in the current step.
    fired_now: [bool; 4],
    /// The console cadence ([`Seams::frame`]): real time (s), the next virtual call, the wheel
    /// positions at the end of the last real frame, per packet the audio block at which a hit's w7
    /// ends, and the pulse length's fractional block.
    clock: f64,
    next_call: f64,
    last_wheels: Option<[[f32; 3]; 4]>,
    pulse_due: [u64; 4],
    pulse_frac: f64,
    /// Virtual process calls run under the console cadence ([`Seams::frame`]).
    pub calls: u64,
    /// Hits fired, and those of them that were material changes (diagnostics).
    pub hits: u64,
    pub transitions: u64,
    /// The Player-slot instance whose Cracks input it writes (0 = the local player).
    pub instance: u32,
}

impl Default for Seams {
    fn default() -> Self {
        Self {
            held: Default::default(),
            toggle: [true; 4],
            cells: [IDLE_CELL; 8],
            front: 0.0,
            rear: REAR_IDLE,
            prev_material: [NO_MATERIAL; 4],
            latch: false,
            frame: 0,
            last: [0; 4],
            turn: 0,
            record: SeamPattern::default(),
            landed0: false,
            prev0: false,
            air0: 0,
            cracks: false,
            fired_now: [false; 4],
            clock: 0.0,
            next_call: 0.0,
            last_wheels: None,
            pulse_due: [0; 4],
            pulse_frac: 0.0,
            calls: 0,
            hits: 0,
            transitions: 0,
            instance: 0,
        }
    }
}

/// `sub_824C2428`: the seam surface of a wheel's material (word 8 of its AudioSurfaceMap entry), or
/// with `transition` word 9 + 5; 0 without contact.
pub fn surface(s: &AudioState, t: &PlayerTuning, wheel: usize, transition: bool) -> i32 {
    let m = s.wheel_material[wheel];
    if m >= NO_MATERIAL {
        return 0;
    }
    t.surface_entry(m).map_or(0, |e| if transition { e[9] + 5 } else { e[8] })
}

/// `sub_824C1BA8` + the floor in `sub_824C1CA0`: the grid cell of a world position on one axis.
pub fn cell(position: [f32; 3], record: &SeamPattern, scale: f32, axis: usize) -> i32 {
    let a = (record.angle as f32) * DEG;
    let (c, s) = ((a as f64).cos() as f32, (a as f64).sin() as f32);
    let [x, _, z] = position;
    let (value, grid) = if axis == 0 { (c * x - s * z, record.grid_x) } else { (c * z + s * x, record.grid_z) };
    let v = f64::from(value / (grid * scale)).floor() as f32;
    if v.is_nan() { 0 } else { v as i32 }
}

impl Seams {
    fn words(s: &AudioState, t: &PlayerTuning, wheel: usize) -> Vec<i32> {
        let mut w = vec![0i32; WORDS];
        w[1] = 32767;
        w[4] = 4096;
        w[5] = 25000;
        w[10] = surface(s, t, wheel, false).clamp(0, 8);
        w[11] = i32::from(s.soft_wheels);
        w[14] = wheel as i32;
        w[19] = EQ_CHAIN;
        w
    }

    fn pattern(t: &PlayerTuning, p: u32) -> SeamPattern {
        t.seam_patterns.get(p as usize).copied().unwrap_or_default()
    }

    /// `sub_824C1DF8`.
    fn fire(&mut self, s: &AudioState, t: &PlayerTuning, wheel: usize, single: bool, transition: bool) {
        let toggle = self.toggle[wheel];
        if let Some(w) = self.held[wheel].as_mut() {
            w[9] = i32::from(single);
            w[7] = if toggle { 1 } else { 2 };
            w[10] = surface(s, t, wheel, transition).clamp(0, 8);
            w[11] = i32::from(s.soft_wheels);
        }
        self.toggle[wheel] = !toggle;
        self.fired_now[wheel] = true;
        // Cracks.in0 := 32767 (written to the MixMap by the next process before its tick).
        self.cracks = true;
        self.hits += 1;
        self.transitions += u64::from(transition);
    }

    /// `sub_824C1CA0`.
    fn crossed(&mut self, s: &AudioState, t: &PlayerTuning, wheel: usize, axis: usize) -> bool {
        if s.airborne || s.grinding {
            return false;
        }
        let mut scale = 1.0;
        if surface(s, t, wheel, false) == 3 && self.record.class == 10 {
            scale = t.seam_surface3_scale;
        }
        let c = cell(s.wheel_position[wheel], &self.record, scale, axis);
        let slot = &mut self.cells[wheel + 4 * axis];
        if *slot == c {
            return false;
        }
        *slot = c;
        true
    }

    /// `sub_824C1698` for one axis.
    fn trigger(&mut self, s: &AudioState, t: &PlayerTuning, axis: usize) {
        let manual = s.balance || s.manual_brake;
        let p = if manual && !self.landed0 { s.seam_pattern[3] } else { s.seam_pattern[0] };
        if p == 0 {
            for w in self.held.iter_mut().flatten() {
                w[13] = 0;
            }
            return;
        }
        self.record = Self::pattern(t, p);
        if self.record.mode == 0 {
            for w in self.held.iter_mut().flatten() {
                w[13] = 0;
            }
            return;
        }
        self.frame += 1;
        if self.frame > 32767 {
            self.frame = 0;
            self.last = [0; 4];
        }
        let min = self.record.min_frames;
        match self.record.mode {
            1 => {
                let (c0, c1) = (self.crossed(s, t, 0, axis), self.crossed(s, t, 1, axis));
                let (c2, c3) = if manual { (false, false) } else { (self.crossed(s, t, 2, axis), self.crossed(s, t, 3, axis)) };
                for (a, b) in [(0usize, 1usize), (2, 3)] {
                    let (ca, cb) = if a == 0 { (c0, c1) } else { (c2, c3) };
                    let both = ca && cb;
                    if ca {
                        if self.frame - self.last[b] > min {
                            self.fire(s, t, a, !both, false);
                            self.last[a] = self.frame;
                        }
                    } else if cb && self.frame - self.last[a] > min {
                        self.fire(s, t, b, !both, false);
                        self.last[b] = self.frame;
                    }
                }
            }
            2 if !s.airborne && axis == 0 => {
                let d = s.ground_speed * DISTANCE_SCALE * 1.0 * s.dt;
                self.front += d;
                if self.rear <= REAR_START {
                    self.rear -= d;
                }
                if self.front > self.record.spacing {
                    self.fire(s, t, 0, false, false);
                    self.fire(s, t, 1, false, false);
                    self.front = 0.0;
                    self.rear = REAR_START;
                }
                if self.rear <= 0.0 {
                    self.fire(s, t, 2, false, false);
                    self.fire(s, t, 3, false, false);
                    self.rear = REAR_IDLE;
                }
            }
            _ => {}
        }
    }

    /// Process (before the MixMap tick): the create on the first call, then `sub_824C14C8`.
    pub fn process(&mut self, s: &AudioState, t: &PlayerTuning, m: &mut MixMap) -> Vec<SeamCommand> {
        let mut cmds = Vec::new();
        for wheel in 0..4 {
            if self.held[wheel].is_none() {
                let w = Self::words(s, t, wheel);
                cmds.push(SeamCommand::Post { wheel, words: w.clone() });
                self.held[wheel] = Some(w);
            }
        }
        // The conditioner's landed latch of wheel 0 (sub_82772FD8).
        let now = s.wheel_contact[0];
        if !self.prev0 && self.air0 > 5 {
            self.landed0 = now;
        }
        self.prev0 = now;
        self.air0 = if now { 0 } else { self.air0 + 1 };

        // Cracks.in0 := 0, then 32767 if a hit fires now or fired on a call between ticks (the
        // MixMap ticks only here; retail ticks on every call).
        self.step(s, t);
        m.set_input(keys::cracks(self.instance), 0, if std::mem::take(&mut self.cracks) { 32767 } else { 0 });
        for (wheel, w) in self.held.iter().enumerate() {
            if let Some(w) = w {
                cmds.push(SeamCommand::Redeliver { wheel, words: w.clone() });
            }
        }
        cmds
    }

    /// The body of `sub_824C14C8` after the create and the landed latch: w7 := 0 on every packet,
    /// the material history (cleared in the air), a transition hit per changed material, else the
    /// pattern trigger on both axes.
    fn step(&mut self, s: &AudioState, t: &PlayerTuning) {
        self.fired_now = [false; 4];
        for w in self.held.iter_mut().flatten() {
            w[7] = 0;
        }
        if s.airborne {
            self.latch = false;
        }
        let mut fired = false;
        if self.latch {
            for wheel in 0..4 {
                if self.prev_material[wheel] != s.wheel_material[wheel] {
                    self.fire(s, t, wheel, false, true);
                    fired = true;
                }
            }
        }
        self.prev_material = s.wheel_material;
        self.latch = true;
        if !fired && s.ground_speed > self.record.speed_threshold {
            self.trigger(s, t, 0);
            self.trigger(s, t, 1);
        }
    }

    /// The console's process cadence, in Hz (Listening test 9): shipped Skate 3 renders at about 30
    /// fps and its audio manager (`sub_82485190`) runs every SFX object's process, the MixMap tick
    /// and the update once per rendered frame (both halves, dt > 0.02).
    pub const CONSOLE_HZ: f64 = 30.0;

    /// The tick's part of the process under the console cadence ([`Seams::frame`] does the rest):
    /// the create, wheel 0's landed latch, and Cracks.in0 (32767 if a hit fired since the last
    /// tick). No packet changes here, so nothing is redelivered.
    pub fn process_tick(&mut self, s: &AudioState, t: &PlayerTuning, m: &mut MixMap) -> Vec<SeamCommand> {
        let mut cmds = Vec::new();
        for wheel in 0..4 {
            if self.held[wheel].is_none() {
                let w = Self::words(s, t, wheel);
                cmds.push(SeamCommand::Post { wheel, words: w.clone() });
                self.held[wheel] = Some(w);
            }
        }
        let now = s.wheel_contact[0];
        if !self.prev0 && self.air0 > 5 {
            self.landed0 = now;
        }
        self.prev0 = now;
        self.air0 = if now { 0 } else { self.air0 + 1 };
        m.set_input(keys::cracks(self.instance), 0, if std::mem::take(&mut self.cracks) { 32767 } else { 0 });
        cmds
    }

    /// The audio blocks (256 frames at 48 kHz) one console frame lasts: 1/30 s = 6.25 blocks.
    pub const PULSE_BLOCKS: f64 = 48_000.0 / 256.0 / Self::CONSOLE_HZ;

    /// Clear the copy's w7 of every pulse that has ended by audio block `block` (the runtime has
    /// already redelivered the cleared words then; later redeliveries must not set it again).
    pub fn expire(&mut self, block: u64) {
        for (wheel, w) in self.held.iter_mut().enumerate() {
            if let Some(w) = w {
                if w[7] != 0 && self.pulse_due[wheel] <= block {
                    w[7] = 0;
                }
            }
        }
    }

    /// One rendered frame of `dt` seconds under the console cadence (Listening test 9); `block` is
    /// the audio block the runtime renders next.
    ///
    /// Retail runs `sub_824C14C8` once per rendered frame: on the 30 fps console every 33.3 ms,
    /// reading the wheel positions of that frame (`+384 + 16·w`), and a hit's w7 stays set until
    /// the next call clears it — one console frame, 6.25 audio blocks, a little longer than the
    /// 32 ms walk, so the program sees every hit once (twice about one time in 24). (The recomp
    /// renders uncapped, ~345 fps, so its seams differ.) This keeps the console's behaviour at any
    /// real frame rate:
    /// - virtual process calls on a fixed 30 Hz grid of real time, each at the wheel positions
    ///   interpolated along the rendered trajectory (`s.wheel_position` = this frame's rendered
    ///   wheels; the last frame's are kept): the crossings the console samples, none lost or
    ///   counted twice between real frames;
    /// - a hit's w7 is redelivered now and cleared on the audio clock after 6 or 7 blocks (6.25 on
    ///   average, [`SeamCommand::RedeliverAt`]), whatever the real frame times;
    /// - below 30 fps several virtual calls run in one real frame; the program then sees only the
    ///   last hit of each packet in that frame.
    ///
    /// Materials, air and the pattern come from `s` (the physics step's). The distance mode uses
    /// dt = 1/30 per call. Only changed packets are redelivered.
    pub fn frame(&mut self, s: &AudioState, t: &PlayerTuning, dt: f32, block: u64) -> Vec<SeamCommand> {
        let mut cmds = Vec::new();
        if self.held.iter().any(Option::is_none) {
            return cmds;
        }
        self.expire(block);
        let before: Vec<Vec<i32>> = self.held.iter().flatten().cloned().collect();
        let start = self.clock;
        self.clock += f64::from(dt.max(0.0));
        let now = s.wheel_position;
        let last = self.last_wheels.unwrap_or(now);
        let period = 1.0 / Self::CONSOLE_HZ;
        // A long stall (pause, load): resume the grid at this frame instead of a burst of calls.
        if self.clock - self.next_call > 8.0 * period {
            self.next_call = self.clock;
        }
        let mut fired = [false; 4];
        while self.next_call <= self.clock {
            let u = if self.clock > start { ((self.next_call - start) / (self.clock - start)).clamp(0.0, 1.0) as f32 } else { 1.0 };
            let mut v = *s;
            v.dt = period as f32;
            v.wheel_position = std::array::from_fn(|w| std::array::from_fn(|c| last[w][c] + (now[w][c] - last[w][c]) * u));
            let kept: Vec<i32> = self.held.iter().flatten().map(|w| w[7]).collect();
            self.step(&v, t);
            for (wheel, w) in self.held.iter_mut().enumerate() {
                let Some(w) = w else { continue };
                if self.fired_now[wheel] {
                    fired[wheel] = true;
                } else if self.pulse_due[wheel] > block {
                    w[7] = kept[wheel];
                }
            }
            self.next_call += period;
            self.calls += 1;
        }
        self.last_wheels = Some(now);
        for (wheel, (w, old)) in self.held.iter().flatten().zip(&before).enumerate() {
            if w != old {
                cmds.push(SeamCommand::Redeliver { wheel, words: w.clone() });
            }
            if fired[wheel] && w[7] != 0 {
                self.pulse_frac += Self::PULSE_BLOCKS;
                let n = self.pulse_frac.floor();
                self.pulse_frac -= n;
                let mut clear = w.clone();
                clear[7] = 0;
                cmds.push(SeamCommand::RedeliverAt { wheel, words: clear, block: block + n as u64 });
            }
        }
        for (wheel, f) in fired.iter().enumerate() {
            if *f && self.held[wheel].as_ref().is_some_and(|w| w[7] != 0) {
                if let Some(SeamCommand::RedeliverAt { block: due, .. }) = cmds.iter().rev().find(|c| matches!(c, SeamCommand::RedeliverAt { wheel: x, .. } if *x == wheel)) {
                    self.pulse_due[wheel] = *due;
                }
            }
        }
        cmds
    }

    /// `sub_824C1F18` (after the tick).
    pub fn update(&mut self, s: &AudioState, out: &dyn Outputs) -> Vec<SeamCommand> {
        let mut cmds = Vec::new();
        let soft = s.soft_wheels;
        let speed = trunc_clamp(clamp01((s.ground_speed - 0.5) * f32::from_bits(0x3DA3_D70A)) * 10000.0, 0, 10000);
        let target = trunc_clamp(s.turn * 1000.0, i32::MIN, i32::MAX);
        for wheel in 0..4 {
            let Some(w) = self.held[wheel].as_mut() else { continue };
            w[0] = 32767;
            w[1] = out.level(if soft { 6 } else { 1 }).clamp(0, 32767);
            w[2] = out.level(5).clamp(0, 32767);
            w[5] = out.level(3).clamp(0, 25000);
            w[6] = out.level(4).clamp(0, 25000);
            w[3] = out.raw(0).clamp(0, 65536);
            w[4] = out.pitch(2).clamp(0, 8192);
            w[8] = speed;
            w[11] = i32::from(soft);
            // The turn word slews by at most 100 per packet write (four writes per frame).
            let v = if target > self.turn { target.min(self.turn + 100) } else { target.max(self.turn - 100) };
            self.turn = v;
            w[15] = v.abs().clamp(0, 1000);
            w[16] = trunc_clamp(self.record.gain * 32767.0, 0, 32767);
            w[17] = i32::from(s.balance || s.manual_brake);
            w[18] = trunc_clamp(self.record.level * 32767.0, 0, 32767);
            w[12] = i32::from(s.push_planted);
            w[13] = self.record.class.clamp(0, 15);
            cmds.push(SeamCommand::Redeliver { wheel, words: w.clone() });
        }
        cmds
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Zero;
    impl Outputs for Zero {
        fn level(&self, _: usize) -> i32 {
            20000
        }
        fn raw(&self, _: usize) -> i32 {
            0
        }
        fn pitch(&self, _: usize) -> i32 {
            4096
        }
    }

    fn tuning() -> PlayerTuning {
        let mut t = PlayerTuning::default();
        let mut row = [0i32; 18];
        row[8] = 2;
        row[9] = 1;
        t.surface_table = vec![row; 95];
        let grid = SeamPattern { gain: 0.63, angle: 0, grid_z: 3.0, grid_x: 3.0, class: 2, mode: 1, min_frames: 1, speed_threshold: 0.05, spacing: 75.0, level: 1.0 };
        t.seam_patterns = vec![grid; 16];
        t.seam_patterns[10].mode = 2;
        t
    }

    fn rolling(x: f32, pattern: u32) -> AudioState {
        let mut s = AudioState { ground_speed: 6.0, wheel_count: 4, wheel_contact: [true; 4], wheel_material: [3; 4], seam_pattern: [pattern; 4], ..AudioState::default() };
        // Front wheels 0.6 m ahead of the rear ones, along x.
        s.wheel_position = [[x + 0.3, 0.0, 0.1], [x + 0.3, 0.0, -0.1], [x - 0.3, 0.0, 0.1], [x - 0.3, 0.0, -0.1]];
        s
    }

    fn mixmap() -> Option<MixMap> {
        let path = std::path::Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/../../assets/private/audio/aems/MixMapSK8.mxb"));
        MixMap::from_bytes(&std::fs::read(path).ok()?).ok()
    }

    #[test]
    #[ignore = "needs the private install data"]
    fn grid_hits_once_per_axle_per_line_and_toggle_the_trigger_word() {
        let Some(mut m) = mixmap() else { panic!("missing private data: no MixMap in the install") };
        let t = tuning();
        let mut k = Seams::default();
        let first = k.process(&rolling(0.1, 1), &t, &mut m);
        assert_eq!(first.iter().filter(|c| matches!(c, SeamCommand::Post { .. })).count(), 4);
        // Retail quirk kept: the cells start at 0x7FFFFFFF, so the first evaluation "crosses" on
        // both axes; the frame counter runs per axis, so axis 1 already passes the minimum and one
        // hit per axle fires on the first frame at speed.
        assert_eq!(k.hits, 2);
        let toggled = k.toggle[0];
        // Ride 3 m (one grid line on axis 0) at 0.1 m per frame.
        let hits_before = k.hits;
        let mut sevens = Vec::new();
        for f in 1..=30 {
            let cmds = k.process(&rolling(0.1 + 0.1 * f as f32, 1), &t, &mut m);
            for c in cmds {
                if let SeamCommand::Redeliver { wheel: 0, words } = c {
                    sevens.push(words[7]);
                }
            }
        }
        // The front axle and the rear axle each cross x = 3 once: two hits, wheel 0 and wheel 2
        // (both wheels of an axle cross together → not single).
        assert_eq!(k.hits - hits_before, 2);
        assert_eq!(sevens.iter().filter(|&&v| v != 0).count(), 1, "w7 is set only on the hit frame");
        assert_eq!(*sevens.iter().find(|&&v| v != 0).unwrap(), if toggled { 1 } else { 2 }, "w7 follows the toggle");
        // In the air nothing fires; no pattern → w13 0.
        let mut air = rolling(10.0, 1);
        air.airborne = true;
        let before = k.hits;
        k.process(&air, &t, &mut m);
        assert_eq!(k.hits, before);
        let cmds = k.update(&rolling(10.0, 1), &Zero);
        let SeamCommand::Redeliver { words, .. } = &cmds[0] else { panic!() };
        assert_eq!((words[0], words[13], words[16], words[19]), (32767, 2, 20643, EQ_CHAIN));
    }

    #[test]
    #[ignore = "needs the private install data"]
    fn a_material_change_fires_with_the_transition_surface_and_skips_the_grid() {
        let Some(mut m) = mixmap() else { panic!("missing private data: no MixMap in the install") };
        let t = tuning();
        let mut k = Seams::default();
        k.process(&rolling(0.1, 1), &t, &mut m);
        let before = k.hits;
        let mut s = rolling(0.2, 1);
        s.wheel_material[1] = 5;
        let cmds = k.process(&s, &t, &mut m);
        assert_eq!(k.hits - before, 1);
        let words = cmds.iter().find_map(|c| match c {
            SeamCommand::Redeliver { wheel: 1, words } => Some(words.clone()),
            _ => None,
        });
        assert_eq!(words.unwrap()[10], 6, "word 9 + 5");
    }

    #[test]
    #[ignore = "needs the private install data"]
    fn distance_mode_fires_front_then_rear() {
        let Some(mut m) = mixmap() else { panic!("missing private data: no MixMap in the install") };
        let t = tuning();
        let mut k = Seams::default();
        k.process(&rolling(0.0, 10), &t, &mut m);
        // 6 m/s × 100 × 1/60 = 10 per frame: the front fires once past 75 (the create frame counts), the rear 50 later.
        let mut fired = Vec::new();
        for f in 0..20 {
            let before = k.hits;
            k.process(&rolling(0.0, 10), &t, &mut m);
            if k.hits > before {
                fired.push((f, k.hits - before));
            }
        }
        assert_eq!(fired[0], (6, 2));
        assert_eq!(fired[1], (11, 2));
    }

    /// Listening test 9: the console cadence gives the same hits at any real frame rate, and every
    /// hit's w7 ends on the audio clock after one console frame (6 or 7 blocks, 6.25 on average).
    #[test]
    fn console_cadence_is_frame_rate_independent() {
        let t = tuning();
        let v = 30.0f32 / 3.6;
        let mut results = Vec::new();
        for fps in [30.0f32, 60.0, 144.0, 365.0, 20.0] {
            let mut k = Seams::default();
            let s0 = rolling(0.0, 7);
            for w in 0..4 {
                k.held[w] = Some(Seams::words(&s0, &t, w));
            }
            let dt = 1.0 / fps;
            let mut lengths = Vec::new();
            let frames = (10.0 * fps) as usize;
            for f in 1..=frames {
                let x = v * f as f32 * dt;
                // Heading 20° off the x axis so both grid axes are crossed.
                let mut s = rolling(0.0, 7);
                let (c, sn) = (20f32.to_radians().cos(), 20f32.to_radians().sin());
                s.wheel_position = s.wheel_position.map(|p| [p[0] * c + x * c, 0.0, p[2] + x * sn]);
                let block = (f64::from(f as f32 * dt) * 187.5) as u64;
                for cmd in k.frame(&s, &t, dt, block) {
                    if let SeamCommand::RedeliverAt { words, block: due, .. } = cmd {
                        assert_eq!(words[7], 0);
                        lengths.push(due - block);
                    }
                }
            }
            assert!(lengths.iter().all(|&n| n == 6 || n == 7), "{fps} fps: {lengths:?}");
            let mean = lengths.iter().sum::<u64>() as f64 / lengths.len() as f64;
            assert!((mean - 6.25).abs() < 0.05, "{fps} fps: mean pulse {mean} blocks");
            results.push((fps, k.hits));
        }
        let hits30 = results[0].1;
        assert!(hits30 > 50);
        for (fps, hits) in &results {
            let d = (*hits as f64 - hits30 as f64).abs() / hits30 as f64;
            // Below 30 fps the real frames no longer line up with the virtual grid (f32 dt), so a
            // call can land a little off: a looser bound there.
            assert!(d < if *fps >= 30.0 { 0.02 } else { 0.05 }, "{fps} fps: {hits} hits vs {hits30} at 30 fps");
        }
    }
}
