//! The game-side MixMap input writers of the local player (mixmap-spec §7): the audio state's
//! controller `PlayerPhysics` (`0x60010000`, `sub_824B19C8`), `Contacts` (`0x40010010`, process
//! `sub_824B90D8` / landing `sub_824BA630`), `Rail` (`0x40010030`, `sub_824C28B0`) and
//! `OffBoard` (`0x40010090`, `sub_824E9270`). Pure functions of the [`AudioState`] plus the little
//! memory each writer keeps.
use super::AudioState;
use super::tuning::PlayerTuning;
use crate::mixmap::{MixMap, keys};

/// The image's PlayerPhysics speed scales (`0x822F9520..`): ids 0 (5 km/h full), 1 (30 km/h), 7
/// (50 km/h), 8 and 14 (70 km/h).
pub const SPEED_SCALES: [u32; 4] = [0x46B8_507A, 0x4575_C0A3, 0x4513_7395, 0x44D2_A51E];
/// `PlayerPhysics.in11` after a bail: held this many 60 Hz frames (see [`Physics`]).
pub const BAIL_FLAG_FRAMES: u32 = 110;

/// clamp(trunc(min(max(v × scale, 0), 32767)), 0, 32767).
pub fn speed_word(speed: f32, scale_bits: u32) -> i32 {
    super::trunc_clamp((speed * f32::from_bits(scale_bits)).clamp(0.0, 32767.0), 0, 32767)
}

fn on(b: bool) -> i32 {
    if b { 32767 } else { 0 }
}

/// PlayerPhysics in13 for a non-local skater: vault class `0xC1831BDB6CB1B1EA`, fields
/// `204DCC9296DC9400` (the cap, m/s) and `0395642CA6FC543A` (the slew, per second).
pub const RELATIVE_CAP: f32 = 35.0;
pub const RELATIVE_SLEW: f32 = 100.0;

/// `PlayerPhysics` writer memory.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Physics {
    was_bail: bool,
    bail_frames: u32,
    /// The Player-slot instance written (0 = the local player; NPC skaters, `world::skaters`).
    pub instance: u32,
    /// State `+784`: in13's slewed relative speed.
    relative: f32,
}

impl Physics {
    /// Ids 2, 10, 4, 5, 0, 1, 7, 8, 14, 6, 9, 11, 13 in retail's order, plus 3 and 12.
    ///
    /// - 0/1/7/8 from |ground speed| (retail's word is signed and clamps reverse speeds to 0; our
    ///   engine's ground speed changes sign riding fakie, so its magnitude is used), 14 from |COM v|.
    /// - 9 = 0 for the local player (`[[state+16]+72]` set), 32767 otherwise.
    /// - 11 = the global "G+16" byte, writer not identified (UNCERTAIN, mixmap-spec §10): in PR #4's
    ///   retail capture it rises with each bail (`+676`) and holds for about 110 frames; we write
    ///   that measured shape.
    /// - 13 = |state+96 − record₀+32| slewed (100 /s, cap 35, /35 × 32767): both are the COM
    ///   velocity of the player itself for the local player (the record array `*(G+0x2F078)` holds
    ///   player 0 first), so it is 0 here; a non-local skater's is against the local player's
    ///   ([`Physics::write_against`]).
    /// - 3 = `sub_824B2088`'s listener-facing factor of two PhysOut slot-0 vectors whose meaning we
    ///   have not recovered: 0. Only A25 reads it, as a factor of the combo emphasis A4 (Music.in3,
    ///   0 outside combos).
    /// - 12 = `sub_824B23C8`: state `+684` (soft wheels) for the local player; a non-local
    ///   skater's state carries that function's value in `soft_wheels` (`world::skaters`).
    pub fn write(&mut self, m: &mut MixMap, s: &AudioState) {
        self.write_against(m, s, s.com_velocity);
    }

    /// [`Physics::write`] with the local player's COM velocity for in13 (`sub_824B19C8`: the
    /// difference's length, capped, slewed by state `+784`; 0 for the local player itself).
    pub fn write_against(&mut self, m: &mut MixMap, s: &AudioState, local_com_velocity: [f32; 3]) {
        let key = keys::player_physics(self.instance);
        let v = s.ground_speed.abs();
        m.set_input(key, 2, on(s.wheel_count == 0));
        let wheels = match s.wheel_count {
            1 => 8191,
            2 => 16383,
            3 => 24575,
            4 => 32767,
            _ => 0,
        };
        m.set_input(key, 10, wheels);
        m.set_input(key, 4, on(s.brake));
        m.set_input(key, 5, on(s.manual_brake));
        m.set_input(key, 0, speed_word(v, SPEED_SCALES[0]));
        m.set_input(key, 1, speed_word(v, SPEED_SCALES[1]));
        m.set_input(key, 7, speed_word(v, SPEED_SCALES[2]));
        m.set_input(key, 8, speed_word(v, SPEED_SCALES[3]));
        m.set_input(key, 14, speed_word(s.com_speed(), SPEED_SCALES[3]));
        m.set_input(key, 6, on(s.trick_active));
        m.set_input(key, 9, if s.local { 0 } else { 32767 });
        if s.bail && !self.was_bail {
            self.bail_frames = BAIL_FLAG_FRAMES;
        }
        self.was_bail = s.bail;
        m.set_input(key, 11, on(self.bail_frames > 0));
        self.bail_frames = self.bail_frames.saturating_sub(1);
        m.set_input(key, 13, if s.local { 0 } else { self.relative_word(s, local_com_velocity) });
        m.set_input(key, 3, 0);
        m.set_input(key, 12, on(s.soft_wheels));
    }

    /// in13 of a non-local skater: d = |v − v_local| capped at 35, the `+784` value moves toward d
    /// by at most 100 × dt, word = trunc(value / 35 × 32767) clamped.
    fn relative_word(&mut self, s: &AudioState, local: [f32; 3]) -> i32 {
        let v = s.com_velocity;
        let d = ((v[0] - local[0]).powi(2) + (v[1] - local[1]).powi(2) + (v[2] - local[2]).powi(2)).sqrt();
        let mut d = if d > RELATIVE_CAP { RELATIVE_CAP } else { d };
        let step = RELATIVE_SLEW * s.dt;
        let last = self.relative;
        if d > last {
            if d - last > step {
                d = step + last;
            }
        } else if d < last && last - d > step {
            d = last - step;
        }
        self.relative = d;
        super::trunc_clamp((d / RELATIVE_CAP) * 32767.0, 0, 32767)
    }
}

/// `Contacts` writer memory (`+120` last frame's airborne) and the audio state's per-wheel landing
/// buckets (`+244` stored air factor, `+448` bucket; bridge `sub_824B2350` / `sub_824B2268`).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Contacts {
    /// The Player-slot instance written (0 = the local player).
    pub instance: u32,
    was_airborne: bool,
    air_factor: [f32; 4],
    bucket: [u32; 4],
}

impl Contacts {
    /// The bridge's per-wheel landing buckets (`+448`) as of the last [`Contacts::write`].
    pub fn buckets(&self) -> [u32; 4] {
        self.bucket
    }

    /// The bridge's per-wheel landing buckets: factor = clamp(air time × 0.5, 0, 1) in the air,
    /// else 0; per wheel, while the factor is > 0, the wheel is down or grinding: bucket = 2 if the
    /// stored factor ≥ high, 1 if ≥ low, else 0; then store the factor. So on the landing frame the
    /// bucket reads the last airborne factor: ≥ 1 s of air → 2, ≥ 0.62 s → 1.
    fn update_buckets(&mut self, s: &AudioState, t: &PlayerTuning) {
        let factor = if s.airborne { super::clamp01(s.air_time * 0.5) } else { 0.0 };
        for w in 0..4 {
            if factor > 0.0 || s.wheel_contact[w] || s.grinding {
                let f = self.air_factor[w];
                self.bucket[w] = if !(f < t.wheel_bucket_high) {
                    2
                } else if f >= t.wheel_bucket_low {
                    1
                } else {
                    0
                };
                self.air_factor[w] = factor;
            }
        }
    }

    /// Ids 0, 1, 6 cleared each frame; on a landing (was airborne, now neither airborne nor
    /// grinding): 1 = 32767 (the bed's landing swell, Player F1/F30), 6 = 32767 for the local player
    /// when the first contacting wheel with a material is on a landing-flag material, 2 = the
    /// largest bucket of the contacting wheels (1 → 16000, 2 → 32767, else 0; 0 with no wheel down),
    /// held until the next landing. Ids 0, 3–5, 8, 9 reach no MixMap output and are not written; 7 is
    /// the body poster's first-hit pulse (Player F7 → the Collision slot, +400 mB; `sub_824BCEB0`,
    /// gated by a game flag not yet located — doc 11 "Session-review leftovers"), 0 until then.
    pub fn write(&mut self, m: &mut MixMap, s: &AudioState, t: &PlayerTuning) -> bool {
        self.update_buckets(s, t);
        let key = keys::contacts(self.instance);
        m.set_input(key, 0, 0);
        m.set_input(key, 1, 0);
        m.set_input(key, 6, 0);
        let landed = self.was_airborne && !s.airborne && !s.grinding;
        if landed {
            m.set_input(key, 1, 32767);
            let material = s.contact_material();
            if s.local && t.landing_materials.contains(&material) {
                m.set_input(key, 6, 32767);
            }
            let down: Vec<u32> = (0..4).filter(|&w| s.wheel_contact[w]).map(|w| self.bucket[w]).collect();
            let class = match down.iter().max() {
                Some(1) => 16000,
                Some(2) => 32767,
                _ => 0,
            };
            m.set_input(key, 2, class);
        }
        self.was_airborne = s.airborne;
        landed
    }
}

/// `Rail` ids 0 = grinding (`+341`), 1 = the grind ended this frame (`+342 && !+341`).
pub fn write_rail(m: &mut MixMap, grinding: bool, was_grinding: bool) {
    write_rail_at(m, 0, grinding, was_grinding);
}

/// [`write_rail`] for Player-slot instance `g`.
pub fn write_rail_at(m: &mut MixMap, g: u32, grinding: bool, was_grinding: bool) {
    let key = keys::rail(g);
    m.set_input(key, 0, on(grinding));
    m.set_input(key, 1, on(was_grinding && !grinding));
}

/// `OffBoard` id 0 = on foot (`+716`, state 500), for the local player. `HandGrabs` id 0 (the
/// object's grab byte) is 0 in retail's free-skate capture and left at 0.
pub fn write_off_board(m: &mut MixMap, s: &AudioState) {
    write_off_board_at(m, 0, s);
}

/// [`write_off_board`] for Player-slot instance `g`.
pub fn write_off_board_at(m: &mut MixMap, g: u32, s: &AudioState) {
    m.set_input(keys::off_board(g), 0, on(s.local && s.on_foot));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn speed_words_clamp_like_retail() {
        assert_eq!(speed_word(0.0, SPEED_SCALES[0]), 0);
        assert_eq!(speed_word(-3.0, SPEED_SCALES[1]), 0);
        assert_eq!(speed_word(5.0, SPEED_SCALES[1]), (5.0 * f32::from_bits(SPEED_SCALES[1])) as i32);
        assert_eq!(speed_word(30.0, SPEED_SCALES[0]), 32767);
    }

    #[test]
    fn landing_buckets_follow_the_air_time() {
        let t = PlayerTuning::default();
        let mut c = Contacts::default();
        let mut s = AudioState { airborne: true, ..Default::default() };
        for (air, want) in [(0.2, 0), (0.7, 1), (1.3, 2)] {
            s.airborne = true;
            s.air_time = air;
            s.wheel_contact = [false; 4];
            c.update_buckets(&s, &t);
            s.airborne = false;
            s.wheel_contact = [true, true, false, false];
            c.update_buckets(&s, &t);
            assert_eq!(&c.bucket[..2], &[want, want], "air {air}");
        }
    }
}
