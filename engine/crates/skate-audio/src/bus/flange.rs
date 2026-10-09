//! The two "FlangeSub" effect returns (spec `audio-specs/aems-bus-leftovers-spec.md` §1; builder
//! `sub_82490270`, presets `sub_824DDF58` → `sub_8248FE68`, levels `sub_824DF220` → `sub_8248FFF8`,
//! sweeps by the LFO task `sub_82490B60` records 11–14).
//!
//! Per return (graph order 150, mono): `Sub0 → Del0 (max 15 ms) → PI20 → Sen0 (→ env bus) → Gai0 →
//! Pn21 (1 → 6) → Sen0 (→ SFX Master)`.
//! - Voices whose routing records hold 4096 / 8192 (return A) or 16384 (return B) followed by an
//!   enable record of 1 get a Send B after their Gain: the post-gain channels summed to mono
//!   (routes N → 1 at unity, LFE dropped) at property 11 / 32767 (posted 0 at open).
//! - Del0's delay is swept every block: d(t) = d₀ + d₀·depth·sin(2π·t·rate) (record fields +20,
//!   +28, +24), whole samples with Del0's 128-sample tap crossfade; feedback stays at the class
//!   default 0 (nothing posts it). Retail's dry voice plus this short, moving copy is a flanger.
//! - PI20's frequency is swept the same way (+16, +8, +4) but its gain is never posted: class
//!   default 1.0 = bypass.
//! - Levels per game frame from the MixMap's Reverb owner (`0x40050000`): A gain = out0, A env
//!   send = out1, B gain = out2, B env send = out3 (each / 32767). Class defaults (1.0 / 1.0)
//!   until the first frame.
//! - Pn21: parameter 0 posted from manager +124 / +160, which nothing we found writes (zeroed
//!   allocation assumed): azimuth 0 on the speaker circle, i.e. the centre. UNCERTAIN.
//! - A return renders only in blocks where some voice sends into it (retail's trace shows return
//!   A's modules processed only in bursts); its LFO records advance every block regardless.
use crate::BLOCK;
use crate::bus::env::{Level, Lfo};
use crate::dsp::delay::Delay;
use crate::dsp::gain::Gain;
use crate::dsp::pan::Pan2D;
use crate::dsp::peaking::PeakingIir2;

/// 1/32767 (0x822F8898).
const INV_32767: f32 = crate::dsp::INV_32767;

/// One return's vault record (class `4CDD7CDC1A955D5C`; collection `C6290FFCB9E84CD9` = return A
/// (type 12288), `DFDFFAD67CCBA322` = return B (16384)): the nine values by record offset 0..32.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FlangePreset(pub [f32; 9]);

impl FlangePreset {
    fn at(&self, offset: usize) -> f32 {
        self.0[offset / 4]
    }
}

#[derive(Clone, Debug)]
pub struct FlangeReturn {
    delay: Delay,
    eq: PeakingIir2,
    /// LFO records 11/13 (Del0 p0) and 12/14 (PI20 p0).
    pub lfo_delay: Lfo,
    pub lfo_eq: Lfo,
    /// Sen0 → env bus (Reverb out1 / out3).
    pub env: Level,
    /// Gai0 (Reverb out0 / out2).
    gain: Gain,
    pan: Pan2D,
    pub preset: Option<FlangePreset>,
}

impl Default for FlangeReturn {
    fn default() -> Self {
        // `sub_824907D8` templates: period 1 s, amount 0.5, centre = depth (6 ms / 1.0).
        let template = |centre| Lfo { period: 1.0, phase: 0.0, amount: 0.5, centre, depth: centre };
        Self {
            delay: Delay::new(0.015, 1),
            eq: PeakingIir2::default(),
            lfo_delay: template(0.006),
            lfo_eq: template(1.0),
            env: Level::new(1.0),
            gain: Gain::default(),
            pan: Pan2D::new(1),
            preset: None,
        }
    }
}

impl FlangeReturn {
    /// `sub_8248FE68`: the LFO records from the preset (periods 1/rate, phase 0).
    pub fn apply(&mut self, p: &FlangePreset) {
        self.preset = Some(*p);
        self.lfo_delay = Lfo { period: 1.0 / p.at(24), phase: 0.0, amount: p.at(28), centre: p.at(20), depth: p.at(20) };
        self.lfo_eq = Lfo { period: 1.0 / p.at(4), phase: 0.0, amount: p.at(8), centre: p.at(16), depth: p.at(16) };
    }

    /// `sub_8248FFF8`: the per-frame levels (Q15 words of the Reverb owner).
    pub fn set_levels(&mut self, gain: i32, env: i32) {
        self.gain.target = gain as f32 * INV_32767;
        self.env.target = env as f32 * INV_32767;
    }

    /// One block: the LFO task's posts, then (when `active`) the graph on `input` (mono), adding
    /// its env send into `env_in` and its panned output into SFX Master.
    pub fn render(&mut self, input: &mut [f32; BLOCK], active: bool, env_in: &mut [f32; BLOCK], master: &mut [[f32; BLOCK]; 6]) {
        self.delay.delay = self.lfo_delay.step();
        self.eq.freq = self.lfo_eq.step();
        if !active {
            return;
        }
        {
            let mut planes: [&mut [f32]; 1] = [&mut input[..]];
            self.delay.process(&mut planes);
            self.eq.process(&mut planes, 48000.0);
        }
        self.env.add(&input[..], &mut env_in[..]);
        {
            let mut planes: [&mut [f32]; 1] = [&mut input[..]];
            self.gain.process(&mut planes);
        }
        let mut six = [[0.0f32; BLOCK]; 6];
        self.pan.process(&[&input[..]], &mut six);
        for (m, s) in master.iter_mut().zip(six.iter()) {
            for (a, b) in m.iter_mut().zip(s.iter()) {
                *a += b;
            }
        }
    }
}

/// Both returns. Disabled (no presets) = no Send B anywhere: renders stay as without the returns.
#[derive(Clone, Debug, Default)]
pub struct FlangeReturns {
    pub returns: [FlangeReturn; 2],
    enabled: bool,
}

impl FlangeReturns {
    /// Load the two presets (A, B) and enable the returns.
    pub fn set_presets(&mut self, a: FlangePreset, b: FlangePreset) {
        self.returns[0].apply(&a);
        self.returns[1].apply(&b);
        self.enabled = true;
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    /// `sub_824DF220` (SFXObj_Reverb's update, after the MixMap tick): the Reverb owner's outputs
    /// 0..3 (A gain, A env send, B gain, B env send).
    pub fn frame(&mut self, reverb: [i32; 4]) {
        self.returns[0].set_levels(reverb[0], reverb[1]);
        self.returns[1].set_levels(reverb[2], reverb[3]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The user's vault values by offset (for the tests only).
    pub(crate) const A: FlangePreset = FlangePreset([20.0, 0.3, 0.2, 0.1, 1500.0, 0.002, 0.5, 0.9, 0.03]);
    pub(crate) const B: FlangePreset = FlangePreset([1.7, 0.3, 0.0, 1.0, 250.0, 0.0005, 0.25, 0.6, 0.11]);

    #[test]
    fn the_delay_sweeps_between_the_preset_bounds_and_the_output_is_centred() {
        let mut fx = FlangeReturns::default();
        fx.set_presets(A, B);
        fx.frame([32692, 2313, 32692, 2313]);
        let (mut lo, mut hi) = (f32::MAX, f32::MIN);
        let mut env_total = 0.0f32;
        let mut energy = [0.0f32; 6];
        for b in 0..400 {
            let mut input = [0.0f32; BLOCK];
            input[0] = if b % 8 == 0 { 1.0 } else { 0.0 };
            let mut env_in = [0.0f32; BLOCK];
            let mut master = [[0.0f32; BLOCK]; 6];
            fx.returns[0].render(&mut input, true, &mut env_in, &mut master);
            lo = lo.min(fx.returns[0].delay.delay);
            hi = hi.max(fx.returns[0].delay.delay);
            env_total += env_in.iter().map(|v| v.abs()).sum::<f32>();
            for (e, ch) in energy.iter_mut().zip(master.iter()) {
                *e += ch.iter().map(|v| v * v).sum::<f32>();
            }
        }
        // 2 ms ± 90 % at 0.5 Hz (400 blocks = 2.1 s covers a whole period).
        assert!((lo - 0.0002).abs() < 2e-5 && (hi - 0.0038).abs() < 2e-5, "{lo} {hi}");
        assert!(env_total > 0.0);
        assert!(energy[1] > 0.0 && energy.iter().enumerate().all(|(i, &e)| i == 1 || e == 0.0), "{energy:?}");
    }

    #[test]
    #[ignore = "needs the private install data"]
    fn the_reverb_owner_gives_the_retail_free_skate_levels() {
        use crate::mixmap::{MixMap, keys};
        let bytes = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../../assets/private/audio/aems/MixMapSK8.mxb"));
        let Ok(bytes) = bytes else { panic!("missing private data: no MixMap") };
        let levels = |in5: i32| {
            let mut m = MixMap::from_bytes(&bytes).unwrap();
            for _ in 0..30 {
                for id in 1..=4 {
                    m.set_input(keys::MASTER, id, 32767);
                }
                for id in [1, 2, 5] {
                    m.set_input(keys::MUSIC, id, 32767);
                }
                m.set_input(keys::REVERB, 5, in5);
                m.tick(1.0 / 60.0);
            }
            (0..5).map(|k| m.level(keys::REVERB, k)).collect::<Vec<i32>>()
        };
        // Retail (all_20261002_163809): return B gain 0.9977 outside pauses, return env sends
        // 0.0706, EnvSub sends = preset × 0.9989 (manager +104 = out4 = 0 mB).
        let out = levels(0);
        assert_eq!(out, vec![32692, 2313, 32692, 2313, 32730]);
        assert!((out[0] as f32 * INV_32767 - 0.9977).abs() < 1e-4 && (out[1] as f32 * INV_32767 - 0.0706).abs() < 1e-4);
        // With Reverb.in5 = 32767 (what the hosts write today, from PR #4's capture statistics)
        // F213 holds out4 at −400 mB: the env scale would be 0.63, which the retail trace rules out.
        assert_eq!(levels(32767)[4], 20603);
    }

    #[test]
    fn an_impulse_comes_back_delayed_by_whole_samples() {
        let mut r = FlangeReturn::default();
        r.apply(&B);
        r.set_levels(32767, 0);
        let mut input = [0.0f32; BLOCK];
        input[0] = 1.0;
        let mut env_in = [0.0f32; BLOCK];
        let mut master = [[0.0f32; BLOCK]; 6];
        r.render(&mut input, true, &mut env_in, &mut master);
        let d = (r.delay.delay * 48000.0).round() as usize;
        assert!((10..=38).contains(&d), "{d}");
        let peak = master[1].iter().position(|&v| v != 0.0).unwrap();
        assert_eq!(peak, d);
        assert!((master[1][d] - 1.0).abs() < 1e-6);
        assert!(env_in.iter().all(|&v| v == 0.0), "env send 0");
    }

    #[test]
    fn an_inactive_return_only_advances_its_sweeps() {
        let mut r = FlangeReturn::default();
        r.apply(&A);
        let before = r.lfo_delay.phase;
        let mut input = [1.0f32; BLOCK];
        let mut env_in = [0.0f32; BLOCK];
        let mut master = [[0.0f32; BLOCK]; 6];
        r.render(&mut input, false, &mut env_in, &mut master);
        assert_ne!(r.lfo_delay.phase, before);
        assert!(master.iter().all(|c| c.iter().all(|&v| v == 0.0)));
        assert!(env_in.iter().all(|&v| v == 0.0));
    }
}
