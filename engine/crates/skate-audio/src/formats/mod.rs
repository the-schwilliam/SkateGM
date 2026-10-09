//! Disc containers used by the AEMS runtime. Layouts: `audio-specs/aems-evaluator-spec.md` §1.
pub mod abk;
pub mod csi;
pub mod snr;

pub use abk::{Bank, Export, InterfaceKind, Module, Op};
pub use csi::Project;
pub use snr::SampleHeader;

/// A container that failed validation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FormatError(pub String);

impl std::fmt::Display for FormatError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for FormatError {}

pub(crate) fn err<T>(msg: impl Into<String>) -> Result<T, FormatError> {
    Err(FormatError(msg.into()))
}
