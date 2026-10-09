//! NPC (AI) skaters' board sounds: the local player's components run for a second owner of the
//! MixMap Player slot, fed by the state an AI-skater system publishes ([`NpcSkaterAudioState`]).
//!
//! **What retail does** (TU3 recompilation, reference only; spec note
//! `audio-specs/world-npc-skater-audio.md`):
//! - The Player slot has 2 MixMap instances in free skate (`mixmap::RETAIL_INSTANCES[1]`), one per
//!   `CSTATE_Player` record; `CSTATEMGR_Player` (init `sub_824F1F40`) creates exactly two records.
//! - Its update `sub_824F1FB0` walks the skater list (`*(G+0x2F070)`, 544-byte entries, index 0 the
//!   local player): the local skater always, an NPC skater only while its position is **less than
//!   30 m from the listener** (`sub_824F8EF8`: |entry+240 − *(0x830CFDD4)| < `0x820D4924` = 30.0;
//!   the listener point is the camera). A skater that already holds a record (matched by its id,
//!   entry+152 bits 16–19) keeps it; otherwise the manager's create (`sub_824F2238`) hands out the
//!   first inactive record, or nothing — only the local skater may evict one. So **one NPC skater
//!   at a time** gets the full player components (the first in list order within 30 m while the
//!   instance is free), and keeps them until it is 30 m or more away (`sub_824F8E18`, the record's
//!   update) or leaves the list.
//! - Every player SFX object of that instance runs with the record's skater: the audio-state bridge
//!   `sub_824B0DA8` reads the skater entry at the record's index (`+68`), so the components see the
//!   NPC's own physics. Their local tests (`[record+72]`) pick the non-local branches the components
//!   already port (`AudioState::local` = false): no SenseOfSpeed wind / rattle (`sub_824E7980`), one
//!   routing pass and no held layers in the SkateBoard routing, no landing-material flag, the
//!   collision messages' local byte clear, buses not created by it. Class_Seams gates on the
//!   record's active byte only (`+52`), so it runs for an NPC too.
//! - The soft-wheel word every component posts goes through `sub_824B23C8`: the local player's own
//!   `+684`; for a non-local skater it walks the Player records for the local one and returns 1
//!   when that record's `+84` is 0 — `+84` is the local player's `+684` (the bridge stores both) —
//!   so an NPC board plays the soft-wheel samples exactly when the local player's wheels are hard.
//!   The recomp agrees: the soft grain members (`asphalt_smooth_soft`, `concrete_smooth_soft`, …)
//!   play around the second instance's contacts although the user's board is hard.
//! - PlayerPhysics in9 = 32767 (not the local player) and in13 = |the skater's COM velocity − the
//!   local player's|, clamped to 35 and slewed by 100 /s (vault class `0xC1831BDB6CB1B1EA`), × 32767
//!   / 35 ([`crate::player::inputs::Physics::write_against`]).
//!
//! **Here:** [`Slots`] is that assignment; [`NpcSkater`] runs the same component code as the local
//! player's host (`skate-game` `player_audio.rs`) for instance `g` ≥ 1, writing the instance's MixMap
//! inputs and returning [`Command`]s and Splice starts for the host to apply. The collision messages
//! go to the host's (shared) collision manager, like the local player's.
//!
//! What runs for the NPC instance besides the board (recomp gap run G3, hook `PLAYERPOST`,
//! `gapg3_20261003_154858`: 851 lines, local72 = 0 on every instance-1 line):
//! - **SFXObj_Wheels** (key `…820`): the spin-down streams on layers 0 (air) / 1 (balance); 18
//!   starts in ~74 s held. Layer 2 (on foot) and the owner-bus send written after a start are
//!   local only (`[[obj+16]+72]`), which [`crate::player::wheels`] already follows (`s.local`;
//!   the send is not modelled for anyone). [`NpcSkater::update_wheels`].
//! - **Clothing** (key `…860`): the push / plant foley and the body slide / cloth falls posts;
//!   its non-local start block (float `+112` = 0, the eq-chain create flag = local72) is
//!   [`crate::player::clothing`]'s own `s.local` branch.
//! - **Not** Tricks or Treatment (their process functions return at once when local72 = 0: 0 NPC
//!   posts) and **no** footsteps (OffBoard's packets exist per claim, its step sounds need
//!   local72: 0 NPC Splice starts).
//! - **The bail grunt**: the body poster's first message of a bail calls `sub_824BF5F8`, which
//!   for a non-local skater sends its SkaterSpeech record message 8206 (event `201_grunt`) / 115
//!   ([`NpcSkater::take_bail_grunt`]; the speech host plays it).
//! - **Board slide** (slot 15, `c_board_slide`): SkateBoard's process `sub_824C6A78` calls
//!   `sub_824CB3C8` and its update `sub_824CB4C0` for every instance with no local test; the
//!   loose-board state they read (`+780`) is computed per skater entry by the conditioner
//!   (`sub_827A1B78`, the per-skater loop) and copied by the instance bridge `sub_824B0DA8`, so an
//!   NPC whose board lies loose (bail / on foot, deck contact, upside down or on its side) holds it
//!   too ([`NpcSkaterAudioState::loose_board`]).
//!
//! The granular rolling bed's binds are collected in [`NpcSkater::routed`] for the host's NPC bed.
use crate::mixmap::{MixMap, keys};
use crate::player::collision::Message;
use crate::player::components::{Command, FootDrag, Grind, SenseOfSpeed, Skid, Slot, Squeaks};
use crate::player::contacts::{self, ContactsTuning, SpliceHost};
use crate::player::inputs::{self, Physics};
use crate::player::objpos::{Listener, ObjPos};
use crate::player::rolling::{BoardSlide, Rattle, Rolling, RollingInputs, Routed};
use crate::player::seams::{self, SeamCommand, Seams};
use crate::player::clothing::{Clothing, ClothingTuning};
use crate::player::tuning::PlayerTuning;
use crate::player::wheels::{StreamHost, Wheels, WheelsTuning};
use crate::player::{AudioState, Owner};

pub use crate::player::rolling::GrainEvent;
pub use super::owners::Assignment;

/// Player-slot instances in free skate (`mixmap::RETAIL_INSTANCES[1]`; `CSTATEMGR_Player` makes
/// two records). Instance 0 is the local player's.
pub const PLAYER_INSTANCES: usize = 2;
/// An NPC skater gets a Player instance while its position is less than this far from the
/// listener (m; `sub_824F8EF8`, image `0x820D4924`).
pub const AUDIO_RADIUS: f32 = 30.0;

/// What an AI-skater system publishes per skater and frame (the bridge fields of retail's skater
/// entry): its id (stable while it lives) and its audio state, filled exactly as the local
/// player's (`skate_events::audio_state` in the game). `state.local` is ignored (always false
/// here) and so is `state.soft_wheels` (the soft word is the local player's, see the module docs);
/// `audio_trick` / `audio_trick_2` are the resolved eSk8AudioTricks ids (−1 none).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NpcSkaterAudioState {
    pub id: u64,
    pub state: AudioState,
    /// The skater's speech voice (its `aud_characteristics` model: the AI skaters' 89–96; 0 = none):
    /// the bail grunt's speaker.
    pub voice: u32,
    /// The conditioner's loose-board state (`+780`: 0 none, 1 upside down, 2 on its side;
    /// [`crate::player::rolling::loose_board`]): the board slide holds while it is set.
    pub loose_board: u32,
    /// The skater record's reaction bytes this frame ([`super::skater_speech`]: its own speech).
    pub reactions: super::skater_speech::Reactions,
}

/// `sub_824B23C8` for a non-local skater: 1 when the local player's record `+84` (= its `+684`,
/// soft wheels) is 0.
pub fn non_local_soft(local_soft_wheels: bool) -> bool {
    !local_soft_wheels
}

/// The audio state the components see for an NPC skater.
pub fn component_state(published: &AudioState, local_soft_wheels: bool) -> AudioState {
    let mut s = *published;
    s.local = false;
    s.soft_wheels = non_local_soft(local_soft_wheels);
    s
}

/// `CSTATEMGR_Player`'s records for NPC skaters: instance `1 + i` is held by `holders[i]`.
#[derive(Clone, Debug)]
pub struct Slots {
    holders: Vec<Option<u64>>,
}

impl Default for Slots {
    fn default() -> Self {
        Self { holders: vec![None; PLAYER_INSTANCES - 1] }
    }
}

impl Slots {
    /// `records` NPC records (instances 1..=records): retail has 1 (`PLAYER_INSTANCES` − 1); the
    /// game's opt-in non-retail "more audible" layout builds the MixMap with more.
    pub fn with_records(records: usize) -> Self {
        Self { holders: vec![None; records] }
    }

    /// How many NPC records there are.
    pub fn records(&self) -> usize {
        self.holders.len()
    }

    /// The instance an NPC skater holds.
    pub fn instance(&self, id: u64) -> Option<u32> {
        self.holders.iter().position(|h| *h == Some(id)).map(|i| i as u32 + 1)
    }

    /// (instance, skater) pairs held.
    pub fn holders(&self) -> impl Iterator<Item = (u32, u64)> + '_ {
        self.holders.iter().enumerate().filter_map(|(i, h)| h.map(|id| (i as u32 + 1, id)))
    }

    /// One manager update. `skaters`: every NPC skater in the skater list's order with its
    /// distance to the listener (the camera). First the records' own update releases a holder
    /// that left the list or is 30 m or more away (NaN included); then, in list order, a skater
    /// closer than 30 m without a record takes the first free one.
    pub fn assign(&mut self, skaters: &[(u64, f32)]) -> Assignment {
        let mut out = Assignment::default();
        for (i, h) in self.holders.iter_mut().enumerate() {
            let Some(id) = *h else { continue };
            let near = skaters.iter().find(|s| s.0 == id).is_some_and(|s| s.1 < AUDIO_RADIUS);
            if !near {
                out.released.push((id, i + 1));
                *h = None;
            }
        }
        for &(id, d) in skaters {
            if !(d < AUDIO_RADIUS) || self.instance(id).is_some() {
                continue;
            }
            let Some(i) = self.holders.iter().position(Option::is_none) else { break };
            self.holders[i] = Some(id);
            out.claimed.push((id, i + 1));
        }
        out
    }

    /// Release every record (map change).
    pub fn clear(&mut self) -> Vec<(u64, usize)> {
        let out = self.holders().map(|(g, id)| (id, g as usize)).collect();
        self.holders.iter_mut().for_each(|h| *h = None);
        out
    }
}

/// Which components run (the host turns on what the install's banks allow, like the local
/// player's host).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Parts {
    /// SkateBoard's surface routing, its Class_rolling patches (`PatchBank_Rolling_Surfaces`).
    pub rolling: bool,
    /// The rattle (`Rolling_Rattles`).
    pub rattle: bool,
    /// The loose board's slide (`board_scrapes`).
    pub slide: bool,
    /// SFXObj_Contacts' Splice one-shots (`Skate_Collisions`) and the grind on / off sounds.
    pub contacts: bool,
    /// SFXObj_Wheels' spin-down streams (the install's two recordings).
    pub wheels: bool,
    /// The Clothing component (`sk8_foley` push / plant foley, body slide, cloth falls).
    pub clothing: bool,
}

/// The tuning the components read (the local player's: the same vault records).
#[derive(Clone, Copy)]
pub struct Tuning<'a> {
    pub player: &'a PlayerTuning,
    pub contacts: &'a ContactsTuning,
    pub wheels: &'a WheelsTuning,
    pub clothing: &'a ClothingTuning,
}

/// One NPC skater's Player-slot instance: the same component objects as the local player's host,
/// keyed to instance [`NpcSkater::instance`].
pub struct NpcSkater {
    pub instance: u32,
    pub parts: Parts,
    physics: Physics,
    contacts_in: inputs::Contacts,
    positions: [ObjPos; 2],
    was_grinding: bool,
    grind: Grind,
    speed: SenseOfSpeed,
    foot_drag: FootDrag,
    skid: Skid,
    squeaks: Squeaks,
    seams: Seams,
    rolling: Rolling,
    rattle: Rattle,
    slide: BoardSlide,
    /// The loose-board state of this pass (the host sets it before [`Self::process`]).
    pub loose_board: u32,
    board: contacts::Contacts,
    wheels: Wheels,
    clothing: Clothing,
    /// The routing's grain binds / stops since the host last took them (for a per-owner bed).
    pub routed: Routed,
    /// Packets posted and Splice sounds started (diagnostics).
    pub posts: u64,
}

impl NpcSkater {
    /// `grind_onoff` / `plant_lift` / `body`: the session-review fixes (doc 11), as the local player's
    /// host sets them (always on in the game; off only in tests).
    pub fn new(instance: u32, parts: Parts, grind_onoff: bool, plant_lift: bool, body: bool) -> Self {
        let mut grind = Grind::default();
        grind.onoff = grind_onoff;
        let mut board = contacts::Contacts::default();
        board.plant_lift_on = plant_lift;
        board.body_on = body;
        let mut seams = Seams::default();
        seams.instance = instance;
        let mut physics = Physics::default();
        physics.instance = instance;
        let mut contacts_in = inputs::Contacts::default();
        contacts_in.instance = instance;
        Self {
            instance,
            parts,
            physics,
            contacts_in,
            positions: [ObjPos::default(); 2],
            was_grinding: false,
            grind,
            speed: SenseOfSpeed::default(),
            foot_drag: FootDrag::default(),
            skid: Skid::default(),
            squeaks: Squeaks::default(),
            seams,
            rolling: Rolling::default(),
            rattle: Rattle::default(),
            slide: BoardSlide::default(),
            loose_board: 0,
            board,
            wheels: Wheels::default(),
            clothing: Clothing::default(),
            routed: Routed::default(),
            posts: 0,
        }
    }

    /// Step 1 (before the tick): the instance's inputs — PlayerPhysics (against the local player's
    /// COM velocity), the two 3DObjPos blocks (COM, board), Contacts, Rail, OffBoard. `s` is the
    /// [`component_state`]. Returns whether the board landed this frame.
    pub fn write_inputs(&mut self, m: &mut MixMap, s: &AudioState, l: &Listener, local_com_velocity: [f32; 3], t: &PlayerTuning) -> bool {
        let g = self.instance;
        self.physics.write_against(m, s, local_com_velocity);
        self.positions[0].write(m, keys::obj_pos(g), l, Some((s.com_position, s.com_velocity)));
        self.positions[1].write(m, keys::obj_pos2(g), l, Some((s.board_position, s.board_velocity)));
        let landed = self.contacts_in.write(m, s, t);
        inputs::write_rail_at(m, g, s.grinding, self.was_grinding);
        self.was_grinding = s.grinding;
        inputs::write_off_board_at(m, g, s);
        landed
    }

    fn seam_commands(cmds: Vec<SeamCommand>) -> Vec<Command> {
        cmds.into_iter()
            .map(|c| match c {
                SeamCommand::Post { wheel, words } => Command::Post { slot: Slot::Seam(wheel as u8), class: seams::CLASS, words },
                SeamCommand::Redeliver { wheel, words } | SeamCommand::RedeliverAt { wheel, words, .. } => {
                    Command::Redeliver { slot: Slot::Seam(wheel as u8), words }
                }
            })
            .collect()
    }

    /// Step 2 (before the tick): the components' process, in the local player's host order. Class
    /// Seams runs its whole process here, once per call: the host calls this once per console
    /// MixMap evaluation (30 Hz), retail's per-rendered-frame cadence on the console.
    pub fn process(&mut self, m: &mut MixMap, s: &AudioState, t: Tuning<'_>, splice: &mut dyn SpliceHost) -> Vec<Command> {
        let g = self.instance;
        let mut cmds = Vec::new();
        if self.parts.rolling {
            let (c, routed) = self.rolling.process(s, t.player, &RollingInputs { speed_scale: None });
            cmds.extend(c);
            m.set_input(keys::skateboard(g), 0, if routed.surface_pulse { 32767 } else { 0 });
            m.set_input(keys::skateboard(g), 6, if routed.on_metal { 32767 } else { 0 });
            self.routed.grains.extend(routed.grains);
            self.routed.primary = routed.primary;
            self.routed.surface_pulse = routed.surface_pulse;
            self.routed.on_metal = routed.on_metal;
        }
        if self.parts.rattle {
            cmds.extend(self.rattle.process(s, &self.rolling, &t.player.rolling));
        }
        // SkateBoard's process: the routing, the rattle, then the board slide (as the local's).
        if self.parts.slide {
            cmds.extend(self.slide.process(self.loose_board, &t.player.rolling));
        }
        let seam_cmds = Self::seam_commands(self.seams.process(s, t.player, m));
        let m: &MixMap = m;
        let mut c = self.grind.process(s, t.player, &Owner { mixmap: m, key: keys::rail(g) });
        c.extend(self.speed.process(s));
        c.extend(self.foot_drag.process(s, t.player));
        c.extend(self.skid.process(s, t.player, &Owner { mixmap: m, key: keys::skateboard(g) }));
        c.extend(self.squeaks.process(s));
        c.extend(seam_cmds);
        c.extend(cmds);
        if self.parts.contacts {
            self.grind.sounds(s, t.player, splice);
            let before = self.board.starts;
            self.board.process(s, self.contacts_in.buckets(), t.player, t.contacts, splice);
            self.posts += self.board.starts - before;
        }
        if self.parts.clothing {
            let before = self.clothing.starts;
            c.extend(self.clothing.process(s, t.player, t.clothing, splice));
            self.posts += self.clothing.starts - before;
        }
        self.posts += c.iter().filter(|c| matches!(c, Command::Post { .. })).count() as u64;
        c
    }

    /// The body poster's console cadence for the next [`Self::process`] (`Contacts::body_calls`:
    /// `Some(n)` = n console frames end there; `None` = once per call).
    pub fn set_body_calls(&mut self, calls: Option<usize>) {
        self.board.body_calls = calls;
    }

    /// The deck poster's console cadence for the next [`Self::process`] (`Contacts::deck_calls`).
    pub fn set_deck_calls(&mut self, calls: Option<usize>) {
        self.board.deck_calls = calls;
    }

    /// The collision messages this skater's contacts posted (hand them to the collision manager
    /// before its process, like the local player's).
    pub fn take_collisions(&mut self) -> Vec<Message> {
        std::mem::take(&mut self.board.outbox)
    }

    /// Step 3 (after the tick): the components' update.
    pub fn update(&mut self, m: &MixMap, s: &AudioState, t: Tuning<'_>, splice: &mut dyn SpliceHost) -> Vec<Command> {
        let g = self.instance;
        let rail = Owner { mixmap: m, key: keys::rail(g) };
        let board = Owner { mixmap: m, key: keys::skateboard(g) };
        let contacts = Owner { mixmap: m, key: keys::contacts(g) };
        let mut c = self.grind.update(s, t.player, &rail);
        c.extend(self.speed.update(s, &Owner { mixmap: m, key: keys::sense_of_speed(g) }));
        c.extend(self.foot_drag.update(s, t.player, &contacts));
        c.extend(self.skid.update(s, t.player, &board));
        c.extend(self.squeaks.update(s, &board));
        c.extend(Self::seam_commands(self.seams.update(s, &Owner { mixmap: m, key: keys::cracks(g) })));
        if self.parts.rolling {
            c.extend(self.rolling.update(s, t.player, &RollingInputs { speed_scale: None }, &board));
        }
        if self.parts.rattle {
            c.extend(self.rattle.update(&board));
        }
        if self.parts.slide {
            c.extend(self.slide.update(s, self.loose_board, &t.player.rolling, &board));
        }
        if self.parts.contacts {
            self.grind.sounds(s, t.player, splice);
            self.grind.update_sounds(s, &rail, splice);
            self.board.update(s, &contacts, t.contacts, splice);
        }
        if self.parts.clothing {
            let cloth = Owner { mixmap: m, key: keys::clothing(g) };
            c.extend(self.clothing.update(s, t.player, t.clothing, &cloth, splice));
        }
        c
    }

    /// Step 3b (after the tick, after [`Self::update`]): SFXObj_Wheels' spin-down streams on this
    /// instance's Wheels outputs (layers 0 / 1; layer 2 is the local player's).
    pub fn update_wheels(&mut self, m: &MixMap, s: &AudioState, t: &WheelsTuning, streams: &mut dyn StreamHost) {
        if !self.parts.wheels {
            return;
        }
        let owner = Owner { mixmap: m, key: keys::wheels(self.instance) };
        let before = self.wheels.starts;
        self.wheels.update(s, &owner, t, streams);
        self.posts += self.wheels.starts - before;
    }

    /// Spin-down streams and Clothing Splice starts so far (diagnostics, checks against G3).
    pub fn component_starts(&self) -> (u64, u64) {
        (self.wheels.starts, self.clothing.starts)
    }

    /// The bail grunt is due (`sub_824BF5F8`, once per bail): the host requests event 8206
    /// (`201_grunt`) for the skater's voice.
    pub fn take_bail_grunt(&mut self) -> bool {
        std::mem::take(&mut self.board.bail_grunt)
    }

    /// Stop the wheel streams (the skater lost its instance: retail's release stops every layer).
    pub fn stop_wheels(&mut self, streams: &mut dyn StreamHost) {
        let s = AudioState { local: false, ..Default::default() };
        self.wheels.update(&s, &Flat, &WheelsTuning::default(), streams);
    }

    /// The skater lost its instance: deactivate the 3-D blocks (every B lookup of the slot then
    /// reads "no position"). The host releases the packets it holds for the skater; the Splice
    /// one-shots end by themselves.
    pub fn deactivate(&mut self, m: &mut MixMap, l: &Listener) {
        let g = self.instance;
        self.positions[0].write(m, keys::obj_pos(g), l, None);
        self.positions[1].write(m, keys::obj_pos2(g), l, None);
    }
}

/// Zero outputs (releasing the wheel streams: no trigger holds).
struct Flat;

impl crate::player::Outputs for Flat {
    fn level(&self, _: usize) -> i32 {
        0
    }
    fn raw(&self, _: usize) -> i32 {
        0
    }
    fn pitch(&self, _: usize) -> i32 {
        4096
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_npc_within_30_m_holds_the_second_instance_until_it_leaves() {
        let mut s = Slots::default();
        // Out of range: nothing.
        let a = s.assign(&[(1, 40.0), (2, 30.0)]);
        assert!(a.claimed.is_empty() && a.released.is_empty());
        // 2 comes inside 30 m first; then 1 too, but the instance is taken (no eviction).
        assert_eq!(s.assign(&[(1, 40.0), (2, 29.9)]).claimed, vec![(2, 1)]);
        let a = s.assign(&[(1, 5.0), (2, 29.0)]);
        assert!(a.claimed.is_empty() && a.released.is_empty());
        assert_eq!(s.instance(2), Some(1));
        // 2 reaches 30 m: released, and 1 (in range) takes the instance in the same update.
        let a = s.assign(&[(1, 5.0), (2, 30.0)]);
        assert_eq!((a.released, a.claimed), (vec![(2, 1)], vec![(1, 1)]));
        // List order decides among newcomers; NaN never claims and releases a holder.
        let mut s = Slots::default();
        assert_eq!(s.assign(&[(9, 20.0), (3, 1.0)]).claimed, vec![(9, 1)]);
        assert_eq!(s.assign(&[(9, f32::NAN), (3, 1.0)]).released, vec![(9, 1)]);
        // Leaving the list releases.
        let mut s = Slots::default();
        s.assign(&[(4, 1.0)]);
        assert_eq!(s.assign(&[]).released, vec![(4, 1)]);
        assert_eq!(s.clear(), vec![]);
    }

    #[test]
    fn the_npc_state_is_non_local_with_the_inverse_of_the_local_soft_word() {
        let p = AudioState { soft_wheels: true, ..Default::default() };
        let s = component_state(&p, false);
        assert!(!s.local && s.soft_wheels);
        assert!(!component_state(&p, true).soft_wheels);
    }

    #[test]
    #[ignore = "needs the private install data"]
    fn npc_physics_in13_slews_toward_the_relative_speed() {
        let bytes = match std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../../assets/private/audio/aems/MixMapSK8.mxb")) {
            Ok(b) => b,
            Err(_) => panic!("missing private data: no MixMap"),
        };
        let mut m = MixMap::from_bytes(&bytes).unwrap();
        let mut npc = NpcSkater::new(1, Parts::default(), false, false, false);
        let l = Listener { view: [0.0, 0.0, -1.0], ..Default::default() };
        let t = PlayerTuning::default();
        let s = component_state(&AudioState { dt: 0.1, com_velocity: [20.0, 0.0, 0.0], ..Default::default() }, false);
        // 20 m/s against a still local player; 100/s × 0.1 s = 10 per call.
        npc.write_inputs(&mut m, &s, &l, [0.0; 3], &t);
        let key = keys::player_physics(1);
        assert_eq!((m.input(key, 13), m.input(key, 9)), (((10.0f32 / 35.0) * 32767.0) as i32, 32767));
        npc.write_inputs(&mut m, &s, &l, [0.0; 3], &t);
        assert_eq!(m.input(key, 13), ((20.0f32 / 35.0) * 32767.0) as i32);
        // Capped at 35.
        let fast = AudioState { com_velocity: [80.0, 0.0, 0.0], ..s };
        for _ in 0..3 {
            npc.write_inputs(&mut m, &fast, &l, [0.0; 3], &t);
        }
        assert_eq!(m.input(key, 13), 32767);
        // The local player's own block is untouched.
        assert_eq!(m.input(keys::player_physics(0), 9), 0);
        assert!(m.input(keys::obj_pos(1), 15) & 1 == 1, "the NPC's 3-D block is active");
        npc.deactivate(&mut m, &l);
        assert_eq!(m.input(keys::obj_pos(1), 15) & 1, 0);
    }
}
