//! The buses behind the voices (specs `audio-specs/aems-env-bus-spec.md`,
//! `audio-specs/aems-eqchain-buses-spec.md`): per block, voices add into the mono environment
//! input (their pre-gain Send A, and the owner one-shot buses' env send), into one of the eight
//! eEQChain buses or straight into SFX Master; then the environment network (orders 199–202) and
//! the eEQChain buses (253) render into SFX Master (254: gain 1, filters open — an identity in
//! retail's traces), which the output stage folds. Voices with an effect routing record also feed
//! one of the two FlangeSub returns (order 150, [`flange`]), which send on into the env input and
//! SFX Master.
pub mod env;
pub mod eqchain;
pub mod flange;
pub mod speech_echo;
pub mod submix;
pub mod zones;

use crate::BLOCK;

/// Where a voice's final 6-channel Send goes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Output {
    /// SFX Master (eEQChain 8, the default bus).
    #[default]
    Master,
    /// eEQChain bus 0..7.
    Eq(u8),
    /// A FootStep SubMix graph ([`submix`]; mono: route it with [`Route::mono`]). It sends on into
    /// the env bus and SFX Master. Falls back to SFX Master when the graph was never built.
    Submix(u8),
}

/// How a direct (Splice / stream) voice is routed: its output bus, whether resolving it may
/// re-roll the bus's EQ (`create`), and the env send of the owner one-shot bus it plays through
/// (`sub_82488DD0`: Sub0 → Sen0 env at the owner's level → Sen0 to the eEQChain bus), 0 = none.
/// `mono`: that bus is mono (the collision manager's per-voice "Collision SubMix",
/// `sub_824D25E0`): the voice's six channels sum into it (routes 6 → 1, LFE dropped) and it sends
/// on into its bus's centre (1 → 6).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Route {
    pub output: Output,
    pub create: bool,
    pub owner_env: f32,
    pub mono: bool,
}

pub struct Buses {
    pub env_in: Box<[f32; BLOCK]>,
    pub eq_in: Box<[[[f32; BLOCK]; 6]; 8]>,
    pub env: env::EnvNetwork,
    pub eq: eqchain::EqBuses,
    /// The FlangeSub returns' mono inputs (A, B) and whether any voice sent into them this block.
    pub flange_in: Box<[[f32; BLOCK]; 2]>,
    pub flange_active: [bool; 2],
    pub flange: flange::FlangeReturns,
    /// The FootStep SubMix graphs (`player::footsteps`).
    pub submix: submix::FootSubmixes,
    /// The speech stream slots' echo submixes (`world::speech_player`).
    pub speech_echo: speech_echo::SpeechEchoes,
}

impl Default for Buses {
    fn default() -> Self {
        Self {
            env_in: Box::new([0.0; BLOCK]),
            eq_in: Box::new([[[0.0; BLOCK]; 6]; 8]),
            env: env::EnvNetwork::default(),
            eq: eqchain::EqBuses::default(),
            flange_in: Box::new([[0.0; BLOCK]; 2]),
            flange_active: [false; 2],
            flange: flange::FlangeReturns::default(),
            submix: submix::FootSubmixes::default(),
            speech_echo: speech_echo::SpeechEchoes::default(),
        }
    }
}

impl Buses {
    pub fn clear_inputs(&mut self) {
        self.env_in.fill(0.0);
        for bus in self.eq_in.iter_mut() {
            for ch in bus.iter_mut() {
                ch.fill(0.0);
            }
        }
        if self.flange.enabled() {
            for ch in self.flange_in.iter_mut() {
                ch.fill(0.0);
            }
            self.flange_active = [false; 2];
        }
    }

    /// The 6-channel input a voice's final Send adds into.
    pub fn target<'a>(&'a mut self, output: Output, master: &'a mut [[f32; BLOCK]; 6]) -> &'a mut [[f32; BLOCK]; 6] {
        match output {
            Output::Eq(i) if i < 8 => &mut self.eq_in[usize::from(i)],
            Output::Submix(i) if self.submix.graphs.get(usize::from(i)).is_some_and(Option::is_some) => {
                self.submix.input(i).expect("built graph")
            }
            _ => master,
        }
    }

    /// Render the FootStep SubMix graphs (when built), the FlangeSub returns (when enabled), the env network and the eEQChain buses into
    /// SFX Master.
    pub fn render(&mut self, master: &mut [[f32; BLOCK]; 6]) {
        self.submix.render(&mut self.env_in, master);
        self.speech_echo.render(&mut self.env_in);
        if self.flange.enabled() {
            for (k, r) in self.flange.returns.iter_mut().enumerate() {
                r.render(&mut self.flange_in[k], self.flange_active[k], &mut self.env_in, master);
            }
        }
        self.env.render(&self.env_in, master);
        self.eq.render(&mut self.eq_in, master);
    }
}
