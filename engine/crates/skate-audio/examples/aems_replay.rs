//! Replay a post script through the native evaluator with the oracle's mock voice device and print
//! every device call, in the same format as the local PoC probe (`aems_golden.rs`, local, not
//! published), so the two outputs can be diffed line by line (a local diff script, not published).
//!
//! usage: aems_replay <dir with the disc's .abk/.csi files> <script> [--trace]
//! Script lines: `banks a.abk,b.abk` · `utility` · `global name=value` ·
//! `post <block> <class> <w0,w1,...>` · `redeliver <block> <k> <words>` · `release <block> <k>` ·
//! `blocks <n>`. The projects are installed in the order of `csi_order.txt` in that directory
//! (the archive order), else alphabetically.
//!
//! Mock device: a voice lives while now < open + duration (frames / rate; loops forever); query
//! remaining = trunc((end − now)·1000), elapsed = trunc((now − open)·1000), loops 1e9;
//! now = block · f64(f32(256/48000)).
use std::collections::HashMap;
use std::path::Path;

use skate_audio::eval::{Evaluator, NodeId, OpenRequest, VoiceHost, VoiceStatus};
use skate_audio::formats::{Bank, Project, SampleHeader};

struct Mock {
    block: u64,
    now: f64,
    next: u32,
    headers: HashMap<usize, Vec<Option<SampleHeader>>>,
    live: HashMap<u32, (f64, f64)>,
}

impl VoiceHost for Mock {
    fn open(&mut self, r: &OpenRequest) -> Option<u32> {
        self.next += 1;
        let header = self.headers.get(&r.bank).and_then(|h| h.get(r.slot as usize).copied().flatten());
        let (duration, looping) = header.map_or((1.0, false), |h| (h.seconds(), h.loop_start.is_some()));
        let az: Vec<String> = r.azimuth.iter().map(u8::to_string).collect();
        println!(
            "{} OPEN v{} slot={} level={} az={} stream={:x} n={}",
            self.block,
            self.next,
            r.slot as i16,
            r.level,
            az.join(","),
            r.stream_offset,
            r.inputs.len()
        );
        let end = if looping { f64::INFINITY } else { self.now + duration };
        self.live.insert(self.next, (self.now, end));
        Some(self.next)
    }
    fn release(&mut self, voice: u32) {
        println!("{} REL v{voice}", self.block);
        self.live.remove(&voice);
    }
    fn pause(&mut self, voice: u32) {
        println!("{} PAUSE v{voice}", self.block);
    }
    fn resume(&mut self, voice: u32) {
        println!("{} RESUME v{voice}", self.block);
    }
    fn set(&mut self, voice: u32, id: u8, value: i32) {
        println!("{} SET v{voice} {id} {value}", self.block);
    }
    fn set_azimuth(&mut self, voice: u32, value: i32) {
        println!("{} AZ v{voice} {value}", self.block);
    }
    fn query(&mut self, voice: u32) -> VoiceStatus {
        let Some(&(start, end)) = self.live.get(&voice) else { return VoiceStatus::default() };
        let alive = self.now < end;
        if !alive {
            println!("{} END v{voice}", self.block);
            return VoiceStatus::default();
        }
        let remaining = if end.is_finite() { (end - self.now).max(0.0) } else { 1.0e6 };
        VoiceStatus { alive, remaining_ms: (remaining * 1000.0) as i32, elapsed_ms: ((self.now - start) * 1000.0) as i32 }
    }
}

enum Action {
    Post(String, Vec<i32>),
    Redeliver(usize, Vec<i32>),
    Release(usize),
}

fn words(s: &str) -> Vec<i32> {
    s.split(',').filter(|s| !s.is_empty()).map(|s| s.trim().parse::<i64>().unwrap() as i32).collect()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: aems_replay <banks dir> <script> [--trace]");
        std::process::exit(2);
    }
    let dir = Path::new(&args[1]);
    let script = std::fs::read_to_string(&args[2]).expect("script");
    let trace = args.iter().any(|a| a == "--trace");
    let mut banks = Vec::new();
    let mut utility = false;
    let mut globals_set = Vec::new();
    let mut actions: Vec<(u64, Action)> = Vec::new();
    let mut blocks = 0u64;
    for line in script.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        match parts[0] {
            "banks" => banks = parts[1].split(',').map(str::to_string).collect(),
            "utility" => utility = true,
            "global" => {
                let (k, v) = parts[1].split_once('=').unwrap();
                globals_set.push((k.to_string(), v.parse::<i64>().unwrap() as i32));
            }
            "post" => actions.push((parts[1].parse().unwrap(), Action::Post(parts[2].to_string(), words(parts.get(3).unwrap_or(&""))))),
            "redeliver" => actions.push((parts[1].parse().unwrap(), Action::Redeliver(parts[2].parse().unwrap(), words(parts[3])))),
            "release" => actions.push((parts[1].parse().unwrap(), Action::Release(parts[2].parse().unwrap()))),
            "blocks" => blocks = parts[1].parse().unwrap(),
            other => panic!("unknown script line {other}"),
        }
    }

    let mut eval = Evaluator::new();
    let order = std::fs::read_to_string(dir.join("csi_order.txt")).map(|s| s.lines().map(str::to_string).collect::<Vec<_>>()).unwrap_or_else(|_| {
        let mut v: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .filter_map(|e| e.ok()?.file_name().into_string().ok())
            .filter(|n| n.ends_with(".csi"))
            .collect();
        v.sort();
        v
    });
    for name in &order {
        let bytes = std::fs::read(dir.join(name)).expect("csi");
        eval.install_project(&Project::parse(name, &bytes).expect("csi parse"));
        println!("# project {name}");
    }
    let mut mock = Mock { block: 0, now: 0.0, next: 0, headers: HashMap::new(), live: HashMap::new() };
    for name in &banks {
        let bytes = std::fs::read(dir.join(name)).unwrap_or_else(|e| panic!("{name}: {e}"));
        let bank = Bank::parse(name, bytes).expect("bank parse");
        let headers = bank.samples.iter().map(|s| s.1).collect();
        let id = eval.load_bank(bank);
        mock.headers.insert(id, headers);
        println!("# bank {name}");
    }
    for (k, v) in &globals_set {
        let g = eval.global_id(k).unwrap_or_else(|| panic!("no global {k}"));
        eval.registry.globals[g].value = *v;
    }
    if utility {
        let c = eval.class_id("c_emitter_utility").expect("c_emitter_utility");
        eval.post(c, &[]);
        println!("# utility posted");
    }
    if trace {
        eval.trace = Some(Vec::new());
    }
    let mut nodes: Vec<NodeId> = Vec::new();
    let delta = f64::from(256.0f32 / 48000.0f32);
    for b in 0..blocks {
        mock.block = b;
        mock.now = b as f64 * delta;
        for (at, action) in &actions {
            if *at != b {
                continue;
            }
            match action {
                Action::Post(class, payload) => {
                    let c = eval.class_id(class).unwrap_or_else(|| panic!("no class {class}"));
                    nodes.push(eval.post(c, payload));
                    println!("{b} POST {} {class}", nodes.len() - 1);
                }
                Action::Redeliver(k, payload) => eval.redeliver(nodes[*k], payload),
                Action::Release(k) => {
                    eval.release(nodes[*k]);
                    println!("{b} RELEASE {k}");
                }
            }
        }
        eval.block(&mut mock);
        if let Some(t) = &mut eval.trace {
            for op in t.drain(..) {
                println!("# op walk={} inst={} m={} op={} blk={} r={}", op.walk, op.instance, op.module, op.opcode, op.block, op.result);
            }
        }
    }
}
