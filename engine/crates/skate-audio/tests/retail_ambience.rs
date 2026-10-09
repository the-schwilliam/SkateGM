//! Independent ambience phase/input outputs from the owned TU3 instruction translation.
use skate_audio::world::ambience::Controller;

#[test]
#[ignore = "requires SKATE_RETAIL_AMBIENCE_VECTORS from the native phase functions"]
fn phases_match_native_instruction_execution() {
    let path = std::env::var_os("SKATE_RETAIL_AMBIENCE_VECTORS").expect("native ambience vectors");
    let text = std::fs::read_to_string(path).unwrap();
    assert!(text.starts_with("# TU3 ambience 824D3C28 824D3FE0 824D41E0;"));
    let hex = |s| u32::from_str_radix(s, 16).unwrap();
    let durations = |key| match key {
        1 => (3.0, 2.0),
        2 => (0.5, 0.25),
        _ => (0.0, 0.0),
    };
    let mut state = Controller::default();
    let mut count = 0;
    for (tick, line) in text.lines().filter(|l| !l.starts_with('#')).enumerate() {
        let v: Vec<_> = line.split_whitespace().collect();
        assert_eq!(v.len(), 11);
        let desired = v[0].parse().unwrap();
        let (fade_in, fade_out) = durations(state.current);
        let change = state.process(desired, f32::from_bits(hex(v[1])), fade_in, fade_out, true);
        assert_eq!(state.current, v[2].parse::<u64>().unwrap(), "tick {tick}");
        assert_eq!(
            state.phase as u32,
            v[3].parse::<u32>().unwrap(),
            "tick {tick}"
        );
        assert_eq!(state.out_time.to_bits(), hex(v[4]), "out timer tick {tick}");
        assert_eq!(state.in_time.to_bits(), hex(v[5]), "in timer tick {tick}");
        let (fade_in, fade_out) = durations(state.current);
        assert_eq!(
            state.input(fade_in, fade_out),
            v[6].parse::<i32>().unwrap(),
            "input tick {tick}"
        );
        for (actual, expected) in [
            change.start_bed,
            change.stop_bed,
            change.start_crossfade,
            change.stop_crossfade,
        ]
        .iter()
        .zip(&v[7..])
        {
            assert_eq!(
                i32::from(*actual),
                expected.parse::<i32>().unwrap(),
                "voice transition tick {tick}"
            );
        }
        count += 1;
    }
    assert_eq!(count, 2048);
}
