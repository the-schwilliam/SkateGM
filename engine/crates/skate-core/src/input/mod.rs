//! Native input publication. Controller/graph producers remain separate stages.
pub mod angle;
pub mod gesture;
pub mod anticipation_intentions;
pub mod animation_packet;
pub mod controller;
pub mod gameplay_map;
pub mod tick;
pub mod graph_intents;
pub mod grind_intentions;
pub mod history;
pub mod pad;
pub mod power_sliding;
pub mod riding_intentions;
pub mod manual_intentions;
pub mod trick_intentions;
pub mod set_turning;
pub mod steering_intentions;
pub mod turn_conditioner;
pub mod turn_remap;
pub mod xbox;
pub mod body_flip_signal;

pub mod wipeout_intentions;
pub mod offboard_intentions;
// gm_sk8 addition: D-pad gestures, ported from SK8-ENGINE/skate-3-rust-engine
pub mod gameplay_gestures;
