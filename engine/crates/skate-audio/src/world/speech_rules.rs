//! The speech library's event rules and its line and take choice (`<bank>_Events.evt`, the per-clip
//! `.hdr` headers; `audio-specs/world-speech.md` "Speech library").
//!
//! Retail's speech runs in two layers. The game's speech manager ([`super::speech_manager`]) turns a
//! request into an event id and a few request words and gates it with the vault tuning. This module
//! is the generic library under it. It is the same code for the living world, the main cast, the
//! cameraman and the announcer; only the tables differ. Read from the TU3 recompilation (reference
//! only, our own code):
//! - `sub_82971480`: the event's own probability (`.evt` byte +9);
//! - `sub_82973CB8`: the line choice. It walks the event's records in a weighted random order
//!   (`sub_82972980`) and takes the first one that passes its probability (record byte +1) and whose
//!   field values match the request words (`sub_82973BD8`: a value of 0 matches anything, otherwise
//!   the request word must share a bit with it);
//! - `sub_82972D70` / `sub_82972660`: a record's clips play in sequence (a radio chirp, the line,
//!   another chirp). For each clip the candidates are the takes that are not in the clip's take
//!   history (`.hdr` +8 = its length). When every take is in it, the one played longest ago is the
//!   only candidate;
//! - `sub_82974220`: the take among the candidates is a random index. The library keeps a ring of the
//!   last 32 (index, clip header) picks and redraws (up to 32 draws) while the index is among the
//!   last `min(n / 2, 10)` picks of the same clip;
//! - `sub_82973408`: when the line starts, each clip's take goes into its history ring.
//!
//! Draws come from the library's own add-with-carry generator. It is the same algorithm and the same
//! image seed as the grain player's title generator ([`crate::eval::rng::Rng`]).
//!
//! **Not ported (no living-world data uses it):** external event conditions (`.evt` +7), record
//! locals and clip parameters, header take-bits (`.hdr` +2 bit 7), the follow-up lists of event
//! flags2 bit4. The host applies the shared16-slot request queue in `speech_player`;
//! this module selects lines and takes. Unsupported selection modes fail closed.
use std::collections::HashMap;

use crate::eval::rng::Rng;

/// A record's weight: `WEIGHT_SCALE[b >> 5] * (b & 31)` of its first byte (`sub_82972980`; the table
/// sits next to the generator's state in the image).
pub const WEIGHT_SCALE: [u32; 8] = [1, 4, 16, 64, 256, 1024, 4096, 16384];
/// The ring of recent take picks (`sub_82974220`).
pub const RECENT_PICKS: usize = 32;
/// At most this many clips in one record (`sub_82972D70`).
pub const MAX_RECORD_CLIPS: usize = 12;

/// One clip reference of a record (8-byte entry: u16 clip id, …, lookup mode at +3, parameter count
/// at +4).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ClipRef {
    pub id: u16,
    /// `+3`: 0 = by id (every living-world entry).
    pub lookup: u8,
    /// `+4`: take parameters (none in the living world).
    pub params: i8,
}

/// One record: a weighted alternative of an event with the field values it needs and the clips it
/// plays in sequence.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    /// Byte 0: the weight code ([`Record::weight`]).
    pub weight_code: u8,
    /// Byte 1: percent.
    pub probability: u8,
    /// Byte 2 low bits: 0 / 2 = always, 1 = only on a flagged channel, 3 = never.
    pub mode: u8,
    /// Byte 3: record locals (none in the living world).
    pub locals: u8,
    /// Field values in the event's field order: 0 = any, else a bit mask.
    pub values: Vec<u32>,
    pub clips: Vec<ClipRef>,
}

impl Record {
    pub fn weight(&self) -> u32 {
        WEIGHT_SCALE[usize::from(self.weight_code >> 5)] * u32::from(self.weight_code & 31)
    }
}

/// One event of an `.evt` table.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Event {
    pub id: u16,
    pub name: String,
    /// `+2`: how long a request may wait for its stream (zero disables expiration).
    pub queue_timeout: u16,
    /// `+4`: the queue priority.
    pub priority: u16,
    /// `+7`: external conditions (none in the living world; events with any fail closed).
    pub conditions: u8,
    /// `+8`: the high nibble is the field count.
    pub flags: u8,
    /// `+9`: percent ([`Library::start`]).
    pub probability: u8,
    /// `+10`: bit 3 = record pairing, bit 4 = follow-up lists (none in the living world).
    pub flags2: u8,
    /// The request word each field reads (1 = the first word after the event).
    pub fields: Vec<u8>,
    pub records: Vec<Record>,
}

/// An `.evt` table: one speech bank's events.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EventTable {
    /// Header `+8` / `+9` (the living world is bank 1).
    pub bank: u8,
    pub sub_bank: u8,
    pub events: Vec<Event>,
}

fn align4(n: usize) -> usize {
    (n + 3) & !3
}

struct Reader<'a>(&'a [u8]);

impl Reader<'_> {
    fn u8(&self, at: usize) -> Result<u8, String> {
        self.0.get(at).copied().ok_or_else(|| format!("evt: read past the end at {at:#x}"))
    }
    fn u16(&self, at: usize) -> Result<u16, String> {
        Ok(u16::from_be_bytes([self.u8(at)?, self.u8(at + 1)?]))
    }
    fn u32(&self, at: usize) -> Result<u32, String> {
        Ok(u32::from_be_bytes([self.u8(at)?, self.u8(at + 1)?, self.u8(at + 2)?, self.u8(at + 3)?]))
    }
}

impl EventTable {
    /// Parse an `.evt` file (layout in `tools/asset_pipeline/world_audio.parse_evt`).
    pub fn parse(data: &[u8]) -> Result<Self, String> {
        let r = Reader(data);
        let names_at = r.u32(4)? as usize;
        let count = usize::from(r.u16(0x10)?);
        let strings = names_at + 32 * count;
        let mut events = Vec::with_capacity(count);
        for i in 0..count {
            let o = usize::from(r.u16(0x18 + 2 * i)?) * 4;
            let name_at = strings + r.u32(names_at + 32 * i)? as usize;
            let name_end = data.get(name_at..).and_then(|s| s.iter().position(|b| *b == 0)).map_or(name_at, |n| name_at + n);
            let name = String::from_utf8_lossy(data.get(name_at..name_end).unwrap_or_default()).into_owned();
            let n_records = usize::from(r.u8(o + 6)?);
            let conditions = r.u8(o + 7)?;
            let flags = r.u8(o + 8)?;
            let n_conditions = usize::from(conditions);
            let fields_at = o + 12 + align4(2 * n_records) + align4(n_conditions.div_ceil(8) * n_records * 2) + align4(3 * n_conditions);
            let fields = (0..usize::from(flags >> 4)).map(|k| r.u8(fields_at + 3 * k + 1)).collect::<Result<_, _>>()?;
            let mut records = Vec::with_capacity(n_records);
            for k in 0..n_records {
                let at = o + 4 * usize::from(r.u16(o + 12 + 2 * k)?);
                let byte2 = r.u8(at + 2)?;
                let n_clips = usize::from(byte2 >> 2);
                let n_values = usize::from(r.u8(at + 4)?);
                let values_at = at + 8 + align4(n_clips);
                let values = (0..n_values).map(|v| r.u32(values_at + 4 * v)).collect::<Result<_, _>>()?;
                let mut clips = Vec::with_capacity(n_clips);
                for c in 0..n_clips {
                    let entry = at + 4 * usize::from(r.u8(at + 8 + c)?);
                    clips.push(ClipRef { id: r.u16(entry)?, lookup: r.u8(entry + 3)?, params: r.u8(entry + 4)? as i8 });
                }
                records.push(Record { weight_code: r.u8(at)?, probability: r.u8(at + 1)?, mode: byte2 & 3, locals: r.u8(at + 3)?, values, clips });
            }
            events.push(Event {
                id: r.u16(o)?,
                name,
                queue_timeout: r.u16(o + 2)?,
                priority: r.u16(o + 4)?,
                conditions,
                flags,
                probability: r.u8(o + 9)?,
                flags2: r.u8(o + 10)?,
                fields,
                records,
            });
        }
        Ok(Self { bank: r.u8(8)?, sub_bank: r.u8(9)?, events })
    }

    /// The event with this id (`sub_829711D0`: the first in table order).
    pub fn event(&self, id: u16) -> Option<&Event> {
        self.events.iter().find(|e| e.id == id)
    }

    /// The request's first word (`sub_829717A0`): the event id, the sub-bank and the bank. A field
    /// id of 0 reads it.
    pub fn packed(&self, id: u16) -> u32 {
        (u32::from(id) << 16) | (u32::from(self.sub_bank) << 8) | u32::from(self.bank)
    }
}

/// A clip's `.hdr` fields the choice reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ClipHeader {
    pub id: u16,
    /// `+3`.
    pub takes: u8,
    /// `+8`: the length of the take history (0 = none: every take is always a candidate).
    pub history: u8,
    /// `+2`: take-condition bits (none in the living world; a clip with any fails closed).
    pub flags: u8,
}

/// One clip of a chosen line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Pick {
    pub clip: u16,
    /// Index into [`Library::headers`].
    pub header: usize,
    pub take: u8,
}

/// A clip's take history: the takes it played, oldest overwritten first.
#[derive(Clone, Debug, PartialEq, Eq)]
struct History {
    cursor: u8,
    takes: Vec<u8>,
}

/// The speech library's state: the clip headers (sorted by id, as retail's header table), the take
/// histories, the recent-pick ring and the generator.
#[derive(Clone, Debug)]
pub struct Library {
    pub rng: Rng,
    headers: Vec<ClipHeader>,
    by_id: HashMap<u16, usize>,
    histories: Vec<History>,
    /// (candidate index, header index); starts as 32 × (0, 0) like retail's zeroed ring.
    recent: [(u16, u16); RECENT_PICKS],
    recent_cursor: usize,
}

/// Why [`Library::start`] played nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NoLine {
    UnknownEvent,
    /// The event's own probability draw.
    Probability,
    /// An unported mechanism the event uses (fails closed).
    Unsupported,
    /// No record matched, passed its probability and had its clips.
    NoRecord,
}

impl Library {
    /// The image's initial generator state (shared in retail with the grain player's title
    /// generator, [`crate::grain::GrainBed::SEED`]).
    pub const SEED: [u32; 6] = crate::grain::GrainBed::SEED;

    pub fn new(mut headers: Vec<ClipHeader>) -> Self {
        headers.sort_by_key(|h| h.id);
        let by_id = headers.iter().enumerate().map(|(i, h)| (h.id, i)).collect();
        let histories = headers.iter().map(|h| History { cursor: 0, takes: vec![0xFF; usize::from(h.history)] }).collect();
        Self { rng: Rng::new(Self::SEED), headers, by_id, histories, recent: [(0, 0); RECENT_PICKS], recent_cursor: 0 }
    }

    pub fn headers(&self) -> &[ClipHeader] {
        &self.headers
    }

    pub fn header(&self, id: u16) -> Option<usize> {
        self.by_id.get(&id).copied()
    }

    /// The clip's take history, most recent last (for logs and tests).
    pub fn history(&self, header: usize) -> Vec<u8> {
        let h = &self.histories[header];
        let n = h.takes.len();
        (0..n).map(|k| h.takes[(usize::from(h.cursor) + k) % n]).filter(|t| *t != 0xFF).collect()
    }

    /// A 16-bit draw scaled to `0..n` (`(draw >> 16) * n >> 16`, 32-bit as retail).
    fn scaled(&mut self, n: u32) -> u32 {
        ((self.rng.draw() >> 16).wrapping_mul(n) >> 16) & 0xFFFF
    }

    /// Start a line of `event` for the request words `values` (word 1 onward). On success the takes
    /// are in the clips' histories.
    pub fn start(&mut self, table: &EventTable, event: u16, values: &[u32]) -> Result<Vec<Pick>, NoLine> {
        let ev = table.event(event).ok_or(NoLine::UnknownEvent)?;
        if self.scaled(100) > u32::from(ev.probability) {
            return Err(NoLine::Probability);
        }
        if ev.conditions != 0 || ev.flags2 & 0x18 != 0 {
            return Err(NoLine::Unsupported);
        }
        let packed = table.packed(event);
        for index in self.record_order(ev) {
            let record = &ev.records[index];
            if self.scaled(100) >= u32::from(record.probability) {
                continue;
            }
            if !matches(ev, record, packed, values) {
                continue;
            }
            let Some(candidates) = self.candidates(record) else { continue };
            let mut picks = Vec::with_capacity(candidates.len());
            for (header, list) in &candidates {
                if list.is_empty() {
                    break;
                }
                let k = self.recent_pick(list.len(), *header);
                picks.push(Pick { clip: self.headers[*header].id, header: *header, take: list[k] });
            }
            if picks.len() != candidates.len() {
                continue;
            }
            for p in &picks {
                let h = &mut self.histories[p.header];
                let len = h.takes.len();
                if len == 0 {
                    continue;
                }
                if usize::from(h.cursor) < len {
                    h.takes[usize::from(h.cursor)] = p.take;
                }
                let next = usize::from(h.cursor) + 1;
                h.cursor = if next < len { next as u8 } else { 0 };
            }
            return Ok(picks);
        }
        Err(NoLine::NoRecord)
    }

    /// `sub_82972980`: the records in a weighted random order without repeats, then the records of
    /// weight 0 in table order.
    pub fn record_order(&mut self, ev: &Event) -> Vec<usize> {
        let n = ev.records.len().min(255);
        let mut weights: Vec<u32> = ev.records[..n].iter().map(Record::weight).collect();
        let mut total: u32 = weights.iter().sum();
        let mut order = Vec::with_capacity(n);
        while total > 0 {
            let mut left = i64::from(self.scaled(total));
            let mut i = 0;
            while i < n {
                left -= i64::from(weights[i]);
                if left < 0 {
                    break;
                }
                i += 1;
            }
            let i = i.min(n - 1);
            order.push(i);
            total -= weights[i];
            weights[i] = 0;
        }
        order.extend((0..n).filter(|i| ev.records[*i].weight() == 0));
        order
    }

    /// `sub_82972D70` / `sub_82972660`: per clip of the record, its header and the candidate takes.
    /// `None` when the record cannot play (a clip missing from the headers, an unported mode).
    fn candidates(&self, record: &Record) -> Option<Vec<(usize, Vec<u8>)>> {
        if record.clips.len() > MAX_RECORD_CLIPS || !matches!(record.mode, 0 | 2) || record.locals != 0 {
            return None;
        }
        let mut out = Vec::with_capacity(record.clips.len());
        let mut total = 0usize;
        for c in &record.clips {
            if c.lookup != 0 || c.params != 0 {
                return None;
            }
            let header = self.header(c.id)?;
            let h = &self.headers[header];
            if h.flags != 0 {
                return None;
            }
            let history = &self.histories[header];
            let len = history.takes.len();
            let mut list = Vec::new();
            let mut oldest: Option<(usize, u8)> = None;
            for take in 0..h.takes {
                let mut age = None;
                let mut at = usize::from(history.cursor);
                for j in 0..len {
                    at = if at == 0 { len - 1 } else { at - 1 };
                    if history.takes[at] == take {
                        age = Some(j + 1);
                        break;
                    }
                }
                match age {
                    Some(a) => {
                        if oldest.is_none_or(|(best, _)| a > best) {
                            oldest = Some((a, take));
                        }
                    }
                    None => {
                        if total < 255 {
                            list.push(take);
                            total += 1;
                        }
                    }
                }
            }
            if list.is_empty()
                && let Some((_, take)) = oldest
                && total < 255
            {
                list.push(take);
                total += 1;
            }
            out.push((header, list));
        }
        Some(out)
    }

    /// `sub_82974220`: a random index below `n` that is not among the last `min(n / 2, 10)` picks of
    /// the same header in the recent ring; up to 32 draws, else the draw whose match was oldest.
    pub fn recent_pick(&mut self, n: usize, header: usize) -> usize {
        let limit = (n / 2).min(10).min(RECENT_PICKS);
        let h = header as u16;
        let mut r = self.scaled(n as u32) as u16;
        let mut chosen = r;
        let mut best: i32 = -1;
        let mut attempts = 0;
        loop {
            let mut found: i32 = -1;
            let mut seen = 0;
            let mut at = self.recent_cursor;
            for _ in 0..=RECENT_PICKS {
                if seen >= limit {
                    break;
                }
                let (pick, owner) = self.recent[at];
                at = (at + RECENT_PICKS - 1) % RECENT_PICKS;
                if owner != h {
                    continue;
                }
                seen += 1;
                if pick == r {
                    found = seen as i32 - 1;
                    break;
                }
            }
            if found == -1 {
                chosen = r;
                break;
            }
            if found > best {
                best = found;
                chosen = r;
            }
            attempts += 1;
            if attempts >= RECENT_PICKS {
                break;
            }
            r = self.scaled(n as u32) as u16;
        }
        self.recent_cursor = (self.recent_cursor + 1) % RECENT_PICKS;
        self.recent[self.recent_cursor] = (chosen, h);
        usize::from(chosen)
    }
}

/// `sub_82973BD8`: every field value of the record is 0 or shares a bit with its request word.
pub fn matches(ev: &Event, record: &Record, packed: u32, values: &[u32]) -> bool {
    ev.fields.iter().enumerate().all(|(k, field)| {
        let want = record.values.get(k).copied().unwrap_or(0);
        if want == 0 {
            return true;
        }
        let word = if *field == 0 { packed } else { values.get(usize::from(*field) - 1).copied().unwrap_or(0) };
        word & want != 0
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(values: &[u32], clips: &[u16]) -> Record {
        Record { weight_code: 0x39, probability: 100, mode: 0, locals: 0, values: values.to_vec(), clips: clips.iter().map(|id| ClipRef { id: *id, lookup: 0, params: 0 }).collect() }
    }

    fn event(id: u16, fields: &[u8], records: Vec<Record>) -> Event {
        Event { id, name: format!("{id}"), queue_timeout: 60, priority: 500, conditions: 0, flags: (fields.len() as u8) << 4, probability: 100, flags2: 0, fields: fields.to_vec(), records }
    }

    /// A tiny `.evt` in the retail layout (synthetic, for the parser).
    fn evt_bytes(ev: &Event) -> Vec<u8> {
        let mut body = Vec::new();
        // Event header + record offsets + field descriptors, then the records.
        let n = ev.records.len();
        let head = 12 + align4(2 * n) + align4(3 * ev.fields.len());
        let mut recs = Vec::new();
        let mut offsets = Vec::new();
        for r in &ev.records {
            offsets.push(((head + recs.len()) / 4) as u16);
            let start = recs.len();
            let nc = r.clips.len();
            let values_at = 8 + align4(nc);
            let clips_at = values_at + 4 * r.values.len();
            recs.extend_from_slice(&[r.weight_code, r.probability, ((nc as u8) << 2) | r.mode, r.locals, r.values.len() as u8, 0, 0, 0]);
            for c in 0..nc {
                recs.push(((clips_at + 8 * c) / 4) as u8);
            }
            recs.resize(start + values_at, 0);
            for v in &r.values {
                recs.extend_from_slice(&v.to_be_bytes());
            }
            for c in &r.clips {
                recs.extend_from_slice(&c.id.to_be_bytes());
                recs.extend_from_slice(&[0, c.lookup, c.params as u8, 0, 0, 0]);
            }
        }
        body.extend_from_slice(&ev.id.to_be_bytes());
        body.extend_from_slice(&ev.queue_timeout.to_be_bytes());
        body.extend_from_slice(&ev.priority.to_be_bytes());
        body.extend_from_slice(&[n as u8, 0, ev.flags, ev.probability, ev.flags2, 0]);
        for o in &offsets {
            body.extend_from_slice(&o.to_be_bytes());
        }
        body.resize(12 + align4(2 * n), 0);
        for f in &ev.fields {
            body.extend_from_slice(&[0xFF, *f, 4]);
        }
        body.resize(head, 0);
        body.extend_from_slice(&recs);
        // File: header (0x18) + one offset (padded to 4) + the event, then the name table.
        let event_at = 0x1C;
        let names_at = event_at + align4(body.len());
        let mut out = vec![0u8; event_at];
        out[4..8].copy_from_slice(&(names_at as u32).to_be_bytes());
        out[8] = 1;
        out[0x10..0x12].copy_from_slice(&1u16.to_be_bytes());
        out[0x18..0x1A].copy_from_slice(&((event_at / 4) as u16).to_be_bytes());
        out.extend_from_slice(&body);
        out.resize(names_at + 32, 0);
        out.extend_from_slice(ev.name.as_bytes());
        out.push(0);
        out
    }

    #[test]
    fn the_parser_reads_back_the_retail_layout() {
        let ev = event(0x2012, &[1, 2, 3], vec![record(&[4, 1, 2], &[0x2FE2]), record(&[4, 1, 1], &[0x2FE1]), record(&[0x4000, 0, 0], &[0x3AF6, 0x2D9F, 0x3AF6])]);
        let table = EventTable::parse(&evt_bytes(&ev)).unwrap();
        assert_eq!(table.bank, 1);
        assert_eq!(table.events, vec![ev]);
    }

    #[test]
    fn records_match_on_shared_bits_and_zero_is_any() {
        let ev = event(1, &[1, 2, 3], vec![]);
        let r = record(&[0x1000, 0x2, 0x2], &[1]);
        assert!(matches(&ev, &r, 0, &[0x1000, 0x2, 0x2]));
        assert!(!matches(&ev, &r, 0, &[0x1000, 0x2, 0x1]), "far request, near record");
        assert!(!matches(&ev, &r, 0, &[0x1000, 0x4, 0x2]), "another voice of the type");
        let any = record(&[0x8, 0x2, 0], &[1]);
        assert!(matches(&ev, &any, 0, &[0x8, 0x2]), "a zero value never reads its (missing) word");
    }

    #[test]
    fn the_weighted_order_is_a_permutation_with_zero_weights_last() {
        let mut records = vec![record(&[], &[1]); 5];
        records[1].weight_code = 0;
        records[3].weight_code = 0xFF; // 16384 × 31
        let ev = event(1, &[], records);
        let mut lib = Library::new(vec![]);
        for _ in 0..50 {
            let order = lib.record_order(&ev);
            assert_eq!(order.len(), 5);
            assert_eq!(order[4], 1, "the zero-weight record comes last");
            let mut sorted = order.clone();
            sorted.sort_unstable();
            assert_eq!(sorted, vec![0, 1, 2, 3, 4]);
        }
        // The heavy record almost always comes first.
        let first_heavy = (0..200).filter(|_| lib.record_order(&ev)[0] == 3).count();
        assert!(first_heavy > 190, "{first_heavy}");
    }

    #[test]
    fn a_clip_plays_every_take_before_repeating_then_cycles() {
        let ev = event(1, &[], vec![record(&[], &[0x10])]);
        let table = EventTable { bank: 1, sub_bank: 0, events: vec![ev] };
        let mut lib = Library::new(vec![ClipHeader { id: 0x10, takes: 5, history: 5, flags: 0 }]);
        let takes: Vec<u8> = (0..15).map(|_| lib.start(&table, 1, &[]).unwrap()[0].take).collect();
        let mut first: Vec<u8> = takes[..5].to_vec();
        first.sort_unstable();
        assert_eq!(first, vec![0, 1, 2, 3, 4], "{takes:?}");
        assert_eq!(takes[5..10], takes[..5], "the history makes the first order repeat: {takes:?}");
        assert_eq!(takes[10..], takes[..5]);
    }

    #[test]
    fn without_a_history_the_recent_ring_avoids_the_last_picks() {
        let ev = event(1, &[], vec![record(&[], &[0x10])]);
        let table = EventTable { bank: 1, sub_bank: 0, events: vec![ev] };
        let mut lib = Library::new(vec![ClipHeader { id: 0x10, takes: 6, history: 0, flags: 0 }]);
        let takes: Vec<u8> = (0..300).map(|_| lib.start(&table, 1, &[]).unwrap()[0].take).collect();
        // limit = min(6 / 2, 10) = 3: never one of the previous three picks.
        for w in takes.windows(4) {
            assert!(!w[..3].contains(&w[3]), "{w:?}");
        }
    }

    #[test]
    fn a_sequence_record_plays_its_clips_in_order_and_fails_without_one() {
        let ev = event(1, &[1], vec![record(&[2], &[0x10, 0x11, 0x10]), record(&[1], &[0x12])]);
        let table = EventTable { bank: 1, sub_bank: 0, events: vec![ev] };
        let mut lib = Library::new(vec![ClipHeader { id: 0x10, takes: 9, history: 9, flags: 0 }, ClipHeader { id: 0x11, takes: 3, history: 3, flags: 0 }]);
        let picks = lib.start(&table, 1, &[2]).unwrap();
        assert_eq!(picks.iter().map(|p| p.clip).collect::<Vec<_>>(), vec![0x10, 0x11, 0x10]);
        assert_ne!(picks[0].take, picks[2].take, "the recent ring keeps the two chirps apart");
        assert_eq!(lib.start(&table, 1, &[1]), Err(NoLine::NoRecord), "clip 0x12 has no header");
        assert_eq!(lib.start(&table, 2, &[1]), Err(NoLine::UnknownEvent));
    }
}
