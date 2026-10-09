//! `SFXObj_Reverb`'s preset selection with the reverb-zone emitters (spec
//! `audio-specs/aems-bus-leftovers-spec.md` §4): the per-frame update `sub_824DE548` and its
//! mode handlers — timed fade `sub_824DE850` (0), zone fade `sub_824DE970` (1), zone-to-zone
//! `sub_824DEAE8` (2) — the start `sub_824DE468`, the snap `sub_824DEDD8` and the zone blend with
//! the reverb outputs' rotation toward the zone `sub_824DEEF0`.
//!
//! The host hands in, per game frame, the active `.ems` nodes whose attribute type is 5 in the
//! emitter manager's list order ([`Zone`]: node identity, attribute key `+24`, the attribute's
//! preset key, the normalised distance `+12` — 0 inside the inner core, 1 at the edge — and the
//! zone position), the `audio_reverb` region key at the skater, and the camera (`*(0x83083C38) +
//! 0x2F078`: position `+48`, forward `+64`).
//!
//! [`EnvNetwork::update`] replaces [`EnvNetwork::request`] + [`EnvNetwork::frame`] for a host that
//! has zones (with none it is the same timed fade, but in retail's order: the frame that starts a
//! fade does not advance it, and the network starts on reverb01 on both sides as `sub_824DDE50`
//! sets it up, so the first region preset fades in over 1 s).
use super::env::{DEFAULT_PRESET, EnvNetwork, FADE};

/// The reverb outputs' azimuths outside a zone blend (0x82063B20 / 0x82256FD8).
const PANS: [f32; 2] = [270.0, 90.0];
/// 180 (0x821DE7BC), 1/π (0x822F8610), 360 (0x820B4118).
const DEG_180: f32 = 180.0;
const INV_PI: f32 = 0.318_309_87;
const DEG_360: f32 = 360.0;

/// One reverb-zone emitter node this frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Zone {
    /// The node's identity (retail compares node pointers).
    pub id: u64,
    /// Node `+24`: the attribute record key (two nodes of one attribute count as one zone).
    pub attribute: u64,
    /// The attribute record's reverb preset key (`sub_8248CDC8` → `sub_8248CE30`, `+8`).
    pub preset: u64,
    /// Node `+12`: the normalised distance (0 = inner core, 1 = edge).
    pub d: f32,
    /// The zone position (x, z) the blend rotates toward (node record `+8` / `+16`).
    pub position: [f32; 2],
    /// `sub_82488278`'s vfunc92 check on the attribute: a failing first candidate ends the query.
    pub enabled: bool,
}

/// The camera as `sub_824DEEF0` reads it (world position and forward; x, z are used).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Camera {
    pub position: [f32; 3],
    pub forward: [f32; 3],
}

/// Retail's selection state: keys `+400` / `+408`, sides `+416` / `+420`, the zone side `+424`,
/// the zone nodes `+428` / `+432` and per side the mode `+128` and timer `+204`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Selector {
    started: bool,
    pub current_key: u64,
    pub target_key: u64,
    pub current: usize,
    pub target: usize,
    pub zone_side: usize,
    pub nodes: [Option<Zone>; 2],
    pub modes: [u8; 2],
    pub timers: [f32; 2],
}

impl Selector {
    pub fn active(&self) -> bool {
        self.started
    }

    pub fn target_side(&self) -> usize {
        self.target
    }
}

/// `sub_82488278(mgr, skip)`: the first zone in list order that is not `skip`, if its attribute
/// passes the check (else none: the query does not look further).
pub fn query(zones: &[Zone], skip: Option<u64>) -> Option<Zone> {
    let z = zones.iter().find(|z| Some(z.id) != skip)?;
    z.enabled.then_some(*z)
}

impl EnvNetwork {
    /// `sub_824DDE50`: both sides on reverb01, side 0 at weight 1, side 1 at 0.
    fn init_selector(&mut self) {
        let key = if self.presets.contains_key(&DEFAULT_PRESET) { DEFAULT_PRESET } else { return };
        let p = self.presets[&key];
        self.last_sends = Some(super::env::Side::sends(&p));
        for (k, side) in self.sides.iter_mut().enumerate() {
            side.apply_scaled(key, &p, self.scale);
            side.weight.target = if k == 0 { 1.0 } else { 0.0 };
        }
        self.selector = Selector { started: true, current_key: key, target_key: key, ..Default::default() };
        self.sync();
    }

    /// Mirror the selector into `current` / `fade` (for [`EnvNetwork::key`] and diagnostics).
    fn sync(&mut self) {
        let s = &self.selector;
        self.current = s.current;
        self.fade = (s.current_key != s.target_key).then_some((s.target, s.timers[s.target]));
    }

    /// `sub_824DE468`: load `key` on the other side at weight 0 in `mode`.
    fn start(&mut self, key: u64, mode: u8) {
        let key = if self.presets.contains_key(&key) { key } else { DEFAULT_PRESET };
        let Some(p) = self.presets.get(&key).copied() else { return };
        let s = &mut self.selector;
        s.target_key = key;
        s.target = 1 - s.current;
        let t = s.target;
        s.modes[t] = mode;
        s.timers[t] = 0.0;
        self.last_sends = Some(super::env::Side::sends(&p));
        self.sides[t].apply_scaled(key, &p, self.scale);
        self.sides[t].weight.target = 0.0;
    }

    fn post(&mut self, side: usize, weight: f32, pans: [f32; 2]) {
        self.sides[side].post(weight, pans);
    }

    /// `sub_824DEDD8`: leave the zone blend at once.
    fn snap(&mut self) {
        let (cur, tgt) = (self.selector.current, self.selector.target);
        if self.selector.zone_side == cur {
            self.post(cur, 0.0, PANS);
            self.post(tgt, 1.0, PANS);
            self.selector.current = tgt;
            self.selector.current_key = self.selector.target_key;
        } else {
            self.post(tgt, 0.0, PANS);
            self.post(cur, 1.0, PANS);
            self.selector.target = cur;
            self.selector.target_key = self.selector.current_key;
        }
        self.selector.nodes = [None, None];
    }

    /// `sub_824DEEF0`: blend `side` (1 − d) against the other side (d) and turn `side`'s reverb
    /// outputs toward the zone. Without a camera retail calls the object's vfunc 28 (UNCERTAIN,
    /// not modelled: nothing changes).
    fn blend(&mut self, side: usize, zone: &Zone, camera: Option<&Camera>) {
        let Some(cam) = camera else { return };
        let d = self.selector.timers[side];
        let (fx, fz) = (cam.forward[0], cam.forward[2]);
        let (dx, dz) = (zone.position[0] - cam.position[0], zone.position[1] - cam.position[2]);
        let nf = 1.0 / (fx * fx + fz * fz).sqrt();
        let nd = 1.0 / (dx * dx + dz * dz).sqrt();
        let (fx, fz, dx, dz) = (fx * nf, fz * nf, dx * nd, dz * nd);
        let c = (dx * fx + dz * fz).clamp(-1.0, 1.0);
        let cross = dx * fz - dz * fx;
        // The vector acos (`sub_82453298`) → degrees: θ ∈ [0, 180], unsigned.
        let theta = INV_PI * (c.acos() * DEG_180);
        let (mut left, right) = (theta - 270.0, 90.0 - theta);
        if !(cross > 0.0) && theta < 90.0 {
            left = theta + 90.0;
        }
        let wrap = |mut a: f32| {
            if a > DEG_360 {
                a -= DEG_360;
            }
            if a < 0.0 {
                a += DEG_360;
            }
            a
        };
        let r = wrap(-d.mul_add(right, -90.0));
        let l = wrap(d.mul_add(left, 270.0));
        self.post(side, 1.0 - d, [l, r]);
        self.post(1 - side, d, PANS);
    }

    /// `sub_824DE548`, once per game frame (`dt` s): pick the preset from the reverb zones or the
    /// region key (0 = reverb01) and run the fade in progress.
    pub fn update(&mut self, dt: f32, region: u64, zones: &[Zone], camera: Option<&Camera>) {
        if !self.enabled() {
            return;
        }
        if !self.selector.started {
            self.init_selector();
            if !self.selector.started {
                return;
            }
        }
        let region = if region == 0 { DEFAULT_PRESET } else { region };
        let s = self.selector.clone();
        if s.current_key == s.target_key {
            match query(zones, None) {
                None => {
                    self.selector.nodes = [None, None];
                    if s.current_key != region {
                        self.start(region, 0);
                    }
                }
                Some(z1) if s.nodes[0].is_none() => {
                    self.selector.nodes[0] = Some(z1);
                    self.start(z1.preset, 1);
                    self.selector.zone_side = self.selector.target;
                }
                Some(z1) => match query(zones, Some(z1.id)) {
                    Some(z2) => {
                        let (k1, k2) = (z1.preset, z2.preset);
                        if k1 == k2 && s.current_key == k1 {
                            self.selector.target = s.current;
                        } else if k1 != k2 && s.current_key == k1 {
                            self.start(k2, 2);
                            self.selector.nodes[1] = Some(z2);
                        } else {
                            self.start(k1, 2);
                            self.selector.nodes[1] = Some(z1);
                        }
                    }
                    None => {
                        // The held node's distance as it is now (its record; the stored copy if it
                        // left the list).
                        let n0 = s.nodes[0].map(|n| zones.iter().find(|z| z.id == n.id).copied().unwrap_or(n));
                        if n0.is_some_and(|n| n.d > 0.0) && s.zone_side == s.current {
                            self.start(region, 1);
                            self.selector.zone_side = s.current;
                        }
                    }
                },
            }
        } else {
            match s.modes[s.target] {
                0 => self.timed(dt),
                1 => self.zone_fade(zones, camera),
                2 => self.zone_to_zone(zones, camera),
                _ => self.selector.target = s.current,
            }
        }
        if let Some(n) = &mut self.selector.nodes[0] {
            if let Some(z) = zones.iter().find(|z| z.id == n.id) {
                *n = *z;
            }
        }
        if let Some(n) = &mut self.selector.nodes[1] {
            if let Some(z) = zones.iter().find(|z| z.id == n.id) {
                *n = *z;
            }
        }
        self.sync();
    }

    /// `sub_824DE850`: the linear 1 s fade.
    fn timed(&mut self, dt: f32) {
        let (cur, tgt) = (self.selector.current, self.selector.target);
        self.selector.timers[tgt] += dt;
        let mut w = self.selector.timers[tgt] / FADE;
        let other = if w >= 1.0 {
            w = 1.0;
            0.0
        } else {
            1.0 - w
        };
        self.post(tgt, w, PANS);
        self.post(cur, other, PANS);
        if w >= 1.0 {
            self.selector.current = tgt;
            self.selector.current_key = self.selector.target_key;
        }
    }

    /// `sub_824DE970`: blend by the zone's distance; commit (or cancel) at d = 0.
    fn zone_fade(&mut self, zones: &[Zone], camera: Option<&Camera>) {
        let z1 = query(zones, None);
        let z2 = z1.and_then(|z| query(zones, Some(z.id)));
        let Some(z1) = z1 else { return self.snap() };
        let Some(held) = self.selector.nodes[0] else { return self.snap() };
        if held.id != z1.id {
            match z2 {
                None if held.attribute == z1.attribute => self.selector.nodes[0] = Some(z1),
                Some(z2) if held.id == z2.id => {}
                _ => return self.snap(),
            }
        }
        let node = self.selector.nodes[0].map(|n| zones.iter().find(|z| z.id == n.id).copied().unwrap_or(n)).unwrap();
        let side = self.selector.zone_side;
        self.selector.timers[side] = node.d;
        if node.d != 0.0 {
            return self.blend(side, &node, camera);
        }
        let s = &mut self.selector;
        if s.target == side {
            s.current = s.target;
            s.current_key = s.target_key;
        } else {
            s.target_key = s.current_key;
            s.target = s.current;
        }
        let cur = s.current;
        self.post(cur, 1.0, PANS);
        self.post(1 - cur, 0.0, PANS);
    }

    /// `sub_824DEAE8`: between two overlapping zones of different presets.
    fn zone_to_zone(&mut self, zones: &[Zone], camera: Option<&Camera>) {
        let z1 = query(zones, None);
        let z2 = z1.and_then(|z| query(zones, Some(z.id)));
        // No zone: retail calls the object's vfunc 28 (UNCERTAIN); we leave the blend as the snap does.
        let Some(z1) = z1 else { return self.snap() };
        let (cur, tgt) = (self.selector.current, self.selector.target);
        let Some(z2) = z2 else {
            if self.selector.nodes[0].map(|n| n.id) != Some(z1.id) {
                self.selector.nodes[0] = self.selector.nodes[1];
            }
            let Some(held) = self.selector.nodes[0] else { return self.snap() };
            if self.selector.current_key == held.preset {
                self.post(cur, 1.0, PANS);
                self.post(tgt, 0.0, PANS);
            } else {
                self.post(tgt, 1.0, PANS);
                self.post(cur, 0.0, PANS);
            }
            let s = &mut self.selector;
            s.nodes[1] = None;
            s.target = s.current;
            s.target_key = s.current_key;
            s.zone_side = s.current;
            return;
        };
        let ids = [z1.id, z2.id];
        let (Some(a), Some(b)) = (self.selector.nodes[0], self.selector.nodes[1]) else { return self.snap() };
        if !ids.contains(&a.id) || !ids.contains(&b.id) {
            return self.snap();
        }
        if a.attribute == b.attribute {
            self.post(cur, 1.0, PANS);
            self.post(tgt, 0.0, PANS);
            let s = &mut self.selector;
            s.zone_side = s.current;
            s.target = s.current;
            s.target_key = s.current_key;
            return;
        }
        let b = zones.iter().find(|z| z.id == b.id).copied().unwrap_or(b);
        if b.d == 0.0 {
            self.post(cur, 0.0, PANS);
            self.post(tgt, 1.0, PANS);
            let s = &mut self.selector;
            s.current = s.target;
            s.zone_side = s.target;
            s.current_key = s.target_key;
            s.nodes = [Some(b), None];
            return;
        }
        self.selector.timers[tgt] = b.d;
        self.blend(tgt, &b, camera);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bus::env::Preset;

    fn net() -> EnvNetwork {
        let mut env = EnvNetwork::default();
        let mut p = Preset([1.0; 44]);
        p.0[5] = 1.5;
        env.presets.insert(DEFAULT_PRESET, p);
        env.presets.insert(7, Preset([0.5; 44]));
        env.presets.insert(9, Preset([0.25; 44]));
        env
    }

    fn zone(id: u64, preset: u64, d: f32) -> Zone {
        Zone { id, attribute: id * 100, preset, d, position: [10.0, 0.0], enabled: true }
    }

    const CAM: Camera = Camera { position: [0.0, 1.5, 0.0], forward: [1.0, 0.0, 0.0] };

    #[test]
    fn without_zones_the_region_preset_fades_in_from_reverb01() {
        let mut env = net();
        env.update(1.0 / 60.0, 7, &[], Some(&CAM));
        // Started this frame on side 1 at weight 0; the fade advances from the next frame.
        assert_eq!((env.selector.target, env.selector.target_key, env.selector.modes[1]), (1, 7, 0));
        assert_eq!(env.sides[1].weight.target, 0.0);
        for _ in 0..30 {
            env.update(1.0 / 60.0, 7, &[], Some(&CAM));
        }
        assert!((env.sides[1].weight.target - 0.5).abs() < 1e-3);
        for _ in 0..31 {
            env.update(1.0 / 60.0, 7, &[], Some(&CAM));
        }
        assert_eq!((env.selector.current, env.selector.current_key), (1, 7));
        assert_eq!(env.key(), Some(7));
    }

    #[test]
    fn a_zone_blends_by_distance_turns_the_reverb_toward_it_and_commits_at_the_core() {
        let mut env = net();
        env.update(1.0 / 60.0, 0, &[], Some(&CAM)); // reverb01, nothing to do
        assert_eq!(env.selector.current_key, DEFAULT_PRESET);
        let z = |d| [zone(1, 9, d)];
        env.update(1.0 / 60.0, 0, &z(0.8), Some(&CAM));
        assert_eq!((env.selector.target_key, env.selector.zone_side, env.selector.modes[1]), (9, 1, 1));
        env.update(1.0 / 60.0, 0, &z(0.75), Some(&CAM));
        // Zone side weight 1 − d, the other d; the zone straight ahead (θ = 0) pulls both
        // outputs toward 0°: L = 270 + 0.75·(90 − 0)... = 337.5, R = 90 − 0.75·90 = 22.5.
        assert!((env.sides[1].weight.target - 0.25).abs() < 1e-6);
        assert!((env.sides[0].weight.target - 0.75).abs() < 1e-6);
        let [l, r] = env.sides[1].pans();
        assert!((l - 337.5).abs() < 0.05 && (r - 22.5).abs() < 0.05, "{l} {r}");
        assert_eq!(env.sides[0].pans(), PANS);
        env.update(1.0 / 60.0, 0, &z(0.0), Some(&CAM));
        assert_eq!((env.selector.current, env.selector.current_key), (1, 9));
        assert_eq!((env.sides[1].weight.target, env.sides[0].weight.target), (1.0, 0.0));
        assert_eq!(env.sides[1].pans(), PANS);
        // Leaving: the region preset loads on the other side (mode 1) and the zone side fades out
        // with d; outside the zone the snap commits to the region preset.
        env.update(1.0 / 60.0, 0, &z(0.4), Some(&CAM));
        assert_eq!((env.selector.target, env.selector.target_key, env.selector.zone_side), (0, DEFAULT_PRESET, 1));
        env.update(1.0 / 60.0, 0, &z(0.6), Some(&CAM));
        assert!((env.sides[1].weight.target - 0.4).abs() < 1e-6);
        env.update(1.0 / 60.0, 0, &[], Some(&CAM));
        assert_eq!((env.selector.current, env.selector.current_key), (0, DEFAULT_PRESET));
        assert_eq!((env.sides[0].weight.target, env.sides[1].weight.target), (1.0, 0.0));
        assert_eq!(env.selector.nodes, [None, None]);
    }

    #[test]
    fn the_rotation_unwraps_by_the_side_of_the_zone() {
        let mut env = net();
        env.update(1.0 / 60.0, 0, &[], Some(&CAM));
        env.selector.timers[1] = 1.0;
        // Zone 90° off the forward axis on either side: θ = 90 (unsigned); full blend (d = 1)
        // puts both outputs on θ.
        for z in [[0.0, 10.0], [0.0, -10.0]] {
            env.blend(1, &Zone { position: z, ..zone(1, 9, 1.0) }, Some(&CAM));
            let [l, r] = env.sides[1].pans();
            assert!((l - 90.0).abs() < 0.05 && (r - 90.0).abs() < 0.05, "{z:?}: {l} {r}");
        }
        // 45° (θ = 45): the cross sign picks L's unwrap (θ − 270 + 270 = 45, or θ + 90 + 270 → 45).
        for z in [[10.0, 10.0], [10.0, -10.0]] {
            env.blend(1, &Zone { position: z, ..zone(1, 9, 1.0) }, Some(&CAM));
            let [l, r] = env.sides[1].pans();
            assert!((l - 45.0).abs() < 0.05 && (r - 45.0).abs() < 0.05, "{z:?}: {l} {r}");
        }
    }
}
