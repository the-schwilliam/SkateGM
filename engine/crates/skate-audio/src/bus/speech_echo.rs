//! The speech stream slots' echo submixes (`sub_82C5E2D8`, built once per stream slot; parameters
//! posted every frame by `sub_82C5CEF0`; spec `audio-specs/world-speech.md` "Speech details
//! resolved"): `Sub0 → HI20 → Del0 → LI20 → Pn21 → Sen0 (→ the environment bus)`.
//!
//! The slot's speech voice feeds Sub0 through its pre-gain Send (the owner's level 21 for a ped,
//! 13 for a skater, × the voice's float). Per frame the stream system posts HI20 = the owner's
//! filter 22 (skater 14), LI20 = filter 23 (skater 15) and, when it changed, Del0's delay = the
//! camera distance × the speech record's factor / 344 m/s, at most 0.15 s. Pn21 and Sen0 keep their
//! class defaults (azimuth 0, level 1.0).
//!
//! Modelled mono: the graph's two channels carry the one mono speech signal and the env bus input
//! is mono, so the Pn21 → Sen0 path is a unity tap (the two-channel routing's exact gains are not
//! traced). The graph keeps its filter history and delay line between lines, as retail's persists.
use super::env::Level;
use crate::dsp::biquad::{Iir2, Kind};
use crate::dsp::delay::Delay;
use crate::{BLOCK, MIX_RATE};

/// Echo slots: retail builds one per stream slot (3 speech channels × 2 streams).
pub const SLOTS: usize = 8;
/// Del0's line length (s): the delay is posted at most 0.15 s (`0x820964B4`).
pub const MAX_DELAY: f32 = 0.15;

#[derive(Clone, Debug)]
pub struct SpeechEcho {
    /// Sub0: the voices' sends add here (mono).
    pub input: Box<[f32; BLOCK]>,
    hpf: Iir2,
    delay: Delay,
    lpf: Iir2,
    env: Level,
    /// Something was sent into it since it was built (the graph renders from then on).
    active: bool,
}

impl Default for SpeechEcho {
    fn default() -> Self {
        Self {
            input: Box::new([0.0; BLOCK]),
            hpf: Iir2::new(Kind::HighPass),
            delay: Delay::new(MAX_DELAY, 1),
            lpf: Iir2::new(Kind::LowPass),
            env: Level::running(1.0),
            active: false,
        }
    }
}

/// What the stream system posts to a slot's echo each frame.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct EchoParams {
    pub high_pass: f32,
    pub low_pass: f32,
    /// Del0 (s); None = unchanged since the last post.
    pub delay: Option<f32>,
}

impl SpeechEcho {
    pub fn set(&mut self, p: &EchoParams) {
        self.hpf.cutoff = p.high_pass;
        self.lpf.cutoff = p.low_pass;
        if let Some(d) = p.delay {
            self.delay.delay = d.min(MAX_DELAY);
        }
        self.active = true;
    }

    fn render(&mut self, env_in: &mut [f32; BLOCK]) {
        if !self.active {
            return;
        }
        let mut mono = *self.input;
        self.input.fill(0.0);
        {
            let mut planes: [&mut [f32]; 1] = [&mut mono[..]];
            self.hpf.process(&mut planes, MIX_RATE as f32);
            self.delay.process(&mut planes);
            self.lpf.process(&mut planes, MIX_RATE as f32);
        }
        self.env.add(&mono, &mut env_in[..]);
    }
}

/// The slots' graphs.
#[derive(Clone, Debug, Default)]
pub struct SpeechEchoes {
    pub slots: Vec<SpeechEcho>,
}

impl SpeechEchoes {
    pub fn slot(&mut self, i: usize) -> Option<&mut SpeechEcho> {
        if i >= SLOTS {
            return None;
        }
        if self.slots.len() < SLOTS {
            self.slots.resize_with(SLOTS, SpeechEcho::default);
        }
        self.slots.get_mut(i)
    }

    pub fn render(&mut self, env_in: &mut [f32; BLOCK]) {
        for s in self.slots.iter_mut() {
            s.render(env_in);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_echo_delays_and_filters_its_input_into_the_env_bus() {
        let mut e = SpeechEchoes::default();
        let s = e.slot(1).unwrap();
        s.set(&EchoParams { high_pass: 0.0, low_pass: 96_000.0, delay: Some(0.01) });
        s.input[0] = 1.0;
        let mut out = Vec::new();
        for _ in 0..4 {
            let mut env = [0.0f32; BLOCK];
            e.render(&mut env);
            out.extend_from_slice(&env);
        }
        // The impulse comes out 480 samples (10 ms) later.
        let at = out.iter().position(|v| v.abs() > 0.5).unwrap();
        assert_eq!(at, 480);
        assert!(e.slot(7).is_some());
        assert!(e.slot(8).is_none());
        // A capped delay.
        e.slot(0).unwrap().set(&EchoParams { delay: Some(1.0), ..Default::default() });
        assert_eq!(e.slots[0].delay.delay, MAX_DELAY);
    }
}
