use glam::Vec3;

pub const PACK_PATH: &str = "skategm/skate3.sk3c";
const MAGIC: &[u8; 4] = b"SK3C";
const VERSION: u32 = 1;

pub struct Authored {
    pub triangles: Vec<[Vec3; 3]>,
    pub surfaces: Vec<u32>,
    pub rails: Vec<Vec<Vec3>>,
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn u32(&mut self) -> Result<u32, String> {
        let end = self.at + 4;
        let b = self.bytes.get(self.at..end).ok_or("truncated SK3C")?;
        self.at = end;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    fn f32(&mut self) -> Result<f32, String> {
        let v = f32::from_bits(self.u32()?);
        if v.is_finite() { Ok(v) } else { Err("non-finite value in SK3C".into()) }
    }

    fn vec3(&mut self) -> Result<Vec3, String> {
        Ok(Vec3::new(self.f32()?, self.f32()?, self.f32()?))
    }

    fn count(&mut self, each: usize) -> Result<usize, String> {
        let n = self.u32()? as usize;
        if n.saturating_mul(each) > self.bytes.len() - self.at.min(self.bytes.len()) {
            return Err("SK3C count runs past the end".into());
        }
        Ok(n)
    }
}

pub fn decode(bytes: &[u8]) -> Result<Authored, String> {
    if bytes.len() < 16 || &bytes[..4] != MAGIC {
        return Err("not a SK3C file".into());
    }
    let mut r = Reader { bytes, at: 4 };
    let version = r.u32()?;
    if version != VERSION {
        return Err(format!("unsupported SK3C version {version}"));
    }
    let count = r.u32()? as usize;
    let rail_count = r.u32()? as usize;
    if count.saturating_mul(40) > bytes.len() {
        return Err("SK3C triangle count runs past the end".into());
    }
    let mut triangles = Vec::with_capacity(count);
    for _ in 0..count {
        triangles.push([r.vec3()?, r.vec3()?, r.vec3()?]);
    }
    let mut surfaces = Vec::with_capacity(count);
    for _ in 0..count {
        surfaces.push(r.u32()?);
    }
    let mut rails = Vec::new();
    for _ in 0..rail_count {
        let n = r.count(12)?;
        let _closed = r.u32()?;
        let mut points = Vec::with_capacity(n);
        for _ in 0..n {
            points.push(r.vec3()?);
        }
        if points.len() >= 2 {
            rails.push(points);
        }
    }
    if r.at != bytes.len() {
        return Err("SK3C has trailing bytes".into());
    }
    Ok(Authored { triangles, surfaces, rails })
}

pub fn from_pack(bsp: &vbsp::Bsp) -> Option<Result<Authored, String>> {
    match bsp.pack.get(PACK_PATH) {
        Ok(Some(bytes)) => Some(decode(&bytes)),
        Ok(None) => None,
        Err(e) => Some(Err(format!("could not read {PACK_PATH}: {e}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encode(tris: &[[[f32; 3]; 3]], rails: &[Vec<[f32; 3]>]) -> Vec<u8> {
        let mut out = MAGIC.to_vec();
        for v in [VERSION, tris.len() as u32, rails.len() as u32] {
            out.extend(v.to_le_bytes());
        }
        for t in tris {
            for p in t {
                for c in p {
                    out.extend(c.to_le_bytes());
                }
            }
        }
        for i in 0..tris.len() {
            out.extend((i as u32 + 7).to_le_bytes());
        }
        for r in rails {
            out.extend((r.len() as u32).to_le_bytes());
            out.extend(0u32.to_le_bytes());
            for p in r {
                for c in p {
                    out.extend(c.to_le_bytes());
                }
            }
        }
        out
    }

    #[test]
    fn reads_what_mapgen_writes() {
        let tris = [[[0.0, 0.0, 0.0], [10.0, 0.0, 0.0], [0.0, 10.0, 0.0]]];
        let rails = vec![vec![[0.0, 0.0, 8.0], [50.0, 0.0, 8.0], [90.0, 5.0, 8.0]]];
        let a = decode(&encode(&tris, &rails)).unwrap();
        assert_eq!(a.triangles.len(), 1);
        assert_eq!(a.triangles[0][1], Vec3::new(10.0, 0.0, 0.0));
        assert_eq!(a.surfaces, vec![7]);
        assert_eq!(a.rails.len(), 1);
        assert_eq!(a.rails[0][2], Vec3::new(90.0, 5.0, 8.0));
    }

    #[test]
    fn refuses_damaged_files() {
        let tris = [[[0.0, 0.0, 0.0], [10.0, 0.0, 0.0], [0.0, 10.0, 0.0]]];
        let good = encode(&tris, &[]);
        assert!(decode(&good[..good.len() - 1]).is_err());
        let mut extra = good.clone();
        extra.push(0);
        assert!(decode(&extra).is_err());
        let mut nan = good.clone();
        nan[16..20].copy_from_slice(&f32::NAN.to_le_bytes());
        assert!(decode(&nan).is_err());
        assert!(decode(b"NOPE............").is_err());
    }
}
