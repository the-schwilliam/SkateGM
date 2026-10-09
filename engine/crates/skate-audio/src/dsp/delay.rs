//! Delay (Del0, process `sub_82B222D8`; spec `audio-specs/aems-env-bus-spec.md` §8.1, §8.3): a whole-sample
//! feedback delay, wet only. p0 = delay (s; 0 = off: the module is skipped and the signal passes
//! undelayed), p1 = feedback (clamped to ±0.99). D = round-half-away(p0 · 48000).
//! w[n] = x[n] + fb·w[n−D]; y[n] = w[n−D]. A change of D crossfades the old and new taps over 128
//! samples (r = 127/128 … 0): y = (1−r)·t_new + r·t_old, w = x + (1−r)·fb_new·t_new + r·fb_old·t_old.
//! A feedback change outside a crossfade applies at once. Mono or multichannel (one line each).
//!
//! UNCERTAIN (spec): the output while the line first fills (we read the zeroed line, i.e. silence
//! until D samples have passed) and whether a resize clears the line (we keep its contents).

#[derive(Clone, Debug)]
pub struct Delay {
    /// p0 (s) and p1.
    pub delay: f32,
    pub feedback: f32,
    lines: Vec<Vec<f32>>,
    write: usize,
    taps: usize,
    fb: f32,
    /// 0 = bypass, 1 = running.
    state: u8,
}

impl Delay {
    /// `max` = the constructor's maximum delay (s): the line length.
    pub fn new(max: f32, channels: usize) -> Self {
        let len = (max * 48000.0).round().max(1.0) as usize + 1;
        Self { delay: 0.0, feedback: 0.0, lines: vec![vec![0.0; len]; channels.max(1)], write: 0, taps: 0, fb: 0.0, state: 0 }
    }

    fn samples(delay: f32) -> usize {
        let d = delay * 48000.0;
        if d.is_nan() || d <= 0.0 { 0 } else { d.round() as usize }
    }

    fn grow(&mut self, d: usize) {
        if d + 1 > self.lines[0].len() {
            let len = self.lines[0].len();
            for line in &mut self.lines {
                // Keep the ring order: unwrap it so `write` stays valid.
                line.rotate_left(self.write);
                line.resize(d + 1, 0.0);
            }
            self.write = len;
            self.write %= self.lines[0].len();
        }
    }

    pub fn process(&mut self, channels: &mut [&mut [f32]]) {
        let d = Self::samples(self.delay);
        let fb_new = if self.feedback.is_nan() { self.feedback } else { self.feedback.clamp(-0.99, 0.99) };
        if d == 0 {
            self.state = 0;
            return;
        }
        self.grow(d);
        if self.state == 0 {
            for line in &mut self.lines {
                line.fill(0.0);
            }
            self.write = 0;
            self.taps = d;
            self.fb = fb_new;
            self.state = 1;
        }
        let len = self.lines[0].len();
        let (old_d, old_fb) = (self.taps, self.fb);
        let fade = old_d != d;
        for (ch, samples) in channels.iter_mut().enumerate().take(self.lines.len()) {
            let line = &mut self.lines[ch];
            let mut w = self.write;
            for (k, s) in samples.iter_mut().enumerate() {
                let t_new = line[super::wrap(w + len - d, len)];
                let (y, wv) = if fade && k < 128 {
                    let r = (127 - k) as f32 * (1.0 / 128.0);
                    let t_old = line[super::wrap(w + len - old_d, len)];
                    ((1.0 - r) * t_new + r * t_old, *s + (1.0 - r) * fb_new * t_new + r * old_fb * t_old)
                } else {
                    (t_new, *s + fb_new * t_new)
                };
                line[w] = wv;
                *s = y;
                w = super::wrap(w + 1, len);
            }
        }
        self.write = (self.write + channels.first().map_or(0, |c| c.len())) % len;
        self.taps = d;
        self.fb = fb_new;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delays_by_whole_samples_with_feedback_and_bypasses_at_zero() {
        let mut dl = Delay::new(0.01, 1);
        let mut x = vec![0.0f32; 256];
        x[0] = 1.0;
        let before = x.clone();
        dl.process(&mut [&mut x[..]]);
        assert_eq!(x, before, "delay 0 = bypass");
        dl.delay = 100.0 / 48000.0;
        dl.feedback = 0.5;
        let mut x = vec![0.0f32; 256];
        x[0] = 1.0;
        dl.process(&mut [&mut x[..]]);
        assert_eq!(x[100], 1.0);
        assert_eq!(x[200], 0.5);
        assert!(x.iter().enumerate().all(|(i, &v)| i == 100 || i == 200 || v == 0.0));
    }

    #[test]
    fn a_new_delay_crossfades_over_128_samples() {
        let mut dl = Delay::new(0.01, 1);
        dl.delay = 10.0 / 48000.0;
        let mut x = vec![1.0f32; 256];
        dl.process(&mut [&mut x[..]]);
        dl.delay = 20.0 / 48000.0;
        let mut x = vec![1.0f32; 256];
        dl.process(&mut [&mut x[..]]);
        // Both taps read a constant 1.0 line: the crossfade is seamless.
        assert!(x.iter().all(|&v| (v - 1.0).abs() < 1e-6));
    }
}
