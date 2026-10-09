//! List every bank's modules: bound class, capacity, payload words, players and the opcodes used.
//!
//! usage: aems_list <dir with the disc's .abk/.csi files> [name filter]
use std::path::Path;

use skate_audio::be::u8_at;
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
            let payload = m.class_data_state.map(|o| u8_at(m.template(&bank.data), o as usize + 16));
            let mut ops: Vec<u8> = m.program.iter().map(|o| o.opcode).collect();
            ops.sort_unstable();
            ops.dedup();
            println!(
                "{name} #{i} class={class} capacity={} payload={payload:?} players={} samples={} ops={ops:?}",
                m.max_instances,
                m.num_players,
                bank.samples.len()
            );
        }
    }
}
