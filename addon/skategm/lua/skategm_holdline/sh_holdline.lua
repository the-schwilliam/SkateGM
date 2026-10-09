-- Hold the Line, shared: the rules, limits and message names.
--
-- A co-op line passed from skater to skater (the server decides, every client
-- follows its state):
--   lobby     the host stood at the start, facing the way to go; players join
--   countdown everyone skating; the first skater held at the start, 3, 2, 1
--   riding    one skater keeps the line going; everyone else watches. When
--             their time's up the line passes on at the next safe moment
--             (rolling on the ground, not mid-trick)
--   handover  the next skater appears exactly there, facing the same way,
--             held still for a few seconds, then carries on at the same speed
--   results   one bail, or the line slowing to a stop, ends it for everyone:
--             the team's score, the handovers survived; then the lobby
HOLDLINE = HOLDLINE or {}

HOLDLINE.mode = SKATEGM_MODES.Register({ id = "holdline", category = "Party", title = "Hold the Line", order = 23, color = Color(90, 200, 255), minPlayers = 1 })

HOLDLINE.TURN_MIN, HOLDLINE.TURN_MAX, HOLDLINE.TURN_DEFAULT = 5, 30, 12
HOLDLINE.SPEEDS = { { 0, "Off" }, { 60, "Slow (1.5 m/s)" }, { 120, "Rolling (3 m/s)" }, { 200, "Quick (5 m/s)" } }
HOLDLINE.SPEED_DEFAULT = 60
HOLDLINE.COUNTDOWN = 3
HOLDLINE.HANDOVER = 3
HOLDLINE.PASS_WAIT = 8
HOLDLINE.STALL_TIME = 2
HOLDLINE.GRACE = 1.5
HOLDLINE.BAIL_HOLD = 0.25
HOLDLINE.RESULTS = 15
HOLDLINE.LIVE_RATE = 4
HOLDLINE.PASS_RANGE = 400
HOLDLINE.SPEED_CAP = 3000

HOLDLINE.ClampTurn = SKATEGM_MODES.Clamper(HOLDLINE.TURN_MIN, HOLDLINE.TURN_MAX, HOLDLINE.TURN_DEFAULT)

function HOLDLINE.MinSpeed(v)
	for _, s in ipairs(HOLDLINE.SPEEDS) do if s[1] == tonumber(v) then return s[1] end end
	return HOLDLINE.SPEED_DEFAULT
end

-- who skates after the one at index i (of n): round and round
function HOLDLINE.NextIndex(i, n) return n > 0 and (i % n) + 1 or 1 end

-- a safe moment to pass the line on: rolling on the board, not mid-trick
HOLDLINE.UNSAFE = { "Air", "Grind", "Manual", "Wipeout", "Biped", "Slide", "Revert", "Lip", "Wall" }
function HOLDLINE.SafeState(state)
	if type(state) ~= "string" or not state:find("Ground", 1, true) then return false end
	for _, word in ipairs(HOLDLINE.UNSAFE) do if state:find(word, 1, true) then return false end end
	return true
end

-- ... and on flat enough ground: the next skater starts level, and taking
-- over on a slope bailed them. The deck's tilt, along it and across it
HOLDLINE.FLAT_DEG = 7
function HOLDLINE.Flat(P)
	if not (P and P.TRUCK_FRONT and P.TRUCK_BACK) then return false end
	local function Tilt(a, b)
		local d = a - b
		local run = math.sqrt(d.x * d.x + d.y * d.y)
		if run < 0.5 then return 90 end
		return math.deg(math.atan(math.abs(d.z) / run))
	end
	local along = Tilt(P.TRUCK_FRONT, P.TRUCK_BACK)
	local across = (P.RIGHT_WHEELFRONT and P.LEFT_WHEELFRONT) and Tilt(P.RIGHT_WHEELFRONT, P.LEFT_WHEELFRONT) or 0
	return along <= HOLDLINE.FLAT_DEG and across <= HOLDLINE.FLAT_DEG
end

HOLDLINE.cvAllowed = HOLDLINE.mode.cvAllowed
function HOLDLINE.Allowed() return HOLDLINE.mode:Allowed() end
