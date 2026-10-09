//! Native TU3 input-stage outputs, generated without calling the Rust implementation.
use skate_audio::mixmap::tables::Tables;

#[test]
#[ignore = "requires SKATE_RETAIL_MIXMAP_INPUT_VECTORS from the owned TU3 instruction translation"]
fn input_stage_matches_native_instruction_execution() {
    let path = std::env::var_os("SKATE_RETAIL_MIXMAP_INPUT_VECTORS")
        .expect("set SKATE_RETAIL_MIXMAP_INPUT_VECTORS");
    let data = std::fs::read_to_string(path).expect("read native MixMap vectors");
    assert!(data.starts_with("# TU3 8294F5E8 input stage and 8294B668;"));
    let tables = Tables::generate();
    let mut count = 0;
    for line in data
        .lines()
        .filter(|line| !line.starts_with('#') && !line.is_empty())
    {
        let row: Vec<i32> = line
            .split_whitespace()
            .map(|s| s.parse().expect("native integer"))
            .collect();
        assert_eq!(row.len(), 4);
        // Enforce exhaustive ordered coverage; duplicate rows cannot satisfy the corpus check.
        assert_eq!(row[0], count / 32768);
        assert_eq!(row[1], count % 32768);
        let shape = tables.shape(row[1], row[0] as u32);
        assert_eq!(shape, row[2], "kind {}, input {}", row[0], row[1]);
        assert_eq!(
            tables.lin_to_mb(shape),
            row[3],
            "kind {}, input {}",
            row[0],
            row[1]
        );
        count += 1;
    }
    assert_eq!(count, 10 * 32768, "complete native corpus required");
    eprintln!("TU3 MixMap input stage: {count} cases match native instruction execution");
}
