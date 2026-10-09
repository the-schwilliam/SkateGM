//! The 14 retail `.grain` members as setup copies them (`assets/private/audio/grains/*.grain`,
//! tools/asset_pipeline/audio_export.py `grain_whole`): every header, seek table and EAAC header
//! parses and matches the spec's census (grain-player-spec §1.1). Skips without the private install.
use skate_audio::grain::GrainFile;

#[test]
#[ignore = "needs the private install data"]
fn every_retail_grain_parses_with_a_single_entry_seek_table() {
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../../assets/private/audio/grains");
    let Ok(entries) = std::fs::read_dir(dir) else {
        panic!("missing private data: no {dir}");
    };
    let mut seen = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("grain") {
            continue;
        }
        let bytes = std::fs::read(&path).unwrap();
        let name = path.file_stem().unwrap().to_string_lossy().into_owned();
        let g = GrainFile::parse(&bytes).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert!(g.single_entry(), "{name}: row 0 spans the stream");
        assert_eq!((g.seek.kind, g.seek.layout, g.seek.low, g.seek.preroll, g.seek.side_offset), (0, 1, 0, 384, 24), "{name}");
        assert_eq!((g.stream.version, g.stream.codec, g.stream.channels, g.stream.kind, g.stream.looped), (0, 3, 1, 0, false), "{name}");
        assert!(matches!(g.stream.rate, 44100 | 48000), "{name}");
        assert!((112..=176).contains(&g.header_len), "{name}");
        seen.push((name, g.stream.samples, g.duration));
    }
    if seen.is_empty() {
        panic!("missing private data: no .grain files in {dir} (run stage_grain_mixmap.py or setup)");
    }
    seen.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(seen.len(), 14);
    let crh = seen.iter().find(|s| s.0 == "concrete_rough_hard").unwrap();
    assert_eq!((crh.1, crh.2.to_bits()), (963228, 0x41AE_BC39));
    let jet = seen.iter().find(|s| s.0 == "x_jet_rolling").unwrap();
    assert_eq!(jet.1, 583305);
}
