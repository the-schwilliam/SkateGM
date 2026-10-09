BINGO = BINGO or {}

BINGO.mode = SKATEGM_MODES.Register({ id = "bingo", category = "Tricks", title = "Trick Bingo", order = 6, color = Color(255, 200, 90) })
BINGO.NET_STATE, BINGO.NET_CMD = BINGO.mode.NET_STATE, BINGO.mode.NET_CMD
BINGO.cvAllowed = BINGO.mode.cvAllowed
function BINGO.Allowed() return BINGO.mode:Allowed() end

BINGO.TIME_MIN, BINGO.TIME_MAX, BINGO.TIME_DEFAULT = 60, 1200, 300
BINGO.COUNTDOWN = 3
BINGO.RESULTS = 15
BINGO.MAX_PLAYERS = 16
BINGO.SIZE = 3

BINGO.TASKS = {
	{ id = "kickflip", label = "Kickflip", kind = "trick", match = { "kickflip" } },
	{ id = "heelflip", label = "Heelflip", kind = "trick", match = { "heelflip" } },
	{ id = "varial", label = "Any varial", kind = "trick", match = { "varial" } },
	{ id = "spin360", label = "Any 360", kind = "trick", match = { "360" } },
	{ id = "fiftyfifty", label = "50-50 grind", kind = "state", state = "GrindFiftyFifty" },
	{ id = "boardslide", label = "Boardslide", kind = "state", state = "GrindBoardslide" },
	{ id = "fiveo", label = "5-0 grind", kind = "state", state = "GrindFiveO" },
	{ id = "tipslide", label = "Tail / nose slide", kind = "state", state = "GrindTipslide" },
	{ id = "darkslide", label = "Darkslide", kind = "state", state = "GrindDarkslide" },
	{ id = "handplant", label = "Hand plant", kind = "state", state = "HandPlant" },
	{ id = "footplant", label = "Foot plant", kind = "state", state = "FootPlant" },
	{ id = "boneless", label = "Boneless", kind = "state", state = "Boneless" },
	{ id = "air15", label = "1.5 s of air", kind = "air", seconds = 1.5 },
	{ id = "air3", label = "3 s of air", kind = "air", seconds = 3 },
	{ id = "grind2", label = "2 s grind", kind = "grindtime", seconds = 2 },
	{ id = "grind4", label = "4 s grind", kind = "grindtime", seconds = 4 },
	{ id = "line2k", label = "2,000 point line", kind = "line", points = 2000 },
	{ id = "line10k", label = "10,000 point line", kind = "line", points = 10000 },
	{ id = "mult3", label = "x3 multiplier", kind = "mult", value = 3 },
	{ id = "mult6", label = "x6 multiplier", kind = "mult", value = 6 },
	{ id = "speed12", label = "Hit 12 m/s", kind = "speed", value = 12 },
	{ id = "speed20", label = "Hit 20 m/s", kind = "speed", value = 20 },
	{ id = "clean", label = "Clean landing", kind = "clean" },
}
BINGO.BY_ID = {}
for _, t in ipairs(BINGO.TASKS) do BINGO.BY_ID[t.id] = t end

BINGO.ClampTime = SKATEGM_MODES.Clamper(BINGO.TIME_MIN, BINGO.TIME_MAX, BINGO.TIME_DEFAULT)

BINGO.Clock = SKATEGM_MODES.Clock

function BINGO.Deal(rand, free)
	rand = rand or math.random
	local pool = {}
	for _, t in ipairs(BINGO.TASKS) do pool[#pool + 1] = t.id end
	for i = #pool, 2, -1 do
		local j = rand(1, i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	local card = {}
	for i = 1, BINGO.SIZE * BINGO.SIZE do card[i] = pool[i] end
	if free then card[math.ceil(#card / 2)] = "free" end
	return card
end

function BINGO.Lines()
	local n, lines = BINGO.SIZE, {}
	for r = 0, n - 1 do
		local row, col = {}, {}
		for c = 0, n - 1 do
			row[#row + 1] = r * n + c + 1
			col[#col + 1] = c * n + r + 1
		end
		lines[#lines + 1], lines[#lines + 2] = row, col
	end
	local d1, d2 = {}, {}
	for i = 0, n - 1 do
		d1[#d1 + 1] = i * n + i + 1
		d2[#d2 + 1] = i * n + (n - 1 - i) + 1
	end
	lines[#lines + 1], lines[#lines + 2] = d1, d2
	return lines
end

function BINGO.Won(marks, card, full)
	local function has(i) return marks[i] or card[i] == "free" end
	if full then
		for i = 1, #card do if not has(i) then return false end end
		return true
	end
	for _, line in ipairs(BINGO.Lines()) do
		local all = true
		for _, i in ipairs(line) do if not has(i) then all = false break end end
		if all then return true end
	end
	return false
end

function BINGO.Count(marks, card)
	local n = 0
	for i = 1, #card do if marks[i] or card[i] == "free" then n = n + 1 end end
	return n
end
