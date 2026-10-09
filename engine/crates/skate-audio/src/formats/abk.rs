//! AEMS ModuleBank (`.abk`, magic `ABKC`): modules (patch programs + instance templates), the
//! interface (export) list that binds them to Csis symbols, and the `S10A` sample bank.
//! Layout: `audio-specs/aems-evaluator-spec.md` §1.1–1.5.
//!
//! Pointers inside the bank (TABLE, sample group, …) are kept as bank-relative offsets, which is
//! what they hold on disc before the loader's rebase; ops resolve them through the bank bytes.
use super::{FormatError, SampleHeader, err};
use crate::be::{cstr, i32_at, i16_at, u8_at, u16_at, u32_at};

/// Symbol table an export binds to (top byte of the export kind).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum InterfaceKind {
    GlobalVariable,
    Class,
    Function,
}

impl InterfaceKind {
    /// Csis table index (0 functions, 1 classes, 2 globals).
    pub fn table(self) -> usize {
        match self {
            Self::Function => 0,
            Self::Class => 1,
            Self::GlobalVariable => 2,
        }
    }
}

/// One interface reference: "resolve this symbol and put its handle at `handle_offset`".
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Export {
    pub handle_offset: u32,
    pub kind: InterfaceKind,
    pub project: u16,
    pub name_id: u16,
    pub name: String,
}

/// One program record: opcode, copy pairs {src, dst} (src −1 = the op's result) relative to the
/// op's block, and the block's offset in the instance.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Op {
    pub opcode: u8,
    pub pairs: Vec<(i32, i32)>,
    /// Byte offset of this op's data block from the instance start.
    pub block: u32,
}

/// One Module (patch): program, instance template and the template's subscription layout.
#[derive(Clone, Debug)]
pub struct Module {
    /// Bank offset of the module record (its class handle is at +4).
    pub offset: u32,
    pub max_instances: i16,
    pub num_globals: u16,
    pub num_functions: u16,
    pub num_players: u8,
    pub has_destructor: bool,
    pub has_class_data: bool,
    pub num_controllers: u8,
    pub program_offset: u32,
    pub template_offset: u32,
    pub data_size: u32,
    pub destroy_offset: u32,
    /// Instance offsets of each Player state, then each ControlClass state.
    pub objects: Vec<u32>,
    pub program: Vec<Op>,
    /// Instance offsets of the subscription states (§1.4).
    pub destructor_state: Option<u32>,
    pub global_states: Vec<u32>,
    pub class_data_state: Option<u32>,
    pub function_states: Vec<u32>,
}

impl Module {
    /// The template bytes inside `bank`.
    pub fn template<'a>(&self, bank: &'a [u8]) -> &'a [u8] {
        let start = self.template_offset as usize;
        &bank[start..start + self.data_size as usize]
    }

    /// Instance offsets of the Player (op 27) states.
    pub fn players(&self) -> &[u32] {
        &self.objects[..self.num_players as usize]
    }

    /// Instance offsets of the ControlClass (op 38) states.
    pub fn controllers(&self) -> &[u32] {
        &self.objects[self.num_players as usize..]
    }
}

#[derive(Clone, Debug)]
pub struct Bank {
    pub name: String,
    pub data: Vec<u8>,
    pub modules: Vec<Module>,
    pub exports: Vec<Export>,
    /// Bank offset of the `S10A` tag.
    pub sample_bank: u32,
    /// Per used S10A slot: the bank offset of its sample and the parsed header (None if the slot
    /// does not hold a recognisable RAM sample).
    pub samples: Vec<(u32, Option<SampleHeader>)>,
}

/// Highest opcode in the TU3 opcode table.
pub const OPCODES: u8 = 40;

impl Bank {
    pub fn parse(name: &str, data: Vec<u8>) -> Result<Self, FormatError> {
        let d = &data[..];
        if d.len() < 0x5C || &d[..4] != b"ABKC" {
            return err(format!("{name}: not an ABKC bank"));
        }
        let count = u16_at(d, 0x0A) as usize;
        let module_at = u32_at(d, 0x1C) as usize;
        let sample_bank = u32_at(d, 0x20);
        let interface = u32_at(d, 0x38) as usize;

        // Interface references.
        let n = u32_at(d, interface) as usize;
        if interface + 4 + 12 * n > d.len() {
            return err(format!("{name}: interface list runs past the file"));
        }
        let mut exports = Vec::with_capacity(n);
        for i in 0..n {
            let r = interface + 4 + 12 * i;
            let (handle_offset, id_at, kind) = (u32_at(d, r), u32_at(d, r + 4) as usize, u32_at(d, r + 8));
            let kind = match kind >> 24 {
                0 => InterfaceKind::GlobalVariable,
                1 => InterfaceKind::Class,
                2 => InterfaceKind::Function,
                k => return err(format!("{name}: export {i} has interface type {k}")),
            };
            exports.push(Export {
                handle_offset,
                kind,
                project: u16_at(d, id_at),
                name_id: u16_at(d, id_at + 2),
                name: cstr(d, id_at + 4),
            });
        }

        // Modules.
        let mut modules = Vec::with_capacity(count);
        let mut at = module_at;
        for m in 0..count {
            if at + 0x3C > d.len() {
                return err(format!("{name}: module {m} runs past the file"));
            }
            let num_players = u8_at(d, at + 0x24);
            let num_controllers = u8_at(d, at + 0x27);
            let objects: Vec<u32> =
                (0..(num_players as usize + num_controllers as usize)).map(|i| u32_at(d, at + 0x3C + 4 * i)).collect();
            let mut module = Module {
                offset: at as u32,
                max_instances: i16_at(d, at + 0x1E),
                num_globals: u16_at(d, at + 0x20),
                num_functions: u16_at(d, at + 0x22),
                num_players,
                has_destructor: u8_at(d, at + 0x25) != 0,
                has_class_data: u8_at(d, at + 0x26) != 0,
                num_controllers,
                program_offset: u32_at(d, at + 0x28),
                template_offset: u32_at(d, at + 0x2C),
                data_size: u32_at(d, at + 0x30),
                destroy_offset: u32_at(d, at + 0x34),
                objects,
                program: Vec::new(),
                destructor_state: None,
                global_states: Vec::new(),
                class_data_state: None,
                function_states: Vec::new(),
            };
            // Checked: two file words can overflow u32 (a malformed bank must fail, not wrap).
            if module.template_offset.checked_add(module.data_size).is_none_or(|end| end as usize > d.len()) || module.data_size < 24 {
                return err(format!("{name}: module {m} template runs past the file"));
            }
            module.program = decode_program(name, d, module.program_offset as usize, module.data_size)?;
            layout_states(&mut module, d);
            at += 0x3C + 4 * module.objects.len();
            modules.push(module);
        }

        // Sample bank.
        let mut samples = Vec::new();
        let s = sample_bank as usize;
        if d.get(s..s + 4) == Some(b"S10A") {
            let capacity = u32_at(d, s + 8) as usize;
            for i in 0..capacity {
                let off = u32_at(d, s + 12 + 4 * i);
                if off == 0xFFFF_FFFF {
                    break;
                }
                let at = s as u32 + off;
                samples.push((at, SampleHeader::parse(d, at as usize)));
            }
        }
        Ok(Self { name: name.to_string(), data, modules, exports, sample_bank, samples })
    }
}

/// Decode a program and check the block walk: every opcode < 40 and the data pointer, starting at
/// instance +24, ends exactly at the template size.
fn decode_program(name: &str, d: &[u8], start: usize, data_size: u32) -> Result<Vec<Op>, FormatError> {
    let mut ops = Vec::new();
    let mut pc = start;
    let mut block: i64 = 24;
    loop {
        if pc + 4 > d.len() {
            return err(format!("{name}: program runs past the file"));
        }
        let opcode = u8_at(d, pc);
        if opcode == 255 {
            break;
        }
        if opcode >= OPCODES {
            return err(format!("{name}: opcode {opcode} at {pc:#x} (only 0..39 exist)"));
        }
        let npairs = u8_at(d, pc + 1) as usize;
        let pairs = (0..npairs).map(|p| (i32_at(d, pc + 4 + 8 * p), i32_at(d, pc + 8 + 8 * p))).collect();
        let advance = i32_at(d, pc + 4 + 8 * npairs);
        ops.push(Op { opcode, pairs, block: block as u32 });
        block += i64::from(advance);
        pc += 8 + 8 * npairs;
        if block < 0 || block > i64::from(data_size) {
            return err(format!("{name}: program data pointer leaves the template"));
        }
    }
    if block != i64::from(data_size) {
        return err(format!("{name}: program walk ends at {block}, template size {data_size}"));
    }
    Ok(ops)
}

/// Instance offsets of the subscription states (§1.4): ClassDestructor (20 B), GlobalVariables
/// (28 B each), ClassData ((n + 5)·4 B), Functions ((n + 7)·4 B each), from instance +24.
fn layout_states(m: &mut Module, d: &[u8]) {
    let t = m.template_offset as usize;
    let mut at = 24u32;
    if m.has_destructor {
        m.destructor_state = Some(at);
        at += 20;
    }
    for _ in 0..m.num_globals {
        m.global_states.push(at);
        at += 28;
    }
    if m.has_class_data {
        m.class_data_state = Some(at);
        at += (u32::from(u8_at(d, t + at as usize + 16)) + 5) * 4;
    }
    for _ in 0..m.num_functions {
        m.function_states.push(at);
        at += (u32::from(u8_at(d, t + at as usize + 24)) + 7) * 4;
    }
}
