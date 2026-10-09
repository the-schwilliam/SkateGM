use super::*;

struct Fixed;
impl Outputs for Fixed {
    fn level(&self, id: usize) -> i32 {
        1000 + id as i32
    }
    fn raw(&self, _: usize) -> i32 {
        70000
    }
    fn pitch(&self, id: usize) -> i32 {
        4000 + id as i32
    }
}

fn kickflip(airborne: bool) -> AudioState {
    AudioState { airborne, trick_active: true, audio_trick: 0, audio_trick_2: 28, ..Default::default() }
}

fn posts(cmds: &[Command]) -> Vec<(Slot, &'static str)> {
    cmds.iter().filter_map(|c| if let Command::Post { slot, class, .. } = c { Some((*slot, *class)) } else { None }).collect()
}

fn releases(cmds: &[Command]) -> Vec<Slot> {
    cmds.iter().filter_map(|c| if let Command::Release { slot } = c { Some(*slot) } else { None }).collect()
}

#[test]
fn spin_words_scale_cap_and_gate() {
    let t = TricksTuning::default();
    // Ri: |v| / 3 × 1000, 0 below 297.
    assert_eq!(spin_word(1.0, t.spin_divisor[0], t.spin_threshold[0]), 333);
    assert_eq!(spin_word(-1.0, t.spin_divisor[0], t.spin_threshold[0]), 333);
    assert_eq!(spin_word(0.8, t.spin_divisor[0], t.spin_threshold[0]), 0);
    assert_eq!(spin_word(0.891, t.spin_divisor[0], t.spin_threshold[0]), 297, "the threshold itself passes");
    assert_eq!(spin_word(40.0, t.spin_divisor[0], t.spin_threshold[0]), 1000);
    // Up 4.4 / 703, At 10.2 / 603.
    assert_eq!(spin_word(4.0, t.spin_divisor[1], t.spin_threshold[1]), 909);
    assert_eq!(spin_word(3.0, t.spin_divisor[1], t.spin_threshold[1]), 0);
    assert_eq!(spin_word(7.0, t.spin_divisor[2], t.spin_threshold[2]), 686);
}

#[test]
fn class_flips_posts_in_the_air_with_the_retail_words() {
    let (t, g) = (TricksTuning::default(), Globals::default());
    let mut k = Tricks::default();
    // On the ground with the trick registered: only cloth A.
    let cmds = k.process(&kickflip(false), &t, &g, &Fixed);
    assert_eq!(posts(&cmds), vec![(Slot::Cloth(0), "cloth_trick")]);
    let Command::Post { words, .. } = &cmds[0] else { panic!() };
    assert_eq!(words[..], [0, 0, 4096, 0, 25000, 0, 0, 0, 1, 0, 0]);
    // First air frame: Class_Flips.
    let mut s = kickflip(true);
    s.deck_spin_xy = [6.0, 0.5];
    s.deck_spin = 7.0;
    let cmds = k.process(&s, &t, &g, &Fixed);
    assert_eq!(posts(&cmds), vec![(Slot::Flips, "Class_Flips")]);
    let Command::Post { words, .. } = &cmds[0] else { panic!() };
    #[rustfmt::skip]
    let want = [0, 32767, 0, 0, 4096, 25000, 0, 686, 0, 1000, 500, 0, 0, 0, 0, 0, 1, 27646, 14848, 6656, 0, 10000, 0, 0, 1, 1, 1006, 6];
    assert_eq!(words[..], want);
    // Held through the air: no repost, the update rewrites it.
    assert!(posts(&k.process(&s, &t, &g, &Fixed)).is_empty());
    let up = k.update(&s, &t, &Fixed);
    let Command::Redeliver { slot: Slot::Flips, words: w } = &up[0] else { panic!("{up:?}") };
    assert_eq!((w[0], w[1], w[2], w[3], w[4], w[5], w[6]), (1001, 32767, 0, 65536, 4002, 1003, 0));
    assert_eq!((w[12], w[20], w[22], w[26]), (0, 1008, 1007, 1006));
    let Command::Redeliver { slot: Slot::Cloth(0), words: c } = &up[1] else { panic!("{up:?}") };
    assert_eq!((c[0], c[1], c[2], c[4], c[7]), (32767, 65535, 4005, 25000, 1004));
    // Landing: released by the update.
    let land = AudioState { airborne: false, ..s };
    k.process(&land, &t, &g, &Fixed);
    assert!(releases(&k.update(&land, &t, &Fixed)).contains(&Slot::Flips));
}

#[test]
fn grabs_none_and_coffin_post_no_flip_and_a_new_trick_reposts() {
    let (t, g) = (TricksTuning::default(), Globals::default());
    for id in [-1, 35, 36] {
        let mut k = Tricks::default();
        let s = AudioState { audio_trick: id, ..kickflip(true) };
        assert!(!posts(&k.process(&s, &t, &g, &Fixed)).contains(&(Slot::Flips, "Class_Flips")));
    }
    // Ollie (28) does post; the trick turning into another one in the air releases and reposts.
    let mut k = Tricks::default();
    let s = AudioState { audio_trick: 28, ..kickflip(true) };
    assert!(posts(&k.process(&s, &t, &g, &Fixed)).contains(&(Slot::Flips, "Class_Flips")));
    let s2 = AudioState { audio_trick: 10, ..s };
    let cmds = k.process(&s2, &t, &g, &Fixed);
    assert_eq!(releases(&cmds), vec![Slot::Cloth(0)], "cloth A releases on the new id");
    assert_eq!(releases(&k.update(&s2, &t, &Fixed)), vec![Slot::Flips]);
    let cmds = k.process(&s2, &t, &g, &Fixed);
    assert_eq!(posts(&cmds), vec![(Slot::Flips, "Class_Flips"), (Slot::Cloth(0), "cloth_trick")]);
    let Command::Post { words, .. } = &cmds[0] else { panic!() };
    assert_eq!(words[11], 10);
    // Without +343 a new flip is not posted in the air.
    let mut k = Tricks::default();
    let s = AudioState { trick_active: false, ..kickflip(true) };
    assert!(!posts(&k.process(&s, &t, &g, &Fixed)).iter().any(|p| p.0 == Slot::Flips));
}

#[test]
fn cloth_b_plays_the_second_id_for_the_tricks_duration() {
    let (t, g) = (TricksTuning::default(), Globals::default());
    let mut k = Tricks::default();
    // 20 frames of trick (1/3 s), then the trick ends.
    for f in 0..20 {
        let s = kickflip(f > 2);
        k.process(&s, &t, &g, &Fixed);
        k.update(&s, &t, &Fixed);
    }
    let end = AudioState { airborne: false, ..Default::default() };
    let cmds = k.process(&end, &t, &g, &Fixed);
    assert_eq!(posts(&cmds), vec![(Slot::Cloth(1), "cloth_trick")]);
    let Command::Post { words, .. } = &cmds[0] else { panic!() };
    assert_eq!(words[9], 28, "the latched +352");
    let up = k.update(&end, &t, &Fixed);
    assert!(releases(&up).contains(&Slot::Cloth(0)), "cloth A ends with the trick on the ground");
    // Held for the trick's 20 frames, then released by the process.
    let mut held = 1;
    loop {
        let cmds = k.process(&end, &t, &g, &Fixed);
        if releases(&cmds).contains(&Slot::Cloth(1)) {
            break;
        }
        k.update(&end, &t, &Fixed);
        held += 1;
        assert!(held < 40);
    }
    // 20 frames of dt summed up, then counted down in f32: a residue above 0 keeps it one more frame.
    assert_eq!(held, 21);
    // An ollie's second id is −1: no cloth B.
    let mut k = Tricks::default();
    let ollie = AudioState { audio_trick: 28, audio_trick_2: -1, ..kickflip(true) };
    for _ in 0..10 {
        k.process(&ollie, &t, &g, &Fixed);
    }
    assert!(posts(&k.process(&end, &t, &g, &Fixed)).is_empty());
}

#[test]
fn a_bail_releases_both_cloths() {
    let (t, g) = (TricksTuning::default(), Globals::default());
    let mut k = Tricks::default();
    for _ in 0..5 {
        k.process(&kickflip(true), &t, &g, &Fixed);
    }
    let end = AudioState::default();
    k.process(&end, &t, &g, &Fixed);
    let bail = AudioState { bail: true, ..Default::default() };
    let r = releases(&k.update(&bail, &t, &Fixed));
    assert!(r.contains(&Slot::Cloth(0)) && r.contains(&Slot::Cloth(1)), "{r:?}");
}

#[test]
fn the_offboard_hold_posts_trick_34_on_the_ground() {
    let (t, g) = (TricksTuning::default(), Globals::default());
    let mut k = Tricks::default();
    let s = AudioState { offboard_310: true, ..Default::default() };
    let cmds = k.process(&s, &t, &g, &Fixed);
    let Command::Post { slot: Slot::Flips, words, .. } = &cmds[0] else { panic!("{cmds:?}") };
    assert_eq!(words[11], 34);
    assert!(releases(&k.update(&s, &t, &Fixed)).is_empty());
    assert_eq!(releases(&k.update(&AudioState::default(), &t, &Fixed)), vec![Slot::Flips]);
}

#[test]
fn the_slew_follows_the_global_bits() {
    let t = TricksTuning::default();
    let mut k = Tricks::default();
    let s = kickflip(true);
    // No bit (free skate): 0.
    k.process(&s, &t, &Globals::default(), &Fixed);
    assert_eq!(k.slew, 0);
    // Bit 14 → 700, rising 10000/s = 166 per frame.
    let g = Globals { flags_96: 0x4000, mode_1060: 7 };
    let mut seen = Vec::new();
    for _ in 0..6 {
        k.process(&s, &t, &g, &Fixed);
        seen.push(k.slew);
    }
    assert_eq!(seen, [166, 332, 498, 664, 700, 700]);
    // Back to 0 at 1000/s = 16 per frame; mode 8 slews to 1000.
    k.process(&s, &t, &Globals::default(), &Fixed);
    assert_eq!(k.slew, 684);
    let mut k = Tricks::default();
    k.process(&s, &t, &Globals { flags_96: 0, mode_1060: 8 }, &Fixed);
    assert_eq!(k.slew, 166);
    let up = k.update(&s, &t, &Fixed);
    let Command::Redeliver { words, .. } = &up[0] else { panic!() };
    assert_eq!(words[12], 166);
}
