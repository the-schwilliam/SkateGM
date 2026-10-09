//! MixMap controller keys of the world owners (mixmap-spec §3; object names from the game's SFX
//! factory table, `mxb_tool.py`). Instance `g` is the owner's pool index ([`super::owners`]).
use crate::mixmap::keys::{ctl, obj};

pub const TRAFFIC: u32 = 4;
pub const PEDESTRIAN: u32 = 5;

/// Free-skate instance counts (`mixmap::RETAIL_INSTANCES`).
pub const TRAFFIC_INSTANCES: usize = 4;
pub const PEDESTRIAN_INSTANCES: usize = 15;

/// `SFXObj_TrafficEngine` (outputs 0–9: azimuths 0–2 of B1 / B2 / B0, volumes 3 / 4 / 5 / 9,
/// pitch 6 (B0's Doppler), filters 7 / 8).
pub const fn traffic_engine(g: u32) -> u32 {
    obj(TRAFFIC, 0, g)
}
/// `SFXObj_TrafficSkids` (outputs 0–6).
pub const fn traffic_skids(g: u32) -> u32 {
    obj(TRAFFIC, 1, g)
}
/// `SFXObj_TrafficHorn` (outputs 0–10: the horn 0–4, the alarm 5–10).
pub const fn traffic_horn(g: u32) -> u32 {
    obj(TRAFFIC, 2, g)
}
/// `SFXCTL_TrafficCarPhysics` (input 0 gates A11, the +650 mB near boost of B13; written by the
/// record writer `sub_824B2A28`: [`super::traffic::relative_speed_word`]).
pub const fn traffic_car_physics(g: u32) -> u32 {
    ctl(TRAFFIC, 0, g)
}
/// The vehicle's three 3DObjPos blocks: 1 (B0, B3–B13: the body), 2 (B1, Doppler c 1557: the
/// engine layer), 3 (B2, c 554: the exhaust layer); they follow the record's body / front / rear
/// points ([`super::traffic::record_points`], binding provisional).
pub const fn traffic_pos(g: u32, block: u32) -> u32 {
    ctl(TRAFFIC, block, g)
}

/// `SFXObj_PedestrianSpeech` (outputs 0–23).
pub const fn ped_speech(g: u32) -> u32 {
    obj(PEDESTRIAN, 0, g)
}
/// `SFXObj_PedestrianSFX` (outputs 0–9: footsteps, foley).
pub const fn ped_sfx(g: u32) -> u32 {
    obj(PEDESTRIAN, 1, g)
}
/// `SFXObj_PedBodyFall` (outputs 0–7).
pub const fn ped_body_fall(g: u32) -> u32 {
    obj(PEDESTRIAN, 2, g)
}
/// `SFXObj_Tazer` (outputs 0–3).
pub const fn ped_tazer(g: u32) -> u32 {
    obj(PEDESTRIAN, 3, g)
}
/// The ped's 3DObjPos block (every Pedestrian B lookup reads `Ctl 5.1`).
pub const fn ped_pos(g: u32) -> u32 {
    ctl(PEDESTRIAN, 1, g)
}

/// The MixMap PlayerSpeech slot (13): one instance per skater's `CSTATE_SkaterSpeech` record (7 in
/// free skate). Its object 0 is the skater's speech owner (`SFXObj_PlayerSpeech`, update
/// `sub_824DA300`), every B lookup reads the 3DObjPos `Ctl 13.1`.
pub const PLAYER_SPEECH: u32 = 13;
pub const PLAYER_SPEECH_INSTANCES: usize = 7;

/// `SFXObj_PlayerSpeech` (outputs 0–18).
pub const fn player_speech(g: u32) -> u32 {
    obj(PLAYER_SPEECH, 0, g)
}
/// The skater speech owner's 3DObjPos block.
pub const fn player_speech_pos(g: u32) -> u32 {
    ctl(PLAYER_SPEECH, 1, g)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_follow_the_controller_layout() {
        assert_eq!(traffic_engine(0), 0x4004_0000);
        assert_eq!(traffic_horn(3), 0x4004_0000 | (3 << 11) | (2 << 4));
        assert_eq!(traffic_pos(1, 2), 0x6004_0000 | (1 << 11) | (2 << 4));
        assert_eq!(ped_pos(14), 0x6005_0000 | (14 << 11) | (1 << 4));
        assert_eq!(ped_sfx(0), 0x4005_0010);
    }
}
