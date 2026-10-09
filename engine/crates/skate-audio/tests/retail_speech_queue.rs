//! Native library selection outputs from82971890.
use skate_audio::world::speech_queue::{Candidate, select};
#[test]
#[ignore = "requires SKATE_RETAIL_SPEECH_QUEUE_VECTORS"]
fn queue_matches_native_instruction_execution() {
    let text = std::fs::read_to_string(
        std::env::var_os("SKATE_RETAIL_SPEECH_QUEUE_VECTORS").expect("native queue vectors"),
    )
    .unwrap();
    assert!(text.starts_with("# TU3 speech_queue 82971890;"));
    let mut count = 0;
    for (case, line) in text.lines().filter(|l| !l.starts_with('#')).enumerate() {
        let v: Vec<i64> = line
            .split_whitespace()
            .map(|s| s.parse().unwrap())
            .collect();
        assert_eq!(v.len(), 99);
        let mut c: Vec<_> = v[1..97]
            .chunks_exact(6)
            .map(|r| Candidate {
                active: r[0] != 0,
                channel: r[1] as u8,
                timeout: r[2] as u16,
                priority: r[3] as u16,
                age: r[4] as u32,
                sequence: r[5] as u16,
            })
            .collect();
        assert_eq!(
            select(&mut c, v[0] as u8).map_or(-1, |i| i as i64),
            v[97],
            "selection {case}"
        );
        let mask = c
            .iter()
            .enumerate()
            .fold(0i64, |m, (i, c)| m | ((c.active as i64) << i));
        assert_eq!(mask, v[98], "expiry {case}");
        count += 1;
    }
    assert_eq!(count, 4096);
}
