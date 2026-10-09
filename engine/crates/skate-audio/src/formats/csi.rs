//! Csis project (`.csi`, magic `MOIR`): the symbol tables game code and banks bind to.
//! Table 0 = Functions (`*_msg`), 1 = Classes (`c_*`), 2 = GlobalVariables (with a default value).
use super::{FormatError, err};
use crate::be::{cstr, i32_at, u16_at, u32_at};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Symbol {
    pub name: String,
    pub name_id: u16,
    /// GlobalVariables only: the default value.
    pub default: i32,
}

#[derive(Clone, Debug)]
pub struct Project {
    pub name: String,
    pub id: u16,
    /// [functions, classes, globals]
    pub tables: [Vec<Symbol>; 3],
}

impl Project {
    pub fn parse(name: &str, d: &[u8]) -> Result<Self, FormatError> {
        if d.len() < 0x28 || &d[..4] != b"MOIR" {
            return err(format!("{name}: not a MOIR project"));
        }
        let counts = [u16_at(d, 0x0A), u16_at(d, 0x0C), u16_at(d, 0x0E)];
        let id = u16_at(d, 0x10);
        let mut at = 0x28usize;
        let mut tables: [Vec<Symbol>; 3] = Default::default();
        for (t, &count) in counts.iter().enumerate() {
            let stride = if t == 2 { 16 } else { 12 };
            for i in 0..count as usize {
                let r = at + stride * i;
                if r + stride > d.len() {
                    return err(format!("{name}: table {t} runs past the file"));
                }
                let (name_off, name_id, default) = if t == 2 {
                    (u32_at(d, r + 8), u16_at(d, r + 12), i32_at(d, r + 4))
                } else {
                    (u32_at(d, r + 4), u16_at(d, r + 8), 0)
                };
                if name_off as usize >= d.len() {
                    return err(format!("{name}: symbol name outside the file"));
                }
                tables[t].push(Symbol { name: cstr(d, name_off as usize), name_id, default });
            }
            at += stride * count as usize;
        }
        Ok(Self { name: name.to_string(), id, tables })
    }

    /// The project as a `.csi` file (the layout [`Project::parse`] reads: a 0x28-byte header with
    /// the three counts at 0x0A / 0x0C / 0x0E and the id at 0x10, the tables, then the names).
    /// For tools and tests that make their own projects (doc 16 "Mod Csis projects").
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut d = vec![0u8; 0x28];
        d[..4].copy_from_slice(b"MOIR");
        for (t, at) in [0x0A, 0x0C, 0x0E].into_iter().enumerate() {
            d[at..at + 2].copy_from_slice(&(self.tables[t].len() as u16).to_be_bytes());
        }
        d[0x10..0x12].copy_from_slice(&self.id.to_be_bytes());
        let records: usize = self.tables.iter().enumerate().map(|(t, s)| s.len() * if t == 2 { 16 } else { 12 }).sum();
        let mut names = Vec::new();
        let mut rec = Vec::with_capacity(records);
        for (t, syms) in self.tables.iter().enumerate() {
            for s in syms {
                let off = (0x28 + records + names.len()) as u32;
                names.extend_from_slice(s.name.as_bytes());
                names.push(0);
                let mut r = vec![0u8; if t == 2 { 16 } else { 12 }];
                if t == 2 {
                    r[4..8].copy_from_slice(&s.default.to_be_bytes());
                    r[8..12].copy_from_slice(&off.to_be_bytes());
                    r[12..14].copy_from_slice(&s.name_id.to_be_bytes());
                } else {
                    r[4..8].copy_from_slice(&off.to_be_bytes());
                    r[8..10].copy_from_slice(&s.name_id.to_be_bytes());
                }
                rec.extend(r);
            }
        }
        d.extend(rec);
        d.extend(names);
        d
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_written_project_reads_back() {
        let s = |name: &str, name_id: u16, default: i32| Symbol { name: name.into(), name_id, default };
        let p = Project { name: "mod.csi".into(), id: 0x4D4F, tables: [vec![s("f_mod_msg", 1, 0)], vec![s("c_mod_a", 1, 0), s("c_mod_b", 2, 0)], vec![s("g_mod", 1, -7)]] };
        let back = Project::parse("mod.csi", &p.to_bytes()).unwrap();
        assert_eq!((back.id, &back.tables), (p.id, &p.tables));
    }
}
