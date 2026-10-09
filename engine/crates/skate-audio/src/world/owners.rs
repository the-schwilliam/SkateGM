//! The world owners' MixMap instances: a fixed pool per slot (retail builds the MixMap with 4
//! Traffic and 15 Pedestrian instances in free skate) and the 3DObjPos blocks each instance's B
//! lookups read.
//!
//! **Assignment rule — provisional.** Which game objects get an instance is decided by retail's
//! SFX object manager, not traced yet (`audio-specs/world-traffic-audio.md` "Open"). Until it is, [`Pool::assign`]
//! keeps the nearest N candidates by listener distance, and an owner that holds an instance keeps
//! it while it stays among the nearest N (no reshuffling between frames). Every Traffic B lookup
//! ends by 90 m (B7) and the vehicle census culls at 110 m, so the nearest four are the audible
//! ones; the rule is the host-side seam to replace once the manager is read.
use crate::mixmap::MixMap;
use crate::player::objpos::{Listener, ObjPos};

/// One owner's instance changes from [`Pool::assign`].
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Assignment {
    /// (owner, instance) that lost their instance: release their packets, deactivate the blocks.
    pub released: Vec<(u64, usize)>,
    /// (owner, instance) newly given one.
    pub claimed: Vec<(u64, usize)>,
}

#[derive(Clone, Debug)]
pub struct Pool {
    slots: Vec<Option<u64>>,
}

impl Pool {
    pub fn new(instances: usize) -> Self {
        Self { slots: vec![None; instances] }
    }

    pub fn len(&self) -> usize {
        self.slots.len()
    }

    pub fn is_empty(&self) -> bool {
        self.slots.is_empty()
    }

    /// The instance an owner holds.
    pub fn instance(&self, owner: u64) -> Option<usize> {
        self.slots.iter().position(|s| *s == Some(owner))
    }

    /// Owners holding an instance, by instance.
    pub fn holders(&self) -> impl Iterator<Item = (usize, u64)> + '_ {
        self.slots.iter().enumerate().filter_map(|(g, s)| s.map(|o| (g, o)))
    }

    /// Give the nearest `len()` candidates (owner, distance) an instance; see the module docs.
    /// Candidates with a non-finite distance never get one.
    pub fn assign(&mut self, candidates: &[(u64, f32)]) -> Assignment {
        let mut sorted: Vec<(u64, f32)> = candidates.iter().copied().filter(|c| c.1.is_finite()).collect();
        // Nearest first; ties by owner id so the result does not depend on the input order.
        sorted.sort_by(|a, b| a.1.total_cmp(&b.1).then(a.0.cmp(&b.0)));
        sorted.dedup_by_key(|c| c.0);
        let wanted: Vec<u64> = sorted.iter().take(self.slots.len()).map(|c| c.0).collect();
        let mut out = Assignment::default();
        for (g, slot) in self.slots.iter_mut().enumerate() {
            if let Some(owner) = *slot {
                if !wanted.contains(&owner) {
                    out.released.push((owner, g));
                    *slot = None;
                }
            }
        }
        for owner in wanted {
            if self.instance(owner).is_some() {
                continue;
            }
            if let Some(g) = self.slots.iter().position(Option::is_none) {
                self.slots[g] = Some(owner);
                out.claimed.push((owner, g));
            }
        }
        out
    }

    /// Release every instance (map change).
    pub fn clear(&mut self) -> Vec<(u64, usize)> {
        let out = self.holders().map(|(g, o)| (o, g)).collect();
        self.slots.iter_mut().for_each(|s| *s = None);
        out
    }
}

/// An instance's 3DObjPos blocks (one per key), written once per frame before the tick.
#[derive(Clone, Debug, Default)]
pub struct Positions {
    blocks: Vec<(u32, ObjPos)>,
}

impl Positions {
    pub fn new(keys: &[u32]) -> Self {
        Self { blocks: keys.iter().map(|&k| (k, ObjPos::default())).collect() }
    }

    /// Write every block: `points[i]` = (position, velocity) of block i, `None` = inactive.
    pub fn write(&mut self, m: &mut MixMap, l: &Listener, points: &[Option<([f32; 3], [f32; 3])>]) {
        for (i, (key, pos)) in self.blocks.iter_mut().enumerate() {
            pos.write(m, *key, l, points.get(i).copied().flatten());
        }
    }

    /// Deactivate every block (the owner lost its instance).
    pub fn deactivate(&mut self, m: &mut MixMap, l: &Listener) {
        for (key, pos) in &mut self.blocks {
            pos.write(m, *key, l, None);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nearest_owners_get_instances_and_keep_them() {
        let mut p = Pool::new(2);
        let a = p.assign(&[(1, 30.0), (2, 10.0), (3, 20.0)]);
        assert_eq!(a.claimed, vec![(2, 0), (3, 1)]);
        assert!(a.released.is_empty());
        // 1 comes closer than 3: 3 is released, 1 takes its instance; 2 keeps instance 0.
        let a = p.assign(&[(1, 5.0), (2, 10.0), (3, 20.0)]);
        assert_eq!(a.released, vec![(3, 1)]);
        assert_eq!(a.claimed, vec![(1, 1)]);
        assert_eq!(p.instance(2), Some(0));
        // Nobody left.
        let a = p.assign(&[]);
        assert_eq!(a.released.len(), 2);
        assert_eq!(p.holders().count(), 0);
    }

    #[test]
    fn non_finite_distances_and_duplicates_are_ignored() {
        let mut p = Pool::new(3);
        let a = p.assign(&[(1, f32::NAN), (2, 1.0), (2, 2.0), (3, f32::INFINITY)]);
        assert_eq!(a.claimed, vec![(2, 0)]);
    }
}
