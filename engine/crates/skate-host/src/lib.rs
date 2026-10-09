#![allow(dead_code, unused_imports)]
mod physics;
mod graph_host;
mod graph_runtime;
mod skater_animation;
mod animation_pose;
mod camera;
mod difficulty;
mod grind_world;
mod input;
pub mod scoring_runtime;
mod skate_world;
mod animation;
mod crash_context;
mod tuning;

pub use physics::bridge;
pub use skate_core::camera::SHAKE_OFF as CAMERA_SHAKE_OFF;
pub static CAMERA_TYPE: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(1);
pub use skate_core::player::selector::AIR_TELEPORT_FRAMES;

mod session_marker;
