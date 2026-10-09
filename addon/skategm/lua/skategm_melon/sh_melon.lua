-- Melon King, shared: limits and message names.
--
-- How a game runs (the server decides, every client follows its state):
--   lobby     the host set it up: a play area around where they stood, and
--             the start; players join (joining switches you into Skater mode)
--   countdown everyone in Skater mode is put on the start, 3, 2, 1
--   playing   a watermelon drops somewhere in the area. Skate through it and
--             it's yours: it floats over your head, your board leaves a trail,
--             and your clock runs down. Skate into the Melon King to take it;
--             bail and you drop it. First to hold it for the target time in
--             all wins.
--   results   the winner, then back to the lobby
MELON = MELON or {}

MELON.mode = SKATEGM_MODES.Register({ music = "arena", id = "melon", category = "Arena", title = "Melon King", order = 5, color = Color(90, 220, 90) })
MELON.NET_STATE = MELON.mode.NET_STATE
MELON.NET_CMD = MELON.mode.NET_CMD

MELON.MODEL = "models/props_junk/watermelon01.mdl"
MELON.TARGET_MIN, MELON.TARGET_MAX, MELON.TARGET_DEFAULT = 10, 180, 30
MELON.AREA_MIN, MELON.AREA_MAX, MELON.AREA_DEFAULT = 256, 4096, 1024
MELON.COUNTDOWN = 3
MELON.FIRST_DROP = 2    -- after GO, before the melon falls
MELON.RESULTS = 12
MELON.MAX_PLAYERS = 16
MELON.GRAB_RADIUS = 40  -- skate this close to a loose melon to take it
MELON.STEAL_RADIUS = 48 -- this close to the Melon King to take it from them
MELON.HOLD_GRACE = 1.5  -- a new Melon King can't lose it for this long
MELON.NO_TAGBACK = 3    -- seconds before whoever lost it can take it straight back
MELON.DROP_LOCK = 2     -- after bailing it away, seconds before you can pick it up again
MELON.LOST_AFTER = 3    -- a loose melon outside the area this long drops in again
MELON.DROP_HEIGHT = 240 -- it falls from this high (or the ceiling)

MELON.TRAIL = { style = 2, mode = 3, color = "90 230 90", length = 1.6, width = 7 }

MELON.ClampTarget = SKATEGM_MODES.Clamper(MELON.TARGET_MIN, MELON.TARGET_MAX, MELON.TARGET_DEFAULT)
MELON.ClampArea = SKATEGM_MODES.Clamper(MELON.AREA_MIN, MELON.AREA_MAX, MELON.AREA_DEFAULT)
function MELON.InArea(area, pos)
	if not (area and pos) then return false end
	local dx, dy = pos.x - area[1], pos.y - area[2]
	return dx * dx + dy * dy <= area[4] * area[4]
end
function MELON.Clock(s)
	s = math.max(0, s or 0)
	return string.format("%.1f", s)
end

MELON.cvAllowed = MELON.mode.cvAllowed
function MELON.Allowed() return MELON.mode:Allowed() end
