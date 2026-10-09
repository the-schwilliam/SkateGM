//! The per-frame player audio state: what retail's audio-state bridge (`sub_824B0DA8`, record
//! `*(0x82083C38) + 0x2F070 + 240 + 544·player`) gathers from the physics output for the audio
//! components. Field docs name the state offsets the components read. The game fills it.

/// Material value of a wheel with no contact (`+620..+632`).
pub const NO_MATERIAL: u32 = 143;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AudioState {
    /// Frame time (s).
    pub dt: f32,
    /// `+208` board ground speed (m/s, SkateboardMotion+164; signed).
    pub ground_speed: f32,
    /// `+96` centre-of-mass velocity (SystemReckoning+16); `+212` is its length.
    pub com_velocity: [f32; 3],
    /// Record `+0` = SystemReckoning+64: the followed point (the skater).
    pub com_position: [f32; 3],
    /// The board (deck) position and linear velocity: what the second position controller
    /// (`60010020`) follows (record `+48` / `+80`, Motion+80).
    pub board_position: [f32; 3],
    pub board_velocity: [f32; 3],
    /// `+200` wheels in contact (0..4).
    pub wheel_count: u32,
    /// Per wheel (FL, FR, BL, BR as the engine orders them): in contact, material (`+620`:
    /// audio surface tag − 1, [`NO_MATERIAL`] without contact) and seam pattern (`+636`).
    pub wheel_contact: [bool; 4],
    pub wheel_material: [u32; 4],
    pub seam_pattern: [u32; 4],
    /// `+384 + 16·w` the wheels' world positions (the engine's wheel bodies), read by `Class_Seams`
    /// for its grid crossings.
    pub wheel_position: [[f32; 3]; 4],
    /// `+204` turn input (Ground+264 = ProcessedPhysIn+2676), −1..1.
    pub turn: f32,
    /// `+712` (Skeleton+516: the pumping absorption), read by the bed's slope inputs. Negative =
    /// downhill. What retail means by it is UNCERTAIN (grain spec §2.7).
    pub slope: f32,
    /// `+332` in the air (KnownAir in retail: 200 ≤ state < 300 with no wheel down) and `+236` the
    /// time in that air phase (s).
    pub airborne: bool,
    pub air_time: f32,
    /// `+336` brake planted, `+339` manual brake, `+340` balance (manual), `+341` grinding,
    /// `+343` trick active, `+372` the hippy-jump trick flag, `+676` bail, `+677` end of bail,
    /// `+716` on foot (state 500), `+684` soft wheels (wheel hardness < 0.5).
    pub brake: bool,
    pub manual_brake: bool,
    pub balance: bool,
    pub grinding: bool,
    pub trick_active: bool,
    pub hippy_jump: bool,
    pub bail: bool,
    pub bail_end: bool,
    pub on_foot: bool,
    pub soft_wheels: bool,
    /// `+333 || +334` the push foot is planted; `+335` a new push plant this frame.
    pub push_planted: bool,
    pub push_trigger: bool,
    /// `+615` / `+616` feet inside the deck box (Skeleton 600 / 601).
    pub feet_in_deck_box: [bool; 2],
    /// `+192` grind family (Grinds+136 latched while grinding; −1 before the first grind) and
    /// `+692` grind material (Grinds+216 latched, as a material: tag − 1 like the wheels, 0 → 143, by the
    /// packer `sub_827A1B78` record `+512`; [`NO_MATERIAL`] before the first grind).
    pub grind_family: i32,
    pub grind_material: u32,
    /// `[[state+16]+72]`: this is the local player.
    pub local: bool,
    /// `+468` jump velocity: the conditioner's |Air+112| / 2.65 (1 above 2.65 m/s), written while
    /// Air440 (Processed2468 bit 22) holds (`sub_82772748`).
    pub jump_velocity: f32,
    /// `+348` the audio trick id of the current scorable (vault `eSk8AudioTricks`, −1 none); the
    /// host resolves it from [`AudioState::scorable`] with `PlayerTuning::audio_trick`.
    pub audio_trick: i32,
    /// The score packet's EScorableID (B60+152, −1 none).
    pub scorable: i32,
    /// `+232` slip: clamp((|deck velocity · deck right| + 0.75) / 45, 0, 1), 0 with no wheel down
    /// (`sub_82772E18`; vault holder `0xBA9837A6CF4C26ED`: 45 and −0.75). See [`slip`].
    pub slip: f32,
    /// `+690` reverting (RevertGround with State+66), `+308` the off-board byte the skid and the
    /// walking voices read: OffBoard 311, the board held in hand (packed record `+164` bit 1,
    /// `sub_827A1B78`; the engine's `off_board.flag_311`).
    pub revert: bool,
    pub offboard_308: bool,
    /// `+264` the signed deck tilt (rad, SkateboardBody+256 filtered steering) and `+488` the deck's
    /// angular velocity about its At axis (rad/s; `+480` = Motion+64 projected on the deck rows).
    pub deck_tilt: f32,
    pub deck_spin: f32,
    /// `+228` the last positive grind impact speed (m/s; B40+32 = Grinds+128 latched while > 0),
    /// read by the grind-start contact.
    pub grind_impact: f32,
    /// `+668` the deck impact: the conditioner's max over the last 4 frames of
    /// clamp01(|deck acceleration · deck contact normal| × 0.00125) with the deck in contact
    /// (`sub_82C02A80` Collision+24, B40+36); `+660` the deck contact's material (tag − 1, 143 none).
    pub deck_impact: f32,
    pub deck_material: u32,
    /// `+272` / `+268`: |local toe velocity Y| of foot 0 (Skeleton+196) / foot 1 (+212);
    /// `+280` / `+276`: max(|x|, |z|) of the same velocities (m/s, the physical board's frame).
    pub foot_speed_y: [f32; 2],
    pub foot_speed_xz: [f32; 2],
    /// Processed2624 -> Ground300 (82DB6EC0), consumed by conditioner82772D30.
    pub jump_strength: f32,
    /// `+304` the jump bucket (0..2, B40+48), resolved from jump_strength and vault thresholds.
    pub jump_bucket: u32,
    /// `+352` the scorable's second eSk8AudioTricks field (record `+184` = vault class
    /// `0x6918469984A8C596` field `0xA2C5C22C5BE725F8` at +172; −1 none): 28 for flips and most
    /// tricks, 35 for grabs, −1 for the ollie, the nollie and footplants. The host resolves it from
    /// [`AudioState::scorable`] with `PlayerTuning::audio_trick_2`. The Tricks component plays it
    /// as the second cloth_trick when the trick ends.
    pub audio_trick_2: i32,
    /// `+310` the off-board hold has run out (record +164 bit 0 held longer than a speed-dependent
    /// time, `sub_824B0DA8`). The per-skater bridge clock publishes it. On the ground the Tricks
    /// component posts Class_Flips with trick id 34.
    pub offboard_310: bool,
    /// `+480` / `+484`: the deck's angular velocity about its Ri and Up rows (rad/s; `+488` is
    /// [`AudioState::deck_spin`]), the conditioner's B40+0 = rows · Motion+64 (`sub_82772748`).
    pub deck_spin_xy: [f32; 2],
    /// `+240` the predicted time until landing (s, Air+184) and `+260` the jump height (m,
    /// Air+200): KnownAir's outputs (skate-core `KnownAirOutput::time_until_collision_184` /
    /// `jump_height_200`), streamed by `Class_Treatment`.
    pub air_until_landing: f32,
    pub jump_height: f32,
    /// `+220` the game time scale (G+0 of the audio game block, 1.0 at normal speed, below 1.0 in
    /// slow motion) and `+224` the block's G+4 byte (also the c_tazer post's input; 0 in free skate).
    pub time_scale: f32,
    pub global_224: bool,
    // ---- off-board and clothing inputs (`player::footsteps`, `player::clothing`,
    // `player::step_on`; spec `audio-specs/aems-offboard-clothing-spec.md`). Foot A is the
    // packet at OffBoard `+36` (OffBoard foot side 1, toe part 19), foot B the one at `+220`
    // (side 0, toe part 15).
    /// `+724` / `+725`: foot A / B down: (OffBoard 307 || Air 450 || `+334` || `+336`) /
    /// (OffBoard 306 || Air 449 || `+333`) — on the board the push plants and the brake count.
    pub foot_down: [bool; 2],
    /// `+732` / `+728`: the surface material under foot A / B (OffBoard `+56` / `+52` u16 tag & 0x7F,
    /// − 1, [`NO_MATERIAL`] without one; the footplant's Air `+224` tag while Air 448).
    pub foot_material: [u32; 2],
    /// `+288` / `+284`: max(|vx|, |vz|) of the world velocity of toe part 19 / 15 (Skeleton
    /// `+240` / `+224`, m/s).
    pub foot_xz_speed: [f32; 2],
    /// `+296` / `+292`: |Skeleton `+308`| / |Skeleton `+324`| (the y lanes of Skeleton `+304` /
    /// `+320`, per-foot vertical speeds, m/s).
    pub foot_vertical_speed: [f32; 2],
    /// `+740` the step code 1..5 ([`super::footsteps::StepCode`]).
    pub step_code: i32,
    /// `+796` Interaction+0 `AudibleFootStepStrength`.
    pub footstep_strength: f32,
    /// `+300` the landing bucket 1..4 ([`super::footsteps::LandingBucket`]).
    pub landing_bucket: i32,
    /// `+768` Air 448 (the footplant) and `+718` OffboardAir (filtered state 7).
    pub footplant: bool,
    pub offboard_air: bool,
    /// `+337` State56: the push stroke (the push animation's flag ahead of the plant `+333`).
    pub push_stroke: bool,
    /// `+328` |Skeleton `+288`| (the ragdoll body speed, m/s) and `+672` 0.25 × Σ Skeleton
    /// `+560..+572` (the limb speeds).
    pub body_speed: f32,
    pub limb_speed: f32,
    /// `+528..+548` the six body-part slide speeds, `+560..+580` their surface tags (1-based, 0 =
    /// none) and `+593` the flag that makes every slide type 4 (Collision `+80..+195` via
    /// `sub_82773298`).
    pub body_slide: [f32; 6],
    pub body_tag: [u32; 6],
    pub body_slide_flag: bool,
    /// `+496..+516` the six body regions' impacts (Collision `+80..`: `sub_82BD60C8` writes
    /// clamp01(max(0.001, Δv(part) · region normal × part mass × physics_collision `+164` (10)))
    /// per region with a contact part, else 0, and the conditioner `sub_82773298` keeps the max of
    /// the last 4 frames), read by the body poster `sub_824BC188` ([`super::contacts`]). These are
    /// the values before the bridge's speed graph: the poster applies it at [`Self::com_speed_216`]
    /// (retail stores the product back into `+496`).
    pub body_impact: [f32; 6],
    /// `+216`: the previous bridge frame's `+212` (|COM v|, m/s; the bridge `sub_824B0DA8` copies
    /// `+212` there after scaling the region impacts by the speed graph at it). The game sets it
    /// per physics step; 0 (graph value 1.0) when nobody does.
    pub com_speed_216: f32,
    /// `+688` / `+689`: hand limb 2 (part 3) / 3 (part 7) on the deck: Skeleton `+602` / `+603`
    /// ([`super::step_on::hands_on_deck`]).
    pub hands_on_deck: [bool; 2],
    // ---- water (`player::footsteps::Splash`, OffBoard's `sub_824EBB58`; the bridge `sub_824B0DA8`
    // copies the packed record's `+172` bits 30 / 29 / 28, written by the conditioner `sub_827A1B78`).
    /// `+811` in water: the current state's `+81` (Wipeout300's special surface, i.e. its water
    /// contact; the engine's `state_flags[81 − 52]`).
    pub in_water: bool,
    /// `+812` under the surface: `+811` and the state's surface height (`+32`) above the Y of any
    /// of the PhysOut Skeleton points `+128` / `+112` / `+32` (part 15's and part 19's pose applied
    /// to a per-part local point, and part 1's pose translation).
    pub under_water: bool,
    /// `+813` the board in water: Collision `+16` (the board's surface vote, `choose_surface`) = 12.
    pub board_in_water: bool,
}

impl Default for AudioState {
    fn default() -> Self {
        Self {
            dt: 1.0 / 60.0,
            ground_speed: 0.0,
            com_velocity: [0.0; 3],
            com_position: [0.0; 3],
            board_position: [0.0; 3],
            board_velocity: [0.0; 3],
            wheel_count: 0,
            wheel_contact: [false; 4],
            wheel_material: [NO_MATERIAL; 4],
            seam_pattern: [0; 4],
            wheel_position: [[0.0; 3]; 4],
            turn: 0.0,
            slope: 0.0,
            airborne: false,
            air_time: 0.0,
            brake: false,
            manual_brake: false,
            balance: false,
            grinding: false,
            trick_active: false,
            hippy_jump: false,
            bail: false,
            bail_end: false,
            on_foot: false,
            soft_wheels: false,
            push_planted: false,
            push_trigger: false,
            feet_in_deck_box: [false; 2],
            grind_family: -1,
            grind_material: NO_MATERIAL,
            local: true,
            jump_velocity: 0.0,
            audio_trick: -1,
            scorable: -1,
            slip: 0.0,
            revert: false,
            offboard_308: false,
            deck_tilt: 0.0,
            deck_spin: 0.0,
            grind_impact: 0.0,
            deck_impact: 0.0,
            deck_material: NO_MATERIAL,
            foot_speed_y: [0.0; 2],
            foot_speed_xz: [0.0; 2],
            jump_strength: 0.0,
            jump_bucket: 0,
            audio_trick_2: -1,
            offboard_310: false,
            deck_spin_xy: [0.0; 2],
            air_until_landing: 0.0,
            jump_height: 0.0,
            time_scale: 1.0,
            global_224: false,
            foot_down: [false; 2],
            foot_material: [NO_MATERIAL; 2],
            foot_xz_speed: [0.0; 2],
            foot_vertical_speed: [0.0; 2],
            step_code: 1,
            footstep_strength: 0.0,
            landing_bucket: 1,
            footplant: false,
            offboard_air: false,
            push_stroke: false,
            body_speed: 0.0,
            limb_speed: 0.0,
            body_slide: [0.0; 6],
            body_tag: [0; 6],
            body_slide_flag: false,
            body_impact: [0.0; 6],
            com_speed_216: 0.0,
            hands_on_deck: [false; 2],
            in_water: false,
            under_water: false,
            board_in_water: false,
        }
    }
}

/// What a skater that is NOT simulated with the player's physics (a route follower, a remote
/// player, a mod's script) can tell the audio: enough for [`AudioState::rolling`]. Not retail data:
/// retail always fills the whole record from the skater's physics.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LiteSkater {
    /// The board's position and velocity (m, m/s, world).
    pub position: [f32; 3],
    pub velocity: [f32; 3],
    /// The board's heading (rad about +Y; 0 = +Z, the game's convention).
    pub heading: f32,
    /// Wheels down (front-left, front-right, rear-left, rear-right).
    pub wheels: [bool; 4],
    /// The material under the board (the audio surface material, `material_of_tag(tag)`;
    /// `NO_MATERIAL` = none).
    pub material: u32,
    /// On a rail / ledge and its material (`+692`, `NO_MATERIAL` = none).
    pub grinding: bool,
    pub grind_material: u32,
    /// In the air and for how long (s).
    pub airborne: bool,
    pub air_time: f32,
    /// The step (s).
    pub dt: f32,
}

impl Default for LiteSkater {
    fn default() -> Self {
        Self {
            position: [0.0; 3],
            velocity: [0.0; 3],
            heading: 0.0,
            wheels: [true; 4],
            material: NO_MATERIAL,
            grinding: false,
            grind_material: NO_MATERIAL,
            airborne: false,
            air_time: 0.0,
            dt: 1.0 / 60.0,
        }
    }
}

impl AudioState {
    /// A documented minimal fill for a skater not simulated with the player's physics (spec
    /// `world-audio-hookin` §3.5): speed, wheels and their material, board / COM positions and
    /// velocities, grind and air flags. Rolling, the Class_rolling surfaces, seams, grinds and
    /// landings (the wheels coming down) sound; tricks, foot / body foley and the deck / region
    /// impacts stay silent (their inputs stay at the defaults). `local` is false. The wheel
    /// positions follow the board's heading (track 0.2 m, wheelbase 0.6 m).
    pub fn rolling(l: &LiteSkater) -> Self {
        let [vx, _, vz] = l.velocity;
        let speed = (vx * vx + vz * vz).sqrt();
        let contact = if l.airborne { [false; 4] } else { l.wheels };
        let wheels = contact.iter().filter(|c| **c).count() as u32;
        let (s, c) = l.heading.sin_cos();
        let [x, y, z] = l.position;
        let offs = [(0.1, 0.3), (-0.1, 0.3), (0.1, -0.3), (-0.1, -0.3)];
        Self {
            dt: l.dt,
            ground_speed: speed,
            com_velocity: l.velocity,
            com_position: [x, y + 1.0, z],
            board_position: l.position,
            board_velocity: l.velocity,
            wheel_count: wheels,
            wheel_contact: contact,
            wheel_material: [if l.airborne { NO_MATERIAL } else { l.material }; 4],
            wheel_position: offs.map(|(r, a)| [x + c * r + s * a, y, z - s * r + c * a]),
            airborne: l.airborne,
            air_time: if l.airborne { l.air_time } else { 0.0 },
            grinding: l.grinding,
            grind_family: if l.grinding { 0 } else { -1 },
            grind_material: if l.grinding { l.grind_material } else { NO_MATERIAL },
            local: false,
            ..Self::default()
        }
    }

    /// `+212`: |COM velocity|.
    pub fn com_speed(&self) -> f32 {
        let [x, y, z] = self.com_velocity;
        (x * x + y * y + z * z).sqrt()
    }

    /// The material of the first wheel in contact that has one (`NO_MATERIAL` if none).
    pub fn contact_material(&self) -> u32 {
        (0..4)
            .filter(|&i| self.wheel_contact[i])
            .map(|i| self.wheel_material[i])
            .find(|&m| m != NO_MATERIAL)
            .unwrap_or(NO_MATERIAL)
    }
}

/// `sub_82772E18`: the slip from the deck's lateral speed |Motion+80 · deck Ri| (m/s), for a board
/// with a wheel down (0 otherwise).
pub fn slip(lateral: f32) -> f32 {
    let x = lateral.abs() - f32::from_bits(0xBF40_0000); // − (−0.75)
    let x = if x >= 0.0 { x } else { 0.0 } / f32::from_bits(0x4234_0000); // / 45
    x.min(1.0)
}

/// `sub_82772748`'s jump-velocity word from |Air+112| (m/s): ×0.37735847 below 2.65, else 1.
pub fn jump_velocity(delta: f32) -> f32 {
    if delta < 0.0 {
        0.0
    } else if delta > f32::from_bits(0x4029_999A) {
        1.0
    } else {
        delta * f32::from_bits(0x3EC1_3521)
    }
}

/// The engine's 7-bit audio surface tag → the audio state's material (`tag − 1`, 0 = none).
pub fn material_of_tag(tag: u32) -> u32 {
    if tag == 0 { NO_MATERIAL } else { (tag - 1).min(NO_MATERIAL) }
}
