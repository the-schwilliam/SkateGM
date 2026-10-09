-- Imposter, shared: the rules, limits and message names.
--
-- How a game runs (the server decides, every client follows its state):
--   lobby     the host opened it where they stood (the spot); players join
--   prep      the active player switches to Skater mode and goes to the spot
--   countdown 3, 2, 1
--   turn      the active player skates one line; it ends when the line lands
--             or they bail (scores stay hidden); everyone else watches
--   finish    time's up: a line already going may still land
--   between   the next player
--   vote      everyone votes for who they think didn't know the score
--   results   the imposter, the score, everyone's lines; then the lobby
-- Everyone but the imposter is told the score to hit in one line; the
-- imposter is told nothing and has to copy what the others do.
IMPOSTER = IMPOSTER or {}

IMPOSTER.mode = SKATEGM_MODES.Register({ id = "imposter", category = "Party", title = "Impostor", order = 8, color = Color(230, 80, 90), minPlayers = 3 })
IMPOSTER.NET_ROLE = "skategm_imposter_role"

IMPOSTER.TURN_MIN, IMPOSTER.TURN_MAX, IMPOSTER.TURN_DEFAULT = 20, 180, 60
IMPOSTER.MIN_PLAYERS = 3
IMPOSTER.PREP_TIMEOUT = 40
IMPOSTER.COUNTDOWN = 3
IMPOSTER.FINISH = 10
IMPOSTER.BETWEEN = 3
IMPOSTER.VOTE_TIME = 45
IMPOSTER.RESULTS = 20
IMPOSTER.MAX_SCORE = 50000000
IMPOSTER.ROUND_TO = 250

IMPOSTER.DIFFICULTIES = {
	{ "easy", "0 - 2,000", 0, 2000 },
	{ "medium", "2,000 - 4,000", 2000, 4000 },
	{ "hard", "4,000 - 6,000", 4000, 6000 },
}
IMPOSTER.DIFFICULTY_DEFAULT = "easy"

IMPOSTER.ClampTurn = SKATEGM_MODES.Clamper(IMPOSTER.TURN_MIN, IMPOSTER.TURN_MAX, IMPOSTER.TURN_DEFAULT)

function IMPOSTER.Difficulty(id)
	for _, d in ipairs(IMPOSTER.DIFFICULTIES) do if d[1] == id then return d end end
	for _, d in ipairs(IMPOSTER.DIFFICULTIES) do if d[1] == IMPOSTER.DIFFICULTY_DEFAULT then return d end end
end

function IMPOSTER.PickTarget(id, random)
	local d = IMPOSTER.Difficulty(id)
	random = random or math.random
	local low = math.max(d[3], IMPOSTER.ROUND_TO)
	local steps = math.floor((d[4] - low) / IMPOSTER.ROUND_TO)
	return low + random(0, steps) * IMPOSTER.ROUND_TO
end

-- the turn order: shuffled, and the imposter never first unless allowed
-- (they'd have nobody to copy)
function IMPOSTER.Order(players, imposter, imposterFirst, random)
	random = random or math.random
	local order = {}
	for i, p in ipairs(players) do order[i] = p end
	for i = #order, 2, -1 do
		local j = random(1, i)
		order[i], order[j] = order[j], order[i]
	end
	if not imposterFirst and #order > 1 and order[1] == imposter then
		local j = random(2, #order)
		order[1], order[j] = order[j], order[1]
	end
	return order
end

-- the vote: the one with the most votes is out; a tie (or no votes) puts
-- nobody out
function IMPOSTER.Tally(votes)
	local count, best, top = {}, 0, nil
	for _, target in pairs(votes) do count[target] = (count[target] or 0) + 1 end
	local tied = false
	for target, n in pairs(count) do
		if n > best then best, top, tied = n, target, false
		elseif n == best then tied = true end
	end
	if tied then top = nil end
	return top, count
end

IMPOSTER.cvAllowed = IMPOSTER.mode.cvAllowed
function IMPOSTER.Allowed() return IMPOSTER.mode:Allowed() end
