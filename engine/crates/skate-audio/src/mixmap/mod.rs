//! The MixMap mixer (`MixMapSK8.mxb`), ported from the TU3 functions and file data.
//! `tests/retail_mixmap.rs` independently compares the native builder/tick instruction execution
//! across state sequences; `retail_mixmap_input.rs` exhaustively checks input shaping/conversion.
//! Earlier golden-cell tests compare two ports and are regression checks, not retail oracles.
//!
//! The game writes controller **inputs** (16 i32 words per controller: physics, 3-D positions,
//! menu / pause / music flags), calls [`MixMap::tick`] once per evaluation (the console's 30 Hz
//! cadence, [`cadence`]), and the audio objects
//! read **outputs** (16 u32 words per SFXObj controller, two 16-bit halves each: volumes as Q15,
//! pitch in cents, filter cutoffs in Hz, raw azimuths) through the owner readers
//! [`MixMap::level`], [`MixMap::raw`], [`MixMap::pitch_4096`], [`MixMap::filter_hz`].
//!
//! Evaluation order per tick (spec §5): input entries (in runs by curve kind) → A products → B
//! lookups → F envelopes → C sums → E sums → output conversion. References read whatever is stored,
//! so earlier records see this tick's values and later ones last tick's (retail's one-tick lags).
//! Integer math is i32 with wrapping, floats are f32 at every step (the spec's rounding rules).
pub mod cadence;
pub mod format;
pub mod keys;
pub mod tables;

use std::collections::HashMap;

pub use format::{FormatError, MixMapFile};
use format::Variant;
use keys::KEY_MASK;
use tables::{SILENT_MB, Tables, trunc};

/// Instances per slot in retail free skate (spec §4.1): Global 1, Player 2, Ambience 1,
/// Collision 10, Traffic 4, Pedestrian 15, Emitter 5, Crowd 5, Dynamic 5, Speaker 3, Whoosh 3,
/// ObjectInstance 0, NISCharacter 5, PlayerSpeech 7 = 247 controllers.
pub const RETAIL_INSTANCES: [usize; 14] = [1, 2, 1, 10, 4, 15, 5, 5, 5, 3, 3, 0, 5, 7];

/// A resolved reference.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Ref {
    Ctl(usize, usize),
    A(usize),
    B(usize),
    F(usize),
    C(usize),
    E(usize),
    Missing,
}

#[derive(Clone, Debug)]
struct Controller {
    key: u32,
    inputs: [i32; 16],
    outputs: [u32; 16],
    has_outputs: bool,
    /// Held inputs ([`MixMap::hold_input`]): bit `id` set = the next tick sees the largest value
    /// written since the last tick; `held` / `held_set` that value and whether one was written.
    hold: u16,
    held_set: u16,
    held: [i32; 16],
}

#[derive(Clone, Debug)]
struct Entry {
    key: u32,
    source: Ref,
    lin: i32,
    mb: i32,
}

#[derive(Clone, Debug)]
struct Product {
    input: usize,
    offset: i32,
    depth: i32,
    refs: Vec<Ref>,
    mb: i32,
}

#[derive(Clone, Debug)]
struct Lookup {
    variants: Vec<Variant>,
    variant: Variant,
    ctl: usize,
    angle: u32,
    mb: i32,
    lin: i32,
    doppler: i32,
}

#[derive(Clone, Debug)]
struct Envelope {
    kind: u32,
    gated: bool,
    linear: bool,
    retrigger: bool,
    boost: bool,
    curves: [u32; 3],
    sustain: i32,
    offset: i32,
    depth: i32,
    trigger: Ref,
    /// Attack, decay, hold, release in ms.
    ms: [f32; 4],
    refs: Vec<Ref>,
    stage: u32,
    elapsed: f32,
    start: i32,
    t0: f32,
    level: i32,
    mb: i32,
}

#[derive(Clone, Debug)]
struct Sum {
    min: i32,
    max: i32,
    refs: Vec<Ref>,
    value: i32,
}

#[derive(Clone, Debug)]
struct OutputSum {
    kind: u32,
    base: i32,
    dest: usize,
    special: Vec<usize>,
    outs: Vec<format::OutputWord>,
    refs: Vec<Ref>,
    value: i32,
}

/// Node identity during the build: (type, slot, group, index).
type NodeKey = (u8, u32, u32, u32);

pub struct MixMap {
    t: Tables,
    ctls: Vec<Controller>,
    by_key: HashMap<u32, usize>,
    entries: Vec<Entry>,
    order: Vec<usize>,
    products: Vec<Product>,
    lookups: Vec<Lookup>,
    envelopes: Vec<Envelope>,
    sums: Vec<Sum>,
    outputs: Vec<OutputSum>,
    /// Camera-state mode word (retail keeps −1: variant 0).
    pub mode: u32,
    dt_ms: f32,
    /// Ticks evaluated.
    pub ticks: u64,
    /// Controllers with held inputs ([`MixMap::hold_input`]).
    holding: Vec<usize>,
    /// The tick's saved last writes of the held inputs (kept between ticks: no allocation per tick).
    saved: Vec<(usize, u16, [i32; 16])>,
}

fn swing(t: &Tables, w: u16) -> (i32, i32) {
    if w & 0x8000 == 0 {
        let w = i32::from(w & 0x7FFF);
        (w, 32767 - t.mb_to_lin(-w))
    } else {
        (0, 32767 - t.mb_to_lin(i32::from(w as i16)))
    }
}

struct Builder<'a> {
    n: &'a [usize],
    ctls: Vec<Controller>,
    by_key: HashMap<u32, usize>,
}

impl Builder<'_> {
    fn ctl(&mut self, key: u32) -> usize {
        let key = key & KEY_MASK;
        if let Some(&i) = self.by_key.get(&key) {
            return i;
        }
        self.ctls.push(Controller { key, inputs: [0; 16], outputs: [0; 16], has_outputs: false, hold: 0, held_set: 0, held: [0; 16] });
        self.by_key.insert(key, self.ctls.len() - 1);
        self.ctls.len() - 1
    }

    /// Cross-slot references expand to every instance of the other slot (spec §4.2).
    fn expand(&self, refs: &[u32], own_slot: u32, group: u32) -> Vec<u32> {
        let mut out = Vec::with_capacity(refs.len());
        for &r in refs {
            let s = (r >> 16) & 0xFF;
            let base = r & 0xFFFF_07FF;
            if s == own_slot {
                out.push(base | (group << 11));
            } else {
                let count = self.n.get(s as usize).copied().unwrap_or(0) as u32;
                out.extend((0..count).map(|g| base | (g << 11)));
            }
        }
        out
    }
}

fn node_key(key: u32) -> Option<NodeKey> {
    let (top, s, g, idx) = (key >> 29, (key >> 16) & 0xFF, (key >> 11) & 0x1F, key & 0xFF);
    match top {
        0 => Some((0, s, g, idx)),
        1 => Some((1, s, g, idx | (key & 0x1000_0000))),
        4 => Some((4, s, g, idx)),
        5 => Some((5, s, g, idx)),
        _ => None,
    }
}

impl MixMap {
    /// Build the graph for `instances[slot]` game objects per slot.
    pub fn new(file: &MixMapFile, instances: &[usize]) -> Self {
        let t = Tables::generate();
        let mut b = Builder { n: instances, ctls: Vec::new(), by_key: HashMap::new() };
        let mut nodes: HashMap<NodeKey, (u8, usize)> = HashMap::new();
        let mut entries: Vec<Entry> = Vec::new();
        let mut entry_at: HashMap<u32, usize> = HashMap::new();
        // Raw (unresolved) references per node, resolved once every node exists.
        let mut products = Vec::new();
        let mut product_refs: Vec<Vec<u32>> = Vec::new();
        let mut lookups = Vec::new();
        let mut envelopes = Vec::new();
        let mut envelope_refs: Vec<(u32, Vec<u32>)> = Vec::new();
        let mut sums = Vec::new();
        let mut sum_refs: Vec<Vec<u32>> = Vec::new();
        let mut outputs = Vec::new();
        let mut output_refs: Vec<(Vec<u32>, Vec<u32>)> = Vec::new();
        let count = |s: usize| instances.get(s).copied().unwrap_or(0) as u32;

        for sec in file.slots.iter().flatten() {
            let s = sec.slot as u32;
            for j in 0..count(sec.slot) {
                for (k, a) in sec.products.iter().enumerate() {
                    let key = (a.input & 0xFFFF_07FF) | (j << 11);
                    let input = *entry_at.entry(key).or_insert_with(|| {
                        entries.push(Entry { key, source: Ref::Missing, lin: 32767, mb: 0 });
                        entries.len() - 1
                    });
                    let (offset, depth) = swing(&t, a.swing);
                    product_refs.push(b.expand(&a.refs, (a.input >> 16) & 0xFF, j));
                    products.push(Product { input, offset, depth, refs: Vec::new(), mb: 0 });
                    nodes.insert((0, s, j, k as u32), (0, products.len() - 1));
                }
                for (k, l) in sec.lookups.iter().enumerate() {
                    let ctl = b.ctl(0x6000_0000 | (j << 11) | (l.ctl & 0x1FFF_FFFF));
                    lookups.push(Lookup { variants: l.variants.clone(), variant: l.variants[0], ctl, angle: 0, mb: 0, lin: 32767, doppler: 0 });
                    nodes.insert((4, s, j, k as u32), (4, lookups.len() - 1));
                }
                for (k, f) in sec.envelopes.iter().enumerate() {
                    let (offset, depth) = swing(&t, f.swing);
                    let short = matches!(f.kind, 0..=2);
                    let frames = [
                        if short { f.attack.0.max(1) } else { f.attack.0 },
                        f.decay.0,
                        if f.kind == 1 { f.hold.max(1) } else { f.hold },
                        if short { f.release.0.max(1) } else { f.release.0 },
                    ];
                    envelope_refs.push((f.trigger | (j << 11), b.expand(&f.refs, (f.word0 >> 16) & 0xFF, j)));
                    envelopes.push(Envelope {
                        kind: f.kind,
                        gated: f.gated,
                        linear: f.linear,
                        retrigger: f.retrigger,
                        boost: (f.swing as i16) > 0,
                        curves: [f.attack.1, f.decay.1, f.release.1],
                        sustain: f.sustain,
                        offset,
                        depth,
                        trigger: Ref::Missing,
                        ms: frames.map(|n| n as f32 * t.k_frame_ms),
                        refs: Vec::new(),
                        stage: 0,
                        elapsed: 0.0,
                        start: 0,
                        t0: 0.0,
                        level: 0,
                        mb: 0,
                    });
                    nodes.insert((5, s, j, k as u32), (5, envelopes.len() - 1));
                }
            }
        }
        for sec in file.slots.iter().flatten() {
            let s = sec.slot as u32;
            for j in 0..count(sec.slot) {
                for (k, c) in sec.sums.iter().enumerate() {
                    sum_refs.push(b.expand(&c.refs, s, j));
                    sums.push(Sum { min: c.min, max: c.max, refs: Vec::new(), value: 0 });
                    nodes.insert((1, s, j, k as u32 | 0x1000_0000), (1, sums.len() - 1));
                }
                for (k, e) in sec.outputs.iter().enumerate() {
                    let specials = e.refs.iter().filter(|&&r| r >> 29 == 4).count();
                    let special: Vec<u32> = e.refs[..specials].iter().map(|&r| (r & 0xFFFF_07FF) | (j << 11)).collect();
                    let dest = b.ctl(e.dest | (j << 11));
                    if !b.ctls[dest].has_outputs {
                        b.ctls[dest].has_outputs = true;
                        b.ctls[dest].outputs[keys::ENABLE_WORD] = 1;
                    }
                    output_refs.push((special, b.expand(&e.refs[specials..], s, j)));
                    outputs.push(OutputSum { kind: e.kind, base: e.base, dest, special: Vec::new(), outs: e.outs.clone(), refs: Vec::new(), value: SILENT_MB });
                    nodes.insert((1, s, j, k as u32), (2, outputs.len() - 1));
                }
            }
        }
        let resolve = |b: &mut Builder, key: u32| -> Ref {
            match key >> 29 {
                2 | 3 => Ref::Ctl(b.ctl(key), (key & 0xF) as usize),
                _ => match node_key(key).and_then(|nk| nodes.get(&nk)) {
                    Some(&(0, i)) => Ref::A(i),
                    Some(&(4, i)) => Ref::B(i),
                    Some(&(5, i)) => Ref::F(i),
                    Some(&(1, i)) => Ref::C(i),
                    Some(&(2, i)) => Ref::E(i),
                    _ => Ref::Missing,
                },
            }
        };
        for e in &mut entries {
            e.source = resolve(&mut b, e.key);
        }
        for (p, refs) in products.iter_mut().zip(product_refs) {
            p.refs = refs.into_iter().map(|r| resolve(&mut b, r)).collect();
        }
        for (f, (trigger, refs)) in envelopes.iter_mut().zip(envelope_refs) {
            f.trigger = resolve(&mut b, trigger);
            f.refs = refs.into_iter().map(|r| resolve(&mut b, r)).collect();
        }
        for (c, refs) in sums.iter_mut().zip(sum_refs) {
            c.refs = refs.into_iter().map(|r| resolve(&mut b, r)).collect();
        }
        for (e, (special, refs)) in outputs.iter_mut().zip(output_refs) {
            e.special = special
                .into_iter()
                .filter_map(|k| match resolve(&mut b, k) {
                    Ref::B(i) => Some(i),
                    _ => None,
                })
                .collect();
            e.refs = refs.into_iter().map(|r| resolve(&mut b, r)).collect();
        }
        // Input entries run in curve-kind order, first use order within a kind (spec §4.3).
        let mut order: Vec<usize> = (0..entries.len()).collect();
        order.sort_by_key(|&i| (entries[i].key >> 24) & 0xF);
        Self {
            t,
            ctls: b.ctls,
            by_key: b.by_key,
            entries,
            order,
            products,
            lookups,
            envelopes,
            sums,
            outputs,
            mode: u32::MAX,
            dt_ms: 0.0,
            ticks: 0,
            holding: Vec::new(),
            saved: Vec::new(),
        }
    }

    /// Parse and build with the retail instance counts.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, FormatError> {
        Ok(Self::new(&MixMapFile::parse(bytes)?, &RETAIL_INSTANCES))
    }

    pub fn tables(&self) -> &Tables {
        &self.t
    }

    /// Number of controllers (retail free skate: 247).
    pub fn controller_count(&self) -> usize {
        self.ctls.len()
    }

    /// (input entries, A, B, F, C, E) counts.
    pub fn counts(&self) -> [usize; 6] {
        [self.entries.len(), self.products.len(), self.lookups.len(), self.envelopes.len(), self.sums.len(), self.outputs.len()]
    }

    /// Every controller key (type + slot + group + object).
    pub fn controller_keys(&self) -> impl Iterator<Item = u32> + '_ {
        self.ctls.iter().map(|c| c.key)
    }

    /// Output blocks.
    pub fn output_blocks(&self) -> usize {
        self.ctls.iter().filter(|c| c.has_outputs).count()
    }

    fn find(&self, key: u32) -> Option<usize> {
        self.by_key.get(&(key & KEY_MASK)).copied()
    }

    /// Whether a controller with this key exists in the built graph.
    pub fn has_controller(&self, key: u32) -> bool {
        self.find(key).is_some()
    }

    /// Write one input word (`id` 0..15). Unknown controllers are ignored (nothing reads them).
    pub fn set_input(&mut self, key: u32, id: usize, value: i32) {
        if let (Some(i), true) = (self.find(key), id < 16) {
            let c = &mut self.ctls[i];
            c.inputs[id] = value;
            let bit = 1u16 << id;
            if c.hold & bit != 0 {
                c.held[id] = if c.held_set & bit != 0 { c.held[id].max(value) } else { value };
                c.held_set |= bit;
            }
        }
    }

    /// Hold an input between ticks: the next [`MixMap::tick`] sees the largest value written to it
    /// since the last tick (the stored input keeps the last write). For one-frame flags (0 / 32767)
    /// written by a host that writes its inputs more often than it ticks — the console cadence,
    /// where retail's writers run once per evaluation and see such a flag over the whole frame.
    /// Returns false for an unknown controller or id.
    pub fn hold_input(&mut self, key: u32, id: usize) -> bool {
        let Some(i) = self.find(key).filter(|_| id < 16) else { return false };
        self.ctls[i].hold |= 1 << id;
        if !self.holding.contains(&i) {
            self.holding.push(i);
        }
        true
    }

    pub fn set_input_f32(&mut self, key: u32, id: usize, value: f32) {
        self.set_input(key, id, value.to_bits() as i32);
    }

    pub fn input(&self, key: u32, id: usize) -> i32 {
        self.find(key).filter(|_| id < 16).map_or(0, |i| self.ctls[i].inputs[id])
    }

    /// Enable or disable an output block (word 15 bit 0).
    pub fn set_enabled(&mut self, key: u32, on: bool) {
        if let Some(i) = self.find(key) {
            let w = &mut self.ctls[i].outputs[keys::ENABLE_WORD];
            *w = (*w & !1) | u32::from(on);
        }
    }

    /// The output half `id` as the owners load it: even ids the whole word (callers mask), odd
    /// ids the high half, arithmetic shift.
    pub fn half(&self, key: u32, id: usize) -> i32 {
        let Some(i) = self.find(key) else { return 0 };
        let w = self.ctls[i].outputs[(id >> 1) & 15] as i32;
        if id & 1 == 1 { w >> 16 } else { w }
    }

    /// Owner vfunc60 / vfunc64: a level (Q15, /32767) or a filter cutoff (Hz).
    pub fn level(&self, key: u32, id: usize) -> i32 {
        self.half(key, id) & 0x7FFF
    }

    pub fn filter_hz(&self, key: u32, id: usize) -> i32 {
        self.level(key, id)
    }

    /// Owner vfunc52: a raw u16 (azimuth, 65536 = 360°).
    pub fn raw(&self, key: u32, id: usize) -> i32 {
        self.half(key, id) & 0xFFFF
    }

    /// Owner vfunc56: pitch with 4096 = 1.0.
    pub fn pitch_4096(&self, key: u32, id: usize) -> i32 {
        self.t.pitch_4096(i32::from(self.half(key, id) as i16))
    }

    fn value(&self, r: Ref, mb: bool) -> i32 {
        match r {
            Ref::Ctl(c, id) => self.ctls[c].inputs[id],
            Ref::A(i) => {
                let p = &self.products[i];
                if mb { p.mb } else { self.entries[p.input].lin }
            }
            Ref::B(i) => {
                let l = &self.lookups[i];
                if mb { l.mb } else { l.lin }
            }
            Ref::F(i) => {
                let f = &self.envelopes[i];
                if mb { f.mb } else { f.level }
            }
            Ref::C(i) => self.sums[i].value,
            Ref::E(i) => self.outputs[i].value,
            Ref::Missing => 0,
        }
    }

    fn scale(&self, refs: &[Ref]) -> i32 {
        refs.iter().fold(32767i32, |acc, &r| self.value(r, false).wrapping_mul(acc) >> 15)
    }

    /// One evaluation with frame time `dt` seconds: retail evaluates once per audio-manager pass,
    /// on the ~30 fps console with the frame's dt (≈ 1/30; [`cadence`]); envelopes use `dt`, the
    /// Doppler slew is per evaluation.
    pub fn tick(&mut self, dt: f32) {
        // Held inputs: evaluate with the largest value since the last tick, then restore the last
        // write (so the next tick sees only what is written after this one).
        let mut saved = std::mem::take(&mut self.saved);
        saved.clear();
        for &i in &self.holding {
            let c = &mut self.ctls[i];
            if c.held_set != 0 {
                saved.push((i, c.held_set, c.inputs));
                for id in 0..16 {
                    if c.held_set & (1 << id) != 0 {
                        c.inputs[id] = c.inputs[id].max(c.held[id]);
                    }
                }
                c.held_set = 0;
            }
        }
        self.evaluate(dt);
        for &(i, set, inputs) in &saved {
            let c = &mut self.ctls[i];
            for id in 0..16 {
                if set & (1 << id) != 0 {
                    c.inputs[id] = inputs[id];
                }
            }
        }
        self.saved = saved;
    }

    fn evaluate(&mut self, dt: f32) {
        self.dt_ms = dt * 1000.0;
        for k in 0..self.order.len() {
            let i = self.order[k];
            let raw = self.value(self.entries[i].source, false);
            let lin = self.t.shape(raw, (self.entries[i].key >> 24) & 0xF);
            let e = &mut self.entries[i];
            e.lin = lin;
            e.mb = self.t.lin_to_mb(lin);
        }
        for i in 0..self.products.len() {
            let p = &self.products[i];
            let lin = self.entries[p.input].lin;
            let x = 32767i32.wrapping_sub(32767i32.wrapping_sub(lin).wrapping_mul(p.depth) >> 15);
            let mb = p.offset.wrapping_add(self.t.lin_to_mb(x));
            let acc = self.scale(&p.refs);
            self.products[i].mb = acc.wrapping_mul(mb) >> 15;
        }
        self.lookups_tick();
        self.envelopes_tick();
        for i in 0..self.sums.len() {
            let v = self.sums[i].refs.iter().fold(0i32, |s, &r| s.wrapping_add(self.value(r, true)));
            let c = &mut self.sums[i];
            c.value = v.min(c.max).max(c.min);
        }
        for i in 0..self.outputs.len() {
            let e = &self.outputs[i];
            let v = if self.ctls[e.dest].outputs[keys::ENABLE_WORD] & 1 == 0 {
                SILENT_MB
            } else {
                e.refs.iter().fold(e.base, |s, &r| s.wrapping_add(self.value(r, true)))
            };
            self.outputs[i].value = v;
        }
        self.write_outputs();
        self.ticks += 1;
    }

    fn lookups_tick(&mut self) {
        let mode = self.mode;
        for i in 0..self.lookups.len() {
            let l = &mut self.lookups[i];
            if mode != u32::MAX {
                l.variant = l.variants.iter().copied().find(|v| v.mode == mode & 0xF).unwrap_or(l.variants[0]);
            }
            let blk = &mut self.ctls[l.ctl].inputs;
            let fl = |w: usize| f32::from_bits(blk[w] as u32);
            if blk[keys::pos::FLAGS] & 1 == 0 {
                (l.mb, l.lin, l.angle, l.doppler) = (SILENT_MB, 0, 0, 0);
                continue;
            }
            let v = l.variant;
            let x = match v.dist_sel {
                0 => fl(keys::pos::DIST_CAMERA),
                1 => fl(keys::pos::DIST_SKATER),
                _ => -1.0,
            };
            let ang = match v.angle_sel {
                0 => blk[keys::pos::AZ_CAMERA],
                1 => blk[keys::pos::AZ_SKATER],
                _ => 0,
            } as u32;
            l.angle = ang;
            let q = (ang >> 14) & 3;
            let frac = (ang as i32).wrapping_sub(16384 * q as i32);
            let (d0, d1) = [(0, 1), (1, 2), (2, 3), (3, 0)][q as usize];
            let kind = v.curves[q as usize];
            let ((mn0, mx0), (mn1, mx1)) = (v.ranges[d0], v.ranges[d1]);
            let (mn0, mx0, mn1, mx1) = (mn0 as f32, mx0 as f32, mn1 as f32, mx1 as f32);
            if x > mx0 && x > mx1 {
                (l.mb, l.lin, l.doppler) = (SILENT_MB, 0, 0);
                continue;
            }
            let clamp = |x: f32, lo: f32, hi: f32| {
                let v = if lo > x { lo } else { x };
                if hi < v { hi } else { v }
            };
            let ratio = |x: f32, lo: f32, hi: f32| if hi != lo { trunc(((x - lo) / (hi - lo)) * 32767.0) } else { 0 };
            let ra = ratio(clamp(x, mn0, mx0), mn0, mx0);
            let rb = ratio(clamp(x, mn1, mx1), mn1, mx1);
            let ca = self.t.shape(ra, kind);
            let cb = if frac != 0 { self.t.shape(rb, kind) } else { 32767 };
            let w = frac.wrapping_shl(1);
            l.lin = (32767i32.wrapping_sub(w).wrapping_mul(ca) >> 15).wrapping_add(w.wrapping_mul(cb) >> 15);
            l.mb = self.t.lin_to_mb(l.lin);
            let c = v.doppler;
            if c == 0 {
                continue;
            }
            let (flag, speed) = if v.dist_sel == 1 { (0x8000_0000u32, fl(keys::pos::SPEED_SKATER)) } else { (0x4000_0000, fl(keys::pos::SPEED_CAMERA)) };
            let target = if blk[keys::pos::FLAGS] as u32 & flag != 0 {
                blk[keys::pos::FLAGS] = (blk[keys::pos::FLAGS] as u32 & !flag) as i32;
                0
            } else {
                let mut span = speed + c as f32;
                if !(span > 0.0) {
                    span = c as f32;
                }
                self.t.ratio_to_cents(c as f32 / span)
            };
            let step = trunc((i64::from(target) - i64::from(l.doppler)) as f32 * -0.2f32);
            l.doppler = l.doppler.wrapping_sub(step);
        }
    }

    fn envelopes_tick(&mut self) {
        for i in 0..self.envelopes.len() {
            let trig = self.value(self.envelopes[i].trigger, false) != 0;
            let f = &mut self.envelopes[i];
            if f.stage == 0 && !trig {
                (f.elapsed, f.start, f.t0, f.stage, f.level) = (0.0, 0, 0.0, 0, 0);
                f.mb = if f.linear { SILENT_MB } else { 0 };
                continue;
            }
            f.elapsed += self.dt_ms;
            // TU3 82950250 dispatches only AR (0), AHR (1), and ADSR (3).
            // Other authored kinds retain their state/level; they do not enter an attack.
            if matches!(f.kind, 0 | 1 | 3) {
                step_envelope(&self.t, f, trig);
            }
            let t = &self.t;
            f.mb = if f.linear {
                t.lin_to_mb(f.level)
            } else {
                let scaled = f.level.wrapping_mul(f.depth) >> 15;
                if f.boost {
                    f.offset.wrapping_add(t.lin_to_mb(scaled.wrapping_sub(f.depth).wrapping_add(32767)))
                } else {
                    t.lin_to_mb(32767i32.wrapping_sub(scaled))
                }
            };
            if !self.envelopes[i].refs.is_empty() {
                let acc = self.scale(&self.envelopes[i].refs);
                let t = &self.t;
                let f = &mut self.envelopes[i];
                f.mb = if f.linear { t.lin_to_mb(t.mb_to_lin(f.mb).wrapping_mul(acc) >> 15) } else { f.mb.wrapping_mul(acc) >> 15 };
            }
        }
    }

    fn write_outputs(&mut self) {
        for i in 0..self.outputs.len() {
            let e = &self.outputs[i];
            let dest = e.dest;
            let put = |blk: &mut [u32; 16], id: u32, v: i32| {
                let (w, sh) = ((id >> 1) as usize & 15, if id & 1 == 1 { 16 } else { 0 });
                blk[w] = (blk[w] & !(0xFFFF << sh)) | (((v as u32) & 0xFFFF) << sh);
            };
            if self.ctls[dest].outputs[keys::ENABLE_WORD] & 1 == 0 {
                if let Some(o) = e.outs.first() {
                    let v = match e.kind {
                        1 => 0,
                        2 => 25000,
                        _ => SILENT_MB,
                    };
                    put(&mut self.ctls[dest].outputs, o.id, v);
                }
                continue;
            }
            for o in &e.outs {
                let v = e.value.wrapping_add(o.offset);
                let val = if let Some(&b) = e.special.get(o.special as usize) {
                    let b = &self.lookups[b];
                    if o.raw_angle {
                        put(&mut self.ctls[dest].outputs, o.id, (b.angle & 0xFFFF) as i32);
                        continue;
                    }
                    match e.kind {
                        0 | 4 => self.t.mb_to_lin(b.mb.wrapping_add(v).clamp(SILENT_MB, 0)),
                        1 => {
                            let x = b.doppler.wrapping_add(v);
                            if x > 2400 {
                                2400
                            } else if x < -4800 {
                                0
                            } else {
                                x
                            }
                        }
                        2 => v.clamp(SILENT_MB, 0),
                        _ => e.value,
                    }
                } else {
                    match e.kind {
                        0 | 4 => self.t.mb_to_lin(v.clamp(SILENT_MB, 0)),
                        1 => v.clamp(-4800, 2400),
                        2 => trunc(self.t.cents_ratio(v.clamp(SILENT_MB, 0)) * 25000.0),
                        _ => v.clamp(0, 25000),
                    }
                };
                put(&mut self.ctls[dest].outputs, o.id, val);
            }
        }
    }
}

/// The envelope stage machine (spec §5.4), one evaluation.
fn step_envelope(t: &Tables, f: &mut Envelope, trig: bool) {
    let [a_ms, d_ms, h_ms, r_ms] = f.ms;
    let [ca, cd, cr] = f.curves;
    let kind = f.kind;
    let progress = |f: &Envelope, span: f32| {
        let sp = span - f.t0;
        let x = f.elapsed - f.t0;
        if sp > 0.0 { x / sp } else { x }
    };
    let enter = |f: &mut Envelope, stage: u32, level: i32| {
        (f.elapsed, f.stage, f.t0, f.start) = (0.0, stage, 0.0, level);
    };
    let carry = |f: &mut Envelope, stage: u32, from: f32, to: f32| {
        f.stage = stage;
        f.start = f.level;
        let x = if from < t.k_min_ramp { to } else { ((from - f.elapsed) / from) * to };
        (f.t0, f.elapsed) = (x, x);
    };
    for _ in 0..16 {
        let s = f.stage;
        if (kind == 3 && s > 3) || (kind != 3 && s >= 4) || (kind == 0 && s > 1) {
            if !(f.elapsed < r_ms) {
                (f.elapsed, f.t0, f.start, f.stage, f.level, f.mb) = (0.0, 0.0, 0, 0, 0, 0);
                return;
            }
            if !trig || !f.retrigger {
                let c = t.curve01(cr, 1.0 - progress(f, r_ms));
                let start = f.start;
                f.level = if kind == 0 { start - trunc(c * start as f32) } else { start - trunc((1.0 - c) * start as f32) };
                return;
            }
            carry(f, 1, r_ms, a_ms);
            continue;
        }
        if s == 0 {
            f.stage = 1;
        }
        if s <= 1 {
            if kind != 0 && f.gated && !trig {
                carry(f, 4, a_ms, r_ms);
                continue;
            }
            if f.elapsed < a_ms {
                if (kind == 3 && !(a_ms > t.k_min_ramp)) || (kind != 3 && a_ms == 0.0) {
                    f.level = 32767;
                    return;
                }
                let c = t.curve01(ca, progress(f, a_ms));
                f.level = trunc(c * (32767 - f.start) as f32) + f.start;
                return;
            }
            enter(f, if kind == 0 { 4 } else if kind == 1 { 3 } else { 2 }, 32767);
            continue;
        }
        if kind == 1 && s == 3 {
            if (!trig && f.gated) || (!f.gated && f.elapsed > h_ms) {
                enter(f, 4, 32767);
                continue;
            }
            f.level = 32767;
            if f.gated {
                f.elapsed = 0.0;
            }
            return;
        }
        if kind == 3 && s == 2 {
            if !trig && f.gated {
                f.stage = 4;
                let x = ((d_ms - f.elapsed) / d_ms) * r_ms;
                (f.start, f.t0, f.elapsed) = (f.level, x, x);
                continue;
            }
            if !(f.elapsed > d_ms) {
                let c = t.curve01(cd, 1.0 - progress(f, d_ms));
                f.level = trunc((1.0 - c) * (f.sustain - f.start) as f32) + f.start;
                return;
            }
            enter(f, 3, f.sustain);
            continue;
        }
        if kind == 3 && s == 3 {
            if (!trig && f.gated) || (!f.gated && f.elapsed > h_ms) {
                enter(f, 4, f.sustain);
                continue;
            }
            f.level = f.sustain;
            if f.gated {
                f.elapsed = 0.0;
            }
            return;
        }
        return;
    }
}

#[cfg(test)]
mod tests;
