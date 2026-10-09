// gm_sk8: ported whole from SK8-ENGINE/skate-3-rust-engine (Skate 3's own
// score accounting there is far closer), plus the read-only view below.
//! ScoreModule integration. The simulation owns recognition and accounting;
//! the APT movie only consumes the resulting publication.
use skate_core::{
    animation::output::attributes::AttributeName,
    physics::filtered_state::FilteredCategory,
    scoring::{
        carrier::{Carrier, delay_ticks},
        conversions::LINKS,
        session::Session,
    },
};
use skate_data::{collections::Collections, scoring::ScoringData};

#[path = "scoring_runtime/display.rs"]
mod display;
#[path = "scoring_runtime/rotation.rs"]
mod rotation;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Collector {
    None,
    Ground,
    Air,
    Grind,
    Offboard,
    Special,
}
pub(crate) struct Frame {
    pub tick: u32,
    pub dt: f32,
    pub category: FilteredCategory,
    pub state: u32,
    pub descriptor: Option<AttributeName>,
    pub grind_id: i32,
    pub flags: u32,
    pub position: [f32; 3],
    pub velocity: [f32; 3],
    pub forward: [f32; 3],
    pub switch: bool,
    pub fakie: bool,
    pub regular: bool,
    pub player_basis: rotation::Basis,
    pub board_basis: rotation::Basis,
    pub reckoning_up: [f32; 3],
    pub body_flip: bool,
    pub front_flip: bool,
    pub suspend_air: bool,
    pub landing: skate_core::animation::landing_quality::Output,
    pub teleported: bool,
    pub reverting: bool,
}
pub(crate) struct Runtime {
    pub data: ScoringData,
    pub session: Session,
    collector: Collector,
    carriers: [Option<Carrier>; 4],
    held: [f32; 4],
    distance: [f32; 4],
    metric_rewards: [f32; 4],
    metric_started: [bool; 4],
    start: [f32; 3],
    previous: [f32; 3],
    rotation: rotation::Rotation,
    spin_turns: i32,
    body_flip_count: i32,
    display_id: Option<usize>,
    air_stance: [bool; 2],
    air_display_started: bool,
    line_hold_ticks: u32,
    spin: f32,
    peak: f32,
    air_factor: f32,
    air_repetition: f32,
    air_repetition_set: bool,
    grab_chain: u32,
    air_metrics: [f32; 5],
    landing_countdown: u32,
    idle_ticks: u32,
    collector_ticks: u32,
    manual_revert_ticks: u32,
    revert_id: Option<usize>,
    sequence_active: bool,
    sequence_score: f32,
    trick_name: String,
    /// gm_sk8 addition: how many tricks have been named (announced or
    /// converted), so a host sees a new one even when it repeats the last name
    tricks_named: u32,
    display_base: String,
    display_spin_degrees: i32,
    trick_seq: u32,
    pub(crate) landing_seq: u32,
    pub(crate) landed_trick: String,
    pub(crate) landed_base: String,
    pub(crate) landed_spin_degrees: i32,
    pub(crate) landed_clean: bool,
    pub(crate) landed_sketchy: bool,
    pub(crate) bail_seq: u32,
    settled_trick_seq: u32,
    was_bailing: bool,
    /// gm_sk8: came off the board before the sequence settled (lost, as a bail)
    ran_out: bool,
    stance: [bool; 4],
    clean: bool,
    sketchy: bool,
    pub new_trick: bool,
    pub modified_trick: bool,
    pub close_tricks: bool,
}
/// gm_sk8: how long a landing must hold (ms) before its sequence is banked.
pub static LANDING_SETTLE_MS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(250);

/// What the trick display shows (gm_sk8 addition: read-only), computed as
/// SK8-ENGINE's `scoring_runtime::Runtime::hud_input` does.
#[derive(Clone, Debug, Default)]
pub struct ScoreView {
    /// the current trick sequence, multiplier applied
    pub sequence_score: f32,
    /// points banked in the current line
    pub line_score: f32,
    /// all completed lines this session
    pub total_score: f32,
    /// seconds left on the line timer, and the timer's capacity in seconds
    pub line_time: f32,
    pub line_capacity: f32,
    pub multiplier: f32,
    pub clean: bool,
    pub sketchy: bool,
    /// switch, fakie, nollie, body-flip flags as the HUD receives them
    pub stance: [bool; 4],
    pub trick_name: String,
    /// gm_sk8 addition: see Runtime::tricks_named
    pub tricks_named: u32,
    /// for Skate 3's own trick display: the line timer in whole seconds, the
    /// line capacity as the HUD reads it, and this tick's display events
    pub sequence_timer: i32,
    pub hud_line_capacity: f32,
    pub new_trick: bool,
    pub modified_trick: bool,
    pub close_tricks: bool,
}

impl Runtime {
    pub fn view(&self) -> ScoreView {
        let drain = if self.data.line_drain != 0.0 { self.data.line_drain } else { 1.0 };
        ScoreView {
            sequence_score: self.sequence_score,
            line_score: self.session.holder.snapshot.line,
            total_score: self.session.holder.snapshot.completed_lines,
            line_time: self.session.line.points / drain,
            line_capacity: self.data.line_capacity / drain,
            multiplier: self.session.combo.multiplier,
            clean: self.clean,
            sketchy: self.sketchy,
            stance: self.stance,
            trick_name: self.trick_name.clone(),
            tricks_named: self.tricks_named,
            sequence_timer: (self.session.line.points / drain) as i32,
            hud_line_capacity: self.data.line_capacity,
            new_trick: self.new_trick,
            modified_trick: self.modified_trick,
            close_tricks: self.close_tricks,
        }
    }
}
impl Runtime {
    pub fn load(data: &Collections) -> Result<Self, String> {
        Ok(Self {
            data: ScoringData::load(data)?,
            session: Session::default(),
            collector: Collector::None,
            carriers: std::array::from_fn(|_| None),
            held: [0.; 4],
            distance: [0.; 4],
            metric_rewards: [0.; 4],
            metric_started: [false; 4],
            start: [0.; 3],
            previous: [0.; 3],
            rotation: Default::default(),
            spin_turns: 0,
            body_flip_count: 0,
            display_id: None,
            air_stance: [false; 2],
            air_display_started: false,
            line_hold_ticks: 0,
            spin: 0.,
            peak: 0.,
            air_factor: 1.,
            air_repetition: 1.,
            air_repetition_set: false,
            grab_chain: 0,
            air_metrics: [0.; 5],
            landing_countdown: 0,
            idle_ticks: 0,
            collector_ticks: 0,
            manual_revert_ticks: 0,
            revert_id: None,
            sequence_active: false,
            sequence_score: 0.,
            trick_name: String::new(),
            tricks_named: 0,
            display_base: String::new(), display_spin_degrees: 0,
            trick_seq: 0,
            landing_seq: 0,
            landed_trick: String::new(),
            landed_base: String::new(), landed_spin_degrees: 0,
            landed_clean: false, landed_sketchy: false,
            bail_seq: 0,
            settled_trick_seq: 0,
            was_bailing: false,
            ran_out: false,
            stance: [false; 4],
            clean: false,
            sketchy: false,
            new_trick: false,
            modified_trick: false,
            close_tricks: false,
        })
    }
    pub(crate) fn trick_name(&self) -> &str {
        &self.trick_name
    }
    pub(crate) fn trick_seq(&self) -> u32 {
        self.trick_seq
    }
    pub(crate) fn sequence_score(&self) -> f32 {
        self.sequence_score
    }
    pub(crate) fn sequence_active(&self) -> bool {
        self.sequence_active
    }
    pub(crate) fn line_score(&self) -> f32 {
        self.session.holder.snapshot.line
    }
    pub(crate) fn multiplier(&self) -> f32 {
        self.session.combo.multiplier
    }
    pub(crate) fn line_time(&self) -> f32 {
        let drain = self.data.line_drain.max(1e-4);
        self.session.line.points / drain
    }
    pub(crate) fn clean(&self) -> bool {
        self.clean
    }
    pub(crate) fn sketchy(&self) -> bool {
        self.sketchy
    }
    pub(crate) fn stance(&self) -> [bool; 4] {
        self.stance
    }
    fn penalty(&self, id: usize) -> f32 {
        let Some(d) = self.data.by_id(id) else {
            return 1.;
        };
        if d.metadata.repetition_applies() {
            self.data.repetition.evaluate(
                self.session
                    .holder
                    .repetition_count(d.metadata)
                    .unwrap_or(0) as f32,
            )
        } else {
            1.
        }
    }
    fn finish(&mut self, slot: usize, complete: bool, keep_metric: bool) {
        if let Some(mut carrier) = self.carriers[slot].take() {
            if complete {
                carrier.complete(self.data.unannounced_factor);
                if self.collector == Collector::Air {
                    self.session
                        .holder
                        .end_trick(carrier.scorable, carrier.reward);
                } else {
                    let metric = self.collector == Collector::Grind
                        || self.collector == Collector::Ground && slot < 3;
                    if !(keep_metric && self.collector == Collector::Ground) {
                        let reward = if keep_metric {
                            0.
                        } else if metric {
                            if carrier.scorable.score_type == 9 {
                                carrier.reward.max(self.metric_rewards[slot])
                            } else {
                                self.metric_rewards[slot].max(0.)
                            }
                        } else {
                            carrier.reward
                        };
                        self.session.holder.credit_trick(carrier.scorable, reward);
                    }
                }
            }
        }
        if !keep_metric {
            self.metric_started[slot] = false;
            self.held[slot] = 0.;
            self.distance[slot] = 0.;
            self.metric_rewards[slot] = 0.;
        }
    }
    fn carrier(&mut self, slot: usize, id: Option<usize>, f: &Frame) -> Result<(), String> {
        if self.carriers[slot].as_ref().map(|c| c.scorable.id) != id {
            let conversion = id.filter(|new| {
                self.collector == Collector::Air
                    && self.carriers[slot].is_some()
                    && LINKS[*new].1 >= 0
            });
            let chained_grab = self.collector == Collector::Air
                && id
                    .and_then(|id| self.data.by_id(id))
                    .is_some_and(|d| d.metadata.class == 2)
                && self.carriers[slot]
                    .as_ref()
                    .is_some_and(|c| c.scorable.class == 2 && !c.announced);
            let previous_tick = self.carriers[slot].as_ref().map(|c| c.start_tick);
            let keep_metric = id.is_some()
                && (self.collector == Collector::Grind
                    || self.collector == Collector::Ground && slot == 0);
            if conversion.is_none() {
                if chained_grab {
                    self.carriers[slot] = None;
                    self.grab_chain += 1;
                } else {
                    self.finish(slot, true, keep_metric);
                    self.grab_chain = 0;
                }
            }
            if let Some(id) = id {
                let d = self
                    .data
                    .by_id(id)
                    .ok_or_else(|| format!("Missing native scorable {id}"))?;
                let factor = self.penalty(id)
                    * if self.collector == Collector::Air {
                        self.air_factor
                    } else {
                        1.
                    };
                let mut carrier = Carrier::new(
                    d.metadata,
                    d.points,
                    factor,
                    self.data.announcement.evaluate(d.points as f32),
                    if chained_grab {
                        previous_tick.unwrap_or(f.tick)
                    } else {
                        f.tick
                    },
                    delay_ticks(
                        d.completion_delay,
                        if self.grab_chain > 1 {
                            self.data.collector.scalar(0x698)
                        } else {
                            0.
                        },
                    ),
                    f.switch,
                    f.fakie,
                );
                if let Some(old) = self.carriers[slot].as_mut() {
                    old.convert_to(&mut carrier, self.data.unannounced_factor);
                    self.modified_trick = true;
                }
                if conversion.is_some() {
                    self.display_id = Some(id);
                    self.trick_name = d.label.clone();
                    self.tricks_named = self.tricks_named.wrapping_add(1);
                }
                self.carriers[slot] = Some(carrier);
                self.sequence_active = true;
                self.idle_ticks = 0;
            }
        }
        let penalty = self.carriers[slot]
            .as_ref()
            .map(|c| self.penalty(c.scorable.id))
            .unwrap_or(1.);
        if let Some(c) = self.carriers[slot].as_mut() {
            if c.announce(f.tick, self.data.unannounced_factor) {
                let d = self
                    .data
                    .by_id(c.scorable.id)
                    .ok_or("Missing announced scorable")?;
                self.trick_name = d.label.clone();
                self.tricks_named = self.tricks_named.wrapping_add(1);
                self.display_id = Some(c.scorable.id);
                if self.collector == Collector::Air {
                    self.air_display_started = true;
                }
                self.stance = [f.switch, f.fakie, true, display::nollie(d)];
                self.new_trick = true;
                self.trick_seq = self.trick_seq.saturating_add(1);
                if self.collector == Collector::Air && !self.air_repetition_set {
                    self.air_repetition = penalty;
                    self.air_repetition_set = true;
                }
            }
            let distance_metric = self.collector == Collector::Grind
                || self.collector == Collector::Ground && slot < 3;
            let was_active = self.metric_started[slot];
            self.metric_started[slot] = true;
            if c.announced && !(self.collector == Collector::Air && f.suspend_air) {
                // 82DB0588 starts a distance collector at time/distance zero.
                // Every active frame still updates its reference position.
                if !distance_metric || was_active {
                    self.held[slot] += f.dt;
                }
                let previous_distance = self.distance[slot];
                let displacement =
                    std::array::from_fn::<_, 3, _>(|i| f.position[i] - self.previous[i]);
                let delta = if self.collector == Collector::Ground && slot == 1 {
                    displacement
                        .iter()
                        .zip(f.forward)
                        .map(|(x, y)| x * y)
                        .sum::<f32>()
                } else {
                    (displacement.iter().map(|x| x * x).sum::<f32>()).sqrt()
                };
                if was_active && delta > f32::from_bits(0x3ba3d70a) {
                    self.distance[slot] += delta;
                }
                let curve = match self.collector {
                    Collector::Air if c.scorable.class == 2 => Some(0x460),
                    Collector::Offboard => Some(0x140),
                    // gm_sk8: a handplant (score type 6) held in state 600, as
                    // the offboard collector rewards score type 6
                    Collector::Special if c.scorable.score_type == 6 => Some(0x140),
                    _ => None,
                };
                if let Some(curve) = curve {
                    c.reward += (self.data.collector.curve(curve, self.held[slot]) * f.dt)
                        * c.announcement_threshold;
                }
                let curve = match (self.collector, c.scorable.score_type) {
                    (Collector::Ground, 9) => Some((0x000, 0x050)),
                    (Collector::Ground, 8) => Some((0x0f0, 0x0a0)),
                    (Collector::Ground, _) if slot == 2 => Some((0x230, 0x1e0)),
                    (Collector::Grind, _) => Some((0x2d0, 0x280)),
                    _ => None,
                };
                if let Some((distance, time)) = curve {
                    let delta = (self.data.collector.curve(distance, self.distance[slot])
                        - self.data.collector.curve(distance, previous_distance))
                    .max(0.);
                    self.metric_rewards[slot] = (self
                        .data
                        .collector
                        .curve(time, self.held[slot])
                        .mul_add(f.dt, delta))
                    .mul_add(c.announcement_threshold, self.metric_rewards[slot]);
                }
            }
        }
        Ok(())
    }
    pub fn advance(&mut self, f: Frame) -> Result<(), String> {
        let bailing = f.category == FilteredCategory::Wipeout;
        if bailing && !self.was_bailing {
            self.bail_seq = self.bail_seq.saturating_add(1);
        }
        self.was_bailing = bailing;
        self.new_trick = false;
        self.modified_trick = false;
        self.close_tricks = false;
        let descriptor = f
            .descriptor
            .and_then(|name| self.data.by_name(name))
            .filter(|d| !(f.flags & 0x02000000 != 0 && [67, 68, 69].contains(&d.metadata.id)))
            .map(|d| (d.metadata.id, d.metadata.class, d.metadata.score_type));
        let mut next = match f.category {
            FilteredCategory::Ground => Collector::Ground,
            FilteredCategory::Air => Collector::Air,
            FilteredCategory::Grind => Collector::Grind,
            FilteredCategory::Offboard | FilteredCategory::OffboardAir => Collector::Offboard,
            _ => Collector::None,
        };
        if f.state == 600 && matches!(next, Collector::Ground | Collector::Air) {
            next = Collector::Special;
        }
        if next == Collector::Air
            && self.collector == Collector::Ground
            && descriptor.is_some_and(|d| d.1 == 0)
        {
            next = Collector::Ground;
        }
        if next == Collector::Ground
            && self.collector == Collector::Air
            && descriptor.is_some_and(|d| d.1 == 3)
        {
            next = Collector::Air;
        }
        if f.teleported {
            next = Collector::None;
        }
        if next != self.collector {
            // gm_sk8: coming off the board while a sequence is still being
            // settled (a landing run out on foot) loses it, like a bail
            if next == Collector::Offboard && self.collector != Collector::Offboard && self.sequence_active {
                self.ran_out = true;
            }
            if self.collector == Collector::Air {
                bevy::log::info!(target: "scoring", "SCORING_AIR_REWARDS tick={} trick={:?} carrier={:?} spin_degrees={} body_flip={} metrics={:?} air_factor={} repetition={}", f.tick, self.trick_name,
                    self.carriers[0].as_ref().map(|c| (c.scorable.id, c.reward, c.announced)),
                    self.spin.to_degrees(), self.body_flip_count, self.air_metrics, self.air_factor, self.air_repetition);
                bevy::log::info!(target: "scoring", "SCORING_AIR_EXIT tick={} state={} preview={} multiplier={} line_points={} combo_points={} landing_valid={} landing_type={} switch={} fakie={}", f.tick, f.state, self.sequence_score, self.session.combo.multiplier, self.session.line.points, self.session.combo.timer.points, f.landing.landing_data_167, f.landing.landing_type_96, f.switch, f.fakie);
            }
            let complete = next != Collector::None;
            let previous_type = self
                .carriers
                .iter()
                .flatten()
                .last()
                .map(|c| c.scorable.score_type);
            for slot in 0..4 {
                self.finish(slot, complete, false);
            }
            if self.collector == Collector::Air {
                if complete {
                    for (i, reward) in self.air_metrics.into_iter().enumerate() {
                        // Skate 3 ExitAir82DA86B4..86F4 credits built-in metric
                        // IDs directly. These have enum metadata, but no VLT
                        // scorable record; descriptor lookup would discard them.
                        let id = 129 + i;
                        let (_, class, score_type) = skate_core::scoring::catalog::IDENTIFIERS[id];
                        self.session.holder.end_trick(
                            skate_core::scoring::Scorable { id, class, score_type },
                            reward,
                        );
                    }
                }
                self.session.holder.finish_collector();
                self.landing_countdown = 2;
            }
            self.collector = next;
            self.start = f.position;
            self.peak = f.position[1];
            self.spin = 0.;
            self.rotation.reset(f.player_basis, f.board_basis);
            self.spin_turns = 0;
            self.body_flip_count = 0;
            self.air_metrics = [0.; 5];
            self.air_repetition = 1.;
            self.air_repetition_set = false;
            self.air_factor = 1.;
            self.grab_chain = 0;
            self.collector_ticks = 0;
            self.manual_revert_ticks = 0;
            self.revert_id = None;
            if next == Collector::Air {
                self.air_stance = [f.switch, f.fakie];
                self.air_display_started = false;
                self.display_id = None;
                self.session.holder.reward_sequence(1.);
                self.landing_countdown = 0;
                if previous_type == Some(8) {
                    self.air_factor *= self.data.collector.scalar(0x68c);
                }
                if previous_type == Some(5) {
                    self.air_factor *= self.data.collector.scalar(0x690);
                }
                // 82DA81E4..823C measures velocity perpendicular to the
                // current reckoning up, not world-horizontal speed. A vertical
                // quarter-pipe launch must not receive the stationary penalty.
                let up_length_squared = f.reckoning_up.iter().map(|v| v * v).sum::<f32>();
                let up_speed = f.velocity.iter().zip(f.reckoning_up)
                    .map(|(v, up)| v * up).sum::<f32>() / up_length_squared;
                let riding_speed_squared = f.velocity.iter().zip(f.reckoning_up)
                    .map(|(v, up)| (v - up * up_speed).powi(2)).sum::<f32>();
                if riding_speed_squared < self.data.collector.scalar(0x66c).powi(2) {
                    self.air_factor *= self.data.collector.scalar(0x688);
                }
                if f.switch && !f.fakie {
                    self.air_factor *= self.data.collector.scalar(0x684);
                }
                if f.fakie && !f.switch {
                    self.air_factor *= self.data.collector.scalar(0x694);
                }
            }
        }
        let mut ids = [None; 4];
        if !(self.collector == Collector::Air && f.suspend_air) {
            self.collector_ticks = self.collector_ticks.saturating_add(1);
        }
        match self.collector {
            Collector::Ground => {
                ids[0] = if f.flags & 0x80000000 != 0 {
                    Some(0)
                } else if f.flags & 0x40000000 != 0 {
                    Some(1)
                } else {
                    None
                };
                ids[1] = if f.flags & 0x08000000 != 0 {
                    Some(2)
                } else if f.flags & 0x04000000 != 0 {
                    Some(3)
                } else {
                    None
                };
                if ids[1].is_some() && f.reverting {
                    self.manual_revert_ticks += 1;
                    ids[1] = None;
                } else {
                    self.manual_revert_ticks = 0;
                }
                if self.manual_revert_ticks > 6 {
                    ids[1] = None;
                }
                if ids[1].is_some() {
                    if let Some(c) = &self.carriers[1] {
                        ids[1] = Some(c.scorable.id);
                    }
                }
                ids[2] = descriptor
                    .filter(|d| d.0 == 60 && f.flags & 0x02000000 != 0)
                    .map(|d| d.0);
                if f.flags & 0x20000000 != 0 {
                    self.revert_id = Some(4);
                } else if f.flags & 0x10000000 != 0 {
                    self.revert_id = Some(5);
                }
                ids[3] = if f.reverting { self.revert_id } else { None };
            }
            Collector::Air => ids[0] = descriptor.filter(|d| d.2 != 5).map(|d| d.0),
            Collector::Grind => ids[0] = (f.grind_id >= 0).then_some(f.grind_id as usize),
            Collector::Offboard => ids[0] = descriptor.filter(|d| d.2 == 6).map(|d| d.0),
            // gm_sk8: state 600 is HandPlant here, so its handplants (scorables
            // 139-161, score type 6) are carried too; with only the hippy jump
            // (234) accepted, a handplant scored nothing
            Collector::Special => ids[0] = descriptor.filter(|d| d.0 == 234 || d.2 == 6).map(|d| d.0),
            Collector::None => {}
        }
        for (slot, id) in ids.into_iter().enumerate() {
            self.carrier(slot, id, &f)?;
        }
        if self.collector == Collector::Air && !f.suspend_air {
            if self.collector_ticks > 5 || f.flags & 0x01000000 != 0 {
                self.sequence_active = true;
            }
            self.spin = self.rotation.update(
                f.player_basis,
                f.board_basis,
                f.reckoning_up,
                self.carriers[0].is_some(),
            );
            self.peak = self.peak.max(f.position[1]);
            let dx = f.position[0] - self.start[0];
            let dz = f.position[2] - self.start[2];
            let scale = self.air_factor * self.air_repetition;
            self.air_metrics[0] =
                self.data.collector.curve(0x3c0, (dx * dx + dz * dz).sqrt()) * scale;
            self.air_metrics[1] =
                self.data.collector.curve(0x410, self.peak - self.start[1]) * scale;
            self.air_metrics[2] = self
                .data
                .collector
                .curve(0x320, f.position[1] - self.start[1])
                * scale;
            let turns =
                ((self.spin.to_degrees().abs() + self.data.collector.scalar(0x63c)) / 180.) as i32;
            self.air_metrics[3] = self.data.collector.curve(0x370, (turns * 180) as f32) * scale;
            let signed_turns = if self.spin < 0. { -turns } else { turns };
            if signed_turns != self.spin_turns {
                self.spin_turns = signed_turns;
                if self.display_id.is_none() && self.spin_turns != 0 && !self.new_trick {
                    // 82775914 starts a display even when no trick descriptor exists.
                    if !self.air_display_started {
                        self.air_display_started = true;
                        self.new_trick = true;
                        self.trick_seq = self.trick_seq.saturating_add(1);
                    } else {
                        self.modified_trick = true;
                    }
                } else {
                    self.modified_trick = true;
                }
            }
            if f.body_flip
                && self.carriers[0]
                    .as_ref()
                    .is_some_and(|c| c.announced && c.scorable.class == 2)
            {
                // 82DA8EB8 retains signed +2348 after the grab/flip is released.
                let count = if f.front_flip { 1 } else { -1 };
                if count != self.body_flip_count {
                    self.body_flip_count = count;
                    self.modified_trick = true;
                }
            }
            self.air_metrics[4] =
                self.body_flip_count.abs() as f32 * self.data.collector.scalar(0x640) * scale;
        }
        if self.new_trick || self.modified_trick {
            let [switch, fakie] = if self.collector == Collector::Air {
                self.air_stance
            } else {
                [f.switch, f.fakie]
            };
            let (name, stance) = display::compose(
                &self.data,
                self.display_id,
                self.spin_turns,
                self.body_flip_count,
                switch,
                fakie,
                f.regular,
            );
            self.display_base = display::compose(&self.data, self.display_id, 0, 0,
                switch, fakie, f.regular).0;
            self.display_spin_degrees = self.spin_turns * 180;
            self.trick_name = name;
            self.stance = stance;
        } else if !self.sequence_active {
            // Stance remains live when riding, instead of retaining the last trick forever.
            self.stance = [f.switch, f.fakie, true, false];
        }
        // Ground IsSequenceActive82DAB3FC preserves the sequence while
        // ScoringTrick bit24 is set, including the manual-to-pop animation.
        let active = self.carriers.iter().any(Option::is_some)
            || self.collector == Collector::Air
            || self.collector == Collector::Ground && f.flags & 0x0100_0000 != 0;
        self.idle_ticks = if active {
            0
        } else {
            self.idle_ticks.saturating_add(1)
        };
        if self.session.holder.has_pending_sequence() {
            if f.landing.landing_data_167 {
                self.clean = f.landing.landing_type_96 == 0;
                self.sketchy = f.landing.landing_type_96 == 1
                    && f.landing.sideways_speed_84 > self.data.sketchy_side_speed
                    && f.landing.spin_92.abs() > 0.5;
            }
            if self.landing_countdown == 0 {
                let mut factor = 1.;
                if f.switch && !f.fakie {
                    factor *= self.data.collector.scalar(0x61c);
                }
                if f.fakie && !f.switch {
                    factor *= self.data.collector.scalar(0x62c);
                }
                if self.collector == Collector::Grind {
                    factor *= self.data.collector.scalar(0x628);
                }
                if self.clean {
                    factor *= self.data.collector.scalar(0x630);
                }
                if self.sketchy {
                    factor *= self.data.collector.scalar(0x620);
                }
                bevy::log::info!(target: "scoring", "SCORING_LANDING_FACTOR tick={} pending={} accumulated={} factor={} clean={} sketchy={}", f.tick, self.session.holder.snapshot.general_pending + self.session.holder.snapshot.fingerflip_pending, self.session.holder.snapshot.accumulated, factor, self.clean, self.sketchy);
                self.session.holder.reward_sequence(factor);
            } else {
                self.landing_countdown -= 1;
            }
        }
        let scales = match self.collector {
            Collector::Air => (0x668, 0x664),
            Collector::Grind => (0x618, 0x614),
            Collector::Offboard => (0x608, 0x604),
            _ => (0x610, 0x60c),
        };
        let line_scale = if active {
            self.data.collector.scalar(scales.0)
        } else {
            1.
        };
        let combo_scale = if active {
            self.data.collector.scalar(scales.1)
        } else {
            1.
        };
        // 82DA3624 holds the active sequence, including ground settlement;
        // it does not use "a descriptor exists this frame" as the hold flag.
        let ground_hold_limit = (self.data.collector.scalar(0x5fc) * 60.) as u32;
        let hold_line = self.sequence_active
            && (self.collector != Collector::Ground || self.line_hold_ticks < ground_hold_limit);
        let held = self
            .session
            .line
            .advance(f.dt, self.data.line_drain, line_scale, hold_line);
        self.line_hold_ticks = if held && self.collector == Collector::Ground {
            self.line_hold_ticks.saturating_add(1)
        } else {
            0
        };
        self.session
            .combo
            .timer
            .advance(f.dt, self.data.combo_drain, combo_scale, false);
        // gm_sk8: falling onto the deck (LandingOnDeck, 503) loses the sequence too
        if f.state == 503 && self.sequence_active {
            self.ran_out = true;
        }
        let bailout = (self.collector == Collector::None || self.ran_out) && self.sequence_active;
        self.ran_out = false;
        // gm_sk8: a landing settles (LANDING_SETTLE_MS, 250 by default) before
        // the sequence is banked. Banked after 3 ticks, a landing the engine
        // turns into a bail a few ticks later had already scored.
        let seconds = LANDING_SETTLE_MS.load(std::sync::atomic::Ordering::Relaxed) as f32 / 1000.;
        let settle = ((seconds / f.dt.max(1e-4)) as u32).max(3);
        if self.sequence_active && (bailout || self.idle_ticks >= settle && self.landing_countdown == 0)
        {
            if bailout {
                self.session.holder.cancel_pending();
            }
            let applied_multiplier = self.session.combo.multiplier;
            let raw_reward = self.session.holder.snapshot.accumulated
                + self.session.holder.snapshot.general_pending
                + self.session.holder.snapshot.fingerflip_pending;
            self.sequence_score =
                self.session
                    .publish_sequence(&self.data.session_rules(), 1., bailout, true);
            bevy::log::info!(target: "scoring", "SCORING_BANK tick={} state={} raw={} applied_multiplier={} reward={} next_multiplier={} line={} line_expired={} bail={} teleport={}", f.tick, f.state, raw_reward, applied_multiplier, self.sequence_score, self.session.combo.multiplier, self.session.holder.snapshot.line, self.session.line.expired, bailout, f.teleported);
            if !bailout
                && !f.teleported
                && f.category == FilteredCategory::Ground
                && self.trick_seq > self.settled_trick_seq
                && !self.trick_name.is_empty()
            {
                self.landing_seq = self.landing_seq.saturating_add(1);
                self.landed_trick = self.trick_name.clone();
                self.landed_base = self.display_base.clone();
                self.landed_spin_degrees = self.display_spin_degrees;
                self.landed_clean = self.clean;
                self.landed_sketchy = self.sketchy;
            }
            self.settled_trick_seq = self.trick_seq;
            self.sequence_active = false;
            // 82775328 -> 82774E88 closes only for ScoreModule reset/bail
            // output 14630 (82DA4010/82DA4238), not a banked landing.
            self.close_tricks = bailout;
        } else if self.sequence_active {
            let s = &self.session.holder.snapshot;
            self.sequence_score = (s.accumulated
                + s.general_pending
                + s.fingerflip_pending
                + self
                    .carriers
                    .iter()
                    .enumerate()
                    .filter_map(|(i, c)| {
                        c.as_ref().map(|c| {
                            if self.collector == Collector::Grind
                                || self.collector == Collector::Ground && i < 3
                            {
                                if c.scorable.score_type == 9 {
                                    c.reward.max(self.metric_rewards[i])
                                } else {
                                    self.metric_rewards[i]
                                }
                            } else {
                                c.reward
                            }
                        })
                    })
                    .sum::<f32>()
                // 82DA8FF8 adds distance and peak height to holder +48,
                // but defers height gain (ID 131) until ExitAir. Its live
                // value falls during descent and must not enter the HUD score.
                + self.air_metrics.iter().enumerate()
                    .filter(|(i, _)| *i != 2)
                    .map(|(_, reward)| *reward).sum::<f32>())
                * self.session.combo.multiplier;
        }
        if self.session.line.expired || f.teleported || bailout {
            bevy::log::info!(target: "scoring", "SCORING_RESET tick={} score={} multiplier={} line_expired={} bail={} teleport={}", f.tick, self.sequence_score, self.session.combo.multiplier, self.session.line.expired, bailout, f.teleported);
            self.sequence_score = 0.;
        }
        self.session.settle_line(f.teleported || bailout, active);
        self.previous = f.position;
        Ok(())
    }
}

