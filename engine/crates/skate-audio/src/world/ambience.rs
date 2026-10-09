//! TU3 zone-bed phase machine (`824D3C28`, `824D3FE0`, `824D41E0`).
//! Resource loading and voice graphs belong to the host; these are the native phase/timer rules.

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(u32)]
pub enum Phase {
    #[default]
    Silent = 0,
    Steady = 1,
    FadeOut = 2,
    FadeIn = 3,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Change {
    pub start_bed: bool,
    pub stop_bed: bool,
    pub start_crossfade: bool,
    pub stop_crossfade: bool,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Controller {
    pub current: u64,
    pub phase: Phase,
    pub out_time: f32,
    pub in_time: f32,
    crossfade: bool,
}

impl Controller {
    /// Native process pass. Durations are those of the current zone, not the desired zone.
    pub fn process(
        &mut self,
        desired: u64,
        dt: f32,
        fade_in: f32,
        fade_out: f32,
        crossfade_ready: bool,
    ) -> Change {
        let mut change = Change::default();
        if desired != self.current {
            match self.phase {
                Phase::Steady => {
                    if self.current == 0 {
                        self.phase = Phase::Silent;
                    } else {
                        self.phase = Phase::FadeOut;
                        self.out_time = 0.0;
                        if desired != 0 && crossfade_ready {
                            change.stop_crossfade = self.crossfade;
                            change.start_crossfade = true;
                            self.crossfade = true;
                        }
                    }
                    return change;
                }
                Phase::FadeOut => {
                    self.out_time += dt;
                    if self.out_time > fade_out {
                        change.stop_bed = true;
                        self.phase = Phase::Silent;
                    }
                    return change;
                }
                Phase::Silent => {
                    if desired != 0 {
                        self.phase = Phase::FadeIn;
                        self.in_time = 0.0;
                        change.start_bed = true;
                    }
                    self.current = desired;
                    return change;
                }
                Phase::FadeIn => {}
            }
        }
        // 824D41E0: a return to the old zone reverses the fade without advancing out_time.
        match self.phase {
            Phase::FadeIn => {
                self.in_time += dt;
                if self.in_time > fade_in {
                    change.stop_crossfade = self.crossfade;
                    self.crossfade = false;
                    self.phase = Phase::Steady;
                }
            }
            Phase::FadeOut => {
                self.in_time = (-(self.out_time / fade_out)).mul_add(fade_in, fade_in);
                self.phase = Phase::FadeIn;
            }
            _ => {}
        }
        change
    }

    /// Native input 0: quantize before complementing/clamping. No invented epsilon duration.
    pub fn input(&self, fade_in: f32, fade_out: f32) -> i32 {
        let integer = |x: f32| if x.is_nan() { i32::MIN } else { x as i32 };
        match self.phase {
            Phase::Silent => 32767,
            Phase::Steady => 0,
            Phase::FadeOut => integer((self.out_time / fade_out) * 32767.0).clamp(0, 32767),
            Phase::FadeIn => 32767i32
                .wrapping_sub(integer((self.in_time / fade_in) * 32767.0))
                .clamp(0, 32767),
        }
    }
}
