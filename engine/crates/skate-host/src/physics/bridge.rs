use super::{GamePhysics, PlayerControls, SkaterRuntime};
use crate::{camera::CameraRuntime, graph_runtime::StockGraphs, input::ControllerInput};
use bevy::prelude::*;
use skate_data::skate_map::{Collision, Geometry, Rail, SkateMap};
use std::path::Path;

#[derive(Clone, Copy, Default)]
pub struct Controls {
    pub buttons: u16,
    pub triggers: [u8; 2],
    pub left: [i16; 2],
    pub right: [i16; 2],
}
pub struct Session {
    physics: GamePhysics,
    skater: SkaterRuntime,
    controls: PlayerControls,
    graphs: StockGraphs,
    input: ControllerInput,
    camera: CameraRuntime,
    markers: crate::session_marker::Runtime,
    forced_wipeout: u32,
    loose_board_friction: f32,
}
pub struct Pose {
    pub root: Mat4,
    pub bones: Vec<Mat4>,
    pub names: Vec<String>,
    pub camera: Option<(Vec3, Mat3, f32)>,
    pub velocity: Vec3,
    pub tick: u64,
    pub state: String,
    /// gm_sk8 addition: POSE_CHRIST_AIR (the animation's ChristAir
    /// attribute), POSE_BODY_FLIP (KnownAir body flip under way)
    pub flags: u32,
    /// gm_sk8: Skate 3 audio surface tags (& 0x7F, 0 = none): the four wheels'
    /// ground, then the grind's
    pub audio: [u32; 5],
}
pub const POSE_CHRIST_AIR: u32 = 1;
pub const POSE_BODY_FLIP: u32 = 2;
impl Session {
    pub fn new(
        root: &Path,
        triangles: Vec<[[f32; 3]; 3]>,
        rails: Vec<Vec<[f32; 3]>>,
        spawn: [f32; 3],
        heading: f32,
    ) -> Result<Self, String> {
        let started = std::time::Instant::now();
        eprintln!("IW4L_SKATE_LOAD begin");
        skate_data::input_config::StockGameplayConfig::load(root).map_err(|e| e.to_string())?;
        let assets = skate_data::GameAssets::load(root).map_err(|e| e.to_string())?;
        let graphs = StockGraphs::load(root, &assets)?;
        let map = collision_map(triangles, rails, spawn, heading);
        eprintln!("IW4L_SKATE_LOAD graphs {}ms", started.elapsed().as_millis());
        let physics = GamePhysics::load_with_map(root, Some(&map))?;
        eprintln!(
            "IW4L_SKATE_LOAD physics {}ms",
            started.elapsed().as_millis()
        );
        let mut physics = physics;
        // gm_sk8 addition: the stock gesture set (first four in table order),
        // so the D-pad gestures have selections before the add-on sends its own
        physics.set_gesture_preferences(Some([0, 1, 2, 3]));
        let skater = SkaterRuntime::load(root, &graphs, &physics, "easy")?;
        eprintln!("IW4L_SKATE_LOAD skater {}ms", started.elapsed().as_millis());
        Ok(Self {
            physics,
            skater,
            controls: PlayerControls::load(root)?,
            graphs,
            input: ControllerInput::default(),
            camera: CameraRuntime::load(root)?,
            markers: crate::session_marker::Runtime::load(root)?,
            forced_wipeout: 0,
            loose_board_friction: 0.0,
        })
    }
    /// A builder for collision to swap in later, usable on another thread.
    pub fn collision_builder(&self) -> CollisionBuilder {
        CollisionBuilder {
            material: self.physics.floor_material(),
        }
    }
    /// Skate 3's scoring for this skater, as the trick display shows it
    /// (gm_sk8 addition: read-only).
    pub fn scoring(&self) -> crate::scoring_runtime::ScoreView {
        self.skater.scoring.view()
    }

    /// Clean up after a tick that failed part-way, so the next tick (or a
    /// reset) can run (gm_sk8 addition).
    pub fn recover_after_error(&mut self) {
        self.physics.riding.abandon_wheel_queries();
        self.input = ControllerInput::default();
    }

    /// Add velocity (skate space, m/s) to the skater and board, as the game
    /// does when it hands momentum over (gm_sk8 addition: a testing boost).
    /// Returns false (and does nothing) unless riding on the board (rolling,
    /// powersliding, reverting) or in the air.
    pub fn push(&mut self, dv: [f32; 3]) -> bool {
        use skate_core::math::Vector3;
        let state = format!("{:?}", self.skater.player_state.current());
        let riding = ["PhysicsGround", "SlideGround", "RevertGround", "Air"].iter().any(|s| state.contains(s));
        if !riding || state.contains("Biped") || state.contains("Wipeout") {
            return false;
        }
        let d = Vector3::new(dv[0], dv[1], dv[2]);
        let add = |v: &mut Vector3| *v = Vector3::new(v.x + d.x, v.y + d.y, v.z + d.z);
        for body in self.physics.board.bodies_mut() {
            add(&mut body.rates.linear_velocity);
        }
        for body in self.skater.skeleton.bodies_mut() {
            add(&mut body.rates.linear_velocity);
        }
        let m = &mut self.skater.animated_skeleton.motion.velocity_world;
        m[0] += dv[0];
        m[1] += dv[1];
        m[2] += dv[2];
        // gm_sk8 addition: KnownAir follows the flight chosen at take-off
        // and overwrites body velocities, so the push bends that flight too
        if state.contains("KnownAir") && std::env::var("SK8_AIR_PUSH").as_deref() != Ok("off") {
            let now = self.skater.known_air.state.trajectory_index_216 as f32 / 60.0;
            self.skater.trajectory.selector.push_selection([dv[0], dv[1], dv[2], 0.0], now);
        }
        true
    }

    /// gm_sk8 addition: knock the skater off (an item hit in a minigame):
    /// the same wipeout request the ground's hang-up check makes.
    pub fn force_wipeout(&mut self) {
        self.forced_wipeout = 1;
    }

    /// gm_sk8 addition: rolling friction on the board while nobody rides it
    /// (bails, on foot): `decel` m/s^2 off its speed along the ground, 0 = the
    /// game's own (a loose board rolls a very long way on smooth floors).
    pub fn set_loose_board_friction(&mut self, decel: f32) {
        self.loose_board_friction = if decel.is_finite() { decel.max(0.0) } else { 0.0 };
    }

    fn roll_loose_board(&mut self) {
        use skate_core::math::Vector3;
        let decel = self.loose_board_friction;
        if decel <= 0.0 {
            return;
        }
        let state = format!("{:?}", self.skater.player_state.current());
        if !(state.contains("Wipeout") || state.contains("Biped")) {
            return;
        }
        let step = decel * self.period();
        for body in self.physics.board.bodies_mut() {
            let v = body.rates.linear_velocity;
            // (only rolling or sliding: a board flying through the air keeps its speed)
            if v.y.abs() > 1.5 {
                continue;
            }
            let speed = (v.x * v.x + v.z * v.z).sqrt();
            if speed <= 1e-4 {
                continue;
            }
            let k = (speed - step).max(0.0) / speed;
            body.rates.linear_velocity = Vector3::new(v.x * k, v.y, v.z * k);
            let w = body.rates.angular_velocity;
            body.rates.angular_velocity = Vector3::new(w.x * k, w.y * k, w.z * k);
        }
    }

    /// Moves the board and skater by `d` (skate space), as standing on
    /// something that moved under them (gm_sk8 addition: lifts, moving
    /// platforms). Positions only; velocities are kept.
    pub fn carry(&mut self, d: [f32; 3]) {
        self.carry_turning(d, [0.0; 3], 0.0);
    }

    /// As `carry`, turning too: about the vertical line through `pivot` by
    /// `yaw` radians (a turntable), then moved by `d` (gm_sk8 addition).
    pub fn carry_turning(&mut self, d: [f32; 3], pivot: [f32; 3], yaw: f32) {
        let (s, c) = yaw.sin_cos();
        // (about +Y, the skate world's up)
        self.carry_rotating(d, pivot, [[c, 0.0, s], [0.0, 1.0, 0.0], [-s, 0.0, c]]);
    }

    /// As `carry`, rotated first about `pivot` by `m` (rows; skate space): a
    /// turntable, a seesaw, a swinging platform (gm_sk8 addition). Each body
    /// turns whole - position, orientation, basis, world inertia and its
    /// velocities - so its motion relative to what it stands on carries on.
    pub fn carry_rotating(&mut self, d: [f32; 3], pivot: [f32; 3], m: [[f32; 3]; 3]) {
        use skate_core::math::Vector3;
        let identity = m == [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]];
        let rot = |v: [f32; 3]| std::array::from_fn::<f32, 3, _>(|r| m[r][0] * v[0] + m[r][1] * v[1] + m[r][2] * v[2]);
        let rot3 = |v: &mut Vector3| {
            let r = rot([v.x, v.y, v.z]);
            *v = Vector3::new(r[0], r[1], r[2]);
        };
        // (the rotation as a quaternion x, y, z, w)
        let q = {
            let t = m[0][0] + m[1][1] + m[2][2];
            if t > 0.0 {
                let s = (t + 1.0).sqrt() * 2.0;
                [(m[2][1] - m[1][2]) / s, (m[0][2] - m[2][0]) / s, (m[1][0] - m[0][1]) / s, 0.25 * s]
            } else if m[0][0] > m[1][1] && m[0][0] > m[2][2] {
                let s = (1.0 + m[0][0] - m[1][1] - m[2][2]).sqrt() * 2.0;
                [0.25 * s, (m[0][1] + m[1][0]) / s, (m[0][2] + m[2][0]) / s, (m[2][1] - m[1][2]) / s]
            } else if m[1][1] > m[2][2] {
                let s = (1.0 + m[1][1] - m[0][0] - m[2][2]).sqrt() * 2.0;
                [(m[0][1] + m[1][0]) / s, 0.25 * s, (m[1][2] + m[2][1]) / s, (m[0][2] - m[2][0]) / s]
            } else {
                let s = (1.0 + m[2][2] - m[0][0] - m[1][1]).sqrt() * 2.0;
                [(m[0][2] + m[2][0]) / s, (m[1][2] + m[2][1]) / s, 0.25 * s, (m[1][0] - m[0][1]) / s]
            }
        };
        let turn = |b: &mut skate_core::physics::assembly::BodySnapshot| {
            let r = &mut b.rates;
            let p = [r.position.x - pivot[0], r.position.y - pivot[1], r.position.z - pivot[2]];
            let p = if identity { p } else { rot(p) };
            r.position = Vector3::new(p[0] + pivot[0] + d[0], p[1] + pivot[1] + d[1], p[2] + pivot[2] + d[2]);
            if identity {
                return;
            }
            let o = r.orientation;
            let [qx, qy, qz, qw] = q;
            r.orientation.w = qw * o.w - qx * o.x - qy * o.y - qz * o.z;
            r.orientation.x = qw * o.x + qx * o.w + qy * o.z - qz * o.y;
            r.orientation.y = qw * o.y - qx * o.z + qy * o.w + qz * o.x;
            r.orientation.z = qw * o.z + qx * o.y - qy * o.x + qz * o.w;
            for col in r.basis.columns.iter_mut() {
                *col = rot(*col);
            }
            // (M W M^T: each column turned, then each row)
            let mut w = r.world_inverse_inertia.columns;
            for col in w.iter_mut() {
                *col = rot(*col);
            }
            let mut rows = [[0f32; 3]; 3];
            for i in 0..3 {
                rows[i] = rot([w[0][i], w[1][i], w[2][i]]);
            }
            for i in 0..3 {
                for j in 0..3 {
                    w[j][i] = rows[i][j];
                }
            }
            r.world_inverse_inertia.columns = w;
            rot3(&mut r.linear_velocity);
            rot3(&mut r.angular_velocity);
            rot3(&mut r.force_acceleration);
            rot3(&mut r.torque_acceleration);
        };
        for body in self.physics.board.bodies_mut() {
            turn(body);
        }
        turn(&mut self.physics.board.hook_mut().body);
        for body in self.skater.skeleton.bodies_mut() {
            turn(body);
        }
    }

    /// The skater's Create-a-Skater settings (gm_sk8 addition): natural stance
    /// (1 regular, 0 goofy), animation style by name ("" standard, "Loose",
    /// "Gonzo", "Aggressive", or a pro's own set such as "MikeCarroll"),
    /// posture profile (0 default, 1 stiff, 2 slouch, 3 buff) and the four
    /// D-pad gestures (Up, Down, Left, Right; indices into the 37-entry table).
    pub fn set_style(&mut self, natural: u32, style: &str, posture: u32, gestures: [u32; 4]) {
        let animation = &mut self.skater.animation;
        animation.set_customisation(natural, 0);
        animation.motion.playback_context.pro_skater =
            skate_core::animation::skeleton_input::name::encode(style.as_bytes());
        animation.motion.animation.posture.set_profile(posture.min(3));
        self.physics.set_gesture_preferences(Some(gestures));
    }

    /// Skate 3's difficulty (gm_sk8 addition): 0 easy, 1 normal, 2 hardcore,
    /// the game's own physics_mode tables, switched on the next tick.
    pub fn set_difficulty(&mut self, index: u32) {
        let d = crate::difficulty::Difficulty::ALL[index.min(2) as usize];
        self.physics.set_difficulty(d);
    }

    /// Start Skate 3's shove (the arm swing it uses on pedestrians) straight
    /// ahead, held for `ticks` (gm_sk8 addition: the RB punch). Only while
    /// riding on the ground or on foot; returns whether it could start.
    pub fn shove(&mut self, ticks: u32) -> bool {
        let state = format!("{:?}", self.skater.player_state.current());
        if state.contains("Air") || state.contains("Wipeout") || state.starts_with("Grind") {
            return false;
        }
        self.skater.forced_shove = ticks.max(1);
        true
    }

    /// Knock the skater off into a bail with this velocity (skate space, m/s),
    /// where they are now (gm_sk8 addition: hit by another player). Uses the
    /// engine's vehicle-ejection reset, which enters WipeoutGround seeded
    /// with momentum.
    pub fn knock_down(&mut self, velocity: [f32; 3]) -> bool {
        let state = format!("{:?}", self.skater.player_state.current());
        if state.contains("Wipeout") || state.contains("Teleport") {
            return false;
        }
        let mut transform = self.skater.animated_skeleton.roots.animation_to_world;
        transform[3][3] = 0.;
        let spin = [velocity[2] * 0.3, 0.0, -velocity[0] * 0.3];
        self.skater.teleport_state.request_vehicle_ejection(transform, velocity, spin);
        true
    }

    /// Back to Skate 3's automatic checkpoint, the last safe spot it recorded,
    /// as the game does after falling into water (gm_sk8 addition).
    pub fn return_to_checkpoint(&mut self) -> Result<(), String> {
        super::respawn::manual_return(&self.physics, &mut self.skater)
    }

    /// The session marker as a display needs it: (holding LB, a marker could be
    /// placed here, a marker exists to return to, return-hold progress 0..1,
    /// marker position in skate space) (gm_sk8 addition: read-only).
    pub fn marker(&self) -> (bool, bool, bool, f32, Option<[f32; 3]>) {
        self.markers.view()
    }

    /// Swaps in collision built by `collision_builder`: the world the skater
    /// rides, climbs and grinds from the next tick.
    /// gm_sk8 addition: replace the moving collision layer (other players,
    /// moving things), checked by every query after the static world. Cheap:
    /// only these triangles are prepared, the static world is untouched.
    pub fn set_moving_collision(&mut self, triangles: Vec<[[f32; 3]; 3]>) -> Result<usize, String> {
        let triangles: Vec<_> = triangles
            .into_iter()
            .filter(|t| {
                let [a, b, c] = t.map(bevy::math::Vec3::from_array);
                (b - a).cross(c - a).length_squared() > 1e-12
            })
            .collect();
        let moving = if triangles.is_empty() {
            Vec::new()
        } else {
            let map = collision_map(triangles, Vec::new(), [0.; 3], 0.);
            crate::skate_world::collision_world(&map, self.physics.floor_material())?.triangles().to_vec()
        };
        let n = moving.len();
        self.physics.set_moving(moving);
        Ok(n)
    }

    pub fn install_collision(&mut self, prepared: PreparedCollision) -> Result<(), String> {
        self.physics
            .install_world(prepared.world, std::sync::Arc::clone(&prepared.grind))?;
        self.skater.trajectory.bind_grind_world(prepared.grind);
        Ok(())
    }
    pub fn period(&self) -> f32 {
        self.physics.period().as_secs_f32()
    }
    pub fn set_aspect_ratio(&mut self, aspect_ratio: f32) {
        if aspect_ratio.is_finite() && aspect_ratio > 0. {
            self.camera.set_aspect_ratio(aspect_ratio);
        }
    }
    /// Eagerly decode immutable animation banks before a map is ready.
    pub fn preload(root: &Path) -> Result<(), String> {
        crate::skater_animation::AnimationSource::load(root).map(|_| ())
    }
    /// Reuse the complete world and animation session. The original teleport path
    /// resets physical bodies and animation state at the new MW2 position.
    pub fn activate(&mut self, spawn: [f32; 3], heading: f32) -> Result<Pose, String> {
        self.input = ControllerInput::default();
        self.markers.suspend();
        if self.physics.ticks == 0 {
            self.tick(Controls::default())?;
        }
        let mut transform = Mat4::from_rotation_translation(
            Quat::from_rotation_y(heading),
            Vec3::from_array(spawn),
        )
        .to_cols_array_2d();
        transform[3][3] = 0.;
        self.skater.travel_to(transform)?;
        for _ in 0..4 {
            self.tick(Controls::default())?;
        }
        self.input = ControllerInput::default();
        Ok(self.pose())
    }
    pub fn collect(&mut self, frame: InputFrame, dt: f32) {
        self.input.collect(frame.samples);
        self.markers.collect_time(f64::from(dt));
    }
    pub fn suspend_input(&mut self) {
        self.input = ControllerInput::default();
        self.markers.suspend();
    }
    pub fn advance(&mut self) -> Result<(), String> {
        self.input.publish_actions();
        self.advance_published()
    }
    fn advance_published(&mut self) -> Result<(), String> {
        let published = self.input.tick_input();
        self.markers
            .advance(&self.input, &self.physics, &mut self.skater);
        let mut actions = published.actions();
        self.controls.update_for_physics(
            &mut actions,
            &self.physics,
            &self.skater,
            &self.camera,
        )?;
        self.controls.publish_gestures(
            self.physics.animation_profile.physics_mode,
            self.skater.player_input.physical.state.state_16,
        );
        if self.forced_wipeout > 0 {
            self.forced_wipeout = 0;
            super::player_state::force_wipeout(&mut self.physics, &mut self.skater)?;
        }
        self.roll_loose_board();
        super::frame::advance(
            &mut self.physics,
            &mut self.skater,
            &mut self.controls,
            &self.graphs,
            &mut actions,
            published.controller_available(),
            &mut self.camera,
        )
    }
    /// Deterministic raw-packet entry point for playback/diagnostics.
    pub fn tick(&mut self, input: Controls) -> Result<(), String> {
        crate::input::sample(
            &mut self.input,
            skate_core::input::xbox::XboxState {
                buttons: input.buttons,
                triggers: input.triggers,
                left: input.left,
                right: input.right,
            },
        );
        self.markers.collect_time(f64::from(self.period()));
        self.advance_published()
    }
    pub fn pose(&self) -> Pose {
        let v = self.physics.board.bodies()[skate_core::physics::board::BodyId::Deck.index()]
            .rates
            .linear_velocity;
        Pose {
            root: crate::animation::native_matrix(
                self.skater.animated_skeleton.roots.animation_to_world,
            ),
            bones: self
                .skater
                .render_pose
                .iter()
                .map(|m| crate::animation::native_matrix(*m))
                .collect(),
            names: self.skater.animation.evaluator.frames.bone_names.clone(),
            camera: self.camera.frame.as_ref().map(|f| {
                (
                    Vec3::new(f.position[0], f.position[1], f.position[2]),
                    Mat3::from_cols_array_2d(&f.basis.columns),
                    f.field_of_view_degrees,
                )
            }),
            velocity: Vec3::new(v.x, v.y, v.z),
            tick: self.physics.ticks,
            state: format!("{:?}", self.skater.player_state.current()),
            flags: self.pose_flags(),
            audio: {
                let w = self.physics.riding.wheel_lines.audio_surfaces;
                [w[0], w[1], w[2], w[3], self.skater.player_input.physical.grinds.audio_surface_216 & 0x7F]
            },
        }
    }
    fn pose_flags(&self) -> u32 {
        let mut flags = 0;
        if self.skater.player_input.processed.flags_2472 & 0x40 != 0 {
            flags |= POSE_CHRIST_AIR;
        }
        let known_air = matches!(self.skater.player_state.current(), skate_core::player::state::PhysicalStateId::KnownAir);
        if known_air && self.skater.known_air.state.body_flipping_211 {
            flags |= POSE_BODY_FLIP;
        }
        flags
    }
}

/// Collision for `Session::install_collision`, built off the simulation.
pub struct PreparedCollision {
    world: skate_core::physics::board_world::BoardWorld,
    grind: std::sync::Arc<crate::grind_world::StaticProvider>,
}

#[derive(Clone, Copy)]
pub struct CollisionBuilder {
    material: skate_core::physics::contact::RetailContactMaterial,
}

impl CollisionBuilder {
    pub fn build(
        &self,
        triangles: Vec<[[f32; 3]; 3]>,
        rails: Vec<Vec<[f32; 3]>>,
    ) -> Result<PreparedCollision, String> {
        let map = collision_map(triangles, rails, [0.; 3], 0.);
        Ok(PreparedCollision {
            world: crate::skate_world::collision_world(&map, self.material)?,
            grind: std::sync::Arc::new(crate::grind_world::StaticProvider::new(Some(&map))?),
        })
    }
}

/// gm_sk8: the map's retail grind splines (a .skate rail's native bytes, in
/// skate space) with the first and last point of the polyline each was
/// sampled into. A rail handed in with those ends grinds on the spline itself,
/// as it did from a .skate package, instead of on the polyline.
pub static NATIVE_RAILS: std::sync::Mutex<Vec<([f32; 3], [f32; 3], Vec<u8>)>> = std::sync::Mutex::new(Vec::new());

/// gm_sk8: the map's collision triangles (by their corners' bits) with their
/// retail surface, native edge codes and sidedness, as a .skate package's
/// RWCM gave them. Without them every edge was guessed from welded
/// neighbours, and where two pieces of a curved rail's tube meet that came
/// out sharp: the board caught on it.
type NativeTriangle = (u32, Option<[u8; 3]>, bool);
static NATIVE_TRIANGLES: std::sync::Mutex<Option<std::collections::HashMap<[u32; 9], NativeTriangle>>> =
    std::sync::Mutex::new(None);

pub fn set_native_triangles(tris: Vec<([[f32; 3]; 3], u32, Option<[u8; 3]>, bool)>) {
    let map = (!tris.is_empty()).then(|| {
        tris.into_iter().map(|(p, surface, edges, one_sided)| (key(&p), (surface, edges, one_sided))).collect()
    });
    *NATIVE_TRIANGLES.lock().unwrap_or_else(|e| e.into_inner()) = map;
}

fn key(p: &[[f32; 3]; 3]) -> [u32; 9] {
    std::array::from_fn(|i| p[i / 3][i % 3].to_bits())
}

/// Bit 31 of a collision triangle's surface: its mesh is one-sided (only from
/// NATIVE_TRIANGLES; skate_world takes it off again).
pub(crate) const SURFACE_ONE_SIDED: u32 = 1 << 31;
/// Bit 30: the triangle came from NATIVE_TRIANGLES (its surface and
/// sidedness are the game's own).
pub(crate) const SURFACE_RETAIL: u32 = 1 << 30;

fn native_for(points: &[[f32; 3]]) -> Option<Vec<u8>> {
    let (first, last) = (points.first()?, points.last()?);
    let near = |a: &[f32; 3], b: &[f32; 3]| (0..3).all(|i| (a[i] - b[i]).abs() <= 0.01);
    let natives = NATIVE_RAILS.lock().unwrap_or_else(|e| e.into_inner());
    natives.iter().find(|(f, l, _)| near(f, first) && near(l, last)).map(|n| n.2.clone())
}

/// IW4L's collision as a Skate map: one material, the triangles and rails.
fn collision_map(
    triangles: Vec<[[f32; 3]; 3]>,
    rails: Vec<Vec<[f32; 3]>>,
    spawn: [f32; 3],
    heading: f32,
) -> SkateMap {
    SkateMap {
            version: 14,
            name: "IW4L collision".into(),
            spawn,
            heading,
            environment: vec![],
            materials: vec![skate_data::skate_map::Material {
                name: "MW2".into(),
                flags: 0,
                friction: 0.8,
                restitution: 0.,
                color: [1.; 3],
                roughness: 1.,
                emissive: 0.,
                textures: [0; 5],
                indirect_strength: 1.,
                alpha_mode: 0,
                alpha_cutoff: 0.5,
                audio: 0,
                physics: 0,
                pattern: 0,
                depth_layer: None,
                retail_definition: None,
            }],
            textures: vec![],
            geometry: Geometry {
                vertices: vec![],
                indices: vec![],
                collision: {
                    let natives = NATIVE_TRIANGLES.lock().unwrap_or_else(|e| e.into_inner());
                    triangles
                        .into_iter()
                        .map(|points| {
                            let native = natives.as_ref().and_then(|m| m.get(&key(&points)));
                            Collision {
                                points,
                                surface: native.map_or(0, |n| (n.0 & 0xFFFF) | SURFACE_RETAIL | if n.2 { SURFACE_ONE_SIDED } else { 0 }),
                                material: 1,
                                native_edges: native.and_then(|n| n.1),
                            }
                        })
                        .collect()
                },
            },
            rails: rails
                .into_iter()
                .enumerate()
                .map(|(i, p)| Rail {
                    name: format!("iw4_edge_{i}"),
                    closed: false,
                    native: native_for(&p),
                    points: p,
                })
                .collect(),
            doors: vec![],
            lights: vec![],
            routes: vec![],
            extensions: vec![],
    }
}

/// The source engine's raw XInput transport. No Bevy deadzones, button remaps,
/// trigger reconstruction or rounding are inserted ahead of its native Pad.
#[derive(Default)]
pub struct ControllerTransport {
    capabilities: [crate::input::platform::CapabilityCache; 4],
}
pub struct InputFrame {
    samples: [Result<crate::input::platform::DevicePacket, crate::input::platform::DeviceError>; 4],
}
impl ControllerTransport {
    pub fn poll(&mut self) -> InputFrame {
        InputFrame {
            samples: std::array::from_fn(|i| {
                crate::input::platform::poll_cached(i, &mut self.capabilities[i])
            }),
        }
    }
}
impl InputFrame {
    pub fn neutral() -> Self {
        Self {
            samples: std::array::from_fn(|_|Err(crate::input::platform::DeviceError::Disconnected)),
        }
    }
    pub fn controller(&self) -> Option<usize> {
        self.samples.iter().position(Result::is_ok)
    }
    /// Take buttons out of this frame's pad samples (gm_sk8 addition: e.g. the
    /// board dismount while airborne, whose Skate 3 behaviour isn't ported).
    pub fn mask_buttons(&mut self, mask: u16) {
        for s in self.samples.iter_mut().flatten() {
            s.state.buttons &= !mask;
        }
    }
    /// Each slot's XInput packet number, None if nothing answers there (gm_sk8
    /// addition: the number changes whenever that pad's state does, so the
    /// host can follow the pad actually in use).
    pub fn packet_numbers(&self) -> [Option<u32>; 4] {
        std::array::from_fn(|i| self.samples[i].as_ref().ok().map(|p| p.number))
    }
    /// Leave only this slot's pad in the frame (gm_sk8 addition).
    pub fn keep_only(&mut self, slot: usize) {
        for (i, s) in self.samples.iter_mut().enumerate() {
            if i != slot {
                *s = Err(crate::input::platform::DeviceError::Disconnected);
            }
        }
    }
    /// Put a pad read some other way (not XInput) into the first empty slot,
    /// as an Xbox pad (gm_sk8 addition). Returns the slot, or None if all four
    /// are taken.
    pub fn insert_pad(&mut self, number: u32, buttons: u16, triggers: [u8; 2], left: [i16; 2], right: [i16; 2]) -> Option<usize> {
        let slot = self.samples.iter().position(Result::is_err)?;
        self.samples[slot] = Ok(crate::input::platform::DevicePacket {
            number,
            state: skate_core::input::xbox::XboxState { buttons, triggers, left, right },
            subtype: 1,
        });
        Some(slot)
    }
    pub fn buttons(&self) -> u16 {
        self.samples
            .iter()
            .find_map(|s| s.as_ref().ok().map(|s| s.state.buttons))
            .unwrap_or(0)
    }
    /// Left and right trigger, 0-255 (gm_sk8 addition: the add-on's own
    /// controller features read them).
    pub fn triggers(&self) -> [u8; 2] {
        self.samples
            .iter()
            .find_map(|s| s.as_ref().ok().map(|s| s.state.triggers))
            .unwrap_or([0, 0])
    }
    pub fn sticks(&self) -> [[i16; 2]; 2] {
        self.samples
            .iter()
            .find_map(|s| s.as_ref().ok().map(|s| [s.state.left, s.state.right]))
            .unwrap_or([[0, 0], [0, 0]])
    }
}
