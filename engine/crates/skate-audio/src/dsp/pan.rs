//! Pan2D1 (Pn21, spec §4.9): places 1, 2, 4 or 6 source channels on the 6-channel layout
//! L (+30°), C (0°), R (−30°), Ls (+110°), Rs (−110°), LFE in internal angles; the azimuth
//! parameter is in degrees, positive = to the right, internal angle θ = −A.
//!
//! On the speaker circle (distance 1): constant-power pairwise panning with centre extraction in
//! the front sector. Inside the circle: a distance spread blended with the angular term and
//! renormalised. A parameter change ramps every matrix cell over 64 samples.
//!
//! Computed in f64 and stored as f32: not bit-exact with retail's single-precision code (its
//! constructor and speaker tables are unverified), checked against the spec's worked gains.

/// Parameter indices.
pub const ANGLE: usize = 0;
pub const DISTANCE: usize = 1;
pub const RADIUS: usize = 2;
pub const TURN: usize = 3;
pub const FOCUS: usize = 4;
pub const LEVEL: usize = 5;
pub const LFE: usize = 6;
pub const SPREAD1: usize = 7;
pub const SPREAD2: usize = 8;
pub const SPREAD3: usize = 9;

/// Class defaults.
pub const DEFAULTS: [f32; 10] = [0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 0.0, 30.0, 110.0, 150.0];

/// Speaker angles (internal degrees) of the 5 full-range outputs L, C, R, Ls, Rs.
const SPEAKERS: [f64; 5] = [30.0, 0.0, -30.0, 110.0, -110.0];

#[derive(Clone, Debug)]
pub struct Pan2D {
    pub params: [f32; 10],
    sources: usize,
    /// Law gain: voices open with law 0 → 1.0.
    law: f32,
    /// Row = source (up to 6), column = output (6).
    matrix: [[f32; 6]; 6],
    cache: Option<[f32; 10]>,
}

impl Pan2D {
    pub fn new(sources: usize) -> Self {
        Self { params: DEFAULTS, sources: sources.clamp(1, 6), law: 1.0, matrix: [[0.0; 6]; 6], cache: None }
    }

    pub fn sources(&self) -> usize {
        self.sources
    }

    /// The current gain matrix (row = source, column = output), rebuilt from the parameters.
    pub fn matrix(&mut self) -> [[f32; 6]; 6] {
        if self.cache.map(|c| c.iter().zip(&self.params).any(|(a, b)| a.to_bits() != b.to_bits())).unwrap_or(true) {
            self.matrix = build(&self.params, self.sources, self.law);
        }
        self.matrix
    }

    /// Pan one block: `src` planar (self.sources channels) → `out` 6 planar channels (overwritten).
    pub fn process(&mut self, src: &[&[f32]], out: &mut [[f32; crate::BLOCK]; 6]) {
        let changed = self.cache.is_none_or(|c| c.iter().zip(&self.params).any(|(a, b)| a.to_bits() != b.to_bits() || b.is_nan()));
        let first = self.cache.is_none();
        let old = self.matrix;
        if changed {
            self.matrix = build(&self.params, self.sources, self.law);
            self.cache = Some(self.params);
        }
        let new = self.matrix;
        for d in 0..6 {
            out[d] = [0.0; crate::BLOCK];
        }
        for (s, input) in src.iter().enumerate().take(self.sources) {
            for d in 0..6 {
                let (from, to) = (old[s][d], new[s][d]);
                let o = &mut out[d];
                if !changed || first || from == to {
                    if to != 0.0 {
                        for (k, &x) in input.iter().enumerate() {
                            o[k] += to * x;
                        }
                    }
                } else {
                    let delta = (to - from) / 64.0;
                    for (k, &x) in input.iter().enumerate() {
                        let g = if k < 64 { from + k as f32 * delta } else { to };
                        o[k] += g * x;
                    }
                }
            }
        }
    }
}

/// Clamp a position to the unit disc: r² > 1 → normalised; 0.999 < r² < 1 → r² treated as 1.
fn clamp(x: f64, y: f64) -> (f64, f64, f64) {
    let r2 = x * x + y * y;
    if r2 > 1.0 {
        let r = r2.sqrt();
        (x / r, y / r, 1.0)
    } else if r2 > 0.999 {
        (x, y, 1.0)
    } else {
        (x, y, r2)
    }
}

/// Gains on L, C, R, Ls, Rs for a point source at (x, y) (internal frame, x forward, y left).
pub fn point_gains(x: f64, y: f64, focus: f64) -> [f64; 5] {
    let (x, y, r2) = clamp(x, y);
    let mut g = [0.0f64; 5];
    if r2 < 1.0 {
        let w: [f64; 5] = SPEAKERS.map(|a| {
            let (sx, sy) = (a.to_radians().cos(), a.to_radians().sin());
            1.0 - 0.5 * ((sx - x).powi(2) + (sy - y).powi(2)).sqrt()
        });
        let mut front = 0.5 * (x + 1.0);
        let mut back = 1.0 - front;
        if front < 5e-4 {
            front = 0.0;
        }
        if back < 5e-4 {
            back = 0.0;
        }
        let wc = w[1] * focus;
        let fd = w[0] * w[0] + w[2] * w[2] + wc * wc;
        let f = if fd > 0.0 { (front / fd).sqrt() } else { 0.0 };
        let bd = w[3] * w[3] + w[4] * w[4];
        let b = if bd > 0.0 { (back / bd).sqrt() } else { 0.0 };
        let fade = (1.0 - r2 * r2).sqrt();
        g = [f * w[0] * fade, f * wc * fade, f * w[2] * fade, b * w[3] * fade, b * w[4] * fade];
    }
    if r2 > 0.0 {
        let mut theta = y.atan2(x).to_degrees();
        if theta < -30.0 {
            theta += 360.0;
        }
        // Sectors: [−30, 30) R–L, [30, 110) L–Ls, [110, 250) Ls–Rs, [250, 330) Rs–R.
        let (ia, alpha, ib, beta) = if theta < 30.0 {
            (2, -30.0, 0, 30.0)
        } else if theta < 110.0 {
            (0, 30.0, 3, 110.0)
        } else if theta < 250.0 {
            (3, 110.0, 4, 250.0)
        } else {
            (4, 250.0, 2, 330.0)
        };
        let span = ((beta - alpha) as f64).to_radians().sin();
        let mut a = ((beta - theta) as f64).to_radians().sin() / span;
        let mut b = ((theta - alpha) as f64).to_radians().sin() / span;
        let mut angular = [0.0f64; 5];
        if ia == 2 && ib == 0 {
            // Front sector: extract the shared part into the centre.
            let share = a.min(b) * focus;
            a -= share;
            b -= share;
            angular[1] = 3f64.sqrt() * share;
        }
        angular[ia] += a;
        angular[ib] += b;
        let norm = angular.iter().map(|v| v * v).sum::<f64>().sqrt();
        if norm > 0.0 {
            for (gk, ak) in g.iter_mut().zip(angular) {
                *gk += ak * r2 / norm;
            }
        }
    }
    if r2 < 1.0 {
        let norm = g.iter().map(|v| v * v).sum::<f64>().sqrt();
        if norm > 0.0 {
            for gk in &mut g {
                *gk /= norm;
            }
        }
    }
    g
}

fn build(p: &[f32; 10], sources: usize, law: f32) -> [[f32; 6]; 6] {
    let deg = |v: f32| f64::from(v).to_radians();
    let focus = f64::from(p[FOCUS]);
    let scale = f64::from(p[LEVEL]) * f64::from(law);
    let mut m = [[0.0f32; 6]; 6];
    let row = |x: f64, y: f64| -> [f32; 6] {
        let g = point_gains(x, y, focus);
        [(g[0] * scale) as f32, (g[1] * scale) as f32, (g[2] * scale) as f32, (g[3] * scale) as f32, (g[4] * scale) as f32, 0.0]
    };
    let d = f64::from(p[DISTANCE]);
    let theta = -deg(p[ANGLE]);
    if sources == 1 {
        m[0] = row(d * theta.cos(), d * theta.sin());
        m[0][5] = p[LFE];
        return m;
    }
    // Multichannel: entries around the layout centre.
    let (cx, cy) = (d * theta.cos(), d * theta.sin());
    let radius = f64::from(p[RADIUS]);
    let base = -deg(p[ANGLE] + p[TURN]);
    let (s1, s2) = (deg(p[SPREAD1]), deg(p[SPREAD2]));
    let offsets: &[Option<f64>] = match sources {
        2 => &[Some(s1), Some(-s1)],
        4 => &[Some(s1), Some(-s1), Some(s2), Some(-s2)],
        6 => &[Some(s1), Some(0.0), Some(-s1), Some(s2), Some(-s2), None],
        _ => &[],
    };
    for (s, offset) in offsets.iter().enumerate() {
        match offset {
            Some(o) => {
                let a = base + o;
                m[s] = row(cx + radius * a.cos(), cy + radius * a.sin());
                if sources != 6 {
                    m[s][5] = p[LFE];
                }
            }
            None => m[s][5] = p[LFE],
        }
    }
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Spec worked gains (mono, focus = level = 1): A (deg), D, focus → L, C, R, Ls, Rs.
    #[test]
    fn worked_gains_from_the_spec() {
        use std::f32::consts::FRAC_1_SQRT_2;
        let cases: &[(f32, f32, f32, [f32; 5])] = &[
            (0.0, 1.0, 1.0, [0.0, 1.0, 0.0, 0.0, 0.0]),
            (-30.0, 1.0, 1.0, [1.0, 0.0, 0.0, 0.0, 0.0]),
            (30.0, 1.0, 1.0, [0.0, 0.0, 1.0, 0.0, 0.0]),
            (-15.0, 1.0, 1.0, [FRAC_1_SQRT_2, FRAC_1_SQRT_2, 0.0, 0.0, 0.0]),
            (-15.0, 1.0, 0.0, [0.9391, 0.0, 0.3437, 0.0, 0.0]),
            (-90.0, 1.0, 1.0, [0.3673, 0.0, 0.0, 0.9301, 0.0]),
            (90.0, 1.0, 1.0, [0.0, 0.0, 0.3673, 0.0, 0.9301]),
            (180.0, 1.0, 1.0, [0.0, 0.0, 0.0, FRAC_1_SQRT_2, FRAC_1_SQRT_2]),
            (-150.0, 1.0, 1.0, [0.0, 0.0, 0.0, 0.8374, 0.5466]),
            (0.0, 0.5, 1.0, [0.4196, 0.6791, 0.4196, 0.3055, 0.3055]),
            (-90.0, 0.5, 1.0, [0.4927, 0.3226, 0.2477, 0.7437, 0.1970]),
            (180.0, 0.5, 1.0, [0.2411, 0.2211, 0.2411, 0.6461, 0.6461]),
            (47.0, 0.0, 1.0, [0.4082, 0.4082, 0.4082, 0.5, 0.5]),
        ];
        for &(a, d, focus, want) in cases {
            let mut p = Pan2D::new(1);
            p.params[ANGLE] = a;
            p.params[DISTANCE] = d;
            p.params[FOCUS] = focus;
            let m = p.matrix();
            for k in 0..5 {
                assert!((m[0][k] - want[k]).abs() < 1.5e-4, "A {a} D {d} focus {focus}: {:?} vs {want:?}", &m[0][..5]);
            }
            assert_eq!(m[0][5], 0.0);
        }
    }

    #[test]
    fn multichannel_defaults_land_each_channel_on_its_speaker() {
        // The open's defaults: distance 0, radius 1, spreads = speaker angles.
        let mut p = Pan2D::new(6);
        p.params[DISTANCE] = 0.0;
        let m = p.matrix();
        for s in 0..5 {
            for d in 0..5 {
                let want = if s == d { 1.0 } else { 0.0 };
                assert!((m[s][d] - want).abs() < 1e-5, "{s}->{d}: {}", m[s][d]);
            }
        }
        // Stereo pair at ±45° (bank descriptors 224/32 → −45°/+45°): channel 0 leans left.
        let mut p = Pan2D::new(2);
        p.params[DISTANCE] = 0.0;
        p.params[SPREAD1] = 45.0;
        let m = p.matrix();
        assert!(m[0][0] > m[0][2] && m[1][2] > m[1][0]);
    }

    #[test]
    fn parameter_change_ramps_over_64_samples() {
        let mut p = Pan2D::new(1);
        let x = vec![1.0f32; crate::BLOCK];
        let mut out = [[0.0f32; crate::BLOCK]; 6];
        p.process(&[&x], &mut out);
        assert!(out[1].iter().all(|&v| (v - 1.0).abs() < 1e-6));
        p.params[ANGLE] = -30.0;
        p.process(&[&x], &mut out);
        assert!((out[1][0] - 1.0).abs() < 1e-6 && out[0][0].abs() < 1e-6);
        assert!((out[1][32] - 0.5).abs() < 1e-3 && (out[0][32] - 0.5).abs() < 1e-3);
        assert!(out[1][64].abs() < 1e-6 && (out[0][64] - 1.0).abs() < 1e-6);
    }
}
