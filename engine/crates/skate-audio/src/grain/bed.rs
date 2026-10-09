//! One board's rolling bed on the block clock (spec §2.1, §3.1): two trucks, each with players A
//! and B bound to the same recording, each player feeding its own bus chain into the default
//! bus; plus the rocket layer straight into the default bus. One title-wide generator feeds every
//! pick (retail's `0x82FD7D74` generator, distinct from the AEMS one).
//!
//! Chain per player (`sub_824C8878`; `audio-specs/aems-grain-chain-spec.md`), all three graphs
//! inside one block (pass order 2 < 3 < 5):
//! - graph 1: SubMix (the player's mono bus) → HighPass → LowPass → FrequencyShiftSsb → Send (→
//!   graph 3) → Gain (level ramp × wobble) → Send (→ graph 2, level 1);
//! - graph 3: SubMix → Clip ±0.09 → Gain (wobble) → HighShelf 5 kHz × 0.65 → Send (→ graph 2,
//!   level 1);
//! - graph 2: SubMix → Send (→ FlangeSub return A `[[manager+116]]`: not rendered, there is no
//!   such bus here; its level is kept) → Send (→ the environment bus, mono, pre-pan) → Pan2D1
//!   (1 → 6 channels) → Send into the default bus.
//!
//! [`GrainBed::chain_extras`] = false keeps the older chain (HighPass → LowPass → Gain → Pan2D1 →
//! Send: no FSS, graph 3 or env send), bit-identical to the renders before the full chain.
use std::sync::Arc;

use crate::BLOCK;
use crate::bus::env::Level;
use crate::dsp::biquad::{Iir2, Kind};
use crate::dsp::fss::FrequencyShift;
use crate::dsp::gain::Gain;
use crate::dsp::pan::{self, Pan2D};
use crate::dsp::peaking::clip;
use crate::dsp::routes::to_six;
use crate::dsp::send::{Mode, Send, fold_release};
use crate::dsp::shelf::HighShelfIir2;
use crate::eval::rng::Rng;

use super::chain::ChainTuning;
use super::player::{BLOCK_DELTA, GrainParams, GrainPlayer, GrainSource, Record};

/// Values the board owner posts to a player's chain each frame (§3.2; computed by
/// [`super::chain::ChainState::values`]).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ChainValues {
    /// HighPass / LowPass cutoffs (Hz): MixMap SkateBoard level(12) / level(11).
    pub highpass_hz: f32,
    pub lowpass_hz: f32,
    /// Pan2D1 angle (degrees): raw(0) × 360/65535.
    pub pan_degrees: f32,
    /// The graph-1 Gain (level ramp × wobble, as last posted).
    pub level: f32,
    /// FrequencyShiftSsb shift (Hz; 0 is an allpass, not a bypass).
    pub fss_hz: f32,
    /// Graph-1 → graph-3 send level (0 below 46 km/h … 3.0 at 70 km/h).
    pub graph3_send: f32,
    /// The graph-3 Gain (wobble, as last posted).
    pub graph3_gain: f32,
    /// Graph-2 environment send: level(13)/32767.
    pub env_send: f32,
    /// Graph-2 first send (→ FlangeSub return A): level(21)/32767 (A) or level(22)/32767 (B).
    /// Kept, not rendered.
    pub flange_send: f32,
}

impl Default for ChainValues {
    fn default() -> Self {
        Self {
            highpass_hz: 77.0,
            lowpass_hz: 24971.0,
            pan_degrees: 0.0,
            level: 1.0,
            fss_hz: 0.0,
            graph3_send: 0.0,
            graph3_gain: 1.0,
            env_send: 0.0,
            flange_send: 0.0,
        }
    }
}

#[derive(Clone, Debug)]
struct Chain {
    bus: [[f32; BLOCK]; 6],
    hpf: Iir2,
    lpf: Iir2,
    gain: Gain,
    pan: Pan2D,
    send: Send,
    values: ChainValues,
    fss: FrequencyShift,
    /// Graph 1's Send → graph 3, graph 3's Gain and HighShelf, the two level-1 Sends into graph 2.
    to_graph3: Level,
    gain3: Gain,
    shelf: HighShelfIir2,
    from_graph1: Level,
    from_graph3: Level,
    /// Graph 2's env Send.
    env: Level,
}

impl Chain {
    fn new() -> Self {
        Self {
            bus: [[0.0; BLOCK]; 6],
            hpf: Iir2::new(Kind::HighPass),
            lpf: Iir2::new(Kind::LowPass),
            gain: Gain::default(),
            pan: Pan2D::new(1),
            send: Send::default(),
            values: ChainValues::default(),
            fss: FrequencyShift::default(),
            to_graph3: Level::new(0.0),
            gain3: Gain::default(),
            shelf: HighShelfIir2::new(96_000.0, 1.0),
            from_graph1: Level::new(1.0),
            from_graph3: Level::new(1.0),
            env: Level::new(0.0),
        }
    }

    /// The older chain: HighPass → LowPass → Gain → Pan2D1 → Send.
    fn process(&mut self, out: &mut [[f32; BLOCK]; 6]) {
        let v = self.values;
        let mut mono = self.bus[0];
        self.hpf.cutoff = v.highpass_hz;
        self.lpf.cutoff = v.lowpass_hz;
        self.hpf.process(&mut [&mut mono[..]], crate::MIX_RATE as f32);
        self.lpf.process(&mut [&mut mono[..]], crate::MIX_RATE as f32);
        self.gain.target = v.level;
        self.gain.process(&mut [&mut mono[..]]);
        self.pan_and_send(&mono, out);
        for ch in &mut self.bus {
            *ch = [0.0; BLOCK];
        }
    }

    /// The full chain (graphs 1, 3, 2); the env send adds into `env` (mono, × `user`). Returns
    /// whether the env send contributed. `graph3`: graph 3 exists (`sub_824C8878` builds it for the
    /// local player only); without it graph 1's send to it and its return are absent.
    fn process_full(&mut self, out: &mut [[f32; BLOCK]; 6], env: &mut [f32; BLOCK], tuning: &ChainTuning, user: f32, graph3: bool) -> bool {
        let rate = crate::MIX_RATE as f32;
        let v = self.values;
        let mut mono = self.bus[0];
        // Graph 1.
        self.hpf.cutoff = v.highpass_hz;
        self.lpf.cutoff = v.lowpass_hz;
        self.hpf.process(&mut [&mut mono[..]], rate);
        self.lpf.process(&mut [&mut mono[..]], rate);
        self.fss.shift_hz = v.fss_hz;
        self.fss.process(&mut mono, rate);
        let mut g3 = [0.0f32; BLOCK];
        if graph3 {
            self.to_graph3.target = v.graph3_send;
            self.to_graph3.add(&mono, &mut g3);
        }
        self.gain.target = v.level;
        self.gain.process(&mut [&mut mono[..]]);
        let mut g2 = [0.0f32; BLOCK];
        self.from_graph1.add(&mono, &mut g2);
        // Graph 3.
        if graph3 {
            clip(&mut [&mut g3[..]], tuning.clip);
            self.gain3.target = v.graph3_gain;
            self.gain3.process(&mut [&mut g3[..]]);
            self.shelf.freq = tuning.shelf_hz;
            self.shelf.gain = tuning.shelf_gain;
            self.shelf.process(&mut [&mut g3[..]], rate);
            self.from_graph3.add(&g3, &mut g2);
        }
        // Graph 2: the FlangeSub send has no bus here; the env send is mono, before the panner.
        self.env.target = v.env_send * user;
        let sends = !self.env.silent();
        if sends {
            self.env.add(&g2, env);
        }
        self.pan_and_send(&g2, out);
        for ch in &mut self.bus {
            *ch = [0.0; BLOCK];
        }
        sends
    }

    fn pan_and_send(&mut self, mono: &[f32; BLOCK], out: &mut [[f32; BLOCK]; 6]) {
        self.pan.params[pan::ANGLE] = self.values.pan_degrees;
        let mut six = [[0.0f32; BLOCK]; 6];
        self.pan.process(&[&mono[..]], &mut six);
        let outs: [&[f32]; 6] = std::array::from_fn(|c| &six[c][..]);
        self.send.process(&outs, to_six(6), out, Mode::Normal);
    }
}

#[derive(Clone, Debug)]
pub struct Truck {
    pub players: [GrainPlayer; 2],
    chains: [Chain; 2],
    /// Retail builds a truck's chains at its first bind (`sub_824C8878`); the full chain is only
    /// processed from then on (the older chain always runs, as before).
    built: bool,
}

impl Truck {
    fn new() -> Self {
        Self { players: [GrainPlayer::new(), GrainPlayer::new()], chains: [Chain::new(), Chain::new()], built: false }
    }

    pub fn bound(&self) -> Option<&str> {
        self.players[0].bound().map(|s| s.name.as_str())
    }
}

pub struct GrainBed {
    pub trucks: [Truck; 2],
    pub rocket: GrainPlayer,
    rocket_send: Send,
    rocket_bus: [[f32; BLOCK]; 6],
    pub rng: Rng,
    /// Our own user-volume scale on the bed's output (1 = retail level).
    pub gain: f32,
    /// Release de-click of chains torn down by a bind.
    fold: [f32; 6],
    /// The full retail chain (FSS, graph 3, env send); false = the older chain, bit-identical to
    /// the renders before it.
    pub chain_extras: bool,
    /// Graph 3's clip and shelf (the owner vault; the speed-driven values come from the host).
    pub chain_tuning: ChainTuning,
    /// The local player's bed (instance 0 of the Player slot): its chains have graph 3
    /// (`sub_824C8878` builds it only for the local player). An NPC skater's bed (instance 1,
    /// [`crate::runtime::Runtime::npc_grains`]) has graphs 1 and 2 only.
    pub local: bool,
    /// This block's dry 6-channel mix (before [`GrainBed::gain`]) and the chains' env sends.
    mix: Box<[[f32; BLOCK]; 6]>,
    env: Box<[f32; BLOCK]>,
    env_active: bool,
}

impl Default for GrainBed {
    fn default() -> Self {
        Self::new()
    }
}

impl GrainBed {
    /// The title generator's fixed constants (`0x82FD36A0`); retail adds the time base at boot.
    pub const SEED: [u32; 6] = [0xF22D_0E56, 0x8831_26E9, 0xC624_DD2F, 0x0702_C49C, 0x9E35_3F7D, 0x6FDF_3B64];

    pub fn new() -> Self {
        Self {
            trucks: [Truck::new(), Truck::new()],
            rocket: GrainPlayer::new(),
            rocket_send: Send::default(),
            rocket_bus: [[0.0; BLOCK]; 6],
            rng: Rng::new(Self::SEED),
            gain: 1.0,
            fold: [0.0; 6],
            chain_extras: true,
            chain_tuning: ChainTuning::default(),
            local: true,
            mix: Box::new([[0.0; BLOCK]; 6]),
            env: Box::new([0.0; BLOCK]),
            env_active: false,
        }
    }

    /// Bind both players of a truck to a recording (A with params[0], B with params[1]). Retail
    /// tears the truck's chains down and rebuilds them on every bind, so their histories restart.
    pub fn bind_truck(&mut self, truck: usize, source: Arc<GrainSource>, params: [GrainParams; 2], records: [Record; 2]) {
        let t = &mut self.trucks[truck];
        t.built = true;
        for c in &mut t.chains {
            for (f, l) in self.fold.iter_mut().zip(c.send.last) {
                *f += l;
            }
            let values = c.values;
            *c = Chain::new();
            c.values = values;
        }
        for (p, (params, record)) in t.players.iter_mut().zip(params.into_iter().zip(records)) {
            p.record = record;
            p.bind(source.clone(), params, &mut self.rng);
        }
    }

    /// Run `f` with `rng` as this bed's generator (swapped in and back out): retail's grain picks
    /// all draw from the one title-wide generator (`0x82FD7D74`), so a second owner's bed (an NPC
    /// skater's, [`crate::runtime::Runtime::npc_grains`]) draws from the local bed's.
    pub fn share_rng<R>(&mut self, rng: &mut Rng, f: impl FnOnce(&mut Self) -> R) -> R {
        std::mem::swap(&mut self.rng, rng);
        let out = f(self);
        std::mem::swap(&mut self.rng, rng);
        out
    }

    /// Stop both players of a truck at once (surface change, no contact).
    pub fn stop_truck(&mut self, truck: usize) {
        for p in &mut self.trucks[truck].players {
            p.stop();
        }
    }

    pub fn set_records(&mut self, truck: usize, records: [Record; 2]) {
        for (p, r) in self.trucks[truck].players.iter_mut().zip(records) {
            p.record = r;
        }
    }

    pub fn set_chains(&mut self, truck: usize, values: [ChainValues; 2]) {
        for (c, v) in self.trucks[truck].chains.iter_mut().zip(values) {
            c.values = v;
        }
    }

    pub fn start_rocket(&mut self, source: Arc<GrainSource>, params: GrainParams, record: Record) {
        self.rocket.record = record;
        self.rocket.bind(source, params, &mut self.rng);
    }

    pub fn stop_rocket(&mut self) {
        self.rocket.stop();
    }

    /// Grain voices sounding.
    pub fn voices(&self) -> usize {
        self.trucks.iter().flat_map(|t| &t.players).map(GrainPlayer::voices).sum::<usize>() + self.rocket.voices()
    }

    /// One 256-frame block: the scheduler (phase 1), then the voices and chains, added into `out`.
    pub fn render(&mut self, out: &mut [[f32; BLOCK]; 6]) {
        if self.render_block() {
            self.add_to(out);
        }
    }

    /// Render one block into the bed's own buffers ([`GrainBed::add_to`], [`GrainBed::env_send`]);
    /// false = idle (nothing to add). The runtime renders the bed before the mixer so that its env
    /// sends reach this block's environment network.
    pub fn render_block(&mut self) -> bool {
        self.env_active = false;
        let pending = self.trucks.iter().flat_map(|t| &t.players).chain([&self.rocket]).any(GrainPlayer::pending);
        let idle = self.voices() == 0 && !pending && self.fold.iter().all(|&f| f == 0.0);
        if idle {
            return false;
        }
        let mix = &mut *self.mix;
        *mix = [[0.0f32; BLOCK]; 6];
        fold_release(mix, &self.fold);
        self.fold = [0.0; 6];
        if self.chain_extras {
            self.env.fill(0.0);
        }
        for t in &mut self.trucks {
            for (p, c) in t.players.iter_mut().zip(t.chains.iter_mut()) {
                p.tick(BLOCK_DELTA, &mut self.rng);
                p.render(&mut c.bus);
                if self.chain_extras && !t.built {
                    c.bus = [[0.0; BLOCK]; 6];
                } else if self.chain_extras {
                    self.env_active |= c.process_full(mix, &mut self.env, &self.chain_tuning, self.gain, self.local);
                } else {
                    c.process(mix);
                }
            }
        }
        self.rocket.tick(BLOCK_DELTA, &mut self.rng);
        self.rocket.render(&mut self.rocket_bus);
        // The rocket binds to the default bus directly: mono → the centre channel.
        let mono = self.rocket_bus[0];
        self.rocket_send.process(&[&mono[..]], to_six(1), mix, Mode::Normal);
        self.rocket_bus = [[0.0; BLOCK]; 6];
        true
    }

    /// Add the last rendered block × [`GrainBed::gain`] into `out`.
    pub fn add_to(&self, out: &mut [[f32; BLOCK]; 6]) {
        for (o, m) in out.iter_mut().zip(self.mix.iter()) {
            for (a, b) in o.iter_mut().zip(m.iter()) {
                *a += self.gain * b;
            }
        }
    }

    /// The last block's mono input to the environment bus (graph 2's env sends, already × the
    /// user gain), or None when no chain sends.
    pub fn env_send(&self) -> Option<&[f32; BLOCK]> {
        self.env_active.then_some(&*self.env)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mixer::Pcm;

    fn source() -> Arc<GrainSource> {
        let data: Vec<f32> = (0..48000 * 20).map(|i| ((i as f32) * 0.05).sin() * 0.5).collect();
        Arc::new(GrainSource { name: "t".into(), duration: 20.0, pcm: Arc::new(Pcm { rate: 48000, channels: vec![data] }) })
    }

    #[test]
    fn a_bound_truck_sounds_and_stops() {
        let mut bed = GrainBed::new();
        let a = GrainParams { attack: 0.1, sustain: 0.2, release: 0.1, window: 1.6, drift: 0.05 };
        let b = GrainParams { attack: 0.2, sustain: 0.1, release: 0.2, window: 1.5, drift: 0.05 };
        let rec = [Record { gain: 0.5, pitch: 1.0, position: 0.3 }, Record { gain: 0.25, pitch: 1.0, position: 0.2 }];
        bed.bind_truck(0, source(), [a, b], rec);
        let mut energy = 0.0f32;
        for _ in 0..200 {
            let mut out = [[0.0f32; BLOCK]; 6];
            bed.render(&mut out);
            energy += out.iter().flat_map(|c| c.iter()).map(|s| s * s).sum::<f32>();
            assert!(bed.voices() <= 4);
        }
        assert!(energy > 1.0, "the bed sounds ({energy})");
        bed.stop_truck(0);
        assert_eq!(bed.voices(), 0);
        let mut out = [[0.0f32; BLOCK]; 6];
        bed.render(&mut out); // release de-click only
        bed.render(&mut out);
        let mut out = [[0.0f32; BLOCK]; 6];
        bed.render(&mut out);
        assert!(out.iter().all(|c| c.iter().all(|&s| s == 0.0)));
    }

    /// 382 Hz tone bed (A only), `blocks` blocks with the chain values, the centre channel.
    fn render_a(values: ChainValues, tuning: ChainTuning, blocks: usize) -> (Vec<f32>, Vec<f32>) {
        let mut bed = GrainBed::new();
        bed.chain_tuning = tuning;
        let a = GrainParams { attack: 0.1, sustain: 0.2, release: 0.1, window: 1.6, drift: 0.05 };
        let rec = [Record { gain: 0.5, pitch: 1.0, position: 0.3 }, Record { gain: 0.0, pitch: 1.0, position: 0.2 }];
        bed.bind_truck(0, source(), [a, a], rec);
        bed.set_chains(0, [values, ChainValues { graph3_send: values.graph3_send, ..ChainValues::default() }]);
        let (mut centre, mut env) = (Vec::new(), Vec::new());
        for _ in 0..blocks {
            let mut out = [[0.0f32; BLOCK]; 6];
            bed.render(&mut out);
            centre.extend_from_slice(&out[1]);
            env.extend_from_slice(bed.env_send().map_or(&[0.0; BLOCK], |e| e));
        }
        (centre, env)
    }

    fn amplitude(x: &[f32], f: f64) -> f64 {
        let w = std::f64::consts::TAU * f / 48000.0;
        let (mut re, mut im) = (0.0f64, 0.0f64);
        for (k, &s) in x.iter().enumerate() {
            re += s as f64 * (w * k as f64).cos();
            im -= s as f64 * (w * k as f64).sin();
        }
        2.0 * (re * re + im * im).sqrt() / x.len() as f64
    }

    #[test]
    fn the_special_shift_moves_the_bed_up_150_hz() {
        let f0 = 0.05 * 48000.0 / std::f64::consts::TAU;
        let (plain, _) = render_a(ChainValues::default(), ChainTuning::default(), 400);
        let (shifted, _) = render_a(ChainValues { fss_hz: 150.0, ..ChainValues::default() }, ChainTuning::default(), 400);
        let tail = |x: &[f32]| x[x.len() / 2..].to_vec();
        let (plain, shifted) = (tail(&plain), tail(&shifted));
        let (p0, p1) = (amplitude(&plain, f0), amplitude(&plain, f0 + 150.0));
        let (s0, s1) = (amplitude(&shifted, f0), amplitude(&shifted, f0 + 150.0));
        assert!(p0 > 20.0 * p1, "unshifted: {p0} at f0, {p1} at f0 + 150");
        assert!(s1 > 20.0 * s0, "shifted: {s0} at f0, {s1} at f0 + 150");
        assert!((s1 / p0 - 1.0).abs() < 0.1, "same level ({s1} vs {p0})");
    }

    #[test]
    fn graph3_adds_a_clipped_copy_only_with_its_send() {
        let loose = ChainTuning { clip: 0.5, ..ChainTuning::default() };
        let (a, _) = render_a(ChainValues::default(), ChainTuning::default(), 200);
        let (b, _) = render_a(ChainValues::default(), loose, 200);
        assert_eq!(a, b, "send 0: graph 3 contributes nothing");
        let rms = |x: &[f32]| (x.iter().map(|v| v * v).sum::<f32>() / x.len() as f32).sqrt();
        let (c, _) = render_a(ChainValues { graph3_send: 3.0, ..ChainValues::default() }, ChainTuning::default(), 200);
        assert!(rms(&c) > 1.2 * rms(&a), "send 3 adds the copy ({} vs {})", rms(&c), rms(&a));
        // Clipped at ±0.09 before the shelf: the copy's peak stays near 0.09 + the dry peak.
        let peak = |x: &[f32]| x.iter().fold(0.0f32, |m, v| m.max(v.abs()));
        assert!(peak(&c) < peak(&a) + 0.09 * 1.2, "{} vs {}", peak(&c), peak(&a));
    }

    #[test]
    fn the_env_send_is_mono_before_the_pan() {
        let (_, none) = render_a(ChainValues::default(), ChainTuning::default(), 100);
        assert!(none.iter().all(|&v| v == 0.0), "level 0: no env input");
        let half = ChainValues { env_send: 0.5, pan_degrees: -90.0, ..ChainValues::default() };
        let (centre, env) = render_a(half, ChainTuning::default(), 200);
        let (dry, _) = render_a(ChainValues { pan_degrees: 0.0, ..ChainValues::default() }, ChainTuning::default(), 200);
        let leak = centre[BLOCK..].iter().fold(0.0f32, |m, v| m.max(v.abs()));
        assert!(leak < 1e-6, "panned hard left: nothing in the centre ({leak})");
        // The env tap is the pre-pan mono × 0.5: half the centre-panned dry signal, sample for sample.
        for (k, (&e, &d)) in env.iter().zip(&dry).enumerate().skip(BLOCK) {
            assert!((e - 0.5 * d).abs() <= 1e-6 * d.abs().max(1e-3), "{k}: {e} vs {d}");
        }
    }

    /// An NPC skater's bed (`local` false) has no graph 3: its send level changes nothing. Its
    /// picks draw from the generator it is handed (`share_rng`), leaving its own untouched.
    #[test]
    fn a_non_local_bed_has_no_graph3_and_shares_the_generator() {
        let a = GrainParams { attack: 0.1, sustain: 0.2, release: 0.1, window: 1.6, drift: 0.05 };
        let rec = [Record { gain: 0.5, pitch: 1.0, position: 0.3 }, Record { gain: 0.25, pitch: 1.0, position: 0.2 }];
        let run = |local: bool, send: f32| {
            let mut bed = GrainBed::new();
            bed.local = local;
            bed.bind_truck(0, source(), [a, a], rec);
            bed.set_chains(0, [ChainValues { graph3_send: send, ..ChainValues::default() }; 2]);
            let mut all = Vec::new();
            for _ in 0..100 {
                let mut out = [[0.0f32; BLOCK]; 6];
                bed.render(&mut out);
                all.extend(out.iter().flatten().copied());
            }
            all
        };
        assert_eq!(run(false, 0.0), run(false, 3.0), "no graph 3: the send is inert");
        assert_ne!(run(true, 0.0), run(true, 3.0), "the local bed's graph 3 adds the copy");
        // Send 0: a built graph 3 still adds its filters' anti-denormal bias (~1e-18), nothing else.
        let gap = run(true, 0.0).iter().zip(run(false, 0.0)).fold(0.0f32, |m, (x, y)| m.max((x - y).abs()));
        assert!(gap < 1e-12, "send 0: graph 3 adds only its bias ({gap})");
        // Shared generator: the same output as a bed that owns that generator's state, and the
        // borrowing bed's own generator never moves.
        let seed = [1, 2, 3, 4, 5, 6];
        let mut owner = GrainBed::new();
        owner.rng = Rng::new(seed);
        let mut borrower = GrainBed::new();
        let own = format!("{:?}", borrower.rng);
        let mut shared = Rng::new(seed);
        owner.bind_truck(0, source(), [a, a], rec);
        borrower.share_rng(&mut shared, |b| b.bind_truck(0, source(), [a, a], rec));
        for _ in 0..100 {
            let (mut x, mut y) = ([[0.0f32; BLOCK]; 6], [[0.0f32; BLOCK]; 6]);
            owner.render(&mut x);
            borrower.share_rng(&mut shared, |b| b.render(&mut y));
            assert_eq!(x, y);
        }
        assert_eq!(format!("{:?}", borrower.rng), own, "its own generator is untouched");
        assert_eq!(format!("{shared:?}"), format!("{:?}", owner.rng), "the shared one drew as the owner's did");
    }

    #[test]
    fn extras_off_is_the_older_chain() {
        // The older chain ignores the new values (no FSS, graph 3 or env send).
        let run = |extras: bool, v: ChainValues| {
            let mut bed = GrainBed::new();
            bed.chain_extras = extras;
            let a = GrainParams { attack: 0.1, sustain: 0.2, release: 0.1, window: 1.6, drift: 0.05 };
            let rec = [Record { gain: 0.5, pitch: 1.0, position: 0.3 }, Record { gain: 0.25, pitch: 1.0, position: 0.2 }];
            bed.bind_truck(0, source(), [a, a], rec);
            bed.set_chains(0, [v; 2]);
            let mut all = Vec::new();
            for _ in 0..100 {
                let mut out = [[0.0f32; BLOCK]; 6];
                bed.render(&mut out);
                all.extend(out.iter().flatten().copied());
                assert!(bed.env_send().is_none());
            }
            all
        };
        let busy = ChainValues { fss_hz: 150.0, graph3_send: 3.0, graph3_gain: 1.2, env_send: 1.0, ..ChainValues::default() };
        assert_eq!(run(false, ChainValues::default()), run(false, busy));
        assert_ne!(run(true, ChainValues::default()), run(false, ChainValues::default()), "FSS at 0 Hz is an allpass");
    }
}
