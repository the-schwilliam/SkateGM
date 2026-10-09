//! The skater's footsteps: retail's `SFXObj_OffBoard` (controller `0x40010090`) foot sounds, on
//! the board (push and brake plants) and off it (walking, running, jumping). Written from our
//! reading of the retail code (TU3, reference only; spec `audio-specs/aems-offboard-clothing-spec.md`):
//!
//! - process `sub_824E9270`: OffBoard.in0 = on foot (`inputs::write_off_board`); the curve words
//!   (`sub_82481E10` over three `Sk8::PointNegGraphData16` records): `+408` = walk(|COM v|),
//!   `+412` / `+416` = xz(foot A / B speed), `+420` / `+424` = vertical(foot A / B speed); the
//!   foot-down copies (`+52` = state `+724`, `+236` = `+725`); on the footplant's falling edge
//!   (state `+768`) the countdown of the foot that was down (A first) is set to 10; both count down;
//!   then the poster, the walking voices (on foot), the jump voices, (remote players only:
//!   `sub_824EBA08`, not modelled) and the water splash ([`Splash`], `sub_824EBB58`);
//! - poster `sub_824E9FD8`: two `playercharacter_footstep` packets (25 words, constructor
//!   `sub_824B73E0`), B (`+220`) then A (`+36`), posted once and held; for the local player, on a
//!   foot-down edge: the foot's four Splice sounds stop (`sub_82494B80`) and up to four start, each
//!   through its own "FootStep SubMix" (`sub_82494188`): the surface layers (`sub_82493E60`, layer 0
//!   and 1; the material's AudioSurface record or the special surfaces 5 and 7) with their EQ
//!   record (`sub_82493448` → class `370AF2704BFA6866`) and gain (`sub_824940F8`), and the step
//!   layers (`sub_82493690`: `sk8_foley` by walk/run mode, step code and footstep surface; layer 1
//!   `Skate_Collisions` on surfaces 3 and 4);
//! - walking voices `sub_824E9D10` (on foot, both feet): `sk8_foley` 62/63/64 by |COM v| over
//!   2.5 / 7.5 m/s, plus `Skate_Collisions` 1121/1122/1123 for the local player with state `+308`;
//! - jump voices `sub_824E9678`: a take-off (`sk8_foley` 65 jumping off the feet, else 67/69/71
//!   by the jump bucket `+304`) on entering OffboardAir on foot, a hippy jump (`+372`) or the
//!   footplant's end, and the apex (66, else 68/70/72) when the COM starts falling with a take-off
//!   sound held;
//! - update `sub_824E9628`: the packets (`sub_824EAEA8`) and the foot sounds' blocks
//!   (`sub_82494C08`), the walking (`sub_824EA9C8` level 3, `sub_824EAC38` level 12) and jump
//!   voices (`sub_824E9AB8` levels 9 / 10), the splash sounds ([`Splash::update`], `sub_824EBE78`).
//!
//! The FootStep SubMix (per foot sound slot, mono): `Sub0 → HI20 → LI20 → PI20 → Sen0 (env bus,
//! level) → Pn21 (azimuth) → Sen0 (SFX Master)`; its parameters are latched at each start of the
//! slot's sound (`sub_82494550`): the slot's EQ record and the holder's env level (OffBoard
//! level(8) / 32767 as of the last update) and azimuth (OffBoard raw(0) × 360/65536). The host gets
//! them through [`SpliceHost::set_submix`] (default: ignored — the voices then play straight into
//! SFX Master with the env send of [`crate::bus::Route::owner_env`]).
use super::components::{Command, Slot};
use super::contacts::SpliceHost;
use super::state::NO_MATERIAL;
use super::tuning::PlayerTuning;
use super::{AudioState, Outputs, trunc_clamp};
use crate::splice::SoundId;

/// The AEMS class and bank of the two held packets.
pub const CLASS: &str = "playercharacter_footstep";
pub const BANK: &str = "fstep_skateshoe1_sm";
pub const WORDS: usize = 25;

const LEVEL: f32 = f32::from_bits(0x3800_0100); // 1/32767 (0x822F8898)
const PITCH: f32 = f32::from_bits(0x3980_0000); // 1/4096 (0x822F890C)
const DEGREES: f32 = f32::from_bits(0x3BB4_00B4); // 360/65535 (0x822F8C64)
/// The submix panner's scale (`0x822F88E8` = 360/65536, not the voices' 360/65535).
pub const PAN_DEGREES: f32 = f32::from_bits(0x3BB4_0000);
/// `0x821BCD64`: the step code's height difference between the feet's last plants (m).
pub const STEP_HEIGHT: f32 = f32::from_bits(0x3D8F_5C29);

/// Retail's Splice bank table index → bank (the report's `SPLC bank indices`; 2 = HOM_Set_1, the
/// collision table's kind 2).
pub fn splice_bank(index: i32) -> Option<&'static str> {
    match index {
        0 => Some("Skate_Collisions"),
        1 => Some("Skate_Metal"),
        2 => Some("HOM_Set_1"),
        7 => Some("sk8_foley"),
        _ => None,
    }
}

/// A vault `Sk8::PointNegGraphData16` curve (16 points: x at record `+16`, y at `+80`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Curve {
    pub x: [f32; 16],
    pub y: [f32; 16],
}

impl Curve {
    pub const fn from_bits(x: [u32; 16], y: [u32; 16]) -> Self {
        let mut c = Curve { x: [0.0; 16], y: [0.0; 16] };
        let mut i = 0;
        while i < 16 {
            c.x[i] = f32::from_bits(x[i]);
            c.y[i] = f32::from_bits(y[i]);
            i += 1;
        }
        c
    }

    /// `sub_82481E10`: below x0 → y0, from x15 on → y15, else the linear piece (y[i] where two x
    /// coincide), `fmadds` order.
    pub fn eval(&self, v: f32) -> f32 {
        let (x, y) = (&self.x, &self.y);
        if v < x[0] {
            return y[0];
        }
        if !(v < x[15]) {
            return y[15];
        }
        for i in 1..16 {
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

    /// The word the owner stores (`fctiwz`).
    pub fn word(&self, v: f32) -> i32 {
        trunc_clamp(self.eval(v), i32::MIN, i32::MAX)
    }
}

/// The FootStep SubMix's EQ of a sound (class `370AF2704BFA6866` record: `+20` HI20 cutoff,
/// `+16` LI20 cutoff, `+12` / `+8` / `+4` PI20 centre / linear gain / Q, `+0` the slot gain).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SubmixEq {
    pub high_pass: f32,
    pub low_pass: f32,
    pub peak_freq: f32,
    pub peak_gain: f32,
    pub peak_q: f32,
    pub gain: f32,
}

impl SubmixEq {
    /// The slot defaults `sub_824D7CE8` writes (filters open, PI20 flat, gain 1).
    pub const SLOT: SubmixEq = SubmixEq { high_pass: 0.0, low_pass: 96_000.0, peak_freq: 96_000.0, peak_gain: 1.0, peak_q: 3.0, gain: 1.0 };
    /// The class's `default` collection (key `D7EDBD362D7D2152`): the record of every sound
    /// without its own entry.
    pub const DEFAULT: SubmixEq =
        SubmixEq { high_pass: 0.0, low_pass: 96_000.0, peak_freq: 96_000.0, peak_gain: 1.0, peak_q: 3.0, gain: f32::from_bits(0x3DB8_51EC) };
}

/// What the FootStep SubMix of a starting sound is set to (latched at the start).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Submix {
    pub eq: SubmixEq,
    /// Sen0 #1 → the env bus: OffBoard level(8) / 32767 as of the last update.
    pub env: f32,
    /// Pn21: OffBoard raw(0) × 360/65536 degrees as of the last update.
    pub azimuth: f32,
    /// The slot's graph (foot A slots 0..3, foot B 4..7; [`crate::bus::submix`]).
    pub graph: u8,
}

impl Submix {
    /// What `sub_82494550` posts to the slot's graph.
    pub fn params(&self) -> crate::bus::submix::SubmixParams {
        let e = &self.eq;
        crate::bus::submix::SubmixParams {
            high_pass: e.high_pass,
            low_pass: e.low_pass,
            peak_freq: e.peak_freq,
            peak_gain: e.peak_gain,
            peak_q: e.peak_q,
            env: self.env,
            azimuth: self.azimuth,
        }
    }
}

/// One material's footstep fields of its AudioSurface record (class `D40CB4C0FFE45676`, key from
/// the image table `0x8302D6E8`).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct FootstepMaterial {
    /// The image table's kind word (Splice bank: 0 Skate_Collisions, 1 Skate_Metal, 2 HOM_Set_1,
    /// −1 none).
    pub kind: i32,
    /// `+125` (`B1CF62EA632CF13F`): the material has footstep sounds.
    pub enabled: bool,
    /// `+48` (`37320DF00471F91A`) and `9D6068AB16703650` (landings, bucket > 1): the slot gain × 32767.
    pub gain: i32,
    pub landing_gain: i32,
    /// [walk, run, landing]: kind 0 `+64` / `+60` / `+104` (`BFABF634D2B1E45A`, `EF9BD81F9CFF725F`,
    /// `A3ADCA7B19287B5D`), kind 1 `+80` / `+76` / `+84` (`66A95889604DED36`, `B722B88FE44B046E`,
    /// `1411108A7E9CC74A`), kind 2 walk = `sub_824825D0` (the HOM_Set_1 tier-0 field
    /// `137C683BFB506ECA` per the collision export, UNCERTAIN), run `5432B35224E4B1C1`, landing
    /// `3FCBE0407F833721` (never selected: kind 2 ignores the bucket). The collision export's
    /// `ids` hold them: see [`FootstepMaterial::from_collision`].
    pub ids: [i32; 3],
}

impl FootstepMaterial {
    /// From the collision manager's material row (`collision::Material`: kind, the seven sample ids
    /// [tier 2, tier 0 × class 0..2, tier 1 × class 0..2]) and the three footstep fields setup must
    /// add (`+125`, `+48`, `9D6068AB16703650`): walk = tier 0 class 0, run = tier 1 class 0,
    /// landing = tier 1 class 1 — the same record offsets.
    pub fn from_collision(kind: i32, ids: &[i32; 7], enabled: bool, gain: i32, landing_gain: i32) -> Self {
        Self { kind, enabled, gain, landing_gain, ids: [ids[1], ids[4], ids[5]] }
    }
}

/// The OffBoard owner's vault values (holder `0xC1831BDB6CB1B1EA`, collection `0x1ABD2984D7248589`
/// unless named; the Clothing class `0xA867FBE3454326FF` `default` for the walking and jump ids).
/// The defaults are the retail values.
#[derive(Clone, Debug, PartialEq)]
pub struct FootstepTuning {
    /// `C3CD069BB1B16B58` (|COM v| → `+408`), `CF844597AB96EAF8` (foot xz speed → w10),
    /// `236311604A3C1FB5` (foot vertical speed → w9).
    pub walk_curve: Curve,
    pub xz_curve: Curve,
    pub vertical_curve: Curve,
    /// `729D6290FB6A8E3B`: running for the surface layers when `+408` is above it; `E82237E2D18B5C5F`:
    /// the step layers' run mode when `+408` reaches it.
    pub run_threshold: i32,
    pub mode_threshold: i32,
    /// `636464FBAD0D71A3`: packet words 18..23.
    pub tail: [i32; 6],
    /// eEQChain `C014A21D0FF6EDBA` (holder `42AFE160E647167C`): the packets' w24 = this + 10.
    pub eq_chain: i32,
    /// `sub_82493690` layer 0 (`sk8_foley`) by [run mode][step code 2 or 4][footstep surface 1..7].
    pub step_ids: [[[i32; 7]; 2]; 2],
    /// Layer 1 (`Skate_Collisions`) on footstep surfaces 3 and 4, same indexing.
    pub step_ids_hard: [[[i32; 2]; 2]; 2],
    /// `sub_82493E60` on footstep surface 7 (`Skate_Collisions`) and 5 (`Skate_Metal`):
    /// [landing (bucket > 1), walk, run][layer].
    pub surface7_ids: [[i32; 2]; 3],
    pub surface5_ids: [[i32; 2]; 3],
    /// Clothing `E12AF885D3C3A168`: |COM v| thresholds [fast, mid] of the walking voices; ids
    /// (slow, mid, fast) `6B61C043E53C44CB`, `EC3399A49055DD8D`, `9D6D2863CFE908C4` (`sk8_foley`) and
    /// `F0292A62D280EB40`, `E420F7DD48E01E0E`, `67717E2388A836ED` (`Skate_Collisions`).
    pub walk_speeds: [f32; 2],
    pub walk_ids: [i32; 3],
    pub walk_ids_hard: [i32; 3],
    /// Clothing `default`: take-off [off the feet `200AB82413E0FF3D`, bucket 1 `65E8997F265A4191`,
    /// bucket 2 `76DE6529A45AC896`, else `FCBAFB90598F3B83`] and apex [`A3A1BB4E3ACD6927`,
    /// `9913D205D51E5F24`, `8AA9F40C9CEABCA6`, `F0F46BA2D527E511`] (`sk8_foley`).
    pub jump_ids: [i32; 4],
    pub apex_ids: [i32; 4],
    /// `60B043CCA6F211C3` (Skate_Collisions ids) and `CA945189654051D3` (other banks): the sounds
    /// with their own EQ record; everything else reads [`SubmixEq::DEFAULT`].
    pub eq_collision: Vec<(i32, SubmixEq)>,
    pub eq_other: Vec<(i32, SubmixEq)>,
    /// Materials 0..142 (setup export; empty: no material footstep layer).
    pub materials: Vec<FootstepMaterial>,
    /// The water splash (`sub_824EBB58`): the AudioSurface-class (`923CCB46EF5BF5BA`) record
    /// `water`'s Skate_Collisions ids — under the surface `35D3B06292CDA10B` (1187), or
    /// `C17485220849574D` (1197) once the time in water reaches `9CD13431903E3719` (0.001 s); the
    /// board in water `BA81E93AE985D1C7` (1198).
    pub splash_ids: [u32; 3],
    pub splash_time: f32,
}

const fn eq(gain: u32, q: u32, peak_gain: u32, peak_freq: u32, low_pass: u32, high_pass: u32) -> SubmixEq {
    SubmixEq {
        gain: f32::from_bits(gain),
        peak_q: f32::from_bits(q),
        peak_gain: f32::from_bits(peak_gain),
        peak_freq: f32::from_bits(peak_freq),
        low_pass: f32::from_bits(low_pass),
        high_pass: f32::from_bits(high_pass),
    }
}

impl Default for FootstepTuning {
    fn default() -> Self {
        // The vault records (class 370AF2704BFA6866) as fields +0, +4, +8, +12, +16, +20.
        let e962 = eq(0x0000_0000, 0x4040_0000, 0x3F80_0000, 0x44BB_8000, 0x459C_4000, 0x43AF_0000);
        let e960 = eq(0x3F80_0000, 0x3F00_0000, 0x3DCC_CCCD, 0x45A2_8000, 0x45BB_8000, 0x437A_0000);
        let e961 = eq(0x3CA3_D70A, 0x3ECC_CCCD, 0x3E99_999A, 0x45BB_8000, 0x45BB_8000, 0x437A_0000);
        let e959 = eq(0x3F80_0000, 0x3F00_0000, 0x3DCC_CCCD, 0x45A2_8000, 0x45DA_C000, 0x4348_0000);
        let e518 = eq(0x3F80_0000, 0x4040_0000, 0x3F80_0000, 0x44BB_8000, 0x459C_4000, 0x43AF_0000);
        let e519 = eq(0x4000_0000, 0x3F00_0000, 0x3DCC_CCCD, 0x45A2_8000, 0x45BB_8000, 0x437A_0000);
        let m459 = eq(0x3F99_999A, 0x3F00_0000, 0x3DCC_CCCD, 0x4396_0000, 0x4422_8000, 0x4396_0000);
        let m460 = eq(0x3F80_0000, 0x3F00_0000, 0x3DCC_CCCD, 0x453B_8000, 0x44FA_0000, 0x4396_0000);
        let m455 = eq(0x3F80_0000, 0x3F00_0000, 0x3DCC_CCCD, 0x4396_0000, 0x4422_8000, 0x43C8_0000);
        let m456 = eq(0x3F40_0000, 0x3F00_0000, 0x3DCC_CCCD, 0x453B_8000, 0x44FA_0000, 0x43C8_0000);
        let m323 = eq(0x4000_0000, 0x3F00_0000, 0x3DCC_CCCD, 0x4396_0000, 0x4422_8000, 0x4396_0000);
        let m324 = eq(0x4000_0000, 0x3F00_0000, 0x3DCC_CCCD, 0x453B_8000, 0x44FA_0000, 0x4396_0000);
        Self {
            walk_curve: Curve::from_bits(
                [
                    0x0000_0000, 0x3EF1_D2F8, 0x3FCC_CCCD, 0x4000_0000, 0x4020_0000, 0x4060_0000, 0x4088_06AB, 0x40A4_2B5C, 0x40C0_D57A,
                    0x40E0_1AAE, 0x40EB_0C82, 0x4103_DB4F, 0x410B_EF53, 0x4112_305E, 0x4117_A947, 0x411F_BD4A,
                ],
                [
                    0x0000_0000, 0x42D2_0000, 0x434D_0000, 0x434D_0000, 0x437A_0000, 0x4398_8000, 0x43AF_0000, 0x43B1_AF9A, 0x43CC_8BA3,
                    0x43CE_9C8F, 0x4400_1964, 0x4401_21D9, 0x4400_1964, 0x4400_1964, 0x4401_21D9, 0x4401_21D9,
                ],
            ),
            xz_curve: Curve::from_bits(
                [
                    0x0000_0000, 0x3E99_999A, 0x3F85_6B90, 0x4008_8C15, 0x4057_C3F8, 0x4088_8C17, 0x40A3_2086, 0x40C5_8640, 0x40E3_C0A0,
                    0x40F7_092D, 0x4107_3E8B, 0x4110_5D65, 0x4115_9399, 0x4118_B41E, 0x411B_0C82, 0x411F_7A94,
                ],
                [
                    0x0000_0000, 0x4404_3B3D, 0x4402_2A51, 0x4400_1964, 0x4400_1964, 0x4401_21D9, 0x4401_21D9, 0x4402_2A51, 0x4401_21D9,
                    0x4401_21D9, 0x4402_2A51, 0x4400_1964, 0x4402_2A51, 0x4402_2A51, 0x4400_1964, 0x4403_32C7,
                ],
            ),
            vertical_curve: Curve::from_bits(
                [
                    0x0000_0000, 0x3F00_0000, 0x3F80_0000, 0x401C_5A0C, 0x405E_0503, 0x4094_88C0, 0x40B4_9618, 0x40DA_E47A, 0x40FE_DA79,
                    0x4114_88C1, 0x4117_4535, 0x4122_370D, 0x4131_1188, 0x413E_BFD1, 0x414E_C67E, 0x415C_D8CD,
                ],
                [
                    0x4000_0000, 0x4000_0000, 0, 0, 0, 0, 0, 0, 0, 0, 0x4060_CB1D, 0x4081_9637, 0x40A1_5283, 0x40DA_2E90, 0x40EE_043A,
                    0x4104_E47E,
                ],
            ),
            run_threshold: 400,
            mode_threshold: 400,
            tail: [32767, 10000, 15000, 25000, 32767, 28000],
            eq_chain: 2,
            step_ids: [
                // walk mode: step codes 1/3/5, then 2/4
                [[86, 82, 86, 91, 86, 78, 75], [87, 83, 87, 91, 107, 79, 110]],
                // run mode
                [[107, 102, 105, 105, 105, 99, 101], [104, 103, 104, 106, 104, 100, 100]],
            ],
            step_ids_hard: [[[963, 964], [963, 964]], [[963, 964], [522, 523]]],
            surface7_ids: [[519, 518], [959, 961], [960, 962]],
            surface5_ids: [[323, 324], [455, 458], [459, 460]],
            walk_speeds: [7.5, 2.5],
            walk_ids: [62, 63, 64],
            walk_ids_hard: [1121, 1122, 1123],
            jump_ids: [65, 69, 71, 67],
            apex_ids: [66, 70, 72, 68],
            eq_collision: vec![(962, e962), (960, e960), (961, e961), (959, e959), (518, e518), (519, e519)],
            eq_other: vec![(459, m459), (460, m460), (455, m455), (456, m456), (457, m455), (458, m456), (323, m323), (324, m324)],
            materials: Vec::new(),
            splash_ids: [1187, 1197, 1198],
            splash_time: f32::from_bits(0x3A83_126F),
        }
    }
}

impl FootstepTuning {
    /// `sub_82493448`: the EQ record of a started sound (bank 0 searches the collision list,
    /// any other bank the metal list; no entry → the `default` record).
    pub fn eq_record(&self, bank: i32, id: i32) -> SubmixEq {
        let list = if bank == 0 { &self.eq_collision } else { &self.eq_other };
        list.iter().find(|(i, _)| *i == id).map_or(SubmixEq::DEFAULT, |(_, e)| *e)
    }

    fn material(&self, m: u32) -> Option<&FootstepMaterial> {
        self.materials.get(m as usize)
    }

    /// `sub_824975D8`: (bank, id) of a material's footstep, id −1 = none.
    pub fn material_sound(&self, m: u32, run: bool, bucket: i32) -> (i32, i32) {
        let Some(r) = self.material(m) else { return (0, -1) };
        if !r.enabled {
            return (0, -1);
        }
        let id = match r.kind {
            0 | 1 => {
                if bucket > 1 {
                    r.ids[2]
                } else if run {
                    r.ids[1]
                } else {
                    r.ids[0]
                }
            }
            2 => {
                if run {
                    r.ids[1]
                } else {
                    r.ids[0]
                }
            }
            // Kinds ≥ 3 (none on the disc) leave the id at 0; −1 reads as unsigned and does the same.
            _ => 0,
        };
        (r.kind, id)
    }

    /// `sub_824977C8`: the slot gain of a material's footstep (`+48`, landings the
    /// `9D6068AB16703650` field) × 1/32767.
    pub fn material_gain(&self, m: u32, bucket: i32) -> f32 {
        let Some(r) = self.material(m) else { return 0.0 };
        let g = if bucket > 1 { r.landing_gain } else { r.gain };
        g as f32 * LEVEL
    }
}

/// AudioSurfaceMap word 6 (`+24`, `sub_82494F58`): the footstep surface of a material (1 without a
/// table: the clamp floor of the packet word).
pub fn footstep_surface(t: &PlayerTuning, m: u32) -> i32 {
    t.surface_entry(m).map_or(1, |e| e[6])
}

/// `sub_82493E60`: (bank, id) of a surface layer (0 or 1), id −1 = none.
pub fn surface_sound(t: &PlayerTuning, ft: &FootstepTuning, run: bool, bucket: i32, layer: usize, m: u32) -> (i32, i32) {
    let s = footstep_surface(t, m);
    if s == 7 || s == 5 {
        let (bank, ids) = if s == 7 { (0, &ft.surface7_ids) } else { (1, &ft.surface5_ids) };
        let row = if bucket > 1 {
            0
        } else if run {
            2
        } else {
            1
        };
        return (bank, ids[row][layer.min(1)]);
    }
    if layer != 0 || m >= NO_MATERIAL {
        return (0, -1);
    }
    ft.material_sound(m, run, bucket)
}

/// `sub_82493690`: (bank, id) of a step layer, id −1 = none. `run` = the run mode (2).
pub fn step_sound(t: &PlayerTuning, ft: &FootstepTuning, run: bool, m: u32, code: i32, layer: usize) -> (i32, i32) {
    let s = footstep_surface(t, m);
    let uneven = !matches!(code, 1 | 3 | 5);
    let (r, u) = (usize::from(run), usize::from(uneven));
    if layer == 0 {
        let id = if (1..=7).contains(&s) { ft.step_ids[r][u][(s - 1) as usize] } else { -1 };
        (7, id)
    } else {
        let id = match s {
            3 => ft.step_ids_hard[r][u][0],
            4 => ft.step_ids_hard[r][u][1],
            _ => -1,
        };
        (0, id)
    }
}

/// `sub_824940F8`: the material's own slot gain, when its footstep record applies.
pub fn material_override(t: &PlayerTuning, ft: &FootstepTuning, m: u32, bucket: i32) -> Option<f32> {
    let s = footstep_surface(t, m);
    if s == 7 || s == 5 || m >= NO_MATERIAL {
        return None;
    }
    if ft.material_sound(m, false, bucket).1 == -1 {
        return None;
    }
    Some(ft.material_gain(m, bucket))
}

/// One foot sound slot of a holder (`sub_824D7CE8`: sound, EQ floats, gain; its submix graph).
#[derive(Clone, Copy, Debug, PartialEq)]
struct FootSlot {
    sound: Option<SoundId>,
    eq: SubmixEq,
}

impl Default for FootSlot {
    fn default() -> Self {
        Self { sound: None, eq: SubmixEq::SLOT }
    }
}

/// `SFXObj_OffBoard`'s footstep state (owner offsets in the field docs).
#[derive(Clone, Debug, PartialEq)]
pub struct Footsteps {
    /// `+54` / `+238`: last frame's foot-down copies (A, B).
    was_down: [bool; 2],
    /// `+460` last frame's footplant (`+768`), `+404` on foot, `+405` OffboardAir.
    was_footplant: bool,
    was_on_foot: bool,
    was_offboard_air: bool,
    /// `+464` / `+468`.
    countdown: [i32; 2],
    /// `+408` walk word, `+412` / `+416` xz words (A, B), `+420` / `+424` vertical words (A, B).
    walk: i32,
    xz: [i32; 2],
    vertical: [i32; 2],
    /// `+56` / `+240`: the feet's materials (143 → 3).
    material: [u32; 2],
    /// Holders `+36` (A) / `+220` (B): the packet, its env level (`+8`) and azimuth (`+12`), and
    /// the four sound slots.
    packets: [Option<Vec<i32>>; 2],
    env: [f32; 2],
    azimuth: [i32; 2],
    slots: [[FootSlot; 4]; 2],
    /// Walking voices: `sk8_foley` `+432` (A) / `+428` (B), `Skate_Collisions` `+440` / `+436`.
    walking: [Option<SoundId>; 2],
    walking_hard: [Option<SoundId>; 2],
    /// Jump voices: take-off `+444` (kept after it ends: its slot is only cleared by a restart or
    /// the apex), apex `+448`; `+456` last frame's "falling" (2 at start), `+452` last hippy jump,
    /// `+472` the take-off's jump bucket, `+476` it was off the feet.
    jump: Option<SoundId>,
    apex: Option<SoundId>,
    falling: i32,
    was_hippy: bool,
    jump_bucket: u32,
    from_feet: bool,
    /// The water splash (`sub_824EBB58` / `sub_824EBE78`).
    pub splash: Splash,
    /// Sounds started (diagnostics).
    pub starts: u64,
}

impl Default for Footsteps {
    fn default() -> Self {
        Self {
            was_down: [false; 2],
            was_footplant: false,
            was_on_foot: false,
            was_offboard_air: false,
            countdown: [0; 2],
            walk: 0,
            xz: [0; 2],
            vertical: [0; 2],
            material: [3; 2],
            packets: [None, None],
            env: [0.0; 2],
            azimuth: [0; 2],
            slots: [[FootSlot::default(); 4]; 2],
            walking: [None; 2],
            walking_hard: [None; 2],
            jump: None,
            apex: None,
            falling: 2,
            was_hippy: false,
            jump_bucket: 0,
            from_feet: false,
            splash: Splash::default(),
            starts: 0,
        }
    }
}

fn start_block(dt: f32, spread: f32) -> [f32; 6] {
    [0.0, 1.0, 0.0, dt, spread, 1.0]
}

fn master() -> crate::bus::Route {
    crate::bus::Route::default()
}

impl Footsteps {
    /// The constructor's words (`sub_824B73E0` as the poster calls it).
    pub fn post_words(ft: &FootstepTuning) -> Vec<i32> {
        let mut w = vec![0i32; WORDS];
        w[2] = 4096;
        w[4] = 25000;
        w[7] = 32767;
        w[12] = 1;
        w[13] = 1;
        w[16] = 1;
        w[17] = 1;
        w[24] = (ft.eq_chain + 10).clamp(0, 32767);
        w
    }

    /// One frame before the MixMap tick (`sub_824E9270`). OffBoard.in0 is written by
    /// [`super::inputs::write_off_board`].
    pub fn process(&mut self, s: &AudioState, t: &PlayerTuning, ft: &FootstepTuning, host: &mut dyn SpliceHost) -> Vec<Command> {
        let footplant_ended = !s.footplant && self.was_footplant;
        self.walk = ft.walk_curve.word(s.com_speed());
        self.xz = [ft.xz_curve.word(s.foot_xz_speed[0]), ft.xz_curve.word(s.foot_xz_speed[1])];
        self.vertical = [ft.vertical_curve.word(s.foot_vertical_speed[0]), ft.vertical_curve.word(s.foot_vertical_speed[1])];
        if footplant_ended {
            if self.was_down[0] {
                self.countdown[0] = 10;
            } else if self.was_down[1] {
                self.countdown[1] = 10;
            }
        }
        for c in &mut self.countdown {
            if *c > 0 {
                *c -= 1;
            }
        }
        let cmds = self.poster(s, t, ft, host);
        if s.on_foot {
            self.walking_voices(s, ft, host);
        }
        self.jump_voices(s, ft, footplant_ended, host);
        self.was_on_foot = s.on_foot;
        self.was_footplant = s.footplant;
        self.was_down = s.foot_down;
        self.was_offboard_air = s.offboard_air;
        self.splash.process(s, ft, host);
        cmds
    }

    /// `sub_824E9FD8`.
    fn poster(&mut self, s: &AudioState, t: &PlayerTuning, ft: &FootstepTuning, host: &mut dyn SpliceHost) -> Vec<Command> {
        let mut cmds = Vec::new();
        let rising = [s.foot_down[0] && !self.was_down[0], s.foot_down[1] && !self.was_down[1]];
        self.material = s.foot_material.map(|m| if m == NO_MATERIAL { 3 } else { m });
        for foot in [1usize, 0] {
            if self.packets[foot].is_none() {
                let words = Self::post_words(ft);
                cmds.push(Command::Post { slot: Slot::Footstep(foot as u8), class: CLASS, words: words.clone() });
                self.packets[foot] = Some(words);
            }
        }
        let run = self.walk > ft.run_threshold;
        let run_mode = self.walk >= ft.mode_threshold;
        for foot in 0..2 {
            if !(rising[foot] && s.local) {
                continue;
            }
            self.foot_down(foot, s, t, ft, run, run_mode, host);
        }
        cmds
    }

    /// The local player's sounds of a foot that came down.
    #[allow(clippy::too_many_arguments)]
    fn foot_down(&mut self, foot: usize, s: &AudioState, t: &PlayerTuning, ft: &FootstepTuning, run: bool, run_mode: bool, host: &mut dyn SpliceHost) {
        for slot in &mut self.slots[foot] {
            if let Some(sound) = slot.sound.take() {
                host.release(sound);
            }
        }
        let m = self.material[foot];
        let bucket = s.landing_bucket;
        let block = start_block(s.dt, 1.0);
        let (bank, id) = surface_sound(t, ft, run, bucket, 0, m);
        if id != -1 {
            let rec = ft.eq_record(bank, id);
            let gain = material_override(t, ft, m, bucket).unwrap_or(rec.gain);
            self.slots[foot][0].eq = SubmixEq { gain, ..rec };
            self.start_slot(foot, 0, bank, id, block, host);
            let (bank, id) = surface_sound(t, ft, run, bucket, 1, m);
            if id != -1 {
                self.slots[foot][1].eq = ft.eq_record(bank, id);
                self.start_slot(foot, 1, bank, id, block, host);
            }
        }
        let code = s.step_code;
        for layer in 0..2 {
            let (bank, id) = step_sound(t, ft, run_mode, m, code, layer);
            if id != -1 {
                self.start_slot(foot, 2 + layer, bank, id, block, host);
            }
        }
    }

    fn start_slot(&mut self, foot: usize, slot: usize, bank: i32, id: i32, block: [f32; 6], host: &mut dyn SpliceHost) {
        let Some(name) = splice_bank(bank) else { return };
        let eq = self.slots[foot][slot].eq;
        let env = self.env[foot];
        host.set_route(crate::bus::Route { output: crate::bus::Output::Master, create: false, owner_env: env, mono: false });
        host.set_submix(Some(Submix { eq, env, azimuth: self.azimuth[foot] as f32 * PAN_DEGREES, graph: (foot * 4 + slot) as u8 }));
        self.slots[foot][slot].sound = host.start(name, id as u32, block);
        self.starts += u64::from(self.slots[foot][slot].sound.is_some());
    }

    /// `sub_824E9D10` (on foot): `sk8_foley` by |COM v| for each foot that came down, plus the
    /// `Skate_Collisions` layer for the local player with `+308`.
    fn walking_voices(&mut self, s: &AudioState, ft: &FootstepTuning, host: &mut dyn SpliceHost) {
        let rising = [s.foot_down[0] && !self.was_down[0], s.foot_down[1] && !self.was_down[1]];
        let hard = s.local && s.on_foot && s.offboard_308;
        let v = s.com_speed();
        let pick = if v > ft.walk_speeds[0] {
            2
        } else if v > ft.walk_speeds[1] {
            1
        } else {
            0
        };
        let block = start_block(s.dt, 1.0);
        for foot in 0..2 {
            if !rising[foot] {
                continue;
            }
            if let Some(old) = self.walking[foot].take() {
                host.release(old);
            }
            host.set_route(master());
            self.walking[foot] = host.start("sk8_foley", ft.walk_ids[pick] as u32, block);
            self.starts += u64::from(self.walking[foot].is_some());
            if hard {
                if let Some(old) = self.walking_hard[foot].take() {
                    host.release(old);
                }
                host.set_route(master());
                self.walking_hard[foot] = host.start("Skate_Collisions", ft.walk_ids_hard[pick] as u32, block);
                self.starts += u64::from(self.walking_hard[foot].is_some());
            }
        }
    }

    /// `sub_824E9678`.
    fn jump_voices(&mut self, s: &AudioState, ft: &FootstepTuning, footplant_ended: bool, host: &mut dyn SpliceHost) {
        let off_feet = s.on_foot && s.offboard_air && !self.was_offboard_air;
        let vy = s.com_velocity[1];
        let (falling, began) = if vy <= 0.0 { (1, self.falling == 0) } else { (0, false) };
        self.falling = falling;
        let apex = self.jump.is_some() && began;
        let hippy = !self.was_hippy && s.hippy_jump;
        let spread = if s.local { 1.0 } else { 0.0 };
        let block = start_block(s.dt, spread);
        let bucket_id = |ids: &[i32; 4], bucket: u32| match bucket {
            1 => ids[1],
            2 => ids[2],
            _ => ids[3],
        };
        if off_feet || hippy || footplant_ended {
            if let Some(old) = self.jump.take() {
                host.release(old);
            }
            self.jump_bucket = s.jump_bucket;
            let id = if off_feet { ft.jump_ids[0] } else { bucket_id(&ft.jump_ids, self.jump_bucket) };
            host.set_route(master());
            self.jump = host.start("sk8_foley", id as u32, block);
            self.starts += u64::from(self.jump.is_some());
            self.from_feet = off_feet;
        }
        if apex {
            if let Some(old) = self.jump.take() {
                host.release(old);
            }
            if let Some(old) = self.apex.take() {
                host.release(old);
            }
            let id = if self.from_feet { ft.apex_ids[0] } else { bucket_id(&ft.apex_ids, self.jump_bucket) };
            host.set_route(master());
            self.apex = host.start("sk8_foley", id as u32, block);
            self.starts += u64::from(self.apex.is_some());
        }
        self.was_hippy = s.hippy_jump;
    }

    /// The packet words of foot `foot` (`sub_824EAEA8`).
    fn packet_words(&self, foot: usize, w: &mut [i32], s: &AudioState, t: &PlayerTuning, ft: &FootstepTuning, out: &dyn Outputs) {
        w[0] = 32767;
        w[1] = out.raw(0).clamp(0, 65535);
        w[2] = out.pitch(1).clamp(0, 8192);
        w[4] = out.level(4).clamp(0, 25001);
        w[5] = out.level(5).clamp(0, 25001);
        w[6] = out.level(6).clamp(0, 32767);
        w[7] = out.level(2).clamp(0, 32767);
        w[8] = i32::from(s.foot_down[foot]);
        w[9] = self.vertical[foot].clamp(0, 1000);
        w[10] = self.xz[foot].clamp(0, 1000);
        w[11] = i32::from(self.countdown[foot] > 0 || self.jump.is_some());
        w[12] = s.landing_bucket.clamp(1, 4);
        w[13] = trunc_clamp(s.footstep_strength, i32::MIN, i32::MAX).clamp(1, 99);
        w[14] = self.walk.clamp(0, 1000);
        w[15] = 1;
        w[16] = footstep_surface(t, self.material[foot]).clamp(1, 7);
        w[17] = s.step_code.clamp(1, 5);
        for (i, v) in ft.tail.iter().enumerate() {
            w[18 + i] = (*v).clamp(0, 32767);
        }
    }

    /// One frame after the MixMap tick (`sub_824E9628`); `out` = the OffBoard outputs.
    pub fn update(&mut self, s: &AudioState, t: &PlayerTuning, ft: &FootstepTuning, out: &dyn Outputs, host: &mut dyn SpliceHost) -> Vec<Command> {
        let mut cmds = Vec::new();
        if self.packets[0].is_some() && self.packets[1].is_some() {
            for foot in 0..2 {
                let mut w = self.packets[foot].take().unwrap();
                self.packet_words(foot, &mut w, s, t, ft, out);
                cmds.push(Command::Redeliver { slot: Slot::Footstep(foot as u8), words: w.clone() });
                self.packets[foot] = Some(w);
            }
            if s.local {
                // The level of every foot sound: level(7), level(11) when foot A's material has
                // its own footstep record.
                let id = if material_override(t, ft, self.material[0], s.landing_bucket).is_some() { 11 } else { 7 };
                let level = out.level(id) as f32 * LEVEL;
                let env = out.level(8) as f32 * LEVEL;
                let block = [0.0, out.pitch(1) as f32 * PITCH, 0.0, s.dt, 1.0, 1.0];
                for foot in 0..2 {
                    self.azimuth[foot] = out.raw(0);
                    self.env[foot] = env;
                    // sub_82494C08 walks slots 0, 2, 1, 3.
                    for slot in [0usize, 2, 1, 3] {
                        let FootSlot { sound, eq } = self.slots[foot][slot];
                        let Some(sound) = sound else { continue };
                        if host.alive(sound) {
                            let mut b = block;
                            b[0] = eq.gain * level;
                            host.update(sound, b);
                        } else {
                            host.release(sound);
                            self.slots[foot][slot].sound = None;
                        }
                    }
                }
            }
        }
        let spread = if s.local { 1.0 } else { 0.0 };
        let block = |level: i32| -> [f32; 6] {
            [level as f32 * LEVEL, out.pitch(1) as f32 * PITCH, out.raw(0) as f32 * DEGREES, s.dt, spread, 1.0]
        };
        // sub_824EA9C8 (level 3, A then B) and sub_824EAC38 (level 12).
        for (voices, level) in [(&mut self.walking, 3usize), (&mut self.walking_hard, 12)] {
            for foot in [0usize, 1] {
                let Some(sound) = voices[foot] else { continue };
                if host.alive(sound) {
                    host.update(sound, block(out.level(level)));
                } else {
                    host.release(sound);
                    voices[foot] = None;
                }
            }
        }
        // sub_824E9AB8: the take-off keeps its slot when it ends; the apex is freed.
        if let Some(sound) = self.jump {
            if host.alive(sound) {
                host.update(sound, block(out.level(9)));
            }
        }
        if let Some(sound) = self.apex {
            if host.alive(sound) {
                host.update(sound, block(out.level(10)));
            } else {
                host.release(sound);
                self.apex = None;
            }
        }
        self.splash.update(s, out, host);
        cmds
    }
}

/// OffBoard's water splash (`sub_824EBB58`, at the end of the process, every frame for an active
/// record; `sub_824EBE78`, at the end of the update). Owner offsets in the field docs.
///
/// - `+811` in water (state `+81`): on its rise the time in water `+480` starts at 0, then counts
///   `dt` per frame; on its fall both latches clear.
/// - `+812` under the surface, once per water stay (`+478`): unless `+224`, the entry sound `+484`
///   is stopped and Skate_Collisions [`FootstepTuning::splash_ids`] 0 (1187) starts — or 1 (1197)
///   when the time in water has reached [`FootstepTuning::splash_time`], i.e. from the frame after
///   the water contact on. (With `+224` the latch is still taken: no sound for this stay.)
/// - `+813` the board in water, once per rise (`+492`): `+488` is stopped and id 2 (1198) starts.
///
/// Both through the collision Splice object (`sub_82497F48`: SFX Master, start block
/// [0, 1, 0, 0, 1, 1]); updated with [level(13) (`+484`) / level(16) (`+488`) / 32767,
/// pitch(14) / 4096, raw(0) × 360/65535, dt, 0, 1] and the env send level(15) / 32767
/// (`sub_82498140`; as the grind on / off sounds, the env level of the last update is latched at
/// each start). A sound that ended is released.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Splash {
    /// `+477` in water last frame, `+480` the time in water, `+478` the entry sound taken.
    in_water: bool,
    time: f32,
    entered: bool,
    /// `+492` the board was in water last frame.
    board: bool,
    /// `+484` the entry sound, `+488` the board's.
    entry: Option<SoundId>,
    board_sound: Option<SoundId>,
    /// level(15) as of the last update.
    env_level: i32,
    /// Sounds started, and the id of the last (diagnostics).
    pub starts: u64,
    pub last_id: u32,
}

impl Splash {
    pub fn process(&mut self, s: &AudioState, ft: &FootstepTuning, host: &mut dyn SpliceHost) {
        if s.in_water {
            if self.in_water {
                self.time += s.dt;
            } else {
                self.in_water = true;
                self.time = 0.0;
            }
        } else if self.in_water {
            self.in_water = false;
            self.entered = false;
        }
        if s.under_water && !self.entered {
            if !s.global_224 {
                if let Some(old) = self.entry.take() {
                    host.release(old);
                }
                let id = if self.time >= ft.splash_time { ft.splash_ids[1] } else { ft.splash_ids[0] };
                self.entry = self.start(id, host);
            }
            self.entered = true;
        }
        if s.board_in_water {
            if !self.board {
                if let Some(old) = self.board_sound.take() {
                    host.release(old);
                }
                self.board_sound = self.start(ft.splash_ids[2], host);
            }
            self.board = true;
        } else {
            self.board = false;
        }
    }

    fn start(&mut self, id: u32, host: &mut dyn SpliceHost) -> Option<SoundId> {
        host.set_route(crate::bus::Route {
            output: crate::bus::Output::Master,
            create: false,
            owner_env: self.env_level as f32 * LEVEL,
            mono: true,
        });
        let sound = host.start("Skate_Collisions", id, [0.0, 1.0, 0.0, 0.0, 1.0, 1.0]);
        if sound.is_some() {
            self.starts += 1;
            self.last_id = id;
        }
        sound
    }

    pub fn update(&mut self, s: &AudioState, out: &dyn Outputs, host: &mut dyn SpliceHost) {
        self.env_level = out.level(15);
        for (sound, level) in [(&mut self.entry, 13usize), (&mut self.board_sound, 16)] {
            let Some(id) = *sound else { continue };
            if host.alive(id) {
                host.update(id, [out.level(level) as f32 * LEVEL, out.pitch(14) as f32 * PITCH, out.raw(0) as f32 * DEGREES, s.dt, 0.0, 1.0]);
            } else {
                host.release(id);
                *sound = None;
            }
        }
    }
}

/// The audio conditioner's step code (`sub_827729B8` → state `+740`): which foot planted higher
/// than the other (by more than 7 cm) at their last plants, and whether the surface under foot
/// B is physics class 8. Feed it every frame.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct StepCode {
    /// `+736` / `+738`: the feet's retained surface tags (OffBoard `+52` / `+56`).
    tags: [u32; 2],
    /// `+740` / `+742` the support flags (OffBoard 306 / 307) of this and `+741` / `+743` last frame.
    support: [bool; 2],
    /// `+708` / `+724`: the plant heights (Skeleton `+144` / `+160` y at the last 306 / 307 plant).
    heights: [f32; 2],
    /// B40 bytes 212 / 213 (kept until the feet plant level).
    up: bool,
    down: bool,
}

impl StepCode {
    /// One frame. `support` = OffBoard 306 / 307, `tags` = OffBoard `+52` / `+56` (raw u16 surface
    /// tags, 0 = keep the last), `heights` = Skeleton `+144` / `+160` y. Returns the code 1..5.
    pub fn update(&mut self, support: [bool; 2], tags: [u32; 2], heights: [f32; 2]) -> i32 {
        for i in 0..2 {
            if tags[i] & 0xFFFF != 0 {
                self.tags[i] = tags[i] & 0xFFFF;
            }
        }
        let class8 = (self.tags[0] >> 7) & 31 == 8;
        let was = self.support;
        self.support = support;
        if support[1] && !was[1] {
            self.heights[1] = heights[1];
        }
        if support[0] && !was[0] {
            self.heights[0] = heights[0];
        }
        let d = self.heights[1] - self.heights[0];
        if !(d.abs() <= STEP_HEIGHT) {
            if support[1] {
                if d <= 0.0 {
                    self.down = true;
                } else {
                    self.up = true;
                }
            } else if support[0] {
                if d <= 0.0 {
                    self.up = true;
                } else {
                    self.down = true;
                }
            }
        } else {
            self.up = false;
            self.down = false;
        }
        if self.up {
            if class8 { 2 } else { 4 }
        } else if self.down {
            if class8 { 3 } else { 5 }
        } else {
            1
        }
    }
}

/// The landing bucket (state `+300`): the conditioner's 4-frame minimum of the COM's vertical
/// velocity (`sub_82772B88`, vault `7385078DD3C063BA` = [1.5, 2.6, 3.45] m/s → 2 / 3 / 4, else
/// 1), forced to 1 by the bridge with a trick (other than audio trick 31) or more than 20 frames
/// after OffboardAir (`+718`, countdown `+720`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LandingBucket {
    ring: [f32; 4],
    at: usize,
    countdown: i32,
    pub thresholds: [f32; 3],
}

impl Default for LandingBucket {
    fn default() -> Self {
        Self { ring: [0.0; 4], at: 0, countdown: 0, thresholds: [1.5, 2.6, 3.45] }
    }
}

fn fsel(a: f32, b: f32, c: f32) -> f32 {
    if a >= 0.0 { b } else { c }
}

impl LandingBucket {
    /// One frame: the COM's vertical velocity (Reckoning `+20`), OffboardAir, the trick flags.
    pub fn update(&mut self, com_vy: f32, offboard_air: bool, trick_active: bool, audio_trick: i32) -> i32 {
        self.ring[self.at] = com_vy;
        let [r0, r1, r2, r3] = self.ring;
        let m = fsel(-r0, r0, 0.0);
        let m = fsel(m - r1, r1, m);
        let m = fsel(m - r2, r2, m);
        let m = fsel(m - r3, r3, m);
        let a = m.abs();
        let t = self.thresholds;
        let bucket = if a > t[2] {
            4
        } else if a > t[1] {
            3
        } else if a > t[0] {
            2
        } else {
            1
        };
        self.at = (self.at + 1) % 4;
        let forced = (trick_active && audio_trick != 31) || self.countdown == 0;
        if offboard_air {
            self.countdown = 20;
        } else if self.countdown > 0 {
            self.countdown -= 1;
        }
        if forced { 1 } else { bucket }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[derive(Default)]
    struct Log {
        started: Vec<(String, u32)>,
        submixes: Vec<Option<Submix>>,
        live: HashMap<SoundId, (String, u32)>,
        next: SoundId,
        updates: Vec<(u32, [f32; 6])>,
        pending: Option<Submix>,
    }
    impl SpliceHost for Log {
        fn set_submix(&mut self, submix: Option<Submix>) {
            self.pending = submix;
        }
        fn start(&mut self, bank: &str, id: u32, _: [f32; 6]) -> Option<SoundId> {
            self.started.push((bank.to_owned(), id));
            self.submixes.push(self.pending.take());
            self.next += 1;
            self.live.insert(self.next, (bank.to_owned(), id));
            Some(self.next)
        }
        fn update(&mut self, sound: SoundId, block: [f32; 6]) {
            self.updates.push((self.live[&sound].1, block));
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
            16384
        }
        fn pitch(&self, _: usize) -> i32 {
            4096
        }
    }

    /// Materials 2 (concrete-like: footstep surface 1, no own record), 9 (surface 7) and 46 (its
    /// own Skate_Collisions record 904 / 905 / 907, gain 8000 / 22000).
    fn tuning() -> (PlayerTuning, FootstepTuning) {
        let mut t = PlayerTuning::default();
        t.surface_table = vec![[0; 18]; 95];
        t.surface_table[2][6] = 1;
        t.surface_table[9][6] = 7;
        t.surface_table[46][6] = 1;
        t.surface_table[30][6] = 4;
        let mut ft = FootstepTuning::default();
        ft.materials = vec![FootstepMaterial { kind: 0, ..Default::default() }; 143];
        ft.materials[46] = FootstepMaterial { kind: 0, enabled: true, gain: 8000, landing_gain: 22000, ids: [904, 905, 907] };
        (t, ft)
    }

    fn walking(foot: [bool; 2], m: u32) -> AudioState {
        AudioState { on_foot: true, com_velocity: [1.5, 0.0, 0.0], foot_down: foot, foot_material: [m; 2], ..Default::default() }
    }

    /// `sub_824EBB58`: one entry sound per water stay (1187 on the water contact's first frame,
    /// 1197 later; none with `+224`), the board's 1198 once per rise, updates at levels 13 / 16.
    #[test]
    fn the_splash_plays_once_per_water_stay_by_its_time_in_water() {
        let ft = FootstepTuning::default();
        let mut sp = Splash::default();
        let mut h = Log::default();
        let st = |in_water: bool, under: bool, board: bool| AudioState { in_water, under_water: under, board_in_water: board, ..Default::default() };
        // Dry, then in water at once under the surface: 1187.
        sp.process(&st(false, false, false), &ft, &mut h);
        sp.process(&st(true, true, false), &ft, &mut h);
        assert_eq!(h.started, [("Skate_Collisions".to_owned(), 1187)]);
        // Staying under: no second sound; the update drives the gain at level(13).
        sp.process(&st(true, true, false), &ft, &mut h);
        sp.update(&st(true, true, false), &Out, &mut h);
        assert_eq!(h.started.len(), 1);
        assert_eq!(h.updates.last().unwrap().0, 1187);
        assert!((h.updates.last().unwrap().1[0] - 10013.0 / 32767.0).abs() < 1e-6);
        // Out, back in water on the surface for a frame, then under: 1197 (time in water > 0.001).
        sp.process(&st(false, false, false), &ft, &mut h);
        sp.process(&st(true, false, false), &ft, &mut h);
        sp.process(&st(true, true, false), &ft, &mut h);
        assert_eq!(h.started.last().unwrap().1, 1197);
        // The board: once per rise.
        sp.process(&st(true, true, true), &ft, &mut h);
        sp.process(&st(true, true, true), &ft, &mut h);
        assert_eq!(h.started.iter().filter(|s| s.1 == 1198).count(), 1);
        sp.update(&st(true, true, true), &Out, &mut h);
        assert!(h.updates.iter().any(|u| u.0 == 1198 && (u.1[0] - 10016.0 / 32767.0).abs() < 1e-6));
        // +224: the stay's latch is taken without a sound.
        let n = h.started.len();
        sp.process(&st(false, false, false), &ft, &mut h);
        sp.process(&AudioState { global_224: true, ..st(true, true, false) }, &ft, &mut h);
        sp.process(&st(true, true, false), &ft, &mut h);
        assert_eq!(h.started.len(), n);
    }

    #[test]
    fn the_curves_interpolate_like_retail() {
        let ft = FootstepTuning::default();
        assert_eq!(ft.walk_curve.word(-1.0), 0);
        assert_eq!(ft.walk_curve.word(2.0), 205);
        // Between 2.0 (205) and 2.5 (250): 205 + 90 × 0.25 = 227.5 → 227.
        assert_eq!(ft.walk_curve.word(2.25), 227);
        assert_eq!(ft.walk_curve.word(50.0), 516);
        assert_eq!(ft.vertical_curve.word(0.25), 2);
        assert_eq!(ft.vertical_curve.word(3.0), 0);
        // Running begins where the walk word passes 400 (≈ 5.88 m/s).
        assert!(ft.walk_curve.word(5.8) < 400 && ft.walk_curve.word(6.0) >= 400);
    }

    #[test]
    fn the_packets_post_once_with_the_constructor_words_and_update_from_the_outputs() {
        let (t, ft) = tuning();
        let mut f = Footsteps::default();
        let mut h = Log::default();
        let cmds = f.process(&walking([false; 2], 2), &t, &ft, &mut h);
        assert_eq!(cmds.len(), 2);
        let Command::Post { slot, class, words } = &cmds[0] else { panic!() };
        assert_eq!((*slot, *class), (Slot::Footstep(1), CLASS));
        assert_eq!(words, &vec![0, 0, 4096, 0, 25000, 0, 0, 32767, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 12]);
        assert!(matches!(cmds[1], Command::Post { slot: Slot::Footstep(0), .. }));
        assert!(f.process(&walking([false; 2], 2), &t, &ft, &mut h).is_empty(), "held");
        let s = AudioState { footstep_strength: 2.7, step_code: 4, landing_bucket: 2, foot_vertical_speed: [0.25, 3.0], foot_xz_speed: [2.0, 0.0], ..walking([true, false], 2) };
        f.process(&s, &t, &ft, &mut h);
        let up = f.update(&s, &t, &ft, &Out, &mut h);
        let Command::Redeliver { slot: Slot::Footstep(0), words } = &up[0] else { panic!() };
        // w1 raw(0), w2 pitch(1), w4/w5 filters 4/5, w6 level(6), w7 level(2), w8 foot down,
        // w9 vertical(0.25) = 2, w10 xz(2.0), w12 bucket, w13 trunc(2.7) = 2, w14 walk(1.5),
        // w15 1, w16 surface 1, w17 code 4, w18.. the vault tail, w24 kept.
        let xz = ft.xz_curve.word(2.0);
        let walk = ft.walk_curve.word(1.5);
        assert_eq!(
            words,
            &vec![32767, 16384, 4096, 0, 10004, 10005, 10006, 10002, 1, 2, xz, 0, 2, 2, walk, 1, 1, 4, 32767, 10000, 15000, 25000, 32767, 28000, 12]
        );
        let Command::Redeliver { slot: Slot::Footstep(1), words } = &up[1] else { panic!() };
        assert_eq!((words[8], words[9], words[10]), (0, 0, 0));
    }

    #[test]
    fn a_step_on_concrete_plays_the_walk_set_and_the_walking_foley() {
        let (t, ft) = tuning();
        let mut f = Footsteps::default();
        let mut h = Log::default();
        f.process(&walking([false; 2], 2), &t, &ft, &mut h);
        f.process(&walking([true, false], 2), &t, &ft, &mut h);
        // Surface 1 has no surface layer (the material's record has none); step layer 0, walk
        // mode, step code 1 → sk8_foley 86; the walking foley at 1.5 m/s → 62.
        assert_eq!(h.started, [("sk8_foley".to_owned(), 86), ("sk8_foley".to_owned(), 62)]);
        let sub = h.submixes[0].unwrap();
        assert_eq!(sub.eq, SubmixEq::SLOT, "step slots keep the constructor's open EQ");
        assert!(h.submixes[1].is_none(), "the walking foley goes straight to SFX Master");
        // Held foot: no new step; the other foot comes down → its own set.
        h.started.clear();
        f.process(&walking([true, false], 2), &t, &ft, &mut h);
        assert!(h.started.is_empty());
        f.process(&walking([true, true], 2), &t, &ft, &mut h);
        assert_eq!(h.started.len(), 2);
    }

    #[test]
    fn a_material_with_its_own_record_adds_the_surface_layer_at_its_gain() {
        let (t, ft) = tuning();
        let mut f = Footsteps::default();
        let mut h = Log::default();
        f.process(&walking([false; 2], 46), &t, &ft, &mut h);
        f.process(&walking([true, false], 46), &t, &ft, &mut h);
        assert_eq!(h.started[0], ("Skate_Collisions".to_owned(), 904));
        let sub = h.submixes[0].unwrap();
        assert_eq!(sub.eq.gain, 8000.0 * LEVEL);
        assert_eq!(sub.eq.low_pass, 96_000.0, "no own EQ record: the default one");
        // The update scales by level(11) (the material's record applies) × the slot gain.
        f.update(&walking([true, false], 46), &t, &ft, &Out, &mut h);
        let b = h.updates.iter().find(|u| u.0 == 904).unwrap().1;
        assert_eq!(b[0], 8000.0 * LEVEL * (10011.0 * LEVEL));
        assert_eq!((b[2], b[4]), (0.0, 1.0), "centred: the submix pans");
    }

    #[test]
    fn surface_seven_plays_both_layers_with_their_records() {
        let (t, ft) = tuning();
        let mut f = Footsteps::default();
        let mut h = Log::default();
        f.process(&walking([false; 2], 9), &t, &ft, &mut h);
        f.process(&walking([false, true], 9), &t, &ft, &mut h);
        let ids: Vec<u32> = h.started.iter().map(|s| s.1).collect();
        // 959 (layer 0, walk), 961 (layer 1), then step layer 0 on surface 7 (walk, code 1) = 75,
        // then the walking foley 62.
        assert_eq!(ids, [959, 961, 75, 62]);
        assert_eq!(h.submixes[0].unwrap().eq.high_pass, 200.0);
        assert_eq!(h.submixes[1].unwrap().eq.gain, f32::from_bits(0x3CA3_D70A));
    }

    #[test]
    fn surface_four_adds_the_hard_step_and_running_switches_sets() {
        let (t, ft) = tuning();
        let mut f = Footsteps::default();
        let mut h = Log::default();
        let run = |down| AudioState { com_velocity: [8.0, 0.0, 0.0], ..walking(down, 30) };
        f.process(&run([false; 2]), &t, &ft, &mut h);
        f.process(&run([true, false]), &t, &ft, &mut h);
        // Surface 4, run mode, code 1: sk8_foley 105 and Skate_Collisions 964; walking foley at
        // 8 m/s → 64 (no hard layer without +308).
        let got: Vec<(&str, u32)> = h.started.iter().map(|(b, i)| (b.as_str(), *i)).collect();
        assert_eq!(got, [("sk8_foley", 105), ("Skate_Collisions", 964), ("sk8_foley", 64)]);
    }

    #[test]
    fn jumping_off_the_feet_plays_the_take_off_then_the_apex() {
        let (t, ft) = tuning();
        let mut f = Footsteps::default();
        let mut h = Log::default();
        let mut s = walking([true, true], 2);
        s.com_velocity = [1.0, 3.0, 0.0];
        f.process(&s, &t, &ft, &mut h);
        h.started.clear();
        s.offboard_air = true;
        s.foot_down = [false; 2];
        f.process(&s, &t, &ft, &mut h);
        assert_eq!(h.started, [("sk8_foley".to_owned(), 65)]);
        s.com_velocity[1] = 1.0;
        f.process(&s, &t, &ft, &mut h);
        s.com_velocity[1] = -0.5;
        f.process(&s, &t, &ft, &mut h);
        assert_eq!(h.started.last().unwrap(), &("sk8_foley".to_owned(), 66));
        assert!(f.jump.is_none() && f.apex.is_some());
    }

    #[test]
    fn the_footplant_end_counts_down_the_foot_flag() {
        let (t, ft) = tuning();
        let mut f = Footsteps::default();
        let mut h = Log::default();
        let mut s = AudioState { footplant: true, foot_down: [true, false], ..Default::default() };
        f.process(&s, &t, &ft, &mut h);
        s.footplant = false;
        f.process(&s, &t, &ft, &mut h);
        assert_eq!(f.countdown, [9, 0], "set to 10 and counted down the same frame");
        // ... and the end of the footplant plays a take-off (bucket 0 → 67).
        assert!(h.started.contains(&("sk8_foley".to_owned(), 67)));
    }

    #[test]
    fn step_code_compares_the_plant_heights() {
        let mut c = StepCode::default();
        assert_eq!(c.update([true, false], [0, 0], [0.0, 0.0]), 1);
        // Foot 307 plants 10 cm higher: up (212) → 4 on a plain surface.
        assert_eq!(c.update([true, true], [0, 0], [0.0, 0.1]), 4);
        // Level again: back to 1.
        c.update([false, true], [0, 0], [0.0, 0.1]);
        assert_eq!(c.update([true, true], [0, 0], [0.1, 0.1]), 1);
        // Physics class 8 under foot B (tag bits 7..11 = 8): codes 2 / 3.
        let tag = 8 << 7;
        let mut c = StepCode::default();
        c.update([true, false], [tag, 0], [0.0, 0.0]);
        assert_eq!(c.update([true, true], [tag, 0], [0.0, -0.2]), 3);
    }

    #[test]
    fn the_landing_bucket_follows_the_fall_speed_after_offboard_air() {
        let mut b = LandingBucket::default();
        assert_eq!(b.update(-3.0, false, false, -1), 1, "no OffboardAir: forced 1");
        b.update(-1.0, true, false, -1);
        assert_eq!(b.update(-3.0, false, false, -1), 4 - 1 + 0, "|-3.0| > 2.6 → 3");
        assert_eq!(b.update(-4.0, false, false, -1), 4);
        assert_eq!(b.update(-4.0, false, true, 28), 1, "a trick forces 1");
    }
}
