//! The local player's audio objects on the native runtime (retail's `SFXObj_*` player components
//! and the per-frame audio state they read), engine independent: the game fills an
//! [`AudioState`] from its physics each 60 Hz frame; this module turns it into MixMap inputs
//! ([`inputs`], [`jitter`], [`objpos`]) and into the AEMS packets of the player classes
//! ([`components`]).
//!
//! Retail order per frame (spec `audio-specs/mixmap-spec.md` §1, upstream PR #4's driver notes):
//! audio-state bridge → state-controller inputs → every component's *process* (owner inputs,
//! posts and releases) → one MixMap evaluation → every component's *update* (the held packets
//! rewritten from the MixMap outputs and redelivered). [`components::Player`] follows that split:
//! `process` before the tick, `update` after it.
//!
//! Written from our specs and our reading of the retail code (addresses in the docs); upstream PR
//! #4 / #1 (no licence) were read for behaviour only. Values the vault holds come in as
//! [`tuning::PlayerTuning`] (exported by setup, `tools/asset_pipeline/audio_export.py`
//! `player_tuning`).
pub mod clothing;
pub mod collision;
pub mod components;
pub mod contacts;
pub mod globals;
pub mod footsteps;
pub mod inputs;
pub mod jitter;
pub mod objpos;
pub mod rolling;
pub mod seams;
pub mod state;
pub mod treatment;
pub mod tricks;
pub mod step_on;
pub mod tuning;
pub mod wheels;

pub use state::AudioState;

/// What a component reads from its owner's MixMap output block (owner vfuncs 52/56/60/64).
pub trait Outputs {
    /// vfunc60 / vfunc64: level (Q15) or filter cutoff (Hz), `& 0x7FFF`.
    fn level(&self, id: usize) -> i32;
    /// vfunc52: raw u16 (azimuth, 65536 = 360°).
    fn raw(&self, id: usize) -> i32;
    /// vfunc56: pitch, 4096 = 1.0.
    fn pitch(&self, id: usize) -> i32;
}

/// One owner's output block of a [`crate::mixmap::MixMap`].
pub struct Owner<'a> {
    pub mixmap: &'a crate::mixmap::MixMap,
    pub key: u32,
}

impl Outputs for Owner<'_> {
    fn level(&self, id: usize) -> i32 {
        self.mixmap.level(self.key, id)
    }
    fn raw(&self, id: usize) -> i32 {
        self.mixmap.raw(self.key, id)
    }
    fn pitch(&self, id: usize) -> i32 {
        self.mixmap.pitch_4096(self.key, id)
    }
}

/// Retail's float → word conversions: `fctiwz` (truncate toward zero) then an integer clamp.
pub fn trunc_clamp(x: f32, low: i32, high: i32) -> i32 {
    if x.is_nan() {
        return low.max(0.min(high));
    }
    (x as i32).clamp(low, high)
}

/// `clamp01(x)` as the owners spell it (`fsel` pairs: NaN → 1 like retail's second select).
pub fn clamp01(x: f32) -> f32 {
    let lo = if -x >= 0.0 { 0.0 } else { x };
    if 1.0 - lo >= 0.0 { lo } else { 1.0 }
}

pub mod bridge;
