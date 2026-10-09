use super::format::*;
use super::*;

/// A one-slot file built in memory: Ambience-like slot 0 with one input product, one sum, one
/// volume output and one envelope ducking it.
fn tiny() -> MixMapFile {
    let input = keys::obj(0, 0, 0); // Obj 0.0 input 0, curve 0 (cos)
    let section = Section {
        slot: 0,
        products: vec![ProductRec { input, swing: (-10000i16) as u16, refs: vec![] }],
        lookups: vec![],
        sums: vec![SumRec { word0: 0xD001_0000, max: 0, min: -10000, refs: vec![0x0000_0000] }],
        outputs: vec![OutputRec {
            word0: 0xC002_0000,
            base: -600,
            dest: keys::obj(0, 0, 0),
            refs: vec![0x3000_0000, 0xA000_0000],
            kind: 0,
            outs: vec![OutputWord { id: 0, special: 31, raw_angle: false, offset: 0 }],
        }],
        envelopes: vec![EnvelopeRec {
            word0: 0x0100_0100,
            kind: 1,
            gated: true,
            linear: false,
            retrigger: false,
            swing: (-1000i16) as u16,
            trigger: keys::obj(0, 0, 0) | 1,
            attack: (6, 9),
            decay: (0, 9),
            hold: 5,
            release: (6, 9),
            sustain: 32767,
            refs: vec![],
        }],
    };
    MixMapFile { id: 0, slots: vec![Some(section)] }
}

#[test]
fn a_duck_envelope_and_a_cut_product_drive_a_volume_output() {
    // The E record sums C0 (key 0x3000_0000 = C/E type with the C bit) and F0 (0xA000_0000).
    let mut m = MixMap::new(&tiny(), &[1]);
    let owner = keys::obj(0, 0, 0);
    m.tick(1.0 / 60.0);
    // Input 0 = 0 → cos(0) = full → the cut is 0 mB; base −600 → 16422-ish; the duck is idle.
    let full = m.level(owner, 0);
    assert_eq!(full, m.tables().mb_to_lin(-600 - 1));
    // Input 0 at 32767 → cos → 0 → the cut reaches −10000: silent.
    m.set_input(owner, 0, 32767);
    m.tick(1.0 / 60.0);
    assert!(m.level(owner, 0) <= 1);
    // Duck: trigger on → attack over 6 frames (100 ms) to −1000 mB.
    m.set_input(owner, 0, 0);
    m.set_input(owner, 1, 1);
    let mut levels = Vec::new();
    for _ in 0..12 {
        m.tick(1.0 / 60.0);
        levels.push(m.level(owner, 0));
    }
    assert!(levels.windows(2).all(|w| w[1] <= w[0]), "attack falls monotonically: {levels:?}");
    let ducked = *levels.last().unwrap();
    let expect = m.tables().mb_to_lin(-600 - 1 - 1000);
    assert!((ducked - expect).abs() <= 40, "{ducked} vs {expect}");
    // Release when the trigger goes off.
    m.set_input(owner, 1, 0);
    for _ in 0..20 {
        m.tick(1.0 / 60.0);
    }
    assert_eq!(m.level(owner, 0), full);
}

#[test]
fn a_disabled_block_writes_its_first_id_only() {
    let mut fixed = tiny();
    fixed.slots[0].as_mut().unwrap().outputs[0].refs = vec![];
    let mut m = MixMap::new(&fixed, &[1]);
    let owner = keys::obj(0, 0, 0);
    m.set_enabled(owner, false);
    m.tick(1.0 / 60.0);
    // −10000 read back through & 0x7FFF = 22768 (spec §5.7).
    assert_eq!(m.level(owner, 0), 22768);
}

/// The install's MixMap, else the extracted disc's (`$SKATE3_DISC/data/audio`, as the published tools).
fn disc_mxb() -> Option<Vec<u8>> {
    let install = std::path::PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../../assets/private/audio/aems/MixMapSK8.mxb"));
    let disc = std::env::var_os("SKATE3_DISC")
        .filter(|v| !v.is_empty())
        .map(|d| std::path::PathBuf::from(d).join("data/audio/MixMapSK8.mxb"));
    std::iter::once(install).chain(disc).find_map(|p| std::fs::read(p).ok())
}

/// The retail file instantiates exactly the spec's census (§2.4).
#[test]
#[ignore = "needs the private install data"]
fn disc_mixmap_census() {
    let Some(bytes) = disc_mxb() else {
        panic!("missing private data: no MixMapSK8.mxb in the dev install or $SKATE3_DISC");
    };
    let file = MixMapFile::parse(&bytes).unwrap();
    assert_eq!(file.slots.len(), 14);
    let per_slot: Vec<[usize; 5]> = file
        .slots
        .iter()
        .map(|s| s.as_ref().map_or([0; 5], |s| [s.products.len(), s.lookups.len(), s.envelopes.len(), s.sums.len(), s.outputs.len()]))
        .collect();
    assert_eq!(per_slot[0], [180, 1, 245, 12, 65]);
    assert_eq!(per_slot[1], [122, 14, 37, 18, 92]);
    assert_eq!(per_slot[2], [3, 0, 0, 1, 4]);
    assert_eq!(per_slot[6], [0, 1, 0, 2, 8]);
    let m = MixMap::new(&file, &RETAIL_INSTANCES);
    assert_eq!(m.counts(), [547, 853, 635, 350, 240, 1044]);
    assert_eq!(m.output_blocks(), 154);
    assert_eq!(m.controller_count(), 247);
}

/// Free-skate steady state (Master.in1–4 = 32767, the rest 0): the spec's emitter and ambience
/// outputs (§6.2, §6.3).
#[test]
#[ignore = "needs the private install data"]
fn disc_mixmap_free_skate_outputs() {
    let Some(bytes) = disc_mxb() else {
        panic!("missing private data: no MixMapSK8.mxb");
    };
    let mut m = MixMap::from_bytes(&bytes).unwrap();
    for id in 1..=4 {
        m.set_input(keys::MASTER, id, 32767);
    }
    for _ in 0..5 {
        m.tick(1.0 / 60.0);
    }
    let e = keys::emitter(0);
    // Positional dry −600 mB + the Global ducks' rest values (no distance roll-off); the same
    // value the PoC's MixMap port gives (golden1.poc.csv).
    assert_eq!(m.level(e, 4), 16365);
    assert_eq!(m.pitch_4096(e, 5), 4096);
    assert_eq!(m.filter_hz(e, 6), 24971); // −2 cents of 25 kHz
    // Emitter 3-D input inactive → B0 silent → the positional send is 0.
    assert_eq!(m.level(e, 8), 0);
    // Ambience out0 ≈ −1100 mB (bed fade 0 = up), out3 = 24971 Hz.
    let t = m.tables();
    let bed = m.level(keys::AMBIENCE, 0);
    assert!((t.lin_to_mb(bed) + 1100).abs() < 20, "bed {bed}");
    assert_eq!(m.filter_hz(keys::AMBIENCE, 3), 24971);
    assert_eq!(m.pitch_4096(keys::AMBIENCE, 2), 4096);
    // Without the Master category gains everything is about −100 dB.
    let mut silent = MixMap::from_bytes(&bytes).unwrap();
    for _ in 0..5 {
        silent.tick(1.0 / 60.0);
    }
    assert_eq!(silent.level(e, 4), 0);
}

/// A held input: a one-step flag written between ticks still reaches the next evaluation once; the
/// stored input keeps the last write, and inputs without a hold are unchanged.
#[test]
fn a_held_flag_written_between_ticks_reaches_the_next_tick_once() {
    let owner = keys::obj(0, 0, 0);
    let run = |hold: bool| {
        let mut m = MixMap::new(&tiny(), &[1]);
        if hold {
            assert!(m.hold_input(owner, 1));
        }
        m.tick(1.0 / 30.0);
        let idle = m.level(owner, 0);
        // The duck trigger pulses on one 60 Hz step and is cleared on the next, before the tick.
        m.set_input(owner, 1, 1);
        m.set_input(owner, 1, 0);
        m.tick(1.0 / 30.0);
        let after = m.level(owner, 0);
        assert_eq!(m.input(owner, 1), 0, "the stored input is the last write");
        (idle, after)
    };
    let (idle, unheld) = run(false);
    assert_eq!(unheld, idle, "without a hold the pulse is lost");
    let (idle, held) = run(true);
    assert!(held < idle, "with a hold the duck starts: {held} vs {idle}");
    // Without writes the hold is inert; a later tick sees only later writes.
    let mut m = MixMap::new(&tiny(), &[1]);
    m.hold_input(owner, 1);
    m.set_input(owner, 1, 1);
    m.tick(1.0 / 30.0);
    m.set_input(owner, 1, 0);
    let a = m.input(owner, 1);
    m.tick(1.0 / 30.0);
    assert_eq!((a, m.input(owner, 1)), (0, 0));
    assert!(!m.hold_input(0x7777_0000, 1), "unknown controller");
}
