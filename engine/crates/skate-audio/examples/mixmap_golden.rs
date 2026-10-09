//! Run a MixMap golden script through the native port and write the watched outputs per
//! evaluation as CSV — the same script format and CSV as the PoC's `mixmap_golden` example and
//! our reference `mxb_tool.py eval` (spec `audio-specs/mixmap-spec.md` §9.1), so the three can
//! be diffed with `mxb_diff.py` / `mixmap_compare.py` (local, not published).
//!
//! Script lines: `dt <s>` | `dtat <eval> <s>` | `frames <n>` | `watch <key hex> <id> level|raw|pitch`
//! | `set <eval> <key hex> <id> <int|0xhex|f:float>`.
//!
//! usage: cargo run -p skate-audio --release --example mixmap_golden -- <MixMapSK8.mxb> <script> <out.csv>
use std::collections::BTreeMap;
use std::fmt::Write as _;

use skate_audio::mixmap::MixMap;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("usage: mixmap_golden <MixMapSK8.mxb> <script> <out.csv>");
        std::process::exit(2);
    }
    let bytes = std::fs::read(&args[1]).expect("read mxb");
    let script = std::fs::read_to_string(&args[2]).expect("read script");
    let mut dt = 1.0f64 / 60.0;
    let mut frames = 0usize;
    let mut dtat = BTreeMap::new();
    let mut watch: Vec<(u32, usize, String)> = Vec::new();
    let mut sets: Vec<(usize, u32, usize, u32)> = Vec::new();
    for line in script.lines() {
        let t: Vec<&str> = line.split_whitespace().collect();
        if t.is_empty() || t[0].starts_with('#') {
            continue;
        }
        let hex = |s: &str| u32::from_str_radix(s, 16).expect("hex key");
        match t[0] {
            "dt" => dt = t[1].parse().unwrap(),
            "dtat" => {
                dtat.insert(t[1].parse::<usize>().unwrap(), t[2].parse::<f64>().unwrap());
            }
            "frames" => frames = t[1].parse().unwrap(),
            "watch" => watch.push((hex(t[1]), t[2].parse().unwrap(), t[3].to_owned())),
            "set" => {
                let v = t[4];
                let value = if let Some(f) = v.strip_prefix("f:") {
                    f.parse::<f32>().unwrap().to_bits()
                } else if let Some(h) = v.strip_prefix("0x") {
                    u32::from_str_radix(h, 16).unwrap()
                } else {
                    v.parse::<i64>().unwrap() as u32
                };
                sets.push((t[1].parse().unwrap(), hex(t[2]), t[3].parse().unwrap(), value));
            }
            _ => {}
        }
    }
    sets.sort_by_key(|s| s.0);
    let mut m = MixMap::from_bytes(&bytes).expect("parse mxb");
    let mut out = String::from("frame");
    for (k, i, how) in &watch {
        write!(out, ",{k:x}:{i}:{how}").unwrap();
    }
    out.push('\n');
    let mut si = 0;
    for frame in 0..frames {
        if let Some(&d) = dtat.get(&frame) {
            dt = d;
        }
        while si < sets.len() && sets[si].0 <= frame {
            let (_, key, id, value) = sets[si];
            m.set_input(key, id, value as i32);
            si += 1;
        }
        // The script's dt is a double; the evaluator takes it as f32 like retail.
        m.tick(dt as f32);
        write!(out, "{frame}").unwrap();
        for (k, i, how) in &watch {
            let v = match how.as_str() {
                "level" => m.level(*k, *i),
                "raw" => m.raw(*k, *i),
                _ => m.pitch_4096(*k, *i),
            };
            write!(out, ",{v}").unwrap();
        }
        out.push('\n');
    }
    std::fs::write(&args[3], out).expect("write csv");
    println!("wrote {} ({frames} frames, {} watched outputs)", args[3], watch.len());
}
