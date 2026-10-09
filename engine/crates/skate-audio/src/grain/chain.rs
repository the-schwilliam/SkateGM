//! The board owner's side of the grain bus chains (spec `audio-specs/aems-grain-chain-spec.md`
//! §3–§4): what `SFXObj_SkateBoard`'s process (`sub_824C6A78`, game thread, before the frame's
//! MixMap evaluation) posts to the four chains each frame. Pure state machines; the host feeds the
//! results into [`super::GrainBed::set_chains`] as [`ChainValues`].
//!
//! - [`fss_shifts`] (`sub_824C9058`): the FrequencyShiftSsb values of players A and B.
//! - [`PushShift`] (`sub_824C6198`, owner `+1036`): the push frequency-shift envelope.
//! - [`ChainState::frame`]: the graph-1 → graph-3 send and the graph-1 level ramp by speed
//!   (`sub_824CAEC0`), the two random-walk gain wobbles (`sub_824CB078`) and their posting
//!   (`sub_824CB180`), local player only.
//! - [`Envelope`]: retail's multi-segment envelope (`sub_8248D368` reset, `sub_8248D3C0` add,
//!   `sub_8248D498` append, `sub_8248D510` advance), linear segments.
use super::bed::ChainValues;
use super::board::SurfaceTuning;

/// Retail's segment envelope (up to 5 segments; only the linear kind is used by these callers).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Envelope {
    /// Time inside the current segment (s, `+0`).
    t: f32,
    /// Per segment: duration (s, `+4`), start (`+28`), end (`+52`), start = previous end (`+76`).
    dur: [f32; 6],
    start: [f32; 6],
    end: [f32; 6],
    chained: [bool; 6],
    count: usize,
    seg: usize,
    value: f32,
    done: bool,
}

impl Default for Envelope {
    /// The reset state (`sub_8248D368`): empty, value 0, done.
    fn default() -> Self {
        Self { t: 0.0, dur: [0.0; 6], start: [0.0; 6], end: [0.0; 6], chained: [false; 6], count: 0, seg: 0, value: 0.0, done: true }
    }
}

/// ms → s as `sub_8248D3C0` (`0x82063A48` 0.001, f32).
const MS: f32 = f32::from_bits(0x3A83_126F);
/// A non-positive duration becomes this (`0x820D71E8`).
const MIN_DUR: f32 = f32::from_bits(0x3C23_D70A);

impl Envelope {
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// Add a linear segment `start → end` over `ms` (`sub_8248D3C0`); the first one sets the value
    /// to `start`. False when the envelope is full (5 segments).
    pub fn add(&mut self, start: f32, end: f32, ms: i32) -> bool {
        let i = self.count;
        if i == 5 {
            return false;
        }
        let d = ms as f32 * MS;
        self.dur[i] = if d > 0.0 { d } else { MIN_DUR };
        self.end[i] = end;
        self.start[i] = start;
        self.chained[i] = false;
        self.done = false;
        if i == 0 {
            self.value = self.start[0];
        }
        self.count = i + 1;
        true
    }

    /// Append a segment that starts where the previous one ends (`sub_8248D498`; needs one).
    pub fn append(&mut self, end: f32, ms: i32) -> bool {
        if self.count == 0 || !self.add(0.0, end, ms) {
            return false;
        }
        self.chained[self.count - 1] = true;
        true
    }

    /// Advance by `dt` seconds (`sub_8248D510`): past a segment's end the value is that end and
    /// the next segment starts with the overshoot; past the last one the envelope is done.
    pub fn advance(&mut self, dt: f32) {
        if self.done || self.count == 0 {
            return;
        }
        self.t += dt;
        let s = self.seg;
        if self.t > self.dur[s] {
            self.value = self.end[s];
            if s + 1 < self.count {
                self.t -= self.dur[s];
                self.seg = s + 1;
                if self.chained[s + 1] {
                    self.start[s + 1] = self.end[s];
                }
            } else {
                self.done = true;
            }
            return;
        }
        let u = self.t / self.dur[s];
        self.value = (self.end[s] - self.start[s]).mul_add(u, self.start[s]);
    }

    pub fn value(&self) -> f32 {
        self.value
    }

    pub fn done(&self) -> bool {
        self.done
    }
}

/// The push frequency-shift envelope (owner `+1036`, `sub_824C6198`): on each push plant
/// 0 → peak over the attack, hold, → 0 over the return (ms from the primary truck's collection,
/// peak = [`super::board::push_peaks`]'s shift). Advanced by the frame time every frame, after a
/// trigger. Its value only counts while it runs ([`PushShift::value`]).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PushShift {
    pub env: Envelope,
}

impl PushShift {
    pub fn trigger(&mut self, peak: f32, ms: [f32; 3]) {
        self.env.reset();
        self.env.add(0.0, peak, ms[0] as i32);
        self.env.append(peak, ms[1] as i32);
        self.env.append(0.0, ms[2] as i32);
    }

    pub fn advance(&mut self, dt: f32) {
        self.env.advance(dt);
    }

    /// `+1152` while `+1156` (done) is clear.
    pub fn value(&self) -> Option<f32> {
        (!self.env.done()).then_some(self.env.value())
    }
}

/// The FrequencyShiftSsb values of players A and B (`sub_824C9058`), Hz:
/// - A = (special ? `special_shift` : 0) + push shift + D × A's shift per slope;
/// - B = B's base shift + push shift + D × B's shift per slope.
///
/// `this` is the truck's grain collection (special shift, B base shift), `primary` the primary
/// truck's (both per-slope values); the slope terms only while D > 0 (fused multiply-adds).
pub fn fss_shifts(this: &SurfaceTuning, primary: &SurfaceTuning, special: bool, push_shift: Option<f32>, downhill: f32) -> [f32; 2] {
    let mut a = if special { this.special_shift_hz } else { 0.0 };
    let mut b = this.b_base_shift_hz;
    if let Some(p) = push_shift {
        a = p + a;
        b = p + b;
    }
    if downhill > 0.0 {
        a = primary.a_shift_per_slope_hz.mul_add(downhill, a);
        b = downhill.mul_add(primary.b_shift_per_slope_hz, b);
    }
    [a, b]
}

/// One random-walk wobble's tuning (owner `+1572..+1584` for A's chains, `+1728..+1740` for B's).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WobbleTuning {
    pub ms_low: i32,
    pub ms_high: i32,
    pub low: f32,
    pub high: f32,
}

/// The chain tuning of the board owner class `0x6E878344774A7999` (`default`, `sub_824CA938`);
/// [`Default`] = the vault values.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ChainTuning {
    /// Graph-1 → graph-3 send: 0 below `send_start_kmh`, linear to `send_max` at `send_end_kmh`.
    pub send_start_kmh: f32,
    pub send_end_kmh: f32,
    pub send_max: f32,
    /// Graph-1 level ramp: 1 at `level_start_kmh` → `level_floor` at `level_end_kmh`.
    pub level_start_kmh: f32,
    pub level_end_kmh: f32,
    pub level_floor: f32,
    /// Wobble depth ramp: 0 at `wobble_start_kmh` → 1 at `wobble_end_kmh`.
    pub wobble_start_kmh: f32,
    pub wobble_end_kmh: f32,
    /// A's chains, B's chains.
    pub wobble: [WobbleTuning; 2],
    /// Graph 3: DCl0 level, HS20 corner and gain.
    pub clip: f32,
    pub shelf_hz: f32,
    pub shelf_gain: f32,
}

impl Default for ChainTuning {
    fn default() -> Self {
        Self {
            send_start_kmh: 46.0,
            send_end_kmh: 70.0,
            send_max: 3.0,
            level_start_kmh: 52.0,
            level_end_kmh: 74.0,
            level_floor: f32::from_bits(0x3EE6_6666),
            wobble_start_kmh: 42.0,
            wobble_end_kmh: 70.0,
            wobble: [
                WobbleTuning { ms_low: 15, ms_high: 30, low: 0.0, high: f32::from_bits(0x3E99_999A) },
                WobbleTuning { ms_low: 5, ms_high: 15, low: f32::from_bits(0x3DCC_CCCD), high: 0.25 },
            ],
            clip: f32::from_bits(0x3DB8_51EC),
            shelf_hz: 5000.0,
            shelf_gain: f32::from_bits(0x3F26_6666),
        }
    }
}

/// km/h from m/s as the owner code (`0x822F8628` 3.6).
const KMH: f32 = f32::from_bits(0x4066_6666);

/// One wobble record (`+16` previous target, `+20` graph-1 gain, `+24` last posted, `+28`
/// graph-3 gain, `+32` envelope).
#[derive(Clone, Copy, Debug, PartialEq)]
struct Wobble {
    target: f32,
    gain1: f32,
    posted: f32,
    gain3: f32,
    env: Envelope,
}

impl Default for Wobble {
    /// `sub_824C59C8`: target 0, gains 1, envelope reset (done → the first frame draws).
    fn default() -> Self {
        Self { target: 0.0, gain1: 1.0, posted: 1.0, gain3: 1.0, env: Envelope::default() }
    }
}

impl Wobble {
    /// `sub_824CB078` for one record: a finished segment draws the next (duration in
    /// [ms_low, ms_high) ms, |target| in [low, high) in steps of 0.01, sign opposite to the last
    /// target's — non-negative → negative), else the envelope advances by `dt`.
    fn step(&mut self, t: &WobbleTuning, dt: f32, draw: &mut impl FnMut() -> u32) {
        if self.env.done() {
            let span = t.ms_high.wrapping_sub(t.ms_low) as u32;
            let ms = t.ms_low.wrapping_add((draw() % span.max(1)) as i32);
            let range = ((t.high - t.low) * 100.0) as i32 as u32;
            let m = (draw() % range.max(1)) as i32 as f32;
            let mut target = m.mul_add(0.01, t.low);
            if self.target >= 0.0 {
                target *= -1.0;
            }
            self.env.reset();
            self.env.add(self.target, target, ms);
            self.target = target;
        } else {
            self.env.advance(dt);
        }
    }
}

/// The owner's chain state (local player): `+1556` send, `+1560` level, the two wobbles, and the
/// gains each chain module currently holds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ChainState {
    send: f32,
    level: f32,
    wobble: [Wobble; 2],
    /// [truck][player] = (graph-1 Gain, graph-3 Gain) as last posted to that chain (1.0 = the
    /// constructor default of a freshly built chain).
    applied: [[(f32, f32); 2]; 2],
}

impl Default for ChainState {
    fn default() -> Self {
        Self { send: 0.0, level: 1.0, wobble: [Wobble::default(); 2], applied: [[(1.0, 1.0); 2]; 2] }
    }
}

impl ChainState {
    /// A truck's chains were (re)built (`sub_824C8878`, on every bind): their gains are back at the
    /// module default 1.0 until the wobble next changes; the send is posted at build time.
    pub fn rebuilt(&mut self, truck: usize) {
        self.applied[truck] = [(1.0, 1.0); 2];
    }

    /// One owner frame, in retail's order: `sub_824CAEC0` (send, level ramp), then
    /// `sub_824CB180` → `sub_824CB078` (wobble draws / advance, gains, posts). `speed` = ground speed
    /// (m/s, audio state `+208`), `dt` = the frame time (s), `bound[t]` = truck t has chains (a
    /// post to a chain that doesn't exist is lost, the compare value still updates). `draw` = the
    /// title generator (shared with the seam-pattern draws, which run first in retail's frame).
    pub fn frame(&mut self, t: &ChainTuning, speed: f32, dt: f32, bound: [bool; 2], mut draw: impl FnMut() -> u32) {
        let kmh = speed * KMH;
        // sub_824CAEC0.
        self.send = if kmh >= t.send_end_kmh {
            t.send_max
        } else if kmh >= t.send_start_kmh {
            ((kmh - t.send_start_kmh) / (t.send_end_kmh - t.send_start_kmh)) * t.send_max
        } else {
            0.0
        };
        if kmh >= t.level_end_kmh {
            self.level = t.level_floor;
        } else if kmh >= t.level_start_kmh {
            let u = (kmh - t.level_start_kmh) / (t.level_end_kmh - t.level_start_kmh);
            self.level = (-u).mul_add(1.0 - t.level_floor, 1.0);
        }
        // Below the start the level keeps its last value (no branch there).
        // sub_824CB180.
        for (w, wt) in self.wobble.iter_mut().zip(&t.wobble) {
            w.step(wt, dt, &mut draw);
        }
        let ramp = if kmh >= t.wobble_end_kmh {
            1.0
        } else if kmh >= t.wobble_start_kmh {
            (kmh - t.wobble_start_kmh) / (t.wobble_end_kmh - t.wobble_start_kmh)
        } else {
            0.0
        };
        for w in &mut self.wobble {
            let g = w.env.value().mul_add(ramp, 1.0);
            w.gain3 = g;
            w.gain1 = g * self.level;
        }
        // Post on change; the compare value is per player, not per chain, so after truck 0 posts
        // truck 1 always compares equal and never receives a wobble (retail behaviour).
        for (truck, applied) in self.applied.iter_mut().enumerate() {
            for (p, w) in self.wobble.iter_mut().enumerate() {
                if w.gain3 != w.posted {
                    w.posted = w.gain3;
                    if bound[truck] {
                        applied[p] = (w.gain1, w.gain3);
                    }
                }
            }
        }
    }

    /// The graph-1 → graph-3 send level (posted to all four chains on change and at every build,
    /// so every chain holds the current value).
    pub fn send(&self) -> f32 {
        self.send
    }

    /// The graph-1 level ramp (`+1560`).
    pub fn level(&self) -> f32 {
        self.level
    }

    /// The wobble values e of A's and B's chains (envelope outputs, before the speed ramp).
    pub fn wobble(&self) -> [f32; 2] {
        [self.wobble[0].env.value(), self.wobble[1].env.value()]
    }

    /// (graph-1 Gain, graph-3 Gain) held by truck `t`'s chains A and B.
    pub fn gains(&self, truck: usize) -> [(f32, f32); 2] {
        self.applied[truck]
    }

    /// The truck's two [`ChainValues`] from this state plus the frame's MixMap values.
    pub fn values(&self, truck: usize, f: &ChainFrame) -> [ChainValues; 2] {
        let g = self.applied[truck];
        [0, 1].map(|p| ChainValues {
            highpass_hz: f.highpass_hz,
            lowpass_hz: f.lowpass_hz,
            pan_degrees: f.pan_degrees,
            level: g[p].0,
            fss_hz: f.fss_hz[p],
            graph3_send: self.send,
            graph3_gain: g[p].1,
            env_send: f.env_send,
            flange_send: f.flange_send[p],
        })
    }
}

/// The per-frame inputs of [`ChainState::values`] (`sub_824C9058`, from SkateBoard's MixMap
/// outputs): HPF level(12) / LPF level(11) Hz, pan raw(0) × 360/65535, env send level(13)/32767,
/// the graph-2 first send level(21)/32767 (A) and level(22)/32767 (B) (local player), and the two
/// [`fss_shifts`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ChainFrame {
    pub highpass_hz: f32,
    pub lowpass_hz: f32,
    pub pan_degrees: f32,
    pub env_send: f32,
    pub flange_send: [f32; 2],
    pub fss_hz: [f32; 2],
}

/// raw(0) → Pan2D1 degrees (`0x822F8C64`, 360/65535 as f32).
pub const DEGREES_PER_RAW: f32 = f32::from_bits(0x3BB4_00B4);
/// Level outputs → send levels (`0x822F8898`).
pub const PER_LEVEL: f32 = crate::dsp::INV_32767;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::eval::rng::Rng;

    #[test]
    fn envelope_segments_carry_their_overshoot() {
        let mut e = Envelope::default();
        assert!(e.done());
        e.add(0.0, -40.0, 30);
        e.append(-40.0, 200);
        e.append(0.0, 600);
        assert_eq!(e.value(), 0.0);
        e.advance(0.015);
        assert!((e.value() + 20.0).abs() < 1e-3);
        e.advance(0.02); // 35 ms: past the attack → its end, 5 ms into the hold
        assert_eq!(e.value(), -40.0);
        e.advance(0.1);
        assert_eq!(e.value(), -40.0, "hold (start copied from the previous end)");
        e.advance(0.1); // 205 ms: past the hold → −40, 5 ms into the return
        assert_eq!(e.value(), -40.0);
        e.advance(0.3); // 305 of 600 ms
        assert!((e.value() + 40.0 * (1.0 - 0.305 / 0.6)).abs() < 1e-3, "{}", e.value());
        e.advance(0.31);
        assert_eq!((e.value(), e.done()), (0.0, true));
        let mut p = PushShift::default();
        assert_eq!(p.value(), None);
        p.trigger(-52.0, [30.0, 200.0, 600.0]);
        p.advance(1.0 / 60.0);
        assert!(p.value().unwrap() < -25.0);
        assert!(Envelope::default().add(1.0, 2.0, 0), "0 ms becomes 10 ms");
    }

    #[test]
    fn fss_values_follow_sub_824c9058() {
        use crate::grain::board::PushTuning;
        use crate::grain::player::GrainParams;
        let p = GrainParams { attack: 0.1, sustain: 0.2, release: 0.1, window: 1.6, drift: 0.05 };
        let t = SurfaceTuning {
            max_kmh: 60.0,
            bezier: [0.0, 0.0, 1.0, 1.0],
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
        };
        assert_eq!(fss_shifts(&t, &t, false, None, 0.0), [0.0, -10.0]);
        assert_eq!(fss_shifts(&t, &t, true, None, 0.0), [150.0, -10.0], "manual / trick: +150 Hz on A");
        assert_eq!(fss_shifts(&t, &t, true, Some(-30.0), 0.0), [120.0, -40.0]);
        assert_eq!(fss_shifts(&t, &t, false, None, 0.5), [-50.0, 15.0]);
    }

    #[test]
    fn send_and_level_by_speed_with_the_hold_quirk() {
        let t = ChainTuning::default();
        let mut s = ChainState::default();
        let mut rng = Rng::new(crate::grain::GrainBed::SEED);
        let mut at = |s: &mut ChainState, kmh: f32| {
            s.frame(&t, kmh / 3.6, 1.0 / 60.0, [true, false], || rng.draw());
            (s.send(), s.level())
        };
        assert_eq!(at(&mut s, 40.0), (0.0, 1.0));
        let (send, level) = at(&mut s, 58.0);
        assert!((send - 1.5).abs() < 1e-4 && (level - (1.0 - 6.0 / 22.0 * 0.55)).abs() < 1e-4, "{send} {level}");
        assert_eq!(at(&mut s, 90.0), (3.0, t.level_floor));
        let (send, level) = at(&mut s, 30.0);
        assert_eq!((send, level), (0.0, t.level_floor), "the level holds below its start");
    }

    #[test]
    fn wobbles_walk_within_their_bounds_and_alternate() {
        let t = ChainTuning::default();
        let mut s = ChainState::default();
        let mut rng = Rng::new(crate::grain::GrainBed::SEED);
        let mut targets = [Vec::new(), Vec::new()];
        let (mut lo, mut hi) = ([f32::MAX; 2], [f32::MIN; 2]);
        for _ in 0..20_000 {
            s.frame(&t, 100.0 / 3.6, 1.0 / 60.0, [true, true], || rng.draw());
            for p in 0..2 {
                let w = s.wobble[p];
                if targets[p].last() != Some(&w.target) {
                    targets[p].push(w.target);
                }
                let g = s.gains(0)[p].1;
                lo[p] = lo[p].min(g);
                hi[p] = hi[p].max(g);
                // Full ramp at 100 km/h; graph 1 = graph 3 × the level floor once posted (the
                // first frame draws, its value 0 → 1.0 = the default: nothing posted).
                if g != 1.0 {
                    assert_eq!(s.gains(0)[p].0, g * t.level_floor);
                }
            }
            assert_eq!(s.gains(1), [(1.0, 1.0); 2], "truck 1 never receives a wobble");
        }
        assert!(lo[0] >= 0.7 - 1e-6 && hi[0] <= 1.3 + 1e-6 && lo[0] < 0.75 && hi[0] > 1.25, "A {} {}", lo[0], hi[0]);
        assert!(lo[1] >= 0.75 - 1e-6 && hi[1] <= 1.25 + 1e-6, "B {} {}", lo[1], hi[1]);
        for (p, ts) in targets.iter().enumerate() {
            assert!(ts[0] <= 0.0, "the first target is negative");
            for w in ts.windows(2) {
                assert!(w[0] * w[1] <= 0.0, "signs alternate ({p}: {} {})", w[0], w[1]);
            }
            let (low, high) = (t.wobble[p].low, t.wobble[p].high);
            assert!(ts.iter().all(|x| x.abs() >= low - 1e-6 && x.abs() < high), "{p}");
        }
        // B's 5–15 ms segments end every frame at 60 Hz (one frame of advance, one of redraw).
        assert!(targets[1].len() > targets[0].len());
    }

    #[test]
    fn rebuilt_chains_hold_unity_until_the_next_change() {
        let t = ChainTuning::default();
        let mut s = ChainState::default();
        let mut rng = Rng::new(crate::grain::GrainBed::SEED);
        for _ in 0..30 {
            s.frame(&t, 60.0 / 3.6, 1.0 / 60.0, [true, false], || rng.draw());
        }
        assert_ne!(s.gains(0)[0], (1.0, 1.0));
        // Slow down below 42 km/h: the wobble settles at 1 and posts once, × the held level.
        for _ in 0..3 {
            s.frame(&t, 20.0 / 3.6, 1.0 / 60.0, [true, false], || rng.draw());
        }
        let held = s.level();
        assert!(held < 1.0);
        assert_eq!(s.gains(0)[0], (held, 1.0));
        s.rebuilt(0);
        for _ in 0..30 {
            s.frame(&t, 20.0 / 3.6, 1.0 / 60.0, [true, false], || rng.draw());
        }
        assert_eq!(s.gains(0)[0], (1.0, 1.0), "a rebuilt chain loses the held level until a change");
    }

    #[test]
    fn vault_defaults() {
        let t = ChainTuning::default();
        assert_eq!((t.clip, t.shelf_gain, t.level_floor), (0.09, 0.65, 0.45));
        assert_eq!(t.wobble[0].high, 0.3);
        assert_eq!(t.wobble[1].low, 0.1);
        assert_eq!(DEGREES_PER_RAW, 360.0 / 65535.0);
    }
}
