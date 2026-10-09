//! Dump one class's program (op, data block, copy pairs) and trace it while a held packet is
//! redelivered with a toggling trigger word: every op's result per walk and every voice open.
//! A headless look at how a program turns packet words into sample choices.
//!
//! usage: program_trace <banks dir> <bank stem> <class> <w0,w1,…> [trigger word] [walks] [period]
//! The trigger word (default 7) alternates 1 / 2 every `period` walks (default 2), 0 in between.
use std::path::Path;

use skate_audio::eval::symbols::SymRef;
use skate_audio::eval::{Evaluator, OpenRequest, VoiceHost, VoiceStatus};
use skate_audio::formats::{Bank, Project};

struct Log {
    walk: usize,
    next: u32,
}

impl VoiceHost for Log {
    fn open(&mut self, r: &OpenRequest) -> Option<u32> {
        self.next += 1;
        println!("w{:<4} OPEN v{} slot {} inputs {:?}", self.walk, self.next, r.slot, r.inputs);
        Some(self.next)
    }
    fn release(&mut self, _: u32) {}
    fn pause(&mut self, _: u32) {}
    fn resume(&mut self, _: u32) {}
    fn set(&mut self, _: u32, _: u8, _: i32) {}
    fn set_azimuth(&mut self, _: u32, _: i32) {}
    fn query(&mut self, _: u32) -> VoiceStatus {
        VoiceStatus { alive: true, remaining_ms: 10_000, elapsed_ms: 0 }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let dir = Path::new(&args[1]);
    let mut eval = Evaluator::new();
    for name in std::fs::read_to_string(dir.join("csi_order.txt")).expect("csi_order.txt").lines() {
        eval.install_project(&Project::parse(name, &std::fs::read(dir.join(name)).unwrap()).unwrap());
    }
    if args[2] == "-classes" {
        for (i, c) in eval.registry.classes.iter().enumerate() {
            println!("class {i:3} {}", c.name);
        }
        for name in std::fs::read_to_string(dir.join("csi_order.txt")).unwrap().lines() {
            let p = Project::parse(name, &std::fs::read(dir.join(name)).unwrap()).unwrap();
            for (t, table) in p.tables.iter().enumerate() {
                for (k, s) in table.iter().enumerate() {
                    println!("project {} ({}) table {t} #{k} id {} {}", p.name, p.id, s.name_id, s.name);
                }
            }
        }
        return;
    }
    let file = format!("{}.abk", args[2]);
    let bank = Bank::parse(&file, std::fs::read(dir.join(&file)).unwrap()).unwrap();
    for (i, m) in bank.modules.iter().enumerate() {
        println!("module {i}: {} ops", m.program.len());
        for e in &bank.exports {
            if e.handle_offset >= m.template_offset && e.handle_offset < m.template_offset + m.data_size {
                let sym = eval.registry.lookup(e.kind, e.project, e.name_id, &e.name);
                let name = match sym {
                    Some(SymRef::Global(g)) => format!("global {}", eval.registry.globals[g].name),
                    Some(SymRef::Function(f)) => format!("function {}", eval.registry.functions[f].name),
                    Some(SymRef::Class(c)) => format!("class {}", eval.registry.classes[c].name),
                    _ => format!("? {}", e.name),
                };
                println!("  handle @{} = {name}", e.handle_offset - m.template_offset);
            }
        }
        for (k, op) in m.program.iter().enumerate() {
            println!("  #{k:3} op {:2} block {:5} pairs {:?}", op.opcode, op.block, op.pairs);
        }
    }
    eval.load_bank(bank);
    // PRE=stem:class,… loads more banks and posts those classes first (boot utilities).
    if let Ok(pre) = std::env::var("PRE") {
        let mut host = Log { walk: 0, next: 1000 };
        for item in pre.split(',').filter(|s| !s.is_empty()) {
            let (stem, class) = item.split_once(':').expect("stem:class");
            let file = format!("{stem}.abk");
            eval.load_bank(Bank::parse(&file, std::fs::read(dir.join(&file)).unwrap()).unwrap());
            eval.post(eval.class_id(class).expect("pre class"), &[]);
        }
        eval.walk(&mut host);
    }
    let class = eval.class_id(&args[3]).expect("class");
    let mut w: Vec<i32> = args[4].split(',').filter(|s| !s.is_empty()).map(|s| s.trim().parse().unwrap()).collect();
    let tw: usize = args.get(5).map_or(7, |v| v.parse().unwrap());
    let walks: usize = args.get(6).map_or(12, |v| v.parse().unwrap());
    let period: usize = args.get(7).map_or(2, |v| v.parse().unwrap());
    eval.trace = Some(Vec::new());
    let node = eval.post(class, &w);
    let mut host = Log { walk: 0, next: 0 };
    let mut toggle = false;
    for k in 0..walks {
        host.walk = k;
        w[tw] = if k % period == 0 {
            toggle = !toggle;
            if toggle { 1 } else { 2 }
        } else {
            0
        };
        eval.redeliver(node, &w);
        eval.walk(&mut host);
        for t in eval.trace.as_mut().unwrap().drain(..) {
            println!("w{k:<4} i{} m{} op {:2} @{:5} = {}", t.instance, t.module, t.opcode, t.block, t.result);
        }
    }
}
