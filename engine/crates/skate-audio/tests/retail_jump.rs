//! Native TU3 jump-strength bucket output, independent of the Rust implementation.
use skate_audio::player::tuning::PlayerTuning;
#[test]
#[ignore = "requires SKATE_RETAIL_JUMP_VECTORS from native82772D30"]
fn jump_buckets_match_native_instruction_execution() {
    let path = std::env::var_os("SKATE_RETAIL_JUMP_VECTORS").expect("native jump vectors");
    let text = std::fs::read_to_string(path).unwrap();
    assert!(text.starts_with("# TU3 jump 82772D30;"));
    let tuning = PlayerTuning::default();
    let mut count = 0;
    for line in text.lines().filter(|l| !l.starts_with('#')) {
        let v: Vec<_> = line.split_whitespace().collect();
        assert_eq!(v.len(), 2);
        let strength = f32::from_bits(u32::from_str_radix(v[0], 16).unwrap());
        assert_eq!(
            tuning.jump_bucket(strength),
            v[1].parse::<u32>().unwrap(),
            "{line}"
        );
        count += 1;
    }
    assert_eq!(count, 4096);
}
