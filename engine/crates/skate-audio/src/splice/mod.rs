//! The Splice one-shot player for the `SPLC` banks (`Skate_Collisions.bnk`, `sk8_foley.bnk`,
//! `Skate_Metal.bnk` …): retail's per-sound records of layered, randomised sample members, played
//! by gameplay owners (the board's contacts, the collision manager, the off-board foley) with a
//! 6-float block they rewrite every frame.
//!
//! Written from our reading of the retail code (TU3; reference only, addresses are facts):
//! - `sub_82975700` start: bank index, sound id → record (ids below the record count), container
//!   (`id − records`, one record picked by [`pick`]) or, past both, the last record;
//! - `sub_829757D0` voices: one per group of the record, member by [`pick`], skipped unless
//!   `U × 1/32768 ≤ member +64` (probability); `sub_82975A60`: the container pitch factor
//!   `record +12 + U·record +16`, then per voice `sub_82975CC8`: gain spread `+44`, pitch
//!   `+8 + U·+48`, delay `+20 + U·+52`;
//! - `sub_82975B08` per frame: block[0] × record `+8`, block[1] × the pitch factor, each voice
//!   `sub_82976860`: delay countdown, start (`sub_82976360`: elapsed = `+24`, seek
//!   `+8/+12 × +24` s), then pitch = factor·block[1], gain = `+4` × spread × block[0] × fade
//!   (`sub_82976CF0` / `sub_82976FF0`, fade-in `+24 → +32`, fade-out `+36 → +28`, curve byte `+40`),
//!   azimuth = block[2] + `+16` × block[4] (no panner when `+16` = −127), the elapsed clock
//!   advancing by the previous frame's block[1] × dt, stop once elapsed > `+8 / pitch × +28 + 0.16`
//!   or the sample ended.
//!
//! Block (what the owners pass, `sub_824BE1B8`): [0] gain (level / 32767), [1] pitch ratio
//! (pitch / 4096), [2] azimuth (degrees, raw × 360/65535), [3] dt (s), [4] pan spread (1 for the
//! local player's 3-D voices, else 0), [5] second rate factor (1).
//!
//! Not modelled (values not recovered or not used by any disc member): the per-voice output route
//! (`member +3`, the owner's bus objects `sub_82488DD0` with their eEQChain preset and level — the
//! voices mix dry into the default bus), the second rate stage (`member +12` is 1.0 on every member
//! and owners pass block[5] = 1), the no-resample path (`member +68` is 0 everywhere), and the
//! exact rounding of retail's cosine polynomial in the fade curves.
pub mod format;

use std::sync::Arc;

use crate::mixer::{Mixer, Pcm};
pub use format::{Member, SpliceBank};

/// The CRT `rand()` retail's Splice code calls (`sub_82F4EAF0`): the MS LCG, 15-bit results.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CrtRand(pub u32);

impl Default for CrtRand {
    fn default() -> Self {
        Self(1)
    }
}

impl CrtRand {
    pub fn next(&mut self) -> u32 {
        self.0 = self.0.wrapping_mul(214_013).wrapping_add(2_531_011);
        (self.0 >> 16) & 0x7FFF
    }
    /// `rand() × 1/32768` as retail computes it (int → double → single, × f32 2⁻¹⁵).
    pub fn unit(&mut self) -> f32 {
        (self.next() as f64) as f32 * f32::from_bits(0x3800_0000)
    }
}

/// `sub_82976DD8`: pick an index of `count` items with `mode` (0 random, 2 shuffled halves, else
/// sequential) and the item's state word.
pub fn pick(count: u8, mode: u8, state: &mut u32, rng: &mut CrtRand) -> u8 {
    let count = u32::from(count);
    if count == 1 {
        return 0;
    }
    match mode {
        // trunc((rand() × 2⁻¹⁵) × count), single precision.
        0 => trunc(rng.unit() * count as f32) as u8,
        2 => shuffle(count, state, rng),
        _ => {
            if count == 0 {
                return 0;
            }
            let next = ((*state as i32).wrapping_add(1) as u32 % count) as u32;
            *state = next;
            next as u8
        }
    }
}

fn trunc(x: f32) -> i32 {
    if x.is_nan() { 0 } else { x as i32 }
}

/// Mode 2: the state's high half is the bitmask of the current half's unplayed items, bit 0 the
/// half (0: items 0..count/2, 1: the rest). A draw starts the search at a random offset; an
/// exhausted half refills the other one (mask 2^size − 1).
fn shuffle(count: u32, state: &mut u32, rng: &mut CrtRand) -> u8 {
    let parity = *state & 1;
    let mask = *state >> 16;
    let half = count >> 1;
    let size = half + u32::from(parity != 0 && count & 1 != 0);
    let r = rng.next();
    let start = trunc((r as f64) as f32 * f32::from_bits(0x3800_0000) * (size + 1) as f32) as u32;
    if size == 0 {
        return 0;
    }
    for k in 0..size {
        let idx = (k + start) % size;
        let bit = 1u32 << idx;
        if bit & mask != 0 {
            let index = parity * half + idx;
            let mut rest = mask & !bit;
            let mut p = parity;
            if rest == 0 {
                p = u32::from(parity == 0);
                let other = half + u32::from(p != 0 && count & 1 != 0);
                rest = (2f64.powi(other as i32) as f32 as i64 - 1) as u32;
            }
            *state = (rest << 16) | u32::from(p != 0);
            return index as u8;
        }
    }
    0
}

/// `sub_82976FF0`: the fade curve of a member (`+40` & 15) at x ∈ [0, 1].
pub fn curve(kind: u8, x: f32) -> f32 {
    let x = x.clamp(0.0, 1.0);
    let k = f32::from_bits(0x3FC9_0FD0); // π/2 as stored
    match kind {
        0 => 1.0 - (x * k).cos(),
        1 => {
            let v = 1.0 - (x * k).cos();
            v * v
        }
        2 => x,
        3 => ((x - 1.0) * k).cos(),
        4 => {
            let v = ((x - 1.0) * k).cos();
            v * v
        }
        _ => x,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    /// Waiting for its delay (`+76` = 1).
    Delay,
    /// Playing (`+76` = 3).
    Playing,
    /// Stopped (`+76` = 4).
    Done,
}

#[derive(Clone, Debug)]
struct Voice {
    member: Member,
    state: State,
    /// `+64` pitch factor, `+68` gain spread, `+72` last block[1], `+80` delay, `+84` elapsed.
    pitch: f32,
    spread: f32,
    last_rate: f32,
    delay: f32,
    elapsed: f32,
    mixer: Option<u32>,
}

/// One started sound (`sub_82975700`'s 92-byte object).
#[derive(Clone, Debug)]
pub struct Sound {
    bank: usize,
    record: usize,
    /// `+88`: the container pitch factor.
    factor: f32,
    voices: Vec<Option<Voice>>,
    /// The bus its voices play into (the poster's route when it started).
    route: crate::bus::Route,
}

/// A loaded bank: its patch tree (with the live pick states) and the mixer bank its samples sit in.
pub struct LoadedBank {
    pub name: String,
    pub bank: SpliceBank,
    mixer_bank: usize,
}

/// Mixer bank ids the Splice banks use (above any evaluator bank id).
pub const MIXER_BANK_BASE: usize = 1 << 20;

#[derive(Default)]
pub struct SplicePlayer {
    pub banks: Vec<LoadedBank>,
    sounds: Vec<Option<Sound>>,
    pub rng: CrtRand,
    /// Voices started (diagnostics).
    pub started: u64,
    /// The route the next [`SplicePlayer::start`] uses (the poster sets it: its eEQChain bus and
    /// owner bus env send); SFX Master by default.
    pub route: crate::bus::Route,
}

pub type SoundId = usize;

impl SplicePlayer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Install a bank and its decoded samples (sample index n = the bank's n-th stream). Returns
    /// the bank index used by [`SplicePlayer::start`]. The samples are decoded before any start, so
    /// the first trigger of a sample sounds exactly like the later ones.
    pub fn load_bank(&mut self, name: &str, bank: SpliceBank, pcm: Vec<Option<Arc<Pcm>>>, mixer: &mut Mixer) -> usize {
        if let Some(i) = self.banks.iter().position(|b| b.name == name) {
            return i;
        }
        let index = self.banks.len();
        let mixer_bank = MIXER_BANK_BASE + index;
        let headers = pcm
            .iter()
            .map(|p| {
                p.as_ref().map(|p| crate::formats::SampleHeader {
                    codec: 3,
                    channels: p.channels.len() as u8,
                    rate: p.rate,
                    frames: p.channels.first().map_or(0, |c| c.len() as u32),
                    loop_start: None,
                })
            })
            .collect();
        mixer.add_bank(mixer_bank, headers, pcm);
        mixer.set_bank_group(mixer_bank, crate::mixer::GROUP_PLAYER);
        self.banks.push(LoadedBank { name: name.to_owned(), bank, mixer_bank });
        index
    }

    /// Replace a loaded bank's patch tree and samples in place (an audio content hot swap): its
    /// sounding sounds stop (their owners' later updates find nothing, as after a release), the
    /// bank keeps its index and mixer bank. None when the bank is not loaded (it loads on use).
    pub fn replace_bank(&mut self, name: &str, bank: SpliceBank, pcm: Vec<Option<Arc<Pcm>>>, mixer: &mut Mixer) -> Option<usize> {
        let index = self.banks.iter().position(|b| b.name == name)?;
        for id in 0..self.sounds.len() {
            if self.sounds[id].as_ref().is_some_and(|s| s.bank == index) {
                self.release(id, mixer);
            }
        }
        let headers = pcm
            .iter()
            .map(|p| {
                p.as_ref().map(|p| crate::formats::SampleHeader {
                    codec: 3,
                    channels: p.channels.len() as u8,
                    rate: p.rate,
                    frames: p.channels.first().map_or(0, |c| c.len() as u32),
                    loop_start: None,
                })
            })
            .collect();
        let mixer_bank = self.banks[index].mixer_bank;
        mixer.add_bank(mixer_bank, headers, pcm);
        mixer.set_bank_group(mixer_bank, crate::mixer::GROUP_PLAYER);
        self.banks[index].bank = bank;
        Some(index)
    }

    pub fn bank_index(&self, name: &str) -> Option<usize> {
        self.banks.iter().position(|b| b.name == name)
    }

    /// `sub_82975700` + `sub_82975A60`: start sound `id` of a bank with the owner's first block.
    pub fn start(&mut self, bank: usize, id: u32, block: [f32; 6], mixer: &mut Mixer) -> Option<SoundId> {
        let b = self.banks.get_mut(bank)?;
        let records = b.bank.records.len();
        let containers = b.bank.containers.len();
        if records == 0 {
            return None;
        }
        let id = id as usize;
        let record = if id < records {
            id
        } else if id < records + containers {
            let c = &mut b.bank.containers[id - records];
            let k = pick(c.ids.len() as u8, c.mode, &mut c.state, &mut self.rng);
            usize::from(c.ids.get(usize::from(k)).copied().unwrap_or(0)).min(records - 1)
        } else {
            records - 1
        };
        // sub_829757D0: one voice per group.
        let mut voices = Vec::new();
        let groups = b.bank.records[record].groups.len();
        for g in 0..groups {
            let group = &mut b.bank.records[record].groups[g];
            let k = pick(group.members.len() as u8, group.mode, &mut group.state, &mut self.rng);
            let member = group.members[usize::from(k).min(group.members.len().saturating_sub(1))];
            let u = self.rng.unit();
            if u > member.probability {
                voices.push(None);
                continue;
            }
            voices.push(Some(Voice { member, state: State::Delay, pitch: 0.0, spread: 1.0, last_rate: 0.0, delay: -1.0, elapsed: 0.0, mixer: None }));
        }
        let rec = &b.bank.records[record];
        // sub_82975A60: the container pitch factor, then each voice's random draws.
        let factor = self.rng.unit().mul_add(rec.pitch_rand, rec.pitch_base);
        let mut sound = Sound { bank, record, factor, voices, route: self.route };
        for v in sound.voices.iter_mut().flatten() {
            init_voice(v, &mut self.rng);
        }
        // Voices without a delay start at once with the start block as the owner passed it to
        // sub_82975A60 (no record gain / pitch factor yet: sub_82975668 → sub_82976360).
        let mixer_bank = b.mixer_bank;
        let route = sound.route;
        for v in sound.voices.iter_mut().flatten() {
            if v.delay == 0.0 {
                begin(v, &block, mixer_bank, route, mixer);
                self.started += 1;
            }
        }
        let slot = self.sounds.iter().position(Option::is_none).unwrap_or_else(|| {
            self.sounds.push(None);
            self.sounds.len() - 1
        });
        self.sounds[slot] = Some(sound);
        Some(slot)
    }

    /// `sub_82975B08`: the owner's per-frame block.
    pub fn update(&mut self, id: SoundId, block: [f32; 6], mixer: &mut Mixer) {
        let Some(Some(sound)) = self.sounds.get_mut(id) else { return };
        let b = &self.banks[sound.bank];
        let rec = &b.bank.records[sound.record];
        let mut block = block;
        block[0] *= rec.gain;
        block[1] *= sound.factor;
        let route = sound.route;
        for slot in sound.voices.iter_mut() {
            let Some(v) = slot else { continue };
            if step(v, &block, b.mixer_bank, route, mixer) {
                self.started += 1;
            }
            if v.state == State::Done {
                if let Some(m) = v.mixer.take() {
                    crate::eval::VoiceHost::release(mixer, m);
                }
                *slot = None;
            }
        }
    }

    /// `sub_82975BF0`: any voice still delaying or playing.
    pub fn alive(&self, id: SoundId) -> bool {
        matches!(self.sounds.get(id), Some(Some(s)) if s.voices.iter().flatten().any(|v| v.state != State::Done))
    }

    /// The owner's release (`sub_824836B8`): stop every voice.
    pub fn release(&mut self, id: SoundId, mixer: &mut Mixer) {
        if let Some(slot) = self.sounds.get_mut(id) {
            if let Some(sound) = slot.take() {
                for v in sound.voices.into_iter().flatten() {
                    if let Some(m) = v.mixer {
                        crate::eval::VoiceHost::release(mixer, m);
                    }
                }
            }
        }
    }

    /// Diagnostics: (bank name, record, member sample, gain, pitch) of every playing voice.
    pub fn voices(&self) -> Vec<(String, usize, u16, f32, f32)> {
        let mut out = Vec::new();
        for s in self.sounds.iter().flatten() {
            for v in s.voices.iter().flatten() {
                if v.state == State::Playing {
                    out.push((self.banks[s.bank].name.clone(), s.record, v.member.sample, v.spread * v.member.gain, v.pitch));
                }
            }
        }
        out
    }
}

/// `sub_82975CC8`: the per-voice draws (gain spread, pitch, delay).
fn init_voice(v: &mut Voice, rng: &mut CrtRand) {
    let m = &v.member;
    let u = rng.unit();
    let x = u.mul_add(2.0, -1.0); // fmsubs: U·2 − 1
    v.spread = if x > 0.0 {
        if m.gain_spread == 0.0 {
            4.0
        } else {
            let s = 1.0 - (1.0 - m.gain_spread);
            (1.0 / s - 1.0).mul_add(x, 1.0)
        }
    } else {
        -((x * -1.0) * (1.0 - m.gain_spread) - 1.0)
    };
    let u = rng.unit();
    v.pitch = u.mul_add(m.pitch_rand, m.pitch);
    v.last_rate = v.pitch;
    v.delay = if m.delay == 0.0 { 0.0 } else { m.delay };
    if m.delay_rand != 0.0 {
        let u = rng.unit();
        v.delay = u.mul_add(m.delay_rand, v.delay);
    }
}

/// `sub_82976CF0`: the member's fade envelope applied to a gain.
fn fade(m: &Member, elapsed: f32, gain: f32) -> f32 {
    if m.fade_in_end != 0.0 && elapsed < m.fade_in_end {
        return gain * curve(m.curve, (elapsed - m.start) / (m.fade_in_end - m.start));
    }
    if m.fade_out_start != 0.0 && elapsed > m.fade_out_start {
        return gain * curve(m.curve, 1.0 - (elapsed - m.fade_out_start) / (m.length - m.fade_out_start));
    }
    gain
}

/// The azimuth (degrees) of a voice for a block.
fn azimuth(m: &Member, block: &[f32; 6]) -> Option<f32> {
    if m.pan == -127.0 { None } else { Some(m.pan.mul_add(block[4], block[2])) }
}

/// `sub_82976360`: start the sample.
fn begin(v: &mut Voice, block: &[f32; 6], mixer_bank: usize, route: crate::bus::Route, mixer: &mut Mixer) {
    let m = v.member;
    v.state = State::Playing;
    v.elapsed = m.start;
    let seek = if m.start != 0.0 { f64::from(m.pitch / m.rate2) * f64::from(m.start) } else { 0.0 };
    let gain = fade(&m, v.elapsed, v.spread * m.gain * block[0]);
    v.mixer = mixer.open_routed(mixer_bank, m.sample, seek, v.pitch * block[1], gain, azimuth(&m, block), route);
    if v.mixer.is_none() {
        v.state = State::Done;
    }
}

/// `sub_82976860`: one frame of a voice. Returns true when it started this frame.
fn step(v: &mut Voice, block: &[f32; 6], mixer_bank: usize, route: crate::bus::Route, mixer: &mut Mixer) -> bool {
    let dt = block[3];
    if v.state == State::Delay {
        if v.delay > 0.0 {
            v.delay -= dt;
            if v.delay > 0.0 {
                return false;
            }
        }
        begin(v, block, mixer_bank, route, mixer);
        return v.state == State::Playing;
    }
    if v.state != State::Playing {
        return false;
    }
    let m = v.member;
    let elapsed = v.last_rate.mul_add(dt, v.elapsed);
    v.last_rate = block[1];
    v.elapsed = elapsed;
    let pitch = v.pitch * block[1];
    let gain = fade(&m, elapsed, (m.gain * v.spread) * block[0]);
    let limit = (m.pitch / v.pitch).mul_add(m.length, f32::from_bits(0x3E23_D70A));
    let ended = v.mixer.is_none_or(|id| !mixer.direct_alive(id));
    if limit < elapsed || ended {
        v.state = State::Done;
        return false;
    }
    if let Some(id) = v.mixer {
        mixer.set_direct(id, pitch, gain, azimuth(&m, block));
    }
    false
}

#[cfg(test)]
mod tests;
