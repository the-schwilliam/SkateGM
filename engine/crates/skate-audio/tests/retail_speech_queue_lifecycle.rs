//! Independent native admission and successful-dequeue comparisons.
use skate_audio::world::speech_queue::{Candidate, admission, consumed, select};
#[test]
#[ignore = "requires SKATE_RETAIL_SPEECH_QUEUE_LIFECYCLE_VECTORS"]
fn lifecycle_matches_native_instruction_execution() {
    let text = std::fs::read_to_string(
        std::env::var_os("SKATE_RETAIL_SPEECH_QUEUE_LIFECYCLE_VECTORS").expect("native vectors"),
    )
    .unwrap();
    assert!(text.starts_with("# TU3 speech_queue_lifecycle 82971340 82971DA8;"));
    let mask = |c: &[Candidate]| {
        c.iter()
            .enumerate()
            .fold(0u32, |m, (i, c)| m | ((c.active as u32) << i))
    };
    let mut n = 0;
    for (case, line) in text.lines().filter(|l| !l.starts_with('#')).enumerate() {
        let v: Vec<i64> = line
            .split_whitespace()
            .map(|s| s.parse().unwrap())
            .collect();
        assert_eq!(v.len(), 118);
        let mut c: Vec<_> = v[2..114]
            .chunks_exact(7)
            .map(|r| Candidate {
                active: r[0] != 0,
                channel: r[1] as u8,
                timeout: r[2] as u16,
                priority: r[3] as u16,
                age: r[4] as u32,
                sequence: r[5] as u16,
            })
            .collect();
        let retain: Vec<_> = v[2..114].chunks_exact(7).map(|r| r[6] != 0).collect();
        let mut admitted = c.clone();
        assert_eq!(
            admission(&mut admitted, v[0] as u8, v[1] as u16).map_or(-1, |i| i as i64),
            v[114],
            "admission {case}"
        );
        assert_eq!(mask(&admitted), v[115] as u32, "admission mask {case}");
        let selected = select(&mut c, v[0] as u8);
        assert_eq!(selected.map_or(-1, |i| i as i64), v[116], "dequeue {case}");
        if let Some(i) = selected {
            consumed(&mut c, i, 100000, &retain);
        }
        assert_eq!(mask(&c), v[117] as u32, "consumed mask {case}");
        n += 1;
    }
    assert_eq!(n, 4096);
}
