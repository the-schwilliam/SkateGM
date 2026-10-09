//! ReverbModel1 (RM10, process `sub_82B2F8C0`; spec `audio-specs/aems-env-bus-spec.md` §8.2, §8.3): mono in,
//! six parallel Moorer combs (a one-pole low-pass in each feedback loop) into one all-pass, wet
//! only. p0 = reverb time T60 (s; ≤ 0 → silence, else at least 0.366 s), p1 = space size (m,
//! clamped 2 … 83.3), p2 = brightness.
//!
//! - Distances: near = 0.8·S, far = 1.5·near (far > 100 → far 100, near 66.666664); six evenly
//!   spaced from near to far. Delay of comb i = the first prime strictly above 48000·dᵢ/344.8,
//!   the search continuing from the previous comb's prime.
//! - g1ᵢ (damping) = linear interpolation over the distance knots 0, 12.5, …, 100 of
//!   0.08·row25k + 0.92·row50k (image tables 0x8211621C / 0x82116264). Brightness quirk: only when
//!   p2 differs from the last applied brightness (constructor 1.0): b = max(p2, g1[5] + 0.001),
//!   every g1 /= b and the comb states are zeroed.
//! - g2ᵢ = (1 − g1ᵢ)·(1 − 0.366/T).
//! - Comb: s[n] = x[n] + g2·s[n−D] + g1·s[n−1]; out = (s[n−D] − g1·s[n−D−1]) / 6.
//! - All-pass: a[n] = c[n] − 0.7·a[n−288]; y[n] = 2·(0.7·a[n] + a[n−288]).
//!
//! UNCERTAIN (spec §8.3): the tap alignment (n−D vs n−D−1), how many blocks retail waits before a
//! new configuration is heard (its module timer; we apply it at the next block), whether resizes
//! clear the lines (we zero them), the f32 association of the vectorised kernels.

const SPEED_OF_SOUND_INV: f32 = 0.002_900_232_1;
const KNOTS: [f32; 9] = [0.0, 12.5, 25.0, 37.5, 50.0, 62.5, 75.0, 87.5, 100.0];
const ROW_25K: [f32; 9] = [0.0, 0.12, 0.23, 0.30, 0.35, 0.40, 0.43, 0.46, 0.50];
const ROW_50K: [f32; 9] = [0.0, 0.31, 0.45, 0.53, 0.57, 0.61, 0.64, 0.67, 0.70];
const MIN_TIME: f32 = 0.366;
const ALLPASS_GAIN: f32 = 0.7;
const ALLPASS_DELAY: usize = 288;

/// The primes 2 … 13999 (the image's table at 0x821147D0 holds these 1652 values as floats).
fn primes() -> &'static [u32] {
    static PRIMES: std::sync::OnceLock<Vec<u32>> = std::sync::OnceLock::new();
    PRIMES.get_or_init(|| {
        let n = 14_000usize;
        let mut sieve = vec![true; n];
        sieve[0] = false;
        sieve[1] = false;
        let mut i = 2;
        while i * i < n {
            if sieve[i] {
                let mut j = i * i;
                while j < n {
                    sieve[j] = false;
                    j += i;
                }
            }
            i += 1;
        }
        (0..n as u32).filter(|&k| sieve[k as usize]).collect()
    })
}

#[derive(Clone, Debug, Default)]
struct Comb {
    line: Vec<f32>,
    at: usize,
    delay: usize,
    g1: f32,
    g2: f32,
    last: f32,
}

#[derive(Clone, Debug)]
pub struct ReverbModel1 {
    pub time: f32,
    pub size: f32,
    pub brightness: f32,
    applied: Option<[u32; 3]>,
    applied_size: Option<u32>,
    last_brightness: f32,
    combs: [Comb; 6],
    allpass: Vec<f32>,
    ap_at: usize,
}

impl Default for ReverbModel1 {
    fn default() -> Self {
        Self {
            time: 0.0,
            size: 0.0,
            brightness: 1.0,
            applied: None,
            applied_size: None,
            last_brightness: 1.0,
            combs: Default::default(),
            allpass: vec![0.0; ALLPASS_DELAY],
            ap_at: 0,
        }
    }
}

/// The six comb distances (m) for a space size.
pub fn distances(size: f32) -> [f32; 6] {
    let s = size.clamp(2.0, 83.3);
    let mut near = 0.8 * s;
    let mut far = 1.5 * near;
    if far > 100.0 {
        far = 100.0;
        near = 66.666_664;
    }
    let mut d = [0.0; 6];
    for (k, v) in d.iter_mut().enumerate() {
        *v = if k == 5 { far } else { near + k as f32 * 0.2 * (far - near) };
    }
    d
}

/// The six comb delays (samples): successive primes above 48000·d/344.8.
pub fn delays(distances: &[f32; 6]) -> [usize; 6] {
    let p = primes();
    let mut from = 0;
    let mut out = [0; 6];
    for (o, &d) in out.iter_mut().zip(distances) {
        let x = 48000.0 * d * SPEED_OF_SOUND_INV;
        while from < p.len() && p[from] as f32 <= x {
            from += 1;
        }
        let k = from.min(p.len() - 1);
        *o = p[k] as usize;
        from = k + 1;
    }
    out
}

/// g1 at a distance: the knot interpolation of 0.08·row25k + 0.92·row50k.
pub fn damping(distance: f32) -> f32 {
    let row = |i: usize| 0.08 * ROW_25K[i] + 0.92 * ROW_50K[i];
    let d = distance.clamp(0.0, 100.0);
    let i = ((d / 12.5) as usize).min(7);
    let t = (d - KNOTS[i]) / 12.5;
    row(i) + t * (row(i + 1) - row(i))
}

impl ReverbModel1 {
    fn configure(&mut self) {
        let size_bits = self.size.to_bits();
        if self.applied_size != Some(size_bits) {
            let d = distances(self.size);
            let delays = delays(&d);
            for (k, c) in self.combs.iter_mut().enumerate() {
                c.delay = delays[k];
                c.line = vec![0.0; delays[k] + 3];
                c.at = 0;
                c.last = 0.0;
                c.g1 = damping(d[k]);
            }
            self.applied_size = Some(size_bits);
        }
        if self.brightness.to_bits() != self.last_brightness.to_bits() {
            let b = self.brightness.max(self.combs[5].g1 + 0.001);
            for c in &mut self.combs {
                c.g1 *= 1.0 / b;
                c.line.fill(0.0);
                c.last = 0.0;
            }
            self.last_brightness = self.brightness;
        }
        let t = self.time.max(MIN_TIME);
        for c in &mut self.combs {
            c.g2 = (1.0 - c.g1) * (1.0 - MIN_TIME / t);
        }
    }

    /// One mono block in place.
    pub fn process(&mut self, x: &mut [f32]) {
        if self.time.is_nan() || self.time <= 0.0 {
            x.fill(0.0);
            return;
        }
        let key = [self.time.to_bits(), self.size.to_bits(), self.brightness.to_bits()];
        if self.applied != Some(key) {
            self.configure();
            self.applied = Some(key);
        }
        for s in x.iter_mut() {
            let input = *s;
            let mut sum = 0.0f32;
            for c in &mut self.combs {
                let len = c.line.len();
                let delayed = c.line[super::wrap(c.at + len - c.delay, len)];
                let before = c.line[super::wrap(c.at + len - c.delay - 1, len)];
                let v = input + c.g2 * delayed + c.g1 * c.last;
                c.line[c.at] = v;
                c.last = v;
                c.at = super::wrap(c.at + 1, len);
                sum += (delayed - c.g1 * before) * (1.0 / 6.0);
            }
            let old = self.allpass[self.ap_at];
            let a = sum - ALLPASS_GAIN * old;
            self.allpass[self.ap_at] = a;
            self.ap_at = (self.ap_at + 1) % ALLPASS_DELAY;
            *s = 2.0 * (ALLPASS_GAIN * a + old);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn comb_delays_match_the_spec_examples() {
        assert_eq!(primes().len(), 1652);
        assert_eq!(delays(&distances(70.0)), [7817, 8581, 9371, 10139, 10937, 11699]);
        assert_eq!(delays(&distances(8.3))[0], 929);
        assert_eq!(delays(&distances(8.3))[5], 1399);
    }

    #[test]
    fn an_impulse_rings_and_decays() {
        let mut rv = ReverbModel1 { time: 1.5, size: 70.0, brightness: 0.7, ..Default::default() };
        let mut energy = Vec::new();
        for b in 0..(48000 * 3 / 256) {
            let mut x = vec![0.0f32; 256];
            if b == 0 {
                x[0] = 1.0;
            }
            rv.process(&mut x);
            energy.push(x.iter().map(|v| v * v).sum::<f32>());
        }
        let window = |s: f32| energy[(s * 48000.0 / 256.0) as usize..((s + 0.2) * 48000.0 / 256.0) as usize].iter().sum::<f32>();
        let drop = 10.0 * (window(0.4) / window(1.9)).log10();
        // The loop gain per round trip is g2/(1 − g1) = 1 − 0.366/T (0.756 at 1.5 s): with 70 m
        // combs (≈ 0.2 s per trip) that is ≈ 12 dB/s, not a 60 dB T60 (retail's formula, spec §8.3).
        assert!(window(0.4) > 0.0 && drop > 10.0 && drop < 40.0, "{drop}");
        let mut silent = ReverbModel1::default();
        let mut x = vec![1.0f32; 256];
        silent.process(&mut x);
        assert!(x.iter().all(|&v| v == 0.0), "T60 0 = silence");
    }
}
