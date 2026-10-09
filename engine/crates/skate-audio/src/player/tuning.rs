//! Vault tuning the player components read (exported by setup into the manifest's
//! `player_tuning`; `tools/asset_pipeline/audio_export.py` `player_tuning`). Every table is
//! optional: a missing one leaves its input or word at the retail default named in the docs.

/// One `Sk8::Audio::eJitterParams` channel of `SFXObj_Jitter` (class `0x0AB9F005A2C8FBC7`, one
/// leaf collection each, fields resolved through `default`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct JitterParams {
    /// Field `0x8F956FBAD301AE26`: the channel writes its value to the Jitter controller.
    pub enabled: bool,
    /// Field `0xE7D491E2EB228F54`: the controller input id.
    pub id: usize,
    /// Field `0xB66AAD957873A8B3`: centre, range, largest and smallest velocity step.
    pub centre: f32,
    pub range: f32,
    pub max_step: f32,
    pub min_step: f32,
}

/// A seam pattern's gain wobble (class `0x7242F32831ED3332`, collections `hash64(name)` of
/// spidercrack … special_2 = patterns 1..15, index 0 = `default`): gain low / high (fields
/// `0xFA3A57801765A2F8` / `0x32A9692F1B826274`) and duration low / high in ms
/// (`0xF713CB547B1DF920` / `0x0608B3129FF81F12`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SeamWobble {
    pub gain_low: f32,
    pub gain_high: f32,
    pub ms_low: i32,
    pub ms_high: i32,
}

impl Default for SeamWobble {
    fn default() -> Self {
        Self { gain_low: 1.0, gain_high: 1.0, ms_low: 0, ms_high: 0 }
    }
}

/// One grind surface's levels (class `0x049861E8F9A8D16B`, collection from the image's key table
/// at `0x82249F90` by grind surface 0..13): per layer 0..3 the post level V (fields
/// `0x0ECECDAC28B2B979`, `0x58070BF511809903`, `0x72BA0780A8FA25D6`, `0x721A50C80028AD69`) and
/// the update factor F on Rail level(1) (`0x69969AF1BE6BB367`, `0x0555484D6D4A3128`,
/// `0xC21983A2160ED3AC`, `0x69A5FC53091ED1F8`). Missing fields read 1.0 (the image's default).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GrindSurface {
    pub v: [f32; 4],
    pub f: [f32; 4],
    /// The grind contact sounds (`player::components::Grind::sounds`): the surface's metal flag
    /// (bool `02BAC36BCC8A30DE`: Skate_Metal, else Skate_Collisions) and the on (`sub_824C35D0`,
    /// `sub_824C2FA0`, `sub_824C3380`) and off (`sub_824C37D8`, `sub_824C3190`, `sub_824C34A8`)
    /// sounds' fields.
    pub metal: bool,
    pub on: GrindContact,
    pub off: GrindContact,
}

impl Default for GrindSurface {
    fn default() -> Self {
        Self { v: [1.0; 4], f: [1.0; 4], metal: false, on: GrindContact::default(), off: GrindContact::default() }
    }
}

/// One grind contact sound of a grind surface: the sound id per layer 0..3 (−1 = none: an install
/// exported before 2026-10-03), the per-layer level factor, the level and pitch endpoints (A at
/// the speed cap, B at rest) of `components::grind_lerp`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GrindContact {
    pub ids: [i32; 4],
    pub gain: [f32; 4],
    pub level: [f32; 2],
    pub pitch: [f32; 2],
}

impl Default for GrindContact {
    fn default() -> Self {
        Self { ids: [-1; 4], gain: [1.0; 4], level: [0.1, 1.0], pitch: [0.8, 1.0] }
    }
}

/// A seam pattern record for `Class_Seams` (class `0x7242F32831ED3332`, collections as
/// [`SeamWobble`]): +0 gain (w16), +4 grid angle (degrees), +8 grid z, +12 grid x, +16 class (w13),
/// and the attributes mode (`CA81764BF5A85E34`: 0 none, 1 grid, 2 distance), minimum frames
/// between hits (`DAE803A0CBD286D1`), speed threshold (`F7BCA67F0A1FC92E`, m/s of `+208`),
/// distance spacing (`A3BC1976039FA00A`) and level (`2F29F40384863C8C`, w18).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SeamPattern {
    pub gain: f32,
    pub angle: i32,
    pub grid_z: f32,
    pub grid_x: f32,
    pub class: i32,
    pub mode: i32,
    pub min_frames: i32,
    pub speed_threshold: f32,
    pub spacing: f32,
    pub level: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PlayerTuning {
    /// `Sk8::AudioSurfaceMap` (holder `0xC1831BDB6CB1B1EA` / `0xC489459A0C07D154`, field
    /// `0x4CA607558B1CF440`): 95 entries of 18 words, by material (≥ 94 → entry 94). Word 1 (+4)
    /// rolling surface, 3 (+12) skid, 4 (+16) grind surface, 5 (+20) foot drag, 8 (+32) seams, 9 (+36)
    /// seams transition, 10 (+40) body slide.
    pub surface_table: Vec<[i32; 18]>,
    pub jitter: Vec<JitterParams>,
    pub seam_wobbles: Vec<SeamWobble>,
    /// Grind surfaces 0..13.
    pub grind: Vec<GrindSurface>,
    /// Materials whose AudioSurface collection (class `0xD40CB4C0FFE45676`) sets the landing flag
    /// `0x1EBF9D2EB0DD56BA` (Contacts input 6). Needs the TU3 image's material key table
    /// (`0x8302D6E8`); empty when the install was set up without it.
    pub landing_materials: Vec<u32>,
    /// Class `0xC26949FCB638A2CA` `default`: the per-wheel landing bucket thresholds on the stored
    /// air factor (fields `0x6D3D91A9BA7ADCDC` = 0.5 → bucket 2, `0x2A70BB8A382574E4` = 0.31 → 1).
    pub wheel_bucket_high: f32,
    pub wheel_bucket_low: f32,
    /// Conditioner82772D30: class A867FBE3454326FF/default, field468752B0BEE65CDB, indices0/1.
    pub jump_thresholds: [f32; 2],
    /// eSk8AudioTricks (class `0x6918469984A8C596`, field `0x8C3025DB4D1761AF`): the audio trick id
    /// (state `+348`) by collection key = [`name_hash`] of the lowercase scorable name.
    pub audio_tricks: std::collections::HashMap<u64, i32>,
    /// The collision manager's material table (`audio_export.collision_tuning`); empty: the
    /// collision contacts stay silent.
    pub collision: super::collision::CollisionTuning,
    /// `Class_Seams` patterns: index 0 = `default`, 1..15 = spidercrack … special_2.
    pub seam_patterns: Vec<SeamPattern>,
    /// The pattern holder's `default` field `1911176187FB9B1F`: the grid scale on rolling surface 3
    /// for class-10 patterns (`sub_824C1CA0`), 1.0 without it.
    pub seam_surface3_scale: f32,
    /// The jitter channels (indices into [`PlayerTuning::jitter`]) that the jittered eEQChain
    /// buses 5–7 read (`sub_82491180`): PI20#1 freq `E17029CE4388E1E8`, gain `C27373E7FD2DCE47`,
    /// Q `EA2ED27D25247927`, PI20#2 freq `816A58ECCCD4112D`, gain `8802BC5475904597`, Q
    /// `D4ED2F0BA77ACAB5`.
    pub eq_jitter: [Option<usize>; 6],
    /// The board's rolling layers (`player::rolling`: Class_rolling speeds, rattle, board slide).
    pub rolling: super::rolling::RollingTuning,
    /// The scorable class's second audio trick field `0xA2C5C22C5BE725F8` (state `+352`), keyed
    /// like [`PlayerTuning::audio_tricks`].
    pub audio_tricks_2: std::collections::HashMap<u64, i32>,
    /// The Tricks component's vault words (`player::tricks`).
    pub tricks: super::tricks::TricksTuning,
    /// `Class_Treatment`'s vault words (`player::treatment`).
    pub treatment: super::treatment::TreatmentTuning,
    /// The grind contact sounds' eEQChain bus (class `42AFE160E647167C` `default` field
    /// `D1A87641CCB98787`, `sub_824C3FC8` / `sub_824C4138`): 0.
    pub grind_contact_eq: u8,
}

/// The jitter keys of [`PlayerTuning::eq_jitter`], in order.
pub const EQ_JITTER_KEYS: [u64; 6] =
    [0xE170_29CE_4388_E1E8, 0xC273_73E7_FD2D_CE47, 0xEA2E_D27D_2524_7927, 0x816A_58EC_CCD4_112D, 0x8802_BC54_7590_4597, 0xD4ED_2F0B_A77A_CAB5];

impl Default for PlayerTuning {
    fn default() -> Self {
        Self {
            surface_table: Vec::new(),
            jitter: Vec::new(),
            seam_wobbles: Vec::new(),
            grind: Vec::new(),
            landing_materials: Vec::new(),
            wheel_bucket_high: 0.5,
            wheel_bucket_low: f32::from_bits(0x3E9E_B852),
            jump_thresholds: [f32::from_bits(0x3EE6_6666), f32::from_bits(0x3F40_0000)],
            audio_tricks: Default::default(),
            collision: Default::default(),
            seam_patterns: Vec::new(),
            seam_surface3_scale: 1.0,
            eq_jitter: [None; 6],
            rolling: Default::default(),
            audio_tricks_2: Default::default(),
            tricks: Default::default(),
            treatment: Default::default(),
            grind_contact_eq: 0,
        }
    }
}

/// The vault's name hash (Bob Jenkins' lookup8, public domain; level 0xABCDEF0011223344).
pub fn name_hash(bytes: &[u8]) -> u64 {
    fn mix(a: &mut u64, b: &mut u64, c: &mut u64) {
        *a = a.wrapping_sub(*b).wrapping_sub(*c) ^ (*c >> 43);
        *b = b.wrapping_sub(*c).wrapping_sub(*a) ^ (*a << 9);
        *c = c.wrapping_sub(*a).wrapping_sub(*b) ^ (*b >> 8);
        *a = a.wrapping_sub(*b).wrapping_sub(*c) ^ (*c >> 38);
        *b = b.wrapping_sub(*c).wrapping_sub(*a) ^ (*a << 23);
        *c = c.wrapping_sub(*a).wrapping_sub(*b) ^ (*b >> 5);
        *a = a.wrapping_sub(*b).wrapping_sub(*c) ^ (*c >> 35);
        *b = b.wrapping_sub(*c).wrapping_sub(*a) ^ (*a << 49);
        *c = c.wrapping_sub(*a).wrapping_sub(*b) ^ (*b >> 11);
        *a = a.wrapping_sub(*b).wrapping_sub(*c) ^ (*c >> 12);
        *b = b.wrapping_sub(*c).wrapping_sub(*a) ^ (*a << 18);
        *c = c.wrapping_sub(*a).wrapping_sub(*b) ^ (*b >> 22);
    }
    if bytes.is_empty() {
        return 0;
    }
    let (mut a, mut b, mut c) = (0xABCD_EF00_1122_3344u64, 0xABCD_EF00_1122_3344u64, 0x9E37_79B9_7F4A_7C13u64);
    let mut blocks = bytes.chunks_exact(24);
    for k in &mut blocks {
        a = a.wrapping_add(u64::from_le_bytes(k[..8].try_into().unwrap()));
        b = b.wrapping_add(u64::from_le_bytes(k[8..16].try_into().unwrap()));
        c = c.wrapping_add(u64::from_le_bytes(k[16..24].try_into().unwrap()));
        mix(&mut a, &mut b, &mut c);
    }
    c = c.wrapping_add(bytes.len() as u64);
    for (i, &byte) in blocks.remainder().iter().enumerate() {
        match i {
            0..=7 => a = a.wrapping_add(u64::from(byte) << (8 * i)),
            8..=15 => b = b.wrapping_add(u64::from(byte) << (8 * (i - 8))),
            _ => c = c.wrapping_add(u64::from(byte) << (8 * (i - 15))),
        }
    }
    mix(&mut a, &mut b, &mut c);
    c
}

impl PlayerTuning {
    /// Native82772D30 tests index1 first, then index0; both comparisons are strict.
    pub fn jump_bucket(&self, strength: f32) -> u32 {
        if strength > self.jump_thresholds[1] { 2 }
        else if strength > self.jump_thresholds[0] { 1 }
        else { 0 }
    }

    /// The audio trick id of a scorable name (−1 without a record).
    pub fn audio_trick(&self, name: &str) -> i32 {
        self.audio_tricks.get(&name_hash(name.to_ascii_lowercase().as_bytes())).copied().unwrap_or(-1)
    }

    /// The second audio trick id (state `+352`) of a scorable name (−1 without a record).
    pub fn audio_trick_2(&self, name: &str) -> i32 {
        self.audio_tricks_2.get(&name_hash(name.to_ascii_lowercase().as_bytes())).copied().unwrap_or(-1)
    }

    /// AudioSurfaceMap entry of a material (`sub_82494E18` and siblings: ≥ 94 → entry 94).
    pub fn surface_entry(&self, material: u32) -> Option<&[i32; 18]> {
        if self.surface_table.is_empty() {
            return None;
        }
        self.surface_table.get((material as usize).min(94)).or_else(|| self.surface_table.last())
    }

    /// The grind surface of a grind material (`+692`): 4 without one (143), else the entry's
    /// `+16`; 14 = "no grind sound" (the poster skips it). Without a table: 4.
    pub fn grind_surface(&self, material: u32) -> i32 {
        if material == super::state::NO_MATERIAL {
            return 4;
        }
        self.surface_entry(material).map_or(4, |e| e[4])
    }

    pub fn grind_levels(&self, surface: i32) -> GrindSurface {
        let s = if (0..14).contains(&surface) { surface as usize } else { 4 };
        self.grind.get(s).copied().unwrap_or_default()
    }

    /// Seam wobble of a pattern (1..15; anything else reads the image's zero block).
    pub fn seam_wobble(&self, pattern: u32) -> SeamWobble {
        if (1..=15).contains(&pattern) {
            self.seam_wobbles.get(pattern as usize).or_else(|| self.seam_wobbles.first()).copied().unwrap_or_default()
        } else {
            SeamWobble { gain_low: 0.0, gain_high: 0.0, ms_low: 0, ms_high: 0 }
        }
    }
}
