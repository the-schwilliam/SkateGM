//! Skate 3's own trick display (gm_sk8 addition), from SK8-ENGINE/skate-3-rust-engine:
//! the original APT movie data/fe/source/screens/hud2/trickdisplay2, prepared
//! from the player's own game files by that project's tools/prepare_hud.py
//! (runtime/trickdisplay.json), run by its ActionScript VM (apt_vm.rs) and
//! timeline (apt_movie.rs) with the native bindings (hud_runtime.rs), and
//! flattened to textured triangles (apt_scene.rs). Lua draws the triangles.
pub mod apt_display;
pub mod apt_movie;
pub mod apt_scene;
pub mod apt_text;
pub mod apt_vm;
pub mod hud_runtime;

use std::path::Path;
use std::sync::Mutex;

pub struct State {
    pub runtime: hud_runtime::Runtime,
    pub source: serde_json::Value,
    pub shapes: apt_scene::Shapes,
    /// the engine tick last fed in
    pub tick: Option<u64>,
    pub failed: Option<String>,
}

pub static HUD: Mutex<Option<State>> = Mutex::new(None);

/// What the scoring gives the HUD each tick.
#[derive(Clone, Default)]
pub struct Feed {
    pub sequence_score: f32,
    pub line_score: f32,
    pub sequence_timer: i32,
    pub line_time: f32,
    pub line_capacity: f32,
    pub multiplier: f32,
    pub clean: bool,
    pub sketchy: bool,
    pub stance: [bool; 4],
    pub trick_name: String,
    pub new_trick: bool,
    pub modified_trick: bool,
    pub close_tricks: bool,
}

fn input(f: &Feed) -> hud_runtime::Input {
    use apt_vm::Value;
    hud_runtime::Input {
        sequence_score: f.sequence_score as i32,
        line_score: f.line_score as i32,
        sequence_timer: f.sequence_timer,
        line_time: f.line_time,
        line_capacity: f.line_capacity,
        multiplier: f.multiplier,
        clean: f.clean,
        sketchy: f.sketchy,
        stance: f.stance,
        trick_name: f.trick_name.clone(),
        trick_metrics: [
            Value::Text(f.trick_name.clone()),
            Value::Bool(f.stance[0]),
            Value::Bool(f.stance[1]),
            Value::Bool(false),
            Value::Bool(f.new_trick),
        ],
        context_tricks: Vec::new(),
    }
}

/// The prepared folder: the one given if it has the movie, otherwise
/// garrysmod/data/skategm_hud found from the working folder or the game's exe.
pub fn find(given: &Path) -> Option<std::path::PathBuf> {
    let movie = |p: &Path| p.join("runtime/trickdisplay.json").is_file();
    if !given.as_os_str().is_empty() && movie(given) {
        return Some(given.to_path_buf());
    }
    let mut starts = Vec::new();
    if let Ok(d) = std::env::current_dir() {
        starts.push(d);
    }
    if let Ok(e) = std::env::current_exe() {
        starts.extend(e.parent().map(Path::to_path_buf));
    }
    for start in starts {
        for dir in start.ancestors() {
            for rel in ["garrysmod/data/skategm_hud", "data/skategm_hud"] {
                let p = dir.join(rel);
                if movie(&p) {
                    return Some(p);
                }
            }
        }
    }
    None
}

/// Load runtime/trickdisplay.json from a prepared HUD folder (see `find`).
pub fn load(given: &Path) -> Result<(), String> {
    let root = find(given).ok_or("no prepared trick display (garrysmod/data/skategm_hud/runtime/trickdisplay.json)")?;
    let path = root.join("runtime/trickdisplay.json");
    let source: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?).map_err(|e| e.to_string())?;
    let runtime = hud_runtime::Runtime::load(&source, input(&Feed::default()))?;
    let shapes: apt_scene::Shapes = serde_json::from_value(source["shapes"].clone()).map_err(|e| e.to_string())?;
    *HUD.lock().unwrap_or_else(|e| e.into_inner()) = Some(State { runtime, source, shapes, tick: None, failed: None });
    Ok(())
}

/// Feed one engine tick's scoring (the movie advances one frame per tick).
pub fn feed(tick: u64, f: &Feed) {
    let mut guard = HUD.lock().unwrap_or_else(|e| e.into_inner());
    let Some(s) = guard.as_mut() else { return };
    if s.failed.is_some() {
        return;
    }
    // a new session (the tick went back): start the movie over
    if s.tick.is_some_and(|t| tick < t) {
        match hud_runtime::Runtime::load(&s.source, input(&Feed::default())) {
            Ok(r) => s.runtime = r,
            Err(e) => {
                s.failed = Some(e);
                return;
            }
        }
        s.tick = None;
    }
    // at most a second of frames at once (after a pause)
    let frames = s.tick.map_or(1, |t| tick.saturating_sub(t)).min(60);
    s.tick = Some(tick);
    for i in 0..frames {
        let first = i + 1 == frames;
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            s.runtime.update(input(f), first && f.new_trick, first && f.modified_trick, first && f.close_tricks)
        }))
        .unwrap_or_else(|_| Err("the trick display stopped (internal error)".to_string()));
        if let Err(e) = result {
            s.failed = Some(e);
            return;
        }
    }
}

/// 825E51A0 localizes each authored component before composing a literal.
pub(crate) fn localize_trick(label: &str, assets: Option<&apt_text::TextAssets>) -> String {
    if let Some(literal) = label.strip_prefix('#') {
        return literal.to_owned();
    }
    label
        .split_whitespace()
        .map(|part| {
            let text = assets.map(|a| a.localize(part)).unwrap_or_else(|| part.to_owned());
            if text.starts_with("ID_") {
                humanize_trick_id(&text)
            } else {
                text
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn humanize_trick_id(id: &str) -> String {
    let rest = id.strip_prefix("ID_TRICK_").or_else(|| id.strip_prefix("ID_")).unwrap_or(id);
    rest.split('_')
        .filter(|w| !w.is_empty())
        .map(|w| {
            let lower = w.to_ascii_lowercase();
            let mut c = lower.chars();
            match c.next() {
                None => String::new(),
                Some(f) => f.to_ascii_uppercase().to_string() + c.as_str(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}
