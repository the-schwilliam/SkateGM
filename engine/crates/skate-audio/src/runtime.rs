//! Evaluator + mixer on one 256-frame block clock.
//!
//! Per block: the mixer renders the block with the voice parameters as they stand, then the
//! evaluator ticks (every 6th block it walks the programs). Voice commands issued by a walk
//! therefore apply from the next block boundary, as retail drains its command ring at the start of
//! each block. Game-side posts, redeliveries and releases happen between blocks (the host holds
//! the runtime's lock while it calls them), so a walk sees the last value before it.
//!
//! The granular rolling bed ([`crate::grain::GrainBed`]) runs on the same clock: its scheduler
//! (retail's phase-1 plug-in), voices and chains render first (their env sends feed the
//! environment bus with the voices'), and the dry mix is added into the default bus after the
//! AEMS voices and buses.
use std::sync::Arc;

use crate::eval::{Evaluator, NodeId};
use crate::formats::{Bank, Project};
use crate::grain::GrainBed;
use crate::mixer::{Mixer, Pcm};
use crate::splice::{SoundId, SplicePlayer};
use crate::{BLOCK, dsp::routes};

pub struct Runtime {
    pub eval: Evaluator,
    pub mixer: Mixer,
    pub grains: GrainBed,
    /// The Player slot's second owner's rolling bed: the NPC skater holding instance 1
    /// (`world::skaters`; retail's second `SFXObj_SkateBoard` has its own grain players). The host
    /// creates it at the NPC bed's first step; `None` until then (nothing renders, the local bed's
    /// output is unchanged). It draws its picks from [`Self::grains`]' generator (retail's one title-wide
    /// generator), plays at the local bed's user gain and has no graph 3 (`GrainBed::local` false).
    pub npc_grains: Option<Box<GrainBed>>,
    /// The two beds' summed env sends (when both send).
    env_sum: Box<[f32; BLOCK]>,
    /// The Splice one-shot player (`SPLC` banks); its voices live in [`Runtime::mixer`].
    pub splice: SplicePlayer,
    /// Our own user-volume scales (1 = retail level): AEMS voices of world banks and of the
    /// player's banks ([`crate::mixer::GROUP_PLAYER`]); the bed has its own.
    pub aems_gain: f32,
    pub player_gain: f32,
    bus: Box<[[f32; BLOCK]; 6]>,
    stereo: Vec<f32>,
    read: usize,
    /// Blocks rendered.
    pub blocks: u64,
    /// Redeliveries scheduled for a block ([`Runtime::redeliver_at`]).
    scheduled: Vec<(u64, NodeId, Vec<i32>)>,
}

impl Default for Runtime {
    fn default() -> Self {
        Self::new()
    }
}

impl Runtime {
    pub fn new() -> Self {
        Self {
            eval: Evaluator::new(),
            mixer: Mixer::new(),
            grains: GrainBed::new(),
            npc_grains: None,
            env_sum: Box::new([0.0; BLOCK]),
            splice: SplicePlayer::new(),
            aems_gain: 1.0,
            player_gain: 1.0,
            bus: Box::new([[0.0; BLOCK]; 6]),
            stereo: vec![0.0; 2 * BLOCK],
            read: 2 * BLOCK,
            blocks: 0,
            scheduled: Vec::new(),
        }
    }

    /// Install a Csis project; returns its token (`Evaluator::uninstall_project`).
    pub fn install_project(&mut self, project: &Project) -> u64 {
        self.eval.install_project(project)
    }

    /// Install a bank and its decoded samples (by S10A slot; None plays silence of the right
    /// length). Returns the bank id.
    pub fn load_bank(&mut self, bank: Bank, pcm: Vec<Option<Arc<Pcm>>>) -> usize {
        let headers = bank.samples.iter().map(|s| s.1).collect();
        let id = self.eval.load_bank(bank);
        self.mixer.add_bank(id, headers, pcm);
        id
    }

    /// Replace a loaded bank in place (an audio content hot swap; `Evaluator::replace_bank`): the
    /// same id, its place in the class constructor lists, its volume group; the new samples.
    /// Voices of the old bank keep their own copy of the samples until their release ends.
    pub fn replace_bank(&mut self, id: usize, bank: Bank, pcm: Vec<Option<Arc<Pcm>>>) -> Vec<NodeId> {
        let headers = bank.samples.iter().map(|s| s.1).collect();
        let group = self.mixer.bank_group(id);
        let held = self.eval.replace_bank(id, bank, &mut self.mixer);
        self.mixer.add_bank(id, headers, pcm);
        if let Some(g) = group {
            self.mixer.set_bank_group(id, g);
        }
        held
    }

    pub fn unload_bank(&mut self, id: usize) {
        self.eval.unload_bank(id, &mut self.mixer);
        self.mixer.remove_bank(id);
    }

    pub fn post(&mut self, class: usize, payload: &[i32]) -> NodeId {
        self.eval.post(class, payload)
    }

    pub fn redeliver(&mut self, node: NodeId, payload: &[i32]) {
        self.eval.redeliver(node, payload);
    }

    pub fn release(&mut self, node: NodeId) {
        self.scheduled.retain(|e| e.1 != node);
        self.eval.release(node);
    }

    /// Redeliver `payload` to `node` just before the evaluator step of block `block` (a block index
    /// as [`Runtime::blocks`] counts them; past blocks apply at the next one). Replaces any earlier
    /// schedule for the node. For words that must change on the audio clock, not the game's frame
    /// (Class_Seams' one-console-frame trigger pulse, Listening test 9).
    pub fn redeliver_at(&mut self, node: NodeId, payload: &[i32], block: u64) {
        self.scheduled.retain(|e| e.1 != node);
        self.scheduled.push((block, node, payload.to_vec()));
    }

    /// Install the player's streamed recordings (`SFXObj_Wheels`: 0 = jump spin, 1 = manual
    /// spin), decoded up front, in the player volume group.
    pub fn load_streams(&mut self, pcm: Vec<Option<Arc<Pcm>>>) {
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
        self.mixer.add_bank(STREAM_BANK, headers, pcm);
        self.mixer.set_bank_group(STREAM_BANK, crate::mixer::GROUP_PLAYER);
    }

    /// The streamed recordings as `SFXObj_Wheels` sees them.
    pub fn stream_host(&mut self) -> StreamAccess<'_> {
        StreamAccess { mixer: &mut self.mixer }
    }

    /// The Splice player as the player components see it (bank by name).
    pub fn splice_host(&mut self) -> SpliceAccess<'_> {
        SpliceAccess { player: &mut self.splice, mixer: &mut self.mixer }
    }

    /// Render one block: returns the 6-channel default bus (L, C, R, Ls, Rs, LFE).
    pub fn render_block(&mut self) -> &[[f32; BLOCK]; 6] {
        self.mixer.group_gain[usize::from(crate::mixer::GROUP_WORLD)] = self.aems_gain;
        self.mixer.group_gain[usize::from(crate::mixer::GROUP_PLAYER)] = self.player_gain;
        // The bed renders first so that its chains' env sends reach this block's environment
        // network; its dry mix is added after the mixer's buses, as before.
        let bed = self.grains.render_block();
        // The NPC skater's bed after the local one, on the same generator.
        let npc = match self.npc_grains.as_deref_mut() {
            Some(n) => {
                n.gain = self.grains.gain;
                n.chain_extras = self.grains.chain_extras;
                n.share_rng(&mut self.grains.rng, GrainBed::render_block)
            }
            None => false,
        };
        let local_env = if bed { self.grains.env_send() } else { None };
        let npc_env = if npc { self.npc_grains.as_deref().and_then(GrainBed::env_send) } else { None };
        let env = match (local_env, npc_env) {
            (Some(a), Some(b)) => {
                for ((s, x), y) in self.env_sum.iter_mut().zip(a).zip(b) {
                    *s = x + y;
                }
                Some(&*self.env_sum)
            }
            (a, b) => a.or(b),
        };
        self.mixer.render_with_env(&mut self.bus, env);
        if bed {
            self.grains.add_to(&mut self.bus);
        }
        if npc {
            if let Some(n) = self.npc_grains.as_deref() {
                n.add_to(&mut self.bus);
            }
        }
        if !self.scheduled.is_empty() {
            let now = self.blocks;
            let mut i = 0;
            while i < self.scheduled.len() {
                if self.scheduled[i].0 <= now {
                    let (_, node, payload) = self.scheduled.swap_remove(i);
                    self.eval.redeliver(node, &payload);
                } else {
                    i += 1;
                }
            }
        }
        self.eval.block(&mut self.mixer);
        self.blocks += 1;
        &self.bus
    }

    /// Fill `out` with interleaved stereo at 48 kHz through the output stage's stereo table
    /// (0.707·L + 0.5·C + 0.5·Ls, mirrored; clamped to ±1).
    pub fn fill_stereo(&mut self, out: &mut [f32]) {
        let mut at = 0;
        while at < out.len() {
            if self.read >= self.stereo.len() {
                self.render_block();
                routes::output_stereo(&self.bus, &mut self.stereo);
                // Host-side safety for the device stream, not a parity change: a non-finite sample
                // (a NaN / inf from any bug upstream) would poison the output device's mix, so it
                // leaves as silence. Finite samples pass untouched (the e2e renders read the bus).
                for x in &mut self.stereo {
                    if !x.is_finite() {
                        *x = 0.0;
                    }
                }
                self.read = 0;
            }
            let n = (self.stereo.len() - self.read).min(out.len() - at);
            out[at..at + n].copy_from_slice(&self.stereo[self.read..self.read + n]);
            self.read += n;
            at += n;
        }
    }
}

/// The mixer bank of the player's streamed recordings ([`Runtime::load_streams`]).
pub const STREAM_BANK: usize = 1 << 21;

/// [`crate::player::wheels::StreamHost`] over the runtime's mixer (direct voices, dry).
pub struct StreamAccess<'a> {
    pub mixer: &'a mut Mixer,
}

impl crate::player::wheels::StreamHost for StreamAccess<'_> {
    fn start(&mut self, stream: usize, seek: f64) -> Option<u32> {
        self.mixer.open_direct(STREAM_BANK, stream as u16, seek, 1.0, 0.0, Some(0.0))
    }
    fn set(&mut self, voice: u32, gain: f32, pitch: f32) {
        self.mixer.set_direct(voice, pitch, gain, None);
    }
    fn alive(&self, voice: u32) -> bool {
        self.mixer.direct_alive(voice)
    }
    fn stop(&mut self, voice: u32) {
        crate::eval::VoiceHost::release(self.mixer, voice);
    }
}

/// [`crate::player::contacts::SpliceHost`] over the runtime's Splice player and mixer.
pub struct SpliceAccess<'a> {
    pub player: &'a mut SplicePlayer,
    pub mixer: &'a mut Mixer,
}

impl crate::player::contacts::SpliceHost for SpliceAccess<'_> {
    fn set_route(&mut self, route: crate::bus::Route) {
        self.player.route = route;
    }
    /// With the FootStep SubMix on ([`crate::bus::submix::FootSubmixes::enabled`]) the next start
    /// plays into the slot's graph (built on first use, its parameters posted now as
    /// `sub_82494550` does); off, the route set before stays (SFX Master with the env tap).
    fn set_submix(&mut self, submix: Option<crate::player::footsteps::Submix>) {
        let Some(sub) = submix else { return };
        let graphs = &mut self.mixer.buses.submix;
        if !graphs.enabled {
            return;
        }
        graphs.set(sub.graph, &sub.params());
        self.player.route = crate::bus::Route { output: crate::bus::Output::Submix(sub.graph), create: false, owner_env: 0.0, mono: true };
    }
    fn start(&mut self, bank: &str, id: u32, block: [f32; 6]) -> Option<SoundId> {
        // A route applies to the next start only.
        let route = std::mem::take(&mut self.player.route);
        let b = self.player.bank_index(bank)?;
        self.player.route = route;
        let sound = self.player.start(b, id, block, self.mixer);
        self.player.route = crate::bus::Route::default();
        sound
    }
    fn update(&mut self, sound: SoundId, block: [f32; 6]) {
        self.player.update(sound, block, self.mixer);
    }
    fn alive(&self, sound: SoundId) -> bool {
        self.player.alive(sound)
    }
    fn release(&mut self, sound: SoundId) {
        self.player.release(sound, self.mixer);
    }
}
