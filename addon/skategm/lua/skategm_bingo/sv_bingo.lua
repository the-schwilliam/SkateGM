local G = { phase = "idle" }
BINGO.session = G
BINGO.mode:UseSessions(G)

local Allowed, Skating = SKATEGM_MODES.Allowed, SKATEGM_MODES.Skating
local function Tell(ply, text) BINGO.mode:Tell(ply, text) end

local function IndexOf(ply) return SKATEGM_MODES.IndexOf(G.players, ply) end

local function Public(now)
	local t = { phase = G.phase }
	if G.phase == "idle" then return t end
	t.host = IsValid(G.host) and G.host:EntIndex() or 0
	t.card, t.full, t.free, t.time = G.card, G.full, G.free, G.time
	t.timeLeft = G.deadline and math.max(0, G.deadline - now) or 0
	t.players = {}
	for _, p in ipairs(G.players) do
		local e = G.entries[p]
		local marks = {}
		for i in pairs(e.marks) do marks[#marks + 1] = i end
		table.sort(marks)
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), playing = e.playing, marks = marks, count = G.card and BINGO.Count(e.marks, G.card) or 0 }
	end
	t.winner = G.winner
	return t
end

local function Broadcast(now)
	BINGO.mode:Broadcast(Public(now or CurTime()), now)
	G.lastBroadcast = now or CurTime()
end

local function Stop(reason, now)
	for k in pairs(G) do G[k] = nil end
	G.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
BINGO.Stop = Stop

local function ToLobby(now)
	G.phase, G.deadline, G.winner = "lobby", nil, nil
	for _, e in pairs(G.entries) do e.playing, e.marks = nil, {} end
	Broadcast(now)
end

local function Results(now, winner, why)
	G.phase, G.deadline = "results", now + BINGO.RESULTS
	if not winner then
		local best, bestN
		for _, p in ipairs(G.players) do
			local e = G.entries[p]
			if e.playing then
				local n = BINGO.Count(e.marks, G.card)
				if not bestN or n > bestN then best, bestN = p, n end
			end
		end
		winner = best
	end
	G.winner = winner and { name = winner:Nick(), ent = winner:EntIndex() } or nil
	Tell(nil, winner and (winner:Nick() .. " wins Trick Bingo" .. (why and (" (" .. why .. ")") or "")) or "nobody played")
	Broadcast(now)
end

local function AddPlayer(ply, now)
	if IndexOf(ply) then return end
	if #G.players >= BINGO.MAX_PLAYERS then return Tell(ply, "the game is full") end
	G.players[#G.players + 1] = ply
	G.entries[ply] = { name = ply:Nick(), marks = {} }
	Tell(nil, ply:Nick() .. " joined Trick Bingo")
	Broadcast(now)
end

local function RemovePlayer(ply, now)
	local i = IndexOf(ply)
	if not i then return end
	table.remove(G.players, i)
	G.entries[ply] = nil
	if ply == G.host then
		G.host = G.players[1]
		if not IsValid(G.host) then return Stop("the host left: Trick Bingo closed", now) end
		Tell(G.host, "you're the Trick Bingo host now")
	end
	Broadcast(now)
end

function BINGO.Command(ply, m, now)
	now = now or CurTime()
	if type(m) ~= "table" then return end
	local cmd = m.cmd
	local host = G.phase ~= "idle" and ply == G.host
	if not BINGO.Allowed() and cmd ~= "leave" then return Tell(ply, "Trick Bingo is turned off on this server") end
	if cmd == "create" then
		if G.phase ~= "idle" then return Tell(ply, "a game is already set up: join it") end
		if BINGO.mode:CantSkate(ply, m, "host") then return end
		G.phase, G.host, G.players, G.entries = "lobby", ply, {}, {}
		G.time, G.full, G.free = BINGO.ClampTime(m.time), m.full == true, m.free ~= false
		AddPlayer(ply, now)
		Tell(nil, ply:Nick() .. " is hosting Trick Bingo: join with LB + D-pad left")
	elseif cmd == "join" then
		if G.phase == "idle" then return Tell(ply, "no game set up") end
		if BINGO.mode:CantSkate(ply, m, "play") then return end
		AddPlayer(ply, now)
		if G.phase == "playing" and Skating(ply) then G.entries[ply].playing = true Broadcast(now) end
	elseif cmd == "leave" then
		RemovePlayer(ply, now)
	elseif cmd == "begin" then
		if not host then return Tell(ply, "only the host can start") end
		if G.phase ~= "lobby" then return end
		G.card = BINGO.Deal(math.random, G.free)
		for _, p in ipairs(G.players) do
			local e = G.entries[p]
			e.playing, e.marks = Skating(p) or nil, {}
		end
		G.phase, G.deadline, G.winner = "countdown", now + BINGO.COUNTDOWN, nil
		Broadcast(now)
	elseif cmd == "stop" then
		if G.phase == "idle" then return end
		if not (host or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
		if G.phase == "lobby" or m.close then Stop("Trick Bingo was closed by " .. ply:Nick(), now) else ToLobby(now) Tell(nil, ply:Nick() .. " stopped the game") end
	elseif cmd == "done" then
		if G.phase ~= "playing" then return end
		local e = G.entries[ply]
		local i = tonumber(m.cell)
		if not e or not i or i ~= math.floor(i) or not G.card[i] or G.card[i] == "free" or e.marks[i] then return end
		if not e.playing then e.playing = true end
		e.marks[i] = true
		local task = BINGO.BY_ID[G.card[i]]
		Tell(nil, string.format("%s: %s (%d/%d)", ply:Nick(), task and task.label or G.card[i], BINGO.Count(e.marks, G.card), #G.card))
		if BINGO.Won(e.marks, G.card, G.full) then return Results(now, ply, G.full and "full card" or "BINGO") end
		Broadcast(now)
	end
end

function BINGO.Think(now)
	if G.phase == "countdown" and now >= G.deadline then
		G.phase, G.deadline = "playing", now + G.time
		Broadcast(now)
	elseif G.phase == "playing" and now >= G.deadline then
		Results(now, nil, "time's up: most squares")
	elseif G.phase == "results" and now >= G.deadline then
		ToLobby(now)
	end
	if G.phase ~= "idle" and now - (G.lastBroadcast or 0) >= 1 then Broadcast(now) end
end

BINGO.mode:OnThink(function(now) BINGO.Think(now) end)
BINGO.mode:OnCommand(function(ply, m) BINGO.Command(ply, m) end)
BINGO.mode:OnPlayerLeave(function(ply) if G.phase ~= "idle" then RemovePlayer(ply, CurTime()) end end)
BINGO.mode:OnPlayerJoin(function(ply) if G.phase ~= "idle" then timer.Simple(3, function() if IsValid(ply) then Broadcast() end end) end end)
BINGO.mode:OnDisallowed(function() if G.phase ~= "idle" then Stop("Trick Bingo was turned off on this server") end end)
