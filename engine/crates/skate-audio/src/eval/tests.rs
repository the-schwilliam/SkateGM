//! Evaluator tests on hand-built banks: posting, payload delivery, the player's open / push /
//! query / restart edge, release → destroy, capacity, and the function → global round trip with
//! its walk-order rule (spec §2, §5).
use super::*;
use super::synthetic::*;

#[derive(Default)]
struct Log {
    calls: Vec<String>,
    next: u32,
    alive: HashMap<u32, bool>,
}

impl VoiceHost for Log {
    fn open(&mut self, r: &OpenRequest) -> Option<u32> {
        self.next += 1;
        self.alive.insert(self.next, true);
        self.calls.push(format!("open v{} slot {}", self.next, r.slot));
        Some(self.next)
    }
    fn release(&mut self, v: u32) {
        self.calls.push(format!("release v{v}"));
    }
    fn pause(&mut self, v: u32) {
        self.calls.push(format!("pause v{v}"));
    }
    fn resume(&mut self, v: u32) {
        self.calls.push(format!("resume v{v}"));
    }
    fn set(&mut self, v: u32, id: u8, value: i32) {
        self.calls.push(format!("set v{v} {id}={value}"));
    }
    fn set_azimuth(&mut self, v: u32, value: i32) {
        self.calls.push(format!("az v{v} {value}"));
    }
    fn query(&mut self, v: u32) -> VoiceStatus {
        let alive = self.alive.get(&v).copied().unwrap_or(false);
        VoiceStatus { alive, remaining_ms: if alive { 500 } else { 0 }, elapsed_ms: 7 }
    }
}

fn setup(modules: Vec<Spec>, exports: Vec<Ex>) -> Evaluator {
    let mut e = Evaluator::new();
    e.install_project(&project());
    e.load_bank(bank(&modules, &exports, &[(48000, false), (24000, false)]));
    e
}

fn walk(e: &mut Evaluator, log: &mut Log) {
    for _ in 0..BLOCKS_PER_WALK {
        e.block(log);
    }
}

#[test]
fn walks_every_sixth_block_starting_on_the_sixth() {
    let mut e = setup(vec![player_module(2)], vec![Ex { module: 0, kind: 1, name_id: 1, name: "c_test", at: None }]);
    let mut log = Log::default();
    let walked: Vec<bool> = (0..13).map(|_| e.block(&mut log)).collect();
    assert_eq!(walked.iter().positions(), vec![5, 11]);
}

trait Positions {
    fn positions(self) -> Vec<usize>;
}
impl<'a, I: Iterator<Item = &'a bool>> Positions for I {
    fn positions(self) -> Vec<usize> {
        self.enumerate().filter(|e| *e.1).map(|e| e.0).collect()
    }
}

#[test]
fn post_opens_pushes_restarts_on_an_edge_and_release_destroys() {
    let mut e = setup(vec![player_module(1)], vec![Ex { module: 0, kind: 1, name_id: 1, name: "c_test", at: None }]);
    let class = e.class_id("c_test").unwrap();
    let mut log = Log::default();
    let node = e.post(class, &[1, 4096, 1]);
    assert_eq!(e.instances().len(), 1);
    // refcount: poster + destructor client + ClassData client.
    assert_eq!(e.node_refcount(node), Some(3));
    // Capacity 1: a second post creates nothing but still succeeds.
    let extra = e.post(class, &[1, 4096, 0]);
    assert_eq!(e.instances().len(), 1);
    e.release(extra);
    assert_eq!(e.node_refcount(extra), None);

    walk(&mut e, &mut log);
    assert_eq!(log.calls, ["open v1 slot 1", "set v1 0=4096"]);
    // Outputs: time left / current written in the same walk.
    let (id, ..) = e.instances()[0];
    let mem = e.instance_memory(id).unwrap();
    assert_eq!((i32_at(mem, 80 + 40), i32_at(mem, 80 + 44)), (500, 7));

    // A payload change pushes only the changed input, and clamps (0..65535).
    log.calls.clear();
    e.redeliver(node, &[1, 99999, 1]);
    walk(&mut e, &mut log);
    assert_eq!(log.calls, ["set v1 0=65535"]);

    // The voice ends: released, outputs cleared; play control is still 1 → no restart.
    log.calls.clear();
    log.alive.insert(1, false);
    walk(&mut e, &mut log);
    walk(&mut e, &mut log);
    assert_eq!(log.calls, ["release v1"]);
    let mem = e.instance_memory(id).unwrap();
    assert_eq!((i32_at(mem, 80 + 40), u32_at(mem, 80 + 8)), (0, 0));

    // A 0 → 1 edge restarts, and the open applies the full input set again.
    log.calls.clear();
    e.redeliver(node, &[0, 4096, 0]);
    walk(&mut e, &mut log);
    e.redeliver(node, &[1, 4096, 0]);
    walk(&mut e, &mut log);
    assert_eq!(log.calls, ["open v2 slot 0", "set v2 0=4096"]);

    // Release: the destructor pulse reaches Destroy in the same walk; the voice is released and
    // the node freed once every client is gone.
    log.calls.clear();
    e.release(node);
    assert_eq!(e.node_refcount(node), Some(2));
    walk(&mut e, &mut log);
    assert_eq!(log.calls, ["release v2"]);
    assert!(e.instances().is_empty());
    assert_eq!(e.node_refcount(node), None);
    // Capacity is free again.
    e.post(class, &[0, 0, 0]);
    assert_eq!(e.instances().len(), 1);
}

#[test]
fn pause_and_resume_follow_the_play_control() {
    let mut e = setup(vec![player_module(1)], vec![Ex { module: 0, kind: 1, name_id: 1, name: "c_test", at: None }]);
    let class = e.class_id("c_test").unwrap();
    let mut log = Log::default();
    let node = e.post(class, &[1, 4096, 0]);
    walk(&mut e, &mut log);
    log.calls.clear();
    e.redeliver(node, &[2, 4096, 0]);
    walk(&mut e, &mut log);
    e.redeliver(node, &[1, 4096, 0]);
    walk(&mut e, &mut log);
    assert_eq!(log.calls, ["pause v1", "resume v1"]);
    // A voice that died while paused is not restarted by 2 → 1.
    log.calls.clear();
    e.redeliver(node, &[2, 4096, 0]);
    walk(&mut e, &mut log);
    log.alive.insert(1, false);
    let (id, ..) = e.instances()[0];
    // Simulate the device dropping the handle while paused (the program sees no voice).
    {
        let i = e.instance_mut(id).unwrap();
        put_u32(&mut i.mem, 80 + 8, 0);
    }
    e.redeliver(node, &[1, 4096, 0]);
    walk(&mut e, &mut log);
    assert_eq!(log.calls, ["pause v1"]);
}

/// Requester (c_req): Create → op 5 calls f_msg with param 5; reads g_snd through a GlobalVariable
/// state into a word we inspect. Utility (c_util): op 37 on f_msg → op 39 publishes the parameter
/// into g_snd.
fn round_trip_modules() -> (Vec<Spec>, Vec<Ex>) {
    // Requester: destructor @24 (20 B), global state @44 (28 B), Create @72, op 5 @76 (handle 8 B,
    // flag 0, n 1 → inputs {trig @88, param @92}), sink word @96, Destroy @100, size 116.
    let mut t = words(29);
    put_i32(&mut t, 72, 1);
    put_u8(&mut t, 76 + 9, 1);
    put_i32(&mut t, 92, 5);
    let requester = Spec {
        max: 4,
        globals: 1,
        functions: 0,
        destructor: true,
        class_data: false,
        players: vec![],
        template: t,
        program: vec![
            (0, vec![(-1, 100 + 12 - 24)], 24),
            (2, vec![(-1, 96 - 44)], 44),
            (3, vec![(-1, 88 - 72)], 72),
            (5, vec![], 76),
            (4, vec![], 100),
        ],
        group_ptrs: vec![],
    };
    // Utility: function state @24 (n 1 → (1 + 7)·4 = 32 B → @24..56), op 39 @56 (handle, min,
    // max, prev, value → 24 B), Destroy @80, size 96.
    let mut t = words(24);
    put_u8(&mut t, 24 + 24, 1);
    put_i32(&mut t, 56 + 8, 0);
    put_i32(&mut t, 56 + 12, 1000);
    put_i32(&mut t, 56 + 16, 0x7FFF_FFFE);
    put_i32(&mut t, 56 + 20, 0x7FFF_FFFE);
    let utility = Spec {
        max: 1,
        globals: 0,
        functions: 1,
        destructor: false,
        class_data: false,
        players: vec![],
        template: t,
        // op 37: on a call, copy the parameter (+28) into op 39's value (+20).
        program: vec![(37, vec![(28, 56 + 20 - 24)], 24), (39, vec![], 56), (4, vec![], 80)],
        group_ptrs: vec![],
    };
    let exports = vec![
        Ex { module: 0, kind: 1, name_id: 3, name: "c_req", at: None },
        Ex { module: 0, kind: 0, name_id: 1, name: "g_snd", at: Some(44) },
        Ex { module: 0, kind: 2, name_id: 1, name: "f_msg", at: Some(76) },
        Ex { module: 1, kind: 1, name_id: 2, name: "c_util", at: None },
        Ex { module: 1, kind: 2, name_id: 1, name: "f_msg", at: Some(24) },
        Ex { module: 1, kind: 0, name_id: 1, name: "g_snd", at: Some(56) },
    ];
    (vec![requester, utility], exports)
}

#[test]
fn function_call_and_global_publish_follow_walk_order() {
    let (modules, exports) = round_trip_modules();
    let mut e = setup(modules, exports);
    let mut log = Log::default();
    let g = e.global_id("g_snd").unwrap();
    assert_eq!(e.global(g), Some(77)); // csi default
    e.post(e.class_id("c_util").unwrap(), &[]);
    let req = e.post(e.class_id("c_req").unwrap(), &[]);
    let (rid, ..) = e.instances()[0]; // newest first: the requester runs first
    // A new subscriber copies the global's current value at creation.
    assert_eq!(i32_at(e.instance_memory(rid).unwrap(), 44 + 24), 77);
    walk(&mut e, &mut log);
    // Walk 1: the requester read the old value (77), then called f_msg; the utility (older, later
    // in the walk) published 5 in the same walk, delivered synchronously into the requester's state.
    let mem = e.instance_memory(rid).unwrap();
    assert_eq!(i32_at(mem, 96), 77);
    assert_eq!(i32_at(mem, 44 + 24), 5);
    assert_eq!(e.global(g), Some(5));
    walk(&mut e, &mut log);
    assert_eq!(i32_at(e.instance_memory(rid).unwrap(), 96), 5);
    // Release: the requester ends; its subscription is gone.
    e.release(req);
    walk(&mut e, &mut log);
    assert_eq!(e.instances().len(), 1);
    assert!(e.registry.globals[g].subscribers.is_empty());
    // Setting the same value notifies nobody; a different one is stored.
    e.set_global(g, 5);
    e.set_global(g, 9);
    assert_eq!(e.global(g), Some(9));
}

#[test]
fn unload_bank_destroys_its_instances_and_stops_answering_posts() {
    let mut e = setup(vec![player_module(2)], vec![Ex { module: 0, kind: 1, name_id: 1, name: "c_test", at: None }]);
    let class = e.class_id("c_test").unwrap();
    let mut log = Log::default();
    e.post(class, &[1, 4096, 0]);
    walk(&mut e, &mut log);
    e.unload_bank(0, &mut log);
    assert!(e.instances().is_empty());
    assert_eq!(log.calls.last().map(String::as_str), Some("release v1"));
    e.post(class, &[1, 4096, 0]);
    assert!(e.instances().is_empty());
}


/// An audio content hot swap (`replace_bank`): the bank keeps its id and its place among the
/// class's constructors; its instances go (voices released); a post its poster still holds gets
/// the new bank's instance with the post's payload and plays it at the next walk; a released post
/// gets nothing; the other bank's instance is untouched; nothing is drawn from the generator.
#[test]
fn a_replaced_bank_keeps_its_place_and_re_instances_held_posts() {
    let ex = || vec![Ex { module: 0, kind: 1, name_id: 1, name: "c_test", at: None }];
    let mut e = Evaluator::new();
    e.install_project(&project());
    let a = e.load_bank(bank(&[player_module(4)], &ex(), &[(48000, false), (24000, false)]));
    let b = e.load_bank(bank(&[player_module(4)], &ex(), &[(48000, false), (24000, false)]));
    let class = e.class_id("c_test").unwrap();
    let mut log = Log::default();
    let held = e.post(class, &[1, 4096, 1]);
    let gone = e.post(class, &[1, 4096, 0]);
    walk(&mut e, &mut log);
    e.release(gone);
    walk(&mut e, &mut log);
    assert_eq!(e.instances().len(), 2, "the held post's two instances");
    let rng = e.rng;
    log.calls.clear();
    let again = e.replace_bank(a, bank(&[player_module(4)], &ex(), &[(12000, false), (6000, false)]), &mut log);
    assert_eq!(again, [held], "only the held post");
    assert_eq!(e.registry.classes[class].constructors, [(a, 0), (b, 0)], "the same place");
    assert!(log.calls.iter().all(|c| c.starts_with("release")) && log.calls.len() == 1, "{:?}", log.calls);
    assert_eq!(e.instances().len(), 2);
    assert_eq!(e.instances()[0].1, a, "the new instance is the newest");
    walk(&mut e, &mut log);
    assert!(log.calls.iter().any(|c| c.starts_with("open") && c.ends_with("slot 1")), "the payload came along: {:?}", log.calls);
    assert_eq!(e.rng, rng);
    // The project of a mod: its banks are found, and once it is out nothing resolves to it.
    let s = |name: &str, id: u16| crate::formats::csi::Symbol { name: name.into(), name_id: id, default: 5 };
    let modp = crate::formats::Project { name: "mod.csi".into(), id: 0x4D4F, tables: [vec![], vec![s("c_mod", 1)], vec![s("g_mod", 1)]] };
    let token = e.install_project(&modp);
    let m = e.load_bank(bank(&[player_module(1)], &[Ex { module: 0, kind: 1, name_id: 1, name: "c_mod", at: None }], &[(1000, false)]));
    assert!(e.class_id("c_mod").is_some() && e.global_id("g_mod").is_some());
    assert_eq!(e.banks_using_project(token), [m]);
    e.unload_bank(m, &mut log);
    assert!(e.uninstall_project(token));
    assert!(e.class_id("c_mod").is_none() && e.global_id("g_mod").is_none());
    assert_eq!(e.class_id("c_test"), Some(class), "retail lookups unchanged");
    assert!(!e.uninstall_project(token));
}
