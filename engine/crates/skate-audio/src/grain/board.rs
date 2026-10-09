//! The board owner's side of the rolling bed (spec §1.5, §2.2, §2.7, §2.8): per-surface tuning
//! from the vault, the speed → read position curve, the per-frame records of players A and B, and
//! the owner's modulators. Game thread, 60 Hz, single precision throughout.
use super::player::{GrainParams, Record};

/// Push envelope tuning (§2.7): peak speed scale and frequency shift by speed, segment times.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PushTuning {
    pub ramp_kmh: f32,
    pub scale_low: f32,
    pub scale_high: f32,
    pub shift_low_hz: f32,
    pub shift_high_hz: f32,
    /// Attack, hold, return (ms).
    pub scale_ms: [f32; 3],
    pub shift_ms: [f32; 3],
}

/// One grain collection of the vault's grain class (inheriting from `default`).
#[derive(Clone, Debug, PartialEq)]
pub struct SurfaceTuning {
    pub max_kmh: f32,
    /// Position-curve control points P0..P3.
    pub bezier: [f32; 4],
    /// GrainParams of players A and B.
    pub params: [GrainParams; 2],
    pub turn_cap: f32,
    pub turn_rise_step: f32,
    pub turn_fall_step: f32,
    pub special_gain: f32,
    pub special_shift_hz: f32,
    pub b_slope_gain: f32,
    pub b_slope_ramp_kmh: f32,
    pub a_shift_per_slope_hz: f32,
    pub b_base_shift_hz: f32,
    pub b_shift_per_slope_hz: f32,
    /// The slope inputs' divisors (`0x57A78D3BE8D47BB3` down = −10, `0x8DD4C3FC8DAF4059` up = 10).
    pub slope_divisors: (f32, f32),
    pub push: PushTuning,
}

/// The rocket layer's owner tuning (§2.8): start / top speed, gain word, GrainParams.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RocketTuning {
    pub start_kmh: f32,
    pub top_kmh: f32,
    pub gain_word: i32,
    pub params: GrainParams,
}

/// f32 1/32767 as the owner code multiplies by it (`0x38000100`).
pub const INV_32767: f32 = f32::from_bits(0x3800_0100);

/// t = clamp((v / max km/h)·3.6, 0, 1), rounded as retail (divide, then scale).
pub fn speed_fraction(speed: f32, max_kmh: f32) -> f32 {
    let x = (speed / max_kmh) * 3.6;
    let x = if x >= 0.0 { x } else { 0.0 };
    if 1.0 - x >= 0.0 { x } else { 1.0 }
}

/// Cubic Bézier of t with control points P0..P3 (not clamped: two members leave [0, 1] slightly),
/// in retail's factored single-precision form: with u = 1 − t and s = 1 − u,
/// pos = u³·P0 + 3·(s·(P2·s + P1·u))·u + s³·P3, the two outer sums and P2·s + P1·u fused.
pub fn position(bezier: &[f32; 4], t: f32) -> f32 {
    let [p0, p1, p2, p3] = *bezier;
    let u = 1.0 - t;
    let s = 1.0 - u;
    let inner = p2.mul_add(s, p1 * u);
    let middle = (inner * s) * u;
    let ends = (s * s * s) * p3;
    ((u * u) * u).mul_add(p0, middle.mul_add(3.0, ends))
}

/// What the owner update reads for one sounding truck (§2.2).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BoardInputs {
    /// Ground speed (m/s).
    pub speed: f32,
    /// The push speed-scale envelope while it runs.
    pub speed_scale: Option<f32>,
    /// MixMap SkateBoard level(1), level(2) (Q15) and pitch(3) (4096 = 1.0).
    pub level_a: i32,
    pub level_b: i32,
    pub pitch: i32,
    /// Slewed turn intensity I and brake Bk (0..1).
    pub turn: f32,
    pub brake: f32,
    /// Manual or trick latch: A × special gain.
    pub special: bool,
    /// Downhill slope level D (0..1).
    pub downhill: f32,
    /// Seam-pattern gain envelope while it runs.
    pub seam: Option<f32>,
}

/// The records of players A and B (§2.2 steps 1–7).
pub fn records(t: &SurfaceTuning, inp: &BoardInputs) -> [Record; 2] {
    let v = inp.speed_scale.map_or(inp.speed, |s| s * inp.speed);
    let pos_a = position(&t.bezier, speed_fraction(v, t.max_kmh));
    let pos_b = pos_a - 0.1;
    let pos_b = if pos_b >= 0.0 { pos_b } else { 0.0 };
    let pitch = inp.pitch as f32 * (1.0 / 4096.0);
    let larger = if inp.turn - inp.brake >= 0.0 { inp.turn } else { inp.brake };
    let mut gain_a = (1.0 - larger) * (inp.level_a as f32 * INV_32767);
    if inp.special {
        gain_a *= t.special_gain;
    }
    if let Some(seam) = inp.seam {
        gain_a *= seam;
    }
    let mut gain_b = inp.turn * (inp.level_b as f32 * INV_32767);
    if let Some(seam) = inp.seam {
        gain_b *= seam;
    }
    if inp.downhill > 0.0 {
        let ramp = if t.b_slope_ramp_kmh > 0.0 { speed_fraction(v, t.b_slope_ramp_kmh) } else { 1.0 };
        gain_b = ((inp.downhill * ramp) * t.b_slope_gain).mul_add(gain_a, gain_b);
        if gain_b > 1.0 {
            gain_b = 1.0;
        }
    }
    [Record { gain: gain_a, pitch, position: pos_a }, Record { gain: gain_b, pitch, position: pos_b }]
}

/// The rocket record (§2.8): gain = level(5)/32767 × gain word/32767, pitch(3)/4096, position
/// = clamp((v·3.6 − start) / (top − start), 0, 1).
pub fn rocket_record(t: &RocketTuning, speed: f32, level: i32, pitch: i32) -> Record {
    Record {
        gain: level as f32 / 32767.0 * (t.gain_word as f32 / 32767.0),
        pitch: pitch as f32 / 4096.0,
        position: ((speed * 3.6 - t.start_kmh) / (t.top_kmh - t.start_kmh)).clamp(0.0, 1.0),
    }
}

/// A linear attack → hold → return envelope from `start` to `peak` and back to `rest`, advanced
/// by the frame time (the push speed scale and frequency shift, §2.7).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PushEnvelope {
    from: f32,
    peak: f32,
    rest: f32,
    ms: [f32; 3],
    elapsed_ms: f32,
    running: bool,
}

impl PushEnvelope {
    /// Start a new push from the current value (or `rest` when idle).
    pub fn trigger(&mut self, peak: f32, rest: f32, ms: [f32; 3]) {
        let from = if self.running { self.value().unwrap_or(rest) } else { rest };
        *self = Self { from, peak, rest, ms, elapsed_ms: 0.0, running: true };
    }

    pub fn advance(&mut self, dt: f32) {
        if self.running {
            self.elapsed_ms += dt * 1000.0;
            if self.elapsed_ms >= self.ms.iter().sum::<f32>() {
                self.running = false;
            }
        }
    }

    /// The value while running.
    pub fn value(&self) -> Option<f32> {
        if !self.running {
            return None;
        }
        let [a, h, r] = self.ms;
        let e = self.elapsed_ms;
        Some(if e < a {
            self.from + (self.peak - self.from) * (e / a.max(1e-3))
        } else if e < a + h {
            self.peak
        } else {
            self.peak + (self.rest - self.peak) * ((e - a - h) / r.max(1e-3)).min(1.0)
        })
    }
}

/// The push tuning's peaks at speed `v` (m/s): t = clamp((v − 1)·3.6 / ramp, 0, 1); speed scale
/// lerp(low, high, t), shift lerp(low, high, t).
pub fn push_peaks(p: &PushTuning, v: f32) -> (f32, f32) {
    let t = (((v - 1.0) * 3.6) / p.ramp_kmh).clamp(0.0, 1.0);
    (p.scale_low + (p.scale_high - p.scale_low) * t, p.shift_low_hz + (p.shift_high_hz - p.shift_low_hz) * t)
}

/// Move `value` toward `target` by at most `step` (the turn and brake slews, per frame).
pub fn slew(value: f32, target: f32, step: f32) -> f32 {
    if target > value { (value + step).min(target) } else { (value - step).max(target) }
}

/// `0x8209xxxx` 0.24: |COM velocity| → turn intensity scale (`sub_824C8588`).
pub const TURN_SPEED_SCALE: f32 = 0.24;

/// The owner's turn intensity (`sub_824C8588`, owner `+1160` signed, `+1164` = |·|), per frame:
/// raw = min(clamp(|COM v|·0.24, 0, cap)·turn, cap), then max(raw, −cap); 0 while the manual or
/// trick latch holds; the signed value moves toward raw by at most the primary truck's rise step
/// when raw is above it, else its fall step (both from the grain collection). Returns |value|.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TurnIntensity {
    pub value: f32,
}

impl TurnIntensity {
    /// One step; `frames` scales the slew steps for frame times other than retail's 1/60 s.
    pub fn step(&mut self, t: &SurfaceTuning, com_speed: f32, turn: f32, special: bool, frames: f32) -> f32 {
        let cap = t.turn_cap;
        let scaled = com_speed * TURN_SPEED_SCALE;
        let scaled = if -scaled >= 0.0 { 0.0 } else { scaled };
        let scaled = if cap - scaled >= 0.0 { scaled } else { cap };
        let mut raw = scaled * turn;
        if raw > cap {
            raw = cap;
        }
        if raw < -cap {
            raw = -cap;
        }
        if special {
            raw = 0.0;
        }
        let step = if raw > self.value { t.turn_rise_step } else { t.turn_fall_step } * frames;
        if raw - self.value > step {
            raw = self.value + step;
        } else if self.value - raw > step {
            raw = self.value - step;
        }
        self.value = raw;
        raw.abs()
    }
}

/// The brake slew's step per call (§2.7; `sub_824C6198`, owner `+1168`: `lfs` of the constant at
/// `0x82165A00`, 0.05 per grain-player-spec §2.7; no dt).
pub const BRAKE_STEP: f32 = 0.05;

/// The owner's two per-call slews in `sub_824C6198` (the SkateBoard process `sub_824C6A78`): the
/// turn intensity (`sub_824C8588`, owner `+1160` / `+1164`) and the brake (`+1168`). Both move by a
/// fixed step per call with no dt; retail calls them once per console frame (~30 fps).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct OwnerSlews {
    pub turn: TurnIntensity,
    pub brake: f32,
}

impl OwnerSlews {
    /// One host pass. `calls`: `Some(n)` = n console frames end in this pass (`mixmap::cadence`),
    /// each one retail call (step × 1); `None` = once with the steps scaled by `frames`
    /// (= dt × 60, the old 60 Hz host). `tuning` None: the brake still slews, the turn holds and
    /// reads 0 (no primary grain truck). Returns |I|.
    #[allow(clippy::too_many_arguments)]
    pub fn step(&mut self, tuning: Option<&SurfaceTuning>, com_speed: f32, turn: f32, special: bool, braking: bool, calls: Option<usize>, frames: f32) -> f32 {
        let target = if braking { 1.0 } else { 0.0 };
        match calls {
            None => {
                self.brake = slew(self.brake, target, BRAKE_STEP * frames);
                tuning.map_or(0.0, |t| self.turn.step(t, com_speed, turn, special, frames))
            }
            Some(n) => {
                for _ in 0..n {
                    self.brake = slew(self.brake, target, BRAKE_STEP);
                    if let Some(t) = tuning {
                        self.turn.step(t, com_speed, turn, special, 1.0);
                    }
                }
                tuning.map_or(0.0, |_| self.turn.value.abs())
            }
        }
    }
}

/// The owner's two latches (`sub_824CA688` / `sub_824CA6E0`): manual (`+1504`) set while balancing
/// (state `+340`), cleared once the wheel count is 0 or 4; trick (`+1505`) set while the hippy-jump
/// flag (`+372`) holds, cleared once both feet are in the deck box (`+615 && +616`). "Special" =
/// either: gain A × special gain, turn intensity 0.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Latches {
    pub manual: bool,
    pub trick: bool,
}

impl Latches {
    pub fn update(&mut self, balance: bool, wheel_count: u32, hippy_jump: bool, feet_in_box: [bool; 2]) -> bool {
        if balance {
            self.manual = true;
        } else if self.manual && (wheel_count == 0 || wheel_count == 4) {
            self.manual = false;
        }
        if hippy_jump {
            self.trick = true;
        } else if self.trick && feet_in_box[0] && feet_in_box[1] {
            self.trick = false;
        }
        self.manual || self.trick
    }
}

/// `sub_824CA738`: with the primary truck on a grain surface, a downhill slope (`+712` < 0) gives
/// D = clamp01(slope / down) and an uphill one U = clamp01(slope / up) (`down` / `up` = the grain
/// collection's divisors, −10 / 10); otherwise both 0. Owner inputs 2 / 3 = trunc(level·32767).
pub fn slope_levels(slope: f32, grain_surface: bool, down_divisor: f32, up_divisor: f32) -> (f32, f32) {
    let unit = |x: f32| {
        let lo = if -x >= 0.0 { 0.0 } else { x };
        if 1.0 - lo >= 0.0 { lo } else { 1.0 }
    };
    if !grain_surface {
        (0.0, 0.0)
    } else if slope < 0.0 {
        (unit(slope / down_divisor), 0.0)
    } else if slope > 0.0 {
        (0.0, unit(slope / up_divisor))
    } else {
        (0.0, 0.0)
    }
}

/// The seam-pattern gain envelope (`sub_824CA448` / draw `sub_824CA318`, owner `+1336..+1484`,
/// local player): when wheel 0's seam pattern changes the envelope resets; for a pattern whose
/// wobble is not {1, 1} it becomes active and ramps linearly from 1 to a random gain in
/// [low, high) (steps of 0.01) over a random duration in [ms_low, ms_high) ms, then holds; the
/// same pattern frame after frame only advances it. While active both grain gains are multiplied
/// by its value. (The grain spec's "random walk" reading is corrected: retail adds one segment
/// per pattern change.)
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SeamEnvelope {
    pattern: u32,
    active: bool,
    from: f32,
    to: f32,
    ms: f32,
    elapsed_ms: f32,
}

impl SeamEnvelope {
    /// Draw the target gain and duration as `sub_824CA318` does (`draw` = the title generator).
    pub fn draw(w: &crate::player::tuning::SeamWobble, mut draw: impl FnMut() -> u32) -> (f32, i32) {
        let mut gain = w.gain_low;
        if w.gain_low != w.gain_high {
            let range = ((w.gain_high - w.gain_low) * 100.0) as i32;
            let m = if range > 0 {
                (draw() % range as u32) as f32 * 0.01
            } else {
                let r = range.unsigned_abs().max(1);
                (draw() % r) as f32 * -0.01
            };
            gain = m + w.gain_low;
        }
        let mut ms = w.ms_low;
        if w.ms_high != w.ms_low {
            let r = w.ms_high.wrapping_sub(w.ms_low).unsigned_abs().max(1);
            ms = (draw() % r) as i32 + w.ms_low;
        }
        (gain, ms)
    }

    /// One frame with wheel 0's pattern. `wobble(pattern)` looks up the tuning; `draw` is used only
    /// on a change to an active pattern.
    pub fn update(&mut self, pattern: u32, dt: f32, wobble: impl Fn(u32) -> crate::player::tuning::SeamWobble, draw: impl FnMut() -> u32) {
        if pattern != self.pattern {
            *self = Self { pattern, ..Self::default() };
            if pattern != 0 {
                let w = wobble(pattern);
                if w.gain_low != 1.0 || w.gain_high != 1.0 {
                    let (gain, ms) = Self::draw(&w, draw);
                    *self = Self { pattern, active: true, from: 1.0, to: gain, ms: ms as f32, elapsed_ms: 0.0 };
                }
            }
        } else if self.active && self.elapsed_ms < self.ms {
            self.elapsed_ms += dt * 1000.0;
        }
    }

    /// The gain factor while active.
    pub fn value(&self) -> Option<f32> {
        if !self.active {
            return None;
        }
        if self.ms <= 0.0 || self.elapsed_ms >= self.ms {
            return Some(self.to);
        }
        Some(self.from + (self.to - self.from) * (self.elapsed_ms / self.ms))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tuning(max_kmh: f32, bezier: [u32; 4]) -> SurfaceTuning {
        let p = GrainParams { attack: 0.1, sustain: 0.2, release: 0.1, window: 1.6, drift: 0.05 };
        SurfaceTuning {
            max_kmh,
            bezier: bezier.map(f32::from_bits),
            params: [p, p],
            turn_cap: 0.6,
            turn_rise_step: 0.06,
            turn_fall_step: 0.06,
            special_gain: 0.65,
            special_shift_hz: 150.0,
            b_slope_gain: 2.0,
            b_slope_ramp_kmh: 10.0,
            a_shift_per_slope_hz: -100.0,
            b_base_shift_hz: -10.0,
            b_shift_per_slope_hz: 50.0,
            slope_divisors: (-10.0, 10.0),
            push: PushTuning { ramp_kmh: 45.0, scale_low: 1.4, scale_high: 1.1, shift_low_hz: -52.0, shift_high_hz: -20.0, scale_ms: [35.0, 200.0, 600.0], shift_ms: [30.0, 200.0, 600.0] },
        }
    }

    /// The PoC's POS vectors (PR #4's `board_records`; the PoC's golden vectors, kept locally):
    /// speed in km/h → position A / B bit patterns.
    #[test]
    fn positions_match_the_golden_vectors() {
        let golden: &[(&str, f32, [u32; 4], &[(u32, u32, u32)])] = &[
            ("concrete_rough_hard", 60.0, [0, 0x3D0D_3DCB, 0x3F69_EE58, 0x3F80_0000], &[
                (0, 0x0000_0000, 0x0000_0000), (5, 0x3CCF_0A1D, 0x0000_0000), (10, 0x3DA3_F6DB, 0x0000_0000),
                (15, 0x3E22_7B96, 0x3D70_54BE), (20, 0x3E82_C772, 0x3E1F_287E), (25, 0x3EBA_B135, 0x3E87_7E02),
                (30, 0x3EF6_11A8, 0x3EC2_DE75), (35, 0x3F18_FFAE, 0x3EFE_CC29), (40, 0x3F35_C86C, 0x3F1C_2ED2),
                (45, 0x3F4F_EE57, 0x3F36_54BD), (50, 0x3F65_FCBC, 0x3F4C_6322), (55, 0x3F76_7EDB, 0x3F5C_E541),
                (60, 0x3F80_0000, 0x3F66_6666), (80, 0x3F80_0000, 0x3F66_6666),
            ]),
            ("default", 74.0, [0, 0x3EB9_611C, 0x3F34_F72B, 0x3F80_0000], &[
                (0, 0x0000_0000, 0x0000_0000), (5, 0x3D95_CD5D, 0x0000_0000), (10, 0x3E15_40D0, 0x3D3B_69A6),
                (15, 0x3E5E_FDB1, 0x3DF1_2E95), (20, 0x3E94_0647, 0x3E41_A628), (25, 0x3EB8_2E5A, 0x3E84_FB27),
                (30, 0x3EDB_EEB2, 0x3EA8_BB7F), (35, 0x3EFF_3EF4, 0x3ECC_0BC1), (40, 0x3F11_0B5E, 0x3EEE_E389),
                (45, 0x3F22_36DB, 0x3F08_9D41), (50, 0x3F33_1DBE, 0x3F19_8424), (55, 0x3F43_BBDB, 0x3F2A_2241),
                (60, 0x3F54_0D02, 0x3F3A_7368), (65, 0x3F64_0D04, 0x3F4A_736A), (70, 0x3F73_B7B2, 0x3F5A_1E18),
                (75, 0x3F80_0000, 0x3F66_6666),
            ]),
        ];
        let mut mismatches = Vec::new();
        for (name, max, bezier, rows) in golden {
            let t = tuning(*max, *bezier);
            for &(kmh, a, b) in rows.iter() {
                let inp = BoardInputs { speed: kmh as f32 / 3.6, speed_scale: None, level_a: 7859, level_b: 16000, pitch: 4096, turn: 0.0, brake: 0.0, special: false, downhill: 0.0, seam: None };
                let [ra, rb] = records(&t, &inp);
                if (ra.position.to_bits(), rb.position.to_bits()) != (a, b) {
                    mismatches.push(format!("{name} {kmh}: A {:08X} want {a:08X}, B {:08X} want {b:08X}", ra.position.to_bits(), rb.position.to_bits()));
                }
                assert_eq!(format!("{:.6}", ra.gain), "0.239845");
            }
        }
        assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
    }

    #[test]
    fn b_is_the_turning_and_downhill_layer() {
        let t = tuning(60.0, [0, 0x3D0D_3DCB, 0x3F69_EE58, 0x3F80_0000]);
        let mut inp = BoardInputs { speed: 5.0, speed_scale: None, level_a: 16384, level_b: 16384, pitch: 4096, turn: 0.0, brake: 0.0, special: false, downhill: 0.0, seam: None };
        assert_eq!(records(&t, &inp)[1].gain, 0.0);
        inp.turn = 0.5;
        let [a, b] = records(&t, &inp);
        assert!((a.gain - 0.25).abs() < 1e-3 && (b.gain - 0.25).abs() < 1e-3);
        inp.turn = 0.0;
        inp.downhill = 1.0;
        let [a, b] = records(&t, &inp);
        assert!((b.gain - (2.0 * a.gain).min(1.0)).abs() < 1e-6);
        inp.special = true;
        assert!((records(&t, &inp)[0].gain - a.gain * 0.65).abs() < 1e-6);
    }

    #[test]
    fn push_envelope_rises_holds_and_returns() {
        let mut e = PushEnvelope::default();
        assert_eq!(e.value(), None);
        e.trigger(1.4, 1.0, [35.0, 200.0, 600.0]);
        e.advance(0.035);
        assert!((e.value().unwrap() - 1.4).abs() < 1e-5);
        e.advance(0.2);
        e.advance(0.3);
        assert!((e.value().unwrap() - 1.2).abs() < 0.01);
        e.advance(0.4);
        assert_eq!(e.value(), None);
        let p = PushTuning { ramp_kmh: 45.0, scale_low: 1.4, scale_high: 1.1, shift_low_hz: -52.0, shift_high_hz: -20.0, scale_ms: [35.0, 200.0, 600.0], shift_ms: [30.0, 200.0, 600.0] };
        assert_eq!(push_peaks(&p, 0.5), (1.4, -52.0));
        assert_eq!(push_peaks(&p, 30.0), (1.1, -20.0));
    }

    #[test]
    fn turn_intensity_caps_slews_and_zeroes_while_special() {
        let t = tuning(60.0, [0, 0x3D0D_3DCB, 0x3F69_EE58, 0x3F80_0000]);
        let mut i = TurnIntensity::default();
        // 10 m/s COM × 0.24 = 2.4 → capped 0.6, × turn −1 → −0.6: reached in steps of 0.06.
        let steps: Vec<f32> = (0..12).map(|_| i.step(&t, 10.0, -1.0, false, 1.0)).collect();
        assert!((steps[0] - 0.06).abs() < 1e-6 && (steps[9] - 0.6).abs() < 1e-5 && (steps[11] - 0.6).abs() < 1e-5);
        assert!(i.value < 0.0, "signed internally");
        // Straight: falls back toward 0 by the step (raw 0 > −0.6 uses the rise step).
        assert!((i.step(&t, 10.0, 0.0, false, 1.0) - 0.54).abs() < 1e-5);
        // A manual or trick latch forces 0 as the target.
        let mut j = TurnIntensity { value: 0.3 };
        assert!((j.step(&t, 10.0, 1.0, true, 1.0) - 0.24).abs() < 1e-5);
        // Slow: |COM v|·0.24 = 0.12 is the cap there.
        let mut k = TurnIntensity::default();
        for _ in 0..10 {
            k.step(&t, 0.5, 1.0, false, 1.0);
        }
        assert!((k.value - 0.12).abs() < 1e-6);
    }

    /// `sub_824C6198`'s turn and brake slews on the console cadence: one retail step per console
    /// frame (0.06 / 0.05, no dt), so a full turn (0.6) is back to ~0 after 10 console frames =
    /// 20 steps = 333 ms (f32 leaves 7.45e-9, removed by the 11th, as retail's `fsubs` does) and a
    /// full brake after 20 = 667 ms; nothing moves on the steps between.
    #[test]
    fn owner_slews_take_one_step_per_console_frame() {
        use crate::mixmap::cadence::Cadence;
        let t = tuning(60.0, [0, 0x3D0D_3DCB, 0x3F69_EE58, 0x3F80_0000]);
        let mut s = OwnerSlews { turn: TurnIntensity { value: 0.6 }, brake: 1.0 };
        let mut c = Cadence::default();
        let (mut turn_zero, mut brake_zero, mut turn_tiny) = (None, None, None);
        let mut last = (s.turn.value, s.brake);
        for step in 1..=60usize {
            let calls = c.advance(1);
            let i = s.step(Some(&t), 10.0, 0.0, false, false, Some(calls), 1.0);
            if calls == 0 {
                assert_eq!((s.turn.value, s.brake), last, "no step between console frames");
            } else {
                // One step (the last one may be the f32 remainder down to the target).
                assert!(s.turn.value == 0.0 || (last.0 - s.turn.value - 0.06).abs() < 1e-6, "one 0.06 step: {last:?} → {}", s.turn.value);
                assert!(s.brake == 0.0 || (last.1 - s.brake - 0.05).abs() < 1e-6, "one 0.05 step: {last:?} → {}", s.brake);
            }
            assert_eq!(i, s.turn.value.abs());
            last = (s.turn.value, s.brake);
            if s.turn.value < 1e-6 && turn_tiny.is_none() {
                turn_tiny = Some(step);
            }
            if s.turn.value == 0.0 && turn_zero.is_none() {
                turn_zero = Some(step);
            }
            if s.brake == 0.0 && brake_zero.is_none() {
                brake_zero = Some(step);
            }
        }
        assert_eq!(turn_tiny, Some(20), "10 console frames = 20 steps = 333 ms");
        assert_eq!(turn_zero, Some(22), "the f32 remainder goes on the 11th console frame");
        assert_eq!(brake_zero, Some(40), "20 console frames = 40 steps = 667 ms");
        // The old host (`calls` None, frames = dt × 60): 0.06 per 60 Hz step, 0 after 11 steps.
        let mut o = OwnerSlews { turn: TurnIntensity { value: 0.6 }, brake: 1.0 };
        let n = (1..=60).find(|_| {
            o.step(Some(&t), 10.0, 0.0, false, false, None, 1.0);
            o.turn.value == 0.0
        });
        assert_eq!(n, Some(11));
        // Without a primary truck the brake still slews, the turn holds and reads 0.
        let mut h = OwnerSlews { turn: TurnIntensity { value: 0.3 }, brake: 0.5 };
        assert_eq!(h.step(None, 10.0, 0.0, false, false, Some(1), 1.0), 0.0);
        assert_eq!((h.turn.value, h.brake), (0.3, 0.45));
    }

    /// The same values on the same console frames at 30 / 60 / 144 / 240 / 365 fps: a host that runs
    /// once per rendered frame with the newest 60 Hz state and the pass's console calls
    /// (`mixmap::cadence`), as `grain_bed::update` does.
    #[test]
    fn owner_slews_are_the_same_at_any_frame_rate() {
        use crate::mixmap::cadence::Cadence;
        let t = tuning(60.0, [0, 0x3D0D_3DCB, 0x3F69_EE58, 0x3F80_0000]);
        // 20 s of 60 Hz states: turns left / right / straight, braking on / off, a varying speed.
        let state = |k: u64| {
            let turn = [1.0, -0.7, 0.0, 0.35][(k / 45 % 4) as usize];
            let braking = k / 70 % 2 == 0;
            let speed = 1.0 + 4.0 * (k as f32 * 0.013).sin().abs();
            (speed, turn, braking, k / 400 % 3 == 2)
        };
        const STEPS: u64 = 20 * 60;
        let run = |fps: u64, console: bool| {
            let (mut s, mut c, mut done) = (OwnerSlews::default(), Cadence::default(), 0u64);
            let mut trace = Vec::new();
            for frame in 1.. {
                let now = frame * 60 / fps;
                if now > STEPS {
                    break;
                }
                let ticks = (now - done) as usize;
                done = now;
                let calls = if ticks > 0 { c.advance(ticks) } else { 0 };
                let (v, turn, braking, special) = state(now.saturating_sub(1));
                let frames = 60.0 / fps as f32;
                let i = s.step(Some(&t), v, turn, special, braking, console.then_some(calls), frames);
                if !console || calls > 0 {
                    trace.push((done, i.to_bits(), s.turn.value.to_bits(), s.brake.to_bits()));
                }
            }
            trace
        };
        let at60 = run(60, true);
        assert_eq!(at60.len() as u64, STEPS / 2);
        assert!(at60.iter().any(|x| x.1 != 0) && at60.iter().any(|x| x.3 != 0));
        for fps in [30, 144, 240, 365] {
            assert_eq!(run(fps, true), at60, "{fps} fps");
        }
        // The old per-frame host does depend on the frame rate.
        let on_console_frames = |t: Vec<(u64, u32, u32, u32)>| t.into_iter().filter(|x| x.0 % 2 == 0).collect::<Vec<_>>();
        assert_ne!(on_console_frames(run(30, false)), on_console_frames(run(60, false)));
    }

    #[test]
    fn latches_hold_until_their_release_conditions() {
        let mut l = Latches::default();
        assert!(l.update(true, 2, false, [false; 2]), "balancing sets the manual latch");
        assert!(l.update(false, 2, false, [false; 2]), "held on two wheels");
        assert!(!l.update(false, 4, false, [false; 2]), "four wheels down clears it");
        assert!(l.update(false, 4, true, [false; 2]));
        assert!(l.update(false, 4, false, [true, false]));
        assert!(!l.update(false, 4, false, [true, true]), "both feet back in the box");
    }

    #[test]
    fn slope_levels_need_a_grain_surface() {
        assert_eq!(slope_levels(-5.0, true, -10.0, 10.0), (0.5, 0.0));
        assert_eq!(slope_levels(20.0, true, -10.0, 10.0), (0.0, 1.0));
        assert_eq!(slope_levels(-5.0, false, -10.0, 10.0), (0.0, 0.0));
        assert_eq!(slope_levels(0.0, true, -10.0, 10.0), (0.0, 0.0));
    }

    #[test]
    fn seam_envelope_ramps_once_per_pattern_change() {
        use crate::player::tuning::SeamWobble;
        let spider = SeamWobble { gain_low: 0.8, gain_high: 0.6, ms_low: 30, ms_high: 80 };
        let wobble = |p: u32| if p == 1 { spider } else { SeamWobble::default() };
        let mut e = SeamEnvelope::default();
        e.update(4, 1.0 / 60.0, wobble, || unreachable!("a {{1, 1}} wobble draws nothing"));
        assert_eq!(e.value(), None);
        // range = trunc(−0.2·100) = −19 (f32): gain = 0.8 − (r mod 19)·0.01; ms = 30 + r mod 50.
        let mut draws = [7u32, 23].into_iter();
        e.update(1, 1.0 / 60.0, wobble, || draws.next().unwrap());
        assert_eq!(e.value(), Some(1.0));
        let (gain, ms) = (0.8 - 0.07, 53.0);
        for _ in 0..2 {
            e.update(1, 1.0 / 60.0, wobble, || unreachable!());
        }
        let v = e.value().unwrap();
        assert!((v - (1.0 + (gain - 1.0) * (33.333332 / ms))).abs() < 1e-4, "{v}");
        for _ in 0..10 {
            e.update(1, 1.0 / 60.0, wobble, || unreachable!());
        }
        assert!((e.value().unwrap() - gain).abs() < 1e-6, "holds the drawn gain");
        e.update(0, 1.0 / 60.0, wobble, || unreachable!());
        assert_eq!(e.value(), None);
    }

    #[test]
    fn rocket_position_spans_35_to_60_kmh() {
        let t = RocketTuning { start_kmh: 35.0, top_kmh: 60.0, gain_word: 22000, params: GrainParams { attack: 0.1, sustain: 0.4, release: 0.1, window: 2.4, drift: 0.1 } };
        assert_eq!(rocket_record(&t, 35.0 / 3.6, 32767, 4096).position, 0.0);
        assert!((rocket_record(&t, 47.5 / 3.6, 32767, 4096).position - 0.5).abs() < 1e-4);
        assert!((rocket_record(&t, 47.5 / 3.6, 32767, 4096).gain - 22000.0 / 32767.0).abs() < 1e-6);
    }
}
