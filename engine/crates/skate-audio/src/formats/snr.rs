//! EA Audio Core "SNR" sample header, as it starts every slot of an `S10A` sample bank: two
//! big-endian words (plus a loop-start word when looped).
//! - word 0: version (bits 28..31), codec (24..27), channels − 1 (18..23), sample rate (0..17);
//! - word 1: type (30..31; 0 = RAM), loop flag (29), sample frames (0..28);
//! - word 2 (looped only): loop start frame.
use crate::be::u32_at;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SampleHeader {
    pub codec: u8,
    pub channels: u8,
    pub rate: u32,
    pub frames: u32,
    pub loop_start: Option<u32>,
}

impl SampleHeader {
    /// Parse the header at `at`, or None when it is not a plausible RAM sample.
    pub fn parse(d: &[u8], at: usize) -> Option<Self> {
        if at + 8 > d.len() {
            return None;
        }
        let w0 = u32_at(d, at);
        let w1 = u32_at(d, at + 4);
        let (version, codec) = (w0 >> 28, ((w0 >> 24) & 0xF) as u8);
        let channels = (((w0 >> 18) & 0x3F) + 1) as u8;
        let rate = w0 & 0x3FFFF;
        let (kind, looped, frames) = (w1 >> 30, (w1 >> 29) & 1 == 1, w1 & 0x1FFF_FFFF);
        if version > 1 || kind != 0 || rate == 0 || frames == 0 || channels > 8 {
            return None;
        }
        let loop_start = if looped { Some(u32_at(d, at + 8)) } else { None };
        Some(Self { codec, channels, rate, frames, loop_start })
    }

    /// Duration in seconds (source time: frames / rate).
    pub fn seconds(&self) -> f64 {
        f64::from(self.frames) / f64::from(self.rate)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_mono_xma_with_and_without_loop() {
        // version 0, codec 3 (EA-XMA), 1 channel, 48000 Hz; 96000 frames.
        let mut d = Vec::new();
        d.extend_from_slice(&((3u32 << 24) | 48000).to_be_bytes());
        d.extend_from_slice(&96000u32.to_be_bytes());
        let h = SampleHeader::parse(&d, 0).unwrap();
        assert_eq!((h.codec, h.channels, h.rate, h.frames, h.loop_start), (3, 1, 48000, 96000, None));
        assert_eq!(h.seconds(), 2.0);
        // Stereo, looped from frame 100.
        let mut d = Vec::new();
        d.extend_from_slice(&((3u32 << 24) | (1 << 18) | 44100).to_be_bytes());
        d.extend_from_slice(&((1u32 << 29) | 44100).to_be_bytes());
        d.extend_from_slice(&100u32.to_be_bytes());
        let h = SampleHeader::parse(&d, 0).unwrap();
        assert_eq!((h.channels, h.loop_start), (2, Some(100)));
    }
}
