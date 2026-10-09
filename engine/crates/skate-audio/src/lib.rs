//! Native port of Skate 3's retail audio runtime, written from our own behavioural specs
//! (`audio-specs/aems-evaluator-spec.md`, `audio-specs/aems-voice-graph-spec.md`; `audio-specs/` in this crate
//! means `docs/hails-additions/audio-specs/`, the published specs).
//!
//! Engine independent: no Bevy, no file I/O, no unsafe code. The game (or a test) hands in bank and
//! project bytes and PCM, posts messages, and pulls 48 kHz output blocks.
//!
//! Layers, each usable alone:
//! - [`formats`]: the disc containers (`ABKC` module banks with their `S10A` sample banks, `MOIR` Csis
//!   projects, EA SNR sample headers);
//! - [`eval`]: the AEMS patch-program evaluator (instances, the 40 opcodes, the shared RNG, the 6-block
//!   tick, Csis classes / functions / global variables) driving voices through the [`eval::VoiceHost`]
//!   trait;
//! - [`dsp`]: the voice-graph modules (linear resampler, RBJ high/low-pass biquads, de-click gain,
//!   send ramps, the 2-D panner, channel routes and the output stage);
//! - [`mixer`]: voices built from those modules, implementing [`eval::VoiceHost`];
//! - [`runtime`]: evaluator + mixer on one block clock, with a game-side command queue;
//! - [`mixmap`]: the MixMap mixer (`MixMapSK8.mxb`): game inputs → per-object volumes, pitches,
//!   filter cutoffs and azimuths, once per 60 Hz frame;
//! - [`grain`]: the granular rolling bed (`grains.big`): GrainPlayers picking windows of one long
//!   slow-to-fast recording around a speed-driven read position, on the block clock;
//! - [`player`]: the local player's audio state, its MixMap input writers (PlayerPhysics,
//!   3DObjPos, Jitter, Contacts, Rail, OffBoard) and the player components that post AEMS
//!   classes (grind, sense of speed, foot drag);
//! - [`splice`]: the Splice one-shot player of the `SPLC` banks (pops, landings, touchdowns,
//!   collisions), driven by owner blocks once per frame.
//!
//! Nothing here is code from upstream PR #4, skate3recomp or BurnoutDecomp (no licence); constants,
//! offsets and opcode numbers are facts. See `docs/hails-additions/11-audio.md` (Credits).
#![forbid(unsafe_code)]

pub mod be;
pub mod bus;
pub mod dsp;
pub mod eval;
pub mod formats;
/// The front-end sounds (`fe` records → `sk8_menu` Splice one-shots): the session marker's UI.
pub mod frontend;
pub mod grain;
pub mod mixer;
pub mod mixmap;
pub mod player;
pub mod runtime;
pub mod splice;
/// World sound sources (traffic, pedestrians, streamed speech): see the module docs.
pub mod world;

/// Mixer rate (Hz) and block size (frames) of the retail runtime.
pub const MIX_RATE: u32 = 48_000;
pub const BLOCK: usize = 256;
/// Internal channel order of the 6-channel mix: L, C, R, Ls, Rs, LFE.
pub const CHANNELS: usize = 6;
