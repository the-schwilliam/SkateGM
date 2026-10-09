//! Installed Csis projects and their run-time symbol records (spec §1.8, §2.7).
//!
//! Each Function, Class and GlobalVariable becomes one record with its client list. Lookup follows
//! retail: pass 1 scans projects whose id matches the reference's project id, pass 2 every
//! project; newest project first; a hit needs an equal name id and an equal name.
use crate::formats::Project;
use crate::formats::abk::InterfaceKind;

/// A resolved symbol.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SymRef {
    Function(usize),
    Class(usize),
    Global(usize),
}

/// A subscription: (instance id, state offset in the instance).
pub type Client = (u32, u32);

#[derive(Clone, Debug)]
pub struct FunctionRec {
    pub name: String,
    pub subscribers: Vec<Client>,
}

#[derive(Clone, Debug)]
pub struct ClassRec {
    pub name: String,
    /// Constructor clients (bank index, module index) in install order; posts call them newest
    /// first.
    pub constructors: Vec<(usize, usize)>,
}

#[derive(Clone, Debug)]
pub struct GlobalRec {
    pub name: String,
    pub value: i32,
    pub subscribers: Vec<Client>,
}

struct Installed {
    id: u16,
    /// The install's token ([`Registry::install`]), for [`Registry::uninstall`].
    token: u64,
    /// Per table: (name id, name, record index).
    tables: [Vec<(u16, String, usize)>; 3],
}

#[derive(Default)]
pub struct Registry {
    /// Install order (lookup walks it newest first).
    projects: Vec<Installed>,
    pub functions: Vec<FunctionRec>,
    pub classes: Vec<ClassRec>,
    pub globals: Vec<GlobalRec>,
    installs: u64,
}

impl Registry {
    /// Install a project (newest first in lookups). Returns its token for [`Registry::uninstall`].
    pub fn install(&mut self, project: &Project) -> u64 {
        let mut tables: [Vec<(u16, String, usize)>; 3] = Default::default();
        for s in &project.tables[0] {
            tables[0].push((s.name_id, s.name.clone(), self.functions.len()));
            self.functions.push(FunctionRec { name: s.name.clone(), subscribers: Vec::new() });
        }
        for s in &project.tables[1] {
            tables[1].push((s.name_id, s.name.clone(), self.classes.len()));
            self.classes.push(ClassRec { name: s.name.clone(), constructors: Vec::new() });
        }
        for s in &project.tables[2] {
            tables[2].push((s.name_id, s.name.clone(), self.globals.len()));
            self.globals.push(GlobalRec { name: s.name.clone(), value: s.default, subscribers: Vec::new() });
        }
        self.installs += 1;
        self.projects.push(Installed { id: project.id, token: self.installs, tables });
        self.installs
    }

    /// The record indices (functions, classes, globals) an installed project holds.
    pub fn records_of(&self, token: u64) -> Option<[Vec<usize>; 3]> {
        let p = self.projects.iter().find(|p| p.token == token)?;
        Some(std::array::from_fn(|t| p.tables[t].iter().map(|e| e.2).collect()))
    }

    /// Take an installed project out of the lookups (an audio content hot swap: a mod's project
    /// goes): no reference resolves to its symbols and no game-side name finds them any more, so
    /// every lookup answers as if it had never been installed. Its records stay (ids are indices)
    /// but are emptied: the host unloads or replaces the banks bound to them first. Returns the
    /// record ranges it held (functions, classes, globals) or None for an unknown token.
    pub fn uninstall(&mut self, token: u64) -> Option<[Vec<usize>; 3]> {
        let at = self.projects.iter().position(|p| p.token == token)?;
        let p = self.projects.remove(at);
        let ids: [Vec<usize>; 3] = std::array::from_fn(|t| p.tables[t].iter().map(|e| e.2).collect());
        for &f in &ids[0] {
            self.functions[f].subscribers.clear();
        }
        for &c in &ids[1] {
            self.classes[c].constructors.clear();
        }
        for &g in &ids[2] {
            self.globals[g].subscribers.clear();
        }
        Some(ids)
    }

    /// Resolve an interface reference; None = retail's −5 (not found).
    pub fn lookup(&self, kind: InterfaceKind, project: u16, name_id: u16, name: &str) -> Option<SymRef> {
        let t = kind.table();
        let find = |p: &Installed| p.tables[t].iter().find(|(id, n, _)| *id == name_id && n == name).map(|e| e.2);
        let hit = self
            .projects
            .iter()
            .rev()
            .filter(|p| p.id == project)
            .find_map(find)
            .or_else(|| self.projects.iter().rev().find_map(find))?;
        Some(match kind {
            InterfaceKind::Function => SymRef::Function(hit),
            InterfaceKind::Class => SymRef::Class(hit),
            InterfaceKind::GlobalVariable => SymRef::Global(hit),
        })
    }

    /// First record with this name in a table (newest project first), for game-side posting.
    pub fn by_name(&self, kind: InterfaceKind, name: &str) -> Option<usize> {
        let t = kind.table();
        self.projects.iter().rev().find_map(|p| p.tables[t].iter().find(|e| e.1 == name).map(|e| e.2))
    }
}
