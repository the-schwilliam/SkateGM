//! The local player's board outputs from the retail MixMap over ground speed, with the inputs
//! the game writes (`skate-game` `native::mixmap_frame`: free-skate globals, PlayerPhysics speed
//! words, all four wheels down, both 3DObjPos blocks active at a camera distance), next to the
//! retail capture medians of grain-player-spec §2.2 / §3.4 (grain pitch 3209 at rest, ~3500 at
//! 1 m/s, ~4080 from ~5 m/s; gain A ≈ 0.06 at 5 km/h, 0.08–0.17 from 10 km/h up).
//!
//! PlayerPhysics.in9 is 0 for the local player (pass 32767 to see a remote player: the high-pass
//! then sits at 1109 Hz and gain A drops ~2 dB).
//!
//! usage: cargo run -p skate-audio --release --example board_mix_probe -- <MixMapSK8.mxb> [camera m] [in9]
use skate_audio::mixmap::{MixMap, keys};

const SPEED_SCALES: [u32; 4] = [0x46B8_507A, 0x4575_C0A3, 0x4513_7395, 0x44D2_A51E];

fn word(v: f32, bits: u32) -> i32 {
    (v * f32::from_bits(bits)).clamp(0.0, 32767.0) as i32
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let bytes = std::fs::read(args.get(1).expect("usage: board_mix_probe <mxb> [camera m]")).expect("read mxb");
    let camera: f32 = args.get(2).map_or(3.5, |a| a.parse().unwrap());
    let in9: i32 = args.get(3).map_or(0, |a| a.parse().unwrap());
    println!("camera {camera} m, PlayerPhysics.in9 {in9}; km/h, level(1) gainA, level(2), pitch(3)/4096, LP(11) Hz, HP(12) Hz, rocket level(5)");
    for kmh in [0.0f32, 3.6, 5.0, 10.0, 15.0, 20.0, 30.0, 40.0, 50.0, 60.0] {
        let mut m = MixMap::from_bytes(&bytes).expect("parse");
        let v = kmh / 3.6;
        for _ in 0..30 {
            for id in 1..=4 {
                m.set_input(keys::MASTER, id, 32767);
            }
            for id in [1, 2, 5] {
                m.set_input(keys::MUSIC, id, 32767);
            }
            m.set_input(keys::REVERB, 5, 32767);
            let p = keys::player_physics(0);
            m.set_input(p, 0, word(v, SPEED_SCALES[0]));
            m.set_input(p, 1, word(v, SPEED_SCALES[1]));
            m.set_input(p, 7, word(v, SPEED_SCALES[2]));
            m.set_input(p, 8, word(v, SPEED_SCALES[3]));
            m.set_input(p, 14, word(v, SPEED_SCALES[3]));
            m.set_input(p, 10, (4.0 * 8191.75) as i32);
            m.set_input(p, 9, in9);
            for key in [keys::obj_pos(0), keys::obj_pos2(0)] {
                m.set_input_f32(key, keys::pos::DIST_SKATER, 0.0);
                m.set_input_f32(key, keys::pos::DIST_CAMERA, camera);
                m.set_input(key, keys::pos::FLAGS, 1);
            }
            m.tick(1.0 / 60.0);
        }
        let b = keys::skateboard(0);
        println!(
            "{kmh:5.1}  {:5} {:.3}  {:5}  {:.3}  {:5}  {:5}  {:5}",
            m.level(b, 1),
            m.level(b, 1) as f32 / 32767.0,
            m.level(b, 2),
            m.pitch_4096(b, 3) as f32 / 4096.0,
            m.filter_hz(b, 11),
            m.filter_hz(b, 12),
            m.level(keys::sense_of_speed(0), 5)
        );
    }
}
