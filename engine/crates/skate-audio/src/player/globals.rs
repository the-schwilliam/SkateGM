//! Game-global words the trick and treatment components read outside the per-player audio state
//! (`AudioState`): the audio game block `G = *(0x83083C38) + 0x2F070` word `G+96` and the game-flow
//! object `X = *(0x830CFDC4)` field `X+1060`. Free-skate values as the defaults (spec
//! `audio-specs/aems-tricks-treatment-spec.md` §4).

/// `G+96` bit read by `Class_Treatment`'s process (with `sub_8279E180` false and the time scale
/// below 1.0 it posts the slow-motion companion).
pub const SLO_MO_BIT: u32 = 0x0400_0000;
/// `G+96` bits of the Tricks slew (`sub_824CD170`): the first set one picks the target.
pub const SLEW_BITS: [u32; 3] = [0x8000, 0x4000, 0x2000];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Globals {
    /// `G+96`. Its writer was not located; 0 in free skate (no bit set: the Tricks slew target is 0
    /// and the slow-motion companion is not posted — retail's free-skate sessions post neither).
    pub flags_96: u32,
    /// `X+1060`, the game-flow mode: 7 in free skate (the Treatment process posts
    /// `hall_of_meat_slo_mo` whenever it is not 7, with w14 = mode − 7; `sub_824898C8` takes 8 as
    /// "slew to full"). None of the clean retail sessions posts the companion, so free skate is 7.
    pub mode_1060: i32,
}

impl Default for Globals {
    fn default() -> Self {
        Self { flags_96: 0, mode_1060: 7 }
    }
}

impl Globals {
    /// `sub_824898C8`: `G+96` bit 13, or `X+932` with the copied `X+476` byte (not modelled:
    /// false), or mode 8.
    pub fn slew_full(&self) -> bool {
        self.flags_96 & 0x2000 != 0 || self.mode_1060 == 8
    }
}
