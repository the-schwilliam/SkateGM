//! Streamed world speech (`data/audio/english/livingworldspeech.big`, `audio-specs/world-speech.md`).
//!
//! **Data.** The archive holds 3,011 clips named `<event>_<voice>[_<voice name>]_<line>.dat` plus
//! `livingworld_Events.evt` (the speech manager's event table, 84 named events such as `501_warn`)
//! and two EB v3 archives read at boot: `livingworldhdr.big` (one `.hdr` per clip: its take count
//! and the `.sth` row of each take) and `livingworldsth.big` (one `.sth` per clip: 12-byte rows =
//! the take's byte offset in the `.dat` + its 8-byte EA SNR header). Every take is mono EA-XMA2 at
//! 36 kHz; a clip holds 1–48 takes (20,096 in all, 14.3 h). Setup exports the index
//! (`tools/asset_pipeline/world_audio.py`); decoding the takes to PCM is opt-in (~2.4 GB for the
//! free-roam events).
//!
//! **Who speaks what.** Ped state graphs send a speech value (`SendSpeechEvent speechvalue=`), and
//! `SFXObj_PedestrianSpeech` hands it to the speech manager on change ([`super::peds::PedSpeech`]).
//! The manager maps it to an `.evt` event and gates it with the vault tuning
//! ([`super::speech_manager`]). The speech library then picks the line (an `.evt` record matching
//! the speaker's type, voice variant and near / far flag) and its takes ([`super::speech_rules`]).
//! Both are ported from the recomp. [`REACTION_CUES`] remains the measured reaction → event table
//! (`speech_reads.py`, sessions `all_20261002_161849` / `163809` / `164620`: the clip starts
//! 0.03 s after the reaction). [`choose`] is the old uniform pick, kept only for hosts without the
//! rules export.
use std::collections::HashMap;

use super::Draw;

/// One take of a clip (`.sth` row).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Take {
    /// Byte offset of the take in the clip's `.dat`, and its size.
    pub offset: u32,
    pub size: u32,
    pub rate: u32,
    pub samples: u32,
}

/// One `.dat` clip.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Clip {
    pub name: String,
    pub event: u32,
    pub voice: u32,
    /// The voice's name where the clip carries it (`busm1`, `torf1`, …).
    pub voice_name: Option<String>,
    pub line: String,
    pub takes: Vec<Take>,
}

/// Split a clip name (`501_59_busm1_Warn_n.dat` → 501, 59, Some("busm1"), "Warn_n").
pub fn parse_name(name: &str) -> Option<(u32, u32, Option<String>, String)> {
    let stem = name.strip_suffix(".dat").unwrap_or(name);
    let mut parts = stem.splitn(3, '_');
    let event = parts.next()?.parse().ok()?;
    let voice = parts.next()?.parse().ok()?;
    let rest = parts.next()?;
    // A voice name is lower-case letters followed by one digit (`busm1`, `grn2`, `sktf3`).
    if let Some((head, tail)) = rest.split_once('_') {
        let b = head.as_bytes();
        if b.len() >= 2 && b[..b.len() - 1].iter().all(u8::is_ascii_lowercase) && b[b.len() - 1].is_ascii_digit() {
            return Some((event, voice, Some(head.to_owned()), tail.to_owned()));
        }
    }
    Some((event, voice, None, rest.to_owned()))
}

/// The clip index of one speech archive.
#[derive(Clone, Debug, Default)]
pub struct SpeechIndex {
    pub clips: Vec<Clip>,
    by_event_voice: HashMap<(u32, u32), Vec<usize>>,
    /// `.hdr` id → clip (the `.evt` records name clips by id).
    by_id: HashMap<u16, usize>,
}

impl SpeechIndex {
    pub fn new(clips: Vec<Clip>) -> Self {
        let mut by_event_voice: HashMap<(u32, u32), Vec<usize>> = HashMap::new();
        for (i, c) in clips.iter().enumerate() {
            by_event_voice.entry((c.event, c.voice)).or_default().push(i);
        }
        Self { clips, by_event_voice, by_id: HashMap::new() }
    }

    /// Attach the clips' `.hdr` ids (`ids[i]` = clip `i`'s; the index export's `id`).
    pub fn set_ids(&mut self, ids: &[Option<u16>]) {
        self.by_id = ids.iter().enumerate().filter_map(|(i, id)| Some(((*id)?, i))).collect();
    }

    /// The clip with this `.hdr` id.
    pub fn clip_by_id(&self, id: u16) -> Option<usize> {
        self.by_id.get(&id).copied()
    }

    /// A chosen line's clips as [`Line`]s (for [`SpeechSlots`]).
    pub fn picks_to_lines(&self, picks: &[super::speech_rules::Pick], event: u32) -> Option<Vec<Line>> {
        picks.iter().map(|p| Some(Line { clip: self.clip_by_id(p.clip)?, take: usize::from(p.take), event })).collect()
    }

    /// The clips of one event in one voice.
    pub fn lines(&self, event: u32, voice: u32) -> &[usize] {
        self.by_event_voice.get(&(event, voice)).map_or(&[], Vec::as_slice)
    }

    /// Every voice id with at least one clip of `event`.
    pub fn voices_for(&self, event: u32) -> Vec<u32> {
        let mut v: Vec<u32> = self.by_event_voice.keys().filter(|k| k.0 == event).map(|k| k.1).collect();
        v.sort_unstable();
        v
    }
}

/// How sure we are that a cue's event follows its trigger.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Evidence {
    /// The recomp played the event's clips right after the trigger (0.03 s).
    Measured,
    /// The `.evt` event name matches the trigger; not seen in a trace.
    Name,
}

/// The mood results (`want` enum, image `0x820646BC`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Want {
    AngryChase = 1,
    Warn = 2,
    Taunt = 3,
    ReturnGreet = 4,
    Greet = 5,
    StartConversation = 6,
    AlertTo = 7,
    JoinChase = 8,
    ThrowHandProp = 9,
    Flee = 10,
    Startle = 11,
    Taze = 12,
    NearbyCollisionReaction = 13,
    SlamReaction = 14,
    StartSpectate = 15,
    NearbySkaterTrick = 16,
}

/// A speech event a trigger plays.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cue {
    pub event: u32,
    pub evidence: Evidence,
}

const fn m(event: u32) -> Cue {
    Cue { event, evidence: Evidence::Measured }
}
const fn n(event: u32) -> Cue {
    Cue { event, evidence: Evidence::Name }
}

/// Reaction → speech events (`audio-specs/world-speech.md` table; the recomp sessions above). Where a reaction
/// played several events the order is the measured frequency; the choice between them is the
/// `.evt`'s (not decoded).
pub const REACTION_CUES: &[(Want, &[Cue])] = &[
    // bump → warn: `501_<voice>_Warn_n`; the female warn + taze pair: `Warn_f`.
    (Want::Warn, &[m(501)]),
    (Want::Taze, &[m(501), n(330), n(331)]),
    // bump → flee: `108 ChsFlee` (session 164620), with `1901 Shout` / `201 grunt` around it.
    (Want::Flee, &[m(108)]),
    (Want::SlamReaction, &[m(104)]),
    (Want::NearbyCollisionReaction, &[m(205), m(204), m(202)]),
    (Want::NearbySkaterTrick, &[m(101)]),
    // The chaser's start line (`603 Strtchs` / `chase`) by name; bystanders' `105 SpecChs` measured.
    (Want::AngryChase, &[n(603), m(105)]),
    (Want::JoinChase, &[n(607)]),
    (Want::Greet, &[m(1901), m(806)]),
    (Want::ReturnGreet, &[m(807), m(1901)]),
    (Want::StartConversation, &[m(806), m(807)]),
    (Want::Taunt, &[n(400)]),
];

/// The cues of a reaction.
pub fn reaction_cues(want: Want) -> &'static [Cue] {
    REACTION_CUES.iter().find(|(w, _)| *w == want).map_or(&[], |(_, c)| c)
}

/// Retail's speech values as the state graphs send them (`SendSpeechEvent`; names from the
/// graphs, for logs and hooks). The value → `.evt` event step is the speech manager's.
pub const SPEECH_VALUES: &[(i32, &str)] = &[
    (1, "PedestrianWandering"),
    (2, "PedestrianIdle"),
    (3, "PedestrianWalk"),
    (4, "PedestrianAvoidJump"),
    (6, "PedestrianCollisionKnockdown"),
    (7, "PedestrianCollisionStanding"),
    (9, "PedestrianRecoveringFromCollision"),
    (10, "PedestrianCollisionNearbyReaction"),
    (11, "PedestrianDoWarning / PedstrianLostInterestEndChase"),
    (12, "PedestrianChaseResting"),
    (14, "PedestrianJoinChase"),
    (17, "PedestrianAttemptTakeDown"),
    (18, "PedestrianTakeDownFailure"),
    (19, "PedestrianTakeDownSuccess"),
    (20, "PedestrianFlee"),
    (22, "PedestrianRunFromHonker"),
    (23, "PedestrianLongCheer"),
    (25, "PedestrianStopCheer"),
    (29, "PictureTaking"),
    (63, "PedestrianUseATM"),
    (64, "PedestrianUseVendingMachine"),
    (65, "PedestrianBlock"),
    (66, "PedstrianEscapedEndChase"),
];

/// The state-graph name of a speech value.
pub fn speech_value_name(value: i32) -> Option<&'static str> {
    SPEECH_VALUES.iter().find(|(v, _)| *v == value).map(|(_, n)| *n)
}

/// One resolved line: the clip (index into [`SpeechIndex::clips`]) and its take.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Line {
    pub clip: usize,
    pub take: usize,
    pub event: u32,
}

/// Pick a line for a ped of `voice` from the first cue whose event the voice has: uniform over the
/// event's lines and the line's takes, never the same take twice in a row for one clip.
/// **Fallback only** (not retail): retail's choice is
/// [`super::speech_manager::SpeechManager::request`] with the `.evt` rules; use this only without the
/// rules export.
pub fn choose(index: &SpeechIndex, cues: &[Cue], voice: u32, last: &mut HashMap<usize, usize>, rng: &mut dyn Draw) -> Option<Line> {
    let cue = cues.iter().find(|c| !index.lines(c.event, voice).is_empty())?;
    let lines = index.lines(cue.event, voice);
    let clip = lines[rng.draw() as usize % lines.len()];
    let takes = index.clips[clip].takes.len();
    if takes == 0 {
        return None;
    }
    let mut take = rng.draw() as usize % takes;
    if takes > 1 && last.get(&clip) == Some(&take) {
        take = (take + 1) % takes;
    }
    last.insert(clip, take);
    Some(Line { clip, take, event: cue.event })
}

/// The mixer bank the decoded takes live in ([`crate::mixer::Mixer::add_bank`]; slot = the take's
/// running number over the index, [`SpeechSlots`]).
pub const SPEECH_BANK: usize = 1 << 22;
/// The main cast's takes (`maincastspeech.big`), slots as in [`SPEECH_BANK`] over its own index.
pub const MAIN_CAST_BANK: usize = SPEECH_BANK + 1;
/// The announcer's takes (`announcerspeech.big`), slots over its own index.
pub const ANNOUNCER_BANK: usize = SPEECH_BANK + 2;

/// (clip, take) → mixer slot of [`SPEECH_BANK`].
#[derive(Clone, Debug, Default)]
pub struct SpeechSlots {
    first: Vec<u32>,
}

impl SpeechSlots {
    pub fn new(index: &SpeechIndex) -> Self {
        let mut first = Vec::with_capacity(index.clips.len());
        let mut at = 0u32;
        for c in &index.clips {
            first.push(at);
            at += c.takes.len() as u32;
        }
        Self { first }
    }

    pub fn slot(&self, line: Line) -> Option<u16> {
        u16::try_from(*self.first.get(line.clip)? as usize + line.take).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clip(name: &str, takes: usize) -> Clip {
        let (event, voice, voice_name, line) = parse_name(name).unwrap();
        Clip { name: name.into(), event, voice, voice_name, line, takes: vec![Take { offset: 0, size: 1, rate: 36000, samples: 1 }; takes] }
    }

    #[test]
    fn names_split_into_event_voice_and_line() {
        assert_eq!(parse_name("501_59_busm1_Warn_n.dat"), Some((501, 59, Some("busm1".into()), "Warn_n".into())));
        assert_eq!(parse_name("1901_53_Shout.dat"), Some((1901, 53, None, "Shout".into())));
        assert_eq!(parse_name("806_47_adtf2_Int_c14_tour.dat"), Some((806, 47, Some("adtf2".into()), "Int_c14_tour".into())));
        assert_eq!(parse_name("101_53_GenPos_Grn1_far.dat"), Some((101, 53, None, "GenPos_Grn1_far".into())));
        assert_eq!(parse_name("livingworld_Events.evt"), None);
    }

    #[test]
    fn a_reaction_picks_a_line_of_the_peds_voice() {
        let index = SpeechIndex::new(vec![clip("501_59_busm1_Warn_n.dat", 3), clip("501_59_busm1_Warn_f.dat", 2), clip("104_59_busm1_Slam_n.dat", 4), clip("501_60_busm2_Warn_n.dat", 1)]);
        let mut last = HashMap::new();
        let mut n = 0u32;
        let mut rng = move || {
            n += 1;
            n
        };
        let line = choose(&index, reaction_cues(Want::Warn), 59, &mut last, &mut rng).unwrap();
        assert_eq!(line.event, 501);
        assert!(index.lines(501, 59).contains(&line.clip));
        assert!(choose(&index, reaction_cues(Want::Flee), 59, &mut last, &mut rng).is_none(), "voice 59 has no flee line");
        let slots = SpeechSlots::new(&index);
        assert_eq!(slots.slot(Line { clip: 2, take: 1, event: 104 }), Some(6));
        assert_eq!(index.voices_for(501), vec![59, 60]);
    }

    #[test]
    fn takes_do_not_repeat_back_to_back() {
        let index = SpeechIndex::new(vec![clip("204_53_Gasp.dat", 2)]);
        let mut last = HashMap::new();
        let mut rng = || 0u32;
        let a = choose(&index, &[m(204)], 53, &mut last, &mut rng).unwrap();
        let b = choose(&index, &[m(204)], 53, &mut last, &mut rng).unwrap();
        assert_ne!(a.take, b.take);
    }
}
