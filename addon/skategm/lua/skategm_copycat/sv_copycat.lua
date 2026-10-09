-- Copycat, server: the game. Uses only SkateGM.API from the skating add-on.
-- The lines are judged here from where each skater's hips were (SkateGMHips).

local CC = COPYCAT
local S = { phase = "idle" }
CC.session = S
CC.mode:UseSessions(S)

local Allowed = SKATEGM_MODES.Allowed
local function Tell(ply, text) CC.mode:Tell(ply, text) end
local function Key(ply) return SKATEGM_MODES.Key(ply) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(S.players, ply) end
local function Ent(ply) return IsValid(ply) and ply:EntIndex() or 0 end

local function PlayerOf(ent)
	for _, p in ipairs(S.players or {}) do if p:EntIndex() == ent then return p end end
end

local function Rounded(path)
	local out = {}
	for i, p in ipairs(path or {}) do out[i] = { math.floor(p[1] + 0.5), math.floor(p[2] + 0.5), math.floor(p[3] + 0.5) } end
	return out
end

local SHOWING = { replay = true, score = true }

local function Public(now)
	local t = { phase = S.phase }
	if S.phase == "idle" then return t end
	t.host = Ent(S.host)
	t.start, t.yaw, t.runTime, t.judging = { S.start.x, S.start.y, S.start.z }, S.yaw, S.runTime, S.judging
	t.timeLeft = S.deadline and math.max(0, S.deadline - now) or 0
	t.leader = S.leader
	t.round = S.lead and { index = S.lead, total = #S.order } or nil
	t.copiers = S.copiers
	if SHOWING[S.phase] and S.copiers and S.replayIndex then
		local ent = S.copiers[S.replayIndex]
		t.replay = { index = S.replayIndex, total = #S.copiers, ent = ent }
		t.paths = { lead = Rounded(S.paths[S.leader]), copy = Rounded(S.paths[ent]) }
	end
	t.last, t.winners = S.last, S.winners
	t.players = {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)] or {}
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), points = e.points or 0, playing = e.playing or nil }
	end
	return t
end

local function Broadcast(now) CC.mode:Broadcast(Public(now or CurTime()), now) end
CC.Broadcast = Broadcast

local function Stop(reason, now)
	for k in pairs(S) do S[k] = nil end
	S.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
CC.Stop = Stop

local function ToLobby(now)
	S.phase, S.deadline, S.order, S.lead, S.leader, S.copiers, S.replayIndex, S.paths, S.scores, S.last, S.winners =
		"lobby", nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
	for _, e in pairs(S.entries) do e.points, e.playing = 0, nil end
	Broadcast(now)
end

local function Results(now)
	local best, names = -1, {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)]
		if e.playing then
			if e.points > best then best, names = e.points, { p:Nick() } elseif e.points == best then names[#names + 1] = p:Nick() end
		end
	end
	S.winners = { names = names, points = math.max(0, best) }
	S.phase, S.deadline, S.leader, S.copiers, S.replayIndex = "results", now + CC.RESULTS, nil, nil, nil
	Broadcast(now)
	Tell(nil, #names > 0 and (table.concat(names, " and ") .. " win" .. (#names == 1 and "s" or "") .. " Copycat with " .. best .. " points") or "nobody scored")
end

local NextLeader

local function Sample(ents, now)
	if now < (S.nextSample or 0) or now < (S.sampleFrom or 0) then return end
	S.nextSample = now + CC.SAMPLE
	for _, ent in ipairs(ents) do
		local p = PlayerOf(ent)
		local at = IsValid(p) and p.SkateGMHips
		if at then
			local path = S.paths[ent] or {}
			path[#path + 1] = { at.x, at.y, at.z }
			S.paths[ent] = path
		end
	end
end

local function Judge()
	S.scores = {}
	for _, ent in ipairs(S.copiers) do S.scores[ent] = CC.Match(S.paths[S.leader], S.paths[ent], S.judging) end
end

local function NextReplay(now)
	S.replayIndex = (S.replayIndex or 0) + 1
	while S.copiers[S.replayIndex] and not PlayerOf(S.copiers[S.replayIndex]) do S.replayIndex = S.replayIndex + 1 end
	if S.replayIndex > #S.copiers then return NextLeader(now) end
	S.phase, S.deadline, S.last = "replay", now + (S.lineTime or S.runTime) + CC.REPLAY_GAP, nil
	Broadcast(now)
end

local function Score(now)
	local ent = S.copiers[S.replayIndex]
	local p = PlayerOf(ent)
	local pct = S.scores[ent] or 0
	if p then S.entries[Key(p)].points = S.entries[Key(p)].points + pct end
	S.last = { ent = ent, name = p and p:Nick() or "?", points = pct }
	S.phase, S.deadline = "score", now + CC.SCORE
	Broadcast(now)
end

function NextLeader(now)
	S.lead = (S.lead or 0) + 1
	while S.order[S.lead] and not PlayerOf(S.order[S.lead]) do S.lead = S.lead + 1 end
	if S.lead > #S.order then return Results(now) end
	S.leader = S.order[S.lead]
	S.copiers = {}
	for _, p in ipairs(S.players) do
		if S.entries[Key(p)].playing and p:EntIndex() ~= S.leader then S.copiers[#S.copiers + 1] = p:EntIndex() end
	end
	S.paths, S.scores, S.replayIndex, S.last = {}, {}, nil, nil
	S.phase, S.deadline = "leadcount", now + CC.COUNTDOWN
	Broadcast(now)
	local lp = PlayerOf(S.leader)
	Tell(nil, (lp and lp:Nick() or "?") .. " sets the line: watch closely")
end

-- the setter's line is over (its time, or a bail): the copies get as long
-- as the line took
function CC.EndLead(now, bailed)
	S.lineTime = math.max(CC.MIN_LINE, math.min(S.runTime, now - (S.leadStart or now)))
	S.phase, S.deadline = "copycount", now + CC.COUNTDOWN
	Broadcast(now)
	local lp = PlayerOf(S.leader)
	Tell(nil, (bailed and ((lp and lp:Nick() or "?") .. " bailed: that's the line. ") or "") .. "your turn: copy that line")
end

function CC.Tick(now)
	local ph = S.phase
	if ph == "idle" or ph == "lobby" then return end
	if ph == "leadcount" and now > S.deadline then
		S.phase, S.deadline, S.nextSample, S.sampleFrom = "lead", now + S.runTime, nil, now + CC.SETTLE
		S.leadStart, S.lineTime = now, S.runTime
		Broadcast(now)
	elseif ph == "lead" then
		Sample({ S.leader }, now)
		if now > S.deadline then CC.EndLead(now) end
	elseif ph == "copycount" and now > S.deadline then
		S.phase, S.deadline, S.nextSample, S.sampleFrom = "copy", now + S.lineTime, nil, now + CC.SETTLE
		Broadcast(now)
	elseif ph == "copy" then
		Sample(S.copiers, now)
		if now > S.deadline then
			Judge()
			NextReplay(now)
		end
	elseif ph == "replay" and now > S.deadline then
		Score(now)
	elseif ph == "score" and now > S.deadline then
		NextReplay(now)
	elseif ph == "results" and now > S.deadline then
		ToLobby(now)
	end
end
CC.mode:OnThink(function(now) CC.Tick(now) end)

function CC.Remove(ply, why, now)
	now = now or CurTime()
	local i = IndexOf(ply)
	if not i then return end
	local ent = ply:EntIndex()
	table.remove(S.players, i)
	S.entries[Key(ply)] = nil
	if #S.players == 0 then return Stop("everyone left: Copycat is over", now) end
	if S.host == ply then
		S.host = S.players[1]
		Tell(nil, S.host:Nick() .. " is the host now")
	end
	Tell(nil, ply:Nick() .. " " .. why)
	local inGame = S.phase ~= "lobby" and S.phase ~= "results"
	if inGame and #S.players < 2 then return Stop("not enough players left: Copycat is over", now) end
	if S.copiers then
		local k = SKATEGM_MODES.IndexOf(S.copiers, ent)
		if k and not SHOWING[S.phase] then table.remove(S.copiers, k) end
	end
	if inGame and S.leader == ent then return NextLeader(now) end
	if SHOWING[S.phase] and S.copiers[S.replayIndex] == ent then return NextReplay(now) end
	Broadcast(now)
end
CC.mode:OnPlayerLeave(function(ply) CC.Remove(ply, "left the game") end)

local handlers = {}
local function Host(ply) return S.phase ~= "idle" and S.host == ply end

function handlers.create(ply, m, now)
	if S.phase ~= "idle" then return Tell(ply, "a game is already open") end
	if CC.mode:CantSkate(ply, m, "host") then return end
	S.phase, S.host = "lobby", ply
	S.start, S.yaw = SKATEGM_MODES.HostStart(ply, m)
	S.runTime, S.judging = CC.ClampRun(m.runTime), CC.Judging(m.judging)
	S.players, S.entries = { ply }, {}
	S.entries[Key(ply)] = { name = ply:Nick(), points = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " is hosting Copycat: join with LB + D-pad left")
end

function handlers.join(ply, m, now)
	if S.phase == "idle" then return Tell(ply, "no game is open") end
	if S.phase ~= "lobby" then return Tell(ply, "a game is on: wait for the next one") end
	if IndexOf(ply) then return end
	if CC.mode:CantSkate(ply, m, "play") then return end
	S.players[#S.players + 1] = ply
	S.entries[Key(ply)] = { name = ply:Nick(), points = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " joined")
end

function handlers.leave(ply, m, now) CC.Remove(ply, "left the game", now) end

function handlers.begin(ply, m, now)
	if not Host(ply) then return Tell(ply, "only the host can start") end
	if S.phase ~= "lobby" then return end
	if #S.players < 2 then return Tell(ply, "Copycat needs at least 2 players") end
	S.order = {}
	for _, p in ipairs(S.players) do
		S.entries[Key(p)].playing, S.entries[Key(p)].points = true, 0
		S.order[#S.order + 1] = p:EntIndex()
	end
	S.lead = 0
	NextLeader(now)
end

-- the setter bailed: their line ends there
function handlers.bailed(ply, m, now)
	if S.phase ~= "lead" or not IsValid(ply) or ply:EntIndex() ~= S.leader then return end
	CC.EndLead(now, true)
end

function handlers.stop(ply, m, now)
	if S.phase == "idle" then return end
	if not (Host(ply) or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
	if m.close or S.phase == "lobby" then return Stop("Copycat was closed by " .. ply:Nick(), now) end
	ToLobby(now)
	Tell(nil, ply:Nick() .. " stopped the game")
end

CC.Command = CC.mode:Serve(S, handlers, function(why) CC.Stop(why) end, function() Broadcast() end)
