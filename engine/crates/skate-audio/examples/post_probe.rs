//! Post one class with a payload through the evaluator (every project + the named banks loaded)
//! and print what reaches the voice host: the open requests' input records (routing ids ≥ 9) and
//! every property set, per block. A headless check of what a component's words do to its voices.
//!
//! usage: post_probe <banks dir> <bank stem[,stem…]> <class> <w0,w1,…> [blocks] [redeliver words]
use std::path::Path;

use skate_audio::eval::{Evaluator, OpenRequest, VoiceHost, VoiceStatus};
use skate_audio::formats::{Bank, Project};

struct Log {
    block: usize,
    next: u32,
}

impl VoiceHost for Log {
    fn open(&mut self, r: &OpenRequest) -> Option<u32> {
        self.next += 1;
        println!("b{:<4} open v{} bank {} slot {} inputs {:?}", self.block, self.next, r.bank, r.slot, r.inputs);
        Some(self.next)
    }
    fn release(&mut self, v: u32) {
        println!("b{:<4} release v{v}", self.block);
    }
    fn pause(&mut self, _: u32) {}
    fn resume(&mut self, _: u32) {}
    fn set(&mut self, v: u32, id: u8, value: i32) {
        println!("b{:<4} set v{v} id {id} = {value}", self.block);
    }
    fn set_azimuth(&mut self, v: u32, value: i32) {
        println!("b{:<4} azimuth v{v} = {value}", self.block);
    }
    fn query(&mut self, _: u32) -> VoiceStatus {
        VoiceStatus { alive: true, remaining_ms: 10_000, elapsed_ms: 0 }
    }
}

fn words(s: &str) -> Vec<i32> {
    s.split(',').filter(|w| !w.is_empty()).map(|w| w.trim().parse().unwrap()).collect()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let dir = Path::new(&args[1]);
    let mut eval = Evaluator::new();
    for name in std::fs::read_to_string(dir.join("csi_order.txt")).expect("csi_order.txt").lines() {
        eval.install_project(&Project::parse(name, &std::fs::read(dir.join(name)).unwrap()).unwrap());
    }
    for stem in args[2].split(',') {
        let file = format!("{stem}.abk");
        eval.load_bank(Bank::parse(&file, std::fs::read(dir.join(&file)).unwrap()).unwrap());
    }
    let class = eval.class_id(&args[3]).expect("class");
    let payload = words(&args[4]);
    let blocks: usize = args.get(5).map_or(60, |b| b.parse().unwrap());
    let again = args.get(6).map(|s| words(s));
    let node = eval.post(class, &payload);
    let mut host = Log { block: 0, next: 0 };
    for b in 0..blocks {
        host.block = b;
        if b == blocks / 2 {
            if let Some(w) = &again {
                eval.redeliver(node, w);
            }
        }
        eval.block(&mut host);
    }
}
