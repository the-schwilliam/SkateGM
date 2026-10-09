//! Checks the format layer and the evaluator's load step against every bank on the disc, using the
//! census numbers in `audio-specs/aems-evaluator-spec.md` §1. Needs the disc's `.abk`/`.csi`
//! files extracted locally (`python tools/audio-file-inspect/bank_layout_check.py --extract <dir>`),
//! found through `SKATE_AEMS_BANKS=<dir>` or `$SKATE_AUDIO_RE_DIR/aems-banks`; ignored, and fails
//! loudly when they are absent (retail data is never committed).
use std::path::PathBuf;

use skate_audio::be::{u8_at, u16_at};
use skate_audio::eval::{Evaluator, OpenRequest, VoiceHost, VoiceStatus};
use skate_audio::formats::{Bank, Project};

mod private_data;

fn banks_dir() -> Option<PathBuf> {
    let dir = private_data::aems_banks()?;
    dir.join("csi_order.txt").is_file().then_some(dir)
}

fn load(dir: &PathBuf) -> (Vec<Project>, Vec<Bank>) {
    let order = std::fs::read_to_string(dir.join("csi_order.txt")).unwrap();
    let projects = order.lines().map(|n| Project::parse(n, &std::fs::read(dir.join(n)).unwrap()).unwrap()).collect();
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|n| n.to_ascii_lowercase().ends_with(".abk"))
        .collect();
    names.sort();
    let banks = names.iter().map(|n| Bank::parse(n, std::fs::read(dir.join(n)).unwrap()).unwrap_or_else(|e| panic!("{e}"))).collect();
    (projects, banks)
}

#[test]
#[ignore = "needs the private install data"]
fn every_disc_bank_parses_and_matches_the_spec_census() {
    let Some(dir) = banks_dir() else {
        panic!("missing private data: no extracted banks");
    };
    let (projects, banks) = load(&dir);
    assert_eq!(projects.len(), 9);
    assert_eq!(banks.len(), 376);
    let modules: usize = banks.iter().map(|b| b.modules.len()).sum();
    assert_eq!(modules, 385);

    // Opcode census (§1.5).
    let mut census = [0usize; 40];
    let mut records = 0;
    for m in banks.iter().flat_map(|b| &b.modules) {
        for op in &m.program {
            census[op.opcode as usize] += 1;
            records += 1;
        }
    }
    let want = [
        385, 385, 252, 385, 385, 182, 50, 630, 599, 3, 2545, 1186, 1902, 837, 12, 3126, 190, 2653, 171, 0, 42, 366, 51, 969,
        863, 709, 267, 1527, 372, 800, 1958, 1450, 49, 310, 1145, 2093, 1927, 129, 1, 110,
    ];
    assert_eq!(census, want);
    assert_eq!(records, want.iter().sum::<usize>());

    // Subscription-state layout (§1.4): ops 0/2/1/37 read exactly the states we laid out, and the
    // Destroy state is the last op's block at datasize − 16.
    for (bank, m) in banks.iter().flat_map(|b| b.modules.iter().map(move |m| (b, m))) {
        let blocks = |opcode: u8| m.program.iter().filter(move |o| o.opcode == opcode).map(|o| o.block);
        for b in blocks(0) {
            assert_eq!(Some(b), m.destructor_state, "{} op 0", bank.name);
        }
        for b in blocks(1) {
            assert_eq!(Some(b), m.class_data_state, "{} op 1", bank.name);
        }
        for b in blocks(2) {
            assert!(m.global_states.contains(&b), "{} op 2 at {b}", bank.name);
        }
        for b in blocks(37) {
            assert!(m.function_states.contains(&b), "{} op 37 at {b}", bank.name);
        }
        assert_eq!(m.destroy_offset, m.data_size - 16, "{}", bank.name);
        assert_eq!(m.program.last().map(|o| (o.opcode, o.block)), Some((4, m.data_size - 16)), "{}", bank.name);
        // Ops 5 and 38: the clamp ranges are present exactly when the flag is set (block sizes).
        let t = m.template(&bank.data);
        for (i, op) in m.program.iter().enumerate() {
            let next = m.program.get(i + 1).map_or(m.data_size, |o| o.block);
            let size = next - op.block;
            let b = op.block as usize;
            match op.opcode {
                5 => {
                    let (flag, n) = (u8_at(t, b + 8) != 0, u32::from(u8_at(t, b + 9)));
                    assert_eq!(size, 12 + if flag { 8 * n } else { 0 } + 4 + 4 * n, "{} op 5", bank.name);
                }
                38 => {
                    let (flag, n) = (u8_at(t, b + 12) != 0, u32::from(u8_at(t, b + 13)));
                    assert_eq!(size, 16 + if flag { 8 * n } else { 0 } + 8 + 4 * n, "{} op 38", bank.name);
                }
                27 => {
                    // Player inputs: 12 B records after +28, then the outputs.
                    let n = u32::from(u8_at(t, b + 14));
                    let update = u8_at(t, b + 15) != 0;
                    assert_eq!(size, 28 + 12 * n + if update { 8 } else { 0 }, "{} op 27", bank.name);
                    let _ = u16_at(t, b);
                }
                _ => {}
            }
        }
    }
}

#[test]
#[ignore = "needs the private install data"]
fn exports_resolve_like_retail() {
    let Some(dir) = banks_dir() else {
        panic!("missing private data: no extracted banks");
    };
    let (projects, banks) = load(&dir);
    let mut eval = Evaluator::new();
    for p in &projects {
        eval.install_project(p);
    }
    let mut unresolved = Vec::new();
    let mut total = 0;
    for b in &banks {
        for e in &b.exports {
            total += 1;
            if eval.registry.lookup(e.kind, e.project, e.name_id, &e.name).is_none() {
                unresolved.push(e.name.clone());
            }
        }
    }
    unresolved.sort();
    assert_eq!(total, 1059);
    // §1.8: 4 of 1,059 exports find nothing.
    assert_eq!(unresolved, ["pa_announce_a_glb", "pa_announce_a_glb", "pa_announce_b_glb", "semi_horns_msg"]);
    for b in banks {
        eval.load_bank(b);
    }
    let emitter = eval.class_id("c_emitter").unwrap();
    // §1.10: 291 banks bind to c_emitter.
    assert_eq!(eval.registry.classes[emitter].constructors.len(), 291);
}

/// A device whose voices live for a fixed number of queries.
#[derive(Default)]
struct Timed {
    next: u32,
    left: std::collections::HashMap<u32, u32>,
}

impl VoiceHost for Timed {
    fn open(&mut self, _: &OpenRequest) -> Option<u32> {
        self.next += 1;
        self.left.insert(self.next, 20);
        Some(self.next)
    }
    fn release(&mut self, v: u32) {
        self.left.remove(&v);
    }
    fn pause(&mut self, _: u32) {}
    fn resume(&mut self, _: u32) {}
    fn set(&mut self, _: u32, _: u8, _: i32) {}
    fn set_azimuth(&mut self, _: u32, _: i32) {}
    fn query(&mut self, v: u32) -> VoiceStatus {
        match self.left.get_mut(&v) {
            Some(n) if *n > 0 => {
                *n -= 1;
                VoiceStatus { alive: true, remaining_ms: 32 * *n as i32, elapsed_ms: 0 }
            }
            _ => VoiceStatus::default(),
        }
    }
}

/// Op 38 (ControlClass) has no oracle (the PoC lacks it): check its lifecycle on Tazer, the one
/// bank that uses it. c_tazer owns a child post to c_tazer_grn_play; while the child instance lives
/// the op returns refcount 3 (owner + the child's destructor and ClassData clients), 1 once the
/// child ended itself; releasing the parent releases the child, and every instance and node goes
/// away.
#[test]
#[ignore = "needs the private install data"]
fn tazer_control_class_owns_and_releases_its_child() {
    let Some(dir) = banks_dir() else {
        panic!("missing private data: no extracted banks");
    };
    let mut eval = Evaluator::new();
    for name in std::fs::read_to_string(dir.join("csi_order.txt")).unwrap().lines() {
        eval.install_project(&Project::parse(name, &std::fs::read(dir.join(name)).unwrap()).unwrap());
    }
    let tazer = eval.load_bank(Bank::parse("Tazer.abk", std::fs::read(dir.join("Tazer.abk")).unwrap()).unwrap());
    eval.load_bank(Bank::parse("emitter_utility.abk", std::fs::read(dir.join("emitter_utility.abk")).unwrap()).unwrap());
    let mut dev = Timed::default();
    eval.post(eval.class_id("c_emitter_utility").unwrap(), &[]);
    let base_nodes = eval.node_count();
    let class = eval.class_id("c_tazer").unwrap();
    let node = eval.post(class, &[32767, 32767, 4096, 25000, 1, 1, 100, 0, 32767]);
    eval.trace = Some(Vec::new());
    let mut child_seen = 0;
    let mut owner_refcounts = std::collections::BTreeSet::new();
    for walk in 0..120 {
        if walk == 25 {
            eval.redeliver(node, &[1, 16000, 500, 2, 3000, 0, 12000, 4096, 1]);
        }
        if walk == 75 {
            eval.redeliver(node, &[0, 20000, 5, 4096, 25000, 32767, 1, 2, 0]);
        }
        for _ in 0..6 {
            eval.block(&mut dev);
        }
        if eval.instances().iter().any(|&(_, b, m)| b == tazer && m == 1) {
            child_seen += 1;
        }
        for t in eval.trace.as_mut().unwrap().drain(..) {
            if t.opcode == 38 {
                owner_refcounts.insert(t.result);
            }
        }
    }
    assert!(child_seen > 0, "the ControlClass child never ran");
    // 0 = no child post; 3 = child instance alive (owner + its two clients); 1 = the child's program
    // ended it while the owner still holds the node.
    assert!(owner_refcounts.contains(&3), "{owner_refcounts:?}");
    assert!(owner_refcounts.iter().all(|r| [0, 1, 3].contains(r)), "{owner_refcounts:?}");
    eval.release(node);
    // The owner ends at once; children released by it end when their own programs say so (here
    // after their voices finish).
    let mut walks_to_clear = None;
    for walk in 0..200 {
        for _ in 0..6 {
            eval.block(&mut dev);
        }
        if eval.instances().iter().all(|&(_, b, _)| b != tazer) {
            walks_to_clear = Some(walk);
            break;
        }
    }
    eprintln!("Tazer cleared {walks_to_clear:?} walks after the release");
    assert!(eval.instances().iter().all(|&(_, b, _)| b != tazer), "Tazer instances left: {:?}", eval.instances());
    assert_eq!(eval.node_count(), base_nodes);
    assert!(dev.left.is_empty(), "voices left open");
}
