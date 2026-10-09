-- Run Royale, shared: limits and message names.
--
-- How a game runs (the server decides, every client follows its state):
--   lobby     the host set it up: the start where they stood (no play
--             area: skate anywhere); players join (joining switches you into Skater mode)
--   countdown everyone still in is put on the start, 3, 2, 1
--   running   everyone still in skates at once for the run time (20 s)
--   replays   every run is shown to everyone, one after the other (each
--             client recorded them all as they happened: poses already reach
--             every player, so nothing extra goes over the network)
--   voting    everyone in the match, knocked out or not, votes for the worst
--             run (not their own); most votes is knocked out (a tie: one of
--             the tied, at random). Knocked-out players watch and vote on.
--   out       who's out, then the next round - until one is left
--   results   the winner, then back to the lobby
ROYALE = ROYALE or {}

ROYALE.mode = SKATEGM_MODES.Register({ id = "royale", category = "Party", title = "Run Royale", order = 6, color = Color(255, 200, 70) })
ROYALE.NET_STATE = ROYALE.mode.NET_STATE
ROYALE.NET_CMD = ROYALE.mode.NET_CMD

ROYALE.RUN_MIN, ROYALE.RUN_MAX, ROYALE.RUN_DEFAULT = 10, 60, 20
ROYALE.COUNTDOWN = 3
ROYALE.REPLAY_GAP = 1.5 -- between replays: the next skater's name
ROYALE.VOTE_TIME = 20
ROYALE.OUT_TIME = 5
ROYALE.RESULTS = 12
ROYALE.MAX_PLAYERS = 12
ROYALE.RECORD_RATE = 20 -- poses a second in a recorded run

ROYALE.ClampRun = SKATEGM_MODES.Clamper(ROYALE.RUN_MIN, ROYALE.RUN_MAX, ROYALE.RUN_DEFAULT)

-- the votes counted: who goes (pick breaks a tie: pick(n) -> 1..n)
function ROYALE.Tally(votes, alive, pick)
	local count, best, tied = {}, 0, {}
	for _, target in pairs(votes) do
		if alive[target] then count[target] = (count[target] or 0) + 1 end
	end
	for target, n in pairs(count) do
		if n > best then best, tied = n, { target } elseif n == best then tied[#tied + 1] = target end
	end
	if #tied == 0 then
		for target in pairs(alive) do tied[#tied + 1] = target end
	end
	table.sort(tied)
	if #tied == 0 then return nil, count end
	return tied[(pick or math.random)(#tied)], count
end

ROYALE.cvAllowed = ROYALE.mode.cvAllowed
function ROYALE.Allowed() return ROYALE.mode:Allowed() end
