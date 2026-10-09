-- Bullseye, server: the game. Uses only SkateGM.API from the skating add-on.

local BE = BULLSEYE
local S = { phase = "idle" }
BE.session = S
BE.mode:UseSessions(S)

local Allowed, Skating = SKATEGM_MODES.Allowed, SKATEGM_MODES.Skating
local function Tell(ply, text) BE.mode:Tell(ply, text) end
local function Key(ply) return SKATEGM_MODES.Key(ply) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(S.players, ply) end
local function Ent(ply) return IsValid(ply) and ply:EntIndex() or 0 end

local function Public(now)
	local t = { phase = S.phase }
	if S.phase == "idle" then return t end
	t.host = Ent(S.host)
	t.start = { S.start.x, S.start.y, S.start.z }
	t.target = S.target
	t.yaw, t.time, t.rounds, t.round, t.size = S.yaw, S.time, S.rounds, S.round, S.size
	t.width, t.zone = S.width, S.zone
	t.active = Ent(S.active)
	t.nextUp = SKATEGM_MODES.UpNext(S.order, S.index, (S.round or 1) < (S.rounds or 1))
	t.timeLeft = S.deadline and math.max(0, S.deadline - now) or 0
	t.last, t.shots, t.winners = S.last, S.shots, S.winners
	t.players = {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)] or {}
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), total = e.total or 0 }
	end
	return t
end

local function Broadcast(now) BE.mode:Broadcast(Public(now or CurTime()), now) end
BE.Broadcast = Broadcast

local PLAYING = { prep = true, countdown = true, shot = true, finish = true, between = true }
local function Freezes() SKATEGM_MODES.FreezeWatchers(S.players, S.active, PLAYING[S.phase] == true) end

local Go, Results

local function Stop(reason, now)
	for _, p in ipairs(S.players or {}) do if IsValid(p) then p:Freeze(false) end end
	for k in pairs(S) do S[k] = nil end
	S.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
BE.Stop = Stop

local function ToLobby(now)
	S.phase, S.active, S.deadline, S.last, S.shots, S.winners, S.order, S.index, S.round = "lobby", nil, nil, nil, nil, nil, nil, 0, 0
	for _, e in pairs(S.entries) do e.total = 0 end
	Freezes()
	Broadcast(now)
end

function Go(now)
	local p = S.order[S.index]
	if not (IsValid(p) and IndexOf(p)) then return BE.Next(now) end
	S.phase, S.active, S.deadline, S.offSince = "prep", p, now + BE.PREP_TIMEOUT, nil
	Freezes()
	Broadcast(now)
end

function BE.Next(now)
	if #S.players == 0 then return Stop("everyone left: Bullseye is over", now) end
	S.index = S.index + 1
	if S.index > #S.order then
		S.index, S.round = 1, S.round + 1
		S.shots = {}
		if S.round > S.rounds then return Results(now) end
	end
	Go(now)
end

function Results(now)
	local best, winners = -1, {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)]
		if e.total > best then best, winners = e.total, { p:Nick() } elseif e.total == best then winners[#winners + 1] = p:Nick() end
	end
	S.winners = { names = winners, points = math.max(0, best) }
	S.phase, S.active, S.deadline = "results", nil, now + BE.RESULTS
	Freezes()
	Broadcast(now)
	Tell(nil, #winners > 0 and (table.concat(winners, " and ") .. " win" .. (#winners == 1 and "s" or "") .. " with " .. math.max(0, best) .. " points!") or "nobody scored")
end

-- the active player's shot: landed at pos, or bailed / never landed (pos nil)
function BE.Shot(ply, pos, how, now)
	if S.active ~= ply or not PLAYING[S.phase] then return end
	local e = S.entries[Key(ply)]
	local points, ring = 0, nil
	local x, y, z = pos and tonumber(pos[1]), pos and tonumber(pos[2]), pos and tonumber(pos[3])
	if x and y and z and x == x and y == y then
		points, ring = BE.Score(S.target, x, y, S.width)
	else
		x, y, z = nil, nil, nil
	end
	e.total = (e.total or 0) + points
	S.last = { name = ply:Nick(), ent = ply:EntIndex(), points = points, ring = ring, how = how }
	S.shots = S.shots or {}
	if x then S.shots[#S.shots + 1] = { ent = ply:EntIndex(), x = x, y = y, z = z, points = points } end
	S.phase, S.active, S.deadline = "between", nil, now + BE.BETWEEN
	Freezes()
	Broadcast(now)
end

function BE.Tick(now)
	local ph = S.phase
	if ph == "idle" or ph == "lobby" then return end
	if ph == "prep" and now > S.deadline then
		Tell(nil, (IsValid(S.active) and S.active:Nick() or "?") .. " couldn't get into Skater mode in time")
		BE.Shot(S.active, nil, "skipped", now)
	elseif ph == "countdown" and now > S.deadline then
		S.phase, S.deadline = "shot", now + S.time
		Broadcast(now)
	elseif ph == "shot" or ph == "finish" then
		if not Skating(S.active) then
			S.offSince = S.offSince or now
			if now - S.offSince > 1 then return BE.Shot(S.active, nil, "left Skater mode", now) end
		else
			S.offSince = nil
		end
		if now > S.deadline then
			if ph == "shot" then
				S.phase, S.deadline = "finish", now + BE.FINISH
				Broadcast(now)
			else
				BE.Shot(S.active, nil, "out of time", now)
			end
		end
	elseif ph == "between" and now > S.deadline then
		BE.Next(now)
	elseif ph == "results" and now > S.deadline then
		ToLobby(now)
	end
end
BE.mode:OnThink(function(now) BE.Tick(now) end)

function BE.Remove(ply, why, now)
	now = now or CurTime()
	local i = IndexOf(ply)
	if not i then return end
	if IsValid(ply) then ply:Freeze(false) end
	table.remove(S.players, i)
	S.entries[Key(ply)] = nil
	if S.order then
		local k = SKATEGM_MODES.IndexOf(S.order, ply)
		if k then
			table.remove(S.order, k)
			if k <= S.index then S.index = S.index - 1 end
		end
	end
	if #S.players == 0 then return Stop("everyone left: Bullseye is over", now) end
	if S.host == ply then
		S.host = S.players[1]
		Tell(nil, S.host:Nick() .. " is the host now")
	end
	Tell(nil, ply:Nick() .. " " .. why)
	if S.active == ply then
		S.active = nil
		S.last = { name = ply:Nick(), points = 0, how = "left" }
		S.phase, S.deadline = "between", now + 1
	end
	Broadcast(now)
end
BE.mode:OnPlayerLeave(function(ply) BE.Remove(ply, "left the game") end)

local handlers = {}
local function Host(ply) return S.phase ~= "idle" and S.host == ply end

function handlers.create(ply, m, now)
	if S.phase ~= "idle" then return Tell(ply, "a game is already open") end
	if BE.mode:CantSkate(ply, m, "host") then return end
	local target = SKATEGM_MODES.Vec(m.target)
	if not target then return Tell(ply, "place the target first") end
	S.phase, S.host = "lobby", ply
	S.start, S.yaw = SKATEGM_MODES.HostStart(ply, m)
	S.target = target
	S.time, S.rounds = BE.ClampTime(m.time), BE.ClampRounds(m.rounds)
	S.size = (m.size == "small" or m.size == "large") and m.size or BE.SIZE_DEFAULT
	S.width = m.width and BE.ClampWidth(m.width) or BE.RingWidth(S.size)
	S.zone = BE.ClampZone(m.zone)
	S.players, S.entries, S.index, S.round = { ply }, {}, 0, 0
	S.entries[Key(ply)] = { name = ply:Nick(), total = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " is hosting Bullseye: join with LB + D-pad left")
end

function handlers.join(ply, m, now)
	if S.phase == "idle" then return Tell(ply, "no game is open") end
	if S.phase ~= "lobby" then return Tell(ply, "a game is on: wait for the next one") end
	if IndexOf(ply) then return end
	if BE.mode:CantSkate(ply, m, "play") then return end
	S.players[#S.players + 1] = ply
	S.entries[Key(ply)] = { name = ply:Nick(), total = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " joined")
end

function handlers.leave(ply, m, now) BE.Remove(ply, "left the game", now) end

function handlers.begin(ply, m, now)
	if not Host(ply) then return Tell(ply, "only the host can start") end
	if S.phase ~= "lobby" then return end
	S.order = {}
	for i, p in ipairs(S.players) do S.order[i] = p end
	for _, e in pairs(S.entries) do e.total = 0 end
	S.index, S.round, S.shots = 0, 1, {}
	BE.Next(now)
end

function handlers.stop(ply, m, now)
	if S.phase == "idle" then return end
	if not (Host(ply) or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
	if m.close or S.phase == "lobby" then return Stop("Bullseye was closed by " .. ply:Nick(), now) end
	ToLobby(now)
	Tell(nil, ply:Nick() .. " stopped the game")
end

function handlers.ready(ply, m, now)
	if S.phase ~= "prep" or S.active ~= ply then return end
	S.phase, S.deadline = "countdown", now + BE.COUNTDOWN
	Broadcast(now)
end

function handlers.landed(ply, m, now)
	if S.phase ~= "shot" and S.phase ~= "finish" then return end
	if m.nozone then return BE.Shot(ply, nil, "nozone", now) end
	BE.Shot(ply, m.bailed and nil or m.pos, m.bailed and "bailed" or "landed", now)
end

BE.Command = BE.mode:Serve(S, handlers, function(why) BE.Stop(why) end, function() Broadcast() end)
