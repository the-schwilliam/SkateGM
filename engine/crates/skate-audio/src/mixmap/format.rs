//! `MixMapSK8.mxb` decoding (spec `audio-specs/mixmap-spec.md` §2). Big-endian throughout.
//! Our letters for EA's record kinds: A = MixCtl (input product), B = 3DMixCtl (distance/azimuth
//! lookup), C = SubMixCh (clamped sum), E = MasterMixCh (output sum) with its G = Preset output
//! list, F = EvtMixCtl (envelope).

#[derive(Clone, Debug, PartialEq)]
pub struct ProductRec {
    /// Input key; bits 24–27 = curve kind.
    pub input: u32,
    /// Low 16 bits of w1: the swing (bit 15 set = a cut of that many mB, else a boost).
    pub swing: u16,
    pub refs: Vec<u32>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Variant {
    /// Camera-state id (bits 24–27 of the first word).
    pub mode: u32,
    /// 0 → input 1, 1 → input 0, ≥ 2 → −1.0.
    pub dist_sel: u32,
    /// 0 → input 3, 1 → input 2, ≥ 2 → 0.
    pub angle_sel: u32,
    /// Curve per quadrant q0..q3.
    pub curves: [u32; 4],
    /// Doppler speed constant (0 = none).
    pub doppler: u32,
    /// (min, max) metres per direction d0..d3.
    pub ranges: [(u32, u32); 4],
}

#[derive(Clone, Debug, PartialEq)]
pub struct LookupRec {
    /// Controller selector word (slot/object bits name the SFXCTL input block).
    pub ctl: u32,
    pub variants: Vec<Variant>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SumRec {
    pub word0: u32,
    pub max: i32,
    pub min: i32,
    pub refs: Vec<u32>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OutputWord {
    pub id: u32,
    /// Which B reference (≥ the number of specials = none).
    pub special: u32,
    pub raw_angle: bool,
    pub offset: i32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct OutputRec {
    pub word0: u32,
    /// Base value (mB / cents).
    pub base: i32,
    /// Destination SFXObj controller key.
    pub dest: u32,
    /// References; B references ("specials") come first.
    pub refs: Vec<u32>,
    /// 0 volume, 1 pitch, 2 filter, 3/≥5 raw, 4 volume.
    pub kind: u32,
    pub outs: Vec<OutputWord>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct EnvelopeRec {
    pub word0: u32,
    /// 0 = AR, 1 = AHR, 3 = ADSR; others are inert.
    pub kind: u32,
    pub gated: bool,
    pub linear: bool,
    pub retrigger: bool,
    pub swing: u16,
    pub trigger: u32,
    /// (frames, curve).
    pub attack: (u32, u32),
    pub decay: (u32, u32),
    pub hold: u32,
    pub release: (u32, u32),
    /// Sustain level (signed Q15).
    pub sustain: i32,
    pub refs: Vec<u32>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Section {
    pub slot: usize,
    pub products: Vec<ProductRec>,
    pub lookups: Vec<LookupRec>,
    pub sums: Vec<SumRec>,
    pub outputs: Vec<OutputRec>,
    pub envelopes: Vec<EnvelopeRec>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct MixMapFile {
    pub id: u32,
    /// One entry per slot (None = no section).
    pub slots: Vec<Option<Section>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FormatError(pub String);

impl std::fmt::Display for FormatError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "MixMap: {}", self.0)
    }
}

impl std::error::Error for FormatError {}

struct Reader<'a>(&'a [u8]);

impl Reader<'_> {
    fn u32(&self, at: usize) -> Result<u32, FormatError> {
        self.0
            .get(at..at + 4)
            .map(|b| u32::from_be_bytes(b.try_into().unwrap()))
            .ok_or_else(|| FormatError(format!("truncated at {at:#x}")))
    }
    fn i32(&self, at: usize) -> Result<i32, FormatError> {
        Ok(self.u32(at)? as i32)
    }
    fn words(&self, at: usize, n: usize) -> Result<Vec<u32>, FormatError> {
        (0..n).map(|q| self.u32(at + 4 * q)).collect()
    }
}

fn s16(v: u32) -> i32 {
    i32::from(v as u16 as i16)
}

impl MixMapFile {
    pub fn parse(data: &[u8]) -> Result<Self, FormatError> {
        let r = Reader(data);
        let id = r.u32(0)?;
        let count = r.u32(4)? as usize;
        if count > 64 {
            return Err(FormatError(format!("{count} slots")));
        }
        let table = r.u32(8)? as usize;
        let mut slots = Vec::with_capacity(count);
        for s in 0..count {
            let off = r.i32(table + 4 * s)?;
            if off < 0 {
                slots.push(None);
                continue;
            }
            slots.push(Some(Self::section(&r, s, off as usize)?));
        }
        Ok(Self { id, slots })
    }

    fn section(r: &Reader, slot: usize, off: usize) -> Result<Section, FormatError> {
        let table = |k: usize| -> Result<Option<usize>, FormatError> {
            let v = r.i32(off + k)?;
            Ok((v >= 0).then(|| off + v as usize))
        };
        let mut sec = Section { slot, ..Section::default() };
        if let Some(t) = table(4)? {
            let mut p = t + 16;
            for _ in 0..r.i32(t)?.max(0) {
                let (w0, w1) = (r.u32(p)?, r.u32(p + 4)?);
                let n = ((w1 >> 16) & 0x1F) as usize;
                sec.products.push(ProductRec { input: w0, swing: w1 as u16, refs: r.words(p + 8, n)? });
                p += (n + 2) * 4;
            }
        }
        if let Some(t) = table(8)? {
            let mut p = t + 16;
            for _ in 0..(r.u32(t)? & 0xFF) {
                let w0 = r.u32(p)?;
                let nv = ((w0 >> 24) & 0xF) as usize;
                let mut variants = Vec::with_capacity(nv);
                for v in 0..nv {
                    let q = p + 4 + 24 * v;
                    let (r0, r1) = (r.u32(q)?, r.u32(q + 4)?);
                    let mut ranges = [(0, 0); 4];
                    for (d, range) in ranges.iter_mut().enumerate() {
                        let w = r.u32(q + 8 + 4 * d)?;
                        *range = (w & 0x7FFF, (w >> 16) & 0x7FFF);
                    }
                    variants.push(Variant {
                        mode: (r0 >> 24) & 0xF,
                        dist_sel: (r0 >> 12) & 0xF,
                        angle_sel: (r0 >> 8) & 0xF,
                        curves: [(r1 >> 28) & 0xF, (r1 >> 16) & 0xF, (r1 >> 24) & 0xF, (r1 >> 20) & 0xF],
                        doppler: r1 & 0xFFFF,
                        ranges,
                    });
                }
                if variants.is_empty() {
                    return Err(FormatError(format!("slot {slot}: lookup at {p:#x} has no variant")));
                }
                sec.lookups.push(LookupRec { ctl: w0, variants });
                p += nv * 24 + 4;
            }
        }
        if let Some(t) = table(12)? {
            let mut p = t + 16;
            for _ in 0..r.i32(t)?.max(0) {
                let (w0, w1) = (r.u32(p)?, r.u32(p + 4)?);
                let n = ((w0 >> 16) & 0xFF) as usize;
                sec.sums.push(SumRec { word0: w0, max: ((w1 >> 16) & 0x7FFF) as i32, min: s16(w1), refs: r.words(p + 8, n)? });
                p += (n + 2) * 4;
            }
        }
        if let (Some(t), Some(mut g)) = (table(16)?, table(20)?) {
            let mut p = t + 16;
            for _ in 0..r.i32(t)?.max(0) {
                let (w0, w1, dest) = (r.u32(p)?, r.u32(p + 4)?, r.u32(p + 8)?);
                let n = ((w0 >> 16) & 0xFF) as usize;
                let head = r.u32(g)?;
                let cnt = (head & 0x1F) as usize;
                let mut outs = Vec::with_capacity(cnt);
                for q in 0..cnt {
                    let d = r.u32(g + 4 + 4 * q)?;
                    outs.push(OutputWord { id: (d >> 26) & 0x1F, special: (d >> 21) & 0x1F, raw_angle: d & 0x8000_0000 != 0, offset: s16(d) });
                }
                sec.outputs.push(OutputRec { word0: w0, base: s16(w1 >> 16), dest, refs: r.words(p + 12, n)?, kind: (head >> 24) & 0xF, outs });
                g += (cnt + 1) * 4;
                p += (n + 3) * 4;
            }
        }
        if let Some(t) = table(24)? {
            let mut p = t + 16;
            for _ in 0..r.i32(t)?.max(0) {
                let w = r.words(p, 6)?;
                let n = ((w[1] >> 16) & 0xF) as usize;
                sec.envelopes.push(EnvelopeRec {
                    word0: w[0],
                    kind: (w[0] >> 24) & 0xF,
                    gated: w[0] & 0x100 != 0,
                    linear: w[0] & 0x200 != 0,
                    retrigger: w[0] & 0x400 != 0,
                    swing: w[1] as u16,
                    trigger: w[2],
                    attack: (w[3] & 0xFFF, (w[3] >> 12) & 0xF),
                    decay: ((w[4] >> 16) & 0xFFF, (w[4] >> 12) & 0xF),
                    hold: w[4] & 0xFFF,
                    release: (w[5] & 0xFFF, (w[5] >> 12) & 0xF),
                    sustain: (w[5] as i32) >> 16,
                    refs: r.words(p + 24, n)?,
                });
                p += (n + 6) * 4;
            }
        }
        Ok(sec)
    }
}
