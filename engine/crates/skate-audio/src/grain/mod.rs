//! The granular rolling bed (`grains.big` + GrainPlayer), our own port from
//! `audio-specs/grain-player-spec.md`:
//! - [`format`]: `.grain` members (header, stored duration, seek table, EAAC header);
//! - [`player`]: the GrainPlayer (pick, per-block scheduler, voices with square-root fades);
//! - [`board`]: per-surface tuning, the speed → position curve and the per-frame records;
//! - [`chain`]: the owner side of the bus chains (FSS values, graph-3 send, gain wobbles);
//! - [`bed`]: the per-board players (2 trucks × A/B) with their bus chains, and the rocket layer,
//!   rendered on the runtime's block clock.
pub mod bed;
pub mod board;
pub mod chain;
pub mod format;
pub mod player;

pub use bed::{ChainValues, GrainBed};
pub use format::GrainFile;
pub use player::{GrainParams, GrainPlayer, GrainSource, Record};
