// gm_sk8: render Skate 3's trick display offline to PNGs (software raster)
use gmcl_skategm_win64::hud;
use std::io::Write;
fn png(path: &str, w: usize, h: usize, rgb: &[u8]) {
    // stored (uncompressed) zlib, no dependencies
    let mut raw = Vec::new();
    for y in 0..h { raw.push(0u8); raw.extend_from_slice(&rgb[y * w * 3..(y + 1) * w * 3]); }
    let mut z = vec![0x78, 0x01];
    for (i, c) in raw.chunks(65535).enumerate() {
        let last = (i + 1) * 65535 >= raw.len();
        z.push(last as u8); z.extend_from_slice(&(c.len() as u16).to_le_bytes()); z.extend_from_slice(&(!(c.len() as u16)).to_le_bytes()); z.extend_from_slice(c);
    }
    let (mut a, mut b) = (1u32, 0u32); for &x in &raw { a = (a + x as u32) % 65521; b = (b + a) % 65521; }
    z.extend_from_slice(&((b << 16) | a).to_be_bytes());
    let crc = |d: &[u8]| { let mut c = 0xffffffffu32; for &x in d { c ^= x as u32; for _ in 0..8 { c = if c & 1 != 0 { 0xedb88320 ^ (c >> 1) } else { c >> 1 }; } } !c };
    let mut f = std::fs::File::create(path).unwrap();
    f.write_all(b"\x89PNG\r\n\x1a\n").unwrap();
    for (k, d) in [(&b"IHDR"[..], { let mut v = Vec::new(); v.extend_from_slice(&(w as u32).to_be_bytes()); v.extend_from_slice(&(h as u32).to_be_bytes()); v.extend_from_slice(&[8, 2, 0, 0, 0]); v }), (&b"IDAT"[..], z), (&b"IEND"[..], vec![])] {
        f.write_all(&(d.len() as u32).to_be_bytes()).unwrap(); let mut kd = k.to_vec(); kd.extend_from_slice(&d); f.write_all(&kd).unwrap(); f.write_all(&crc(&kd).to_be_bytes()).unwrap();
    }
}
fn main() {
    let root = std::env::args().nth(1).unwrap();
    hud::load(std::path::Path::new(&root)).unwrap();
    let mut tex: std::collections::HashMap<String, (usize, usize, Vec<u8>)> = Default::default();
    let mut f = hud::Feed { line_capacity: 100.0, multiplier: 1.0, ..Default::default() };
    let mut tick = 1u64;
    let mut shot = |name: &str, tex: &mut std::collections::HashMap<String, (usize, usize, Vec<u8>)>| {
        let g = hud::HUD.lock().unwrap(); let s = g.as_ref().unwrap();
        let draws = hud::apt_scene::draw(&s.runtime.bindings.movie, &s.runtime.vm, &s.shapes).unwrap();
        let (w, h) = (1280usize, 720usize);
        let mut img: Vec<f32> = (0..w * h * 3).map(|i| if (i / 3 / w / 40 + i / 3 % w / 40) % 2 == 0 { 0.35 } else { 0.45 }).collect();
        for d in &draws {
            let t = tex.entry(d.texture.clone()).or_insert_with(|| {
                let shapes = &s.shapes; let mut wh = None;
                for v in shapes.values().flatten() { if v.texture.rgba == d.texture { wh = Some((v.texture.width as usize, v.texture.height as usize)); } }
                let raw = std::fs::read(format!("{root}/{}", d.texture)).unwrap();
                let (tw, th) = wh.unwrap_or_else(|| { let n = ((raw.len() / 4) as f64).sqrt() as usize; (n, n) });
                (tw, th, raw)
            });
            for tri in d.vertices.chunks(3) {
                let p = |i: usize| (tri[i].position[0], tri[i].position[1]);
                let (a, b, c) = (p(0), p(1), p(2));
                let area = (b.0 - a.0) * (c.1 - a.1) - (b.1 - a.1) * (c.0 - a.0);
                if area.abs() < 1e-6 { continue; }
                let (x0, x1) = (a.0.min(b.0).min(c.0).floor().max(0.) as usize, (a.0.max(b.0).max(c.0).ceil() as usize).min(w - 1));
                let (y0, y1) = (a.1.min(b.1).min(c.1).floor().max(0.) as usize, (a.1.max(b.1).max(c.1).ceil() as usize).min(h - 1));
                for y in y0..=y1 { for x in x0..=x1 {
                    let (px, py) = (x as f32 + 0.5, y as f32 + 0.5);
                    let w0 = ((b.0 - px) * (c.1 - py) - (b.1 - py) * (c.0 - px)) / area;
                    let w1 = ((c.0 - px) * (a.1 - py) - (c.1 - py) * (a.0 - px)) / area;
                    let w2 = 1. - w0 - w1;
                    if w0 < 0. || w1 < 0. || w2 < 0. { continue; }
                    let u = w0 * tri[0].uv[0] + w1 * tri[1].uv[0] + w2 * tri[2].uv[0];
                    let v = w0 * tri[0].uv[1] + w1 * tri[1].uv[1] + w2 * tri[2].uv[1];
                    let tx = ((u * t.0 as f32) as isize).clamp(0, t.0 as isize - 1) as usize; let ty = ((v * t.1 as f32) as isize).clamp(0, t.1 as isize - 1) as usize;
                    let o = (ty * t.0 + tx) * 4;
                    let s4: [f32; 4] = std::array::from_fn(|k| (t.2[o + k] as f32 / 255. * d.multiply[k] + d.add[k]).clamp(0., 1.));
                    for k in 0..3 { let i = (y * w + x) * 3 + k; img[i] = img[i] * (1. - s4[3]) + s4[k] * s4[3]; }
                } }
            }
        }
        let bytes: Vec<u8> = img.iter().map(|v| (v.clamp(0., 1.) * 255.) as u8).collect();
        png(&format!("hud_{name}.png"), w, h, &bytes);
    };
    hud::feed(tick, &f); shot("idle", &mut tex);
    f.trick_name = "ID_TRICK_KICKFLIP".into(); f.new_trick = true; f.sequence_score = 250.; f.line_score = 1250.; f.sequence_timer = 60; f.line_time = 60.;
    tick += 1; hud::feed(tick, &f); f.new_trick = false;
    for _ in 0..30 { tick += 1; hud::feed(tick, &f); }
    shot("trick", &mut tex);
    f.multiplier = 2.0; f.clean = true; tick += 1; hud::feed(tick, &f);
    for _ in 0..20 { tick += 1; hud::feed(tick, &f); }
    shot("mult", &mut tex);
    for i in 0..120 { tick += 1; f.line_time = 60. - i as f32 * 0.25; f.sequence_timer = f.line_time as i32; hud::feed(tick, &f); }
    shot("later", &mut tex);
}
