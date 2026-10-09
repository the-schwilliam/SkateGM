//! Where the data-gated tests find the private research data (retail data, never committed). Each
//! kind has its own environment variable; the shared root `SKATE_AUDIO_RE_DIR` (the extracted
//! research data: `aems-banks/`, `splc-banks/`, `bank-wavs/`, `tricks/`, `golden/dsp/vectors.txt`)
//! fills in the ones that are not set. Nothing set → `None`, and the (ignored) test fails with
//! "missing private data".
#![allow(dead_code)]
use std::path::PathBuf;

fn var(name: &str) -> Option<PathBuf> {
    std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from)
}

/// `$SKATE_AUDIO_RE_DIR/<sub>`.
pub fn audio_re(sub: &str) -> Option<PathBuf> {
    var("SKATE_AUDIO_RE_DIR").map(|d| d.join(sub))
}

/// The disc's `.abk` / `.csi` files (`bank_layout_check.py --extract`): `SKATE_AEMS_BANKS`, else
/// `$SKATE_AUDIO_RE_DIR/aems-banks`.
pub fn aems_banks() -> Option<PathBuf> {
    var("SKATE_AEMS_BANKS").or_else(|| audio_re("aems-banks"))
}

/// The disc's SPLC `.bnk` files: `SKATE_SPLC_BANKS`, else `$SKATE_AUDIO_RE_DIR/splc-banks`.
pub fn splc_banks() -> Option<PathBuf> {
    var("SKATE_SPLC_BANKS").or_else(|| audio_re("splc-banks"))
}

/// One recomp session folder (with its `trace.tsv`): `<session_var>` (a session folder), else
/// `$SKATE_RECOMP_SESSIONS/<name>`.
pub fn recomp_session(session_var: &str, name: &str) -> Option<PathBuf> {
    var(session_var).or_else(|| var("SKATE_RECOMP_SESSIONS").map(|d| d.join(name)))
}

/// A file named by `file_var`, else `$SKATE_AUDIO_RE_DIR/<sub>`.
pub fn file(file_var: &str, sub: &str) -> Option<PathBuf> {
    var(file_var).or_else(|| audio_re(sub))
}
