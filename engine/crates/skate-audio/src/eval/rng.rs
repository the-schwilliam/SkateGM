//! The AEMS random generator (spec §2.8): six u32 words shared by every instance, used only by
//! ops 7, 8 and 9. All zero at boot; deterministic from there.

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Rng {
    pub w: [u32; 6],
}

impl Rng {
    pub fn new(state: [u32; 6]) -> Self {
        Self { w: state }
    }

    /// One draw; returns the low 32 bits of the new w0.
    pub fn draw(&mut self) -> u32 {
        let w = &mut self.w;
        // Ripple-add upward: w4 += w5, then w3 += w4' + carry, … w0 += w1' + carry. The carry of each
        // step is "the result is below the original word" (retail's compare-based carry).
        let mut carry = 0u32;
        for k in (0..5).rev() {
            let original = w[k];
            w[k] = original.wrapping_add(w[k + 1]).wrapping_add(carry);
            carry = u32::from(w[k] < original);
        }
        // Then w5 += 1, rippling an increment upward while words wrap to zero.
        w[5] = w[5].wrapping_add(1);
        if w[5] == 0 {
            for k in (0..5).rev() {
                w[k] = w[k].wrapping_add(1);
                if w[k] != 0 {
                    break;
                }
            }
        }
        w[0]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_draws_from_zero() {
        let mut r = Rng::default();
        assert_eq!([r.draw(), r.draw(), r.draw()], [0, 1, 7]);
        assert_eq!(r.w, [7, 6, 5, 4, 3, 3]);
    }

    #[test]
    fn full_ripple_of_the_increment() {
        let mut r = Rng::new([0, 0, 0, 0, 0, 0xFFFF_FFFF]);
        // w4 += w5 → FFFFFFFF (no carry), w3..w0 take FFFFFFFF in turn; w5 wraps to 0 and the
        // increment ripples through every word.
        let v = r.draw();
        assert_eq!(r.w, [0, 0, 0, 0, 0, 0]);
        assert_eq!(v, 0);
    }
}
