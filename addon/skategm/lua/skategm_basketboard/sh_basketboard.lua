-- Basketboard, shared: the rules, limits and message names.
--
-- How a game runs (the server decides, every client follows its state):
--   lobby     the host stood at the start, facing the way to go, and placed
--             the ghost hoop (where, how big, how high, which way it faces);
--             players join
--   prep      the one whose turn it is goes to the start
--   countdown 3, 2, 1
--   turn      one dismount or bail: get the board, or yourself, down
--             through the rim
--   finish    time's up: a few seconds to let go of the board
--   between   the score, then the next turn
--   results   the most baskets after every round; then the lobby
-- The board or the skater down through the hoop: 1 point. Under the hoop,
-- the no-zone (red, hatched): touching it at all (rolling, landing, a bail,
-- on foot) ends the turn with nothing, so nobody rolls up and ollies in; in
-- the air over it is fine, and going through the hoop counts first.
BASKETBOARD = BASKETBOARD or {}

BASKETBOARD.mode = SKATEGM_MODES.Register({ id = "basketboard", category = "Sports", title = "Basketboard", order = 19, color = Color(255, 130, 40) })

BASKETBOARD.TURN_STEP = 15
BASKETBOARD.RADIUS_MIN, BASKETBOARD.RADIUS_MAX, BASKETBOARD.RADIUS_DEFAULT = 16, 96, 34
BASKETBOARD.LIFT_MIN, BASKETBOARD.LIFT_MAX, BASKETBOARD.LIFT_DEFAULT = 24, 160, 40
BASKETBOARD.TIME_MIN, BASKETBOARD.TIME_MAX, BASKETBOARD.TIME_DEFAULT = 10, 120, 30
BASKETBOARD.ROUNDS_MIN, BASKETBOARD.ROUNDS_MAX, BASKETBOARD.ROUNDS_DEFAULT = 1, 10, 3
BASKETBOARD.PREP_TIMEOUT = 40
BASKETBOARD.COUNTDOWN = 3
BASKETBOARD.FINISH = 5
BASKETBOARD.WATCH = 4
BASKETBOARD.BETWEEN = 4
BASKETBOARD.RESULTS = 15
BASKETBOARD.BODY_MARGIN = 6
BASKETBOARD.ZONE_MIN, BASKETBOARD.ZONE_MAX, BASKETBOARD.ZONE_DEFAULT = 0, 480, 160
BASKETBOARD.ClampZone = SKATEGM_MODES.Clamper(BASKETBOARD.ZONE_MIN, BASKETBOARD.ZONE_MAX, BASKETBOARD.ZONE_DEFAULT)

-- touching the no-zone: within it on the ground under the hoop
function BASKETBOARD.InZone(ground, zone, x, y, z)
	return (zone or 0) > 0 and SKATEGM_MODES.InNoZone(ground, 0, zone, x, y, z) or false
end

BASKETBOARD.ClampRadius = SKATEGM_MODES.Clamper(BASKETBOARD.RADIUS_MIN, BASKETBOARD.RADIUS_MAX, BASKETBOARD.RADIUS_DEFAULT)
BASKETBOARD.ClampLift = SKATEGM_MODES.Clamper(BASKETBOARD.LIFT_MIN, BASKETBOARD.LIFT_MAX, BASKETBOARD.LIFT_DEFAULT)
BASKETBOARD.ClampTime = SKATEGM_MODES.Clamper(BASKETBOARD.TIME_MIN, BASKETBOARD.TIME_MAX, BASKETBOARD.TIME_DEFAULT)
BASKETBOARD.ClampRounds = SKATEGM_MODES.Clamper(BASKETBOARD.ROUNDS_MIN, BASKETBOARD.ROUNDS_MAX, BASKETBOARD.ROUNDS_DEFAULT)

-- which way the hoop's open side faces (degrees): toward the start, turned by turn
function BASKETBOARD.Facing(hoop, start, turn)
	local yaw = math.deg(math.atan2(start[2] - hoop[2], start[1] - hoop[1]))
	return (yaw + (tonumber(turn) or 0)) % 360
end

-- a point moving from a to b went through the rim (a circle of radius r at
-- hoop {x, y, z}): down only, or either way; true and where it crossed
function BASKETBOARD.Through(a, b, hoop, r, either)
	local z = hoop[3]
	local down = a[3] > z and b[3] <= z
	local up = a[3] < z and b[3] >= z
	if not (down or (either and up)) then return false end
	local t = (a[3] - z) / (a[3] - b[3])
	local x, y = a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t
	return (x - hoop[1]) ^ 2 + (y - hoop[2]) ^ 2 <= r * r, x, y
end

BASKETBOARD.cvAllowed = BASKETBOARD.mode.cvAllowed
function BASKETBOARD.Allowed() return BASKETBOARD.mode:Allowed() end
