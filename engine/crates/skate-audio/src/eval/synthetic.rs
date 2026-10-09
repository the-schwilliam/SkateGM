//! Hand-built ABKC banks for tests (the evaluator's unit tests and the integration tests, e.g.
//! `tests/render_alloc.rs`): not retail data, built from the format spec. Hidden from the docs.
use crate::be::*;
use crate::formats::Bank;
use crate::formats::Project;
use crate::formats::csi::Symbol;

/// One module of a synthetic bank.
pub struct Spec {
    pub max: i16,
    pub globals: u16,
    pub functions: u16,
    pub destructor: bool,
    pub class_data: bool,
    pub players: Vec<u32>,
    pub template: Vec<u8>,
    /// (opcode, pairs, block offset); advances are derived from the next op's block.
    pub program: Vec<(u8, Vec<(i32, i32)>, u32)>,
    /// Template offsets that must hold the bank offset of the shared sample group.
    pub group_ptrs: Vec<u32>,
}

/// An export: kind (0 global, 1 class, 2 function), name id, name, and where the handle goes:
/// None = the module's class handle, Some(off) = template offset.
pub struct Ex {
    pub module: usize,
    pub kind: u32,
    pub name_id: u16,
    pub name: &'static str,
    pub at: Option<u32>,
}

pub const PROJECT: u16 = 0x1234;

pub fn project() -> Project {
    let s = |name: &str, id: u16, default: i32| Symbol { name: name.into(), name_id: id, default };
    Project {
        name: "test.csi".into(),
        id: PROJECT,
        tables: [
            vec![s("f_msg", 1, 0)],
            vec![s("c_test", 1, 0), s("c_util", 2, 0), s("c_req", 3, 0)],
            vec![s("g_snd", 1, 77)],
        ],
    }
}

pub fn be(v: &mut Vec<u8>, w: u32) {
    v.extend_from_slice(&w.to_be_bytes());
}

/// Build an ABKC bank: header | module records | templates | programs | sample group | S10A |
/// interface list + id records | empty rebase list. Samples: (frames, looping) at 48 kHz mono.
pub fn bank(modules: &[Spec], exports: &[Ex], samples: &[(u32, bool)]) -> Bank {
    let records: usize = modules.iter().map(|m| 60 + 4 * m.players.len()).sum();
    let mut at = 0x5C + records;
    let mut template_at = Vec::new();
    for m in modules {
        template_at.push(at);
        at += m.template.len();
    }
    let mut program_at = Vec::new();
    let mut programs = Vec::new();
    for m in modules {
        program_at.push(at);
        let mut p = Vec::new();
        for (i, (op, pairs, block)) in m.program.iter().enumerate() {
            let next = m.program.get(i + 1).map_or(m.template.len() as u32, |o| o.2);
            p.push(*op);
            p.push(pairs.len() as u8);
            p.extend_from_slice(&[0, 0]);
            for &(s, d) in pairs {
                be(&mut p, s as u32);
                be(&mut p, d as u32);
            }
            be(&mut p, next - block);
        }
        p.push(255);
        p.extend_from_slice(&[0, 0, 0]);
        at += p.len();
        programs.push(p);
    }
    let group_at = at;
    let mut group = Vec::new();
    be(&mut group, samples.len() as u32);
    for i in 0..samples.len() {
        group.extend_from_slice(&(i as u16).to_be_bytes());
        group.push(100);
        // Bytes 3..7 azimuths; byte 8 is the first byte of the stream offset word.
        group.extend_from_slice(&[0, 0, 0, 0, (i + 1) as u8]);
        be(&mut group, u32::MAX);
    }
    at += group.len();
    let s10a_at = at;
    let mut s10a = b"S10A".to_vec();
    be(&mut s10a, 0);
    be(&mut s10a, samples.len() as u32);
    let mut bodies = Vec::new();
    let table = 12 + 4 * samples.len();
    for &(frames, looping) in samples {
        be(&mut s10a, (table + bodies.len()) as u32);
        be(&mut bodies, (3 << 24) | 48000);
        be(&mut bodies, (u32::from(looping) << 29) | frames);
        be(&mut bodies, 0);
    }
    s10a.extend_from_slice(&bodies);
    at += s10a.len();
    let interface_at = at;
    let mut iface = Vec::new();
    be(&mut iface, exports.len() as u32);
    let ids_at = interface_at + 4 + 12 * exports.len();
    let mut ids = Vec::new();
    let mut module_at = Vec::new();
    let mut r = 0x5C;
    for m in modules {
        module_at.push(r);
        r += 60 + 4 * m.players.len();
    }
    for e in exports {
        let handle = match e.at {
            None => module_at[e.module] + 4,
            Some(off) => template_at[e.module] + off as usize,
        };
        be(&mut iface, handle as u32);
        be(&mut iface, (ids_at + ids.len()) as u32);
        be(&mut iface, e.kind << 24);
        ids.extend_from_slice(&PROJECT.to_be_bytes());
        ids.extend_from_slice(&e.name_id.to_be_bytes());
        ids.extend_from_slice(e.name.as_bytes());
        ids.push(0);
        while ids.len() % 4 != 0 {
            ids.push(0);
        }
    }
    at = ids_at + ids.len();
    let rebase_at = at;

    let mut d = vec![0u8; 0x5C];
    d[..4].copy_from_slice(b"ABKC");
    d[0x0A..0x0C].copy_from_slice(&(modules.len() as u16).to_be_bytes());
    d[0x18..0x1C].copy_from_slice(&(s10a_at as u32).to_be_bytes());
    d[0x1C..0x20].copy_from_slice(&0x5Cu32.to_be_bytes());
    d[0x20..0x24].copy_from_slice(&(s10a_at as u32).to_be_bytes());
    d[0x34..0x38].copy_from_slice(&(rebase_at as u32).to_be_bytes());
    d[0x38..0x3C].copy_from_slice(&(interface_at as u32).to_be_bytes());
    for (i, m) in modules.iter().enumerate() {
        let mut rec = vec![0u8; 60];
        rec[0x1E..0x20].copy_from_slice(&m.max.to_be_bytes());
        rec[0x20..0x22].copy_from_slice(&m.globals.to_be_bytes());
        rec[0x22..0x24].copy_from_slice(&m.functions.to_be_bytes());
        rec[0x24] = m.players.len() as u8;
        rec[0x25] = u8::from(m.destructor);
        rec[0x26] = u8::from(m.class_data);
        rec[0x28..0x2C].copy_from_slice(&(program_at[i] as u32).to_be_bytes());
        rec[0x2C..0x30].copy_from_slice(&(template_at[i] as u32).to_be_bytes());
        rec[0x30..0x34].copy_from_slice(&(m.template.len() as u32).to_be_bytes());
        rec[0x34..0x38].copy_from_slice(&(m.template.len() as u32 - 16).to_be_bytes());
        for p in &m.players {
            be(&mut rec, *p);
        }
        d.extend_from_slice(&rec);
    }
    for m in modules {
        let mut t = m.template.clone();
        for &g in &m.group_ptrs {
            put_u32(&mut t, g as usize, group_at as u32);
        }
        d.extend_from_slice(&t);
    }
    for p in &programs {
        d.extend_from_slice(p);
    }
    d.extend_from_slice(&group);
    d.extend_from_slice(&s10a);
    d.extend_from_slice(&iface);
    d.extend_from_slice(&ids);
    be(&mut d, 0); // empty rebase list
    Bank::parse("test.abk", d).expect("synthetic bank")
}

/// Template words helper.
pub fn words(n: usize) -> Vec<u8> {
    vec![0u8; 4 * n]
}

/// A c_test module: destructor @24, ClassData (2 values) @44, Create @72, Player @76 (one input:
/// pitch), Destroy @124. Payload w0 → playcontrol, w1 → pitch, w2 → sample select.
pub fn player_module(max: i16) -> Spec {
    let mut t = words(35); // 140 bytes
    put_u8(&mut t, 44 + 16, 3); // ClassData: 3 values ((3 + 5)·4 = 32 B → @44..76)
    // Create @76
    put_i32(&mut t, 76, 1);
    // Player @80: n = 1 input, update outputs
    let p = 80usize;
    put_u8(&mut t, p + 14, 1);
    put_u8(&mut t, p + 15, 1);
    put_u8(&mut t, p + 28, 0); // input id 0 (pitch)
    put_i32(&mut t, p + 32, -1); // applied
    // Destroy @124 (datasize 140 − 16)
    Spec {
        max,
        globals: 0,
        functions: 0,
        destructor: true,
        class_data: true,
        players: vec![80],
        template: t,
        program: vec![
            (0, vec![(-1, 124 + 12 - 24)], 24),
            // ClassData @44: values at +20,+24,+28 → playcontrol (+24 of player), pitch value
            // (+36), sample select (+20).
            (1, vec![(20, 80 + 24 - 44), (24, 80 + 36 - 44), (28, 80 + 20 - 44)], 44),
            (3, vec![], 76),
            (27, vec![], 80),
            (4, vec![], 124),
        ],
        group_ptrs: vec![80 + 4],
    }
}
