-- Basketboard, server: the game. Uses only SkateGM.API from the skating add-on.

local BB = BASKETBOARD
local S = { phase = "idle" }
BB.session = S
BB.mode:UseSessions(S)

local Allowed, Skating = SKATEGM_MODES.Allowed, SKATEGM_MODES.Skating
local function Tell(ply, text) BB.mode:Tell(ply, text) end
local function Key(ply) return SKATEGM_MODES.Key(ply) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(S.players, ply) end
local function Ent(ply) return IsValid(ply) and ply:EntIndex() or 0 end

local function Public(now)
	local t = { phase = S.phase }
	if S.phase == "idle" then return t end
	t.host = Ent(S.host)
	t.start = { S.start.x, S.start.y, S.start.z }
	t.hoop, t.ground = S.hoop, S.ground
	t.yaw, t.time, t.rounds, t.round, t.size, t.height, t.facing, t.turn = S.yaw, S.time, S.rounds, S.round, S.size, S.height, S.facing, S.turn
	t.radius, t.zone = S.radius, S.zone
	t.active = Ent(S.active)
	t.nextUp = SKATEGM_MODES.UpNext(S.order, S.index, (S.round or 1) < (S.rounds or 1))
	t.timeLeft = S.deadline and math.max(0, S.deadline - now) or 0
	t.last, t.winners = S.last, S.winners
	t.players = {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)] or {}
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), total = e.total or 0 }
	end
	return t
end

local function Broadcast(now) BB.mode:Broadcast(Public(now or CurTime()), now) end
BB.Broadcast = Broadcast

local PLAYING = { prep = true, countdown = true, turn = true, finish = true, between = true }
local function Freezes() SKATEGM_MODES.FreezeWatchers(S.players, S.active, PLAYING[S.phase] == true) end

local Go, Results

local function Stop(reason, now)
	for _, p in ipairs(S.players or {}) do if IsValid(p) then p:Freeze(false) end end
	for k in pairs(S) do S[k] = nil end
	S.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
BB.Stop = Stop

local function ToLobby(now)
	S.phase, S.active, S.deadline, S.last, S.winners, S.order, S.index, S.round = "lobby", nil, nil, nil, nil, nil, 0, 0
	for _, e in pairs(S.entries) do e.total = 0 end
	Freezes()
	Broadcast(now)
end

function Go(now)
	local p = S.order[S.index]
	if not (IsValid(p) and IndexOf(p)) then return BB.Next(now) end
	S.phase, S.active, S.deadline, S.offSince = "prep", p, now + BB.PREP_TIMEOUT, nil
	Freezes()
	Broadcast(now)
end

function BB.Next(now)
	if #S.players == 0 then return Stop("everyone left: Basketboard is over", now) end
	S.index = S.index + 1
	if S.index > #S.order then
		S.index, S.round = 1, S.round + 1
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
	if best <= 0 then winners = {} end
	S.winners = { names = winners, points = math.max(0, best) }
	S.phase, S.active, S.deadline = "results", nil, now + BB.RESULTS
	Freezes()
	Broadcast(now)
	Tell(nil, #winners > 0 and (table.concat(winners, " and ") .. " win" .. (#winners == 1 and "s" or "") .. " with " .. best .. " basket" .. (best == 1 and "" or "s") .. "!") or "nobody scored")
end

-- the active player's turn is over: how = "basket" (the board went in),
-- "player" (the skater did), "miss", "skipped", "out of time", "left"
BB.SCORING = { basket = true, player = true }
function BB.Done(ply, how, now)
	if S.active ~= ply or not PLAYING[S.phase] or S.phase == "between" then return end
	local e = S.entries[Key(ply)]
	local points = BB.SCORING[how] and 1 or 0
	e.total = (e.total or 0) + points
	S.last = { name = ply:Nick(), ent = ply:EntIndex(), points = points, how = how }
	S.phase, S.active, S.deadline = "between", nil, now + BB.BETWEEN
	Freezes()
	Broadcast(now)
	if how == "basket" then Tell(nil, ply:Nick() .. " sank the board!") elseif how == "player" then Tell(nil, ply:Nick() .. " dunked themselves!") end
end

function BB.Tick(now)
	local ph = S.phase
	if ph == "idle" or ph == "lobby" then return end
	if ph == "prep" and now > S.deadline then
		Tell(nil, (IsValid(S.active) and S.active:Nick() or "?") .. " couldn't get into Skater mode in time")
		BB.Done(S.active, "skipped", now)
	elseif ph == "countdown" and now > S.deadline then
		S.phase, S.deadline = "turn", now + S.time
		Broadcast(now)
	elseif ph == "turn" or ph == "finish" then
		if not Skating(S.active) then
			S.offSince = S.offSince or now
			if now - S.offSince > 1 then return BB.Done(S.active, "left", now) end
		else
			S.offSince = nil
		end
		if now > S.deadline then
			if ph == "turn" then
				S.phase, S.deadline = "finish", now + BB.FINISH + BB.WATCH
				Broadcast(now)
			else
				BB.Done(S.active, "out of time", now)
			end
		end
	elseif ph == "between" and now > S.deadline then
		BB.Next(now)
	elseif ph == "results" and now > S.deadline then
		ToLobby(now)
	end
end
BB.mode:OnThink(function(now) BB.Tick(now) end)

function BB.Remove(ply, why, now)
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
	if #S.players == 0 then return Stop("everyone left: Basketboard is over", now) end
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
BB.mode:OnPlayerLeave(function(ply) BB.Remove(ply, "left the game") end)

local handlers = {}
local function Host(ply) return S.phase ~= "idle" and S.host == ply end

function handlers.create(ply, m, now)
	if S.phase ~= "idle" then return Tell(ply, "a game is already open") end
	if BB.mode:CantSkate(ply, m, "host") then return end
	local obj = type(m.hoop) == "table" and m.hoop or nil
	local spot = obj and SKATEGM_MODES.Vec(obj.pos)
	if not spot then return Tell(ply, "place the hoop first") end
	S.phase, S.host = "lobby", ply
	S.start, S.yaw = SKATEGM_MODES.HostStart(ply, m)
	S.time, S.rounds = BB.ClampTime(m.time), BB.ClampRounds(m.rounds)
	S.radius, S.height = BB.ClampRadius(obj.scale), BB.ClampLift(obj.lift)
	S.zone = BB.ClampZone(obj.zone)
	S.ground = spot[3]
	S.hoop = { spot[1], spot[2], S.ground + S.height }
	local yaw = tonumber(obj.yaw)
	S.facing = (yaw and yaw == yaw) and yaw % 360 or BB.Facing(S.hoop, { S.start.x, S.start.y }, 0)
	S.players, S.entries, S.index, S.round = { ply }, {}, 0, 0
	S.entries[Key(ply)] = { name = ply:Nick(), total = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " is hosting Basketboard: join with LB + D-pad left")
end

function handlers.join(ply, m, now)
	if S.phase == "idle" then return Tell(ply, "no game is open") end
	if S.phase ~= "lobby" then return Tell(ply, "a game is on: wait for the next one") end
	if IndexOf(ply) then return end
	if BB.mode:CantSkate(ply, m, "play") then return end
	S.players[#S.players + 1] = ply
	S.entries[Key(ply)] = { name = ply:Nick(), total = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " joined")
end

function handlers.leave(ply, m, now) BB.Remove(ply, "left the game", now) end

function handlers.begin(ply, m, now)
	if not Host(ply) then return Tell(ply, "only the host can start") end
	if S.phase ~= "lobby" then return end
	S.order = {}
	for i, p in ipairs(S.players) do S.order[i] = p end
	for _, e in pairs(S.entries) do e.total = 0 end
	S.index, S.round = 0, 1
	BB.Next(now)
end

function handlers.stop(ply, m, now)
	if S.phase == "idle" then return end
	if not (Host(ply) or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
	if m.close or S.phase == "lobby" then return Stop("Basketboard was closed by " .. ply:Nick(), now) end
	ToLobby(now)
	Tell(nil, ply:Nick() .. " stopped the game")
end

function handlers.ready(ply, m, now)
	if S.phase ~= "prep" or S.active ~= ply then return end
	S.phase, S.deadline = "countdown", now + BB.COUNTDOWN
	Broadcast(now)
end

local OUTCOMES = { basket = true, player = true, miss = true, nozone = true }
function handlers.result(ply, m, now)
	if S.phase ~= "turn" and S.phase ~= "finish" then return end
	if not OUTCOMES[m.how] then return end
	BB.Done(ply, m.how, now)
end

BB.Command = BB.mode:Serve(S, handlers, function(why) BB.Stop(why) end, function() Broadcast() end)
