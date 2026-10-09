-- Run Royale, server: rounds, the replay order, the votes and who's out.
-- Uses only SkateGM.API from the skating add-on.

local G = { phase = "idle" }
ROYALE.session = G
ROYALE.mode:UseSessions(G)

local API, Allowed, Skating = SKATEGM_MODES.API, SKATEGM_MODES.Allowed, SKATEGM_MODES.Skating

local function Tell(ply, text) ROYALE.mode:Tell(ply, text) end

local function Key(ply) return SKATEGM_MODES.Key(ply, G.keys) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(G.players, ply) end
local function Entry(ply) return IndexOf(ply) and G.entries[Key(ply)] or nil end
local function InMatch(ply) local e = Entry(ply) return e ~= nil and e.inMatch end
local function Alive(ply) local e = Entry(ply) return e ~= nil and e.inMatch and not e.out end

local Vec = SKATEGM_MODES.Vec

local function AlivePlayers()
	local list = {}
	for _, p in ipairs(G.players or {}) do if Alive(p) then list[#list + 1] = p end end
	return list
end

---------------------------------------------------------------------------
-- what every client sees (who voted for whom isn't in it: only who's voted)
---------------------------------------------------------------------------
local function Public(now)
	local t = { phase = G.phase }
	if G.phase == "idle" then return t end
	t.host = IsValid(G.host) and G.host:EntIndex() or 0
	t.start, t.yaw, t.runTime, t.round, t.bailEnds = G.start, G.yaw or 0, G.runTime, G.round or 0, G.bailEnds
	t.timeLeft = G.deadline and math.max(0, G.deadline - now) or 0
	if G.phase == "replays" and G.order then
		local cur = G.order[G.replayIndex]
		t.replay = cur and { ent = cur.ent, name = cur.name, index = G.replayIndex, total = #G.order, at = now - G.replayAt, score = cur.score } or nil
	end
	t.players = {}
	for _, p in ipairs(G.players) do
		local e = G.entries[Key(p)]
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), inMatch = e.inMatch, out = e.out, done = e.done, voted = G.votes and G.votes[p:EntIndex()] ~= nil or nil, score = e.score }
	end
	t.knocked = G.knocked
	t.winner = G.winner
	return t
end

local function Broadcast(now)
	ROYALE.mode:Broadcast(Public(now or CurTime()), now)
	G.lastBroadcast = now or CurTime()
end
ROYALE.Broadcast = Broadcast

---------------------------------------------------------------------------
-- flow
---------------------------------------------------------------------------
local function Stop(reason, now)
	for k in pairs(G) do G[k] = nil end
	G.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
ROYALE.Stop = Stop

local function ToLobby(now)
	G.phase, G.deadline, G.winner, G.knocked, G.votes, G.order, G.round = "lobby", nil, nil, nil, nil, nil, 0
	for key, e in pairs(G.entries) do
		if e.left then G.entries[key] = nil else e.inMatch, e.out, e.score, e.done = nil, nil, nil, nil end
	end
	Broadcast(now)
end

local function Results(now, why)
	G.phase, G.deadline, G.votes, G.order = "results", now + ROYALE.RESULTS, nil, nil
	local alive = AlivePlayers()
	G.winner = #alive == 1 and { name = alive[1]:Nick(), ent = alive[1]:EntIndex() } or nil
	Tell(nil, G.winner and (G.winner.name .. " wins Run Royale!") or (why or "nobody's left"))
	Broadcast(now)
end

local function Countdown(now)
	G.round = (G.round or 0) + 1
	G.phase, G.deadline, G.knocked, G.votes, G.order = "countdown", now + ROYALE.COUNTDOWN, nil, nil, nil
	for _, p in ipairs(AlivePlayers()) do G.entries[Key(p)].score, G.entries[Key(p)].done = nil, nil end
	Broadcast(now)
end

local function Run(now)
	G.phase, G.deadline = "running", now + G.runTime
	Broadcast(now)
end

local function Replays(now)
	G.order = {}
	for _, p in ipairs(AlivePlayers()) do
		G.order[#G.order + 1] = { ent = p:EntIndex(), name = p:Nick(), score = G.entries[Key(p)].score }
	end
	G.phase, G.replayIndex, G.replayAt = "replays", 1, now
	G.deadline = now + G.runTime + ROYALE.REPLAY_GAP
	Broadcast(now)
end

local function Voting(now)
	G.phase, G.deadline, G.votes, G.order = "voting", now + ROYALE.VOTE_TIME, {}, nil
	Broadcast(now)
	Tell(nil, "vote for the worst run!")
end

local function Count(now)
	local alive = {}
	for _, p in ipairs(AlivePlayers()) do alive[p:EntIndex()] = p end
	local target = ROYALE.Tally(G.votes or {}, alive)
	local ply = target and alive[target]
	G.votes = nil
	if not ply then return Results(now, "nobody's left") end
	local e = G.entries[Key(ply)]
	e.out = true
	G.knocked = { ent = ply:EntIndex(), name = ply:Nick() }
	Tell(nil, ply:Nick() .. " had the worst run and is out!")
	if #AlivePlayers() <= 1 then return Results(now) end
	G.phase, G.deadline = "out", now + ROYALE.OUT_TIME
	Broadcast(now)
end

local function Begin(now)
	local n = 0
	for _, p in ipairs(G.players) do
		local e = G.entries[Key(p)]
		e.inMatch = Skating(p) or nil
		e.out, e.score = nil, nil
		if e.inMatch then n = n + 1 else Tell(p, "not in Skater mode yet: you sit this one out") end
	end
	if n < 2 then return Tell(G.host, "Run Royale needs at least two skaters in Skater mode") end
	G.round = 0
	Countdown(now)
end

local function AddPlayer(ply, now)
	if IndexOf(ply) then return end
	if #G.players >= ROYALE.MAX_PLAYERS then return Tell(ply, "the game is full") end
	local e = G.entries[Key(ply)]
	if e then e.left = nil else G.entries[Key(ply)] = { name = ply:Nick() } end
	G.players[#G.players + 1] = ply
	G.keys[ply] = Key(ply)
	Tell(nil, ply:Nick() .. " joined Run Royale")
	Broadcast(now)
end

local function RemovePlayer(ply, now, quiet)
	local i = IndexOf(ply)
	if not i then return end
	local ent = ply.EntIndex and ply:EntIndex()
	table.remove(G.players, i)
	G.entries[Key(ply)] = nil
	G.keys[ply] = nil
	if G.votes and ent then
		G.votes[ent] = nil
		for voter, target in pairs(G.votes) do if target == ent then G.votes[voter] = nil end end
	end
	if ply == G.host then
		G.host = G.players[1]
		if not IsValid(G.host) then return Stop("the host left: Run Royale closed", now) end
		Tell(G.host, "you're the Run Royale host now")
	end
	if not quiet then Tell(nil, (IsValid(ply) and ply:Nick() or "someone") .. " left Run Royale") end
	if G.phase ~= "lobby" and G.phase ~= "results" and #AlivePlayers() <= 1 then return Results(now, "everyone else left") end
	Broadcast(now)
end

---------------------------------------------------------------------------
-- votes and scores
---------------------------------------------------------------------------
function ROYALE.Vote(ply, target, now)
	if G.phase ~= "voting" or not InMatch(ply) then return false end
	target = tonumber(target)
	if not target or target == ply:EntIndex() then return false end
	local ok = false
	for _, p in ipairs(AlivePlayers()) do if p:EntIndex() == target then ok = true end end
	if not ok then return false end
	G.votes[ply:EntIndex()] = target
	local all = true
	for _, p in ipairs(G.players) do if InMatch(p) and G.votes[p:EntIndex()] == nil then all = false end end
	if all then G.deadline = math.min(G.deadline, now + 1.5) end
	Broadcast(now)
	return true
end

function ROYALE.Bailed(ply, score, now)
	if not G.bailEnds or G.phase ~= "running" or not Alive(ply) then return false end
	local e = G.entries[Key(ply)]
	if e.done then return false end
	ROYALE.Score(ply, score, now)
	e.done = true
	local all = true
	for _, p in ipairs(AlivePlayers()) do if not G.entries[Key(p)].done then all = false end end
	if all then
		Tell(nil, "everyone's bailed: replays")
		G.deadline = now
	end
	Broadcast(now)
	return true
end

function ROYALE.Score(ply, score, now)
	if not Alive(ply) or (G.phase ~= "running" and G.phase ~= "replays") then return false end
	if G.entries[Key(ply)].done and G.entries[Key(ply)].score ~= nil then return false end
	score = tonumber(score)
	if not score or score ~= score then return false end
	G.entries[Key(ply)].score = math.Clamp(math.floor(score), 0, 99999999)
	if G.order then for _, o in ipairs(G.order) do if o.ent == ply:EntIndex() then o.score = G.entries[Key(ply)].score end end end
	return true
end

---------------------------------------------------------------------------
-- commands (from the menu, chat or the console)
---------------------------------------------------------------------------
function ROYALE.Command(ply, m, now)
	now = now or CurTime()
	if type(m) ~= "table" or type(m.cmd) ~= "string" then return end
	local cmd = m.cmd
	local host = G.phase ~= "idle" and ply == G.host
	if not ROYALE.Allowed() and cmd ~= "leave" then return Tell(ply, "Run Royale is turned off on this server") end
	if cmd == "create" then
		if G.phase ~= "idle" then return Tell(ply, "a game is already set up: join it") end
		if ROYALE.mode:CantSkate(ply, m, "host") then return end
		local p = Vec(m.pos)
		if not p then return end
		G.phase, G.host, G.players, G.entries, G.keys, G.round = "lobby", ply, {}, {}, {}, 0
		G.start, G.yaw = p, math.NormalizeAngle(tonumber(m.yaw) or 0)
		G.runTime = ROYALE.ClampRun(m.runTime)
		G.bailEnds = m.bailEnds ~= false
		AddPlayer(ply, now)
		Tell(nil, ply:Nick() .. " is hosting Run Royale: join with LB + D-pad left")
	elseif cmd == "join" then
		if G.phase ~= "lobby" then return Tell(ply, G.phase == "idle" and "no game set up: !royale create starts one" or "a game is on: wait for the next one") end
		if ROYALE.mode:CantSkate(ply, m, "play") then return end
		AddPlayer(ply, now)
	elseif cmd == "leave" then
		RemovePlayer(ply, now)
	elseif cmd == "settings" then
		if not host then return Tell(ply, "only the host can change the settings") end
		if G.phase ~= "lobby" then return Tell(ply, "settings can be changed between games") end
		G.runTime = ROYALE.ClampRun(m.runTime or G.runTime)
		Broadcast(now)
		Tell(nil, string.format("%d-second runs", G.runTime))
	elseif cmd == "begin" then
		if not host then return Tell(ply, "only the host can start") end
		if G.phase ~= "lobby" then return end
		Begin(now)
	elseif cmd == "stop" then
		if G.phase == "idle" then return end
		if not (host or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
		if G.phase == "lobby" or m.close then Stop("Run Royale was closed by " .. ply:Nick(), now) else ToLobby(now) Tell(nil, ply:Nick() .. " stopped the game") end
	elseif cmd == "vote" then
		ROYALE.Vote(ply, m.target, now)
	elseif cmd == "score" then
		ROYALE.Score(ply, m.score, now)
	elseif cmd == "bailed" then
		ROYALE.Bailed(ply, m.score, now)
	end
end

function ROYALE.Think(now)
	if G.phase == "idle" then return end
	for i = #(G.players or {}), 1, -1 do
		if not IsValid(G.players[i]) then RemovePlayer(G.players[i], now, true) if G.phase == "idle" then return end end
	end
	if G.deadline and now >= G.deadline then
		if G.phase == "countdown" then return Run(now)
		elseif G.phase == "running" then return Replays(now)
		elseif G.phase == "replays" then
			if G.replayIndex < #G.order then
				G.replayIndex, G.replayAt = G.replayIndex + 1, now
				G.deadline = now + G.runTime + ROYALE.REPLAY_GAP
				return Broadcast(now)
			end
			return Voting(now)
		elseif G.phase == "voting" then return Count(now)
		elseif G.phase == "out" then return Countdown(now)
		elseif G.phase == "results" then return ToLobby(now) end
	end
	if now - (G.lastBroadcast or 0) >= 0.5 then Broadcast(now) end
end

ROYALE.mode:OnThink(function(now) ROYALE.Think(now) end)
ROYALE.mode:OnPlayerLeave(function()
	if G.phase ~= "idle" then timer.Simple(0, function() ROYALE.mode:RunThink(CurTime()) end) end
end)
ROYALE.mode:OnCommand(function(ply, m) ROYALE.Command(ply, m) end)
ROYALE.mode:OnPlayerJoin(function(ply)
	if G.phase ~= "idle" then timer.Simple(3, function() if IsValid(ply) then Broadcast() end end) end
end)
ROYALE.mode:OnDisallowed(function() if G.phase ~= "idle" then Stop("Run Royale was turned off on this server") end end)
