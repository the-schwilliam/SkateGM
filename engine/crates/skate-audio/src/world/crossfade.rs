//! The zone-ambience crossfade layers (`c_main_ambience_crossfade`), read from a bank's own program.
//!
//! Retail's ambience manager (`sub_824D0F38`, audio-specs/ems-emitters-re.md "Crossfade") posts
//! `c_main_ambience_crossfade` to the map's crossfade bank with w1 = 32767, w4 = 4096, w5 = 25000,
//! w9 = the zone pair's group and w0 = w8 = the MixMap level; the bank's program then opens the
//! group's voices (retail's three banks: four looping voices at quad pans, the rear ones at
//! w8 × 23000/32767). Which voices a group opens is therefore data of the bank, not of the engine:
//! [`layouts`] posts every group to a private evaluator at full level (w0 = w8 = 32767) and records
//! what the program opens (sample slot, azimuth input, level input), so any bank whose program binds
//! the class (retail's or a mod's) gets its layout the way retail plays it.
//!
//! Pure: the caller hands in the parsed projects and bank; nothing touches a live runtime.
use crate::eval::{Evaluator, OpenRequest, VoiceHost, VoiceStatus};
use crate::formats::{Bank, Project};

/// The class the ambience manager posts.
pub const CLASS: &str = "c_main_ambience_crossfade";

/// Groups a pair record can name (retail's pair records use 1..=9; the post takes 1..=25).
pub const MAX_GROUP: u32 = 25;

/// Evaluator walks run per group before reading the opened voices (retail's programs open every
/// voice on the first walk; two leave room for a program that opens one walk late).
const WALKS: u32 = 2;

/// One voice a group opens.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Voice {
    /// S10A slot (= the bank's exported sample index).
    pub slot: u16,
    /// The AZIMUTH input (property 3) at open: 65536 = 360°, 0 = straight ahead.
    pub azimuth: i32,
    /// The level input (property 2) at open: 32767 = full.
    pub level: i32,
}

/// The post payload for `group` at full level (w0 = w8 = 32767), as `sub_824D0F38` builds it.
pub fn payload(group: u32) -> [i32; 10] {
    let mut w = [0; 10];
    w[0] = 32767;
    w[1] = 32767;
    w[4] = 4096;
    w[5] = 25000;
    w[8] = 32767;
    w[9] = group as i32;
    w
}

#[derive(Default)]
struct Recorder {
    next: u32,
    opened: Vec<Voice>,
}

impl VoiceHost for Recorder {
    fn open(&mut self, r: &OpenRequest) -> Option<u32> {
        let input = |id: u8, default: i32| r.inputs.iter().find(|(t, _)| *t == id).map_or(default, |(_, v)| *v);
        self.opened.push(Voice { slot: r.slot, azimuth: input(3, 0), level: input(2, 32767) });
        self.next += 1;
        Some(self.next)
    }
    fn release(&mut self, _: u32) {}
    fn pause(&mut self, _: u32) {}
    fn resume(&mut self, _: u32) {}
    fn set(&mut self, _: u32, _: u8, _: i32) {}
    fn set_azimuth(&mut self, _: u32, _: i32) {}
    fn query(&mut self, _: u32) -> VoiceStatus {
        // Looping layers: alive for as long as the probe runs.
        VoiceStatus { alive: true, remaining_ms: i32::MAX, elapsed_ms: 0 }
    }
}

/// The voices each group 1..=[`MAX_GROUP`] opens, in open order, for groups that open any.
/// `Ok(empty)` when the bank has no module bound to [`CLASS`]; `Err` when the projects lack the
/// class. Each group runs in a fresh evaluator (no state carries between groups).
pub fn layouts(projects: &[Project], bank: &Bank) -> Result<Vec<(u32, Vec<Voice>)>, String> {
    let mut out = Vec::new();
    for group in 1..=MAX_GROUP {
        let mut eval = Evaluator::new();
        for p in projects {
            eval.install_project(p);
        }
        eval.load_bank(bank.clone());
        let class = eval.class_id(CLASS).ok_or_else(|| format!("the AEMS projects have no class {CLASS}"))?;
        eval.post(class, &payload(group));
        if eval.instance_count() == 0 {
            // Nothing in the bank answers the class: no group will open anything.
            return Ok(out);
        }
        let mut rec = Recorder::default();
        for _ in 0..WALKS * crate::eval::BLOCKS_PER_WALK {
            eval.block(&mut rec);
        }
        if !rec.opened.is_empty() {
            out.push((group, rec.opened));
        }
    }
    Ok(out)
}
