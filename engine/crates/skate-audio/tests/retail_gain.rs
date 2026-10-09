//! Independent outputs from TU3 `82B3C098`, executed by tools/audio-retail-probe.
//! The generator reads the owned TU3 instruction translation and image; it never
//! calls this crate or the old PoC. Retail-derived vectors stay private.
use skate_audio::dsp::gain::ramp;

#[test]
#[ignore = "requires SKATE_RETAIL_GAIN_VECTORS generated from the owned TU3 function"]
fn gain_matches_native_instruction_execution() {
    let path = std::env::var_os("SKATE_RETAIL_GAIN_VECTORS")
        .expect("set SKATE_RETAIL_GAIN_VECTORS to the native probe output");
    let text = std::fs::read_to_string(path).expect("read native probe vectors");
    assert!(
        text.starts_with("# TU3 82B3C098 translated instruction execution;"),
        "unexpected vector provenance"
    );
    let hex = |s: &str| u32::from_str_radix(s, 16).expect("vector hex word");
    let (mut cases, mut samples) = (0, 0);
    for (case, line) in text
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
        .enumerate()
    {
        let mut words = line.split_whitespace();
        let start = f32::from_bits(hex(words.next().expect("start")));
        let step = f32::from_bits(hex(words.next().expect("step")));
        let pairs: Vec<_> = words
            .map(|word| {
                let (input, output) = word.split_once(':').expect("input:output");
                (hex(input), hex(output))
            })
            .collect();
        assert_eq!(
            pairs.len(),
            256,
            "case {case}: complete native block required"
        );
        let input: Vec<_> = pairs.iter().map(|(x, _)| f32::from_bits(*x)).collect();
        let mut got = input.clone();
        ramp(&mut got, start, step);
        for (i, (actual, (_, expected))) in got.iter().zip(&pairs).enumerate() {
            assert_eq!(
                actual.to_bits(),
                *expected,
                "case {case}, sample {i}, start {start:?}, step {step:?}"
            );
        }
        // Compare both dispatch paths against the independent output, not each other.
        for path in [
            Some(skate_audio_fma::Path::PLAIN),
            skate_audio_fma::Path::fma(),
        ]
        .into_iter()
        .flatten()
        {
            let mut got = input.clone();
            path.gain_ramp(&mut got, start, step);
            for (i, (actual, (_, expected))) in got.iter().zip(&pairs).enumerate() {
                assert_eq!(
                    actual.to_bits(),
                    *expected,
                    "{} case {case}, sample {i}",
                    path.name()
                );
            }
        }
        cases += 1;
        samples += pairs.len();
    }
    assert!(cases >= 4096, "incomplete native corpus: {cases} cases");
    assert_eq!(samples, cases * 256);
    eprintln!(
        "TU3 Gain: {cases} cases, {samples} samples; all bits match on every available dispatch path"
    );
}
