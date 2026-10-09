use super::*;

#[test]
fn crt_rand_is_the_ms_lcg() {
    let mut r = CrtRand::default();
    // MS CRT rand() from seed 1: 41, 18467, 6334, 26500, 19169.
    assert_eq!([r.next(), r.next(), r.next(), r.next(), r.next()], [41, 18467, 6334, 26500, 19169]);
}

#[test]
fn sequential_pick_advances_from_the_state_word() {
    let mut rng = CrtRand::default();
    let mut state = 0x0001_0000; // the disc's initial word
    let picks: Vec<u8> = (0..4).map(|_| pick(3, 1, &mut state, &mut rng)).collect();
    // (65536 + 1) % 3 = 2, then 0, 1, 2.
    assert_eq!(picks, [2, 0, 1, 2]);
}

#[test]
fn shuffle_plays_each_half_without_repeats_then_refills_the_other() {
    let mut rng = CrtRand::default();
    let mut state = 0x0001_0000; // mask 1 in half 0
    let mut seen = Vec::new();
    for _ in 0..7 {
        seen.push(pick(5, 2, &mut state, &mut rng));
    }
    // First the one item the disc state allows (index 0), then half 1 (items 2..4) in some
    // order, then half 0 (items 0, 1) again.
    assert_eq!(seen[0], 0);
    let mut h1 = seen[1..4].to_vec();
    h1.sort();
    assert_eq!(h1, [2, 3, 4]);
    let mut h0 = seen[4..6].to_vec();
    h0.sort();
    assert_eq!(h0, [0, 1]);
    assert!((2..5).contains(&seen[6]));
}

#[test]
fn random_pick_stays_in_range() {
    let mut rng = CrtRand::default();
    let mut state = 0;
    for _ in 0..1000 {
        assert!(pick(7, 0, &mut state, &mut rng) < 7);
    }
}

#[test]
fn fade_curves_run_from_zero_to_one() {
    for kind in 0..5 {
        assert!(curve(kind, 0.0).abs() < 1e-5, "curve {kind} at 0");
        assert!((curve(kind, 1.0) - 1.0).abs() < 1e-5, "curve {kind} at 1");
    }
    assert!((curve(2, 0.25) - 0.25).abs() < 1e-7);
    assert!((curve(3, 0.5) - (std::f32::consts::FRAC_PI_4).sin()).abs() < 1e-5);
}

/// The extracted SPLC banks: `SKATE_SPLC_BANKS`, else `$SKATE_AUDIO_RE_DIR/splc-banks`.
fn splc_dir() -> Option<std::path::PathBuf> {
    let var = |n: &str| std::env::var_os(n).filter(|v| !v.is_empty()).map(std::path::PathBuf::from);
    var("SKATE_SPLC_BANKS").or_else(|| var("SKATE_AUDIO_RE_DIR").map(|d| d.join("splc-banks")))
}

fn disc_bank(name: &str) -> Option<Vec<u8>> {
    std::fs::read(splc_dir()?.join(format!("{name}.bnk"))).ok()
}

#[test]
#[ignore = "needs the private install data"]
fn disc_banks_parse_and_the_contact_ids_resolve() {
    let Some(d) = disc_bank("Skate_Collisions") else { panic!("missing private data: no extracted SPLC banks") };
    let bank = SpliceBank::parse(&d).unwrap();
    assert!(bank.records.len() > 800 && !bank.containers.is_empty());
    let records = bank.records.len();
    // The Contacts vault ids (pop 1097..1099, touchdowns 1051.., ollie 1096, landing 1095, roll 1111)
    // are containers.
    for id in [1095usize, 1096, 1097, 1098, 1099, 1051, 1060, 1111] {
        assert!(id >= records && id < records + bank.containers.len(), "id {id}");
    }
    // Every bank on the disc parses.
    let dir = splc_dir().unwrap();
    let mut n = 0;
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        let d = std::fs::read(&p).unwrap();
        SpliceBank::parse(&d).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
        let tree = SpliceBank::tree_len(&d).unwrap();
        assert_eq!(SpliceBank::parse(&d[..tree]).unwrap(), SpliceBank::parse(&d).unwrap());
        n += 1;
    }
    assert_eq!(n, 20);
}

fn tone(seconds: f32) -> Arc<Pcm> {
    let n = (seconds * 48000.0) as usize;
    Arc::new(Pcm { rate: 48000, channels: vec![(0..n).map(|i| (i as f32 * 0.05).sin() * 0.5).collect()] })
}

#[test]
#[ignore = "needs the private install data"]
fn a_record_plays_its_layers_and_ends_after_its_length() {
    let Some(d) = disc_bank("Skate_Collisions") else { panic!("missing private data: no extracted SPLC banks") };
    let bank = SpliceBank::parse(&d).unwrap();
    let pcm = (0..bank.samples).map(|_| Some(tone(0.5))).collect();
    let mut mixer = Mixer::new();
    let mut p = SplicePlayer::new();
    let b = p.load_bank("Skate_Collisions", bank, pcm, &mut mixer);
    let s = p.start(b, 1097, [0.0, 1.0, 0.0, 1.0 / 60.0, 1.0, 1.0], &mut mixer).unwrap();
    let mut bus = [[0.0f32; crate::BLOCK]; 6];
    let mut frames = 0;
    while p.alive(s) && frames < 600 {
        p.update(s, [0.5, 1.0, 0.0, 1.0 / 60.0, 1.0, 1.0], &mut mixer);
        for _ in 0..3 {
            mixer.render(&mut bus);
        }
        frames += 1;
    }
    assert!(frames < 600, "the pop ends by itself");
    assert!(p.started >= 1);
}

/// The user's crack/seam report (a first trigger that sounded different): every trigger of a
/// sample renders the same samples — PCM is decoded before any start, and a voice's first block
/// (the format change), resampler, gain ramp and panner start from the same state each time.
#[test]
fn the_first_trigger_of_a_sample_renders_like_the_next() {
    let mut mixer = Mixer::new();
    let pcm = tone(0.2);
    let header = crate::formats::SampleHeader { codec: 3, channels: 1, rate: 48000, frames: pcm.channels[0].len() as u32, loop_start: None };
    mixer.add_bank(7, vec![Some(header)], vec![Some(pcm)]);
    let mut takes = Vec::new();
    for _ in 0..2 {
        let id = mixer.open_direct(7, 0, 0.0, 1.0, 0.5, Some(30.0)).unwrap();
        let mut out = Vec::new();
        let mut bus = [[0.0f32; crate::BLOCK]; 6];
        while mixer.direct_alive(id) {
            mixer.render(&mut bus);
            out.extend(bus.iter().flatten().copied());
        }
        crate::eval::VoiceHost::release(&mut mixer, id);
        mixer.render(&mut bus); // the stop fold of the finished voice
        takes.push(out);
    }
    assert!(takes[0].iter().any(|&x| x != 0.0));
    assert_eq!(takes[0], takes[1]);
}
