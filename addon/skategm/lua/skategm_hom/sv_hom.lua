local S = { phase = "idle" }
HOM.session = S
HOM.mode:UseSessions(S)

local Allowed, Skating = SKATEGM_MODES.Allowed, SKATEGM_MODES.Skating
local function Tell(ply, text) HOM.mode:Tell(ply, text) end

local function IndexOf(ply) return SKATEGM_MODES.IndexOf(S.players, ply) end

local Num = SKATEGM_MODES.Num

local function Public(now)
	local t = { phase = S.phase }
	if S.phase == "idle" then return t end
	t.host = IsValid(S.host) and S.host:EntIndex() or 0
	t.spot, t.yaw = S.spot, S.yaw
	t.turn, t.rounds, t.round, t.pain = S.turn, S.rounds, S.round, S.pain
	t.active = IsValid(S.active) and S.active:EntIndex() or 0
	t.nextUp = SKATEGM_MODES.UpNext(S.players, S.index, (S.round or 1) < (S.rounds or 1))
	t.timeLeft = S.deadline and math.max(0, S.deadline - now) or 0
	t.live = S.live
	t.bailing = S.bailing
	t.last = S.last
	t.winner = S.winner
	t.players = {}
	for _, p in ipairs(S.players) do
		local e = S.entries[p]
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), best = e.best, turns = #e.turns }
	end
	return t
end

local function Broadcast(now)
	HOM.mode:Broadcast(Public(now or CurTime()), now)
	S.lastBroadcast = now or CurTime()
end

local StartTurn, NextTurn, EndTurn

local function Stop(reason, now)
	for k in pairs(S) do S[k] = nil end
	S.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
HOM.Stop = Stop

local function Final(now)
	S.phase, S.active, S.deadline = "final", nil, now + HOM.FINAL
	local best, who = -1, nil
	for _, p in ipairs(S.players) do
		local e = S.entries[p]
		if #e.turns > 0 and e.best > best then best, who = e.best, p end
	end
	S.winner = who and { name = who:Nick(), score = best } or nil
	Broadcast(now)
	Tell(nil, who and string.format("%s takes the Hall of Meat with %s!", who:Nick(), HOM.Commas(best)) or "nobody bailed")
end

function StartTurn(now)
	local p = S.players[S.index]
	if not IsValid(p) then return NextTurn(now) end
	S.phase, S.active, S.deadline, S.live, S.offSince, S.bailing = "prep", p, now + HOM.PREP_TIMEOUT, { score = 0, injuries = {} }, nil, nil
	Broadcast(now)
end

function NextTurn(now)
	if #S.players == 0 then return Stop("everyone left: Hall of Meat is over", now) end
	S.index = S.index + 1
	if S.index > #S.players then
		S.index = 1
		S.round = S.round + 1
		if S.round > S.rounds then return Final(now) end
	end
	StartTurn(now)
end

function EndTurn(now, result, reason)
	local p = S.active
	if IsValid(p) and S.entries[p] then
		local e = S.entries[p]
		local score = result and math.Clamp(math.floor(tonumber(result.score) or 0), 0, HOM.MAX_SCORE) or 0
		e.turns[#e.turns + 1] = score
		e.best = math.max(e.best, score)
		S.last = { name = p:Nick(), ent = p:EntIndex(), score = score, reason = reason, damage = result and tonumber(result.damage) or 0, air = result and tonumber(result.air) or 0, bonus = result and tonumber(result.bonus) or 0, injuries = result and result.injuries or {} }
		if result then Tell(nil, string.format("%s: %s", p:Nick(), HOM.Commas(score))) end
	end
	S.phase, S.deadline, S.active = "between", now + HOM.BETWEEN, nil
	Broadcast(now)
end

local function SafeInjuries(list)
	local out = {}
	if type(list) ~= "table" then return out end
	for i = 1, math.min(#list, #HOM.PARTS) do
		local inj = list[i]
		if type(inj) == "table" and HOM.PART[inj.part] then
			out[#out + 1] = { part = inj.part, level = math.Clamp(math.floor(tonumber(inj.level) or 0), 1, #HOM.LEVELS) }
		end
	end
	return out
end

local function AddPlayer(ply, now)
	if IndexOf(ply) then return end
	if #S.players >= HOM.MAX_PLAYERS then return Tell(ply, "the game is full") end
	S.players[#S.players + 1] = ply
	S.entries[ply] = { name = ply:Nick(), best = 0, turns = {} }
	Tell(nil, ply:Nick() .. " joined Hall of Meat")
	Broadcast(now)
end

local function RemovePlayer(ply, now)
	local i = IndexOf(ply)
	if not i then return end
	local wasActive = S.active == ply
	table.remove(S.players, i)
	S.entries[ply] = nil
	if S.index and i <= S.index then S.index = S.index - 1 end
	if ply == S.host then
		S.host = S.players[1]
		if not IsValid(S.host) then return Stop("the host left: Hall of Meat closed", now) end
		Tell(S.host, "you're the Hall of Meat host now")
	end
	if wasActive then S.active = nil S.phase, S.deadline = "between", now + 1 end
	Broadcast(now)
end

function HOM.Command(ply, m, now)
	now = now or CurTime()
	if type(m) ~= "table" then return end
	local cmd = m.cmd
	local host = S.phase ~= "idle" and ply == S.host
	if not HOM.Allowed() and cmd ~= "leave" then return Tell(ply, "Hall of Meat is turned off on this server") end
	if cmd == "create" then
		if S.phase ~= "idle" then return Tell(ply, "a game is already set up: join it") end
		if HOM.mode:CantSkate(ply, m, "host") then return end
		local x, y, z = Num(m.x), Num(m.y), Num(m.z)
		if not (x and y and z) then return end
		S.phase, S.host, S.players, S.entries = "lobby", ply, {}, {}
		S.spot, S.yaw = { x, y, z }, tonumber(m.yaw) or 0
		S.turn, S.rounds, S.round, S.index = HOM.ClampTurn(m.turn), HOM.ClampRounds(m.rounds), 1, 0
		S.pain = HOM.PainScale(m.pain)
		AddPlayer(ply, now)
		Tell(nil, ply:Nick() .. " is hosting Hall of Meat: join with LB + D-pad left")
	elseif cmd == "join" then
		if S.phase == "idle" or S.phase == "final" then return Tell(ply, "no game to join") end
		if HOM.mode:CantSkate(ply, m, "play") then return end
		AddPlayer(ply, now)
	elseif cmd == "leave" then
		RemovePlayer(ply, now)
	elseif cmd == "begin" then
		if not host then return Tell(ply, "only the host can start") end
		if S.phase ~= "lobby" then return end
		S.round, S.index = 1, 0
		for _, p in ipairs(S.players) do S.entries[p].best, S.entries[p].turns = 0, {} end
		NextTurn(now)
	elseif cmd == "stop" then
		if S.phase == "idle" then return end
		if not (host or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
		if S.phase == "lobby" or m.close then return Stop("Hall of Meat was closed by " .. ply:Nick(), now) end
		for _, p in ipairs(S.players) do if IsValid(p) then p:Freeze(false) end end
		S.phase, S.active, S.deadline, S.live, S.last, S.winner, S.round, S.index = "lobby", nil, nil, nil, nil, nil, 1, 0
		Broadcast(now)
		Tell(nil, ply:Nick() .. " stopped the game: back to the lobby")
	elseif cmd == "ready" then
		if S.phase ~= "prep" or ply ~= S.active then return end
		S.phase, S.deadline = "countdown", now + HOM.COUNTDOWN
		Broadcast(now)
	elseif cmd == "bailing" then
		-- the bail has started in time: no more clock, it runs till it's over
		if S.phase ~= "turn" or ply ~= S.active or S.bailing then return end
		S.bailing, S.deadline = true, now + HOM.BAIL_CAP
		Broadcast(now)
	elseif cmd == "injury" then
		if S.phase ~= "turn" or ply ~= S.active then return end
		local inj = SafeInjuries({ m })
		if inj[1] then
			S.live.injuries[#S.live.injuries + 1] = inj[1]
			S.live.score = math.Clamp(math.floor(tonumber(m.score) or S.live.score), 0, HOM.MAX_SCORE)
			S.live.at = now
			Broadcast(now)
		end
	elseif cmd == "result" then
		if S.phase ~= "turn" or ply ~= S.active then return end
		EndTurn(now, { score = m.score, damage = Num(m.damage), air = Num(m.air), bonus = Num(m.bonus), injuries = SafeInjuries(m.injuries) }, "bail")
	end
end

function HOM.Think(now)
	local ph = S.phase
	if ph == "idle" or ph == "lobby" then return end
	if ph == "prep" and now > S.deadline then
		Tell(nil, (IsValid(S.active) and S.active:Nick() or "?") .. " couldn't get into Skater mode in time: skipped")
		EndTurn(now, nil, "skipped")
	elseif ph == "countdown" and now > S.deadline then
		S.phase, S.deadline = "turn", now + S.turn
		Broadcast(now)
	elseif ph == "turn" then
		if not Skating(S.active) then
			S.offSince = S.offSince or now
			if now - S.offSince > 1 then return EndTurn(now, nil, "left Skater mode") end
		else
			S.offSince = nil
		end
		if now > S.deadline then
			if S.bailing then return EndTurn(now, { score = S.live.score, injuries = S.live.injuries }, "bail") end
			return EndTurn(now, nil, "no bail in time")
		end
	elseif ph == "between" and now > S.deadline then
		NextTurn(now)
	elseif ph == "final" and now > S.deadline then
		Stop(nil, now)
	end
	if S.phase ~= "idle" and now - (S.lastBroadcast or 0) > 0.5 then Broadcast(now) end
end

HOM.mode:OnThink(function(now) HOM.Think(now) end)
HOM.mode:OnCommand(function(ply, m) HOM.Command(ply, m) end)
HOM.mode:OnPlayerLeave(function(ply) if S.phase ~= "idle" then RemovePlayer(ply, CurTime()) end end)
HOM.mode:OnPlayerJoin(function(ply) if S.phase ~= "idle" then timer.Simple(3, function() if IsValid(ply) then Broadcast() end end) end end)
HOM.mode:OnDisallowed(function() if S.phase ~= "idle" then Stop("Hall of Meat was turned off on this server") end end)
