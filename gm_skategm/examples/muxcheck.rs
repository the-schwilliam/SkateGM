fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 4 {
        eprintln!("usage: muxcheck <video.webm> <audio.webm> <out.webm> [audio offset s]");
        std::process::exit(2);
    }
    let offset = a.get(4).and_then(|s| s.parse().ok()).unwrap_or(0.0);
    let t = std::time::Instant::now();
    match gmcl_skategm_win64::mux::mux_files(a[1].as_ref(), a[2].as_ref(), a[3].as_ref(), offset) {
        Ok(()) => println!("ok in {:.2} s", t.elapsed().as_secs_f64()),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}
