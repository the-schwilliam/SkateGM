//! `SPLC` bank patch trees (the `.bnk` banks' header part; layout verified on all 20 disc banks,
//! `tools/audio-file-inspect/splc_fields.py`): a 60-byte header (+8 sample-table offset from
//! byte 60, +12 record count, +16 container count, +20 extras (0), +24 sample count), 36-byte
//! records, 72-byte containers, then per record its groups (12-byte header) of 72-byte members.
//! Field roles from the retail Splice code (`super` docs); offsets are facts.
use crate::be::{f32_at, u8_at, u16_at, u32_at};

/// One member of a group: a sample and how it plays.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Member {
    /// `+0` sample index (= the bank's n-th stream).
    pub sample: u16,
    /// `+3` output route byte (255 = none; not modelled).
    pub route: u8,
    /// `+4` gain, `+8` pitch ratio, `+12` second rate factor (1.0 on every disc member).
    pub gain: f32,
    pub pitch: f32,
    pub rate2: f32,
    /// `+16` pan offset (degrees, × block[4]); −127 = not panned.
    pub pan: f32,
    /// `+20` delay (s), `+24` start (s of elapsed time), `+28` length (s at the nominal pitch).
    pub delay: f32,
    pub start: f32,
    pub length: f32,
    /// `+32` fade-in end, `+36` fade-out start (0 = none); `+40` & 15 the curve.
    pub fade_in_end: f32,
    pub fade_out_start: f32,
    pub curve: u8,
    /// `+44` gain spread, `+48` pitch randomisation, `+52` delay randomisation.
    pub gain_spread: f32,
    pub pitch_rand: f32,
    pub delay_rand: f32,
    /// `+64` probability of playing.
    pub probability: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Group {
    /// `+9` pick mode, `+4` state word (live), the members.
    pub mode: u8,
    pub state: u32,
    pub members: Vec<Member>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Record {
    /// `+8` gain, `+12` pitch factor base, `+16` its randomisation.
    pub gain: f32,
    pub pitch_base: f32,
    pub pitch_rand: f32,
    pub groups: Vec<Group>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Container {
    /// `+69` pick mode, `+0` state word (live), `+4…` record ids (`+68` count).
    pub mode: u8,
    pub state: u32,
    pub ids: Vec<u16>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SpliceBank {
    pub records: Vec<Record>,
    pub containers: Vec<Container>,
    pub samples: usize,
}

impl SpliceBank {
    /// Parse a bank's patch tree (the whole `.bnk`, or its first `60 + table + 4·samples` bytes).
    pub fn parse(d: &[u8]) -> Result<Self, String> {
        if d.get(..4) != Some(b"SPLC") {
            return Err("not an SPLC bank".into());
        }
        let table = 60 + u32_at(d, 8) as usize;
        let records = u32_at(d, 12) as usize;
        let containers = u32_at(d, 16) as usize;
        let samples = u32_at(d, 24) as usize;
        if u32_at(d, 20) != 0 {
            return Err("SPLC bank with extras".into());
        }
        if table > d.len() || records > 65_536 || containers > 65_536 {
            return Err("SPLC header out of range".into());
        }
        let cbase = 60 + 36 * records;
        let mut out_containers = Vec::with_capacity(containers);
        for c in 0..containers {
            let at = cbase + 72 * c;
            let count = usize::from(u8_at(d, at + 68)).min(32);
            out_containers.push(Container {
                mode: u8_at(d, at + 69),
                state: u32_at(d, at),
                ids: (0..count).map(|k| u16_at(d, at + 4 + 2 * k)).collect(),
            });
        }
        let mut cursor = cbase + 72 * containers;
        let mut out_records = Vec::with_capacity(records);
        for r in 0..records {
            let at = 60 + 36 * r;
            let mut groups = Vec::new();
            for _ in 0..u8_at(d, at + 7) {
                let count = u8_at(d, cursor + 8);
                let mode = u8_at(d, cursor + 9);
                let state = u32_at(d, cursor + 4);
                cursor += 12;
                let mut members = Vec::with_capacity(usize::from(count));
                for _ in 0..count {
                    let m = cursor;
                    let sample = u16_at(d, m);
                    if usize::from(sample) >= samples {
                        return Err(format!("record {r}: member names sample {sample} of {samples}"));
                    }
                    members.push(Member {
                        sample,
                        route: u8_at(d, m + 3),
                        gain: f32_at(d, m + 4),
                        pitch: f32_at(d, m + 8),
                        rate2: f32_at(d, m + 12),
                        pan: f32_at(d, m + 16),
                        delay: f32_at(d, m + 20),
                        start: f32_at(d, m + 24),
                        length: f32_at(d, m + 28),
                        fade_in_end: f32_at(d, m + 32),
                        fade_out_start: f32_at(d, m + 36),
                        curve: u8_at(d, m + 40) & 15,
                        gain_spread: f32_at(d, m + 44),
                        pitch_rand: f32_at(d, m + 48),
                        delay_rand: f32_at(d, m + 52),
                        probability: f32_at(d, m + 64),
                    });
                    cursor += 72;
                }
                if members.is_empty() {
                    return Err(format!("record {r}: empty group"));
                }
                groups.push(Group { mode, state, members });
            }
            out_records.push(Record { gain: f32_at(d, at + 8), pitch_base: f32_at(d, at + 12), pitch_rand: f32_at(d, at + 16), groups });
        }
        if cursor != table {
            return Err(format!("patch tree ends at {cursor:#x}, sample table at {table:#x}"));
        }
        Ok(Self { records: out_records, containers: out_containers, samples })
    }

    /// The patch-tree part of a bank file (what setup keeps): header, records, containers and
    /// groups, up to the sample table.
    pub fn tree_len(d: &[u8]) -> Option<usize> {
        if d.get(..4) != Some(b"SPLC") {
            return None;
        }
        let n = 60 + u32_at(d, 8) as usize;
        (n <= d.len()).then_some(n)
    }
}
