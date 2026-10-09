//! Stateful audio bridge fields from TU3, kept separately from gameplay state.

/// Off-board hold clock at audio state309..319 (824B0DA8).
#[derive(Clone, Copy, Debug, Default)]
pub struct OffboardHold {
    pub latched: bool,
    pub clock: f32,
    pub start: f32,
}
impl OffboardHold {
    /// `held` is OffBoard309 (Processed2480bit18), not board-in-hand OffBoard311.
    pub fn tick(&mut self, held: bool, signed_speed: f32, dt: f32) -> bool {
        let mut expired = false;
        if held {
            if !self.latched {
                self.latched = true;
                self.start = self.clock;
            }
            if self.clock > self.start {
                let scaled = signed_speed * f32::from_bits(0x3df5_c28f);
                let low = if -scaled >= 0.0 { 0.0 } else { scaled };
                let factor = if 1.0 - low >= 0.0 { low } else { 1.0 };
                expired = self.clock - self.start > (1.0 - factor) * f32::from_bits(0x3ecc_cccd);
            }
        } else {
            self.latched = false;
        }
        self.clock += dt;
        expired
    }
}
