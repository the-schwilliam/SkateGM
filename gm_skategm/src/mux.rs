use std::path::Path;

const EBML: u32 = 0x1A45_DFA3;
const SEGMENT: u32 = 0x1853_8067;
const INFO: u32 = 0x1549_A966;
const TIMECODE_SCALE: u32 = 0x2A_D7B1;
const DURATION: u32 = 0x4489;
const TRACKS: u32 = 0x1654_AE6B;
const TRACK_ENTRY: u32 = 0xAE;
const TRACK_NUMBER: u32 = 0xD7;
const TRACK_UID: u32 = 0x73C5;
const TRACK_TYPE: u32 = 0x83;
const CLUSTER: u32 = 0x1F43_B675;
const TIMECODE: u32 = 0xE7;
const SIMPLE_BLOCK: u32 = 0xA3;
const BLOCK_GROUP: u32 = 0xA0;
const BLOCK: u32 = 0xA1;
const REFERENCE_BLOCK: u32 = 0xFB;
const VOID: u32 = 0xEC;

const VIDEO: u64 = 1;
const AUDIO: u64 = 2;
const UNKNOWN: u64 = u64::MAX;
const CLUSTER_NS: i64 = 1_000_000_000;

struct Element<'a> {
    id: u32,
    data: &'a [u8],
}

fn read_id(b: &[u8], at: usize) -> Option<(u32, usize)> {
    let first = *b.get(at)?;
    let len = first.leading_zeros() as usize + 1;
    if len > 4 || at + len > b.len() {
        return None;
    }
    let mut id = 0u32;
    for i in 0..len {
        id = (id << 8) | b[at + i] as u32;
    }
    Some((id, len))
}

fn read_size(b: &[u8], at: usize) -> Option<(u64, usize)> {
    let first = *b.get(at)?;
    let len = first.leading_zeros() as usize + 1;
    if len > 8 || at + len > b.len() {
        return None;
    }
    let mut v = (first as u64) & (0xFF >> len);
    let mut all_ones = v == (0xFF >> len) as u64;
    for i in 1..len {
        v = (v << 8) | b[at + i] as u64;
        all_ones &= b[at + i] == 0xFF;
    }
    Some((if all_ones { UNKNOWN } else { v }, len))
}

fn children(b: &[u8]) -> Vec<Element<'_>> {
    let mut out = Vec::new();
    let mut at = 0;
    while at < b.len() {
        let Some((id, il)) = read_id(b, at) else { break };
        let Some((size, sl)) = read_size(b, at + il) else { break };
        let start = at + il + sl;
        let end = if size == UNKNOWN { b.len() } else { (start as u64 + size).min(b.len() as u64) as usize };
        out.push(Element { id, data: &b[start..end] });
        at = end;
    }
    out
}

fn uint(b: &[u8]) -> u64 {
    b.iter().fold(0u64, |v, &x| (v << 8) | x as u64)
}

fn float(b: &[u8]) -> f64 {
    match b.len() {
        4 => f32::from_be_bytes([b[0], b[1], b[2], b[3]]) as f64,
        8 => f64::from_be_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]),
        _ => 0.0,
    }
}

fn write_id(out: &mut Vec<u8>, id: u32) {
    let bytes = id.to_be_bytes();
    let skip = bytes.iter().position(|&x| x != 0).unwrap_or(3);
    out.extend_from_slice(&bytes[skip..]);
}

fn write_size(out: &mut Vec<u8>, size: u64) {
    out.push(0x01);
    out.extend_from_slice(&size.to_be_bytes()[1..]);
}

fn element(out: &mut Vec<u8>, id: u32, data: &[u8]) {
    write_id(out, id);
    write_size(out, data.len() as u64);
    out.extend_from_slice(data);
}

fn uint_bytes(v: u64) -> Vec<u8> {
    let b = v.to_be_bytes();
    let skip = b.iter().position(|&x| x != 0).unwrap_or(7);
    b[skip..].to_vec()
}

fn vint(v: u64) -> Vec<u8> {
    if v < 0x7F {
        vec![0x80 | v as u8]
    } else {
        vec![0x40 | (v >> 8) as u8, v as u8]
    }
}

struct Track {
    entry: Vec<u8>,
    number: u64,
}

struct Frame {
    ns: i64,
    key: bool,
    flags: u8,
    payload: Vec<u8>,
}

struct Parsed {
    header: Vec<u8>,
    scale: u64,
    duration_ns: f64,
    tracks: Vec<(u64, Track)>,
    frames: Vec<(u64, Frame)>,
}

fn block_header(b: &[u8]) -> Option<(u64, i16, u8, usize)> {
    let (track, tl) = read_size(b, 0)?;
    if b.len() < tl + 3 {
        return None;
    }
    let rel = i16::from_be_bytes([b[tl], b[tl + 1]]);
    Some((track, rel, b[tl + 2], tl + 3))
}

fn parse(file: &[u8]) -> Result<Parsed, String> {
    let top = children(file);
    let header = top.iter().find(|e| e.id == EBML).ok_or("not a WebM file (no EBML header)")?;
    let mut header_bytes = Vec::new();
    element(&mut header_bytes, EBML, header.data);
    let segment = top.iter().find(|e| e.id == SEGMENT).ok_or("no Segment")?;
    let mut scale = 1_000_000u64;
    let mut duration = 0.0;
    let mut tracks = Vec::new();
    let mut frames = Vec::new();
    for e in children(segment.data) {
        match e.id {
            INFO => {
                for c in children(e.data) {
                    if c.id == TIMECODE_SCALE {
                        scale = uint(c.data).max(1);
                    } else if c.id == DURATION {
                        duration = float(c.data);
                    }
                }
            }
            TRACKS => {
                for t in children(e.data).into_iter().filter(|t| t.id == TRACK_ENTRY) {
                    let mut kind = 0;
                    let mut number = 0;
                    for c in children(t.data) {
                        if c.id == TRACK_TYPE {
                            kind = uint(c.data);
                        } else if c.id == TRACK_NUMBER {
                            number = uint(c.data);
                        }
                    }
                    tracks.push((kind, Track { entry: t.data.to_vec(), number }));
                }
            }
            CLUSTER => {
                let parts = children(e.data);
                let base = parts.iter().find(|c| c.id == TIMECODE).map(|c| uint(c.data)).unwrap_or(0) as i64;
                for c in parts {
                    let (block, key_hint) = match c.id {
                        SIMPLE_BLOCK => (Some(c.data), None),
                        BLOCK_GROUP => {
                            let inner = children(c.data);
                            let reference = inner.iter().any(|x| x.id == REFERENCE_BLOCK);
                            (inner.iter().find(|x| x.id == BLOCK).map(|x| x.data), Some(!reference))
                        }
                        _ => (None, None),
                    };
                    let Some(block) = block else { continue };
                    let Some((track, rel, flags, at)) = block_header(block) else { continue };
                    let key = key_hint.unwrap_or(flags & 0x80 != 0);
                    let ns = (base + rel as i64) * scale as i64;
                    frames.push((track, Frame { ns, key, flags: flags & 0x7F & !0x08, payload: block[at..].to_vec() }));
                }
            }
            _ => {}
        }
    }
    Ok(Parsed { header: header_bytes, scale, duration_ns: duration * scale as f64, tracks, frames })
}

fn retracked(entry: &[u8], number: u64) -> Vec<u8> {
    let mut out = Vec::new();
    for c in children(entry) {
        match c.id {
            TRACK_NUMBER => element(&mut out, TRACK_NUMBER, &uint_bytes(number)),
            TRACK_UID => element(&mut out, TRACK_UID, &uint_bytes(number)),
            VOID => {}
            id => element(&mut out, id, c.data),
        }
    }
    out
}

pub fn mux_bytes(video_file: &[u8], audio_file: &[u8], audio_offset_ns: i64) -> Result<Vec<u8>, String> {
    let v = parse(video_file)?;
    let a = parse(audio_file)?;
    let (_, vt) = v.tracks.iter().find(|(k, _)| *k == VIDEO).ok_or("the picture pass has no video track")?;
    let (_, at) = a.tracks.iter().find(|(k, _)| *k == AUDIO).ok_or("the sound pass has no audio track")?;
    let mut frames: Vec<(u64, Frame)> = Vec::new();
    for (track, f) in v.frames.into_iter() {
        if track == vt.number {
            frames.push((1, f));
        }
    }
    let video_end = frames.iter().map(|(_, f)| f.ns).max().unwrap_or(0);
    let frame_ns = if frames.len() > 1 { video_end / (frames.len() as i64 - 1).max(1) } else { 0 };
    let end_ns = (video_end + frame_ns).max(v.duration_ns as i64);
    for (track, mut f) in a.frames.into_iter() {
        if track != at.number {
            continue;
        }
        f.ns -= audio_offset_ns;
        if f.ns < 0 || f.ns > end_ns {
            continue;
        }
        f.key = true;
        frames.push((2, f));
    }
    frames.sort_by(|x, y| x.1.ns.cmp(&y.1.ns).then(x.0.cmp(&y.0)));

    let scale = v.scale.min(a.scale).max(1);
    let mut info = Vec::new();
    element(&mut info, TIMECODE_SCALE, &uint_bytes(scale));
    element(&mut info, DURATION, &((end_ns as f64 / scale as f64).to_be_bytes()));
    element(&mut info, 0x4D80, b"SkateGM");
    element(&mut info, 0x5741, b"SkateGM");
    let mut tracks = Vec::new();
    element(&mut tracks, TRACK_ENTRY, &retracked(&vt.entry, 1));
    element(&mut tracks, TRACK_ENTRY, &retracked(&at.entry, 2));

    let mut segment = Vec::new();
    element(&mut segment, INFO, &info);
    element(&mut segment, TRACKS, &tracks);
    let mut i = 0;
    while i < frames.len() {
        let start = frames[i].1.ns;
        let base = start / scale as i64;
        let mut cluster = Vec::new();
        element(&mut cluster, TIMECODE, &uint_bytes(base.max(0) as u64));
        let mut first = true;
        while i < frames.len() {
            let (track, f) = &frames[i];
            let rel = f.ns / scale as i64 - base;
            let new_cluster = !first && (f.ns - start >= CLUSTER_NS || (*track == 1 && f.key) || rel > i16::MAX as i64);
            if new_cluster {
                break;
            }
            let mut block = vint(*track);
            block.extend_from_slice(&(rel as i16).to_be_bytes());
            block.push(f.flags | if f.key { 0x80 } else { 0 });
            block.extend_from_slice(&f.payload);
            element(&mut cluster, SIMPLE_BLOCK, &block);
            first = false;
            i += 1;
        }
        element(&mut segment, CLUSTER, &cluster);
    }
    let mut out = v.header.clone();
    element(&mut out, SEGMENT, &segment);
    Ok(out)
}

pub fn mux_files(video: &Path, audio: &Path, out: &Path, audio_offset_s: f64) -> Result<(), String> {
    let vb = std::fs::read(video).map_err(|e| format!("can't read the picture pass: {e}"))?;
    let ab = std::fs::read(audio).map_err(|e| format!("can't read the sound pass: {e}"))?;
    let bytes = mux_bytes(&vb, &ab, (audio_offset_s * 1e9) as i64)?;
    let tmp = out.with_extension("webm.part");
    std::fs::write(&tmp, &bytes).map_err(|e| format!("can't write the video: {e}"))?;
    std::fs::rename(&tmp, out).map_err(|e| format!("can't write the video: {e}"))?;
    Ok(())
}

pub fn safe_name(name: &str) -> bool {
    !name.is_empty() && name.len() < 200 && name.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn webm(tracks: &[(u64, u64)], frames: &[(u64, i64, bool, u8)]) -> Vec<u8> {
        let mut out = Vec::new();
        element(&mut out, EBML, &[0x42, 0x82, 0x84, b'w', b'e', b'b', b'm']);
        let mut seg = Vec::new();
        let mut info = Vec::new();
        element(&mut info, TIMECODE_SCALE, &uint_bytes(1_000_000));
        element(&mut info, DURATION, &(2000.0f64).to_be_bytes());
        element(&mut seg, INFO, &info);
        let mut tr = Vec::new();
        for &(n, kind) in tracks {
            let mut t = Vec::new();
            element(&mut t, TRACK_NUMBER, &uint_bytes(n));
            element(&mut t, TRACK_TYPE, &uint_bytes(kind));
            element(&mut t, 0x86, if kind == VIDEO { b"V_VP8" } else { b"A_VORBIS" });
            element(&mut tr, TRACK_ENTRY, &t);
        }
        element(&mut seg, TRACKS, &tr);
        let mut cl = Vec::new();
        element(&mut cl, TIMECODE, &uint_bytes(0));
        for &(n, ms, key, tag) in frames {
            let mut b = vint(n);
            b.extend_from_slice(&(ms as i16).to_be_bytes());
            b.push(if key { 0x80 } else { 0 });
            b.push(tag);
            element(&mut cl, SIMPLE_BLOCK, &b);
        }
        element(&mut seg, CLUSTER, &cl);
        element(&mut out, SEGMENT, &seg);
        out
    }

    #[test]
    fn keeps_the_video_of_one_and_the_audio_of_the_other() {
        let video = webm(&[(1, VIDEO), (2, AUDIO)], &[(1, 0, true, 10), (2, 5, true, 99), (1, 33, false, 11), (1, 66, false, 12)]);
        let audio = webm(&[(1, VIDEO), (2, AUDIO)], &[(1, 0, true, 50), (2, 100, true, 20), (2, 120, true, 21), (2, 140, true, 22)]);
        let out = mux_bytes(&video, &audio, 100_000_000).unwrap();
        let p = parse(&out).unwrap();
        assert_eq!(p.tracks.len(), 2);
        let video_tags: Vec<u8> = p.frames.iter().filter(|(t, _)| *t == 1).map(|(_, f)| f.payload[0]).collect();
        let audio: Vec<(i64, u8)> = p.frames.iter().filter(|(t, _)| *t == 2).map(|(_, f)| (f.ns / 1_000_000, f.payload[0])).collect();
        assert_eq!(video_tags, vec![10, 11, 12]);
        assert_eq!(audio, vec![(0, 20), (20, 21), (40, 22)]);
        assert!(p.frames.iter().filter(|(t, _)| *t == 1).map(|(_, f)| f.key).eq([true, false, false]));
    }

    #[test]
    fn audio_before_the_offset_or_past_the_video_is_dropped() {
        let video = webm(&[(1, VIDEO)], &[(1, 0, true, 1), (1, 1000, false, 2)]);
        let audio = webm(&[(2, AUDIO)], &[(2, 0, true, 7), (2, 600, true, 8), (2, 5000, true, 9)]);
        let out = mux_bytes(&video, &audio, 500_000_000).unwrap();
        let p = parse(&out).unwrap();
        let audio: Vec<u8> = p.frames.iter().filter(|(t, _)| *t == 2).map(|(_, f)| f.payload[0]).collect();
        assert_eq!(audio, vec![8]);
    }

    #[test]
    fn long_videos_split_into_clusters_with_valid_relative_times() {
        let mut many = Vec::new();
        for i in 0..120i64 {
            let mut c = Vec::new();
            element(&mut c, TIMECODE, &uint_bytes((i * 1000) as u64));
            let mut b = vint(1);
            b.extend_from_slice(&0i16.to_be_bytes());
            b.push(0x80);
            b.push(i as u8);
            element(&mut c, SIMPLE_BLOCK, &b);
            many.push(c);
        }
        let mut out = Vec::new();
        element(&mut out, EBML, &[0x42, 0x82, 0x84, b'w', b'e', b'b', b'm']);
        let mut s = Vec::new();
        let mut info = Vec::new();
        element(&mut info, TIMECODE_SCALE, &uint_bytes(1_000_000));
        element(&mut s, INFO, &info);
        let mut tr = Vec::new();
        let mut t = Vec::new();
        element(&mut t, TRACK_NUMBER, &uint_bytes(1));
        element(&mut t, TRACK_TYPE, &uint_bytes(VIDEO));
        element(&mut tr, TRACK_ENTRY, &t);
        element(&mut s, TRACKS, &tr);
        for c in many {
            element(&mut s, CLUSTER, &c);
        }
        element(&mut out, SEGMENT, &s);
        let audio = webm(&[(2, AUDIO)], &[(2, 0, true, 1)]);
        let muxed = mux_bytes(&out, &audio, 0).unwrap();
        let p = parse(&muxed).unwrap();
        let times: Vec<i64> = p.frames.iter().filter(|(t, _)| *t == 1).map(|(_, f)| f.ns / 1_000_000).collect();
        assert_eq!(times, (0..120).map(|i| i * 1000).collect::<Vec<_>>());
    }

    #[test]
    fn names_are_plain() {
        assert!(safe_name("skategm_tl_2026-10-05_10-30-03"));
        assert!(!safe_name("../cfg/config"));
        assert!(!safe_name("a b"));
        assert!(!safe_name(""));
    }
}
