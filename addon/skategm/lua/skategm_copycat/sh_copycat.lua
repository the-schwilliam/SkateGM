-- Copycat, shared: the rules, limits and message names.
--
-- How a game runs (the server decides, every client follows its state):
--   lobby      the host stood at the start, facing the way to go; players join
--   leadcount  the setter goes to the start, 3, 2, 1
--   lead       the setter skates a line; everyone watches live
--   copycount  everyone else to the start, 3, 2, 1
--   copy       they all skate at once, out of each other's sight
--   replay     one copy played back beside the setter (with a name tag)
--   score      how close it was; then the next copy, then the next setter
--   results    every player has set a line: the most points wins
COPYCAT = COPYCAT or {}

COPYCAT.mode = SKATEGM_MODES.Register({ id = "copycat", category = "Tricks", title = "Copycat", order = 20, color = Color(120, 220, 200), minPlayers = 2 })

COPYCAT.RUN_MIN, COPYCAT.RUN_MAX, COPYCAT.RUN_DEFAULT = 5, 60, 15
COPYCAT.JUDGING = { { 128, "Strict" }, { 192, "Normal" }, { 320, "Loose" } }
COPYCAT.JUDGING_DEFAULT = 192
COPYCAT.COUNTDOWN = 3
COPYCAT.REPLAY_GAP = 1
COPYCAT.SCORE = 4
COPYCAT.RESULTS = 15
COPYCAT.SAMPLE = 0.1
COPYCAT.MIN_LINE = 3 -- seconds a copy gets at least, when the setter bailed early
COPYCAT.BAIL_HOLD, COPYCAT.BAIL_GRACE = 0.25, 1
COPYCAT.SETTLE = 0.4 -- seconds into a run before its path is sampled (the start teleport lands)
COPYCAT.RECORD_RATE = 20

COPYCAT.ClampRun = SKATEGM_MODES.Clamper(COPYCAT.RUN_MIN, COPYCAT.RUN_MAX, COPYCAT.RUN_DEFAULT)

function COPYCAT.Judging(v)
	for _, j in ipairs(COPYCAT.JUDGING) do if j[1] == tonumber(v) then return j[1] end end
	return COPYCAT.JUDGING_DEFAULT
end

COPYCAT.Closeness = SKATEGM_MODES.Closeness
function COPYCAT.Match(lead, copy, scale) return SKATEGM_MODES.PathMatch(lead, copy, scale or COPYCAT.JUDGING_DEFAULT) end

COPYCAT.cvAllowed = COPYCAT.mode.cvAllowed
function COPYCAT.Allowed() return COPYCAT.mode:Allowed() end
