-- Bullseye, shared: the rules, limits and message names.
--
-- How a game runs (the server decides, every client follows its state):
--   lobby     the host stood at the start and placed the target; players join
--   prep      the one whose shot it is goes to the start
--   countdown 3, 2, 1
--   shot      one jump into the rings: the first landing in them, from a
--             jump that took off outside them, is locked in (other landings,
--             a drop-in on the way, don't count; a bail scores nothing); the
--             rocket board can steer it in the air
--   finish    time's up while in the air: it may still land
--   between   the score, then the next shot
--   results   the totals after every round; then the lobby
-- Rings around the target from the middle: gold 6, purple 3, blue 2, green 1.
-- Around them the no-zone (red, hatched): touching it at all (rolling,
-- landing, bailing, on foot) ends the go with nothing, so nobody rolls up
-- and ollies in. In the air over it is fine.
BULLSEYE = BULLSEYE or {}

BULLSEYE.mode = SKATEGM_MODES.Register({ id = "bullseye", category = "Sports", title = "Bullseye", order = 11, color = Color(255, 200, 40) })

BULLSEYE.RINGS = {
	{ name = "gold", points = 6, color = { 255, 200, 40 } },
	{ name = "purple", points = 3, color = { 165, 80, 230 } },
	{ name = "blue", points = 2, color = { 60, 140, 255 } },
	{ name = "green", points = 1, color = { 70, 205, 90 } },
}
BULLSEYE.SIZES = { { "small", "Small", 40 }, { "medium", "Medium", 72 }, { "large", "Large", 120 } }
BULLSEYE.SIZE_DEFAULT = "medium"
BULLSEYE.WIDTH_MIN, BULLSEYE.WIDTH_MAX, BULLSEYE.WIDTH_DEFAULT = 24, 200, 72
BULLSEYE.ClampWidth = SKATEGM_MODES.Clamper(BULLSEYE.WIDTH_MIN, BULLSEYE.WIDTH_MAX, BULLSEYE.WIDTH_DEFAULT)
BULLSEYE.TIME_MIN, BULLSEYE.TIME_MAX, BULLSEYE.TIME_DEFAULT = 15, 120, 40
BULLSEYE.ROUNDS_MIN, BULLSEYE.ROUNDS_MAX, BULLSEYE.ROUNDS_DEFAULT = 1, 10, 3
BULLSEYE.PREP_TIMEOUT = 40
BULLSEYE.COUNTDOWN = 3
BULLSEYE.FINISH = 8
BULLSEYE.BETWEEN = 4
BULLSEYE.RESULTS = 15
BULLSEYE.MIN_AIR = 0.25
BULLSEYE.ZONE_MIN, BULLSEYE.ZONE_MAX, BULLSEYE.ZONE_DEFAULT = 0, 480, 128
BULLSEYE.ClampZone = SKATEGM_MODES.Clamper(BULLSEYE.ZONE_MIN, BULLSEYE.ZONE_MAX, BULLSEYE.ZONE_DEFAULT)

-- (x, y, z) touching the no-zone: past the rings, within the band, near the target's height
function BULLSEYE.InZone(target, width, zone, x, y, z)
	if not (target and zone and zone > 0) then return false end
	local outer = width * #BULLSEYE.RINGS
	return SKATEGM_MODES.InNoZone(target, outer, outer + zone, x, y, z)
end

-- a skater's pose touching it (board, feet, or lying on it)
function BULLSEYE.Touching(P, target, width, zone, lying)
	if not (target and zone and zone > 0) then return false end
	local outer = width * #BULLSEYE.RINGS
	return SKATEGM_MODES.TouchingNoZone(P, target, outer, outer + zone, lying)
end

BULLSEYE.ClampTime = SKATEGM_MODES.Clamper(BULLSEYE.TIME_MIN, BULLSEYE.TIME_MAX, BULLSEYE.TIME_DEFAULT)
BULLSEYE.ClampRounds = SKATEGM_MODES.Clamper(BULLSEYE.ROUNDS_MIN, BULLSEYE.ROUNDS_MAX, BULLSEYE.ROUNDS_DEFAULT)

function BULLSEYE.RingWidth(size)
	for _, s in ipairs(BULLSEYE.SIZES) do if s[1] == size then return s[3] end end
	return BULLSEYE.SIZES[2][3]
end

-- which ring a landing at (x, y) is in, its points (0 outside), the distance
function BULLSEYE.Score(target, x, y, width)
	local d = math.sqrt((x - target[1]) ^ 2 + (y - target[2]) ^ 2)
	local i = math.floor(d / width) + 1
	local ring = BULLSEYE.RINGS[i]
	return ring and ring.points or 0, ring and ring.name or nil, d
end

BULLSEYE.cvAllowed = BULLSEYE.mode.cvAllowed
function BULLSEYE.Allowed() return BULLSEYE.mode:Allowed() end
