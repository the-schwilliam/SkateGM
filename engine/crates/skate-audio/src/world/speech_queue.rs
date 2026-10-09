//! TU3 library request selection82971890, separate from per-event interrupt tuning.
#[derive(Clone, Copy, Debug)]
pub struct Candidate {
    pub active: bool,
    pub channel: u8,
    pub timeout: u16,
    pub priority: u16,
    pub age: u32,
    pub sequence: u16,
}
/// Expiration is tested only for the requested channel. Timeout zero never expires.
pub fn select(candidates: &mut [Candidate], channel: u8) -> Option<usize> {
    let mut best = None;
    let (mut priority, mut age, mut sequence) = (0u16, u32::MAX, 0u16);
    for (i, c) in candidates.iter_mut().enumerate() {
        if !c.active || c.channel != channel {
            continue;
        }
        if c.timeout != 0 && c.age > u32::from(c.timeout) {
            c.active = false;
            continue;
        }
        if c.priority > priority
            || (c.priority == priority && (c.age < age || (c.age == age && c.sequence > sequence)))
        {
            best = Some(i);
            priority = c.priority;
            age = c.age;
            sequence = c.sequence;
        }
    }
    best
}

/// Native82971340 admission: first free slot, then first expired slot, then first
/// same-channel slot whose priority does not exceed the incoming priority.
/// `age` here is measured from the queue callback clock, before any clock offset.
pub fn admission(candidates: &mut [Candidate], channel: u8, priority: u16) -> Option<usize> {
    if let Some(i) = candidates.iter().position(|c| !c.active) {
        return Some(i);
    }
    if let Some(i) = candidates
        .iter()
        .position(|c| c.timeout != 0 && c.age > u32::from(c.timeout))
    {
        candidates[i].active = false;
        return Some(i);
    }
    let i = candidates
        .iter()
        .position(|c| c.channel == channel && c.priority <= priority)?;
    candidates[i].active = false;
    Some(i)
}

/// Native82971DA8 removes older same-channel requests when a line starts, except
/// events carrying flags2 bit2 (value4). Native compares absolute unsigned ticks.
pub fn consumed(candidates: &mut [Candidate], selected: usize, tick: u32, retain: &[bool]) {
    let chosen = candidates[selected];
    let started = tick.wrapping_sub(chosen.age);
    for (i, c) in candidates.iter_mut().enumerate() {
        if !c.active || c.channel != chosen.channel || i == selected {
            continue;
        }
        let enqueued = tick.wrapping_sub(c.age);
        if (enqueued < started || (enqueued == started && c.sequence < chosen.sequence))
            && !retain[i]
        {
            c.active = false;
        }
    }
    candidates[selected].active = false;
}

/// `824A62F0`: channel0 considers both streams; other channels consider stream0.
pub fn channel_available(channel: u8, active: [bool; 2], paused: [bool; 2]) -> bool {
    let busy = |k: usize| active[k] && !paused[k];
    !busy(0) || (channel == 0 && !busy(1))
}

/// `824A73F0`: the caller supplies the speaker's stream index and whether it is
/// already speaking. The no-stream sentinel2 targets stream0, never the weakest stream.
pub fn interrupt_target(
    target: u32,
    force: bool,
    interrupt: bool,
    when_full: bool,
    incoming_priority: i32,
    active: [bool; 2],
    priorities: [i32; 2],
    available: bool,
) -> Option<usize> {
    assert!(
        target <= 2,
        "speaker stream must be0,1 or the native sentinel2"
    );
    let k = if target == 2 { 0 } else { target as usize };
    (active[k]
        && priorities[k] < incoming_priority
        && ((force && interrupt) || (!available && when_full)))
        .then_some(k)
}
