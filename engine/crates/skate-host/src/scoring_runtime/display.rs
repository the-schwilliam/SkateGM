//! Skate 3 TU3 825E51A0 / 825C2700 / 82DA4EE8.
use skate_data::scoring::{Definition, ScoringData};

pub(super) fn nollie(d: &Definition) -> bool {
    matches!(d.metadata.score_type, 1 | 2) && d.identifier.starts_with('n')
}
pub(super) fn compose(
    data: &ScoringData,
    id: Option<usize>,
    turns: i32,
    body_flip: i32,
    switch: bool,
    fakie: bool,
    regular: bool,
) -> (String, [bool; 4]) {
    let original = id.and_then(|id| data.by_id(id));
    let mut d = original;
    let mut stance = [switch, fakie, true, original.is_some_and(nollie)];
    let eligible = d.is_none_or(|d| {
        matches!(d.trick_type, 1 | 2 | 3 | 7 | 10 | 12 | 13)
            || d.trick_type == 4 && d.metadata.id != 60
    });
    if let Some(variant) = d
        .filter(|d| nollie(d) && d.variant >= 0 && switch != fakie)
        .and_then(|d| data.by_id(d.variant as usize))
    {
        d = Some(variant);
        stance[0] = fakie;
        stance[1] = switch;
    }
    let cab = eligible && fakie && !switch && !d.is_some_and(nollie) && turns != 0;
    let cab_label = if turns.abs() == 1 {
        if turns > 0 {
            "ID_TRICK_AUTHENTIC_FS_HALFCAB"
        } else {
            "ID_TRICK_AUTHENTIC_BS_HALFCAB"
        }
    } else if turns > 0 {
        "ID_TRICK_AUTHENTIC_FS_CAB"
    } else {
        "ID_TRICK_AUTHENTIC_BS_CAB"
    };
    let mut name = d.map(|d| d.label.clone()).unwrap_or_else(|| {
        if cab {
            cab_label.to_owned()
        } else if turns == 0 {
            "ID_TRICK_AIR".to_owned()
        } else if (turns < 0) ^ switch ^ !regular {
            "ID_TRICK_AIR_FS_SPIN".to_owned()
        } else {
            "ID_TRICK_AIR_BS_SPIN".to_owned()
        }
    });
    // 825E51A0: the authored Christ Air (252) becomes Miracle Whip.
    let miracle_whip = id == Some(252) && body_flip != 0;
    if miracle_whip {
        name = "ID_TRICK_GRAB_MIRACLE_WHIP".to_owned();
    }
    if cab {
        if d.is_some() {
            name.push(' ');
            name.push_str(cab_label);
        }
        stance[1] = false;
    }
    if eligible && turns != 0 && !(cab && turns.abs() == 1) {
        name.push_str(&format!(" {}", turns.abs() * 180));
    }
    if body_flip != 0 && !miracle_whip {
        name.push(' ');
        name.push_str(if body_flip > 0 {
            "ID_TRICK_AIR_METRICS_FRONTFLIP"
        } else {
            "ID_TRICK_AIR_METRICS_BACKFLIP"
        });
    }
    (name, stance)
}
