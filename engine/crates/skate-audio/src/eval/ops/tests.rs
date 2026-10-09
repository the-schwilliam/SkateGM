//! Per-opcode tests from the spec's rules (§4, §8.1), on hand-built blocks.
use super::*;
use crate::eval::tick_scale;

fn words(v: &[i32]) -> Vec<u8> {
    v.iter().flat_map(|w| w.to_be_bytes()).collect()
}

fn run_op(opcode: u8, m: &mut [u8], bank: &[u8], rng: &mut Rng) -> i32 {
    let mut ctx = Ctx { bank, rng, tick: tick_scale() };
    run(opcode, m, 0, &mut ctx).unwrap()
}

fn op(opcode: u8, m: &mut [u8]) -> i32 {
    run_op(opcode, m, &[], &mut Rng::default())
}

#[test]
fn tick_scale_is_the_f32_value() {
    assert_eq!(tick_scale(), 31.999998);
    assert_eq!(tick_scale().to_bits(), 31.999998f32.to_bits());
}

#[test]
fn arithmetic_ops() {
    assert_eq!(op(23, &mut words(&[5, 7])), -2);
    assert_eq!(op(24, &mut words(&[0x10000, 0x10000])), 0); // low 32 bits
    assert_eq!(op(25, &mut words(&[7, 0])), 0);
    assert_eq!(op(25, &mut words(&[i32::MIN, -1])), 0);
    assert_eq!(op(25, &mut words(&[-7, 2])), -3);
    assert_eq!(op(26, &mut words(&[-7, 2])), -1);
    assert_eq!(op(26, &mut words(&[7, 0])), 0);
    assert_eq!(op(33, &mut words(&[3, -4])), -4);
    assert_eq!(op(34, &mut words(&[3, -4])), 3);
    assert_eq!(op(36, &mut words(&[i32::MAX, 1])), i32::MIN);
    // n-ary: n = 0 still reads input 0.
    assert_eq!(op(22, &mut words(&[0, 9, 100])), 9);
    assert_eq!(op(22, &mut words(&[3 << 24, 1, 2, 3])), 6);
    assert_eq!(op(19, &mut words(&[3 << 24, 4, -2, 9])), -2);
    assert_eq!(op(20, &mut words(&[3 << 24, 4, -2, 9])), 9);
    assert_eq!(op(20, &mut words(&[0, 4, 50])), 4);
    // AddMaximum, SubtractMinimum, MultiplyMaximum.
    assert_eq!(op(30, &mut words(&[2 << 24, 10, 6, 7])), 10);
    assert_eq!(op(30, &mut words(&[0, 10, 6, 7])), 6);
    assert_eq!(op(31, &mut words(&[0, 3, 10])), 0);
    assert_eq!(op(32, &mut words(&[50, 6, 7])), 42);
    assert_eq!(op(32, &mut words(&[40, 6, 7])), 40);
}

#[test]
fn scale_ops_round_in_f32() {
    // Scale: 0.5 × 3 × 5 = 7.5 → 8.
    let mut m = words(&[2 << 24, 0.5f32.to_bits() as i32, 3, 5]);
    assert_eq!(op(21, &mut m), 8);
    // n = 0 still uses input 0: 0.5 × 3 = 1.5 → 2.
    let mut m = words(&[0, 0.5f32.to_bits() as i32, 3]);
    assert_eq!(op(21, &mut m), 2);
    // Scale2: round(b·a·s) = 4096 × 3 × 0.25 = 3072; negative rounds away from zero.
    assert_eq!(op(35, &mut words(&[0.25f32.to_bits() as i32, 3, 4096])), 3072);
    assert_eq!(op(35, &mut words(&[0.5f32.to_bits() as i32, -3, 1])), -2);
}

#[test]
fn mux_and_demux() {
    assert_eq!(op(17, &mut words(&[2 << 24, 2, 10, 20])), 20);
    assert_eq!(op(17, &mut words(&[2 << 24, 3, 10, 20])), 0);
    assert_eq!(op(17, &mut words(&[2 << 24, 0, 10, 20])), 0);
    // Demux: n = 3, prev = 1, control 2, value 77 → outputs [0, 77, 0], prev = 2, returns out[0].
    let mut m = words(&[(3 << 24) | 1, 2, 77, 5, 0, 0]);
    assert_eq!(op(18, &mut m), 0);
    assert_eq!(&m[12..24], &words(&[0, 77, 0])[..]);
    assert_eq!(i16_at(&m, 2), 2);
    // Next walk with control 0: the previous output is cleared, prev unchanged.
    put_i32(&mut m, 4, 0);
    op(18, &mut m);
    assert_eq!(&m[12..24], &words(&[0, 0, 0])[..]);
    assert_eq!(i16_at(&m, 2), 2);
}

#[test]
fn counter_wraps_and_override_wins() {
    // min 0, max 2, value 2, step +1, trigger 1, override −1 (out of range).
    let mut m = words(&[0, 2, 2, 1 << 24, 1, -1]);
    assert_eq!(op(6, &mut m), 0);
    assert_eq!(op(6, &mut m), 1);
    // Step −1 from 0 wraps to max.
    let mut m = words(&[0, 2, 0, (-1i32 as u8 as i32) << 24, 1, -1]);
    assert_eq!(op(6, &mut m), 2);
    // Override in range: returned, value untouched.
    let mut m = words(&[0, 2, 0, 1 << 24, 1, 1]);
    assert_eq!(op(6, &mut m), 1);
    assert_eq!(i32_at(&m, 8), 0);
    // Trigger must be > 0 (signed).
    let mut m = words(&[0, 5, 1, 1 << 24, -1, -1]);
    assert_eq!(op(6, &mut m), 1);
}

#[test]
fn random_draws_mod_range() {
    let mut rng = Rng::default();
    // draws 0, 1, 7 → min 10 + draw mod 5 → 10, 11, 12.
    let mut m = words(&[10, 5, 0, 1]);
    let got: Vec<i32> = (0..3).map(|_| run_op(7, &mut m, &[], &mut rng)).collect();
    assert_eq!(got, [10, 11, 12]);
    // No trigger: current unchanged, no draw.
    put_i32(&mut m, 12, 0);
    assert_eq!(run_op(7, &mut m, &[], &mut rng), 12);
    assert_eq!(rng.w, [7, 6, 5, 4, 3, 3]);
    // Range 0: min + draw.
    let mut m = words(&[10, 0, 0, 1]);
    let draw = Rng::new(rng.w).draw() as i32;
    assert_eq!(run_op(7, &mut m, &[], &mut rng), 10 + draw);
}

/// A shuffle block: trigger at +16 + set size, u8 entries.
fn shuffle_block(range: u16, min: i32) -> Vec<u8> {
    let mut m = vec![0u8; 16 + range as usize + 4];
    m.resize((m.len() + 3) & !3, 0);
    let trig = (m.len() - 4) as u16;
    put_u16(&mut m, 0, trig);
    put_u8(&mut m, 2, 1);
    put_u8(&mut m, 3, 0);
    put_i32(&mut m, 4, min);
    put_u16(&mut m, 8, 0);
    put_u16(&mut m, 10, range);
    for i in 0..range as usize {
        put_u8(&mut m, 16 + i, i as u8);
    }
    put_i32(&mut m, trig as usize, 1);
    m
}

#[test]
fn shuffle_never_repeats_within_a_pass_or_across_the_wrap() {
    let mut rng = Rng::new([0x1234, 0x5678, 9, 10, 11, 12]);
    let range = 7u16;
    let mut m = shuffle_block(range, 100);
    let mut last = None;
    let mut pass = Vec::new();
    for draw in 0..10_000 {
        let v = run_op(8, &mut m, &[], &mut rng);
        assert!((100..107).contains(&v));
        assert_ne!(Some(v), last, "repeat at draw {draw}");
        last = Some(v);
        pass.push(v);
        if pass.len() == range as usize {
            let mut sorted = pass.clone();
            sorted.sort_unstable();
            assert_eq!(sorted, (100..107).collect::<Vec<_>>(), "a pass plays every value once");
            pass.clear();
        }
    }
    // Without a trigger the current value is returned and nothing is drawn.
    let trig = u16_at(&m, 0) as usize;
    put_i32(&mut m, trig, 0);
    let state = rng;
    assert_eq!(run_op(8, &mut m, &[], &mut rng), last.unwrap());
    assert_eq!(rng, state);
}

#[test]
fn shuffle_span_arithmetic() {
    // From zero RNG: draw 0 → k = index + 0. range 3: picks set[0] = 0 first.
    let mut rng = Rng::default();
    let mut m = shuffle_block(3, 0);
    assert_eq!(run_op(8, &mut m, &[], &mut rng), 0); // draw 0, span 3 → k 0
    assert_eq!(run_op(8, &mut m, &[], &mut rng), 2); // draw 1, span 2, index 1 → k 2 (set[2] = 2)
    assert_eq!(run_op(8, &mut m, &[], &mut rng), 1); // draw 7, span 1 → k 2 (set now [0,2,1])
    // Pass done: index 0, avoid-repeat 1 → span 2 excludes the last slot.
    assert_eq!((u16_at(&m, 8), i8_at(&m, 3)), (0, 1));
}

fn table_bank(entry: u8, values: &[i32], min: i32, max: i32, resolution: f32) -> Vec<u8> {
    let mut t = vec![entry, 0];
    t.extend_from_slice(&(values.len() as u16).to_be_bytes());
    t.extend_from_slice(&min.to_be_bytes());
    t.extend_from_slice(&max.to_be_bytes());
    t.extend_from_slice(&resolution.to_bits().to_be_bytes());
    for &v in values {
        match entry {
            1 => t.push(v as i8 as u8),
            2 => t.extend_from_slice(&(v as i16).to_be_bytes()),
            _ => t.extend_from_slice(&v.to_be_bytes()),
        }
    }
    t
}

#[test]
fn table_nearest_and_linear() {
    let mut rng = Rng::default();
    // Nearest: s16 entries, input clamped to [10, 13].
    let bank = table_bank(2, &[-100, 200, 300, 400], 10, 13, 1.0);
    let mut m = words(&[0, 0x7FFF_FFF1, 0, 12]);
    assert_eq!(run_op(15, &mut m, &bank, &mut rng), 300);
    put_i32(&mut m, 12, 99);
    assert_eq!(run_op(15, &mut m, &bank, &mut rng), 400);
    put_i32(&mut m, 12, -5);
    assert_eq!(run_op(15, &mut m, &bank, &mut rng), -100);
    // Same input again: cached output, even if the table changed.
    assert_eq!(run_op(15, &mut m, &[0; 32], &mut rng), -100);
    // Linear: resolution 0.5 entries per unit, s8 entries.
    let bank = table_bank(1, &[0, 100, 50], 0, 4, 0.5);
    let mut m = words(&[0, 0x7FFF_FFF1, 0, 1]);
    assert_eq!(run_op(15, &mut m, &bank, &mut rng), 50); // x = 0.5 between 0 and 100
    put_i32(&mut m, 12, 3);
    assert_eq!(run_op(15, &mut m, &bank, &mut rng), 75); // x = 1.5 between 100 and 50
    put_i32(&mut m, 12, 4);
    assert_eq!(run_op(15, &mut m, &bank, &mut rng), 50); // x = 2.0: i1 clamps to the last entry
    // x = 0: i0 rounds to −1 (reads the resolution's low byte) yet lands exactly on entry 0.
    let bank = table_bank(1, &[-7, 100, 50], 0, 4, 0.5);
    put_i32(&mut m, 12, 0);
    assert_eq!(run_op(15, &mut m, &bank, &mut rng), -7);
}

#[test]
fn weighted_takes_the_first_cumulative_weight_above_the_draw() {
    let bank = table_bank(1, &[30, 30, 40], 0, 2, 1.0);
    let mut rng = Rng::new([0; 6]);
    // draws 0, 1, 7: all below 30 → index 0.
    let mut m = words(&[0, 5, 3, -1, 1]);
    assert_eq!(run_op(9, &mut m, &bank, &mut rng), 5);
    // A draw of 45 → cumulative 30, 60 → index 1.
    let mut rng = Rng::new([44, 0, 0, 0, 0, 0]); // next w0 = 44 + 1 (w1 + carry) … check via draw
    let mut probe = rng;
    let r = probe.draw() % 100;
    let expect = if r < 30 { 5 } else if r < 60 { 6 } else { 7 };
    assert_eq!(run_op(9, &mut m, &bank, &mut rng), expect);
}

#[test]
fn range_trigger_trips_once_until_reset() {
    // trip [10, 20], reset [0, 5]
    let mut m = words(&[10, 20, 0, 5, 0, 15]);
    assert_eq!(op(10, &mut m), 1);
    assert_eq!(op(10, &mut m), 0); // still tripped
    put_i32(&mut m, 20, 30);
    assert_eq!(op(10, &mut m), 0); // outside both: stays tripped
    put_i32(&mut m, 20, 15);
    assert_eq!(op(10, &mut m), 0);
    put_i32(&mut m, 20, 3);
    assert_eq!(op(10, &mut m), 0); // reset
    put_i32(&mut m, 20, 12);
    assert_eq!(op(10, &mut m), 1);
}

#[test]
fn delay_trigger_fires_after_the_delay_rounded_up_to_a_tick() {
    let mut m = words(&[(-1.0f32).to_bits() as i32, 0, 1, 100]);
    let mut fired = Vec::new();
    for walk in 0..8 {
        if walk == 1 {
            put_i32(&mut m, 8, 0); // restart released after the first walk
        }
        fired.push(op(11, &mut m));
    }
    // time 0 → 32 → 64 → 96 → 128 ≥ 100 on the 5th walk.
    assert_eq!(fired, [0, 0, 0, 0, 1, 0, 0, 0]);
    assert_eq!(f32_at(&m, 0), -1.0);
}

#[test]
fn delay_line_delays_by_whole_ticks() {
    // offset 12 → {value, delay}; 4 slots; ring at +12. Words: [hdr, in/out, prev, ring×4, value, delay]
    let mut m = vec![0u8; 12 + 16 + 8];
    put_u16(&mut m, 0, 28);
    put_u16(&mut m, 2, 4);
    put_i32(&mut m, 8, -12345);
    put_i32(&mut m, 32, 64); // 64 ms = 2 ticks
    let mut out = Vec::new();
    for v in 1..=6 {
        put_i32(&mut m, 28, v);
        out.push(op(16, &mut m));
    }
    assert_eq!(out, [0, 0, 1, 2, 3, 4]);
    // Delay 0 passes the value straight through (write before read).
    put_i32(&mut m, 32, 0);
    put_i32(&mut m, 28, 42);
    assert_eq!(op(16, &mut m), 42);
    // A negative delay is written back as 0.
    put_i32(&mut m, 32, -5);
    op(16, &mut m);
    assert_eq!(i32_at(&m, 32), 0);
}

#[test]
fn oscillator_waveforms_and_quadrants() {
    // Sine, amplitude 65536 → sample = T value (×1).
    let t = quarter_sine();
    let mut m = words(&[0, 0.0f32.to_bits() as i32, 128_000, 65536]);
    // Phase 0, 0.25, 0.5, 0.75 → 0, T[256], 0 (−T[0]), −T[256].
    for (phase, want) in [(0.0f32, 0), (0.25, i32::from(t[256])), (0.5, 0), (0.75, -i32::from(t[256])), (0.125, i32::from(t[128]))] {
        put_f32(&mut m, 4, phase);
        assert_eq!(op(28, &mut m), want, "phase {phase}");
    }
    // u = 1024 (phase just below 1 rounds up): quadrant (1024 >> 8) & 3 = 0, i = 0 → 0.
    put_f32(&mut m, 4, 0.9999);
    assert_eq!(op(28, &mut m), 0);
    // Phase advances by tick/period and wraps.
    put_f32(&mut m, 4, 0.0);
    op(28, &mut m);
    assert_eq!(f32_at(&m, 4), tick_scale() / 128_000.0);
    // Square, saw, triangle.
    let mut m = words(&[1 << 24, 0.6f32.to_bits() as i32, 1000, 100]);
    assert_eq!(op(28, &mut m), 100);
    let mut m = words(&[2 << 24, 0.25f32.to_bits() as i32, 1000, 100]);
    assert_eq!(op(28, &mut m), 25);
    let mut m = words(&[3 << 24, 0.75f32.to_bits() as i32, 1000, 100]);
    assert_eq!(op(28, &mut m), 50);
    // Period ≤ 0: 0 and no state change.
    let mut m = words(&[0, 0.3f32.to_bits() as i32, 0, 100]);
    assert_eq!(op(28, &mut m), 0);
    assert_eq!(f32_at(&m, 4), 0.3);
    // Phase ≥ 1 wraps first.
    let mut m = words(&[2 << 24, 2.5f32.to_bits() as i32, 1000, 100]);
    assert_eq!(op(28, &mut m), 50);
}

#[test]
fn ramp_reaches_its_target_in_its_duration() {
    // current 0, target 4096 over 320 ms at scale 4096 (1×): 10 ticks of ~409.6.
    let mut m = words(&[0, 0, 0, 0, 320, 4096, 4096]);
    let mut out = Vec::new();
    for _ in 0..12 {
        out.push(op(29, &mut m));
    }
    assert_eq!(out[0], 410);
    assert_eq!(*out.last().unwrap(), 4096);
    assert!(out.windows(2).all(|w| w[0] <= w[1]));
    // Overshoot is clamped; reaching the target exactly returns the target without work.
    assert_eq!(f32_at(&m, 0), 4096.0);
    // Duration ≤ 0 snaps.
    let mut m = words(&[0, 0, 0, 0, 0, 4096, 77]);
    assert_eq!(op(29, &mut m), 77);
    assert_eq!(f32_at(&m, 0), 77.0);
    // Scale 0 freezes until target/duration change.
    let mut m = words(&[0, 0, 0, 0, 320, 0, 4096]);
    assert_eq!(op(29, &mut m), 0);
    assert_eq!(op(29, &mut m), 0);
}

/// Envelope block: control word at +24 + 8·nseg (self-relative offset at +0).
fn envelope_block(segments: &[(f32, f32)], release: i16, initial: f32) -> (Vec<u8>, usize) {
    let control = 24 + 8 * segments.len();
    let mut m = vec![0u8; control + 4];
    put_u16(&mut m, 0, control as u16);
    put_u8(&mut m, 16, segments.len() as u8);
    put_u16(&mut m, 18, release as u16);
    put_f32(&mut m, 20, initial);
    for (i, &(d, t)) in segments.iter().enumerate() {
        put_f32(&mut m, 24 + 8 * i, d);
        put_f32(&mut m, 28 + 8 * i, t);
    }
    (m, control)
}

#[test]
fn envelope_start_hold_release_and_end() {
    // Attack 64 ms to 1000, hold-ish segment 640 ms to 1000, release 64 ms to 0 (segment 2).
    let (mut m, ctl) = envelope_block(&[(64.0, 1000.0), (640.0, 1000.0), (64.0, 0.0)], 2, 0.0);
    put_i32(&mut m, ctl, 1);
    let start = op(14, &mut m);
    assert_eq!(start, 0); // output = initial on the start walk
    let a = op(14, &mut m);
    assert!(a > 450 && a < 550, "{a}");
    let b = op(14, &mut m);
    assert_eq!(b, 1000); // segment 0 done, segment 1 programmed from its target
    // Hold (2): unchanged.
    put_i32(&mut m, ctl, 2);
    assert_eq!(op(14, &mut m), 1000);
    // Release (3): jump to segment 2 from the current output.
    put_i32(&mut m, ctl, 3);
    assert_eq!(op(14, &mut m), 1000);
    let r1 = op(14, &mut m);
    assert!(r1 < 600, "{r1}");
    let r2 = op(14, &mut m);
    assert_eq!(r2, 0); // last segment done → output 0
    assert_eq!(op(14, &mut m), 0);
    // Stop (0): output 0.
    put_i32(&mut m, ctl, 0);
    assert_eq!(op(14, &mut m), 0);
    assert_eq!(i8_at(&m, 2), 0);
}
