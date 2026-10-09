//! The GrainPlayer (spec `audio-specs/grain-player-spec.md` §2.1–2.6): two voice slots that
//! play short windows of one long slow-to-fast recording, picked without repeats around a read
//! position, cross-faded with equal-power square-root fades, rescheduled every 256-frame block.
//!
//! - **Pick** (§2.3): target T = (D − W)·position; the free gaps between recently played windows,
//!   clamped to [T, T + W], are tiled with back-to-back windows of the grain length
//!   L = attack + sustain + release; one is drawn uniformly with the title-wide generator and
//!   remembered (16-entry list; it collapses to the last window when it is full or nothing fits).
//! - **Per block** (§2.4): a drift of the read position beyond the threshold releases the current
//!   grain and starts a new one; otherwise each voice runs attack → sustain (timer × pitch) →
//!   release, and the end of a sustain starts the next grain in the other slot.
//! - **Voice** (§2.5–2.6): SndPlayer1 (PCM from frame ⌊rate·start⌋; the first block of a new
//!   player is silent, as in the standard graph) → Resample (rate/48000 × pitch) → GainFader
//!   (square-root fades) → Send (the record gain, 64-sample ramp) into the player's mono bus.
use std::sync::Arc;

use crate::BLOCK;
use crate::dsp::resample::{Resampler, ratio};
use crate::dsp::send::{Mode, Send};
use crate::eval::rng::Rng;
use crate::mixer::Pcm;

/// One block's time as the block driver passes it: f32(256/48000) = `0x3BAEC33E`.
pub const BLOCK_DELTA: f32 = f32::from_bits(0x3BAE_C33E);
/// 2⁻³¹, the pick's scale for the generator's u32 draw.
const TWO_POW_MINUS_31: f32 = f32::from_bits(0x3000_0000);
const RECENT: u16 = 16;
const MAX_CANDIDATES: usize = 64;

/// GrainParams (vault `D18D1174735E5CDE`): seconds of source at pitch 1, the search window and the
/// drift threshold (in position units).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GrainParams {
    pub attack: f32,
    pub sustain: f32,
    pub release: f32,
    pub window: f32,
    pub drift: f32,
}

impl GrainParams {
    pub fn from_slice(v: &[f32]) -> Option<Self> {
        match *v {
            [attack, sustain, release, window, drift, ..] => Some(Self { attack, sustain, release, window, drift }),
            _ => None,
        }
    }

    /// The grain length L, summed as retail does: (sustain + release) + attack.
    pub fn length(&self) -> f32 {
        (self.sustain + self.release) + self.attack
    }
}

/// The per-frame record the game writes (§2.2): send gain, pitch (1 = native), read position 0..1.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Record {
    pub gain: f32,
    pub pitch: f32,
    pub position: f32,
}

impl Default for Record {
    fn default() -> Self {
        Self { gain: 1.0, pitch: 1.0, position: 0.0 }
    }
}

/// A bound recording: the stored duration and mono PCM at its native rate.
#[derive(Clone, Debug)]
pub struct GrainSource {
    pub name: String,
    pub duration: f32,
    pub pcm: Arc<Pcm>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stage {
    Attack,
    Sustain,
    Release,
}

/// What the scheduler did, for tests and traces.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Event {
    Start { slot: usize, start: f32, position: f32 },
    Release { slot: usize },
    Stop { slot: usize },
}

/// The recently played windows: a start-sorted list holding a sentinel (−2, −1) after a reset,
/// and how many windows were inserted since (retail's 16-entry pool hands out entries 1..15).
#[derive(Clone, Debug)]
struct Recent {
    windows: Vec<(f32, f32)>,
    /// Entry 0's window (the sentinel, or the window a collapse kept).
    first: (f32, f32),
    inserted: u16,
    last: (f32, f32),
}

impl Recent {
    fn new() -> Self {
        // Room for the sentinel and every insert before a collapse, so the audio thread's picks never
        // grow it (test `tests/render_alloc.rs`).
        let mut windows = Vec::with_capacity(usize::from(RECENT) + 1);
        windows.push((-2.0, -1.0));
        Self { windows, first: (-2.0, -1.0), inserted: 0, last: (-2.0, -1.0) }
    }

    fn collapse(&mut self) {
        let keep = if self.inserted == 0 { self.first } else { self.last };
        // In place (no new allocation): the same single-entry list.
        self.windows.clear();
        self.windows.push(keep);
        (self.first, self.inserted) = (keep, 0);
    }

    fn insert(&mut self, w: (f32, f32)) {
        let at = self.windows.iter().position(|e| !(e.0 < w.0)).unwrap_or(self.windows.len());
        self.windows.insert(at, w);
        self.inserted += 1;
        self.last = w;
    }
}

/// Tile the free interval [lo, hi], clamped to [low, high], with back-to-back windows of `len`
/// while a whole window still fits (single precision), at most 64 in all.
fn candidates(out: &mut Vec<(f32, f32)>, lo: f32, hi: f32, len: f32, low: f32, high: f32) {
    if hi < low || lo > high {
        return;
    }
    let mut lo = if lo >= low { lo } else { low };
    let hi = if hi <= high { hi } else { high };
    if hi - lo < len {
        return;
    }
    loop {
        out.push((lo, lo + len));
        lo += len;
        if hi - lo < len || lo + len > high || out.len() >= MAX_CANDIDATES {
            return;
        }
    }
}

/// The equal-power fader (GaF0 with curve 1): g = from + (to − from)·√(n/N) rising,
/// to + (from − to)·√(1 − n/N) falling; N = max(1, ⌊seconds·48000⌋) samples.
#[derive(Clone, Debug)]
struct Fader {
    gain: f32,
    from: f32,
    to: f32,
    n: u32,
    total: u32,
}

impl Fader {
    fn new() -> Self {
        Self { gain: 1.0, from: 1.0, to: 1.0, n: 0, total: 0 }
    }

    fn fade(&mut self, to: f32, seconds: f32) {
        let total = ((seconds * crate::MIX_RATE as f32) as i64).max(1) as u32;
        (self.from, self.to, self.n, self.total) = (self.gain, to, 0, total);
    }

    fn apply(&mut self, x: &mut [f32]) {
        for s in x.iter_mut() {
            if self.total > 0 {
                let f = self.n as f32 / self.total as f32;
                self.gain = if self.to >= self.from {
                    self.from + (self.to - self.from) * f.sqrt()
                } else {
                    self.to + (self.from - self.to) * (1.0 - f).sqrt()
                };
                self.n += 1;
                if self.n >= self.total {
                    self.total = 0;
                    self.gain = self.to;
                }
            }
            *s *= self.gain;
        }
    }
}

#[derive(Clone, Debug)]
struct Voice {
    pcm: Arc<Pcm>,
    resampler: Resampler,
    started: bool,
    fader: Fader,
    send: Send,
}

impl Voice {
    fn new(pcm: Arc<Pcm>, start: f32, gain: f32) -> Self {
        let frame = (f64::from(pcm.rate) * f64::from(start)).floor().max(0.0) as u64;
        let mut fader = Fader::new();
        fader.gain = 0.0;
        let mut send = Send::default();
        send.target = gain;
        let mut resampler = Resampler::default();
        resampler.position = frame;
        Self { pcm, resampler, started: false, fader, send }
    }

    fn render(&mut self, pitch: f32, gain: f32, bus: &mut [[f32; BLOCK]; 6]) {
        let mut buf = [0.0f32; BLOCK];
        if self.started {
            self.resampler.set_ratio(ratio(self.pcm.rate, pitch));
            let data = self.pcm.channels.first().map_or(&[][..], |c| &c[..]);
            self.resampler.render(&mut buf, |i| data.get(i as usize).copied().unwrap_or(0.0));
            self.resampler.advance(BLOCK);
        }
        self.started = true;
        self.fader.apply(&mut buf);
        self.send.target = gain;
        self.send.process(&[&buf], &[(0, 0, 1.0)], bus, Mode::Normal);
    }
}

#[derive(Clone, Debug)]
struct Slot {
    voice: Option<Voice>,
    timer: f32,
    start: f32,
    picked_at: f32,
    stage: Stage,
}

impl Slot {
    fn new() -> Self {
        Self { voice: None, timer: 0.0, start: 0.0, picked_at: 0.0, stage: Stage::Attack }
    }
}

#[derive(Clone, Debug)]
pub struct GrainPlayer {
    pub params: GrainParams,
    pub record: Record,
    source: Option<Arc<GrainSource>>,
    slots: [Slot; 2],
    active: usize,
    recent: Recent,
    /// Scratch candidate list of [`GrainPlayer::pick`] (kept for its capacity only).
    found: Vec<(f32, f32)>,
    /// Retail's hold flag (+36): cleared on bind, no known writer (spec §2.4).
    pub hold: bool,
    /// Release de-click of voices torn down since the last render (bus channel 0).
    fold: f32,
    /// Scheduler events since the last [`GrainPlayer::take_events`] (kept only when `trace`).
    pub trace: bool,
    events: Vec<Event>,
    /// Voices started since construction.
    pub starts: u64,
}

impl Default for GrainPlayer {
    fn default() -> Self {
        Self::new()
    }
}

impl GrainPlayer {
    pub fn new() -> Self {
        Self {
            // Constructor defaults (always overwritten on bind).
            params: GrainParams { attack: 0.01, sustain: 0.5, release: 0.01, window: 4.0, drift: 0.05 },
            record: Record::default(),
            source: None,
            slots: [Slot::new(), Slot::new()],
            active: 0,
            recent: Recent::new(),
            found: Vec::with_capacity(MAX_CANDIDATES),
            hold: false,
            fold: 0.0,
            trace: false,
            events: Vec::new(),
            starts: 0,
        }
    }

    pub fn bound(&self) -> Option<&GrainSource> {
        self.source.as_deref()
    }

    /// A torn-down voice's release de-click is still to be rendered.
    pub fn pending(&self) -> bool {
        self.fold != 0.0
    }

    pub fn voices(&self) -> usize {
        self.slots.iter().filter(|s| s.voice.is_some()).count()
    }

    pub fn take_events(&mut self) -> Vec<Event> {
        std::mem::take(&mut self.events)
    }

    fn log(&mut self, e: Event) {
        if self.trace {
            self.events.push(e);
        }
    }

    /// Bind a recording (§2.5): reset the recent list, take the params, pick and start a voice in
    /// slot 0 at once. The record should already hold this frame's values.
    pub fn bind(&mut self, source: Arc<GrainSource>, params: GrainParams, rng: &mut Rng) {
        self.stop();
        self.recent = Recent::new();
        self.active = 0;
        self.hold = false;
        self.params = params;
        self.source = Some(source);
        let start = self.pick(rng);
        self.start_voice(0, start);
    }

    /// Stop both voices without a release fade and unbind (§2.5 "stop the player").
    pub fn stop(&mut self) {
        if self.source.is_none() {
            return;
        }
        for i in 0..2 {
            self.stop_voice(i);
        }
        self.source = None;
    }

    fn stop_voice(&mut self, i: usize) {
        if let Some(v) = self.slots[i].voice.take() {
            self.fold += v.send.last[0];
            self.log(Event::Stop { slot: i });
        }
    }

    fn release(&mut self, i: usize) {
        let release = self.params.release;
        let s = &mut self.slots[i];
        s.timer = release;
        s.stage = Stage::Release;
        if let Some(v) = &mut s.voice {
            v.fader.fade(0.0, release);
        }
        self.log(Event::Release { slot: i });
    }

    fn start_voice(&mut self, i: usize, start: f32) {
        let Some(source) = self.source.clone() else { return };
        let at = if !(start >= 0.0) { 0.0 } else if !(start <= source.duration) { source.duration } else { start };
        let mut voice = Voice::new(source.pcm.clone(), at, self.record.gain);
        voice.fader.fade(1.0, self.params.attack);
        self.stop_voice(i);
        let position = self.record.position;
        self.slots[i] = Slot { voice: Some(voice), timer: self.params.attack, start: at, picked_at: position, stage: Stage::Attack };
        self.starts += 1;
        self.log(Event::Start { slot: i, start: at, position });
    }

    /// The next grain's start time (§2.3).
    pub fn pick(&mut self, rng: &mut Rng) -> f32 {
        let duration = self.source.as_ref().map_or(0.0, |s| s.duration);
        self.pick_in(duration, rng)
    }

    fn pick_in(&mut self, duration: f32, rng: &mut Rng) -> f32 {
        // The candidate list is a buffer kept by the player (cleared per attempt), not a new `Vec`
        // per pick: the audio thread must not allocate (test `tests/render_alloc.rs`).
        let mut found = std::mem::take(&mut self.found);
        let start = self.pick_from(&mut found, duration, rng);
        self.found = found;
        start
    }

    fn pick_from(&mut self, found: &mut Vec<(f32, f32)>, duration: f32, rng: &mut Rng) -> f32 {
        let p = self.params;
        let len = p.length();
        let target = (duration - p.window) * self.record.position;
        let fits = crate::mixmap::tables::trunc(p.window / len);
        let end = p.window + target;
        // A collapse leaves one window; retry at most a few times (retail retries until a window
        // fits, which cannot loop for a region of ≥ 2 windows unless one sits in its middle).
        for _ in 0..4 {
            found.clear();
            let head = self.recent.windows[0];
            if !(target >= head.0) {
                candidates(found, target, head.0, len, target, end);
            }
            for k in 0..self.recent.windows.len() {
                let lo = self.recent.windows[k].1;
                let hi = self.recent.windows.get(k + 1).map_or(duration, |w| w.0);
                if found.len() < MAX_CANDIDATES {
                    candidates(found, lo, hi, len, target, end);
                }
            }
            if found.is_empty() || self.recent.inserted == RECENT - 1 {
                self.recent.collapse();
                if fits > 1 {
                    continue;
                }
                return target;
            }
            let r = rng.draw();
            let index = crate::mixmap::tables::trunc(((r as f32 * TWO_POW_MINUS_31) * 0.5) * found.len() as f32);
            // r within 128 of 2³² rounds the index to the count: retail reads an unfilled record.
            let w = usize::try_from(index).ok().and_then(|i| found.get(i).copied()).unwrap_or((-1.0, -1.0));
            self.recent.insert(w);
            return w.0;
        }
        target
    }

    /// The per-block scheduler (§2.4), `delta` seconds since the last block.
    pub fn tick(&mut self, delta: f32, rng: &mut Rng) {
        if self.source.is_none() {
            return;
        }
        let a = self.active;
        let drift = self.slots[a].picked_at - self.record.position;
        let threshold = self.params.drift;
        if (drift > threshold || !(drift >= -threshold)) && !self.hold && self.slots[a].voice.is_some() {
            let o = 1 - a;
            if self.slots[o].voice.is_some() {
                if self.slots[o].stage != Stage::Release {
                    self.release(o);
                }
            } else {
                if self.slots[a].stage != Stage::Release {
                    self.release(a);
                }
                let start = self.pick(rng);
                self.start_voice(o, start);
                self.active = o;
            }
        }
        for i in 0..2 {
            if self.slots[i].voice.is_none() {
                continue;
            }
            let pitch = self.record.pitch;
            let sustain = self.params.sustain;
            let s = &mut self.slots[i];
            s.timer = if s.stage == Stage::Sustain { (-delta).mul_add(pitch, s.timer) } else { s.timer - delta };
            if s.timer >= 0.0 {
                continue;
            }
            match s.stage {
                Stage::Attack => {
                    s.stage = Stage::Sustain;
                    s.timer = sustain;
                }
                Stage::Sustain => {
                    self.release(i);
                    if !self.hold {
                        let o = 1 - i;
                        self.stop_voice(o);
                        let start = self.pick(rng);
                        self.start_voice(o, start);
                        self.active = o;
                    }
                }
                Stage::Release => self.stop_voice(i),
            }
        }
    }

    /// Render this block's voices into the player's mono bus (channel 0 of `bus`, added).
    pub fn render(&mut self, bus: &mut [[f32; BLOCK]; 6]) {
        if self.fold != 0.0 {
            crate::dsp::send::fold_release(bus, &[self.fold, 0.0, 0.0, 0.0, 0.0, 0.0]);
            self.fold = 0.0;
        }
        let (gain, pitch) = (self.record.gain, self.record.pitch);
        for s in &mut self.slots {
            if let Some(v) = &mut s.voice {
                v.render(pitch, gain, bus);
            }
        }
    }

    /// Slot state for tests: (has voice, stage, timer, start).
    pub fn slot(&self, i: usize) -> (bool, Stage, f32, f32) {
        let s = &self.slots[i];
        (s.voice.is_some(), s.stage, s.timer, s.start)
    }

    pub fn active(&self) -> usize {
        self.active
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: GrainParams = GrainParams { attack: 0.1, sustain: 0.2, release: 0.1, window: 1.6, drift: 0.05 };
    const B: GrainParams = GrainParams { attack: 0.2, sustain: 0.1, release: 0.2, window: 1.5, drift: 0.05 };
    /// concrete_rough_hard's stored duration.
    const DURATION: f32 = f32::from_bits(0x41AE_BC39);
    const IMAGE_SEED: [u32; 6] = [0xF22D_0E56, 0x8831_26E9, 0xC624_DD2F, 0x0702_C49C, 0x9E35_3F7D, 0x6FDF_3B64];

    fn picks(params: GrainParams, position: f32, seed: [u32; 6]) -> Vec<String> {
        let mut p = GrainPlayer::new();
        p.params = params;
        p.record.position = position;
        let mut rng = Rng::new(seed);
        (0..24).map(|_| format!("{:.4}", p.pick_in(DURATION, &mut rng))).collect()
    }

    /// The PoC's golden pick sequences (the PoC's golden vectors, kept locally; PR #4's ported
    /// pick driven from the zero and the image generator state).
    #[test]
    fn picks_match_the_golden_vectors() {
        let golden: &[(&str, f32, &str, &str)] = &[
            ("A", 0.0, "zero", "0.0000 0.4000 0.8000 0.0000 0.4000 0.0000 0.8000 0.0000 0.4000 0.0000 0.8000 0.0000 0.4000 0.0000 0.8000 0.0000 0.4000 0.0000 0.8000 0.0000 0.4000 0.0000 0.8000 0.0000"),
            ("A", 0.0, "image", "0.4000 0.0000 0.8000 0.0000 0.4000 0.8000 0.0000 0.4000 0.8000 0.4000 0.0000 0.4000 0.8000 0.0000 0.4000 0.8000 0.0000 0.8000 0.4000 0.8000 0.0000 0.4000 0.8000 0.0000"),
            ("A", 0.25, "zero", "5.0605 5.4605 5.8605 5.0605 5.4605 5.0605 5.8605 5.0605 5.4605 5.0605 5.8605 5.0605 5.4605 5.0605 5.8605 5.0605 5.4605 5.0605 5.8605 5.0605 5.4605 5.0605 5.8605 5.0605"),
            ("A", 0.25, "image", "5.4605 5.0605 5.8605 5.0605 5.4605 5.8605 5.0605 5.4605 5.8605 5.4605 5.0605 5.4605 5.8605 5.0605 5.4605 5.8605 5.0605 5.8605 5.4605 5.8605 5.0605 5.4605 5.8605 5.0605"),
            ("A", 0.63, "zero", "12.7524 13.1524 13.5524 13.9524 12.7524 13.1524 13.5524 13.9524 12.7524 13.1524 13.5524 13.9524 12.7524 13.1524 13.5524 13.9524 12.7524 13.1524 13.5524 13.9524 12.7524 13.1524 13.5524 13.9524"),
            ("A", 0.63, "image", "13.1524 13.5524 13.9524 12.7524 13.1524 13.9524 12.7524 13.1524 13.5524 13.9524 13.1524 13.5524 13.9524 12.7524 13.1524 13.9524 13.1524 13.9524 13.1524 13.9524 12.7524 13.1524 13.9524 12.7524"),
            ("A", 1.0, "zero", "20.2419 20.6419 21.0419 21.4419 20.2419 20.6419 21.0419 21.4419 20.2419 20.6419 21.0419 21.4419 20.2419 20.6419 21.0419 21.4419 20.2419 20.6419 21.0419 21.4419 20.2419 20.6419 21.0419 21.4419"),
            ("A", 1.0, "image", "20.6419 21.0419 21.4419 20.2419 20.6419 21.4419 20.2419 20.6419 21.0419 21.4419 20.6419 21.0419 21.4419 20.2419 20.6419 21.4419 20.6419 21.4419 20.6419 21.4419 20.2419 20.6419 21.4419 20.2419"),
            ("B", 0.0, "zero", "0.0000 0.5000 1.0000 0.0000 0.5000 0.0000 1.0000 0.0000 0.5000 0.0000 1.0000 0.0000 0.5000 0.0000 1.0000 0.0000 0.5000 0.0000 1.0000 0.0000 0.5000 0.0000 1.0000 0.0000"),
            ("B", 0.0, "image", "0.5000 0.0000 1.0000 0.0000 0.5000 1.0000 0.0000 0.5000 1.0000 0.5000 0.0000 0.5000 1.0000 0.0000 0.5000 1.0000 0.0000 1.0000 0.5000 1.0000 0.0000 0.5000 1.0000 0.0000"),
            ("B", 0.25, "zero", "5.0855 5.5855 6.0855 5.0855 5.5855 5.0855 6.0855 5.0855 5.5855 5.0855 6.0855 5.0855 5.5855 5.0855 6.0855 5.0855 5.5855 5.0855 6.0855 5.0855 5.5855 5.0855 6.0855 5.0855"),
            ("B", 0.25, "image", "5.5855 5.0855 6.0855 5.0855 5.5855 6.0855 5.0855 5.5855 6.0855 5.5855 5.0855 5.5855 6.0855 5.0855 5.5855 6.0855 5.0855 6.0855 5.5855 6.0855 5.0855 5.5855 6.0855 5.0855"),
            ("B", 0.63, "zero", "12.8154 13.3154 13.8154 12.8154 13.3154 12.8154 13.8154 12.8154 13.3154 12.8154 13.8154 12.8154 13.3154 12.8154 13.8154 12.8154 13.3154 12.8154 13.8154 12.8154 13.3154 12.8154 13.8154 12.8154"),
            ("B", 0.63, "image", "13.3154 12.8154 13.8154 12.8154 13.3154 13.8154 12.8154 13.3154 13.8154 13.3154 12.8154 13.3154 13.8154 12.8154 13.3154 13.8154 12.8154 13.8154 13.3154 13.8154 12.8154 13.3154 13.8154 12.8154"),
            ("B", 1.0, "zero", "20.3419 20.8419 21.3419 20.3419 20.8419 20.3419 21.3419 20.3419 20.8419 20.3419 21.3419 20.3419 20.8419 20.3419 21.3419 20.3419 20.8419 20.3419 21.3419 20.3419 20.8419 20.3419 21.3419 20.3419"),
            ("B", 1.0, "image", "20.8419 20.3419 21.3419 20.3419 20.8419 21.3419 20.3419 20.8419 21.3419 20.8419 20.3419 20.8419 21.3419 20.3419 20.8419 21.3419 20.3419 21.3419 20.8419 21.3419 20.3419 20.8419 21.3419 20.3419"),
        ];
        for &(which, pos, seed, want) in golden {
            let params = if which == "A" { A } else { B };
            let got = picks(params, pos, if seed == "zero" { [0; 6] } else { IMAGE_SEED }).join(" ");
            assert_eq!(got, want, "{which} pos {pos} seed {seed}");
        }
    }

    /// The golden candidate tilings (CAND rows): 3 windows of 0.4 in [0, 1.6] (the 4th rounds out),
    /// 3 of 0.5 in [5, 6.5], 4 of 0.4 in [19, 20.6].
    #[test]
    fn candidate_tiling_matches_the_golden_vectors() {
        for (t, w, len, want) in [(0.0f32, 1.6f32, 0.4f32, vec![0.0, 0.4, 0.8]), (5.0, 1.5, 0.5, vec![5.0, 5.5, 6.0]), (19.0, 1.6, 0.4, vec![19.0, 19.4, 19.8, 20.2])] {
            let mut out = Vec::new();
            candidates(&mut out, -1.0, 21.84, len, t, t + w);
            let got: Vec<String> = out.iter().map(|c| format!("{:.4}", c.0)).collect();
            let want: Vec<String> = want.iter().map(|c| format!("{c:.4}")).collect();
            assert_eq!(got, want);
        }
    }

    fn source(seconds: f32) -> Arc<GrainSource> {
        let rate = 48000;
        let n = (seconds * rate as f32) as usize;
        let data = (0..n).map(|i| ((i as f32) * 0.01).sin() * 0.5).collect();
        Arc::new(GrainSource { name: "test".into(), duration: n as f32 / rate as f32, pcm: Arc::new(Pcm { rate, channels: vec![data] }) })
    }

    /// At pitch 1 and a fixed position, player A starts a grain every 0.1 + 0.2 s (quantised up to
    /// blocks) and never runs more than two voices; B every 0.2 + 0.1 s (§2.4 table).
    #[test]
    fn steady_rhythm_and_two_voices_at_most() {
        for (params, period) in [(A, 0.3f32), (B, 0.3)] {
            let mut p = GrainPlayer::new();
            p.trace = true;
            p.record.position = 0.4;
            let mut rng = Rng::new(IMAGE_SEED);
            p.bind(source(20.0), params, &mut rng);
            let mut starts = Vec::new();
            let mut bus = [[0.0f32; BLOCK]; 6];
            for block in 0..2000 {
                p.tick(BLOCK_DELTA, &mut rng);
                p.render(&mut bus);
                assert!(p.voices() <= 2);
                for e in p.take_events() {
                    if let Event::Start { start, .. } = e {
                        starts.push((block, start));
                    }
                }
            }
            let gaps: Vec<i32> = starts.windows(2).map(|w| w[1].0 - w[0].0).collect();
            let expect = (period / BLOCK_DELTA).ceil() as i32;
            assert!(gaps[1..].iter().all(|&g| (expect - 1..=expect + 1).contains(&g)), "{gaps:?} vs {expect}");
            // Starts stay inside the search region [T, T + W].
            let t = (20.0 - params.window) * 0.4;
            assert!(starts.iter().all(|&(_, s)| s >= t - 1e-3 && s <= t + params.window));
        }
    }

    /// A position jump beyond the drift threshold releases the grain and starts one in the
    /// other slot at once.
    #[test]
    fn drift_cuts_the_grain() {
        let mut p = GrainPlayer::new();
        p.trace = true;
        p.record.position = 0.1;
        let mut rng = Rng::new(IMAGE_SEED);
        p.bind(source(20.0), A, &mut rng);
        p.take_events();
        p.tick(BLOCK_DELTA, &mut rng);
        assert!(p.take_events().is_empty());
        p.record.position = 0.5;
        p.tick(BLOCK_DELTA, &mut rng);
        let events = p.take_events();
        assert_eq!(events[0], Event::Release { slot: 0 });
        assert!(matches!(events[1], Event::Start { slot: 1, position, .. } if position == 0.5));
        assert_eq!(p.active(), 1);
    }

    /// Release and next attack overlap with square-root fades: g_in² + g_out² = 1.
    #[test]
    fn fades_are_equal_power() {
        let mut a = Fader::new();
        a.gain = 0.0;
        a.fade(1.0, 0.1);
        let mut b = Fader::new();
        b.fade(0.0, 0.1);
        let mut x = [1.0f32; BLOCK];
        let mut y = [1.0f32; BLOCK];
        a.apply(&mut x);
        b.apply(&mut y);
        for (gi, go) in x.iter().zip(y.iter()) {
            assert!((gi * gi + go * go - 1.0).abs() < 1e-5);
        }
    }
}
