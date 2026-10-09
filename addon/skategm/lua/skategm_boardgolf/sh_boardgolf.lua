-- Board Golf, shared: the rules, limits and message names.
--
-- How a game runs (the server decides, every client follows its state):
--   lobby     the host stood at the tee and placed the cup; players join
--   flyover   the camera flies from the tee to the cup, for everyone
--   prep      the one whose shot it is goes to their lie (the tee at first),
--             facing the cup
--   countdown 3, 2, 1
--   shot      a few seconds to ride (the rocket board's on); when the shot
--             clock runs out the board is let go
--   roll      the board as a physics prop, with the real board's place, angle
--             and speed; the skater is out of the picture (unseen, frozen).
--             Where it comes to rest is the next lie; in the cup holes out
--   between   the stroke's result, then the next shot: farthest from the cup first
--   results   every skater holed out (or picked up): the fewest strokes wins
BOARDGOLF = BOARDGOLF or {}

BOARDGOLF.mode = SKATEGM_MODES.Register({ id = "boardgolf", category = "Sports", title = "Board Golf", order = 22, color = Color(110, 210, 110), minPlayers = 1 })

BOARDGOLF.CUPS = { { "small", "Small", 32 }, { "medium", "Medium", 56 }, { "large", "Large", 96 } }
BOARDGOLF.CUP_DEFAULT = "medium"
BOARDGOLF.RADIUS_MIN, BOARDGOLF.RADIUS_MAX, BOARDGOLF.RADIUS_DEFAULT = 24, 160, 56
BOARDGOLF.ClampRadius = SKATEGM_MODES.Clamper(BOARDGOLF.RADIUS_MIN, BOARDGOLF.RADIUS_MAX, BOARDGOLF.RADIUS_DEFAULT)
BOARDGOLF.FRICTIONS = { { 0, "Off (rolls forever)" }, { 37.5, "Normal" }, { 75, "Grippy" }, { 150, "Heavy" } }
BOARDGOLF.FRICTION_DEFAULT = 37.5
BOARDGOLF.CAPTURE_SPEED = 450 -- slower than this over the cup, the board drops in (faster: it rolls over)
BOARDGOLF.SINK_TIME = 0.8
BOARDGOLF.PARS = { { 0, "Auto" }, { 2, "2" }, { 3, "3" }, { 4, "4" }, { 5, "5" }, { 6, "6" }, { 7, "7" }, { 8, "8" } }
BOARDGOLF.SHOT_MIN, BOARDGOLF.SHOT_MAX, BOARDGOLF.SHOT_DEFAULT = 2, 10, 4
BOARDGOLF.STROKES_MIN, BOARDGOLF.STROKES_MAX, BOARDGOLF.STROKES_DEFAULT = 4, 20, 10
BOARDGOLF.PICKUP = 2
BOARDGOLF.PREP_TIMEOUT = 40
BOARDGOLF.COUNTDOWN = 3
BOARDGOLF.SETTLE = 12
BOARDGOLF.RELEASE_GRACE = 3
BOARDGOLF.RELEASE_RANGE = 400
BOARDGOLF.SPEED_MAX = 3000
BOARDGOLF.BETWEEN = 3
BOARDGOLF.RESULTS = 15
BOARDGOLF.REST_SPEED = 20
BOARDGOLF.REST_TIME = 0.5
BOARDGOLF.LIE_RANGE = 700
BOARDGOLF.CUP_HEIGHT = 64
BOARDGOLF.REMOUNT = 0x8000

BOARDGOLF.ClampShot = SKATEGM_MODES.Clamper(BOARDGOLF.SHOT_MIN, BOARDGOLF.SHOT_MAX, BOARDGOLF.SHOT_DEFAULT)
BOARDGOLF.ClampStrokes = SKATEGM_MODES.Clamper(BOARDGOLF.STROKES_MIN, BOARDGOLF.STROKES_MAX, BOARDGOLF.STROKES_DEFAULT)

function BOARDGOLF.CupId(id)
	for _, c in ipairs(BOARDGOLF.CUPS) do if c[1] == id then return id end end
	return BOARDGOLF.CUP_DEFAULT
end

function BOARDGOLF.Friction(v)
	for _, f in ipairs(BOARDGOLF.FRICTIONS) do if f[1] == tonumber(v) then return f[1] end end
	return BOARDGOLF.FRICTION_DEFAULT
end

-- the host's par (2-8), or 0 = from the distance
function BOARDGOLF.ParChoice(v)
	v = math.floor(tonumber(v) or 0)
	return (v >= 2 and v <= 8) and v or 0
end

function BOARDGOLF.CupRadius(id)
	for _, c in ipairs(BOARDGOLF.CUPS) do if c[1] == id then return c[3] end end
	return BOARDGOLF.CUPS[2][3]
end

function BOARDGOLF.Distance(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) end

-- a board resting at pos: in the cup?
function BOARDGOLF.InCup(pos, cup, radius)
	return BOARDGOLF.Distance(pos, cup) <= radius and math.abs(pos[3] - cup[3]) <= BOARDGOLF.CUP_HEIGHT
end

-- how long the flyover from the tee to the cup takes (seconds)
function BOARDGOLF.FlyTime(distance) return math.max(3.5, math.min(7, (distance or 0) / 700)) end

-- par from the tee's distance to the cup (map units)
function BOARDGOLF.Par(distance)
	return math.max(2, math.min(6, math.floor(distance / 900) + 2))
end

-- the next to shoot: whoever's not holed out and farthest from the cup
function BOARDGOLF.NextUp(players, cup)
	local best, bestD
	for _, p in ipairs(players) do
		if not p.holed then
			local d = BOARDGOLF.Distance(p.lie, cup)
			if not bestD or d > bestD then best, bestD = p, d end
		end
	end
	return best
end

-- a yaw (degrees) looking from a to b
function BOARDGOLF.YawTo(a, b) return math.deg(math.atan2(b[2] - a[2], b[1] - a[1])) end

BOARDGOLF.cvAllowed = BOARDGOLF.mode.cvAllowed
function BOARDGOLF.Allowed() return BOARDGOLF.mode:Allowed() end
