//! The simulation behind one small interface. With the `engine` feature this is
//! the real Skate 3 simulation (skate-host's `bridge::Session`); without it, a
//! stand-in that fakes a skater so the Lua side can be tested on its own.

use std::path::Path;

/// Raw Xbox pad state, the same packet skate-host's `Session::tick` takes.
#[derive(Clone, Copy, Default, Debug)]
#[cfg_attr(not(feature = "engine"), allow(dead_code))]
pub struct Controls {
    pub buttons: u16,
    pub triggers: [u8; 2],
    pub left: [i16; 2],
    pub right: [i16; 2],
}

/// Skate 3's scoring as the trick display shows it.
#[derive(Clone, Debug, Default)]
pub struct Score {
    pub sequence: f32,
    pub line: f32,
    pub total: f32,
    pub line_time: f32,
    pub line_capacity: f32,
    pub multiplier: f32,
    pub clean: bool,
    pub sketchy: bool,
    pub stance: [bool; 4],
    pub trick: String,
    pub tricks_named: u32,
    /// gm_sk8: what Skate 3's own trick display reads (hud/), the raw trick
    /// label and the display events of every tick since the last pose
    pub sequence_timer: i32,
    pub hud_line_capacity: f32,
    pub trick_label: String,
    pub new_trick: bool,
    pub modified_trick: bool,
    pub close_tricks: bool,
}

/// Skate 3's session marker, as a display needs it.
#[derive(Clone, Debug, Default)]
pub struct Marker {
    /// LB held (the marker controls are active)
    pub active: bool,
    pub can_place: bool,
    pub can_return: bool,
    /// return-hold progress 0..1
    pub progress: f32,
    /// skate space
    pub position: Option<[f32; 3]>,
}

/// A published pose, still in skate space (metres, Y up).
#[derive(Clone, Debug, Default)]
pub struct Pose {
    pub root: [f32; 16],
    pub bones: Vec<[f32; 16]>,
    pub names: Vec<String>,
    /// position, camera basis columns (x, y, z), field of view in degrees
    pub camera: Option<([f32; 3], [[f32; 3]; 3], f32)>,
    pub velocity: [f32; 3],
    pub tick: u64,
    pub state: String,
    pub score: Score,
    pub marker: Marker,
    /// Skate 3 audio surface tags: four wheels, then the grind (0 = none)
    pub audio: [u32; 5],
    pub christ_air: bool,
    pub body_flip: bool,
}

/// Where the input for a step comes from.
pub enum Input {
    /// Keyboard and mouse, already converted to a pad packet by Lua.
    Synthetic(Controls),
    /// Read the real controller directly (XInput), if one is connected.
    Controller,
}

/// Keep Y (get off the board) from the engine while airborne (off by default).
pub static BLOCK_AIR_DISMOUNT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
pub static INPUT_BLOCKED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// Keep the session marker (LB + D-pad up / down) from the engine.
pub static PAD_NAME: std::sync::Mutex<String> = std::sync::Mutex::new(String::new());
pub static PAD_KIND: std::sync::Mutex<&'static str> = std::sync::Mutex::new("xbox");
pub static MARKER_BLOCKED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// Buttons kept from the engine (a minigame uses them: left stick in for items).
pub static MASKED_BUTTONS: std::sync::atomic::AtomicU16 = std::sync::atomic::AtomicU16::new(0);
/// Rolling friction on a loose board (m/s^2, f32 bits; 0 = the game's own).
pub static BOARD_FRICTION: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
pub fn board_friction() -> f32 {
    f32::from_bits(BOARD_FRICTION.load(std::sync::atomic::Ordering::Relaxed))
}

/// Seconds in the air before the engine sends you back to a checkpoint (0 = never).
pub fn set_air_reset(seconds: f32) {
    let frames = if seconds.is_finite() && seconds > 0.0 { (seconds * 60.0).round() as u32 } else { 0 };
    #[cfg(feature = "engine")]
    skate_host::AIR_TELEPORT_FRAMES.store(frames, std::sync::atomic::Ordering::Relaxed);
    #[cfg(not(feature = "engine"))]
    AIR_RESET_FRAMES.store(frames, std::sync::atomic::Ordering::Relaxed);
}
#[cfg(not(feature = "engine"))]
pub static AIR_RESET_FRAMES: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(1800);

/// The skater's style (skategm.SetStyle): natural stance (1 regular, 0
/// goofy), animation style name, posture profile, D-pad gestures (Up, Down,
/// Left, Right). Each change bumps the generation; the simulation applies
/// it before its next step.
#[derive(Clone)]
pub struct Style {
    pub natural: u32,
    pub style: String,
    pub posture: u32,
    pub gestures: [u32; 4],
}
pub static STYLE: std::sync::Mutex<(u64, Option<Style>)> = std::sync::Mutex::new((0, None));

pub fn set_style(s: Style) {
    let mut g = STYLE.lock().unwrap_or_else(|e| e.into_inner());
    g.0 += 1;
    g.1 = Some(s);
}

/// The map's retail grind splines (authored::native_rails), for the engine to
/// grind on instead of their polylines. A map without them clears the list.
pub fn set_native_rails(natives: Vec<([f32; 3], [f32; 3], Vec<u8>)>) {
    #[cfg(feature = "engine")]
    {
        *skate_host::bridge::NATIVE_RAILS.lock().unwrap_or_else(|e| e.into_inner()) = natives;
    }
    #[cfg(not(feature = "engine"))]
    let _ = natives;
}

/// The map's collision triangles with their retail surface and native edges
/// (authored::native_triangles), for the engine's collision_map.
pub fn set_native_triangles(tris: Vec<([[f32; 3]; 3], u32, Option<[u8; 3]>, bool)>) {
    #[cfg(feature = "engine")]
    skate_host::bridge::set_native_triangles(tris);
    #[cfg(not(feature = "engine"))]
    let _ = tris;
}

/// Skate 3's difficulty (skategm.SetDifficulty): 0 easy, 1 normal, 2 hardcore.
pub static DIFFICULTY: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// A punch asked for (skategm.Punch): ticks to hold Skate 3's shove, taken
/// by the next step. And a knock-down (skategm.KnockDown): skate-space m/s.
pub static PUNCH: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
pub static PUNCH_OK: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
pub static KNOCK: std::sync::Mutex<Option<[f32; 3]>> = std::sync::Mutex::new(None);

pub fn set_camera_shake(on: bool) {
    #[cfg(feature = "engine")]
    skate_host::CAMERA_SHAKE_OFF.store(!on, std::sync::atomic::Ordering::Relaxed);
    #[cfg(not(feature = "engine"))]
    CAMERA_SHAKE.store(on, std::sync::atomic::Ordering::Relaxed);
}
pub fn set_camera_type(kind: u32) {
    #[cfg(feature = "engine")]
    skate_host::CAMERA_TYPE.store(kind, std::sync::atomic::Ordering::Relaxed);
    #[cfg(not(feature = "engine"))]
    CAMERA_TYPE.store(kind, std::sync::atomic::Ordering::Relaxed);
}
#[cfg(not(feature = "engine"))]
pub static CAMERA_TYPE: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(1);
#[cfg(not(feature = "engine"))]
pub static CAMERA_SHAKE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);

#[cfg(feature = "engine")]
mod real {
    use super::*;
    use skate_host::bridge::{CollisionBuilder, Controls as HostControls, ControllerTransport, PreparedCollision, Session};

    /// Builds collision off the simulation thread (Copy + Send, as in the mashup).
    #[derive(Clone, Copy)]
    pub struct Builder(CollisionBuilder);
    pub struct Prepared(PreparedCollision);

    impl Builder {
        pub fn build(&self, triangles: Vec<[[f32; 3]; 3]>, rails: Vec<Vec<[f32; 3]>>) -> Result<Prepared, String> {
            self.0.build(triangles, rails).map(Prepared)
        }
    }

    pub struct Sim {
        session: Session,
        pad: ControllerTransport,
        accumulated: f32,
        /// the physical state after the last tick (to know when we're airborne)
        last_state: String,
        /// the buttons handed to the engine for the latest tick (error reports)
        last_buttons: u16,
        /// the pad's own buttons and triggers this step (for the add-on's
        /// controller features: the rocket, interacting on foot)
        pad_buttons: u16,
        pad_triggers: [u8; 2],
        pad_sticks: [[i16; 2]; 2],
        connected: bool,
        pads: crate::pad::Pads,
        /// the STYLE generation last applied
        style_gen: u64,
        /// the DIFFICULTY last applied (the session starts on easy)
        difficulty: u32,
    }

    /// Y gets you off the board. Its in-air version ("AirDismounting") once
    /// stopped a tick with "not implemented", so Y was kept from the engine in
    /// the air; now that's a setting (off: Y works in the air), to find out
    /// which in-air cases actually fail. A failed tick is recovered either way.
    const DISMOUNT: u16 = 0x8000;
    fn block_air_y() -> bool {
        super::BLOCK_AIR_DISMOUNT.load(std::sync::atomic::Ordering::Relaxed)
    }
    const MARKER_MODIFIER: u16 = 0x0100;
    const MARKER_DPAD: u16 = 0x0003;
    fn marker_mask(buttons: u16) -> u16 {
        let masked = super::MASKED_BUTTONS.load(std::sync::atomic::Ordering::Relaxed);
        if super::MARKER_BLOCKED.load(std::sync::atomic::Ordering::Relaxed) && buttons & MARKER_MODIFIER != 0 {
            MARKER_DPAD | masked
        } else {
            masked
        }
    }
    fn airborne(state: &str) -> bool {
        state.contains("Air")
    }

    fn convert(p: skate_host::bridge::Pose, session: &Session) -> Pose {
        let v = session.scoring();
        let score = Score {
            sequence: v.sequence_score,
            line: v.line_score,
            total: v.total_score,
            line_time: v.line_time,
            line_capacity: v.line_capacity,
            multiplier: v.multiplier,
            clean: v.clean,
            sketchy: v.sketchy,
            stance: v.stance,
            trick_label: v.trick_name.clone(),
            trick: v.trick_name,
            tricks_named: v.tricks_named,
            sequence_timer: v.sequence_timer,
            hud_line_capacity: v.hud_line_capacity,
            new_trick: v.new_trick,
            modified_trick: v.modified_trick,
            close_tricks: v.close_tricks,
        };
        let (active, can_place, can_return, progress, position) = session.marker();
        let marker = Marker { active, can_place, can_return, progress, position };
        Pose {
            score,
            marker,
            root: p.root.to_cols_array(),
            bones: p.bones.iter().map(|m| m.to_cols_array()).collect(),
            names: p.names,
            camera: p.camera.map(|(pos, basis, fov)| {
                (
                    pos.to_array(),
                    [basis.x_axis.to_array(), basis.y_axis.to_array(), basis.z_axis.to_array()],
                    fov,
                )
            }),
            velocity: p.velocity.to_array(),
            tick: p.tick,
            audio: p.audio,
            state: p.state,
            christ_air: p.flags & skate_host::bridge::POSE_CHRIST_AIR != 0,
            body_flip: p.flags & skate_host::bridge::POSE_BODY_FLIP != 0,
        }
    }

    impl Sim {
        pub fn new(root: &Path, triangles: Vec<[[f32; 3]; 3]>, rails: Vec<Vec<[f32; 3]>>, spawn: [f32; 3], heading: f32) -> Result<Self, String> {
            Ok(Self {
                session: Session::new(root, triangles, rails, spawn, heading)?,
                pad: ControllerTransport::default(),
                accumulated: 0.0,
                last_state: String::new(),
                last_buttons: 0,
                pad_buttons: 0,
                pad_triggers: [0, 0],
                pad_sticks: [[0, 0], [0, 0]],
                connected: false,
                pads: crate::pad::Pads::default(),
                style_gen: 0,
                difficulty: 0,
            })
        }

        fn apply_style(&mut self) {
            let d = super::DIFFICULTY.load(std::sync::atomic::Ordering::Relaxed);
            if d != self.difficulty {
                self.difficulty = d;
                self.session.set_difficulty(d);
            }
            let g = super::STYLE.lock().unwrap_or_else(|e| e.into_inner());
            if g.0 == self.style_gen {
                return;
            }
            self.style_gen = g.0;
            if let Some(s) = &g.1 {
                self.session.set_style(s.natural, &s.style, s.posture, s.gestures);
            }
        }

        pub fn activate(&mut self, spawn: [f32; 3], heading: f32) -> Result<Pose, String> {
            self.accumulated = 0.0;
            self.apply_style();
            self.session.activate(spawn, heading).map(|p| convert(p, &self.session))
        }

        pub fn period(&self) -> f32 {
            self.session.period()
        }

        pub fn builder(&self) -> Builder {
            Builder(self.session.collision_builder())
        }

        /// Load Skate 3's animation data into the engine's own process-wide
        /// cache ahead of time, so starting a session later doesn't wait for it.
        pub fn preload(root: &std::path::Path) -> Result<(), String> {
            Session::preload(root)
        }

        /// Add velocity (skate space, m/s): a testing boost. False if not riding.
        pub fn push(&mut self, dv: [f32; 3]) -> bool {
            self.session.push(dv)
        }

        pub fn force_wipeout(&mut self) {
            self.session.force_wipeout()
        }

        /// Move the board and skater by `d` (skate space), rotated about
        /// `pivot` by `m` (rows) first: carried by a mover.
        pub fn carry(&mut self, d: [f32; 3], pivot: [f32; 3], m: [[f32; 3]; 3]) {
            self.session.carry_rotating(d, pivot, m)
        }

        /// The physical state after the last good tick (for error reports).
        pub fn last_state(&self) -> &str {
            &self.last_state
        }
        pub fn last_buttons(&self) -> u16 {
            self.last_buttons
        }
        /// The controller as the add-on sees it: buttons and triggers (0-255).
        pub fn pad_state(&self) -> (u16, [u8; 2]) {
            (self.pad_buttons, self.pad_triggers)
        }

        pub fn pad_sticks(&self) -> [[i16; 2]; 2] {
            self.pad_sticks
        }

        fn read_pad(&mut self) -> skate_host::bridge::InputFrame {
            let mut frame = self.pad.poll();
            let (slot, other) = self.pads.pick(frame.packet_numbers());
            frame.keep_only(slot.unwrap_or(usize::MAX));
            if let Some((number, s)) = other {
                frame.insert_pad(number, s.buttons, s.triggers, s.left, s.right);
            }
            let mut name = super::PAD_NAME.lock().unwrap_or_else(|e| e.into_inner());
            if *name != self.pads.name {
                name.clone_from(&self.pads.name);
            }
            *super::PAD_KIND.lock().unwrap_or_else(|e| e.into_inner()) = if self.pads.kind.is_empty() { "xbox" } else { self.pads.kind };
            frame
        }

        pub fn poll_pad(&mut self) {
            let frame = self.read_pad();
            self.connected = frame.controller().is_some();
            self.pad_buttons = frame.buttons();
            self.pad_triggers = frame.triggers();
            self.pad_sticks = frame.sticks();
        }

        /// Clean up after a tick that failed part-way.
        pub fn recover(&mut self) {
            self.session.recover_after_error();
            self.accumulated = 0.0;
        }

        /// Back to Skate 3's automatic checkpoint (the last safe spot).
        pub fn return_to_checkpoint(&mut self) -> Result<(), String> {
            self.session.return_to_checkpoint()
        }

        /// Swap in new collision; the skater rides it from the next tick.
        pub fn install(&mut self, p: Prepared) -> Result<(), String> {
            self.session.install_collision(p.0)
        }

        /// The moving collision layer (skate space), swapped in whole.
        pub fn set_moving(&mut self, tris: Vec<[[f32; 3]; 3]>) -> Result<usize, String> {
            self.session.set_moving_collision(tris)
        }

        pub fn controller_connected(&mut self) -> bool {
            self.connected
        }

        pub fn poll_connected(&mut self) -> bool {
            self.connected = self.read_pad().controller().is_some();
            self.connected
        }

        /// Advance by `dt` seconds of real time at the simulation's own rate.
        /// Returns the newest pose (if any tick ran) and the number of ticks.
        pub fn step(&mut self, dt: f32, input: Input) -> Result<(Option<Pose>, u32), String> {
            self.apply_style();
            let punch = super::PUNCH.swap(0, std::sync::atomic::Ordering::Relaxed);
            if punch > 0 {
                let ok = self.session.shove(punch);
                super::PUNCH_OK.store(ok, std::sync::atomic::Ordering::Relaxed);
            }
            let knock = super::KNOCK.lock().unwrap_or_else(|e| e.into_inner()).take();
            if let Some(v) = knock {
                self.session.knock_down(v);
            }
            let pad = match input {
                Input::Controller => {
                    let mut frame = self.read_pad();
                    self.connected = frame.controller().is_some();
                    self.pad_buttons = frame.buttons();
                    self.pad_triggers = frame.triggers();
                    self.pad_sticks = frame.sticks();
                    if block_air_y() && airborne(&self.last_state) {
                        frame.mask_buttons(DISMOUNT);
                    }
                    let marker = marker_mask(frame.buttons());
                    if marker != 0 {
                        frame.mask_buttons(marker);
                    }
                    self.last_buttons = frame.buttons();
                    if super::INPUT_BLOCKED.load(std::sync::atomic::Ordering::Relaxed) {
                        self.last_buttons = 0;
                        Some(Controls::default())
                    } else if frame.controller().is_some() {
                        self.session.collect(frame, dt);
                        None
                    } else {
                        Some(Controls::default())
                    }
                }
                Input::Synthetic(mut c) => {
                    if block_air_y() && airborne(&self.last_state) {
                        c.buttons &= !DISMOUNT;
                    }
                    c.buttons &= !marker_mask(c.buttons);
                    self.last_buttons = c.buttons;
                    Some(c)
                }
            };
            // same cap as the mashup: never try to catch up more than 150 ms
            self.accumulated = (self.accumulated + dt).min(0.15);
            let mut ticks = 0;
            self.session.set_loose_board_friction(super::board_friction());
            // (the trick display's events of every tick, not just the last)
            let mut events = [false; 3];
            while self.accumulated >= self.session.period() {
                self.accumulated -= self.session.period();
                match pad {
                    None => self.session.advance()?,
                    Some(c) => self.session.tick(HostControls {
                        buttons: c.buttons,
                        triggers: c.triggers,
                        left: c.left,
                        right: c.right,
                    })?,
                }
                ticks += 1;
                let v = self.session.scoring();
                events[0] |= v.new_trick;
                events[1] |= v.modified_trick;
                events[2] |= v.close_tricks;
            }
            if ticks > 0 {
                let mut pose = convert(self.session.pose(), &self.session);
                pose.score.new_trick = events[0];
                pose.score.modified_trick = events[1];
                pose.score.close_tricks = events[2];
                self.last_state = pose.state.clone();
                return Ok((Some(pose), ticks));
            }
            Ok((None, ticks))
        }
    }
}

#[cfg(not(feature = "engine"))]
mod real {
    //! Stand-in: a stick figure that rolls where the left stick points.
    use super::*;

    #[derive(Clone, Copy)]
    pub struct Builder;
    pub struct Prepared(#[allow(dead_code)] pub usize);
    impl Builder {
        pub fn build(&self, triangles: Vec<[[f32; 3]; 3]>, _rails: Vec<Vec<[f32; 3]>>) -> Result<Prepared, String> {
            Ok(Prepared(triangles.len()))
        }
    }

    pub struct Sim {
        pos: [f32; 3],
        spawn: [f32; 3],
        /// test hook: a failed tick leaves the stand-in broken until recover()
        broken: bool,
        hard: bool,
        /// (test hook) how many boosts it's had
        pub pushes: u32,
        checkpoint_returns: u32,
        heading: f32,
        speed: f32,
        tick: u64,
        accumulated: f32,
    }

    impl Sim {
        pub fn new(root: &Path, _triangles: Vec<[[f32; 3]; 3]>, _rails: Vec<Vec<[f32; 3]>>, spawn: [f32; 3], heading: f32) -> Result<Self, String> {
            if !root.as_os_str().is_empty() && !root.exists() {
                return Err(format!("data folder not found: {}", root.display()));
            }
            Ok(Self { pos: spawn, spawn, broken: false, hard: false, pushes: 0, checkpoint_returns: 0, heading, speed: 0.0, tick: 0, accumulated: 0.0 })
        }
        pub fn activate(&mut self, spawn: [f32; 3], heading: f32) -> Result<Pose, String> {
            if self.broken {
                return Err("stand-in: Wheel queries were started twice without result publication".into());
            }
            self.pos = spawn;
            self.heading = heading;
            self.speed = 0.0;
            Ok(self.pose())
        }
        pub fn period(&self) -> f32 {
            1.0 / 60.0
        }
        pub fn builder(&self) -> Builder {
            Builder
        }
        pub fn last_state(&self) -> &str {
            "PhysicsGround"
        }
        pub fn last_buttons(&self) -> u16 {
            0
        }
        pub fn pad_state(&self) -> (u16, [u8; 2]) {
            (0, [0, 0])
        }
        pub fn pad_sticks(&self) -> [[i16; 2]; 2] {
            [[0, 0], [0, 0]]
        }
        pub fn poll_pad(&mut self) {}

        /// (stand-in) carried: nothing to move
        pub fn carry(&mut self, _d: [f32; 3], _pivot: [f32; 3], _m: [[f32; 3]; 3]) {}

        pub fn force_wipeout(&mut self) {
            self.speed = 0.0;
        }

        /// (stand-in) a boost moves it along
        pub fn push(&mut self, dv: [f32; 3]) -> bool {
            self.speed += (dv[0] * dv[0] + dv[2] * dv[2]).sqrt();
            self.pushes += 1;
            true
        }

        pub fn preload(_root: &std::path::Path) -> Result<(), String> {
            std::thread::sleep(std::time::Duration::from_millis(50));
            Ok(())
        }

        pub fn recover(&mut self) {
            if !self.hard {
                self.broken = false;
            }
        }
        /// The stand-in keeps its spawn as the only checkpoint.
        pub fn return_to_checkpoint(&mut self) -> Result<(), String> {
            self.pos = self.spawn;
            self.speed = 0.0;
            self.checkpoint_returns += 1;
            Ok(())
        }
        pub fn install(&mut self, _p: Prepared) -> Result<(), String> {
            Ok(())
        }
        pub fn set_moving(&mut self, tris: Vec<[[f32; 3]; 3]>) -> Result<usize, String> {
            Ok(tris.len())
        }
        pub fn controller_connected(&mut self) -> bool {
            false
        }
        pub fn poll_connected(&mut self) -> bool {
            false
        }
        pub fn step(&mut self, dt: f32, input: Input) -> Result<(Option<Pose>, u32), String> {
            let c = match input {
                Input::Synthetic(c) => c,
                Input::Controller => Controls::default(),
            };
            // test hook: an all-buttons packet makes the stand-in fail a tick,
            // like an unimplemented Skate 3 graph path in the real engine
            if c.buttons == 0xFFFF {
                // like a real tick failing part-way: unusable until recover()
                self.broken = true;
                return Err("stand-in: simulated engine error".into());
            }
            if c.buttons == 0xFFFE {
                // broken beyond recover(): only a fresh session helps
                self.broken = true;
                self.hard = true;
                return Err("stand-in: simulated engine error (hard)".into());
            }
            if self.broken {
                return Err("stand-in: still broken (a tick failed part-way)".into());
            }
            self.accumulated = (self.accumulated + dt).min(0.15);
            let mut ticks = 0;
            while self.accumulated >= self.period() {
                self.accumulated -= self.period();
                let p = self.period();
                self.heading -= c.left[0] as f32 / 32767.0 * 2.0 * p;
                if c.buttons & 0x1000 != 0 {
                    self.speed = (self.speed + 6.0 * p).min(8.0);
                }
                if c.buttons & 0x2000 != 0 {
                    self.speed = (self.speed - 12.0 * p).max(0.0);
                }
                self.speed *= 1.0 - 0.3 * p;
                self.pos[0] += self.heading.sin() * self.speed * p;
                self.pos[2] += self.heading.cos() * self.speed * p;
                self.tick += 1;
                ticks += 1;
            }
            Ok((if ticks > 0 { Some(self.pose()) } else { None }, ticks))
        }
        fn pose(&self) -> Pose {
            let (s, c) = self.heading.sin_cos();
            let mut root = [0.0; 16];
            root[0] = c;
            root[2] = -s;
            root[5] = 1.0;
            root[8] = s;
            root[10] = c;
            root[12] = self.pos[0];
            root[13] = self.pos[1];
            root[14] = self.pos[2];
            root[15] = 1.0;
            let names = ["HIPS", "SPINE", "CHEST", "NECK", "HEAD"];
            let bones = (0..names.len())
                .map(|i| {
                    let mut m = root;
                    m[13] += 0.9 + i as f32 * 0.2;
                    m
                })
                .collect();
            Pose {
                root,
                bones,
                names: names.iter().map(|s| s.to_string()).collect(),
                camera: None,
                velocity: [s * self.speed, 0.0, c * self.speed],
                tick: self.tick,
                state: if self.speed > 0.1 { "Riding (stand-in)".into() } else { "Idle (stand-in)".into() },
                score: Score { multiplier: 1.0, ..Score::default() },
                marker: Marker { position: (self.checkpoint_returns > 0).then_some(self.spawn), ..Marker::default() },
                audio: [0; 5],
                christ_air: false,
                body_flip: false,
            }
        }
    }
}

pub use real::{Builder, Prepared, Sim};

pub const ENGINE: &str = if cfg!(feature = "engine") { "skate-host" } else { "stand-in" };
