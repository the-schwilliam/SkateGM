-- Imposter, server: the game. Uses only SkateGM.API from the skating add-on.

local S = { phase = "idle" }
IMPOSTER.session = S
IMPOSTER.mode:UseSessions(S)
util.AddNetworkString(IMPOSTER.NET_ROLE)

local Allowed, Skating = SKATEGM_MODES.Allowed, SKATEGM_MODES.Skating
local function Tell(ply, text) IMPOSTER.mode:Tell(ply, text) end
local function Key(ply) return SKATEGM_MODES.Key(ply) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(S.players, ply) end
local function Ent(ply) return IsValid(ply) and ply:EntIndex() or 0 end

---------------------------------------------------------------------------
-- what every client sees (the score and the imposter only in the results)
---------------------------------------------------------------------------
local function Public(now)
	local t = { phase = S.phase }
	if S.phase == "idle" then return t end
	t.host = Ent(S.host)
	t.spot = { S.spot.x, S.spot.y, S.spot.z }
	t.yaw, t.turn, t.difficulty, t.imposterFirst = S.yaw, S.turn, S.difficulty, S.imposterFirst
	t.active = Ent(S.active)
	t.nextUp = SKATEGM_MODES.UpNext(S.order, S.index, false)
	t.index, t.turns = S.index, S.order and #S.order or 0
	t.timeLeft = S.deadline and math.max(0, S.deadline - now) or 0
	t.last = S.last
	t.players = {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)] or {}
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), done = e.done or nil, voted = S.votes and S.votes[p:EntIndex()] ~= nil or nil }
	end
	if S.phase == "results" then t.result = S.result end
	return t
end

local function Broadcast(now)
	IMPOSTER.mode:Broadcast(Public(now or CurTime()), now)
end
IMPOSTER.Broadcast = Broadcast

local function SendRole(ply)
	if not IsValid(ply) or not S.imposter then return end
	local imposter = ply == S.imposter
	net.Start(IMPOSTER.NET_ROLE)
	net.WriteBool(imposter)
	net.WriteUInt(imposter and 0 or S.target, 32)
	net.Send(ply)
end
IMPOSTER.SendRole = SendRole

local PLAYING = { prep = true, countdown = true, turn = true, finish = true, between = true, vote = true }
local function Freezes() SKATEGM_MODES.FreezeWatchers(S.players, S.active, PLAYING[S.phase] == true) end

---------------------------------------------------------------------------
-- flow
---------------------------------------------------------------------------
local StartTurn, NextTurn, EndTurn, Results

local function Stop(reason, now)
	for _, p in ipairs(S.players or {}) do if IsValid(p) then p:Freeze(false) end end
	for k in pairs(S) do S[k] = nil end
	S.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
IMPOSTER.Stop = Stop

local function ToLobby(now)
	S.phase, S.active, S.deadline, S.order, S.index, S.votes, S.result, S.last = "lobby", nil, nil, nil, 0, nil, nil, nil
	S.imposter, S.target = nil, nil
	for _, e in pairs(S.entries) do e.done, e.score, e.how = nil, nil, nil end
	Freezes()
	Broadcast(now)
end

function StartTurn(now)
	local p = S.order[S.index]
	if not IsValid(p) or not IndexOf(p) then return NextTurn(now) end
	S.phase, S.active, S.deadline = "prep", p, now + IMPOSTER.PREP_TIMEOUT
	S.offSince = nil
	Freezes()
	Broadcast(now)
end

local function StartVote(now)
	S.phase, S.active, S.deadline, S.votes = "vote", nil, now + IMPOSTER.VOTE_TIME, {}
	Freezes()
	Broadcast(now)
	Tell(nil, "who didn't know the score? vote them out!")
end

function NextTurn(now)
	if #S.players < 2 then return Stop("not enough players left: Impostor is over", now) end
	S.index = S.index + 1
	if S.index > #S.order then return StartVote(now) end
	StartTurn(now)
end

function EndTurn(now, score, how)
	local p = S.active
	if IsValid(p) then
		local e = S.entries[Key(p)]
		if e then e.done, e.score, e.how = true, math.Clamp(math.floor(score or 0), 0, IMPOSTER.MAX_SCORE), how end
	end
	S.last = { name = IsValid(p) and p:Nick() or "?", ent = IsValid(p) and p:EntIndex() or nil }
	S.phase, S.active, S.deadline = "between", nil, now + IMPOSTER.BETWEEN
	Freezes()
	Broadcast(now)
end

function Results(now, why)
	local out, count = IMPOSTER.Tally(S.votes or {})
	local imposterEnt = Ent(S.imposter)
	local r = { imposter = imposterEnt, imposterName = S.imposterName, target = S.target, out = out, why = why, lines = {}, votes = {} }
	r.crewWin = out ~= nil and out == imposterEnt
	for key, e in pairs(S.entries) do
		if e.done then r.lines[#r.lines + 1] = { name = e.name, score = e.score, how = e.how, imposter = key == S.imposterKey or nil } end
	end
	table.sort(r.lines, function(a, b) return math.abs(a.score - S.target) < math.abs(b.score - S.target) end)
	for ent, n in pairs(count) do r.votes[#r.votes + 1] = { ent = ent, n = n } end
	table.sort(r.votes, function(a, b) return a.n > b.n end)
	for _, l in ipairs(r.lines) do if not l.imposter then r.closest = l.name break end end
	S.result = r
	S.phase, S.active, S.deadline = "results", nil, now + IMPOSTER.RESULTS
	Freezes()
	Broadcast(now)
	if why then Tell(nil, why) end
	Tell(nil, string.format("%s was the impostor: %s", S.imposterName or "?", r.crewWin and "caught!" or "they got away with it"))
end
IMPOSTER.Results = Results

local function AllVoted()
	for _, p in ipairs(S.players) do if S.votes[p:EntIndex()] == nil then return false end end
	return true
end

function IMPOSTER.Tick(now)
	local ph = S.phase
	if ph == "idle" or ph == "lobby" then return end
	if ph == "prep" and now > S.deadline then
		Tell(nil, (IsValid(S.active) and S.active:Nick() or "?") .. " couldn't get into Skater mode in time: skipped")
		EndTurn(now, 0, "skipped")
	elseif ph == "countdown" and now > S.deadline then
		S.phase, S.deadline = "turn", now + S.turn
		Broadcast(now)
	elseif ph == "turn" or ph == "finish" then
		if not Skating(S.active) then
			S.offSince = S.offSince or now
			if now - S.offSince > 1 then return EndTurn(now, 0, "left Skater mode") end
		else
			S.offSince = nil
		end
		if now > S.deadline then
			if ph == "turn" then
				S.phase, S.deadline = "finish", now + IMPOSTER.FINISH
				Broadcast(now)
			else
				EndTurn(now, 0, "out of time")
			end
		end
	elseif ph == "between" and now > S.deadline then
		NextTurn(now)
	elseif ph == "vote" and (now > S.deadline or AllVoted()) then
		Results(now)
	elseif ph == "results" and now > S.deadline then
		ToLobby(now)
	end
end
IMPOSTER.mode:OnThink(function(now) IMPOSTER.Tick(now) end)

---------------------------------------------------------------------------
-- players leaving
---------------------------------------------------------------------------
function IMPOSTER.Remove(ply, why, now)
	now = now or CurTime()
	local i = IndexOf(ply)
	if not i then return end
	if IsValid(ply) then ply:Freeze(false) end
	table.remove(S.players, i)
	local key = Key(ply)
	local playing = PLAYING[S.phase] == true
	if not playing then S.entries[key] = nil end
	if #S.players == 0 then return Stop("everyone left: Impostor is over", now) end
	if S.host == ply then
		S.host = S.players[1]
		Tell(nil, S.host:Nick() .. " is the host now")
	end
	Tell(nil, ply:Nick() .. " " .. why)
	if S.votes then
		S.votes[ply:EntIndex()] = nil
		for voter, target in pairs(S.votes) do if target == ply:EntIndex() then S.votes[voter] = nil end end
	end
	if playing and ply == S.imposter then return Results(now, "the impostor left") end
	if playing and #S.players < 2 then return Stop("not enough players left: Impostor is over", now) end
	if ply == S.active and (S.phase == "prep" or S.phase == "countdown" or S.phase == "turn" or S.phase == "finish") then
		S.active = nil
		S.phase, S.deadline = "between", now + 1
		S.last = { name = ply:Nick() }
	end
	Broadcast(now)
end
IMPOSTER.mode:OnPlayerLeave(function(ply) IMPOSTER.Remove(ply, "left the game") end)

---------------------------------------------------------------------------
-- commands
---------------------------------------------------------------------------
local handlers = {}
local function Host(ply) return S.phase ~= "idle" and S.host == ply end
local function NewEntry(ply) S.entries[Key(ply)] = { name = ply:Nick() } end

function handlers.create(ply, m, now)
	if S.phase ~= "idle" then return Tell(ply, "a game is already open") end
	if IMPOSTER.mode:CantSkate(ply, m, "host") then return end
	S.phase, S.host = "lobby", ply
	S.spot, S.yaw = SKATEGM_MODES.HostStart(ply, m)
	S.turn = IMPOSTER.ClampTurn(m.turn)
	S.difficulty = IMPOSTER.Difficulty(m.difficulty)[1]
	S.imposterFirst = m.imposterFirst == true
	S.players, S.entries, S.index = { ply }, {}, 0
	NewEntry(ply)
	Broadcast(now)
	Tell(nil, ply:Nick() .. " is hosting Impostor: join with LB + D-pad left")
end

function handlers.join(ply, m, now)
	if S.phase == "idle" then return Tell(ply, "no game is open") end
	if S.phase ~= "lobby" then return Tell(ply, "a game is on: wait for the next one") end
	if IndexOf(ply) then return end
	if IMPOSTER.mode:CantSkate(ply, m, "play") then return end
	S.players[#S.players + 1] = ply
	NewEntry(ply)
	Broadcast(now)
	Tell(nil, ply:Nick() .. " joined")
end

function handlers.leave(ply, m, now) IMPOSTER.Remove(ply, "left the game", now) end

function handlers.begin(ply, m, now)
	if not Host(ply) then return Tell(ply, "only the host can start") end
	if S.phase ~= "lobby" then return end
	if #S.players < IMPOSTER.MIN_PLAYERS then return Tell(ply, string.format("Impostor needs at least %d players", IMPOSTER.MIN_PLAYERS)) end
	S.imposter = S.players[math.random(1, #S.players)]
	S.imposterKey, S.imposterName = Key(S.imposter), S.imposter:Nick()
	S.target = IMPOSTER.PickTarget(S.difficulty)
	S.order = IMPOSTER.Order(S.players, S.imposter, S.imposterFirst)
	S.index = 1
	for _, e in pairs(S.entries) do e.done, e.score, e.how = nil, nil, nil end
	for _, p in ipairs(S.players) do SendRole(p) end
	StartTurn(now)
end

function handlers.stop(ply, m, now)
	if S.phase == "idle" then return end
	if not (Host(ply) or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
	if m.close or S.phase == "lobby" then return Stop("Impostor was closed by " .. ply:Nick(), now) end
	ToLobby(now)
	Tell(nil, ply:Nick() .. " stopped the game")
end

function handlers.ready(ply, m, now)
	if S.phase ~= "prep" or S.active ~= ply then return end
	S.phase, S.deadline = "countdown", now + IMPOSTER.COUNTDOWN
	Broadcast(now)
end

function handlers.landed(ply, m, now)
	if S.active ~= ply or (S.phase ~= "turn" and S.phase ~= "finish") then return end
	local how = m.how == "bail" and "bailed" or (m.how == "none" and "no line" or "landed")
	EndTurn(now, how == "landed" and tonumber(m.score) or 0, how)
end

function handlers.vote(ply, m, now)
	if S.phase ~= "vote" or not IndexOf(ply) then return end
	local target = tonumber(m.target)
	if not target or target == ply:EntIndex() then return end
	local ok = false
	for _, p in ipairs(S.players) do if p:EntIndex() == target then ok = true end end
	if not ok then return end
	S.votes[ply:EntIndex()] = target
	Broadcast(now)
end

function handlers.role(ply, m, now)
	if PLAYING[S.phase] and IndexOf(ply) then SendRole(ply) end
end

IMPOSTER.Command = IMPOSTER.mode:Serve(S, handlers, function(why) IMPOSTER.Stop(why) end, function() Broadcast() end)
