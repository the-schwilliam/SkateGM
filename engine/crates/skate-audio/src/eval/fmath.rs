//! Single-precision helpers with the retail rounding rules (spec §3 "Float semantics").

/// Float → int as the evaluator's `round`: add ±0.5 in f32, then truncate toward zero, saturating
/// like PPC `fctiwz` (NaN and values below −2³¹ → i32::MIN, above 2³¹−1 → i32::MAX).
#[inline]
pub fn round(x: f32) -> i32 {
    let v = if x < 0.0 { x - 0.5 } else { x + 0.5 };
    trunc(v)
}

/// Truncate toward zero with `fctiwz` saturation (Rust's `as` maps NaN to 0, retail to i32::MIN).
#[inline]
pub fn trunc(v: f32) -> i32 {
    if v.is_nan() { i32::MIN } else { v as i32 }
}

/// One-rounding a·b + c (PPC `fmadds`).
#[inline]
pub fn fused(a: f32, b: f32, c: f32) -> f32 {
    a.mul_add(b, c)
}

/// The quarter-sine table used by the Oscillator (257 entries): T[i] = min(65535,
/// floor(65536·sin(i·π/512))). Generated from the formula; it equals the retail table on all 257
/// entries (checked with `tools/re/aems_image_consts.py`).
pub fn quarter_sine() -> &'static [u16; 257] {
    use std::sync::OnceLock;
    static TABLE: OnceLock<[u16; 257]> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut t = [0u16; 257];
        for (i, v) in t.iter_mut().enumerate() {
            let s = (65536.0 * (i as f64 * std::f64::consts::PI / 512.0).sin()).floor();
            *v = s.min(65535.0) as u16;
        }
        t
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rounding_matches_fctiwz_rules() {
        assert_eq!(round(1.5), 2);
        assert_eq!(round(-1.5), -2);
        assert_eq!(round(0.49), 0);
        assert_eq!(round(-0.5), -1);
        assert_eq!(round(f32::NAN), i32::MIN);
        assert_eq!(round(3.0e10), i32::MAX);
        assert_eq!(round(-3.0e10), i32::MIN);
    }

    #[test]
    fn sine_table_endpoints() {
        let t = quarter_sine();
        assert_eq!(t[0], 0);
        assert_eq!(t[256], 65535);
        assert_eq!(t[128], (65536.0 * (std::f64::consts::PI / 4.0).sin()).floor() as u16);
    }
}
