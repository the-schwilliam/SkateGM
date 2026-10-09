//! `SFXObj_Contacts`' board one-shots on the Splice player ([`crate::splice`]): the take-off pop,
//! its roll layer and the ollie voice, the landing impact, the per-wheel touchdowns and the manual
//! landing. Written from our reading of the retail code (TU3, reference only):
//!
//! - frame (`sub_824B8218`): manual landing `sub_824BB330` → touchdowns `sub_824B86E0` → process
//!   `sub_824B90D8` (pop `sub_824B9CC8` on entering the air with a trick, landing `sub_824BA630`);
//!   after the MixMap tick the update `sub_824BE1B8` rewrites every held sound's block;
//! - pop: selector 2 / 1 / 0 by the jump velocity (`+468`) over 0.42 / 0.25 (boneless and no-comply
//!   → 0); ids `[1097, 1098, 1099]`, `[1103, 1104, 1105]` on a hollow surface (`sub_824B9AD8` with
//!   the tier `sub_824BA310`); gain = trunc(level(2) × K[sel]) / 32767, K = `[0.5, 0.75, 1.0]`
//!   (`[0.58, 0.76, 0.99]` hollow); roll 1111 (above 4 m/s ground speed, or with an audio trick,
//!   gain level(7)); ollie 1096 (local player, level(12));
//! - landing: id 1095 (local player, level(13));
//! - touchdowns: per wheel the conditioner's landed latch (`sub_82772FD8`: set at a touchdown after
//!   more than 5 frames in the air) and the bridge's landing bucket (`+448`, 0..2); newly landed
//!   wheels pick the kind (0 = all four, 1 = a pair from nothing, 2 = the last pair, 3 = one wheel),
//!   the variant (the largest bucket) and the set `sub_824BA3F0` = `table[tier][3·kind + variant]`
//!   (tier = 2 × hollow surface + soft wheels; variant 2 of kinds 0..2 reads tier 0), with a second
//!   voice of variant 2 for bucket-2 landings; gain = trunc(level(3) × K[tier][3·kind + variant]) /
//!   32767 (`sub_824BEA80`);
//! - manual landing: after a manual, with 3–4 wheels down: kind 4, variant 0 (`sub_824BB330`);
//! - the hands on the deck (`sub_824B85B0` → [`super::step_on`]): 1124 / 1125 / 1126;
//! - the push foot's plant / lift (`sub_824BBB28` → `sub_824BB8D8` / `sub_824BBA00`, update
//!   `sub_824BF268`): `sk8_foley` by wheel 0's material kind, eEQChain bus 1 (session review
//!   2026-10-03 #2);
//! - the body regions' impacts (`sub_824BC188`): collision messages per region of the ragdoll
//!   (session review 2026-10-03 #4).
//!
//! The block of every sound: [level/32767, pitch(1)/4096, raw(0) × 360/65535, dt, 1 for the local
//! player's 3-D voices else 0, 1].
//!
//! Buses (`audio-specs/aems-eqchain-buses-spec.md` §3, §5): the pop plays through an owner
//! one-shot bus (`sub_82488DD0`: env send at Contacts level(14) as of the post, then eEQChain bus 0),
//! the touchdowns and the manual landing through one at level(15) (bus 0); the landing impact goes
//! to bus 1, the foot taps and scuffs to bus 1; each resolve may re-roll the bus's EQ (create =
//! the local player, owner byte +72 — UNCERTAIN meaning). The roll and ollie voices' bus is not
//! recovered (SFX Master here).
//!
//! Not modelled: the cartoon DLC sets (bank 8), the body poster's first-hit torso message
//! (`sub_824BCEB0`) and Hall of Meat layer, the step-on force (`+500..+503`: `+720` / `+814` are not published) and which
//! update rewrites the manual-landing holder `+36` (taken as a touchdown voice of kind 4).
use super::collision::Message;
use super::state::NO_MATERIAL;
use super::tuning::PlayerTuning;
use super::{AudioState, Outputs};
use crate::splice::SoundId;

/// What the component needs from the Splice player (the host implements it over the runtime).
pub trait SpliceHost {
    /// The bus the following starts play into (the poster's eEQChain bus / owner bus).
    fn set_route(&mut self, _route: crate::bus::Route) {}
    /// The FootStep SubMix the next start plays through (`player::footsteps`: per foot sound
    /// slot `Sub0 → HI20 → LI20 → PI20 → Sen0 env → Pn21 → Sen0` SFX Master, latched at the
    /// start); applies to the next start only, like the route. Hosts without per-sound submixes
    /// ignore it (the route's `owner_env` still carries the env send).
    fn set_submix(&mut self, _submix: Option<super::footsteps::Submix>) {}
    fn start(&mut self, bank: &str, id: u32, block: [f32; 6]) -> Option<SoundId>;
    fn update(&mut self, sound: SoundId, block: [f32; 6]);
    fn alive(&self, sound: SoundId) -> bool;
    fn release(&mut self, sound: SoundId);
}

/// The Contacts tuning (vault class `0xC26949FCB638A2CA` `default`; the exported values are the
/// retail ones, used when the install's tuning lacks them).
#[derive(Clone, Debug, PartialEq)]
pub struct ContactsTuning {
    pub pop_ids: [u32; 3],
    pub pop_ids_hollow: [u32; 3],
    pub pop_gain: [f32; 3],
    pub pop_gain_hollow: [f32; 3],
    /// Jump-velocity thresholds of selectors 2 / 1 (`0xF2A1E273ABB8E9AB` / `0xD7758385CDB8DC26`).
    pub pop_high: f32,
    pub pop_low: f32,
    /// Roll speed thresholds (m/s, `0x58523180E1AD61B4` / `0xA73073D3A33E35AE` / `0xFB71DF2C85928859`)
    /// and ids (`0x7A745D81E4BCABC3` / `0x537C97E4F64A0EE2` / `0x9C4CDCF0DD84C281`).
    pub roll_speeds: [f32; 3],
    pub roll_ids: [u32; 3],
    pub ollie_id: u32,
    pub landing_id: u32,
    /// Touchdown sets per tier (`0x5A93802D11B00173`, `0xA0F86FEEA9C2412F`, `0x797EC34502499EC3`,
    /// `0xAB0D92058B4293A7`) and their gains (`0xCEA5AFA8BA170B07`, `0x951AD53718030327`,
    /// `0x068C8C5EBEC1B45F`, `0x6823F4910A1882AD`), index 3·kind + variant.
    pub touch_ids: [[u32; 13]; 4],
    pub touch_gain: [[f32; 15]; 4],
    /// The conditioner's wheel-impact divisor (`0x3D399FE04952B425`, not used by the sounds).
    pub wheel_impact_divisor: f32,
    /// Collision posters (`audio_export.collision_tuning` `posters`): the grind start
    /// (`sub_824BB0E0`, Class_grind default `0x086B66C3D4FFEE8F` / `0xB2ACAFDBCD963C93`, cooldown
    /// the image's 0.5 s), the landing pair (`sub_824BA630`: air divisor `0x6D68BC2D1A23C29A`, board
    /// material `0x85FDC8BF696BCA5C`, tier split / high `0x3462CBB16DCA696E` / `0x590495E420B399E5`,
    /// level scales `0x31DEEF8FA219950F` / `0x0EC6EEF5366FEA85`) and the deck impact (`sub_824BD000`:
    /// cooldown `0x27D3C5DC3282B59D`, in frames).
    pub grind_split: f32,
    pub grind_high: f32,
    pub grind_cooldown: f32,
    pub landing_air: f32,
    pub landing_board: i32,
    pub landing_split: f32,
    pub landing_high: f32,
    pub landing_scale: [f32; 2],
    pub deck_cooldown: f32,
    /// Foot taps on the deck (`sub_824B95A0` / `sub_824B9268`, collection
    /// `0x923CCB46EF5BF5BA`/`0xF1647BFB782BE97F`): minimum time out of the deck box (ms × 0.001),
    /// minimum toe speed, variant thresholds, ids per kind (first foot, second foot, both,
    /// special) and the soft variants (`+484`).
    pub tap_off_ms: f32,
    pub tap_speed: f32,
    pub tap_mid: f32,
    pub tap_high: f32,
    pub tap_ids: [[u32; 3]; 4],
    pub tap_ids_soft: [[u32; 3]; 3],
    /// Shoe scuffs (`sub_824B9948` / `sub_824B97A8`, Contacts default): toe XZ speed threshold
    /// (× 0.01) and the `sk8_foley` ids per foot (and soft).
    pub scuff_speed: f32,
    pub scuff_ids: [u32; 2],
    pub scuff_ids_soft: [u32; 2],
    /// The hands on the deck (`player::step_on`, `sub_824B85B0`).
    pub step_on: super::step_on::StepOnTuning,
    /// The push foot's plant / lift (`sub_824BBB28`): `sk8_foley` ids by the material kind of wheel 0
    /// (AudioSurfaceMap word 5, `sub_82494EB8`; kinds 0..4, Contacts `default` fields plant
    /// `1A5D3CDBA6C160D0` `6C93C9BAD7B07C6B` `9CCABF46584CA16C` `57553DC3A33C9B38`
    /// `4F138972C957C8AF`, lift `2D97D30AEA78BCE2` `73CB69882A79481B` `767F6CAEACB748C8`
    /// `A17BA1994B766B55` `8D8EF475983B33A8`) and their eEQChain bus (class `42AFE160E647167C`
    /// `default` field `748CBC9727A5347F`).
    pub plant_ids: [u32; 5],
    pub lift_ids: [u32; 5],
    pub plant_eq: u8,
    /// The body poster (`sub_824BC188`, class `6EBA5BCD3E38A98A` `default`): the per-region cooldown
    /// (`6DD85F43C1B6E6AA`, frames) and the cloth / face thresholds `sub_824BCCF8` reads from the
    /// Contacts object `+296..+332`: material 110 on the head / torso (low, high: `D12003A60E987B9D`
    /// / `FA2AA5A0C0481D00`, `AFA4B5090F1BCF36` / `00960FEDB3EFEE9C`), 111 on the limbs
    /// (`3695327CFB5E1AC3` / `35FEE8A95523D812`), 112 (the face) at tier 0 (`076E9081CA1759E9` /
    /// `DF539915EB7E883E`) and tier 1 (`8E3025BAA686F721` / `504D3B73505972D4`).
    pub body_cooldown: f32,
    /// The audio-state bridge's speed graph (`sub_824B0DA8`, the holder `*(0x830CFDA4)+36` = class
    /// `6EBA5BCD3E38A98A` `default` field `8B164823E008749C`, a `Sk8::PointNegGraphData8`): the
    /// eight region impacts are multiplied by it at the previous frame's |COM v|
    /// ([`super::AudioState::com_speed_216`]) before the body poster reads them.
    pub body_speed_curve: SpeedGraph8,
    pub body_110: [[f32; 2]; 2],
    pub body_111: [f32; 2],
    pub body_112: [[f32; 2]; 2],
}

impl Default for ContactsTuning {
    fn default() -> Self {
        Self {
            pop_ids: [1097, 1098, 1099],
            pop_ids_hollow: [1103, 1104, 1105],
            pop_gain: [0.5, 0.75, 1.0],
            pop_gain_hollow: [0.58, 0.76, 0.99],
            pop_high: 0.42,
            pop_low: 0.25,
            roll_speeds: [12.0, 8.0, 4.0],
            roll_ids: [1111, 1111, 1111],
            ollie_id: 1096,
            landing_id: 1095,
            touch_ids: [
                [1051, 1052, 1053, 1054, 1055, 1056, 1057, 1058, 1059, 1060, 1061, 1127, 1050],
                [1073, 1074, 1075, 1076, 1077, 1078, 1079, 1080, 1081, 1082, 1128, 1129, 1130],
                [1062, 1063, 1064, 1065, 1066, 1067, 1068, 1069, 1070, 1071, 1131, 1132, 1072],
                [1084, 1085, 1086, 1087, 1088, 1089, 1090, 1091, 1092, 1093, 1133, 1134, 1094],
            ],
            touch_gain: [
                [0.84, 1.0, 0.89, 1.0, 0.78, 0.76, 1.0, 0.7, 0.79, 0.82, 0.88, 0.76, 0.26, 0.38, 0.47],
                [1.0, 1.0, 0.72, 0.77, 0.98, 0.8, 0.9, 0.98, 0.73, 1.0, 0.88, 0.83, 0.88, 0.55, 0.4],
                [0.65, 1.0, 0.94, 0.59, 1.0, 0.84, 0.81, 0.97, 0.73, 0.64, 0.68, 0.63, 0.42, 0.42, 0.01],
                [0.73, 0.99, 0.56, 0.79, 0.99, 0.59, 0.74, 0.91, 0.55, 0.58, 0.61, 0.59, 0.4, 0.4, 0.4],
            ],
            wheel_impact_divisor: 9.0,
            grind_split: 0.25,
            grind_high: 0.5,
            grind_cooldown: 0.5,
            landing_air: 0.4,
            landing_board: 95,
            landing_split: 0.1,
            landing_high: 0.3,
            landing_scale: [0.65, 1.0],
            deck_cooldown: 6.0,
            tap_off_ms: 25.0,
            tap_speed: 0.0,
            tap_mid: 2.0,
            tap_high: 5.0,
            tap_ids: [[1112, 1113, 1114], [1115, 1116, 1117], [1118, 1119, 1120], [1176, 1177, 1178]],
            tap_ids_soft: [[1159, 1160, 1161], [1162, 1163, 1164], [1165, 1166, 1167]],
            scuff_speed: 35.0,
            scuff_ids: [95, 94],
            scuff_ids_soft: [97, 96],
            step_on: super::step_on::StepOnTuning::default(),
            plant_ids: [84, 88, 92, 80, 76],
            lift_ids: [85, 89, 93, 81, 77],
            plant_eq: 1,
            body_cooldown: 15.0,
            body_speed_curve: SpeedGraph8::BODY_SPEED,
            body_110: [[0.75, 1.25], [0.7, 1.25]],
            body_111: [0.65, 1.25],
            body_112: [[0.05, 0.3], [0.3, 0.55]],
        }
    }
}

/// An 8-point vault graph (`Sk8::PointNegGraphData8`: x at record `+16`, y at `+48`) evaluated by
/// `sub_82481E10(8, x, y, v)`: below x0 → y0, from x7 on → y7, else the linear piece of the first
/// i with v < x[i] (y[i] where two x coincide), slope first, `fmadds` order.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SpeedGraph8 {
    pub x: [f32; 8],
    pub y: [f32; 8],
}

impl SpeedGraph8 {
    /// The stock vault's bridge speed graph (class `6EBA5BCD3E38A98A` `default`, field
    /// `8B164823E008749C`; the same words read from the running game at `[[[0x830CFDA4]+36]+4]`):
    /// x 0 … 0.946 m/s, y 1.0 … 5.0.
    pub const BODY_SPEED: SpeedGraph8 = SpeedGraph8::from_bits(
        [0x0000_0000, 0x3EBB_9F41, 0x3EE5_50DE, 0x3F05_6B91, 0x3F17_C3F8, 0x3F3D_B4F8, 0x3F5C_FA27, 0x3F72_3DB4],
        [0x3F80_0000, 0x3F99_999A, 0x3FBE_2BE0, 0x3FF5_0753, 0x401B_6DB5, 0x4066_6666, 0x4092_4921, 0x40A0_0000],
    );

    pub const fn from_bits(x: [u32; 8], y: [u32; 8]) -> Self {
        let mut g = SpeedGraph8 { x: [0.0; 8], y: [0.0; 8] };
        let mut i = 0;
        while i < 8 {
            g.x[i] = f32::from_bits(x[i]);
            g.y[i] = f32::from_bits(y[i]);
            i += 1;
        }
        g
    }

    /// `sub_82481E10` with eight points.
    pub fn eval(&self, v: f32) -> f32 {
        let (x, y) = (&self.x, &self.y);
        if v < x[0] {
            return y[0];
        }
        if !(v < x[7]) {
            return y[7];
        }
        for i in 1..8 {
            if v < x[i] {
                let dx = x[i] - x[i - 1];
                if dx > 0.0 {
                    return ((y[i] - y[i - 1]) / dx).mul_add(v - x[i - 1], y[i - 1]);
                }
                return y[i];
            }
        }
        y[0]
    }
}

/// The body poster's material of a body region (`sub_824BCBA0`: head 97, torso 98, arms 100, legs
/// 99), its cloth contact (`+112`: none / denim 109 / skin 107 / denim 108) and its pad contact
/// (`+120`: 110, the face 112 with the face point in contact, 111 on the limbs). The Hall of Meat
/// layer (`+128`, materials 102..106 while the global `+859` byte is set) is not modelled.
pub fn body_materials(region: usize, face: bool) -> (i32, i32, i32) {
    match region {
        0 => (97, NO_MATERIAL as i32, if face { 112 } else { 110 }),
        1 => (98, 109, 110),
        2 | 3 => (100, 107, 111),
        _ => (99, 108, 111),
    }
}

/// The bank every Contacts sound plays from (the vault fields' type).
pub const BANK: &str = "Skate_Collisions";
/// The shoe scuffs' bank (retail Splice bank 7; the vault type `sk82_cloth_foley`).
pub const FOLEY: &str = "sk8_foley";

const DEGREES: f32 = f32::from_bits(0x3BB4_00B4); // 360 / 65535
const PITCH: f32 = f32::from_bits(0x3980_0000); // 1 / 4096
const LEVEL: f32 = f32::from_bits(0x3800_0100); // 1 / 32767

#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct Touch {
    sound: SoundId,
    kind: usize,
    variant: usize,
    tier: usize,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Contacts {
    /// `+424` frames since the last landing (`sub_824B9CC8` needs ≥ 2).
    frames: u32,
    /// `+120` airborne last frame, `+122` grinding last frame, `+121` in a manual.
    was_air: bool,
    was_grinding: bool,
    in_manual: bool,
    /// The conditioner (`sub_82772FD8`): previous contact, frames in the air, landed latch `+464`.
    prev_contact: [bool; 4],
    air_frames: [u32; 4],
    landed: [bool; 4],
    /// `+132..+135` wheels already counted, `+136` the second-voice memory.
    counted: [bool; 4],
    memory_136: bool,
    /// Held sounds: pop `+60` (selector `+64`, hollow `+68`), roll `+96`, ollie `+52`, landing
    /// `+56`, touchdowns `+140`.., second voice `+236`, manual landing `+36`.
    pop: Option<(SoundId, usize, bool)>,
    roll: Option<SoundId>,
    ollie: Option<SoundId>,
    landing: Option<SoundId>,
    touch: [Option<Touch>; 4],
    second: Option<Touch>,
    manual: Option<Touch>,
    /// Sounds started (diagnostics).
    pub starts: u64,
    /// `+340` the last air phase's time (state `+236` latched while airborne).
    air_latched: f32,
    /// `+124` grind-start cooldown (s), `+292` deck-impact cooldown (frames).
    grind_cooldown: f32,
    deck_cooldown: f32,
    taps: FootTaps,
    /// Shoe scuffs `+112` (foot 1) / `+116` (foot 0).
    scuffs: [Option<SoundId>; 2],
    /// Collision messages posted this frame (the host hands them to the
    /// [`super::collision::CollisionManager`] before its process).
    pub outbox: Vec<Message>,
    /// The hands on the deck (`sub_824B85B0` / `sub_824BF728`).
    pub step_on: super::step_on::StepOn,
    /// Contacts level(14) / level(15) as of the last update: the owner buses' env sends.
    owner_levels: [i32; 2],
    /// The local player (the buses' create flag), as of the last process.
    local: bool,
    /// `+123` the push foot is down (`sub_824BBB28`), `+84` / `+92` the plant / lift sounds.
    planted: bool,
    plant: Option<SoundId>,
    lift: Option<SoundId>,
    /// `+260..+280` the body regions' cooldowns (frames, `sub_824BC188`).
    body_cooldown: [f32; 6],
    /// Body-poster messages posted (diagnostics) and a running FNV-1a digest of them (every field,
    /// in posting order): two runs posted the same messages iff counts and digests agree.
    pub body_posts: u64,
    pub body_digest: u64,
    /// The body poster's console cadence: `Some(n)` = n console frames end in this process (the
    /// host's `mixmap::cadence`; 0 on the 60 Hz steps between them), so the poster runs n times
    /// here, once per console frame as retail's per-rendered-frame `sub_824BC188` does on the 30 fps
    /// console (15-frame cooldown = 0.5 s at any real frame rate). `None`: once per process, the
    /// the tests (the game's host always passes `Some`).
    pub body_calls: Option<usize>,
    /// The deck-impact poster (`sub_824BD000`) the same way: `Some(n)` runs it n times in this
    /// process (its 6-frame cooldown in console frames = 0.2 s), `None` once per process (before
    /// 2026-10-03; the tests). Its messages so far and their digest (diagnostics).
    pub deck_calls: Option<usize>,
    pub deck_posts: u64,
    pub deck_digest: u64,
    /// The push foot's plant / lift (`sub_824BBB28`) and the body poster (`sub_824BC188`). The game's
    /// host always turns them on; off only isolates the rest in tests.
    pub plant_lift_on: bool,
    pub body_on: bool,
    /// The bridge's speed graph on the region impacts ([`ContactsTuning::body_speed_curve`] at
    /// [`AudioState::com_speed_216`]; off: the impacts as the conditioner wrote them, the tests).
    /// The game's host always turns it on.
    pub body_speed_on: bool,
    /// Diagnostics (the e2e harness): when `Some`, every body-poster message with its region and
    /// the impact the poster read.
    pub body_log: Option<Vec<(usize, f32, Message)>>,
    /// `+422`: armed while the skater is not bailing; the body poster's first message of a bail
    /// calls the bail grunt helper `sub_824BF5F8` and disarms it. The helper speaks only for a
    /// non-local skater (its SkaterSpeech record gets message 8206 / 115: the NPC's bail grunt),
    /// so [`Self::bail_grunt`] is read only by the NPC host.
    grunt_armed: bool,
    /// The bail grunt is due (set by the body poster; the NPC host takes it).
    pub bail_grunt: bool,
}

/// The route of a poster's sounds: eEQChain bus `bus` (re-rolled on first use by the local
/// player), through an owner bus whose env send is `env` (Q15) when given.
fn route(bus: u8, s: &AudioState, env: Option<i32>) -> crate::bus::Route {
    crate::bus::Route {
        output: crate::bus::Output::Eq(bus),
        create: s.local,
        owner_env: env.map_or(0.0, |l| l as f32 * crate::dsp::INV_32767),
        mono: false,
    }
}

/// FNV-1a over a collision message's fields (diagnostics: [`Contacts::body_digest`]).
fn body_digest(mut h: u64, m: &Message) -> u64 {
    if h == 0 {
        h = 0xCBF2_9CE4_8422_2325;
    }
    let words = [m.material[0] as u32, m.material[1] as u32, m.tier[0] as u32, m.tier[1] as u32, m.position[0].to_bits(), m.position[1].to_bits(), m.position[2].to_bits(), m.level[0] as u32, m.level[1] as u32, u32::from(m.local)];
    for w in words {
        for b in w.to_le_bytes() {
            h = (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01B3);
        }
    }
    h
}

/// `sub_824B95A0`'s memory: time out of the deck box per foot (`+360` foot 0, `+352` foot 1) and
/// of both (`+368`), the step counter `+364`, last frame's feet (`+356` foot 0, `+348` foot 1), the
/// hippy-jump latch `+476` with its bucket `+480`, and the tap sounds `+100..+108` by mode.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct FootTaps {
    out_time: [f32; 2],
    both_time: f32,
    count: u32,
    prev: [bool; 2],
    special: bool,
    bucket: u32,
    sounds: [Option<SoundId>; 3],
}

fn start_block(dt: f32) -> [f32; 6] {
    [0.0, 1.0, 0.0, dt, 1.0, 1.0]
}

impl Contacts {
    /// `sub_824BA310`: 2 × hollow (AudioSurfaceMap word 2 of wheel 0's material) + soft wheels.
    pub fn tier(s: &AudioState, t: &PlayerTuning) -> usize {
        let material = s.wheel_material[0];
        let hollow = material < NO_MATERIAL && t.surface_entry(material).is_some_and(|e| e[2] != 0);
        // `sub_824B23C8`: the state carries its value (the local player's +684; NPCs: world::skaters).
        let soft = s.soft_wheels;
        usize::from(hollow) * 2 + usize::from(soft)
    }

    /// `sub_824BA3F0`: (set id, unmasked tier).
    fn set(&self, s: &AudioState, t: &PlayerTuning, c: &ContactsTuning, kind: usize, variant: usize) -> (u32, usize) {
        let tier = Self::tier(s, t);
        let used = if kind <= 2 && variant >= 2 { 0 } else { tier };
        let idx = (3 * kind + variant).min(12);
        (c.touch_ids[used.min(3)][idx], tier)
    }

    /// The conditioner's per-wheel landed latches (+464), once per frame.
    fn condition(&mut self, s: &AudioState) {
        for w in 0..4 {
            let now = s.wheel_contact[w];
            if !self.prev_contact[w] && self.air_frames[w] > 5 {
                self.landed[w] = false;
            }
            if now && !self.prev_contact[w] && self.air_frames[w] > 5 {
                self.landed[w] = true;
            }
            self.prev_contact[w] = now;
            self.air_frames[w] = if now { 0 } else { self.air_frames[w] + 1 };
        }
    }

    /// One frame before the MixMap tick. `buckets` = the bridge's `+448` per wheel. Collision
    /// messages land in [`Contacts::outbox`].
    pub fn process(&mut self, s: &AudioState, buckets: [u32; 4], t: &PlayerTuning, c: &ContactsTuning, host: &mut dyn SpliceHost) {
        self.local = s.local;
        self.condition(s);
        self.foot_taps(s, c, host);
        self.scuffs(s, c, host);
        let manual_landed = self.manual_landing(s, t, c, host);
        self.touchdowns(s, buckets, manual_landed, t, c, host);
        // sub_824B90D8
        self.frames = self.frames.saturating_add(1);
        let air = s.airborne;
        if !self.was_air {
            if air && s.trick_active && !matches!(s.audio_trick, -1 | 31 | 32 | 35 | 36) && !self.was_grinding {
                self.pop(s, t, c, host);
            }
        } else if !air && !s.grinding {
            self.land(s, t, c, host);
        }
        if air {
            self.air_latched = s.air_time;
        }
        if s.grinding && !self.was_grinding {
            self.grind_start(s, t, c);
        }
        self.was_air = air;
        self.was_grinding = s.grinding;
        // sub_824B8218's order after the process: the plant / lift `sub_824BBB28`, the body
        // `sub_824BC188`, the deck `sub_824BD000`.
        if self.plant_lift_on {
            self.plant_lift(s, t, c, host);
        }
        if self.body_on {
            for _ in 0..self.body_calls.unwrap_or(1) {
                self.body(s, t, c);
            }
        }
        for _ in 0..self.deck_calls.unwrap_or(1) {
            self.deck(s, t, c);
        }
        self.step_on.process(s, &c.step_on, host);
    }

    /// `sub_82494EB8`: the plant / lift kind of a material, AudioSurfaceMap word 5 (`+20`; entry
    /// 94 for 94..142); 0 for no material (`+620` ≥ 143) or without the table.
    pub fn plant_kind(material: u32, t: &PlayerTuning) -> usize {
        if material >= NO_MATERIAL {
            return 0;
        }
        t.surface_entry(material).map_or(0, |e| usize::try_from(e[5]).unwrap_or(usize::MAX))
    }

    /// `sub_824BBB28`: the push foot planting (`+333 || +334` rising while `+123` is clear) plays
    /// the plant (`sub_824BB8D8`), lifting it again the lift (`sub_824BBA00`): `sk8_foley` by wheel
    /// 0's material kind (kinds above 4 post id 0), through the eEQChain bus `plant_eq`, each
    /// releasing its own previous sound first; block [0, 1, 0, dt, 1, 1], then
    /// [level(6), pitch(1), raw(0), dt, 0, 1] from the update `sub_824BF268`.
    fn plant_lift(&mut self, s: &AudioState, t: &PlayerTuning, c: &ContactsTuning, host: &mut dyn SpliceHost) {
        if s.push_planted == self.planted {
            return;
        }
        let kind = Self::plant_kind(s.wheel_material[0], t);
        let (ids, slot) = if s.push_planted { (&c.plant_ids, &mut self.plant) } else { (&c.lift_ids, &mut self.lift) };
        let id = ids.get(kind).copied().unwrap_or(0);
        if let Some(old) = slot.take() {
            host.release(old);
        }
        host.set_route(route(c.plant_eq, s, None));
        *slot = host.start(FOLEY, id, start_block(s.dt));
        self.starts += u64::from(slot.is_some());
        self.planted = s.push_planted;
    }

    /// `sub_824BC188`: the body regions' impacts. With the rider bailing until the end of the bail
    /// (`+676` && `+677` stops it, cooldowns included), per region 0..5 with an impact (`+496 + 4i`
    /// > 0) and no cooldown: the region's material ([`body_materials`]) against the surface it
    /// touches (`+560 + 4i` tag − 1, 143 without one), each by its impact band; nothing when both
    /// are under their floors. Otherwise the cooldown restarts and it posts the pair (a band-2
    /// hit adds the second message at tier 1 × the window scale, as the deck), the cloth contact
    /// against nothing at tier 0 with the region's level, and the pad contact by
    /// `sub_824BCCF8`'s thresholds. Cooldowns count down by min(time scale, 1) per frame.
    /// Not modelled: the first-hit torso message (`sub_824BCEB0`, gated by an unidentified game
    /// global at `*(0x82083C38) + 0x2FCB4`), the Hall of Meat layer and the bail flags `+406..+416`
    /// (they feed game events, not sounds).
    fn body(&mut self, s: &AudioState, t: &PlayerTuning, c: &ContactsTuning) {
        if !s.bail {
            self.grunt_armed = true;
        }
        if s.bail && s.bail_end {
            return;
        }
        let ct = &t.collision;
        let none = NO_MATERIAL as i32;
        // `sub_824B0DA8`: `+496 + 4i` ×= graph(`+216`) (`fmuls`, no clamp after: the poster sees up
        // to 5.0, which is what reaches the concrete record's tier 1 / 2 above 1.0 / 1.85).
        let scale = if self.body_speed_on { c.body_speed_curve.eval(s.com_speed_216) } else { 1.0 };
        for i in 0..6 {
            let impact = if self.body_speed_on { s.body_impact[i] * scale } else { s.body_impact[i] };
            if impact > 0.0 && !(self.body_cooldown[i] > 0.0) {
                let (a, cloth, pad) = body_materials(i, s.body_slide_flag);
                let tag = s.body_tag[i];
                let b = if tag == 0 { none } else { (tag as i32 - 1).clamp(0, none) };
                let (ta, la_lo, la_hi) = if a < none { ct.impact_band(a, impact) } else { (3, 0.0, 0.0) };
                let (tb, lb_lo, lb_hi) = if b < none { ct.impact_band(b, impact) } else { (3, 0.0, 0.0) };
                if !(ta == 3 && tb == 3) {
                    self.body_cooldown[i] = c.body_cooldown;
                    let la = if a < none { ct.contact_level(a, b, ta, la_lo, la_hi, impact) } else { 0 };
                    let lb = if b < none { ct.contact_level(b, a, tb, lb_lo, lb_hi, impact) } else { 0 };
                    let msg = Message { material: [a, b], tier: [ta, tb], position: s.board_position, level: [la, lb], local: s.local };
                    self.outbox.push(msg);
                    if s.bail && self.grunt_armed {
                        self.grunt_armed = false;
                        self.bail_grunt = true;
                    }
                    let second = |tier: i32| if tier == 2 { 1 } else { 3 };
                    let (sa, sb) = (second(ta), second(tb));
                    if !(sa == 3 && sb == 3) {
                        let la2 = (ct.level_scale(a) * la as f32) as i32;
                        let lb2 = (ct.level_scale(b) * lb as f32) as i32;
                        self.outbox.push(Message { tier: [sa, sb], level: [la2, lb2], ..msg });
                    }
                    let mut posts = 1 + u64::from(!(sa == 3 && sb == 3));
                    if cloth != none {
                        let l = if a < none { ct.contact_level(a, b, 0, la_lo, la_hi, impact) } else { 0 };
                        self.outbox.push(Message { material: [cloth, none], tier: [0, 0], level: [l, 0], ..msg });
                        posts += 1;
                    }
                    if pad != none {
                        let (tier, lo, hi) = Self::pad_band(a, pad, impact, c, t);
                        if tier != 3 && !(tier >= 1 && impact > hi) {
                            let l = ct.contact_level(pad, b, tier, lo, hi, impact);
                            self.outbox.push(Message { material: [pad, none], tier: [tier, 0], level: [l, 0], ..msg });
                            posts += 1;
                        }
                    }
                    self.body_posts += posts;
                    let fresh = self.outbox.len() - posts as usize;
                    for m in &self.outbox[fresh..] {
                        self.body_digest = body_digest(self.body_digest, m);
                    }
                    if let Some(log) = self.body_log.as_mut() {
                        log.extend(self.outbox[fresh..].iter().map(|m| (i, impact, *m)));
                    }
                }
            }
            if self.body_cooldown[i] > 0.0 {
                self.body_cooldown[i] -= s.time_scale.min(1.0);
            }
        }
    }

    /// `sub_824BCCF8`: the pad contact's (tier, low, high) — 3 = none. Materials 102..106 use their
    /// own bands; 110 has a threshold on the head (97) and the torso (98) only; 111 one tier-1
    /// threshold; 112 (the face) tier 1 above its upper threshold, else tier 0 above the lower.
    fn pad_band(a: i32, pad: i32, impact: f32, c: &ContactsTuning, t: &PlayerTuning) -> (i32, f32, f32) {
        match pad {
            102..=106 => t.collision.impact_band(pad, impact),
            110 => {
                let th = match a {
                    97 => c.body_110[0],
                    98 => c.body_110[1],
                    _ => return (3, 0.0, 0.0),
                };
                if impact > th[0] { (1, th[0], th[1]) } else { (3, 0.0, 0.0) }
            }
            111 => {
                if impact > c.body_111[0] { (1, c.body_111[0], c.body_111[1]) } else { (3, 0.0, 0.0) }
            }
            112 => {
                let [t0, t1] = c.body_112;
                if impact > t1[0] {
                    (1, t1[0], t1[1])
                } else if impact > t0[0] {
                    (0, t0[0], t0[1])
                } else {
                    (3, 0.0, 0.0)
                }
            }
            _ => (3, 0.0, 0.0),
        }
    }

    /// `sub_824BB0E0`: the board (95: families 1, 2, 5) or truck (96) against the grind material
    /// (`+692`, 10 without one), tier by the last grind impact `+228` over the Class_grind split;
    /// 0.5 s cooldown.
    fn grind_start(&mut self, s: &AudioState, t: &PlayerTuning, c: &ContactsTuning) {
        if self.grind_cooldown > 0.0 {
            return;
        }
        let b = if s.grind_material == NO_MATERIAL { 10 } else { s.grind_material as i32 };
        let a = if matches!(s.grind_family, 1 | 2 | 5) { 95 } else { 96 };
        let v = s.grind_impact;
        let (tier, low, high) = if v > c.grind_split { (1, c.grind_split, c.grind_high) } else { (0, 0.0, c.grind_split) };
        let ct = &t.collision;
        let la = if a < 143 { ct.contact_level(a, b, tier, low, high, v) } else { 0 };
        let lb = if b < 143 { ct.contact_level(b, a, tier, low, high, v) } else { 0 };
        self.outbox.push(Message { material: [a, b], tier: [tier, tier], position: s.com_position, level: [la, lb], local: s.local });
        self.grind_cooldown = c.grind_cooldown;
    }

    /// `sub_824BA630`'s pair contact: on a landing-flag material, the board (95) against the
    /// first landed wheel's material, tier by the latched air time over the Contacts split.
    fn land_pair(&mut self, s: &AudioState, t: &PlayerTuning, c: &ContactsTuning) {
        let mut b = NO_MATERIAL as i32;
        for w in 0..4 {
            if self.landed[w] {
                b = s.wheel_material[w] as i32;
                if b != NO_MATERIAL as i32 {
                    break;
                }
            }
        }
        let air = super::clamp01(self.air_latched / c.landing_air);
        if !(0..143).contains(&b) || !t.collision.material(b).is_some_and(|m| m.landing) {
            return;
        }
        let a = c.landing_board;
        let (tier, low, high) = if air >= c.landing_split { (1, c.landing_split, c.landing_high) } else { (0, 0.0, c.landing_split) };
        let ct = &t.collision;
        let la = ct.contact_level(b, a, tier, low, high, air);
        let lb = if a < 143 { ct.contact_level(a, b, tier, low, high, air) } else { 0 };
        if la == 0 || lb == 0 {
            return;
        }
        let la = (la as f32 * c.landing_scale[0]) as i32;
        let lb = (lb as f32 * c.landing_scale[1]) as i32;
        self.outbox.push(Message { material: [a, b], tier: [tier, tier], position: s.board_position, level: [la, lb], local: s.local });
    }

    /// `sub_824BD000`: a deck impact (`+668`) — the board (95; 113 on foot or bailing) against the
    /// deck's material (`+660`), each by its impact band; a band-2 impact posts a second message
    /// at tier 1 with the levels × the window record's `+40`. Cooldown in frames.
    fn deck(&mut self, s: &AudioState, t: &PlayerTuning, c: &ContactsTuning) {
        let impact = s.deck_impact;
        if impact > 0.0 && !(self.deck_cooldown > 0.0) {
            let ct = &t.collision;
            let a = if s.on_foot || s.bail { 113 } else { 95 };
            let b = s.deck_material as i32;
            let (ta, la_lo, la_hi) = if a < 143 { ct.impact_band(a, impact) } else { (3, 0.0, 0.0) };
            let (tb, lb_lo, lb_hi) = if b < 143 { ct.impact_band(b, impact) } else { (3, 0.0, 0.0) };
            if !(ta == 3 && tb == 3) {
                self.deck_cooldown = c.deck_cooldown;
                let la = if a < 143 { ct.contact_level(a, b, ta, la_lo, la_hi, impact) } else { 0 };
                let lb = if b < 143 { ct.contact_level(b, a, tb, lb_lo, lb_hi, impact) } else { 0 };
                let msg = Message { material: [a, b], tier: [ta, tb], position: s.board_position, level: [la, lb], local: s.local };
                self.outbox.push(msg);
                let second = |tier: i32| if tier == 2 { 1 } else { 3 };
                let (sa, sb) = (second(ta), second(tb));
                if !(sa == 3 && sb == 3) {
                    let la = (ct.level_scale(a) * la as f32) as i32;
                    let lb = (ct.level_scale(b) * lb as f32) as i32;
                    self.outbox.push(Message { tier: [sa, sb], level: [la, lb], ..msg });
                }
                let posts = 1 + usize::from(!(sa == 3 && sb == 3));
                self.deck_posts += posts as u64;
                let fresh = self.outbox.len() - posts;
                for m in &self.outbox[fresh..] {
                    self.deck_digest = body_digest(self.deck_digest, m);
                }
            }
        }
        if self.deck_cooldown > 0.0 {
            // − min(state +220, 1): the time scale (1 at normal speed).
            self.deck_cooldown -= 1.0;
        }
    }

    /// `sub_824B95A0` (+ `sub_824B9508` / `sub_824B9268`): a foot coming back into the deck box
    /// after more than 25 ms out taps the deck — first foot, second foot, or both at once.
    fn foot_taps(&mut self, s: &AudioState, c: &ContactsTuning, host: &mut dyn SpliceHost) {
        let [f0, f1] = s.feet_in_deck_box;
        if !f0 {
            self.taps.out_time[0] += s.dt;
        }
        if !f1 {
            self.taps.out_time[1] += s.dt;
        }
        let rise1 = f1 && !self.taps.prev[1];
        let rise0 = f0 && !self.taps.prev[0];
        if rise1 {
            if rise0 {
                self.taps.count = 0;
                let [t0, t1] = self.taps.out_time;
                self.taps.both_time = if t1 - t0 >= 0.0 { t1 } else { t0 };
                let [y0, y1] = s.foot_speed_y;
                self.tap(2, if y0 - y1 >= 0.0 { y0 } else { y1 }, c, host);
                self.taps.out_time = [0.0; 2];
                self.taps.both_time = 0.0;
            } else {
                self.taps.count += 1;
                self.tap(0, s.foot_speed_y[1], c, host);
                self.taps.out_time[1] = 0.0;
            }
        } else if rise0 {
            self.taps.count += 1;
            self.tap(1, s.foot_speed_y[0], c, host);
            self.taps.out_time[0] = 0.0;
        }
        self.taps.prev = [f0, f1];
        // +676 bail, +725 / +724 the foot plants (push feet, brake).
        if s.bail || s.push_planted || s.brake {
            self.taps.special = false;
        }
        if !f1 && !f0 {
            if s.hippy_jump {
                if !self.taps.special {
                    self.taps.bucket = s.jump_bucket;
                }
                self.taps.special = true;
            }
        } else if self.taps.special && f1 && f0 {
            self.taps.special = false;
        }
    }

    /// `sub_824B9508` → `sub_824B9268`. `mode` 0 = foot 1, 1 = foot 0, 2 = both.
    fn tap(&mut self, mode: usize, speed: f32, c: &ContactsTuning, host: &mut dyn SpliceHost) {
        let kind = match self.taps.count {
            0 => 2,
            1 => 0,
            2 => {
                self.taps.count = 0;
                1
            }
            _ => return,
        };
        let timer = match mode {
            0 => self.taps.out_time[1],
            1 => self.taps.out_time[0],
            _ => self.taps.both_time,
        };
        if !(timer > c.tap_off_ms * f32::from_bits(0x3A83_126F)) || speed < c.tap_speed {
            return;
        }
        let (kind, variant) = if self.taps.special {
            (3, match self.taps.bucket {
                1 => 1,
                2 => 2,
                _ => 0,
            })
        } else {
            (kind, if speed >= c.tap_high { 2 } else if speed >= c.tap_mid { 1 } else { 0 })
        };
        if self.taps.sounds[mode].is_some() {
            return;
        }
        let id = c.tap_ids[kind.min(3)][variant];
        host.set_route(crate::bus::Route { output: crate::bus::Output::Eq(1), create: self.local, owner_env: 0.0, mono: false });
        self.taps.sounds[mode] = host.start(BANK, id, [0.0, 1.0, 0.0, 0.0, 1.0, 1.0]);
        self.starts += u64::from(self.taps.sounds[mode].is_some());
    }

    /// `sub_824B9948` / `sub_824B97A8`: a foot in the deck box moving faster than 0.35 m/s across
    /// the deck scuffs it (`sk8_foley`), with more than one wheel down.
    fn scuffs(&mut self, s: &AudioState, c: &ContactsTuning, host: &mut dyn SpliceHost) {
        if s.wheel_count <= 1 {
            return;
        }
        let threshold = c.scuff_speed * f32::from_bits(0x3C23_D70A);
        let [f0, f1] = s.feet_in_deck_box;
        for (i, (down, speed)) in [(f1, s.foot_speed_xz[1]), (f0, s.foot_speed_xz[0])].into_iter().enumerate() {
            if down && speed > threshold && self.scuffs[i].is_none() {
                host.set_route(route(1, s, None));
                self.scuffs[i] = host.start(FOLEY, c.scuff_ids[i], [0.0, 1.0, 0.0, s.dt, 1.0, 1.0]);
                self.starts += u64::from(self.scuffs[i].is_some());
            }
        }
    }

    /// `sub_824B9CC8`.
    fn pop(&mut self, s: &AudioState, t: &PlayerTuning, c: &ContactsTuning, host: &mut dyn SpliceHost) {
        if let Some((p, ..)) = self.pop.take() {
            host.release(p);
        }
        if self.frames < 2 {
            return;
        }
        let mut sel = if s.jump_velocity > c.pop_high {
            2
        } else if s.jump_velocity > c.pop_low {
            1
        } else {
            0
        };
        if matches!(s.audio_trick, 33 | 34) {
            sel = 0;
        }
        let hollow = Self::tier(s, t) >= 2;
        let id = if hollow { c.pop_ids_hollow[sel] } else { c.pop_ids[sel] };
        host.set_route(route(0, s, Some(self.owner_levels[0])));
        if let Some(p) = host.start(BANK, id, start_block(s.dt)) {
            self.pop = Some((p, sel, hollow));
            self.starts += 1;
        }
        if self.roll.is_none() {
            let v = s.ground_speed;
            let id = if v > c.roll_speeds[0] {
                Some(c.roll_ids[0])
            } else if v > c.roll_speeds[1] {
                Some(c.roll_ids[1])
            } else if v > c.roll_speeds[2] || s.audio_trick >= 0 {
                Some(if s.audio_trick >= 0 { c.roll_ids[1] } else { c.roll_ids[2] })
            } else {
                None
            };
            if let Some(id) = id {
                self.roll = host.start(BANK, id, start_block(s.dt));
                self.starts += u64::from(self.roll.is_some());
            }
        }
        if s.local {
            if let Some(o) = self.ollie.take() {
                host.release(o);
            }
            self.ollie = host.start(BANK, c.ollie_id, start_block(s.dt));
            self.starts += u64::from(self.ollie.is_some());
        }
    }

    /// `sub_824BA630`: the local landing impact, then the collision pair contact.
    fn land(&mut self, s: &AudioState, t: &PlayerTuning, c: &ContactsTuning, host: &mut dyn SpliceHost) {
        self.frames = 0;
        if s.local {
            if let Some(l) = self.landing.take() {
                host.release(l);
            }
            host.set_route(route(1, s, None));
            self.landing = host.start(BANK, c.landing_id, start_block(s.dt));
            self.starts += u64::from(self.landing.is_some());
        }
        self.land_pair(s, t, c);
    }

    /// `sub_824BB330`: true when the manual landing played (all wheels then count as down).
    fn manual_landing(&mut self, s: &AudioState, t: &PlayerTuning, c: &ContactsTuning, host: &mut dyn SpliceHost) -> bool {
        if s.balance {
            self.in_manual = true;
            return false;
        }
        if !self.in_manual {
            return false;
        }
        match s.wheel_count {
            3 | 4 => {
                if let Some(m) = self.manual.take() {
                    host.release(m.sound);
                }
                let (id, tier) = self.set(s, t, c, 4, 0);
                host.set_route(route(0, s, Some(self.owner_levels[1])));
                if let Some(sound) = host.start(BANK, id, start_block(s.dt)) {
                    self.manual = Some(Touch { sound, kind: 4, variant: 0, tier });
                    self.starts += 1;
                }
                self.counted = [true; 4];
                self.in_manual = false;
                true
            }
            0 => {
                self.in_manual = false;
                false
            }
            _ => false,
        }
    }

    /// `sub_824B8D48`: a touchdown voice (and the variant-2 second voice).
    fn touch(&mut self, s: &AudioState, t: &PlayerTuning, c: &ContactsTuning, kind: usize, variant: usize, second_ok: bool, host: &mut dyn SpliceHost) {
        let Some(free) = self.touch.iter().position(Option::is_none) else { return };
        let (variant, second) = if variant > 1 { (1, !second_ok || !self.memory_136) } else { (variant, false) };
        let second_set = second.then(|| self.set(s, t, c, kind, 2));
        let (id, tier) = self.set(s, t, c, kind, variant);
        host.set_route(route(0, s, Some(self.owner_levels[1])));
        if let Some(sound) = host.start(BANK, id, start_block(s.dt)) {
            self.touch[free] = Some(Touch { sound, kind, variant, tier });
            self.starts += 1;
        }
        if let (Some((id2, tier2)), None) = (second_set, self.second) {
            host.set_route(route(0, s, Some(self.owner_levels[1])));
            if let Some(sound) = host.start(BANK, id2, start_block(s.dt)) {
                self.second = Some(Touch { sound, kind, variant: 2, tier: tier2 });
                self.starts += 1;
            }
        }
    }

    /// `sub_824B86E0`.
    fn touchdowns(&mut self, s: &AudioState, buckets: [u32; 4], manual: bool, t: &PlayerTuning, c: &ContactsTuning, host: &mut dyn SpliceHost) {
        let mut landed = self.landed;
        let mut count = 0;
        let mut class = 0u32;
        for w in 0..4 {
            if landed[w] {
                if !self.counted[w] {
                    count += 1;
                    class = class.max(buckets[w]);
                } else {
                    landed[w] = false;
                }
            } else {
                self.counted[w] = false;
            }
        }
        let down = self.counted.iter().filter(|c| **c).count();
        if !s.local && count > 0 && class == 2 {
            class = 1;
        }
        let class = class as usize;
        let latch_new = |me: &mut Self| {
            for w in 0..4 {
                if landed[w] {
                    me.counted[w] = true;
                }
            }
        };
        match count {
            0 => {}
            4 => {
                self.touch(s, t, c, 0, class, false, host);
                self.counted = [true; 4];
                self.memory_136 = false;
            }
            2 if down == 0 => {
                self.memory_136 = class == 2;
                self.touch(s, t, c, 1, class, false, host);
                latch_new(self);
            }
            2 if down == 2 => {
                if !manual && !self.in_manual {
                    self.touch(s, t, c, 2, class, true, host);
                }
                latch_new(self);
                self.memory_136 = false;
            }
            2 => {
                self.touch(s, t, c, 0, class, true, host);
                self.counted = [true; 4];
                self.memory_136 = false;
            }
            3 => {
                self.touch(s, t, c, 0, class, true, host);
                self.counted = [true; 4];
                self.memory_136 = false;
            }
            _ => match down {
                3 => self.counted = [true; 4],
                2 => {
                    if !manual && !self.in_manual {
                        self.touch(s, t, c, 2, class, true, host);
                    }
                    self.counted = [true; 4];
                    self.memory_136 = false;
                }
                1 => {
                    let m = self.memory_136;
                    self.touch(s, t, c, 3, class, m, host);
                    self.memory_136 = class == 2;
                    latch_new(self);
                }
                _ => {
                    self.memory_136 = class == 2;
                    self.touch(s, t, c, 3, class, false, host);
                    latch_new(self);
                }
            },
        }
    }

    /// `sub_824BE1B8`: every held sound's block, after the MixMap tick (owner = Contacts).
    pub fn update(&mut self, s: &AudioState, out: &dyn Outputs, c: &ContactsTuning, host: &mut dyn SpliceHost) {
        self.owner_levels = [out.level(14), out.level(15)];
        let spread = if s.local { 1.0 } else { 0.0 };
        let block = |level: i32| -> [f32; 6] {
            [level as f32 * LEVEL, out.pitch(1) as f32 * PITCH, out.raw(0) as f32 * DEGREES, s.dt, spread, 1.0]
        };
        // sub_824BEBD8 (taps, level 8) and sub_824BF4A8 (scuffs, level 9): no pan spread.
        for (slots, level) in [(&mut self.taps.sounds[..], 8usize), (&mut self.scuffs[..], 9)] {
            for slot in slots.iter_mut() {
                let Some(sound) = *slot else { continue };
                if host.alive(sound) {
                    let mut b = block(out.level(level));
                    b[4] = 0.0;
                    host.update(sound, b);
                } else {
                    host.release(sound);
                    *slot = None;
                }
            }
        }
        if let Some((p, sel, hollow)) = self.pop {
            if host.alive(p) {
                let k = if hollow { c.pop_gain_hollow[sel] } else { c.pop_gain[sel] };
                host.update(p, block((out.level(2) as f32 * k) as i32));
            } else {
                host.release(p);
                self.pop = None;
            }
        }
        if let Some(r) = self.roll {
            if host.alive(r) {
                let mut b = block(out.level(7));
                b[4] = 0.0;
                host.update(r, b);
            } else {
                host.release(r);
                self.roll = None;
            }
        }
        for slot in self.touch.iter_mut().chain(std::iter::once(&mut self.second)).chain(std::iter::once(&mut self.manual)) {
            let Some(t) = *slot else { continue };
            if host.alive(t.sound) {
                let k = c.touch_gain.get(t.tier).map_or(1.0, |g| g[(3 * t.kind + t.variant).min(14)]);
                host.update(t.sound, block((out.level(3) as f32 * k) as i32));
            } else {
                host.release(t.sound);
                *slot = None;
            }
        }
        for (slot, id) in [(&mut self.ollie, 12usize), (&mut self.landing, 13)] {
            let Some(o) = *slot else { continue };
            if host.alive(o) {
                host.update(o, block(out.level(id)));
            } else {
                host.release(o);
                *slot = None;
            }
        }
        // sub_824BF268: the push foot's plant / lift sounds at level(6), no pan spread.
        for slot in [&mut self.plant, &mut self.lift] {
            let Some(sound) = *slot else { continue };
            if host.alive(sound) {
                let mut b = block(out.level(6));
                b[4] = 0.0;
                host.update(sound, b);
            } else {
                host.release(sound);
                *slot = None;
            }
        }
        self.step_on.update(s, &c.step_on, out, host);
        if self.grind_cooldown > 0.0 {
            self.grind_cooldown -= s.dt;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[derive(Default)]
    struct Log {
        started: Vec<u32>,
        live: HashMap<SoundId, u32>,
        next: SoundId,
        updates: Vec<(u32, [f32; 6])>,
    }
    impl SpliceHost for Log {
        fn start(&mut self, _: &str, id: u32, _: [f32; 6]) -> Option<SoundId> {
            self.started.push(id);
            self.next += 1;
            self.live.insert(self.next, id);
            Some(self.next)
        }
        fn update(&mut self, sound: SoundId, block: [f32; 6]) {
            self.updates.push((self.live[&sound], block));
        }
        fn alive(&self, sound: SoundId) -> bool {
            self.live.contains_key(&sound)
        }
        fn release(&mut self, sound: SoundId) {
            self.live.remove(&sound);
        }
    }

    struct Out;
    impl Outputs for Out {
        fn level(&self, id: usize) -> i32 {
            10000 + id as i32
        }
        fn raw(&self, _: usize) -> i32 {
            0
        }
        fn pitch(&self, _: usize) -> i32 {
            4096
        }
    }

    fn rolling() -> AudioState {
        AudioState { ground_speed: 6.0, wheel_count: 4, wheel_contact: [true; 4], wheel_material: [2; 4], ..Default::default() }
    }

    #[test]
    fn an_ollie_pops_rolls_and_lands_on_four_wheels() {
        let (t, c) = (PlayerTuning::default(), ContactsTuning::default());
        let mut k = Contacts::default();
        let mut h = Log::default();
        for _ in 0..10 {
            k.process(&rolling(), [0; 4], &t, &c, &mut h);
        }
        assert!(h.started.is_empty(), "rolling alone makes no contact sound");
        let air = AudioState { airborne: true, wheel_count: 0, wheel_contact: [false; 4], trick_active: true, audio_trick: 28, jump_velocity: 0.3, ..rolling() };
        for _ in 0..30 {
            k.process(&air, [0; 4], &t, &c, &mut h);
        }
        // selector 1 (0.25 < jv ≤ 0.42) → 1098, roll 1111 (6 m/s > 4), ollie 1096.
        assert_eq!(h.started, [1098, 1111, 1096]);
        k.update(&air, &Out, &c, &mut h);
        let pop = h.updates.iter().find(|u| u.0 == 1098).unwrap().1;
        assert!((pop[0] - (10002.0f32 * 0.75).trunc() / 32767.0).abs() < 1e-6, "pop gain = trunc(level(2) × 0.75) / 32767");
        h.started.clear();
        k.process(&rolling(), [2; 4], &t, &c, &mut h);
        // Landing impact 1095, then the four-wheel touchdown kind 0 variant 1 (bucket 2 → 1 + second
        // voice of variant 2): ids 1052 and 1053 (tier 0).
        assert_eq!(h.started, [1052, 1053, 1095]);
        h.started.clear();
        for _ in 0..10 {
            k.process(&rolling(), [2; 4], &t, &c, &mut h);
        }
        assert!(h.started.is_empty(), "each wheel counts once");
    }

    #[test]
    fn staggered_landings_use_the_pair_kinds() {
        let (t, c) = (PlayerTuning::default(), ContactsTuning::default());
        let mut k = Contacts::default();
        let mut h = Log::default();
        let air = AudioState { airborne: true, wheel_count: 0, wheel_contact: [false; 4], ..rolling() };
        for _ in 0..10 {
            k.process(&air, [0; 4], &t, &c, &mut h);
        }
        let front = AudioState { wheel_count: 2, wheel_contact: [true, true, false, false], ..rolling() };
        k.process(&front, [0; 4], &t, &c, &mut h);
        k.process(&rolling(), [0; 4], &t, &c, &mut h);
        // a pair from nothing (kind 1, 1054) then the last pair (kind 2, 1057), landing 1095 between.
        assert_eq!(h.started, [1054, 1095, 1057]);
    }

    #[test]
    fn the_tier_reads_hollow_and_soft() {
        let mut t = PlayerTuning::default();
        let mut row = [0i32; 18];
        row[2] = 1;
        t.surface_table = vec![[0; 18]; 95];
        t.surface_table[40] = row;
        let mut s = rolling();
        s.wheel_material = [40; 4];
        assert_eq!(Contacts::tier(&s, &t), 2);
        s.soft_wheels = true;
        assert_eq!(Contacts::tier(&s, &t), 3);
    }

    fn collision_tuning() -> PlayerTuning {
        use crate::player::collision::{CollisionTuning, Material};
        let mut materials = vec![Material::default(); 143];
        let windows = [10000, 23000, 10000, 2000, 12000, 24000, 9000, 22000, 11000, 16000, 12000, 24000, 9000, 22000];
        materials[9] = Material { kind: 1, landing: true, gain: 32767, windows, bands: [0.4, 2.0, 0.15, 0.025], ..Material::default() };
        materials[95] = Material { kind: 0, gain: 28000, windows, bands: [0.4, 2.0, 0.15, 0.025], ..Material::default() };
        materials[96] = Material { kind: 0, gain: 27000, windows, ..Material::default() };
        PlayerTuning { collision: CollisionTuning { materials, surface_class: vec![2; 95], surface_eq: Vec::new() }, ..PlayerTuning::default() }
    }

    #[test]
    fn a_grind_start_posts_the_truck_against_the_rail_once_per_half_second() {
        let (t, c) = (collision_tuning(), ContactsTuning::default());
        let mut k = Contacts::default();
        let mut h = Log::default();
        let grind = AudioState { grinding: true, grind_family: 0, grind_material: 9, grind_impact: 0.6, ..rolling() };
        k.process(&rolling(), [0; 4], &t, &c, &mut h);
        k.process(&grind, [0; 4], &t, &c, &mut h);
        assert_eq!(k.outbox.len(), 1);
        let m = k.outbox[0];
        assert_eq!((m.material, m.tier), ([96, 9], [1, 1]), "family 0 → truck 96; impact 0.6 > 0.25 → tier 1");
        // Clamped to the tier's high (0.5): the window's high word for class 2 (+48) = 24000.
        assert_eq!(m.level, [24000, 24000]);
        k.outbox.clear();
        k.update(&grind, &Out, &c, &mut h);
        k.process(&rolling(), [0; 4], &t, &c, &mut h);
        k.process(&grind, [0; 4], &t, &c, &mut h);
        assert!(k.outbox.is_empty(), "the 0.5 s cooldown holds");
    }

    #[test]
    fn a_landing_on_a_landing_flag_material_posts_the_board_pair() {
        let (t, c) = (collision_tuning(), ContactsTuning::default());
        let mut k = Contacts::default();
        let mut h = Log::default();
        let metal = AudioState { wheel_material: [9; 4], ..rolling() };
        let air = AudioState { airborne: true, wheel_count: 0, wheel_contact: [false; 4], ..metal };
        for i in 0..30 {
            k.process(&AudioState { air_time: i as f32 / 60.0, ..air }, [0; 4], &t, &c, &mut h);
        }
        k.process(&metal, [1; 4], &t, &c, &mut h);
        assert_eq!(k.outbox.len(), 1);
        let m = k.outbox[0];
        // Air 29/60 s over 0.4 → clamp 1 ≥ 0.1 → tier 1 over [0.1, 0.3]: the high words (class 2,
        // +48 = 24000), × 0.65 / × 1.
        assert_eq!((m.material, m.tier), ([95, 9], [1, 1]));
        assert_eq!(m.level, [(24000.0f32 * 0.65) as i32, 24000]);
        // Concrete (no landing flag) posts nothing.
        let mut k = Contacts::default();
        k.process(&air, [0; 4], &t, &c, &mut h);
        k.process(&rolling(), [1; 4], &t, &c, &mut h);
        assert!(k.outbox.is_empty());
    }

    #[test]
    fn feet_back_on_the_deck_tap_it() {
        let (t, c) = (PlayerTuning::default(), ContactsTuning::default());
        let mut k = Contacts::default();
        let mut h = Log::default();
        let on = AudioState { feet_in_deck_box: [true, true], foot_speed_y: [3.0, 1.0], ..rolling() };
        let off = AudioState { feet_in_deck_box: [false, false], ..on };
        k.process(&on, [0; 4], &t, &c, &mut h);
        k.process(&off, [0; 4], &t, &c, &mut h);
        // One frame out (16.7 ms) is under the 25 ms minimum: no tap.
        k.process(&on, [0; 4], &t, &c, &mut h);
        assert!(h.started.is_empty());
        for _ in 0..3 {
            k.process(&off, [0; 4], &t, &c, &mut h);
        }
        // Both feet together at 3 m/s (≥ 2): the "both" set, variant 1.
        k.process(&on, [0; 4], &t, &c, &mut h);
        assert_eq!(h.started, [1119]);
        // Foot 0 alone: the first-foot set (count 1); foot 1 next: the second-foot set.
        h.started.clear();
        let only1 = AudioState { feet_in_deck_box: [false, true], ..on };
        let only0 = AudioState { feet_in_deck_box: [true, false], ..on };
        for _ in 0..3 {
            k.process(&only1, [0; 4], &t, &c, &mut h);
        }
        k.process(&on, [0; 4], &t, &c, &mut h);
        for _ in 0..3 {
            k.process(&only0, [0; 4], &t, &c, &mut h);
        }
        k.update(&on, &Out, &c, &mut h);
        k.process(&on, [0; 4], &t, &c, &mut h);
        assert_eq!(h.started, [1113, 1115]);
    }

    #[derive(Default)]
    struct Routed {
        log: Log,
        banks: Vec<String>,
        routes: Vec<crate::bus::Route>,
    }
    impl SpliceHost for Routed {
        fn set_route(&mut self, route: crate::bus::Route) {
            self.routes.push(route);
        }
        fn start(&mut self, bank: &str, id: u32, b: [f32; 6]) -> Option<SoundId> {
            self.banks.push(bank.to_owned());
            self.log.start(bank, id, b)
        }
        fn update(&mut self, sound: SoundId, block: [f32; 6]) {
            self.log.update(sound, block)
        }
        fn alive(&self, sound: SoundId) -> bool {
            self.log.alive(sound)
        }
        fn release(&mut self, sound: SoundId) {
            self.log.release(sound)
        }
    }

    #[test]
    fn the_push_foot_plants_and_lifts_by_the_material_kind() {
        let c = ContactsTuning::default();
        let mut t = PlayerTuning::default();
        let mut row = [0i32; 18];
        row[5] = 2; // AudioSurfaceMap word 5: the plant kind of material 7
        t.surface_table = vec![[0; 18]; 95];
        t.surface_table[7] = row;
        let mut k = Contacts { plant_lift_on: true, ..Default::default() };
        let mut h = Routed::default();
        let s = AudioState { wheel_material: [7; 4], ..rolling() };
        k.process(&s, [0; 4], &t, &c, &mut h);
        assert!(h.log.started.is_empty(), "nothing before a plant");
        let planted = AudioState { push_planted: true, ..s };
        for _ in 0..5 {
            k.process(&planted, [0; 4], &t, &c, &mut h);
        }
        assert_eq!(h.log.started, [92], "one plant per plant: kind 2 → sk8_foley 92");
        assert_eq!(h.banks, ["sk8_foley"]);
        assert_eq!(h.routes.last().map(|r| r.output), Some(crate::bus::Output::Eq(1)), "eEQChain bus 1");
        k.update(&planted, &Out, &c, &mut h);
        let level = h.log.updates.iter().find(|u| u.0 == 92).unwrap().1;
        assert_eq!((level[0], level[4]), (10006.0 * f32::from_bits(0x3800_0100), 0.0), "level(6), no spread");
        k.process(&s, [0; 4], &t, &c, &mut h);
        assert_eq!(h.log.started, [92, 93], "the lift: kind 2 → 93");
        // No material under wheel 0: kind 0 (84 / 85); off: nothing.
        let none = AudioState { wheel_material: [NO_MATERIAL; 4], push_planted: true, ..s };
        k.process(&none, [0; 4], &t, &c, &mut h);
        assert_eq!(h.log.started.last(), Some(&84));
        let mut off = Contacts::default();
        off.process(&none, [0; 4], &t, &c, &mut h);
        assert_eq!(h.log.started.len(), 3, "plant_lift_on off: silent");
    }

    /// Concrete (2), the arm (100), skin (107) and the limb pad (111) with retail-shaped bands.
    fn body_tuning() -> PlayerTuning {
        use crate::player::collision::{CollisionTuning, Material};
        let windows = [16000, 32767, 25000, 32767, 16000, 32767, 25000, 32767, 24000, 32767, 16000, 32767, 25000, 32767];
        let mut materials = vec![Material::default(); 143];
        materials[2] = Material { kind: 0, gain: 32767, windows, bands: [1.85, 2.0, 1.0, 0.12], ..Material::default() };
        materials[100] = Material { kind: 0, gain: 32767, windows, bands: [0.65, 1.25, 0.2, 0.005], scale: 1.0, ..Material::default() };
        materials[107] = Material { kind: 0, gain: 18000, windows, bands: [1.0, 2.0, 0.5, 0.005], ..Material::default() };
        materials[111] = Material { kind: 0, gain: 15000, windows, bands: [1.0, 2.0, 0.5, 0.005], ..Material::default() };
        PlayerTuning { collision: CollisionTuning { materials, surface_class: vec![0; 95], surface_eq: Vec::new() }, ..PlayerTuning::default() }
    }

    /// The body poster on the console cadence (2026-10-03): a host at any real frame rate runs
    /// the components on the frames that complete 60 Hz steps (newest step's state) and the poster
    /// once per console frame (`mixmap::cadence`, every second step), so the same messages are
    /// posted on the same steps at 30 / 60 / 144 / 240 / 365 fps, and the 15-frame cooldown lasts
    /// 30 steps = 0.5 s. (Below 30 fps a pass spans more than one console frame and the host has only
    /// the newest step's state.) The old per-process cadence depends on the frame rate.
    #[test]
    fn the_body_poster_keeps_the_console_cadence_at_any_frame_rate() {
        use crate::mixmap::cadence::Cadence;
        let (t, c) = (body_tuning(), ContactsTuning::default());
        // 20 s of 60 Hz steps: both arm regions on concrete, impacts rising and falling (some
        // under every floor, some tier 2), as the conditioner's 4-step max hands them over.
        let steps: Vec<AudioState> = (0..1200u32)
            .map(|i| {
                let mut s = AudioState { bail: true, ..AudioState::default() };
                for (r, k) in [(2usize, 7u32), (3, 11)] {
                    let x = (i.wrapping_mul(k).wrapping_add(r as u32 * 13) % 41) as f32 / 50.0;
                    s.body_impact[r] = if x < 0.1 { 0.0 } else { x };
                    s.body_tag[r] = 3;
                }
                s.board_position = [i as f32 * 0.1, 0.0, 0.0];
                s
            })
            .collect();
        let run = |fps: f64, console: bool| -> Vec<(usize, u64, u64)> {
            let mut k = Contacts { body_on: true, ..Default::default() };
            let mut h = Log::default();
            let (mut cadence, mut owed, mut step, mut out) = (Cadence::default(), 0.0f64, 0usize, Vec::new());
            while step < steps.len() {
                owed += 60.0 / fps;
                let n = (owed.floor() as usize).min(steps.len() - step);
                owed -= n as f64;
                if n == 0 {
                    continue;
                }
                step += n;
                let calls = cadence.advance(n);
                k.body_calls = console.then_some(calls);
                let before = k.body_posts;
                k.process(&steps[step - 1], [0; 4], &t, &c, &mut h);
                k.outbox.clear();
                if k.body_posts != before {
                    out.push((step, k.body_posts, k.body_digest));
                }
            }
            out
        };
        let reference = run(60.0, true);
        assert!(reference.len() > 50, "the stream posts ({} times)", reference.len());
        for fps in [30.0, 144.0, 240.0, 365.0] {
            assert_eq!(run(fps, true), reference, "{fps} fps");
        }
        assert_ne!(run(30.0, false), run(60.0, false), "the per-process cadence depends on the frame rate");
        // A held impact: one post group per 15 console frames = 30 steps (0.5 s).
        let mut k = Contacts { body_on: true, ..Default::default() };
        let mut h = Log::default();
        let mut s = AudioState { bail: true, ..AudioState::default() };
        s.body_impact[2] = 0.7;
        s.body_tag[2] = 3;
        let (mut cadence, mut at) = (Cadence::default(), Vec::new());
        for step in 1..=120 {
            k.body_calls = Some(cadence.advance(1));
            let before = k.body_posts;
            k.process(&s, [0; 4], &t, &c, &mut h);
            if k.body_posts != before {
                at.push(step);
            }
        }
        assert_eq!(at, [2, 32, 62, 92]);
    }

    /// The deck poster (`sub_824BD000`) on the console cadence (2026-10-03): the same messages on the
    /// same steps at 30 / 60 / 144 / 240 / 365 fps, and the 6-frame cooldown lasts 12 steps (0.2 s).
    #[test]
    fn the_deck_poster_keeps_the_console_cadence_at_any_frame_rate() {
        use crate::mixmap::cadence::Cadence;
        let (t, c) = (body_tuning(), ContactsTuning::default());
        let steps: Vec<AudioState> = (0..1200u32)
            .map(|i| {
                let x = (i.wrapping_mul(13) % 37) as f32 / 20.0;
                AudioState { deck_impact: if x < 0.3 { 0.0 } else { x.min(1.0) }, deck_material: 2, board_position: [i as f32 * 0.1, 0.0, 0.0], ..AudioState::default() }
            })
            .collect();
        let run = |fps: f64, console: bool| -> Vec<(usize, u64, u64)> {
            let mut k = Contacts::default();
            let mut h = Log::default();
            let (mut cadence, mut owed, mut step, mut out) = (Cadence::default(), 0.0f64, 0usize, Vec::new());
            while step < steps.len() {
                owed += 60.0 / fps;
                let n = (owed.floor() as usize).min(steps.len() - step);
                owed -= n as f64;
                if n == 0 {
                    continue;
                }
                step += n;
                k.deck_calls = console.then_some(cadence.advance(n));
                let before = k.deck_posts;
                k.process(&steps[step - 1], [0; 4], &t, &c, &mut h);
                k.outbox.clear();
                if k.deck_posts != before {
                    out.push((step, k.deck_posts, k.deck_digest));
                }
            }
            out
        };
        let reference = run(60.0, true);
        assert!(reference.len() > 50, "the stream posts ({} times)", reference.len());
        for fps in [30.0, 144.0, 240.0, 365.0] {
            assert_eq!(run(fps, true), reference, "{fps} fps");
        }
        assert_ne!(run(30.0, false), run(60.0, false), "the per-process cadence depends on the frame rate");
        let mut k = Contacts::default();
        let mut h = Log::default();
        let s = AudioState { deck_impact: 0.7, deck_material: 2, ..AudioState::default() };
        let (mut cadence, mut at) = (Cadence::default(), Vec::new());
        for step in 1..=50 {
            k.deck_calls = Some(cadence.advance(1));
            let before = k.deck_posts;
            k.process(&s, [0; 4], &t, &c, &mut h);
            if k.deck_posts != before {
                at.push(step);
            }
        }
        assert_eq!(at, [2, 14, 26, 38, 50], "every 6 console frames = 12 steps");
    }

    #[test]
    fn a_body_region_impact_posts_the_pair_cloth_and_pad_contacts() {
        let t = body_tuning();
        let c = ContactsTuning::default();
        let mut k = Contacts { body_on: true, ..Default::default() };
        let mut h = Log::default();
        // Region 2 (an arm, material 100) hits concrete (tag 3 → material 2) at 0.7.
        let mut s = AudioState { bail: true, ..AudioState::default() };
        s.body_impact[2] = 0.7;
        s.body_tag[2] = 3;
        k.process(&s, [0; 4], &t, &c, &mut h);
        let m: Vec<_> = k.outbox.iter().map(|m| (m.material, m.tier)).collect();
        // 100 at 0.7 > 0.65 → tier 2 (and the second message at tier 1); concrete at 0.7 < 1.0 →
        // tier 0; the skin 107 at tier 0; the limb pad 111 at 0.7 > 0.65 → tier 1.
        assert_eq!(m, [([100, 2], [2, 0]), ([100, 2], [1, 3]), ([107, 143], [0, 0]), ([111, 143], [1, 0])]);
        assert_eq!(k.body_posts, 4);
        k.outbox.clear();
        for _ in 0..13 {
            k.process(&s, [0; 4], &t, &c, &mut h);
        }
        assert!(k.outbox.is_empty(), "15-frame cooldown");
        k.process(&s, [0; 4], &t, &c, &mut h);
        k.process(&s, [0; 4], &t, &c, &mut h);
        assert_eq!(k.outbox.len(), 4, "posts again after the cooldown");
        // The end of the bail stops it; a tiny impact under both floors posts nothing.
        let mut k = Contacts { body_on: true, ..Default::default() };
        k.process(&AudioState { bail_end: true, ..s }, [0; 4], &t, &c, &mut h);
        assert!(k.outbox.is_empty());
        let mut tiny = s;
        tiny.body_impact[2] = 0.001;
        k.process(&tiny, [0; 4], &t, &c, &mut h);
        assert!(k.outbox.is_empty());
    }

    /// `sub_82481E10` over the bridge's 8 points: clamped to y0 below x0 and to y7 from x7 on
    /// (an unordered input too), linear in between, a knot gives its own y.
    #[test]
    fn the_bridge_speed_graph_is_the_vault_curve_piecewise_linear_and_clamped() {
        let g = SpeedGraph8::BODY_SPEED;
        let x = [0.0, 0.366_449_4, 0.447_882_6, 0.521_172_6, 0.592_834, 0.741_042_6, 0.863_192, 0.946_254];
        let y = [1.0, 1.2, 1.485_714, 1.914_286, 2.428_571, 3.6, 4.571_427, 5.0];
        for i in 0..8 {
            assert!((g.x[i] - x[i]).abs() < 1e-6 && (g.y[i] - y[i]).abs() < 1e-6, "point {i}");
            assert_eq!(g.eval(g.x[i]), g.y[i], "a knot reads its own y");
        }
        assert_eq!(g.eval(-1.0), 1.0, "below x0: y0");
        assert_eq!(g.eval(0.0), 1.0, "at rest: x1");
        assert_eq!(g.eval(0.946_254), 5.0);
        assert_eq!(g.eval(23.0), 5.0, "past x7: y7");
        assert_eq!(g.eval(f32::NAN), 5.0, "unordered: the last value");
        // Halfway between the knots 5 and 6: (3.6 + 4.571) / 2.
        let mid = (g.x[5] + g.x[6]) * 0.5;
        assert!((g.eval(mid) - (g.y[5] + g.y[6]) * 0.5).abs() < 1e-5);
        // Slope first, fmadds: bit-exact against the formula.
        let v = 0.2f32;
        assert_eq!(g.eval(v), ((g.y[1] - g.y[0]) / (g.x[1] - g.x[0])).mul_add(v - g.x[0], g.y[0]));
    }

    /// The bridge's graph scales the region impacts before the poster: at rest (×1) a 0.3 arm hit on
    /// concrete is tier 0 for both; moving (×5) the same hit reads 1.5 (concrete tier 1, the arm
    /// tier 2), 0.4 → 2.0 (concrete tier 2): the concrete record's 1047 / 991 tiers become
    /// reachable as in the recomp. Off, or at rest, the impacts post unchanged. The deck poster
    /// does not see the graph.
    #[test]
    fn the_speed_graph_scales_the_body_impacts_not_the_deck() {
        let t = body_tuning();
        let c = ContactsTuning::default();
        let post = |impact: f32, speed: f32, on: bool| {
            let mut k = Contacts { body_on: true, body_speed_on: on, ..Default::default() };
            let mut s = AudioState { bail: true, com_speed_216: speed, ..AudioState::default() };
            s.body_impact[2] = impact;
            s.body_tag[2] = 3;
            k.process(&s, [0; 4], &t, &c, &mut Log::default());
            k.outbox.first().map(|m| (m.material, m.tier))
        };
        assert_eq!(post(0.3, 0.0, true), Some(([100, 2], [1, 0])), "×1: arm tier 1 (> 0.2), concrete tier 0");
        assert_eq!(post(0.3, 2.0, true), Some(([100, 2], [2, 1])), "×5: 1.5 → arm tier 2, concrete tier 1");
        assert_eq!(post(0.4, 2.0, true), Some(([100, 2], [2, 2])), "×5: 2.0 → concrete tier 2");
        assert_eq!(post(0.3, 2.0, false), post(0.3, 0.0, true), "off = the conditioner's value");
        // Under every floor at rest (0.001 < 0.005 arm, < 0.12 concrete), above the arm's when moving.
        assert_eq!(post(0.001, 0.0, true), None);
        assert_eq!(post(0.0011, 2.0, true).map(|m| m.1), Some([0, 3]), "0.0055 > the arm floor 0.005");
        // The deck poster reads `+668`, which the bridge does not scale.
        let deck = |on: bool| {
            let mut k = Contacts { body_speed_on: on, ..Default::default() };
            let s = AudioState { deck_impact: 0.3, deck_material: 2, com_speed_216: 3.0, ..AudioState::default() };
            k.process(&s, [0; 4], &t, &c, &mut Log::default());
            (k.deck_posts, k.deck_digest)
        };
        assert_eq!(deck(true), deck(false));
    }

    #[test]
    fn a_foot_sliding_on_the_deck_scuffs() {
        let (t, c) = (PlayerTuning::default(), ContactsTuning::default());
        let mut k = Contacts::default();
        let mut h = Log::default();
        let s = AudioState { feet_in_deck_box: [true, true], foot_speed_xz: [0.2, 0.5], ..rolling() };
        k.process(&s, [0; 4], &t, &c, &mut h);
        assert_eq!(h.started, [95], "foot 1 above 0.35 m/s → sk8_foley 95; foot 0 below");
        k.process(&s, [0; 4], &t, &c, &mut h);
        assert_eq!(h.started.len(), 1, "one scuff per foot at a time");
    }
}
