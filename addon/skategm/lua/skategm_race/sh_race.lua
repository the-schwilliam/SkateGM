-- Race, shared: limits and message names.
--
-- How a race runs (the server decides, every client follows its state):
--   lobby     the host created it; they place the start (where they stand,
--             facing the way to go) and the finish; players join (joining
--             switches you into Skater mode, so you're loaded in time)
--   countdown the host starts it: everyone in Skater mode is put on the start,
--             all in the same spot (skaters don't collide), 5, 4, 3, 2, 1
--   racing    first to reach the finish wins; everyone's time is kept
--   results   the finishing order, then back to the lobby for a rematch
-- Skaters don't collide with each other while racing.
RACE = RACE or {}

RACE.mode = SKATEGM_MODES.Register({ music = "arena", id = "race", category = "Sports", title = "Race", order = 1, color = Color(120, 220, 255), netState = "skategm_race_state", netCommand = "skategm_race_cmd" })
RACE.NET_STATE, RACE.NET_CMD = RACE.mode.NET_STATE, RACE.mode.NET_CMD

RACE.RADIUS_MIN, RACE.RADIUS_MAX, RACE.RADIUS_DEFAULT = 50, 800, 150
RACE.LIMIT_MIN, RACE.LIMIT_MAX, RACE.LIMIT_DEFAULT = 30, 900, 180
RACE.PREP_TIMEOUT = 40 -- seconds to get into Skater mode
RACE.COUNTDOWN = 3
RACE.RESULTS = 12
RACE.MAX_PLAYERS = 16

RACE.ClampRadius = SKATEGM_MODES.Clamper(RACE.RADIUS_MIN, RACE.RADIUS_MAX, RACE.RADIUS_DEFAULT)
RACE.ClampLimit = SKATEGM_MODES.Clamper(RACE.LIMIT_MIN, RACE.LIMIT_MAX, RACE.LIMIT_DEFAULT)

-- where racers start: all in exactly the same spot (they don't collide)
function RACE.Slot(start) return start end

function RACE.Time(t)
	t = math.max(0, t or 0)
	return string.format("%d:%05.2f", math.floor(t / 60), t % 60)
end

RACE.cvAllowed = RACE.mode.cvAllowed
function RACE.Allowed() return RACE.mode:Allowed() end
