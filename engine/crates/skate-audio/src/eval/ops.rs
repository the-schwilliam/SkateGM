//! The self-contained opcodes: everything that only reads and writes its own block (plus the bank's
//! tables, the shared RNG and the tick scale). Behaviour per `audio-specs/aems-evaluator-spec.md`
//! §4; the ops that touch other objects (0–5, 27, 37–39) live in `eval/mod.rs`.
//!
//! Every word is an i32 with wrapping arithmetic; floats are f32 with one rounding per operation.
use super::fmath::{fused, quarter_sine, round, trunc};
use super::rng::Rng;
use crate::be::*;

pub struct Ctx<'a> {
    /// The bank's bytes (TABLE pointers are bank offsets).
    pub bank: &'a [u8],
    pub rng: &'a mut Rng,
    /// Tick length in ms (f32 31.999998 in play).
    pub tick: f32,
}

#[inline]
fn w(m: &[u8], at: usize) -> i32 {
    i32_at(m, at)
}

/// Run a self-contained op on the block at `b`; None for the opcodes handled by the evaluator.
pub fn run(opcode: u8, m: &mut [u8], b: usize, ctx: &mut Ctx) -> Option<i32> {
    Some(match opcode {
        6 => counter(m, b),
        7 => random(m, b, ctx),
        8 => shuffle(m, b, ctx),
        9 => weighted(m, b, ctx),
        10 => range_trigger(m, b),
        11 => delay_trigger(m, b, ctx.tick),
        12 => state_generator(m, b),
        13 => {
            let n = u8_at(m, b) as usize;
            i32::from((0..n).any(|i| w(m, b + 4 + 4 * i) != 0))
        }
        14 => envelope(m, b, ctx.tick),
        15 => table(m, b, ctx.bank),
        16 => delay_line(m, b, ctx.tick),
        17 => {
            let n = u8_at(m, b) as i32;
            let control = w(m, b + 4);
            if (1..=n).contains(&control) { w(m, b + 8 + 4 * (control - 1) as usize) } else { 0 }
        }
        18 => demux(m, b),
        19 | 20 => {
            let n = (u8_at(m, b) as usize).max(1);
            let it = (0..n).map(|i| w(m, b + 4 + 4 * i));
            if opcode == 19 { it.min().unwrap_or(0) } else { it.max().unwrap_or(0) }
        }
        21 => {
            let n = u8_at(m, b) as usize;
            let scale = f32_at(m, b + 4);
            let mut acc = w(m, b + 8) as f32;
            for i in 1..n {
                acc *= w(m, b + 8 + 4 * i) as f32;
            }
            round(scale * acc)
        }
        22 => {
            let n = (u8_at(m, b) as usize).max(1);
            (0..n).fold(0i32, |s, i| s.wrapping_add(w(m, b + 4 + 4 * i)))
        }
        23 => w(m, b).wrapping_sub(w(m, b + 4)),
        24 => w(m, b).wrapping_mul(w(m, b + 4)),
        25 => divide(w(m, b), w(m, b + 4)),
        26 => {
            let (a, d) = (w(m, b), w(m, b + 4));
            if d == 0 { 0 } else { a.wrapping_sub(divide(a, d).wrapping_mul(d)) }
        }
        28 => oscillator(m, b, ctx.tick),
        29 => ramp(m, b, ctx.tick),
        30 => {
            let n = (u8_at(m, b) as usize).max(1);
            let sum = (0..n).fold(0i32, |s, i| s.wrapping_add(w(m, b + 8 + 4 * i)));
            sum.min(w(m, b + 4))
        }
        31 => w(m, b + 4).wrapping_sub(w(m, b + 8)).max(w(m, b)),
        32 => w(m, b + 4).wrapping_mul(w(m, b + 8)).min(w(m, b)),
        33 => w(m, b).min(w(m, b + 4)),
        34 => w(m, b).max(w(m, b + 4)),
        35 => {
            let s = f32_at(m, b);
            round((w(m, b + 8) as f32 * w(m, b + 4) as f32) * s)
        }
        36 => w(m, b).wrapping_add(w(m, b + 4)),
        _ => return None,
    })
}

/// Integer division with the retail guards: x/0 = 0 and i32::MIN/−1 = 0; truncates toward zero.
fn divide(a: i32, b: i32) -> i32 {
    if b == 0 || (a == i32::MIN && b == -1) { 0 } else { a / b }
}

/// Op 6 Counter: +0 min, +4 max, +8 value, +12 s8 step, +16 trigger, +20 override.
fn counter(m: &mut [u8], b: usize) -> i32 {
    let (min, max, ovr) = (w(m, b), w(m, b + 4), w(m, b + 20));
    if min <= ovr && ovr <= max {
        return ovr;
    }
    let mut value = w(m, b + 8);
    if w(m, b + 16) > 0 {
        value = value.wrapping_add(i32::from(i8_at(m, b + 12)));
        if value > max {
            value = min;
        } else if value < min {
            value = max;
        }
        put_i32(m, b + 8, value);
    }
    value
}

/// Op 7 Random: +0 min, +4 range, +8 current, +12 trigger.
fn random(m: &mut [u8], b: usize, ctx: &mut Ctx) -> i32 {
    if w(m, b + 12) != 0 {
        let (min, range) = (w(m, b), u32_at(m, b + 4));
        let r = ctx.rng.draw();
        let pick = if range == 0 { r } else { r % range };
        put_i32(m, b + 8, min.wrapping_add(pick as i32));
    }
    w(m, b + 8)
}

/// Op 8 RandomShuffle: draws without repeats from the number set; the last pick of a pass is kept
/// out of the next pass's first pick.
fn shuffle(m: &mut [u8], b: usize, ctx: &mut Ctx) -> i32 {
    let trigger_at = b + u16_at(m, b) as usize;
    if w(m, trigger_at) == 0 {
        return w(m, b + 12);
    }
    let wide = u8_at(m, b + 2) != 1;
    let avoid = i32::from(i8_at(m, b + 3));
    let index = i32::from(u16_at(m, b + 8));
    let range = i32::from(u16_at(m, b + 10));
    let span = range - avoid - index;
    let r = ctx.rng.draw();
    // Span 0 never occurs on disc (retail would divide by zero); pick the slot at `index`.
    let k = index + if span > 0 { (r % span as u32) as i32 } else { 0 };
    let set = b + 16;
    let (at_k, at_i) = if wide { (set + 2 * k as usize, set + 2 * index as usize) } else { (set + k as usize, set + index as usize) };
    let (vk, vi) = if wide { (u16_at(m, at_k) as i32, u16_at(m, at_i) as i32) } else { (u8_at(m, at_k) as i32, u8_at(m, at_i) as i32) };
    if wide {
        put_u16(m, at_k, vi as u16);
        put_u16(m, at_i, vk as u16);
    } else {
        put_u8(m, at_k, vi as u8);
        put_u8(m, at_i, vk as u8);
    }
    let current = vk.wrapping_add(w(m, b + 4));
    put_i32(m, b + 12, current);
    let next = index + 1;
    if next >= range {
        put_u16(m, b + 8, 0);
        put_u8(m, b + 3, 1);
    } else {
        put_u16(m, b + 8, next as u16);
        put_u8(m, b + 3, 0);
    }
    current
}

/// Op 9 RandomWeighted: +0 TABLE (s8 weights), +4 min, +8 count, +12 current, +16 trigger.
fn weighted(m: &mut [u8], b: usize, ctx: &mut Ctx) -> i32 {
    if w(m, b + 16) != 0 {
        let table = u32_at(m, b) as usize;
        let r = ctx.rng.draw() % 100;
        let mut sum = 0i32;
        for i in 0..w(m, b + 8).max(0) as usize {
            sum = sum.wrapping_add(i32::from(i8_at(ctx.bank, table + 16 + i)));
            if sum as u32 > r {
                put_i32(m, b + 12, w(m, b + 4).wrapping_add(i as i32));
                break;
            }
        }
    }
    w(m, b + 12)
}

/// Op 10 RangeTrigger: +0/+4 trip range, +8/+12 reset range, +16 s8 tripped, +17 s8 output, +20 input.
fn range_trigger(m: &mut [u8], b: usize) -> i32 {
    let input = w(m, b + 20);
    let in_trip = w(m, b) <= input && input <= w(m, b + 4);
    if in_trip && i8_at(m, b + 16) == 0 {
        put_u8(m, b + 16, 1);
        put_u8(m, b + 17, 1);
        return 1;
    }
    if !in_trip && w(m, b + 8) <= input && input <= w(m, b + 12) {
        put_u8(m, b + 16, 0);
    }
    put_u8(m, b + 17, 0);
    0
}

/// Op 11 DelayTrigger: +0 f32 time (−1 idle), +4 s8 output, +8 restart trigger, +12 delay ms.
fn delay_trigger(m: &mut [u8], b: usize, tick: f32) -> i32 {
    if w(m, b + 8) != 0 {
        put_f32(m, b, 0.0);
    }
    let time = f32_at(m, b);
    if time < 0.0 {
        return 0;
    }
    if time >= w(m, b + 12) as f32 {
        put_u8(m, b + 4, 1);
        put_f32(m, b, -1.0);
        return 1;
    }
    put_f32(m, b, time + tick);
    put_u8(m, b + 4, 0);
    0
}

/// Op 12 StateGenerator: +0 u16 self-relative offset of the triggers, +2 u8 n, +4 current, +8 values.
fn state_generator(m: &mut [u8], b: usize) -> i32 {
    let triggers = b + u16_at(m, b) as usize;
    let n = u8_at(m, b + 2) as usize;
    if let Some(i) = (0..n).find(|&i| w(m, triggers + 4 * i) != 0) {
        put_i32(m, b + 4, w(m, b + 8 + 4 * i));
    }
    w(m, b + 4)
}

/// Op 14 Envelope (§4.1).
fn envelope(m: &mut [u8], b: usize, tick: f32) -> i32 {
    let control = w(m, b + u16_at(m, b) as usize);
    let prev = i8_at(m, b + 2);
    let mut segment = u8_at(m, b + 3);
    let mut remaining = f32_at(m, b + 4);
    let mut delta = f32_at(m, b + 8);
    let mut output = f32_at(m, b + 12);
    let count = u8_at(m, b + 16);
    let release = i16_at(m, b + 18);
    let duration = |s: u8| f32_at(m, b + 24 + 8 * s as usize);
    let target = |s: u8| f32_at(m, b + 28 + 8 * s as usize);
    let program = |s: u8, from: f32, remaining: &mut f32, delta: &mut f32| {
        let d = duration(s);
        *remaining = d;
        *delta = ((target(s) - from) / d) * tick;
    };
    if control == 1 && prev == 0 {
        output = f32_at(m, b + 20);
        segment = 0;
        program(0, output, &mut remaining, &mut delta);
    } else if control == 3 && prev != 3 && i16::from(segment) < release {
        segment = release as u8;
        program(segment, output, &mut remaining, &mut delta);
    } else if control == 1 || control == 3 {
        if segment < count {
            remaining -= tick;
            if remaining > 0.0 {
                output += delta;
            } else {
                output = target(segment);
                segment += 1;
                if segment < count {
                    program(segment, target(segment - 1), &mut remaining, &mut delta);
                } else {
                    output = 0.0;
                }
            }
        }
        if segment >= count {
            output = 0.0;
        }
    } else if control != 2 {
        output = 0.0;
    }
    put_u8(m, b + 3, segment);
    put_f32(m, b + 4, remaining);
    put_f32(m, b + 8, delta);
    put_f32(m, b + 12, output);
    // prevcontrol = low byte of the control word, re-read after the stores (the word may lie inside
    // this block).
    let control = w(m, b + u16_at(m, b) as usize);
    put_u8(m, b + 2, control as u8);
    round(output)
}

/// A TABLE entry (sign-extended), at a possibly negative index (op 15's i0 can be −1).
fn entry(bank: &[u8], table: usize, size: u8, index: i64) -> i32 {
    let width = match size {
        1 => 1,
        2 => 2,
        _ => 4,
    };
    let at = table as i64 + 16 + index * width;
    if at < 0 {
        return 0;
    }
    let at = at as usize;
    match size {
        1 => i32::from(i8_at(bank, at)),
        2 => i32::from(i16_at(bank, at)),
        _ => i32_at(bank, at),
    }
}

/// Op 15 Table (§4.2): +0 TABLE, +4 previous input, +8 output, +12 input.
fn table(m: &mut [u8], b: usize, bank: &[u8]) -> i32 {
    let input = w(m, b + 12);
    if input == w(m, b + 4) {
        return w(m, b + 8);
    }
    put_i32(m, b + 4, input);
    let t = u32_at(m, b) as usize;
    let size = u8_at(bank, t);
    let count = i64::from(u16_at(bank, t + 2));
    let (min, max) = (i32_at(bank, t + 4), i32_at(bank, t + 8));
    let resolution = f32_at(bank, t + 12);
    let idx = input.clamp(min, max.max(min)).wrapping_sub(min);
    let output = if resolution == 1.0 {
        entry(bank, t, size, i64::from(idx))
    } else {
        let x = idx as f32 * resolution;
        let i0 = round(x - 0.5);
        let frac = x - i0 as f32;
        let i1 = (i64::from(i0) + 1).min(count - 1);
        let e0 = entry(bank, t, size, i64::from(i0)) as f32;
        let e1 = entry(bank, t, size, i1) as f32;
        round(fused(e1 - e0, frac, e0))
    };
    put_i32(m, b + 8, output);
    output
}

/// Op 16 DelayLine (§4.3): +0 u16 self-relative offset of {value, delay ms}, +2 u16 slots,
/// +4 u16 in, +6 u16 out, +8 previous delay, +12 ring.
fn delay_line(m: &mut [u8], b: usize, tick: f32) -> i32 {
    let input = b + u16_at(m, b) as usize;
    let value = w(m, input);
    let mut delay = w(m, input + 4);
    let slots = u16_at(m, b + 2);
    let mut write = u16_at(m, b + 4);
    let mut read = u16_at(m, b + 6);
    if delay != w(m, b + 8) {
        put_i32(m, b + 8, delay);
        if delay < 0 {
            // Retail writes 0 back into the input word. [?] We also use 0 for this walk's offset.
            put_i32(m, input + 4, 0);
            delay = 0;
        }
        let mut offset = trunc((delay as f32 / tick) + 0.5);
        if offset >= i32::from(slots) {
            offset = i32::from(slots) - 1;
        }
        write = read.wrapping_add(offset as u16);
    }
    if write >= slots {
        write = write.wrapping_sub(slots);
    }
    if read >= slots {
        read = 0;
    }
    put_i32(m, b + 12 + 4 * write as usize, value);
    let result = w(m, b + 12 + 4 * read as usize);
    put_u16(m, b + 4, write.wrapping_add(1));
    put_u16(m, b + 6, read.wrapping_add(1));
    result
}

/// Op 18 Demux: +0 u8 n, +2 s16 previous, +4 control, +8 value, +12 outputs.
fn demux(m: &mut [u8], b: usize) -> i32 {
    let n = i32::from(u8_at(m, b));
    let prev = i32::from(i16_at(m, b + 2));
    if (1..=n).contains(&prev) {
        put_i32(m, b + 12 + 4 * (prev - 1) as usize, 0);
    }
    let control = w(m, b + 4);
    if (1..=n).contains(&control) {
        put_i32(m, b + 12 + 4 * (control - 1) as usize, w(m, b + 8));
        put_u16(m, b + 2, control as u16);
    }
    w(m, b + 12)
}

/// Op 28 Oscillator (§4.4): +0 u8 waveform, +4 f32 phase, +8 period ms, +12 amplitude.
fn oscillator(m: &mut [u8], b: usize, tick: f32) -> i32 {
    let period = w(m, b + 8);
    if period <= 0 {
        return 0;
    }
    let inc = tick / period as f32;
    let mut phase = f32_at(m, b + 4);
    if !phase.is_finite() {
        phase = 0.0; // retail would spin forever
    }
    while phase >= 1.0 {
        phase -= 1.0;
    }
    let amp = w(m, b + 12) as f32;
    let sample = match u8_at(m, b) {
        0 => {
            let u = round(phase * 1024.0);
            let (q, i) = ((u >> 8) & 3, (u & 255) as usize);
            let t = quarter_sine();
            let s = match q {
                0 => i32::from(t[i]),
                1 => i32::from(t[256 - i]),
                2 => -i32::from(t[i]),
                _ => -i32::from(t[256 - i]),
            };
            (s as f32 * amp) * (1.0 / 65536.0)
        }
        1 => {
            if phase < 0.5 { 0.0 } else { amp }
        }
        2 => phase * amp,
        _ => {
            if phase < 0.5 { phase * amp * 2.0 } else { (1.0 - phase) * amp * 2.0 }
        }
    };
    put_f32(m, b + 4, phase + inc);
    round(sample)
}

/// Op 29 Ramp (§4.5): +0 f32 current, +4 f32 delta, +8 previous target, +12 previous duration,
/// +16 duration ms, +20 scale (4096 = 1×), +24 target.
fn ramp(m: &mut [u8], b: usize, tick: f32) -> i32 {
    let target = w(m, b + 24);
    let mut current = f32_at(m, b);
    if target as f32 == current {
        return target;
    }
    let duration = w(m, b + 16);
    let mut delta = f32_at(m, b + 4);
    if target != w(m, b + 8) || duration != w(m, b + 12) {
        put_i32(m, b + 8, target);
        put_i32(m, b + 12, duration);
        if duration <= 0 {
            put_f32(m, b, target as f32);
            return target;
        }
        delta = (((target as f32 - current) / duration as f32) * tick) * (1.0 / 4096.0);
        put_f32(m, b + 4, delta);
    }
    current = fused(w(m, b + 20) as f32, delta, current);
    let t = target as f32;
    if (delta < 0.0 && current < t) || (delta >= 0.0 && current > t) {
        current = t;
    }
    put_f32(m, b, current);
    round(current)
}

#[cfg(test)]
mod tests;
