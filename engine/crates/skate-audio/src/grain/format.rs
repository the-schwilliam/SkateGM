//! `.grain` members of `grains.big` (spec `audio-specs/grain-player-spec.md` §1.2–1.3):
//! `+0` u32 header length H (= offset of the EA Audio Core stream), `+4` f32 stored duration
//! (seconds; the player uses this float), `+8..H` a seek table, then one EAAC stream.
//!
//! The seek table maps a sample position to the XMA entry's byte offset; in every retail grain
//! row 0 already spans the whole stream, so a seek to t seconds is "read from frame ⌊rate·t⌋" of
//! the decoded PCM. We parse it only to validate a member.

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GrainError(pub String);

impl std::fmt::Display for GrainError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "grain: {}", self.0)
    }
}

impl std::error::Error for GrainError {}

/// EA Audio Core stream header (two big-endian words).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Eaac {
    pub version: u32,
    pub codec: u32,
    pub channels: u32,
    pub rate: u32,
    pub kind: u32,
    pub looped: bool,
    pub samples: u32,
}

/// One seek-table row: (byte step, side-data step, samples, key flag).
pub type SeekRow = [i64; 4];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SeekTable {
    /// 0 = run-length columns.
    pub kind: u8,
    pub layout: u8,
    pub low: u8,
    /// Samples decoded and discarded before a target.
    pub preroll: u16,
    /// Offset of the per-entry side data from the table start (0 = none).
    pub side_offset: u32,
    pub rows: Vec<SeekRow>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct GrainFile {
    pub header_len: u32,
    /// The stored duration (seconds), not samples/rate.
    pub duration: f32,
    pub seek: SeekTable,
    pub stream: Eaac,
}

fn be32(b: &[u8], at: usize) -> Result<u32, GrainError> {
    b.get(at..at + 4).map(|w| u32::from_be_bytes(w.try_into().unwrap())).ok_or_else(|| GrainError(format!("truncated at {at:#x}")))
}

/// The shared byte cursor of the seek table's columns.
struct Cursor<'a> {
    data: &'a [u8],
    pos: usize,
}

impl Cursor<'_> {
    fn byte(&self, k: usize) -> Option<u32> {
        self.data.get(self.pos + k).map(|&b| u32::from(b))
    }

    /// Signed variable-length integer: the first byte picks 1–5 bytes; the lowest bit of the last
    /// byte is the sign (set: value = −1 − magnitude); 0xFF = a raw big-endian i32.
    fn varint(&mut self) -> Option<i64> {
        let b0 = self.byte(0)?;
        let (magnitude, sign, len) = if b0 < 0xC0 {
            (b0 >> 1, b0 & 1, 1)
        } else if b0 < 0xF0 {
            let b1 = self.byte(1)?;
            ((((b0 << 8) | b1) >> 1 & !0x6000) + 96, b1 & 1, 2)
        } else if b0 < 0xFC {
            let (b1, b2) = (self.byte(1)?, self.byte(2)?);
            ((((((b0 << 8) | b1) & !0xF000) << 8 | b2) >> 1) + 6240, b2 & 1, 3)
        } else if b0 < 0xFF {
            let (b1, b2, b3) = (self.byte(1)?, self.byte(2)?, self.byte(3)?);
            (((((b0 & 3) << 24) | (b1 << 16) | (b2 << 8) | (b3 & 0xFE)) >> 1) + 0x60000 + 6240, b3 & 1, 4)
        } else {
            let raw = ((self.byte(1)? << 24) | (self.byte(2)? << 16) | (self.byte(3)? << 8) | self.byte(4)?) as i32;
            self.pos += 5;
            return Some(i64::from(raw));
        };
        self.pos += len;
        Some(if sign == 1 { -1 - i64::from(magnitude) } else { i64::from(magnitude) })
    }
}

/// A run-length column: a header h ≥ 0 gives one delta for the next h+1 rows; h < 0 gives 1−h
/// rows that each read their own delta. The column value is the running sum of the deltas read.
#[derive(Default)]
struct Column {
    value: i64,
    left: i64,
    repeat: bool,
}

impl Column {
    fn next(&mut self, cur: &mut Cursor) -> Option<i64> {
        if self.left <= 0 {
            let h = cur.varint()?;
            if h >= 0 {
                (self.left, self.repeat) = (h + 1, true);
                self.value += cur.varint()?;
            } else {
                (self.left, self.repeat) = (1 - h, false);
            }
        }
        if !self.repeat {
            self.value += cur.varint()?;
        }
        self.left -= 1;
        Some(self.value)
    }
}

impl SeekTable {
    pub fn parse(table: &[u8]) -> Result<Self, GrainError> {
        if table.len() < 8 {
            return Err(GrainError("seek table shorter than its header".into()));
        }
        let side_offset = be32(table, 4)?;
        let columns = if side_offset != 0 { table.get(..side_offset as usize).unwrap_or(table) } else { table };
        let mut cur = Cursor { data: columns, pos: 8 };
        let mut cols: [Column; 4] = Default::default();
        let mut rows = Vec::new();
        'rows: while rows.len() < 4096 && cur.pos < columns.len() {
            let mut row = [0i64; 4];
            for (c, v) in cols.iter_mut().zip(row.iter_mut()) {
                match c.next(&mut cur) {
                    Some(x) => *v = x,
                    None => break 'rows,
                }
            }
            rows.push(row);
            if row[2] < 0 {
                break;
            }
        }
        Ok(Self {
            kind: table[0],
            layout: table[1] >> 4,
            low: table[1] & 0xF,
            preroll: u16::from_be_bytes([table[2], table[3]]),
            side_offset,
            rows,
        })
    }
}

impl GrainFile {
    pub fn parse(data: &[u8]) -> Result<Self, GrainError> {
        let header_len = be32(data, 0)?;
        let duration = f32::from_bits(be32(data, 4)?);
        let h = header_len as usize;
        if !(16..data.len()).contains(&h) {
            return Err(GrainError(format!("header length {h} outside the member ({} bytes)", data.len())));
        }
        let seek = SeekTable::parse(&data[8..h])?;
        let (w0, w1) = (be32(data, h)?, be32(data, h + 4)?);
        let stream = Eaac {
            version: w0 >> 28,
            codec: (w0 >> 24) & 0xF,
            channels: ((w0 >> 18) & 0x3F) + 1,
            rate: w0 & 0x3FFFF,
            kind: w1 >> 30,
            looped: (w1 >> 29) & 1 == 1,
            samples: w1 & 0x1FFF_FFFF,
        };
        if stream.rate == 0 || stream.samples == 0 {
            return Err(GrainError("empty EAAC stream".into()));
        }
        let seconds = stream.samples as f32 / stream.rate as f32;
        if !(duration > 0.0) || (duration - seconds).abs() > 0.01 {
            return Err(GrainError(format!("stored duration {duration} s does not match the stream ({seconds} s)")));
        }
        Ok(Self { header_len, duration, seek, stream })
    }

    /// Whether row 0 is one key entry spanning the whole stream (true for every retail grain).
    pub fn single_entry(&self) -> bool {
        self.seek.rows.first().is_some_and(|r| r[2] == i64::from(self.stream.samples) && r[3] == 1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn varint_forms() {
        let mut c = Cursor { data: &[0x06, 0x07, 0xC0, 0x01, 0xFF, 0x00, 0x00, 0x01, 0x00], pos: 0 };
        assert_eq!(c.varint(), Some(3));
        assert_eq!(c.varint(), Some(-4));
        // 2-byte: ((0xC001 >> 1) & !0x6000) + 96 = 96; sign bit set → −97.
        assert_eq!(c.varint(), Some(-97));
        assert_eq!(c.varint(), Some(256));
    }

    #[test]
    fn a_minimal_member_parses() {
        let mut m = Vec::new();
        m.extend_from_slice(&24u32.to_be_bytes());
        m.extend_from_slice(&1.0f32.to_be_bytes());
        // Seek header: kind 0, layout 1, pre-roll 384, no side data; one row of four run headers
        // h = 0 with one delta each: bytes 10, side 0, samples 1, key 1.
        m.extend_from_slice(&[0x00, 0x10, 0x01, 0x80, 0, 0, 0, 0]);
        m.extend_from_slice(&[0x00, 0x14, 0x00, 0x00, 0x00, 0x02, 0x00, 0x02]);
        // Header word: version 0, codec 3, mono, 48000 Hz; samples 48000.
        m.extend_from_slice(&((3u32 << 24) | 48000).to_be_bytes());
        m.extend_from_slice(&48000u32.to_be_bytes());
        m.extend_from_slice(&[0; 16]);
        let g = GrainFile::parse(&m).unwrap();
        assert_eq!(g.duration, 1.0);
        assert_eq!(g.stream.rate, 48000);
        assert_eq!(g.seek.preroll, 384);
        assert_eq!(g.seek.layout, 1);
        assert_eq!(g.seek.rows, vec![[10, 0, 1, 1]]);
        assert!(!g.single_entry());
    }
}
