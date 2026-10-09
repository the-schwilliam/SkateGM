//! `SFXCTL_3DObjPos` (`sub_824AEC70` → `sub_824AEB28` / `sub_824AE6E0`, rates `sub_824AEE60`): the
//! 3-D input block a MixMap B lookup reads (mixmap-spec §7.3). Two listener frames:
//! - frame A, the camera: origin = camera position pulled back 0.25 m along the horizontal view
//!   direction (vault `camera` collection), direction = the view;
//! - frame B, the followed point (the skater's SystemReckoning position) with its facing.
//!
//! Inputs written: 0 = f32 |skater − emitter|, 1 = f32 |camera − emitter| (the camera itself, not
//! the pulled-back origin), 2 / 3 = azimuth of the emitter in frame B / A, 13 / 14 = f32 signed
//! relative speed against the skater's / the camera's velocity (|v_emitter − v_listener|, negated
//! while the distance shrinks), 15 = bit 0 active, bit 31 / bit 30 set when the sign of 13 / 14
//! flips (the MixMap's Doppler slew resets and clears them). Inactive: 0 = 1 = −1.0, 2 = 3 = 0,
//! bit 0 cleared. Input 10 (facing difference, `sub_824AE418`) is not written: no MixMap record
//! reads it.
//!
//! Azimuths are measured in the horizontal plane (retail drops the height) from the frame's
//! direction, clockwise seen from above, 65535 = 360°. Retail takes an `acos` of the normalised dot
//! product and mirrors it by the cross product's sign; we compute the same angle with `atan2`
//! (not bit-exact in the last unit).
use crate::mixmap::{MixMap, keys::pos};

/// Vault `camera` collection, field `0xA6F853B935E46E5F`: the frame-A pull-back (m).
pub const PULLBACK: f32 = 0.25;

/// The listener as the position controllers see it (`*(0x830CFDD4)`, `sub_8248CC08`): the camera
/// (position, view direction, velocity) and the followed point (position, facing, velocity).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Listener {
    pub camera: [f32; 3],
    pub view: [f32; 3],
    pub camera_velocity: [f32; 3],
    pub followed: [f32; 3],
    pub facing: [f32; 3],
    pub followed_velocity: [f32; 3],
}

/// One position controller's own memory (last distances and rates).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ObjPos {
    dist: [f32; 2],
    rate: [f32; 2],
    primed: bool,
}

fn sub(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn length(v: [f32; 3]) -> f32 {
    (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt()
}

/// Clockwise azimuth (65535 = 360°) of `target` seen from `origin` facing `dir`, in the
/// horizontal (x, z) plane; 0 when either vector has no horizontal length (retail: < 0.0001).
pub fn azimuth(dir: [f32; 3], origin: [f32; 3], target: [f32; 3]) -> i32 {
    let (dx, dz) = (dir[0], dir[2]);
    let (rx, rz) = (target[0] - origin[0], target[2] - origin[2]);
    if (dx * dx + dz * dz).sqrt() < 1e-4 || (rx * rx + rz * rz).sqrt() < 1e-4 {
        return 0;
    }
    // Right of the direction (y up): (−dz, 0, dx).
    let ahead = rx * dx + rz * dz;
    let right = rx * -dz + rz * dx;
    let mut turns = right.atan2(ahead) / std::f32::consts::TAU;
    if turns < 0.0 {
        turns += 1.0;
    }
    ((turns * 65535.0) as i32).clamp(0, 65535)
}

impl ObjPos {
    /// Write the block for an emitter (`None`: inactive). `flags15` is the controller's current
    /// input 15 (retail reads it back and ors in the new bits).
    pub fn write(&mut self, m: &mut MixMap, key: u32, l: &Listener, emitter: Option<([f32; 3], [f32; 3])>) {
        let flags15 = m.input(key, pos::FLAGS) as u32;
        let Some((position, velocity)) = emitter else {
            m.set_input(key, pos::AZ_CAMERA, 0);
            m.set_input_f32(key, pos::DIST_CAMERA, -1.0);
            m.set_input(key, pos::AZ_SKATER, 0);
            m.set_input_f32(key, pos::DIST_SKATER, -1.0);
            m.set_input(key, pos::FLAGS, (flags15 & !1) as i32);
            self.primed = false;
            return;
        };
        let mut w15 = flags15 | 1;
        m.set_input(key, pos::FLAGS, w15 as i32);
        m.set_input(key, 11, 0);
        // Frame A: the camera, origin pulled back along the horizontal view.
        let h = (l.view[0] * l.view[0] + l.view[2] * l.view[2]).sqrt();
        let origin_a = if h > 1e-4 {
            [l.camera[0] - l.view[0] / h * PULLBACK, l.camera[1], l.camera[2] - l.view[2] / h * PULLBACK]
        } else {
            l.camera
        };
        m.set_input(key, pos::AZ_CAMERA, azimuth(l.view, origin_a, position));
        m.set_input_f32(key, pos::DIST_CAMERA, length(sub(l.camera, position)));
        m.set_input(key, pos::AZ_SKATER, azimuth(l.facing, l.followed, position));
        m.set_input_f32(key, pos::DIST_SKATER, length(sub(l.followed, position)));
        // Rates.
        let d = [length(sub(l.followed, position)), length(sub(l.camera, position))];
        let mut s = [length(sub(velocity, l.followed_velocity)), length(sub(velocity, l.camera_velocity))];
        for i in 0..2 {
            if self.primed && self.dist[i] > d[i] {
                s[i] = -s[i];
            }
            let (p, n) = (self.rate[i], s[i]);
            if self.primed && ((p < 0.0 && n > 0.0) || (p > 0.0 && n < 0.0)) {
                w15 |= if i == 0 { 0x8000_0000 } else { 0x4000_0000 };
                m.set_input(key, pos::FLAGS, w15 as i32);
            }
        }
        self.dist = d;
        // Retail's first active frame compares against uninitialised memory; we start from 0
        // (no flip on the frame after activation).
        self.rate = if self.primed { s } else { [0.0; 2] };
        self.primed = true;
        m.set_input_f32(key, pos::SPEED_SKATER, s[0]);
        m.set_input_f32(key, pos::SPEED_CAMERA, s[1]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn azimuth_is_clockwise_in_the_horizontal_plane() {
        let ahead = [0.0, 0.0, -1.0];
        assert_eq!(azimuth(ahead, [0.0; 3], [0.0, 5.0, -5.0]), 0);
        assert_eq!(azimuth(ahead, [0.0; 3], [5.0, 0.0, 0.0]), 16383);
        assert_eq!(azimuth(ahead, [0.0; 3], [-5.0, 0.0, 0.0]), 49151);
        assert_eq!(azimuth(ahead, [0.0; 3], [0.0, 0.0, 5.0]), 32767);
        assert_eq!(azimuth(ahead, [0.0; 3], [0.0, 3.0, 0.0]), 0, "straight above: no horizontal offset");
    }

    #[test]
    #[ignore = "needs the private install data"]
    fn rates_are_signed_by_closing_and_flag_their_sign_flips() {
        let bytes = match std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../../assets/private/audio/aems/MixMapSK8.mxb")) {
            Ok(b) => b,
            Err(_) => panic!("missing private data: no MixMap"),
        };
        let mut m = MixMap::from_bytes(&bytes).unwrap();
        let key = crate::mixmap::keys::obj_pos2(0);
        let mut o = ObjPos::default();
        let l = Listener { view: [0.0, 0.0, -1.0], ..Default::default() };
        // Approaching the camera at 5 m/s along z.
        o.write(&mut m, key, &l, Some(([0.0, 0.0, -10.0], [0.0, 0.0, 5.0])));
        o.write(&mut m, key, &l, Some(([0.0, 0.0, -9.9], [0.0, 0.0, 5.0])));
        assert_eq!(f32::from_bits(m.input(key, pos::SPEED_CAMERA) as u32), -5.0);
        assert_eq!(m.input(key, pos::FLAGS) as u32, 1);
        // Receding: the sign flips, bit 30 (camera) and bit 31 (skater) set.
        o.write(&mut m, key, &l, Some(([0.0, 0.0, -10.0], [0.0, 0.0, -5.0])));
        assert_eq!(f32::from_bits(m.input(key, pos::SPEED_CAMERA) as u32), 5.0);
        assert_eq!(m.input(key, pos::FLAGS) as u32, 0xC000_0001);
        assert!((f32::from_bits(m.input(key, pos::DIST_CAMERA) as u32) - 10.0).abs() < 1e-6);
        o.write(&mut m, key, &l, None);
        assert_eq!(m.input(key, pos::FLAGS) as u32 & 1, 0);
        assert_eq!(f32::from_bits(m.input(key, pos::DIST_SKATER) as u32), -1.0);
    }
}
