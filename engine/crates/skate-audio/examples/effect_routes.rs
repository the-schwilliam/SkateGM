//! Census of the voice routing records (player input records with id ≥ 9) of every bank: which
//! modules route their voices into the FlangeSub effect returns (values 4096 / 8192 / 16384, then
//! an enable record and a level record), into an eEQChain bus (0–7, 10–17) or a fixed bus
//! (512 / 2048). Template (authored) values; a program may overwrite the words at run time
//! (the record's value word is then also an op output — flagged "dyn").
//!
//! usage: effect_routes <dir with the disc's .abk/.csi files> [name filter]
use std::collections::BTreeMap;
use std::path::Path;

use skate_audio::be::{i32_at, u8_at};
use skate_audio::eval::Evaluator;
use skate_audio::eval::symbols::SymRef;
use skate_audio::formats::{Bank, Project};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let dir = Path::new(&args[1]);
    let filter = args.get(2).map(|s| s.to_ascii_lowercase());
    let mut eval = Evaluator::new();
    for name in std::fs::read_to_string(dir.join("csi_order.txt")).expect("csi_order.txt").lines() {
        eval.install_project(&Project::parse(name, &std::fs::read(dir.join(name)).unwrap()).unwrap());
    }
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|n| n.to_ascii_lowercase().ends_with(".abk"))
        .filter(|n| filter.as_ref().is_none_or(|f| n.to_ascii_lowercase().contains(f)))
        .collect();
    names.sort();
    let mut totals: BTreeMap<i32, usize> = BTreeMap::new();
    for name in names {
        let bank = Bank::parse(&name, std::fs::read(dir.join(&name)).unwrap()).unwrap();
        for (i, m) in bank.modules.iter().enumerate() {
            let class = bank
                .exports
                .iter()
                .find(|e| e.handle_offset == m.offset + 4)
                .and_then(|e| eval.registry.lookup(e.kind, e.project, e.name_id, &e.name))
                .and_then(|s| match s {
                    SymRef::Class(c) => Some(eval.registry.classes[c].name.clone()),
                    _ => None,
                })
                .unwrap_or_else(|| "?".into());
            let t = m.template(&bank.data);
            // Every instance offset some op writes to (op outputs: the second word of each pair).
            let outputs: Vec<i32> = m.program.iter().flat_map(|o| o.pairs.iter().map(move |p| o.block as i32 + p.1)).collect();
            for (p, &b) in m.players().iter().enumerate() {
                let b = b as usize;
                if b + 28 > t.len() {
                    continue;
                }
                let n = u8_at(t, b + 14) as usize;
                let recs: Vec<(u8, i32, bool)> = (0..n)
                    .filter(|k| b + 36 + 12 * k + 4 <= t.len())
                    .map(|k| {
                        let at = b + 28 + 12 * k;
                        (u8_at(t, at), i32_at(t, at + 8), outputs.contains(&((at + 8) as i32)))
                    })
                    .collect();
                let routing: Vec<String> = recs
                    .iter()
                    .filter(|r| r.0 >= 9)
                    .map(|r| format!("{}={}{}", r.0, r.1, if r.2 { "(dyn)" } else { "" }))
                    .collect();
                if routing.is_empty() {
                    continue;
                }
                for r in recs.iter().filter(|r| r.0 >= 9) {
                    *totals.entry(r.1).or_default() += 1;
                }
                let fx = recs.iter().any(|r| r.0 >= 9 && matches!(r.1, 4096 | 8192 | 16384));
                println!(
                    "{}{name} #{i} player {p} class={class} n={n} routing [{}]",
                    if fx { "FX " } else { "   " },
                    routing.join(" ")
                );
            }
        }
    }
    println!("totals by value: {totals:?}");
}
