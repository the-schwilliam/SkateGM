//! Native target selection, priority comparison and channel availability.
use skate_audio::world::speech_queue::{channel_available, interrupt_target};
#[test]
#[ignore = "requires SKATE_RETAIL_SPEECH_INTERRUPT_VECTORS"]
fn interruption_matches_native_instruction_execution() {
    let text = std::fs::read_to_string(
        std::env::var_os("SKATE_RETAIL_SPEECH_INTERRUPT_VECTORS").expect("native vectors"),
    )
    .unwrap();
    assert!(text.starts_with("# TU3 speech_interrupt 824A73F0 824A62F0;"));
    let mut n = 0;
    for (case, line) in text.lines().filter(|l| !l.starts_with('#')).enumerate() {
        let v: Vec<i32> = line
            .split_whitespace()
            .map(|s| s.parse().unwrap())
            .collect();
        assert_eq!(v.len(), 18);
        let available = channel_available(
            v[1] as u8,
            [v[11] != 0, v[12] != 0],
            [v[13] != 0, v[14] != 0],
        );
        assert_eq!(available, v[15] != 0, "availability {case}");
        assert_eq!(
            interrupt_target(
                v[2] as u32,
                v[3] != 0,
                v[4] != 0,
                v[5] != 0,
                v[6],
                [v[7] != 0, v[8] != 0],
                [v[9], v[10]],
                available
            )
            .map_or(-1, |k| k as i32),
            v[16],
            "interrupt {case}"
        );
        assert_eq!(v[4] != 0 || v[5] != 0, v[17] != 0, "timer reset {case}");
        n += 1;
    }
    assert_eq!(n, 4096);
}
