//! Controller keys (spec §3): bits 29–31 type (2 = SFXObj, 3 = SFXCTL), 16–23 slot, 11–15
//! instance ("group"), 4–10 object id within the slot, 0–3 input id. A controller is named by
//! its key with the input bits clear. Object names are the game's SFX factory table.

/// Controller identity bits of a key (type + slot + group + object).
pub const KEY_MASK: u32 = 0xE0FF_FFF0;

/// An SFXObj controller (owner of outputs and inputs) of `slot`, object `object`, instance `group`.
pub const fn obj(slot: u32, object: u32, group: u32) -> u32 {
    0x4000_0000 | (slot << 16) | (group << 11) | (object << 4)
}

/// An SFXCTL controller (input block only: physics, 3-D positions).
pub const fn ctl(slot: u32, object: u32, group: u32) -> u32 {
    0x6000_0000 | (slot << 16) | (group << 11) | (object << 4)
}

pub mod slot {
    pub const GLOBAL: u32 = 0;
    pub const PLAYER: u32 = 1;
    pub const AMBIENCE: u32 = 2;
    pub const COLLISION: u32 = 3;
    pub const TRAFFIC: u32 = 4;
    pub const PEDESTRIAN: u32 = 5;
    pub const EMITTER: u32 = 6;
}

// Global slot objects.
pub const ANNOUNCER: u32 = obj(0, 0, 0);
pub const MUSIC: u32 = obj(0, 1, 0);
pub const MASTER: u32 = obj(0, 2, 0);
pub const REVERB: u32 = obj(0, 5, 0);
pub const NIS: u32 = obj(0, 6, 0);
pub const PAUSE: u32 = obj(0, 7, 0);
pub const MENU: u32 = obj(0, 13, 0);
pub const SPEECH: u32 = obj(0, 8, 0);
pub const VU: u32 = obj(0, 10, 0);
pub const CHALLENGE: u32 = obj(0, 11, 0);
pub const HOM: u32 = obj(0, 12, 0);
/// `SFXObj_Jitter` (inputs 0..4: bounded random walks, `player::jitter`).
pub const JITTER: u32 = obj(0, 14, 0);

/// The ambience bed owner (input 0 = the bed fade, 0 = up, 32767 = silent).
pub const AMBIENCE: u32 = obj(2, 0, 0);

/// Player instance `g` (0 = the local player).
pub const fn skateboard(g: u32) -> u32 {
    obj(1, 0, g)
}
pub const fn contacts(g: u32) -> u32 {
    obj(1, 1, g)
}
pub const fn wheels(g: u32) -> u32 {
    obj(1, 2, g)
}
pub const fn rail(g: u32) -> u32 {
    obj(1, 3, g)
}
pub const fn cracks(g: u32) -> u32 {
    obj(1, 4, g)
}
pub const fn tricks(g: u32) -> u32 {
    obj(1, 5, g)
}
pub const fn clothing(g: u32) -> u32 {
    obj(1, 6, g)
}
pub const fn treatments(g: u32) -> u32 {
    obj(1, 7, g)
}
pub const fn sense_of_speed(g: u32) -> u32 {
    obj(1, 8, g)
}
pub const fn off_board(g: u32) -> u32 {
    obj(1, 9, g)
}
pub const fn hand_grabs(g: u32) -> u32 {
    obj(1, 10, g)
}
pub const fn player_physics(g: u32) -> u32 {
    ctl(1, 0, g)
}
/// The player's two 3DObjPos input blocks (`0x60010010`, `0x60010020`).
pub const fn obj_pos(g: u32) -> u32 {
    ctl(1, 1, g)
}
pub const fn obj_pos2(g: u32) -> u32 {
    ctl(1, 2, g)
}

/// One `CSTATEMGR_Emitter` state (0..4): its SFXObj outputs and its 3-D input block.
pub const fn emitter(g: u32) -> u32 {
    obj(6, 0, g)
}
pub const fn emitter_pos(g: u32) -> u32 {
    ctl(6, 0, g)
}

/// 3DObjPos / SFXCTL input ids (spec §7.3).
pub mod pos {
    /// f32 distance from the followed point (skater).
    pub const DIST_SKATER: usize = 0;
    /// f32 distance from the camera point.
    pub const DIST_CAMERA: usize = 1;
    /// Azimuth (u16 scale) in the skater frame / camera frame.
    pub const AZ_SKATER: usize = 2;
    pub const AZ_CAMERA: usize = 3;
    /// f32 signed relative speed vs skater / camera (negative when closing).
    pub const SPEED_SKATER: usize = 13;
    pub const SPEED_CAMERA: usize = 14;
    /// Bit 0 active; bits 31/30 = speed sign flipped (reset the Doppler slew).
    pub const FLAGS: usize = 15;
}

/// Output-block word 15 bit 0: the block is enabled (set at build).
pub const ENABLE_WORD: usize = 15;
