//! The skater's clothing: retail's `SFXObj_Clothing` (controller `0x40010060`). Written from our
//! reading of the retail code (TU3, reference only; spec `audio-specs/aems-offboard-clothing-spec.md`):
//!
//! - process `sub_824DBB68`: cloth falls `sub_824DBF10`, push foley `sub_824DBBB8`, body slide
//!   `sub_824DC0E8`;
//! - cloth falls: `c_cloth_falls` (10 words, `Foley_Cloth`, constructor `sub_824B72D8`) posted on
//!   the bail's rising edge (`+676`) with w3 = trunc(`+328` / 5 × 1000), released at the end of the
//!   bail (`+677`) or when the bail flag drops; the level word kept for the update is max of that
//!   and trunc(`+672` / 5 × 1000);
//! - push foley: `sk8_foley` 73 on the push stroke's rising edge (`+337`; stopped by the push plant
//!   `+335` or a bail) and 74 on each push plant (`+335`; stopped by a bail), both on eEQChain
//!   bus 0 (`AEA5BA7E64515945`, created by the local player);
//! - body slide: `c_body_slide` (12 words, `Bodyslide`, constructor `sub_824B7070`; helper
//!   `sub_824DC2B0`): any of the six body-part slide records (`+528..+548`) non-zero is a slide;
//!   speed word trunc(|COM v| / 4.5 × 1000); type = AudioSurfaceMap word 10 (`+40`) of the slide's
//!   surface tag − 1 (part 0, overridden by part 1, else the first of parts 2..5 with a tag), 4
//!   with `+593`, 2 without a surface; posted above speed 350, held while sliding above 150;
//! - update `sub_824DCB98`: body slide `sub_824DC578`, cloth falls `sub_824DCA48`, push foley
//!   `sub_824DC7D8` (level 4, pitch 3).
//!
//! What retail's `sk8_foley` containers 62/63/64 played by caller `824D8164` are: the pedestrians'
//! footsteps (`SFXObj_PedestrianSFX`, vtable `0x822FCCC8`, process `sub_824D8078`), not the player.
use super::components::{Command, Slot};
use super::contacts::SpliceHost;
use super::state::NO_MATERIAL;
use super::tuning::PlayerTuning;
use super::{AudioState, Outputs, trunc_clamp};
use crate::splice::SoundId;

pub const CLOTH_FALLS: &str = "c_cloth_falls";
pub const BODY_SLIDE: &str = "c_body_slide";

const LEVEL: f32 = f32::from_bits(0x3800_0100); // 1/32767
const PITCH: f32 = f32::from_bits(0x3980_0000); // 1/4096
const DEGREES: f32 = f32::from_bits(0x3BB4_00B4); // 360/65535
/// `0x82256FE8`.
const THOUSAND: f32 = 1000.0;

/// The Clothing tuning (class `0xA867FBE3454326FF` `default` unless named; the defaults are the
/// retail values).
#[derive(Clone, Debug, PartialEq)]
pub struct ClothingTuning {
    /// `0A9A9BD1150FE838`: the cloth falls' speed divisor; eEQChain `E633C8F009CAEFFC`.
    pub falls_divisor: f32,
    pub falls_eq: i32,
    /// `6FD273157742AC4B` (stroke) / `616CE02AA10D596F` (plant), `sk8_foley`; eEQChain
    /// `AEA5BA7E64515945`.
    pub push_ids: [u32; 2],
    pub push_eq: u8,
    /// Class `6EBA5BCD3E38A98A` `default`: the slide speed divisor `787171ECD02DBBC3`, the start /
    /// hold thresholds `B021DB338B89D0F2` / `746EA8EF187E1571`, the w10 divisor `5D2F244E82CF7255`;
    /// eEQChain `4A022FEF9905D8F4`.
    pub slide_divisor: f32,
    pub slide_start: i32,
    pub slide_hold: i32,
    pub slide_body_divisor: f32,
    pub slide_eq: i32,
}

impl Default for ClothingTuning {
    fn default() -> Self {
        Self {
            falls_divisor: 5.0,
            falls_eq: 5,
            push_ids: [73, 74],
            push_eq: 0,
            slide_divisor: 4.5,
            slide_start: 350,
            slide_hold: 150,
            slide_body_divisor: 8.0,
            slide_eq: 7,
        }
    }
}

/// `sub_824DC2B0`: (slide type 0..4, speed word, sliding).
pub fn slide(s: &AudioState, t: &PlayerTuning, ct: &ClothingTuning) -> (i32, i32, bool) {
    let mut sliding = false;
    let mut flag = false;
    let mut tag = 0u32;
    for part in 0..6 {
        if s.body_slide[part].abs() > 0.0 {
            sliding = true;
            if s.body_slide_flag {
                flag = true;
            }
            let m = s.body_tag[part];
            if m != 0 && (part < 2 || tag == 0) {
                tag = m;
            }
        }
    }
    let speed = trunc_clamp((s.com_speed() / ct.slide_divisor) * THOUSAND, i32::MIN, i32::MAX);
    let material = if (1..=NO_MATERIAL + 1).contains(&tag) { (tag - 1).min(NO_MATERIAL) } else { NO_MATERIAL };
    let kind = if material == NO_MATERIAL {
        2
    } else if flag {
        4
    } else {
        t.surface_entry(material).map_or(2, |e| e[10])
    };
    (kind, speed, sliding)
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Clothing {
    /// `+36` last frame's bail, `+40` the cloth falls packet, `+44` its level word.
    was_bail: bool,
    falls: Option<Vec<i32>>,
    falls_level: i32,
    /// `+48` the stroke foley, `+52` the plant foley, `+56` last frame's stroke.
    stroke: Option<SoundId>,
    plant: Option<SoundId>,
    was_stroke: bool,
    /// `+60` the body slide packet.
    slide: Option<Vec<i32>>,
    /// Sounds started (diagnostics).
    pub starts: u64,
}

impl Clothing {
    /// `sub_824B72D8`'s words.
    pub fn falls_words(level: i32, ct: &ClothingTuning) -> Vec<i32> {
        let mut w = vec![0i32; 10];
        w[3] = level.clamp(0, 1000);
        w[4] = 25000;
        w[9] = ct.falls_eq.clamp(0, 32767);
        w
    }

    /// `sub_824B7070`'s words.
    pub fn slide_words(speed: i32, kind: i32, bail: bool, ct: &ClothingTuning) -> Vec<i32> {
        let mut w = vec![0i32; 12];
        w[3] = speed.clamp(0, 1000);
        w[4] = 25000;
        w[8] = kind.clamp(0, 4);
        w[9] = i32::from(bail);
        w[11] = ct.slide_eq.clamp(0, 32767);
        w
    }

    /// One frame before the MixMap tick (`sub_824DBB68`).
    pub fn process(&mut self, s: &AudioState, t: &PlayerTuning, ct: &ClothingTuning, host: &mut dyn SpliceHost) -> Vec<Command> {
        let mut cmds = Vec::new();
        self.cloth_falls(s, ct, &mut cmds);
        self.push_foley(s, ct, host);
        self.body_slide(s, t, ct, &mut cmds);
        cmds
    }

    /// `sub_824DBF10`.
    fn cloth_falls(&mut self, s: &AudioState, ct: &ClothingTuning, cmds: &mut Vec<Command>) {
        let rising = !self.was_bail && s.bail;
        let k = 1.0 / ct.falls_divisor;
        let body = trunc_clamp((k * s.body_speed) * THOUSAND, i32::MIN, i32::MAX);
        let limbs = trunc_clamp((s.limb_speed * k) * THOUSAND, i32::MIN, i32::MAX);
        self.falls_level = body.max(limbs);
        if self.falls.is_some() {
            if s.bail_end || !s.bail {
                self.falls = None;
                cmds.push(Command::Release { slot: Slot::ClothFalls });
            }
        } else if rising {
            let words = Self::falls_words(body, ct);
            cmds.push(Command::Post { slot: Slot::ClothFalls, class: CLOTH_FALLS, words: words.clone() });
            self.falls = Some(words);
        }
        self.was_bail = s.bail;
    }

    /// `sub_824DBBB8`.
    fn push_foley(&mut self, s: &AudioState, ct: &ClothingTuning, host: &mut dyn SpliceHost) {
        let stroke = s.push_stroke && !self.was_stroke;
        let block = [0.0, 1.0, 0.0, s.dt, if s.local { 1.0 } else { 0.0 }, 1.0];
        let route = crate::bus::Route { output: crate::bus::Output::Eq(ct.push_eq), create: s.local, owner_env: 0.0, mono: false };
        match self.stroke {
            None => {
                if stroke {
                    host.set_route(route);
                    self.stroke = host.start("sk8_foley", ct.push_ids[0], block);
                    self.starts += u64::from(self.stroke.is_some());
                }
            }
            Some(sound) => {
                if s.push_trigger || s.bail {
                    host.release(sound);
                    self.stroke = None;
                }
            }
        }
        self.was_stroke = s.push_stroke;
        if s.push_trigger {
            if let Some(old) = self.plant.take() {
                host.release(old);
            }
            host.set_route(route);
            self.plant = host.start("sk8_foley", ct.push_ids[1], block);
            self.starts += u64::from(self.plant.is_some());
        } else if s.bail {
            if let Some(old) = self.plant.take() {
                host.release(old);
            }
        }
    }

    /// `sub_824DC0E8`.
    fn body_slide(&mut self, s: &AudioState, t: &PlayerTuning, ct: &ClothingTuning, cmds: &mut Vec<Command>) {
        let (kind, speed, sliding) = slide(s, t, ct);
        if self.slide.is_some() {
            if !(speed > ct.slide_hold && sliding) {
                self.slide = None;
                cmds.push(Command::Release { slot: Slot::BodySlide });
            }
        } else if sliding && speed > ct.slide_start {
            let words = Self::slide_words(speed, kind, s.bail, ct);
            cmds.push(Command::Post { slot: Slot::BodySlide, class: BODY_SLIDE, words: words.clone() });
            self.slide = Some(words);
        }
    }

    /// One frame after the MixMap tick (`sub_824DCB98`); `out` = the Clothing outputs.
    pub fn update(&mut self, s: &AudioState, t: &PlayerTuning, ct: &ClothingTuning, out: &dyn Outputs, host: &mut dyn SpliceHost) -> Vec<Command> {
        let mut cmds = Vec::new();
        // sub_824DC578
        if let Some(w) = self.slide.as_mut() {
            let (kind, speed, _) = slide(s, t, ct);
            let body = trunc_clamp((s.body_speed / ct.slide_body_divisor) * THOUSAND, i32::MIN, i32::MAX);
            w[0] = 32767;
            w[1] = out.raw(0).clamp(0, 65535);
            w[2] = out.pitch(6).clamp(0, 8192);
            w[3] = speed.clamp(0, 1000);
            w[7] = out.level(5).clamp(0, 32767);
            w[8] = kind.clamp(0, 4);
            w[10] = body.clamp(0, 1000);
            w[9] = i32::from(s.bail);
            cmds.push(Command::Redeliver { slot: Slot::BodySlide, words: w.clone() });
        }
        // sub_824DCA48
        if let Some(w) = self.falls.as_mut() {
            w[1] = out.raw(0).clamp(0, 65535);
            w[2] = out.pitch(1).clamp(0, 8192);
            w[3] = self.falls_level.clamp(0, 1000);
            w[0] = 32767;
            w[7] = out.level(2).clamp(0, 32767);
            cmds.push(Command::Redeliver { slot: Slot::ClothFalls, words: w.clone() });
        }
        // sub_824DC7D8
        let block = [out.level(4) as f32 * LEVEL, out.pitch(3) as f32 * PITCH, out.raw(0) as f32 * DEGREES, s.dt, if s.local { 1.0 } else { 0.0 }, 1.0];
        for slot in [&mut self.stroke, &mut self.plant] {
            let Some(sound) = *slot else { continue };
            if host.alive(sound) {
                host.update(sound, block);
            } else {
                host.release(sound);
                *slot = None;
            }
        }
        cmds
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Log {
        started: Vec<(u32, crate::bus::Route)>,
        route: crate::bus::Route,
        live: Vec<SoundId>,
    }
    impl SpliceHost for Log {
        fn set_route(&mut self, route: crate::bus::Route) {
            self.route = route;
        }
        fn start(&mut self, _: &str, id: u32, _: [f32; 6]) -> Option<SoundId> {
            self.started.push((id, std::mem::take(&mut self.route)));
            self.live.push(self.started.len());
            Some(self.started.len())
        }
        fn update(&mut self, _: SoundId, _: [f32; 6]) {}
        fn alive(&self, sound: SoundId) -> bool {
            self.live.contains(&sound)
        }
        fn release(&mut self, sound: SoundId) {
            self.live.retain(|&s| s != sound);
        }
    }

    struct Out;
    impl Outputs for Out {
        fn level(&self, id: usize) -> i32 {
            1000 + id as i32
        }
        fn raw(&self, _: usize) -> i32 {
            100
        }
        fn pitch(&self, id: usize) -> i32 {
            4000 + id as i32
        }
    }

    #[test]
    fn a_bail_posts_the_cloth_falls_and_its_end_releases_them() {
        let (t, ct) = (PlayerTuning::default(), ClothingTuning::default());
        let mut c = Clothing::default();
        let mut h = Log::default();
        let s = AudioState { bail: true, body_speed: 3.0, limb_speed: 4.0, ..Default::default() };
        let cmds = c.process(&s, &t, &ct, &mut h);
        // w3 = trunc(0.2 × 3 × 1000) = 600 (the body part only); the update writes max(600, 800).
        assert_eq!(cmds, vec![Command::Post { slot: Slot::ClothFalls, class: CLOTH_FALLS, words: vec![0, 0, 0, 600, 25000, 0, 0, 0, 0, 5] }]);
        let up = c.update(&s, &t, &ct, &Out, &mut h);
        assert_eq!(up, vec![Command::Redeliver { slot: Slot::ClothFalls, words: vec![32767, 100, 4001, 800, 25000, 0, 0, 1002, 0, 5] }]);
        assert!(c.process(&s, &t, &ct, &mut h).is_empty(), "held through the bail");
        let end = AudioState { bail_end: true, ..s };
        assert_eq!(c.process(&end, &t, &ct, &mut h), vec![Command::Release { slot: Slot::ClothFalls }]);
        assert!(c.process(&end, &t, &ct, &mut h).is_empty(), "only on the next rising edge");
    }

    #[test]
    fn the_push_stroke_and_plant_play_the_push_foley_on_eq_bus_zero() {
        let (t, ct) = (PlayerTuning::default(), ClothingTuning::default());
        let mut c = Clothing::default();
        let mut h = Log::default();
        let mut s = AudioState { push_stroke: true, ..Default::default() };
        c.process(&s, &t, &ct, &mut h);
        c.process(&s, &t, &ct, &mut h);
        assert_eq!(h.started.iter().map(|x| x.0).collect::<Vec<_>>(), [73], "once per stroke");
        assert_eq!(h.started[0].1, crate::bus::Route { output: crate::bus::Output::Eq(0), create: true, owner_env: 0.0, mono: false });
        s.push_trigger = true;
        c.process(&s, &t, &ct, &mut h);
        assert_eq!(h.started.last().unwrap().0, 74);
        assert!(c.stroke.is_none(), "the plant stops the stroke foley");
    }

    #[test]
    fn a_body_slide_posts_above_350_and_holds_above_150() {
        let mut t = PlayerTuning::default();
        t.surface_table = vec![[0; 18]; 95];
        t.surface_table[40][10] = 1;
        let ct = ClothingTuning::default();
        let mut c = Clothing::default();
        let mut h = Log::default();
        let mut body_slide = [0.0; 6];
        body_slide[2] = 0.8;
        let mut body_tag = [0; 6];
        body_tag[2] = 41;
        let fast = AudioState { com_velocity: [2.0, 0.0, 0.0], body_slide, body_tag, bail: true, body_speed: 4.0, ..Default::default() };
        // |COM v| 2 m/s → 444 > 350; the slide's tag 41 → material 40 → AudioSurfaceMap +40 = 1.
        let cmds = c.process(&AudioState { bail: false, ..fast }, &t, &ct, &mut h);
        assert_eq!(cmds, vec![Command::Post { slot: Slot::BodySlide, class: BODY_SLIDE, words: vec![0, 0, 0, 444, 25000, 0, 0, 0, 1, 0, 0, 7] }]);
        let up = c.update(&fast, &t, &ct, &Out, &mut h);
        let Command::Redeliver { words, .. } = &up[0] else { panic!() };
        // w1 raw, w2 pitch(6), w3 speed, w7 level(5), w8 type, w9 bail, w10 trunc(4 / 8 × 1000).
        assert_eq!(words, &vec![32767, 100, 4006, 444, 25000, 0, 0, 1005, 1, 1, 500, 7]);
        let slow = AudioState { com_velocity: [0.5, 0.0, 0.0], bail: false, ..fast };
        assert_eq!(c.process(&slow, &t, &ct, &mut h), vec![Command::Release { slot: Slot::BodySlide }]);
        // With the +593 flag every slide is type 4.
        let flagged = AudioState { body_slide_flag: true, ..fast };
        assert_eq!(slide(&flagged, &t, &ct).0, 4);
        assert_eq!(slide(&AudioState { body_tag: [0; 6], ..fast }, &t, &ct).0, 2);
    }
}
