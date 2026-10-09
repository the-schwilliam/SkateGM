-- S.K.A.T.E., shared: the rules, limits and message names.
--
-- How a game runs (the server decides, every client follows its state):
--   lobby     the host opened it where they stood (the spot); players join
--   prep      the one whose go it is switches to Skater mode, goes to the spot
--   countdown 3, 2, 1
--   attempt   one line: it ends when it lands or they bail. The setter's
--             landed tricks are the set; everyone else must land a line with
--             every one of them in it
--   between   how it went, then the next go
--   results   the last one without S.K.A.T.E. spelled wins; then the lobby
-- A miss earns the next letter; a setter who doesn't land passes the set on.
SKATE = SKATE or {}

SKATE.mode = SKATEGM_MODES.Register({ id = "skate", category = "Tricks", title = "S.K.A.T.E.", order = 9, color = Color(120, 200, 255), minPlayers = 2 })

SKATE.WORD = { "S", "K", "A", "T", "E" }
SKATE.TIME_MIN, SKATE.TIME_MAX, SKATE.TIME_DEFAULT = 15, 120, 40
SKATE.PREP_TIMEOUT = 40
SKATE.COUNTDOWN = 3
SKATE.FINISH = 8
SKATE.BETWEEN = 4
SKATE.RESULTS = 15
SKATE.MAX_TRICKS = 12

SKATE.ClampTime = SKATEGM_MODES.Clamper(SKATE.TIME_MIN, SKATE.TIME_MAX, SKATE.TIME_DEFAULT)

function SKATE.Letters(n)
	local out = {}
	for i = 1, math.min(n or 0, #SKATE.WORD) do out[#out + 1] = SKATE.WORD[i] end
	return table.concat(out, ".")
end

function SKATE.Clean(tricks)
	local out, seen = {}, {}
	for _, t in ipairs(type(tricks) == "table" and tricks or {}) do
		t = tostring(t):sub(1, 40)
		local key = t:lower()
		if t ~= "" and not seen[key] and #out < SKATE.MAX_TRICKS then seen[key] = true out[#out + 1] = t end
	end
	return out
end

-- every trick of the set somewhere in the line
function SKATE.Matches(set, tricks)
	local have = {}
	for _, t in ipairs(tricks or {}) do have[tostring(t):lower()] = true end
	for _, t in ipairs(set or {}) do if not have[tostring(t):lower()] then return false end end
	return #(set or {}) > 0
end

SKATE.cvAllowed = SKATE.mode.cvAllowed
function SKATE.Allowed() return SKATE.mode:Allowed() end
