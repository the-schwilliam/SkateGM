-- Ghost Writer, server: the game. Uses only SkateGM.API from the skating add-on.

local GW = GHOSTWRITER
local S = { phase = "idle" }
GW.session = S
GW.mode:UseSessions(S)

local Allowed = SKATEGM_MODES.Allowed
local function Tell(ply, text) GW.mode:Tell(ply, text) end
local function Key(ply) return SKATEGM_MODES.Key(ply) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(S.players, ply) end
local function Ent(ply) return IsValid(ply) and ply:EntIndex() or 0 end

local function Public(now)
	local t = { phase = S.phase }
	if S.phase == "idle" then return t end
	t.host = Ent(S.host)
	t.start, t.yaw, t.runTime = { S.start.x, S.start.y, S.start.z }, S.yaw, S.runTime
	t.timeLeft = S.deadline and math.max(0, S.deadline - now) or 0
	if S.order and S.replayIndex and (S.phase == "replay" or S.phase == "guess" or S.phase == "reveal") then
		t.replay = { index = S.replayIndex, total = #S.order, ent = S.order[S.replayIndex] }
	end
	t.reveal, t.winners = S.reveal, S.winners
	t.players = {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)] or {}
		local shown = S.phase == "lobby" or S.phase == "reveal" or S.phase == "results"
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), points = shown and (e.points or 0) or nil, inRun = e.inRun or nil,
			guessed = S.guesses and S.guesses[p:EntIndex()] ~= nil or nil }
	end
	return t
end

local function Broadcast(now) GW.mode:Broadcast(Public(now or CurTime()), now) end
GW.Broadcast = Broadcast

local function Stop(reason, now)
	for k in pairs(S) do S[k] = nil end
	S.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
GW.Stop = Stop

local function ToLobby(now)
	S.phase, S.deadline, S.order, S.replayIndex, S.guesses, S.reveal, S.winners, S.kept = "lobby", nil, nil, nil, nil, nil, nil, nil
	for _, e in pairs(S.entries) do e.points, e.inRun = 0, nil end
	Broadcast(now)
end

local function Results(now)
	local best, names = -1, {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)]
		if e.inRun then
			if e.points > best then best, names = e.points, { p:Nick() } elseif e.points == best then names[#names + 1] = p:Nick() end
		end
	end
	S.winners = { names = names, points = math.max(0, best) }
	S.phase, S.deadline = "results", now + GW.RESULTS
	Broadcast(now)
	Tell(nil, #names > 0 and (table.concat(names, " and ") .. " win" .. (#names == 1 and "s" or "") .. " Ghost Writer with " .. best .. " points") or "nobody scored")
end

local function Replay(now)
	S.phase, S.guesses, S.reveal = "replay", nil, nil
	S.deadline = now + S.runTime + GW.REPLAY_GAP
	Broadcast(now)
end

local function Present(ent)
	for _, p in ipairs(S.players) do if p:EntIndex() == ent then return true end end
	return false
end

local NextReveal

local function NextReplay(now)
	S.replayIndex = (S.replayIndex or 0) + 1
	while S.order[S.replayIndex] and not Present(S.order[S.replayIndex]) do S.replayIndex = S.replayIndex + 1 end
	if S.replayIndex > #S.order then
		S.replayIndex = 0
		return NextReveal(now)
	end
	Replay(now)
end

local function Guessers(index)
	local out = {}
	local runner = S.order[index or S.replayIndex]
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)]
		if e.inRun and p:EntIndex() ~= runner then out[#out + 1] = p end
	end
	return out
end

-- the guesses for a run are kept, unseen, until every run has been guessed
local function Keep(now)
	S.kept = S.kept or {}
	S.kept[S.replayIndex] = S.guesses or {}
	S.guesses = nil
	NextReplay(now)
end

-- after the last run: each one in turn, who it was and who got it
local function Reveal(now)
	local runnerEnt = S.order[S.replayIndex]
	local runner
	for _, p in ipairs(S.players) do if p:EntIndex() == runnerEnt then runner = p end end
	local guesses = S.kept and S.kept[S.replayIndex] or {}
	local right, fooled, picks = {}, 0, {}
	for _, p in ipairs(Guessers()) do
		local g = guesses[p:EntIndex()]
		picks[#picks + 1] = { by = p:EntIndex(), target = g or 0 }
		if g == runnerEnt then
			S.entries[Key(p)].points = S.entries[Key(p)].points + 1
			right[#right + 1] = p:Nick()
		else
			fooled = fooled + 1
		end
	end
	if runner then S.entries[Key(runner)].points = S.entries[Key(runner)].points + fooled end
	S.reveal = { name = runner and runner:Nick() or "?", ent = runnerEnt, right = right, fooled = fooled, picks = picks, index = S.replayIndex, total = #S.order }
	S.phase, S.deadline = "reveal", now + GW.REVEAL
	Broadcast(now)
end

function NextReveal(now)
	S.replayIndex = (S.replayIndex or 0) + 1
	while S.order[S.replayIndex] and not Present(S.order[S.replayIndex]) do S.replayIndex = S.replayIndex + 1 end
	if S.replayIndex > #S.order then return Results(now) end
	Reveal(now)
end

function GW.Tick(now)
	local ph = S.phase
	if ph == "idle" or ph == "lobby" then return end
	if ph == "countdown" and now > S.deadline then
		S.phase, S.deadline = "running", now + S.runTime
		Broadcast(now)
	elseif ph == "running" and now > S.deadline then
		NextReplay(now)
	elseif ph == "replay" and now > S.deadline then
		S.phase, S.deadline, S.guesses = "guess", now + GW.GUESS_TIME, {}
		Broadcast(now)
	elseif ph == "guess" then
		local all = true
		for _, p in ipairs(Guessers()) do if S.guesses[p:EntIndex()] == nil then all = false end end
		if now > S.deadline or all then Keep(now) end
	elseif ph == "reveal" and now > S.deadline then
		NextReveal(now)
	elseif ph == "results" and now > S.deadline then
		ToLobby(now)
	end
end
GW.mode:OnThink(function(now) GW.Tick(now) end)

function GW.Remove(ply, why, now)
	now = now or CurTime()
	local i = IndexOf(ply)
	if not i then return end
	table.remove(S.players, i)
	S.entries[Key(ply)] = nil
	for _, g in pairs(S.kept or {}) do g[ply:EntIndex()] = nil end
	if S.guesses then
		S.guesses[ply:EntIndex()] = nil
		for voter, target in pairs(S.guesses) do if target == ply:EntIndex() then S.guesses[voter] = nil end end
	end
	if #S.players == 0 then return Stop("everyone left: Ghost Writer is over", now) end
	if S.host == ply then
		S.host = S.players[1]
		Tell(nil, S.host:Nick() .. " is the host now")
	end
	Tell(nil, ply:Nick() .. " " .. why)
	if S.phase ~= "lobby" and S.phase ~= "results" and #S.players < 2 then return Stop("not enough players left: Ghost Writer is over", now) end
	if S.order and S.order[S.replayIndex] == ply:EntIndex() and (S.phase == "replay" or S.phase == "guess") then
		S.guesses = nil
		return NextReplay(now)
	end
	if S.order and S.order[S.replayIndex] == ply:EntIndex() and S.phase == "reveal" then return NextReveal(now) end
	Broadcast(now)
end
GW.mode:OnPlayerLeave(function(ply) GW.Remove(ply, "left the game") end)

local handlers = {}
local function Host(ply) return S.phase ~= "idle" and S.host == ply end

function handlers.create(ply, m, now)
	if S.phase ~= "idle" then return Tell(ply, "a game is already open") end
	if GW.mode:CantSkate(ply, m, "host") then return end
	S.phase, S.host = "lobby", ply
	S.start, S.yaw = SKATEGM_MODES.HostStart(ply, m)
	S.runTime = GW.ClampRun(m.runTime)
	S.players, S.entries = { ply }, {}
	S.entries[Key(ply)] = { name = ply:Nick(), points = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " is hosting Ghost Writer: join with LB + D-pad left")
end

function handlers.join(ply, m, now)
	if S.phase == "idle" then return Tell(ply, "no game is open") end
	if S.phase ~= "lobby" then return Tell(ply, "a game is on: wait for the next one") end
	if IndexOf(ply) then return end
	if GW.mode:CantSkate(ply, m, "play") then return end
	S.players[#S.players + 1] = ply
	S.entries[Key(ply)] = { name = ply:Nick(), points = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " joined")
end

function handlers.leave(ply, m, now) GW.Remove(ply, "left the game", now) end

function handlers.begin(ply, m, now)
	if not Host(ply) then return Tell(ply, "only the host can start") end
	if S.phase ~= "lobby" then return end
	if #S.players < 3 then return Tell(ply, "Ghost Writer needs at least 3 players") end
	S.order = {}
	for _, p in ipairs(S.players) do
		S.entries[Key(p)].inRun, S.entries[Key(p)].points = true, 0
		S.order[#S.order + 1] = p:EntIndex()
	end
	for i = #S.order, 2, -1 do
		local j = math.random(1, i)
		S.order[i], S.order[j] = S.order[j], S.order[i]
	end
	S.replayIndex = 0
	S.phase, S.deadline = "countdown", now + GW.COUNTDOWN
	Broadcast(now)
end

function handlers.stop(ply, m, now)
	if S.phase == "idle" then return end
	if not (Host(ply) or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
	if m.close or S.phase == "lobby" then return Stop("Ghost Writer was closed by " .. ply:Nick(), now) end
	ToLobby(now)
	Tell(nil, ply:Nick() .. " stopped the game")
end

function handlers.guess(ply, m, now)
	if S.phase ~= "guess" or not IndexOf(ply) then return end
	local target = tonumber(m.target)
	if not target or ply:EntIndex() == S.order[S.replayIndex] or target == ply:EntIndex() then return end
	local ok = false
	for _, p in ipairs(S.players) do if p:EntIndex() == target and S.entries[Key(p)].inRun then ok = true end end
	if not ok then return end
	S.guesses[ply:EntIndex()] = target
	Broadcast(now)
end

GW.Command = GW.mode:Serve(S, handlers, function(why) GW.Stop(why) end, function() Broadcast() end)
