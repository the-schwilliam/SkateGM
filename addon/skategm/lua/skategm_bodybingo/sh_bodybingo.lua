-- Body Bingo, shared: the rules, limits and message names.
--
-- How a game runs (the server decides, every client follows its state):
--   lobby     the host opened it; players join
--   countdown 3, 2, 1
--   playing   one shared card of injuries ("Left Tibia: Fractured"): bail
--             and every injury at least that bad ticks its square (Hall of
--             Meat's injury tracker, on each player's own skater). Three in
--             a row (or the whole card) wins; else the most squares
--   results   the winner; then the lobby
BODYBINGO = BODYBINGO or {}

BODYBINGO.mode = SKATEGM_MODES.Register({ id = "bodybingo", category = "Chaos", title = "Body Bingo", order = 17, color = Color(255, 90, 90), minPlayers = 1 })

BODYBINGO.SIZE = 3
BODYBINGO.TIME_MIN, BODYBINGO.TIME_MAX, BODYBINGO.TIME_DEFAULT = 60, 900, 240
BODYBINGO.COUNTDOWN = 3
BODYBINGO.RESULTS = 15
-- how hard the squares ask: a level per square, picked with these weights
-- (Bruised, Fractured, Broken; Shattered is left out: too rare to plan for)
BODYBINGO.LEVEL_WEIGHTS = { 4, 4, 2 }

BODYBINGO.ClampTime = SKATEGM_MODES.Clamper(BODYBINGO.TIME_MIN, BODYBINGO.TIME_MAX, BODYBINGO.TIME_DEFAULT)

-- a card: SIZE x SIZE different body parts, each with the injury it asks for
BODYBINGO.SPACING = 72

-- where the i-th of n skaters starts (and respawns): side by side at the start
function BODYBINGO.Slot(start, yaw, i, n)
	local r = math.rad((yaw or 0) - 90)
	local d = ((i or 1) - ((n or 1) + 1) / 2) * BODYBINGO.SPACING
	return { start[1] + math.cos(r) * d, start[2] + math.sin(r) * d, start[3] }
end

function BODYBINGO.Deal(parts, random)
	random = random or math.random
	local pool = {}
	for _, p in ipairs(parts) do pool[#pool + 1] = p.id end
	for i = #pool, 2, -1 do
		local j = random(1, i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	local total = 0
	for _, w in ipairs(BODYBINGO.LEVEL_WEIGHTS) do total = total + w end
	local card = {}
	for i = 1, BODYBINGO.SIZE * BODYBINGO.SIZE do
		local r, level = random(1, total), 1
		for lv, w in ipairs(BODYBINGO.LEVEL_WEIGHTS) do
			if r <= w then level = lv break end
			r = r - w
		end
		card[i] = { part = pool[(i - 1) % #pool + 1], level = level }
	end
	return card
end

function BODYBINGO.Lines()
	local n, lines = BODYBINGO.SIZE, {}
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

function BODYBINGO.Won(marks, card, full)
	if full then
		for i = 1, #card do if not marks[i] then return false end end
		return true
	end
	for _, line in ipairs(BODYBINGO.Lines()) do
		local all = true
		for _, i in ipairs(line) do if not marks[i] then all = false break end end
		if all then return true end
	end
	return false
end

function BODYBINGO.Count(marks, card)
	local n = 0
	for i = 1, #card do if marks[i] then n = n + 1 end end
	return n
end

-- which squares an injury ticks: the same part, at least as bad
function BODYBINGO.Ticks(card, marks, part, level)
	local out = {}
	for i, sq in ipairs(card) do
		if not marks[i] and sq.part == part and level >= sq.level then out[#out + 1] = i end
	end
	return out
end

BODYBINGO.cvAllowed = BODYBINGO.mode.cvAllowed
function BODYBINGO.Allowed() return BODYBINGO.mode:Allowed() end
