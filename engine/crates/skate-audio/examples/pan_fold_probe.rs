//! The stereo gain a mono voice gets through Pan2D1 and the output stage's stereo fold, by
//! azimuth (degrees): what the native host does to a voice of per-voice gain 1.
//! usage: cargo run -p skate-audio --release --example pan_fold_probe
use skate_audio::dsp::pan::{ANGLE, Pan2D};

fn main() {
    const G707: f32 = std::f32::consts::FRAC_1_SQRT_2;
    println!("azimuth  L  C  R  Ls  Rs  ->  left  right  (power sum dB)");
    for az in [0.0f32, 30.0, 60.0, 90.0, 135.0, 180.0, -90.0] {
        let mut p = Pan2D::new(1);
        p.params[ANGLE] = az;
        let m = p.matrix()[0];
        let l = G707 * m[0] + 0.5 * m[1] + 0.5 * m[3];
        let r = G707 * m[2] + 0.5 * m[1] + 0.5 * m[4];
        let db = 10.0 * (l * l + r * r).log10();
        println!("{az:6.0}  {:.3} {:.3} {:.3} {:.3} {:.3}  ->  {l:.3} {r:.3}  ({db:+.1} dB vs a mono g on both channels {:+.1} dB)", m[0], m[1], m[2], m[3], m[4], db - 10.0 * 2.0f32.log10());
    }
}
