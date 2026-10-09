//! Big-endian word access on byte buffers (banks, projects and instance memory are all big-endian,
//! as on the Xbox 360). Out-of-range reads return 0 and writes are dropped, so a malformed program
//! can never panic the audio thread; bank loading validates layouts up front.

#[inline]
pub fn u8_at(d: &[u8], at: usize) -> u8 {
    d.get(at).copied().unwrap_or(0)
}

#[inline]
pub fn i8_at(d: &[u8], at: usize) -> i8 {
    u8_at(d, at) as i8
}

#[inline]
pub fn u16_at(d: &[u8], at: usize) -> u16 {
    match d.get(at..at + 2) {
        Some(b) => u16::from_be_bytes([b[0], b[1]]),
        None => 0,
    }
}

#[inline]
pub fn i16_at(d: &[u8], at: usize) -> i16 {
    u16_at(d, at) as i16
}

#[inline]
pub fn u32_at(d: &[u8], at: usize) -> u32 {
    match d.get(at..at + 4) {
        Some(b) => u32::from_be_bytes([b[0], b[1], b[2], b[3]]),
        None => 0,
    }
}

#[inline]
pub fn i32_at(d: &[u8], at: usize) -> i32 {
    u32_at(d, at) as i32
}

#[inline]
pub fn f32_at(d: &[u8], at: usize) -> f32 {
    f32::from_bits(u32_at(d, at))
}

#[inline]
pub fn put_u8(d: &mut [u8], at: usize, v: u8) {
    if let Some(b) = d.get_mut(at) {
        *b = v;
    }
}

#[inline]
pub fn put_u16(d: &mut [u8], at: usize, v: u16) {
    if let Some(b) = d.get_mut(at..at + 2) {
        b.copy_from_slice(&v.to_be_bytes());
    }
}

#[inline]
pub fn put_u32(d: &mut [u8], at: usize, v: u32) {
    if let Some(b) = d.get_mut(at..at + 4) {
        b.copy_from_slice(&v.to_be_bytes());
    }
}

#[inline]
pub fn put_i32(d: &mut [u8], at: usize, v: i32) {
    put_u32(d, at, v as u32);
}

#[inline]
pub fn put_f32(d: &mut [u8], at: usize, v: f32) {
    put_u32(d, at, v.to_bits());
}

/// NUL-terminated Latin-1 string at `at`.
pub fn cstr(d: &[u8], at: usize) -> String {
    let tail = d.get(at..).unwrap_or(&[]);
    let end = tail.iter().position(|&b| b == 0).unwrap_or(tail.len());
    tail[..end].iter().map(|&b| b as char).collect()
}
