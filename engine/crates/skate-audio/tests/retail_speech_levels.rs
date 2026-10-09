//! Execute both complete native owner updates; compare their main/second output indices.
use skate_audio::world::speech_player::{
    PedLevelSelect, ped_level_ids_focused, skater_level_ids_focused,
};
#[test]
#[ignore = "requires SKATE_RETAIL_SPEECH_LEVELS_VECTORS"]
fn output_indices_match_native_owner_updates() {
    let text = std::fs::read_to_string(
        std::env::var_os("SKATE_RETAIL_SPEECH_LEVELS_VECTORS").expect("native vectors"),
    )
    .unwrap();
    assert!(text.starts_with("# TU3 speech_levels 824D9370 824DA300;"));
    let mut n = 0;
    for (case, line) in text.lines().filter(|l| !l.starts_with('#')).enumerate() {
        let v: Vec<u32> = line
            .split_whitespace()
            .map(|s| s.parse().unwrap())
            .collect();
        assert_eq!(v.len(), 13);
        let focused = v[8] != 0 && v[9] == if v[0] == 0 { v[10] } else { v[7] };
        let result = if v[0] == 0 {
            ped_level_ids_focused(
                PedLevelSelect {
                    s100: v[1] as i32,
                    s104: v[2] as i32,
                    s112: v[3] as i32,
                    security: v[4] != 0,
                },
                v[5] as u16,
                v[6] != 0,
                focused,
            )
        } else {
            skater_level_ids_focused(v[7], v[6] != 0, focused)
        };
        assert_eq!(result, (v[11] as usize, v[12] as usize), "case {case}");
        n += 1;
    }
    assert_eq!(n, 4096);
}
