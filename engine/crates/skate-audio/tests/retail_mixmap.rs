//! State-sequence comparison against the owned TU3 MixMap builder and tick instructions.
use skate_audio::mixmap::MixMap;

#[test]
#[ignore = "requires SKATE_RETAIL_MIXMAP_FULL_VECTORS and SKATE_RETAIL_MXB"]
fn stateful_mixmap_matches_native_instruction_execution() {
    let bytes = std::fs::read(
        std::env::var_os("SKATE_RETAIL_MIXMAP_FULL_VECTORS").expect("native vectors"),
    )
    .unwrap();
    let mxb =
        std::fs::read(std::env::var_os("SKATE_RETAIL_MXB").expect("owned MixMapSK8.mxb")).unwrap();
    assert_eq!(&bytes[..8], b"TU3MXB01");
    let mut words = bytes[8..]
        .chunks_exact(4)
        .map(|v| u32::from_le_bytes(v.try_into().unwrap()));
    let count = words.next().unwrap() as usize;
    let ticks = words.next().unwrap();
    assert_eq!(count, 247);
    assert_eq!(ticks, 1024);
    let controllers: Vec<_> = (0..count)
        .map(|_| (words.next().unwrap(), words.next().unwrap() != 0))
        .collect();
    let mut mixer = MixMap::from_bytes(&mxb).unwrap();
    assert_eq!(mixer.controller_count(), count);
    for &(key, _) in &controllers {
        assert!(
            mixer.has_controller(key),
            "missing native controller {key:08x}"
        );
    }
    let mut mismatches = 0;
    for tick in 0..ticks {
        let dt = f32::from_bits(words.next().unwrap());
        mixer.mode = words.next().unwrap();
        for &(key, has_output) in &controllers {
            for id in 0..16 {
                mixer.set_input(key, id, words.next().unwrap() as i32);
            }
            let enabled = words.next().unwrap() != 0;
            if has_output {
                mixer.set_enabled(key, enabled);
            }
        }
        mixer.tick(dt);
        for &(key, _) in &controllers {
            for id in 0..16 {
                let expected = words.next().unwrap();
                let actual = mixer.half(key, 2 * id) as u32;
                if actual != expected {
                    if mismatches < 30 {
                        eprintln!(
                            "tick {tick}, ctl {key:08x}, word {id}: Rust {actual:08x}, native {expected:08x}"
                        );
                    }
                    mismatches += 1;
                }
            }
        }
    }
    assert!(
        words.next().is_none(),
        "unexpected trailing native corpus data"
    );
    assert_eq!(
        mismatches, 0,
        "{ticks} ticks, {count} controllers, all 16 output words"
    );
}
