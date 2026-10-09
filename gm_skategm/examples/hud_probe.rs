// gm_sk8: run Skate 3's trick display offline and report what it draws
use gmcl_skategm_win64::hud;
fn main() {
    let root = std::env::args().nth(1).expect("prepared HUD folder");
    hud::load(std::path::Path::new(&root)).expect("load");
    let mut f = hud::Feed { line_capacity: 100.0, multiplier: 1.0, ..Default::default() };
    let report = |label: &str| {
        let g = hud::HUD.lock().unwrap();
        let s = g.as_ref().unwrap();
        if let Some(e) = &s.failed { println!("{label}: FAILED {e}"); return; }
        let d = hud::apt_scene::draw(&s.runtime.bindings.movie, &s.runtime.vm, &s.shapes).unwrap();
        let tris: usize = d.iter().map(|x| x.vertices.len() / 3).sum();
        let tex: std::collections::BTreeSet<_> = d.iter().map(|x| x.texture.rsplit('/').next().unwrap().to_string()).collect();
        let addmax = d.iter().flat_map(|x| x.add).fold(0f32, f32::max);
        let masks = d.iter().filter(|x| x.mask == 2).count(); println!("{label}: {masks} masks, {} draws, {} triangles, max add {addmax:.2}, textures {:?}", d.len(), tris, tex);
    };
    let mut tick = 1;
    hud::feed(tick, &f); report("idle");
    f.trick_name = "ID_TRICK_KICKFLIP".into(); f.new_trick = true; f.sequence_score = 250.0; f.line_score = 250.0; f.sequence_timer = 5; f.line_time = 5.0;
    tick += 1; hud::feed(tick, &f); report("new trick");
    f.new_trick = false;
    for _ in 0..30 { tick += 1; hud::feed(tick, &f); }
    report("half a second later");
    f.multiplier = 2.0; f.clean = true; tick += 1; hud::feed(tick, &f); report("multiplier");
    for _ in 0..240 { tick += 1; hud::feed(tick, &f); }
    report("4 s later");
    f.close_tricks = true; tick += 1; hud::feed(tick, &f); f.close_tricks = false;
    for _ in 0..120 { tick += 1; hud::feed(tick, &f); }
    report("closed");
}
