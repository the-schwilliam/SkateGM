//! The announcer channel (`announcerspeech.big`, speech manager bank 3, speech channel 3): the
//! contest commentator's lines (`480_slam_pro`, `422_slam`, `443_pos_trk`, the results …). Read from
//! the TU3 recompilation (reference only; addresses are facts; spec `audio-specs/world-speech.md`
//! "The announcer channel"):
//!
//! - **Who speaks.** Two announcer characters, models 35 and 36 (`aud_characteristics`
//!   `SPCH3Type_char_ID_Ann` = 1 / 2: the first field of every announcer record). The running
//!   challenge names one (system `+1036`, written when the challenge record changes,
//!   `sub_82488330`); without a challenge it is 104 = nobody. [`Context`].
//! - **The request** (`sub_824AA858`): the event's vault tuning (bank 3), the shared game-state
//!   gate (record `+48`, as the main cast's), then — when the caller left word 0 empty and a
//!   character is named — word 0 = that character's announcer id; word 8 = 5 or 6 (system
//!   `+1089`); the manager's timers are kept for the character (104 → 35); the gate
//!   ([`super::speech_manager::SpeechManager::gate`], one `rand()` for the probability); the
//!   interrupt on channel 3; the library request with [`request_words`] (`sub_824AAC40`).
//!   **Without a challenge word 0 stays 0, so no record matches** (every record wants 1 or 2):
//!   free skate never plays an announcer line, though a pro's crash still asks (and draws).
//!   38 recorded free-roam sessions read nothing from `announcerspeech.big` but its index.
//! - **Senders.** 39 calls in the game: SFXObj_Announcer's challenge commentary (`sub_824CF350`,
//!   which does nothing unless the character is 35 / 36), the contest results (`sub_8248C988`), the
//!   trick / grind / bail / big-air commentary of the challenge modes, the scripts'
//!   `PlayAnnouncerSpeech`, and the one that runs in free skate: an NPC skater's crash
//!   (`sub_824DB688`, `SFXObj_PlayerSpeech`'s non-local process): when the skater's camera
//!   distance is below the speech record's `887C1D3324B12C4A` (12 m), [`SLAM_PRO`] with word 2 =
//!   the model's `SPCH3Type_pro_id_ANN` (`14B23B4527AF919E`; pros only, 0 = no request).
//! - **The voice** (stream system block `mgr+0x1B898`, refreshed every frame from SFXObj_Announcer
//!   `sub_824D07B8` by `sub_824A7FA0`'s neighbour): level = the Announcer MixMap object's out2 ×
//!   [`AnnouncerLevel::scale`] (truncated to an integer), pitch out1, azimuth out0 (the MixMap
//!   writes none: centre), high pass out4, low pass out3, the environment send out5; the block's
//!   voice float 1.0, PEAK gain 1.0 (flat), no echo send (`sub_824A3C28`'s constants).
//!   `speech_player::announcer_outputs`.
//! - **The duck.** SFXObj_Announcer (`sub_824CF218`) sets `Announcer.in0` = 32767 while the stream
//!   system plays an announcer line (`sub_824A61C0`): the Global's F2 / F37 / F47 / F50 / F95 / F172
//!   / F241 duck the mix and F208 / F209 / F212 the reverb.
use super::Draw;
use super::speech_manager::{EventTuning, GateInputs, Line, Refusal, SpeechManager};
use super::speech_rules::{EventTable, Library};

/// The speech channel (stream records 6 / 7).
pub const CHANNEL: u8 = 3;
/// The speech bank the announcer's events live in (`id >> 13`).
pub const BANK: u32 = 3;
/// System `+1036` without a challenge.
pub const NO_CHARACTER: u32 = 104;
/// The manager's timer slot when no character is named (`sub_824AA858`: 104 → 35).
pub const DEFAULT_SLOT: u32 = 35;
/// `480_slam_pro`: a pro's crash near the camera.
pub const SLAM_PRO: u16 = 24708;
/// The speech record's crash distance (`887C1D3324B12C4A`, m): shipped value.
pub const CRASH_DISTANCE: f32 = 12.0;
/// Request block words (`sub_824AAC40` reads up to word 32).
pub const BLOCK: usize = 33;
pub type Block = [u32; BLOCK];

/// `sub_824AAC40`: the words an announcer event's library request carries, in field order (the
/// block's word indices; every other event reads word 0 only).
pub fn request_words(event: u16, w: &Block) -> Vec<u32> {
    let idx: &[usize] = match event {
        24576 | 24587 => &[0, 7],
        24580 => &[0, 2, 8, 11],
        24582 => &[0, 3, 8],
        24584 => &[0, 5],
        24585 => &[0, 6, 8],
        24632 => &[0, 2, 11, 32, 7],
        24640 => &[0, 9],
        24647 | 24694 => &[0, 1, 10],
        24674 | 24675 => &[0, 15],
        24676 => &[0, 13],
        24677 | 24698 => &[0, 6],
        24683 => &[0, 16],
        24684 => &[0, 17],
        24685 => &[0, 18],
        24686 | 24696 => &[0, 19],
        24688 | 24697 => &[0, 20],
        24704 | 24706 => &[0, 23],
        24708 | 24710 => &[0, 2, 11],
        24709 => &[0, 25],
        24711 => &[0, 24],
        24712 => &[0, 26],
        24713 => &[0, 22],
        24728 => &[0, 11],
        24748 => &[0, 2, 11, 31],
        24749 => &[0, 31],
        24751 => &[0, 31, 7],
        _ => &[0],
    };
    idx.iter().map(|&i| w[i]).collect()
}

/// The game state an announcer request reads.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Context {
    /// System `+1036`: the running challenge's announcer character (model 35 / 36). None = no
    /// challenge (104): free skate.
    pub character: Option<u32>,
    /// That character's `SPCH3Type_char_ID_Ann` (`aud_characteristics` `6F9C8A27E4CD37DC`): 1 for
    /// model 35, 2 for 36 (setup `world_tuning.ped_models[..].announcer_id`).
    pub character_word: u32,
    /// System `+1089` (set from the challenge record; meaning not traced): word 8 = 6 when set, else 5.
    pub flag_1089: bool,
    /// System `+1044` (the challenge record's byte): picks the challenge scale of
    /// [`AnnouncerLevel`].
    pub challenge_flag: bool,
}

impl Context {
    /// The speaker slot the manager keeps the timers for.
    pub fn slot(&self) -> u32 {
        match self.character {
            Some(c) if c != NO_CHARACTER => c,
            _ => DEFAULT_SLOT,
        }
    }

    /// `sub_824AA858`'s block edits: word 0 from the character when the caller left it 0 (and a
    /// character below 104 is named), word 8 from `+1089`.
    pub fn fill(&self, block: &mut Block) {
        if block[0] == 0 && self.character.is_some_and(|c| c < NO_CHARACTER) {
            block[0] = self.character_word;
        }
        block[8] = 4 | (1 + u32::from(self.flag_1089));
    }
}

/// The announcer level multiplier (`sub_824A8250`, speech record holder `*(0x830CFDA4)+44`): one
/// 3-entry array per console language group and the challenge byte `+1044`, indexed by the line's
/// speaker (its clip name's voice: 36 → 1, 31 → 2, else 0). The language global (`0x82FDE288`,
/// `sub_82D08010`): French 1, German 2, everything else (English: this disc) 0 → the `other`
/// arrays (`49AE841BE63F9EB7` / `60E0221FD3D6F04B`). Defaults = the shipped English values.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AnnouncerLevel {
    pub scale: [f32; 3],
    pub scale_challenge: [f32; 3],
    /// The crash request's camera distance (m).
    pub crash_distance: f32,
}

impl Default for AnnouncerLevel {
    fn default() -> Self {
        Self { scale: [1.1, 1.25, 1.1], scale_challenge: [0.9, 1.0, 1.0], crash_distance: CRASH_DISTANCE }
    }
}

impl AnnouncerLevel {
    pub fn scale(&self, speaker_voice: u32, challenge_flag: bool) -> f32 {
        let i = match speaker_voice {
            36 => 1,
            31 => 2,
            _ => 0,
        };
        if challenge_flag { self.scale_challenge[i] } else { self.scale[i] }
    }
}

/// The request block of the crash (`sub_824DB688`): word 2 = the crashing model's announcer pro
/// id; None when it has none (no request).
pub fn crash_block(pro_id: u32) -> Option<Block> {
    (pro_id != 0).then(|| {
        let mut b = [0; BLOCK];
        b[2] = pro_id;
        b
    })
}

impl SpeechManager {
    /// An announcer request (`sub_824AA858`). This manager must hold the announcer's tuning
    /// (`speech_tuning["3"]`). The gate draws `rng` as retail's does, also when the library then
    /// finds no record (free skate: no character, word 0 = 0).
    #[allow(clippy::too_many_arguments)]
    pub fn request_announcer(
        &mut self,
        library: &mut Library,
        table: &EventTable,
        event: u16,
        context: &Context,
        block: &Block,
        inputs: &GateInputs,
        rng: &mut dyn Draw,
    ) -> Result<Line, Refusal> {
        let mut block = *block;
        context.fill(&mut block);
        let slot = context.slot();
        let default = EventTuning::default();
        let tuning = self.tuning.get(&event).unwrap_or(&default);
        self.gate(slot, event, tuning, inputs, rng)?;
        let words = request_words(event, &block);
        let picks = library.start(table, event, &words).map_err(Refusal::Library)?;
        self.started(slot, event, inputs.now);
        Ok(Line { event, picks })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::world::speech_rules::{ClipHeader, ClipRef, Event, NoLine, Record};

    fn slam_pro_table() -> (EventTable, Library) {
        let rec = |ann, pro, clip| Record { weight_code: 0x39, probability: 100, mode: 0, locals: 0, values: vec![ann, pro, 0], clips: vec![ClipRef { id: clip, lookup: 0, params: 0 }] };
        let ev = Event {
            id: SLAM_PRO,
            name: "480_slam_pro".into(),
            queue_timeout: 30,
            priority: 620,
            conditions: 0,
            flags: 0x30,
            probability: 100,
            flags2: 0,
            fields: vec![1, 2, 3],
            // 480_35_slam_pro_Dway (danny_way 0x8) / 480_36_slam_pro_Cole (chris_cole 0x2).
            records: vec![rec(1, 0x8, 0x40), rec(2, 0x2, 0x41)],
        };
        let headers = vec![ClipHeader { id: 0x40, takes: 5, history: 5, flags: 0 }, ClipHeader { id: 0x41, takes: 4, history: 4, flags: 0 }];
        (EventTable { bank: 3, sub_bank: 0, events: vec![ev] }, Library::new(headers))
    }

    #[test]
    fn events_read_their_own_words() {
        let mut w = [0u32; BLOCK];
        for (i, v) in w.iter_mut().enumerate() {
            *v = i as u32 * 10;
        }
        assert_eq!(request_words(SLAM_PRO, &w), vec![0, 20, 110]);
        assert_eq!(request_words(24632, &w), vec![0, 20, 110, 320, 70], "426_results");
        assert_eq!(request_words(24585, &w), vec![0, 60, 80], "422_slam reads word 8");
        assert_eq!(request_words(24703, &w), vec![0], "475_BigAir_A: the announcer only");
    }

    #[test]
    fn the_block_takes_the_character_and_word_8() {
        let mut b = [0; BLOCK];
        Context { character: Some(36), character_word: 2, flag_1089: false, challenge_flag: false }.fill(&mut b);
        assert_eq!((b[0], b[8]), (2, 5));
        let mut b = [0; BLOCK];
        b[0] = 1;
        Context { character: Some(36), character_word: 2, flag_1089: true, challenge_flag: false }.fill(&mut b);
        assert_eq!((b[0], b[8]), (1, 6), "a caller's word 0 stays");
        let mut b = [0; BLOCK];
        Context::default().fill(&mut b);
        assert_eq!(b[0], 0, "no challenge: nobody");
        assert_eq!((Context::default().slot(), Context { character: Some(36), ..Default::default() }.slot()), (35, 36));
    }

    #[test]
    fn free_skate_asks_draws_and_finds_no_line() {
        let (table, mut lib) = slam_pro_table();
        let tuning = EventTuning { repeat: 15.0, priority: 90, ..Default::default() };
        let mut m = SpeechManager::new(std::collections::HashMap::from([(SLAM_PRO, tuning)]));
        let draws = std::cell::Cell::new(0);
        let mut rng = || {
            draws.set(draws.get() + 1);
            0u32
        };
        let inputs = GateInputs { now: 100.0, ..Default::default() };
        let block = crash_block(0x8).unwrap();
        assert_eq!(m.request_announcer(&mut lib, &table, SLAM_PRO, &Context::default(), &block, &inputs, &mut rng), Err(Refusal::Library(NoLine::NoRecord)));
        assert_eq!(draws.get(), 1, "the probability draw happens before the library");
        // Nothing started: the next crash asks again at once.
        assert_eq!(m.request_announcer(&mut lib, &table, SLAM_PRO, &Context::default(), &block, &inputs, &mut rng), Err(Refusal::Library(NoLine::NoRecord)));
        assert!(crash_block(0).is_none(), "no pro id: no request");
    }

    #[test]
    fn a_challenge_announcer_names_the_crashing_pro() {
        let (table, mut lib) = slam_pro_table();
        let mut m = SpeechManager::new(std::collections::HashMap::from([(SLAM_PRO, EventTuning { repeat: 15.0, ..Default::default() })]));
        let mut rng = || 0u32;
        let at = |now| GateInputs { now, ..Default::default() };
        let first = Context { character: Some(35), character_word: 1, ..Default::default() };
        let line = m.request_announcer(&mut lib, &table, SLAM_PRO, &first, &crash_block(0x8).unwrap(), &at(20.0), &mut rng).unwrap();
        assert_eq!(line.picks[0].clip, 0x40, "announcer 1 on danny_way");
        assert_eq!(m.request_announcer(&mut lib, &table, SLAM_PRO, &first, &crash_block(0x8).unwrap(), &at(30.0), &mut rng), Err(Refusal::Repeat), "the character's timer");
        let second = Context { character: Some(36), character_word: 2, ..Default::default() };
        let line = m.request_announcer(&mut lib, &table, SLAM_PRO, &second, &crash_block(0x2).unwrap(), &at(30.0), &mut rng).unwrap();
        assert_eq!(line.picks[0].clip, 0x41, "announcer 2 keeps its own timers");
        assert_eq!(m.request_announcer(&mut lib, &table, SLAM_PRO, &second, &crash_block(0x8).unwrap(), &at(60.0), &mut rng), Err(Refusal::Library(NoLine::NoRecord)), "announcer 2 has no danny_way line here");
    }

    #[test]
    fn the_level_scale_follows_the_speaker_and_the_challenge_byte() {
        let l = AnnouncerLevel::default();
        assert_eq!((l.scale(35, false), l.scale(36, false), l.scale(31, false)), (1.1, 1.25, 1.1));
        assert_eq!((l.scale(35, true), l.scale(36, true)), (0.9, 1.0));
    }
}
