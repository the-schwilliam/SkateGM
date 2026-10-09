//! The environment (reverb) network (spec `audio-specs/aems-env-bus-spec.md`): the mono
//! "EnvSendSub" bus every standard voice's Send A feeds, split into two sides A / B (for preset
//! crossfades), each = EnvSub (gain → PeakingIir2) → RvrbSub (pre-delay → ReverbModel1 → gain →
//! two filtered outputs panned 270° / 90° with LFE 0.5) + two echo taps (delay → HPF → LPF → gain
//! → panner, delay and pan swept by the per-block LFO task), all into SFX Master.
//!
//! Presets: vault class `204CAC1FD77088B8` (`aud_reverb/reverbNN`, 44 values by record offset,
//! applied as `sub_8248DD18` posts them); a preset change loads the new preset on the other side
//! with weight 0 and crossfades the two side weights linearly over 1.0 s of game time
//! (`sub_824DE548` timed fade, re-posted per frame).
//!
//! The reverb-zone emitters (type 5: zone fades, zone-to-zone, the pan rotation toward the zone)
//! and retail's frame order are in [`super::zones`] ([`EnvNetwork::update`]); the global env-send
//! scale from the Reverb owner in [`EnvNetwork::scale_frame`]; the FlangeSub returns in
//! [`super::flange`].
//!
//! Not modelled (UNCERTAIN in the spec): the non-voice contributors other than the owner one-shot
//! buses and the Collision SubMix, the module timer delay before a new reverb configuration is
//! heard (applied at the next block here).
use crate::BLOCK;
use crate::dsp::biquad::{Iir2, Kind};
use crate::dsp::delay::Delay;
use crate::dsp::gain::Gain;
use crate::dsp::pan::{self, Pan2D};
use crate::dsp::peaking::PeakingIir2;
use crate::dsp::reverb::ReverbModel1;
use crate::dsp::send::RAMP_STEP;

/// Block time step (256/48000 as f32, 0x3BAEC33E).
const DT: f32 = BLOCK as f32 / 48000.0;
/// 2π as the image holds it (0x820B411C).
const TWO_PI: f32 = 6.283_185_5;
/// The global env-send scale (manager +104) as the constructor writes it; per frame
/// `sub_824DF220` rewrites it from the MixMap Reverb owner's out4 ([`EnvNetwork::scale_frame`]).
pub const ENV_SCALE: f32 = 1.0;
/// The crossfade length (s) between presets (0x8231A844).
pub const FADE: f32 = 1.0;

/// One preset: the 44 record values in offset order (offset = 4 × index).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Preset(pub [f32; 44]);

impl Preset {
    fn at(&self, offset: usize) -> f32 {
        self.0[offset / 4]
    }
}

/// A send level with Sen0's ramp: 64 samples to 64/65 of the way, flat after.
#[derive(Clone, Copy, Debug)]
pub struct Level {
    pub target: f32,
    current: f32,
    started: bool,
}

impl Level {
    pub fn new(target: f32) -> Self {
        Self { target, current: target, started: false }
    }

    /// A send that has already processed blocks at `level` (its class default when nothing was
    /// posted): the next posted target ramps from there instead of starting flat.
    pub fn running(level: f32) -> Self {
        Self { target: level, current: level, started: true }
    }

    /// dst[k] += level(k) · src[k].
    pub fn add(&mut self, src: &[f32], dst: &mut [f32]) {
        if !self.started {
            self.current = self.target;
            self.started = true;
        }
        let (from, to) = (self.current, self.target);
        if from == to {
            if to != 0.0 {
                for (d, &s) in dst.iter_mut().zip(src) {
                    *d += to * s;
                }
            }
        } else {
            let step = (to - from) * RAMP_STEP;
            let flat = from + 64.0 * step;
            for (k, (d, &s)) in dst.iter_mut().zip(src).enumerate() {
                *d += if k < 64 { from + k as f32 * step } else { flat } * s;
            }
        }
        self.current = to;
    }

    pub fn silent(&self) -> bool {
        self.target == 0.0 && self.current == 0.0
    }
}

/// One LFO record (`sub_82490B60`): out = centre + depth · amount · sin(2π · phase / period).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Lfo {
    pub period: f32,
    pub phase: f32,
    pub amount: f32,
    pub centre: f32,
    pub depth: f32,
}

impl Lfo {
    fn template(centre: f32) -> Self {
        Self { period: 1.0, phase: 0.0, amount: 0.5, centre, depth: centre }
    }

    /// One block: advance the phase (truncating fmod) and return the output.
    pub fn step(&mut self) -> f32 {
        let p = self.phase + DT;
        self.phase = if self.period > 0.0 { p - (p / self.period).trunc() * self.period } else { 0.0 };
        let x = if self.period > 0.0 { TWO_PI * self.phase / self.period } else { 0.0 };
        self.centre + self.depth * self.amount * (x as f64).sin() as f32
    }
}

fn period(rate: f32, min: f32) -> f32 {
    if rate >= min { 1.0 / rate } else { 10.0 }
}

/// A filtered, panned output (rvrbfiltsub / the tail of rvrbdelaysub).
#[derive(Clone, Debug)]
struct Out {
    hpf: Iir2,
    lpf: Iir2,
    gain: Gain,
    pan: Pan2D,
}

impl Out {
    fn new(azimuth: f32) -> Self {
        let mut pan = Pan2D::new(1);
        pan.params[pan::ANGLE] = azimuth;
        pan.params[pan::DISTANCE] = 1.0;
        pan.params[pan::LFE] = 0.5;
        Self { hpf: Iir2::new(Kind::HighPass), lpf: Iir2::new(Kind::LowPass), gain: Gain::default(), pan }
    }

    fn set(&mut self, lpf: f32, hpf: f32, gain: f32) {
        self.lpf.cutoff = lpf;
        self.hpf.cutoff = hpf;
        self.gain.target = gain;
    }

    /// Filter, gain, pan the mono block and add it into SFX Master.
    fn render(&mut self, x: &mut [f32; BLOCK], master: &mut [[f32; BLOCK]; 6]) {
        {
            let mut planes: [&mut [f32]; 1] = [&mut x[..]];
            self.hpf.process(&mut planes, 48000.0);
            self.lpf.process(&mut planes, 48000.0);
            self.gain.process(&mut planes);
        }
        let mut six = [[0.0f32; BLOCK]; 6];
        self.pan.process(&[&x[..]], &mut six);
        for (m, s) in master.iter_mut().zip(six.iter()) {
            for (a, b) in m.iter_mut().zip(s.iter()) {
                *a += b;
            }
        }
    }
}

/// One side: EnvSub, RvrbSub with its two outputs, two echo taps, and its LFO records.
#[derive(Clone, Debug)]
pub struct Side {
    /// EnvSendSub's Sen0 to this side (the crossfade weight).
    pub weight: Level,
    g_in: Gain,
    eq: PeakingIir2,
    s_rev: Level,
    s_tap: [Level; 2],
    predelay: Delay,
    reverb: ReverbModel1,
    g_rev: Gain,
    outs: [Out; 2],
    taps: [(Delay, Out); 2],
    /// LFO records: EQ frequency, tap 1 / tap 2 delay, tap 1 / tap 2 azimuth.
    pub lfo: [Lfo; 5],
    pub preset: Option<u64>,
}

impl Side {
    fn new(weight: f32) -> Self {
        Self {
            weight: Level::new(weight),
            g_in: Gain::default(),
            eq: PeakingIir2::default(),
            s_rev: Level::new(1.0),
            s_tap: [Level::new(1.0); 2],
            predelay: Delay::new(0.16, 1),
            reverb: ReverbModel1::default(),
            g_rev: Gain::default(),
            outs: [Out::new(270.0), Out::new(90.0)],
            taps: [(Delay::new(0.46, 1), Out::new(270.0)), (Delay::new(0.46, 1), Out::new(90.0))],
            lfo: [Lfo::template(1.0), Lfo::template(0.3), Lfo::template(0.3), Lfo::template(0.3), Lfo::template(0.3)],
            preset: None,
        }
    }

    /// The three EnvSub sends (→ reverb, → tap 1, → tap 2) of a preset, before the scale.
    pub(crate) fn sends(p: &Preset) -> [f32; 3] {
        [p.at(52), p.at(60), p.at(56)]
    }

    fn set_sends(&mut self, sends: [f32; 3], scale: f32) {
        self.s_rev.target = sends[0] * scale;
        self.s_tap[0].target = sends[1] * scale;
        self.s_tap[1].target = sends[2] * scale;
    }

    /// `sub_8248DD18`: post a preset's values (the side weight is set by the caller); the sends
    /// × the global env scale (manager +104).
    pub fn apply(&mut self, key: u64, p: &Preset) {
        self.apply_scaled(key, p, ENV_SCALE);
    }

    pub(crate) fn apply_scaled(&mut self, key: u64, p: &Preset, scale: f32) {
        self.preset = Some(key);
        self.g_in.target = p.at(84);
        let f_eq = p.at(80);
        self.eq.freq = f_eq;
        let g = p.at(76);
        self.eq.gain = if (0.1..=20.0).contains(&g) { g } else { 0.1 };
        let q = p.at(64);
        self.eq.q = if (0.2..=20.0).contains(&q) { q } else { 0.2 };
        self.lfo[0] = Lfo { period: period(p.at(68), 0.1), phase: 0.0, amount: p.at(72), centre: f_eq, depth: f_eq };
        self.set_sends(Self::sends(p), scale);
        self.predelay.delay = p.at(12);
        self.predelay.feedback = p.at(16);
        self.reverb.time = p.at(20);
        self.reverb.size = p.at(24);
        self.reverb.brightness = p.at(32);
        self.g_rev.target = p.at(28);
        self.outs[0].set(p.at(36), p.at(40), p.at(44));
        self.outs[1].set(p.at(0), p.at(4), p.at(8));
        // Pn21 p0 of the two reverb outputs: the code constants 270 / 90 (a zone blend rotates
        // them, `sub_824DEEF0`).
        self.outs[0].pan.params[pan::ANGLE] = 270.0;
        self.outs[1].pan.params[pan::ANGLE] = 90.0;
        // Tap 1: delay +168, fb +172, delay LFO depth +156 / rate +152, LPF +148, HPF +160, gain +164.
        let (d1, d2) = (p.at(168), p.at(128));
        self.taps[0].0.delay = d1;
        self.taps[0].0.feedback = p.at(172);
        self.taps[0].1.set(p.at(148), p.at(160), p.at(164));
        self.lfo[1] = Lfo { period: period(p.at(152), 0.01), phase: 0.0, amount: p.at(156), centre: d1, depth: d1 };
        // Tap 2: delay +128, fb +132, depth +116 / rate +112, LPF +108, HPF +120, gain +124.
        self.taps[1].0.delay = d2;
        self.taps[1].0.feedback = p.at(132);
        self.taps[1].1.set(p.at(108), p.at(120), p.at(124));
        self.lfo[2] = Lfo { period: period(p.at(112), 0.01), phase: 0.0, amount: p.at(116), centre: d2, depth: d2 };
        // The echo pans: rate +88, depth +92; tap 2 swings in the opposite phase.
        let pan_period = period(p.at(88), 0.01);
        self.lfo[3] = Lfo { period: pan_period, phase: 0.0, amount: p.at(92), centre: 270.0, depth: 90.0 };
        self.lfo[4] = Lfo { period: pan_period, phase: pan_period / 2.0, amount: p.at(92), centre: 90.0, depth: 90.0 };
    }

    /// `sub_824DE400` → `sub_8248D770`: the per-frame re-post of a side's blend weight and its
    /// reverb outputs' azimuths (the EQ frequency, tap delays and tap pans it also posts are
    /// overwritten by the LFO task within the block).
    pub(crate) fn post(&mut self, weight: f32, pans: [f32; 2]) {
        self.weight.target = weight;
        self.outs[0].pan.params[pan::ANGLE] = pans[0];
        self.outs[1].pan.params[pan::ANGLE] = pans[1];
    }

    /// The reverb outputs' azimuths (filt L, filt R).
    pub fn pans(&self) -> [f32; 2] {
        [self.outs[0].pan.params[pan::ANGLE], self.outs[1].pan.params[pan::ANGLE]]
    }

    fn render(&mut self, input: &[f32; BLOCK], master: &mut [[f32; BLOCK]; 6]) {
        // The LFO task runs every block whether or not anything sounds.
        self.eq.freq = self.lfo[0].step();
        self.taps[0].0.delay = self.lfo[1].step();
        self.taps[1].0.delay = self.lfo[2].step();
        self.taps[0].1.pan.params[pan::ANGLE] = self.lfo[3].step();
        self.taps[1].1.pan.params[pan::ANGLE] = self.lfo[4].step();
        let mut x = [0.0f32; BLOCK];
        self.weight.add(input, &mut x);
        {
            let mut planes: [&mut [f32]; 1] = [&mut x[..]];
            self.g_in.process(&mut planes);
            self.eq.process(&mut planes, 48000.0);
        }
        let mut rev = [0.0f32; BLOCK];
        self.s_rev.add(&x, &mut rev);
        {
            let mut planes: [&mut [f32]; 1] = [&mut rev[..]];
            self.predelay.process(&mut planes);
        }
        self.reverb.process(&mut rev);
        {
            let mut planes: [&mut [f32]; 1] = [&mut rev[..]];
            self.g_rev.process(&mut planes);
        }
        for out in &mut self.outs {
            let mut copy = rev;
            out.render(&mut copy, master);
        }
        for (k, (delay, out)) in self.taps.iter_mut().enumerate() {
            let mut tap = [0.0f32; BLOCK];
            self.s_tap[k].add(&x, &mut tap);
            {
                let mut planes: [&mut [f32]; 1] = [&mut tap[..]];
                delay.process(&mut planes);
            }
            out.render(&mut tap, master);
        }
    }
}

/// The whole network plus the preset selection.
#[derive(Clone, Debug)]
pub struct EnvNetwork {
    pub sides: [Side; 2],
    pub presets: std::collections::HashMap<u64, Preset>,
    /// The side currently in use, and the running fade (target side, elapsed s).
    pub current: usize,
    pub fade: Option<(usize, f32)>,
    /// Manager +104, the global env-send scale (1.0 until [`EnvNetwork::scale_frame`]).
    pub scale: f32,
    /// The sends of the last applied preset (the parameter block at manager +868 + 32..40).
    pub(crate) last_sends: Option<[f32; 3]>,
    /// `SFXObj_Reverb`'s retail state machine ([`EnvNetwork::update`]); unused by the
    /// `request` / `frame` path.
    pub selector: super::zones::Selector,
}

impl Default for EnvNetwork {
    fn default() -> Self {
        Self { sides: [Side::new(1.0), Side::new(0.0)], presets: Default::default(), current: 0, fade: None, scale: ENV_SCALE, last_sends: None, selector: Default::default() }
    }
}

/// `sub_824DF390`'s jump table (`0x824DF3D0`): a preset's number (record `+48`, the NN of
/// reverbNN, 1..24) → the MixMap Reverb input `sub_824DF468` raises to 32767 (the other six are
/// written 0 the same frame); 0 or > 24 → none.
pub fn reverb_input(number: i32) -> Option<usize> {
    match number {
        1..=5 => Some(4),
        6..=8 => Some(0),
        9 | 13 | 14 | 17 | 18 => Some(1),
        10 => Some(2),
        21 => Some(3),
        11 | 12 | 15 | 16 | 22 => Some(5),
        19 | 20 | 23 | 24 => Some(6),
        _ => None,
    }
}

/// reverb01, the preset when the region layer gives none (`A2782D75A971CC8C`).
pub const DEFAULT_PRESET: u64 = 0xA278_2D75_A971_CC8C;

impl EnvNetwork {
    /// Presets loaded: the network renders; without any it stays silent (no wet path).
    pub fn enabled(&self) -> bool {
        !self.presets.is_empty()
    }

    /// The preset key in use (or being faded to).
    pub fn key(&self) -> Option<u64> {
        match self.fade {
            Some((t, _)) => self.sides[t].preset,
            None => self.sides[self.current].preset,
        }
    }

    /// Ask for a preset (per game frame): starts a 1 s fade on the other side when it differs from
    /// the current one and no fade runs (`sub_824DE548` / `sub_824DE468`). The very first preset
    /// is applied at once on the current side.
    pub fn request(&mut self, key: u64) {
        let key = if self.presets.contains_key(&key) { key } else { DEFAULT_PRESET };
        let Some(p) = self.presets.get(&key).copied() else { return };
        if self.fade.is_some() || self.sides[self.current].preset == Some(key) {
            return;
        }
        self.last_sends = Some(Side::sends(&p));
        if self.sides[self.current].preset.is_none() {
            self.sides[self.current].apply_scaled(key, &p, self.scale);
            return;
        }
        let target = 1 - self.current;
        self.sides[target].apply_scaled(key, &p, self.scale);
        self.sides[target].weight.target = 0.0;
        self.fade = Some((target, 0.0));
    }

    /// The per-frame fade step (`sub_824DE850`): weights new = x, old = 1 − x, x = elapsed / 1 s.
    pub fn frame(&mut self, dt: f32) {
        let Some((target, elapsed)) = self.fade else { return };
        let elapsed = elapsed + dt;
        let x = (elapsed / FADE).min(1.0);
        self.sides[target].weight.target = x;
        self.sides[1 - target].weight.target = 1.0 - x;
        if x >= 1.0 {
            self.current = target;
            self.fade = None;
        } else {
            self.fade = Some((target, elapsed));
        }
    }

    /// The preset on the side being faded to (`+420`; the current one when no fade runs): what
    /// `sub_824DF390` reads.
    pub fn target_key(&self) -> Option<u64> {
        let side = if self.selector.active() { self.selector.target_side() } else { self.fade.map_or(self.current, |(t, _)| t) };
        self.sides[side].preset
    }

    /// `sub_824DF468` (first step of `SFXObj_Reverb`'s update `sub_824DE548`, before the MixMap
    /// tick): Reverb.in0..in6 = 0, then the input of the target side's preset number
    /// ([`reverb_input`]) = 32767. All 0 without presets.
    pub fn reverb_inputs(&self) -> [i32; 7] {
        let mut v = [0; 7];
        let number = self.target_key().and_then(|k| self.presets.get(&k)).map(|p| p.at(48) as i32);
        if let Some(i) = number.and_then(reverb_input) {
            v[i] = 32767;
        }
        v
    }

    /// `sub_824DF220` → `sub_8248DB78`, per game frame after the MixMap tick: the global scale =
    /// the Reverb owner's out4 / 32767, and the EnvSub sends of the side being faded to and of the
    /// current side are re-posted as the *last applied* preset's sends × the scale (during a fade
    /// the old side takes the new preset's sends: retail keeps one parameter block). Optional: a
    /// host that never calls it keeps the constructor's 1.0 and the per-side sends.
    pub fn scale_frame(&mut self, out4: i32) {
        self.scale = out4 as f32 * crate::dsp::INV_32767;
        let Some(sends) = self.last_sends else { return };
        let (target, current) = if self.selector.active() {
            (self.selector.target_side(), self.current)
        } else {
            (self.fade.map_or(self.current, |(t, _)| t), self.current)
        };
        self.sides[target].set_sends(sends, self.scale);
        if target != current {
            self.sides[current].set_sends(sends, self.scale);
        }
    }

    /// Render one block of the mono env input into SFX Master.
    pub fn render(&mut self, input: &[f32; BLOCK], master: &mut [[f32; BLOCK]; 6]) {
        if !self.enabled() {
            return;
        }
        for side in &mut self.sides {
            if side.preset.is_some() {
                side.render(input, master);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reverb01() -> Preset {
        // reverb01's values by offset (the user's vault; only the first preset, for the test).
        Preset([
            4000.0, 600.0, 1.0, 0.08, 0.0, 1.5, 70.0, 1.0, 0.7, 4000.0, 500.0, 1.0, 1.0, 0.25, 1.0, 1.0, 3.0, 0.1, 0.34, 1.0, 1161.0,
            0.5, 0.2, 0.6, 1.0, 1.0, 270.0, 5000.0, 0.5, 0.45, 500.0, 0.75, 0.3, 0.3, 1.0, 1.0, 90.0, 5000.0, 0.51, 0.5, 500.0, 0.75,
            0.28, 0.25,
        ])
    }

    #[test]
    fn an_impulse_comes_back_as_a_wet_tail_on_the_sides() {
        let mut env = EnvNetwork::default();
        env.presets.insert(DEFAULT_PRESET, reverb01());
        env.request(0x1234); // unknown → reverb01
        assert_eq!(env.key(), Some(DEFAULT_PRESET));
        let mut first = true;
        let mut energy = [0.0f32; 6];
        for _ in 0..200 {
            let mut input = [0.0f32; BLOCK];
            if first {
                input[0] = 1.0;
                first = false;
            }
            let mut master = [[0.0f32; BLOCK]; 6];
            env.render(&input, &mut master);
            for (e, ch) in energy.iter_mut().zip(master.iter()) {
                *e += ch.iter().map(|v| v * v).sum::<f32>();
            }
        }
        // The reverb and echoes sit left and right (Ls/L, Rs/R); LFE gets 0.5 of each.
        assert!(energy[3] > 0.0 && energy[4] > 0.0 && energy[5] > 0.0, "{energy:?}");
        assert!(energy[3] > energy[1] * 10.0, "centre stays (nearly) dry: {energy:?}");
    }

    #[test]
    fn the_reverb_owner_scales_the_sends_of_the_last_applied_preset() {
        let mut env = EnvNetwork::default();
        let mut other = reverb01();
        other.0[13] = 0.5; // +52 s_rev
        env.presets.insert(DEFAULT_PRESET, reverb01());
        env.presets.insert(7, other);
        env.request(DEFAULT_PRESET);
        assert_eq!(env.sides[0].s_rev.target, 0.25);
        env.scale_frame(32730);
        let scale = 32730.0 * crate::dsp::INV_32767;
        assert_eq!(env.sides[0].s_rev.target, 0.25 * scale);
        // A fade to preset 7: the new side is applied at the current scale, and the per-frame
        // re-post gives both sides preset 7's sends.
        env.request(7);
        assert_eq!(env.sides[1].s_rev.target, 0.5 * scale);
        assert_eq!(env.sides[0].s_rev.target, 0.25 * scale);
        env.scale_frame(32730);
        assert_eq!(env.sides[0].s_rev.target, 0.5 * scale);
        assert_eq!(env.sides[0].s_tap[0].target, 1.0 * scale);
    }

    #[test]
    fn the_reverb_inputs_follow_the_preset_being_faded_to() {
        let mut env = EnvNetwork::default();
        assert_eq!(env.reverb_inputs(), [0; 7], "no presets: nothing raised");
        let mut eleven = reverb01();
        eleven.0[12] = 11.0; // reverb11 (the zones' BEEFC8E3DE04FBAE)
        let mut nine = reverb01();
        nine.0[12] = 9.0;
        env.presets.insert(DEFAULT_PRESET, reverb01());
        env.presets.insert(11, eleven);
        env.presets.insert(9, nine);
        env.request(DEFAULT_PRESET);
        assert_eq!(env.reverb_inputs(), [0, 0, 0, 0, 32767, 0, 0], "reverb01 → in4");
        env.request(11);
        assert_eq!(env.reverb_inputs(), [0, 0, 0, 0, 0, 32767, 0], "the target side's preset, from the fade's start");
        for _ in 0..61 {
            env.frame(1.0 / 60.0);
        }
        assert_eq!(env.reverb_inputs()[5], 32767, "committed");
        env.request(9);
        assert_eq!(env.reverb_inputs(), [0, 32767, 0, 0, 0, 0, 0]);
        let table: Vec<Option<usize>> = (0..=25).map(reverb_input).collect();
        assert_eq!(table[0], None);
        assert_eq!(table[25], None);
        assert_eq!((1..=24).filter(|&n| reverb_input(n) == Some(5)).collect::<Vec<_>>(), vec![11, 12, 15, 16, 22]);
    }

    #[test]
    fn a_new_preset_fades_in_over_one_second() {
        let mut env = EnvNetwork::default();
        let mut other = reverb01();
        other.0[5] = 1.04;
        env.presets.insert(DEFAULT_PRESET, reverb01());
        env.presets.insert(7, other);
        env.request(DEFAULT_PRESET);
        env.request(7);
        assert_eq!(env.fade, Some((1, 0.0)));
        env.request(DEFAULT_PRESET); // ignored while fading
        for _ in 0..30 {
            env.frame(1.0 / 60.0);
        }
        assert!((env.sides[1].weight.target - 0.5).abs() < 1e-3);
        for _ in 0..31 {
            env.frame(1.0 / 60.0);
        }
        assert_eq!((env.current, env.fade), (1, None));
        assert_eq!(env.sides[0].weight.target, 0.0);
        let mut lfo = Lfo { period: 1.0, phase: 0.0, amount: 0.5, centre: 1.0, depth: 1.0 };
        let first = lfo.step();
        assert!((first - (1.0 + 0.5 * (TWO_PI * DT).sin())).abs() < 1e-6);
    }
}

#[cfg(test)]
mod timing {
    use super::*;

    #[test]
    #[ignore = "timing print"]
    fn first_blocks_cost() {
        let mut env = EnvNetwork::default();
        env.presets.insert(DEFAULT_PRESET, Preset([
            4000.0, 600.0, 1.0, 0.08, 0.0, 1.5, 70.0, 1.0, 0.7, 4000.0, 500.0, 1.0, 1.0, 0.25, 1.0, 1.0, 3.0, 0.1, 0.34, 1.0, 1161.0,
            0.5, 0.2, 0.6, 1.0, 1.0, 270.0, 5000.0, 0.5, 0.45, 500.0, 0.75, 0.3, 0.3, 1.0, 1.0, 90.0, 5000.0, 0.51, 0.5, 500.0, 0.75,
            0.28, 0.25,
        ]));
        let t = std::time::Instant::now();
        env.request(DEFAULT_PRESET);
        println!("request {:?}", t.elapsed());
        for b in 0..5 {
            let t = std::time::Instant::now();
            let mut master = [[0.0f32; BLOCK]; 6];
            env.render(&[0.1; BLOCK], &mut master);
            println!("block {b}: {:?}", t.elapsed());
        }
    }
}
