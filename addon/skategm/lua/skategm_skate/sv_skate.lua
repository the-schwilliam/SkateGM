-- S.K.A.T.E., server: the game. Uses only SkateGM.API from the skating add-on.

local S = { phase = "idle" }
SKATE.session = S
SKATE.mode:UseSessions(S)

local Allowed, Skating = SKATEGM_MODES.Allowed, SKATEGM_MODES.Skating
local function Tell(ply, text) SKATE.mode:Tell(ply, text) end
local function Key(ply) return SKATEGM_MODES.Key(ply) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(S.players, ply) end
local function Ent(ply) return IsValid(ply) and ply:EntIndex() or 0 end

local function Alive(ply)
	local e = IsValid(ply) and IndexOf(ply) and S.entries[Key(ply)]
	return e ~= nil and e ~= false and not e.out
end

local function AliveList()
	local out = {}
	for _, p in ipairs(S.order or {}) do if Alive(p) then out[#out + 1] = p end end
	return out
end

---------------------------------------------------------------------------
-- what every client sees
---------------------------------------------------------------------------
local function Public(now)
	local t = { phase = S.phase }
	if S.phase == "idle" then return t end
	t.host = Ent(S.host)
	t.spot = { S.spot.x, S.spot.y, S.spot.z }
	t.yaw, t.time = S.yaw, S.time
	t.active, t.setter = Ent(S.active), Ent(S.setter)
	t.set = S.set
	t.timeLeft = S.deadline and math.max(0, S.deadline - now) or 0
	t.last, t.winner = S.last, S.winner
	t.players = {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)] or {}
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), letters = e.letters or 0, out = e.out or nil }
	end
	return t
end

local function Broadcast(now) SKATE.mode:Broadcast(Public(now or CurTime()), now) end
SKATE.Broadcast = Broadcast

local PLAYING = { prep = true, countdown = true, attempt = true, finish = true, between = true }
local function Freezes() SKATEGM_MODES.FreezeWatchers(S.players, S.active, PLAYING[S.phase] == true) end

---------------------------------------------------------------------------
-- flow
---------------------------------------------------------------------------
local Go, Results

local function Stop(reason, now)
	for _, p in ipairs(S.players or {}) do if IsValid(p) then p:Freeze(false) end end
	for k in pairs(S) do S[k] = nil end
	S.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
SKATE.Stop = Stop

local function ToLobby(now)
	S.phase, S.active, S.setter, S.set, S.queue, S.order, S.deadline, S.last, S.winner = "lobby", nil, nil, nil, nil, nil, nil, nil, nil
	for _, e in pairs(S.entries) do e.letters, e.out = 0, nil end
	Freezes()
	Broadcast(now)
end

function Go(p, now)
	S.phase, S.active, S.deadline, S.offSince = "prep", p, now + SKATE.PREP_TIMEOUT, nil
	Freezes()
	Broadcast(now)
end

function Results(now)
	local alive = AliveList()
	S.winner = alive[1] and { name = alive[1]:Nick(), ent = alive[1]:EntIndex() } or nil
	S.phase, S.active, S.deadline = "results", nil, now + SKATE.RESULTS
	Freezes()
	Broadcast(now)
	Tell(nil, S.winner and (S.winner.name .. " wins S.K.A.T.E.!") or "nobody's left")
end

-- the next setter after p in the order who's still in
local function NextSetter(p)
	local order = S.order
	local i = SKATEGM_MODES.IndexOf(order, p) or 0
	for k = 1, #order do
		local q = order[(i - 1 + k) % #order + 1]
		if Alive(q) and q ~= p then return q end
	end
	return Alive(p) and p or nil
end

-- who has to match the set: everyone still in after the setter, in order
local function Matchers(setter)
	local out, order = {}, S.order
	local i = SKATEGM_MODES.IndexOf(order, setter) or 0
	for k = 1, #order - 1 do
		local q = order[(i - 1 + k) % #order + 1]
		if Alive(q) and q ~= setter then out[#out + 1] = q end
	end
	return out
end

local function Continue(now)
	if #AliveList() <= 1 then return Results(now) end
	S.phase, S.active, S.deadline = "between", nil, now + SKATE.BETWEEN
	Freezes()
	Broadcast(now)
end

local function NextGo(now)
	if #AliveList() <= 1 then return Results(now) end
	if S.set and S.queue and #S.queue > 0 then
		local p = table.remove(S.queue, 1)
		if Alive(p) then return Go(p, now) end
		return NextGo(now)
	end
	S.set, S.queue = nil, nil
	if not Alive(S.setter) then S.setter = NextSetter(S.setter) end
	if not S.setter then return Results(now) end
	Go(S.setter, now)
end

function SKATE.Result(ply, landed, tricks, now)
	if S.active ~= ply or (S.phase ~= "attempt" and S.phase ~= "finish") then return end
	SKATE.Resolve(ply, landed, tricks, now)
end

function SKATE.Resolve(ply, landed, tricks, now)
	tricks = SKATE.Clean(tricks)
	local name = ply:Nick()
	if not S.set then
		if landed and #tricks > 0 then
			S.set, S.queue = tricks, Matchers(ply)
			S.last = { name = name, ent = ply:EntIndex(), how = "set", set = tricks }
			Tell(nil, name .. " set: " .. table.concat(tricks, " + "))
		else
			S.last = { name = name, ent = ply:EntIndex(), how = "missed the set" }
			S.setter = NextSetter(ply)
		end
		return Continue(now)
	end
	local e = S.entries[Key(ply)]
	local matched = landed and SKATE.Matches(S.set, tricks)
	if not matched then
		e.letters = (e.letters or 0) + 1
		if e.letters >= #SKATE.WORD then e.out = true end
	end
	S.last = { name = name, ent = ply:EntIndex(), how = matched and "matched" or "missed", letters = SKATE.Letters(e.letters), out = e.out or nil }
	if not matched then Tell(nil, string.format("%s missed: %s%s", name, SKATE.Letters(e.letters), e.out and " - out!" or "")) end
	Continue(now)
end

function SKATE.Tick(now)
	local ph = S.phase
	if ph == "idle" or ph == "lobby" then return end
	if ph == "prep" and now > S.deadline then
		Tell(nil, (IsValid(S.active) and S.active:Nick() or "?") .. " couldn't get into Skater mode in time")
		SKATE.Resolve(S.active, false, {}, now)
	elseif ph == "countdown" and now > S.deadline then
		S.phase, S.deadline = "attempt", now + S.time
		Broadcast(now)
	elseif ph == "attempt" or ph == "finish" then
		if not Skating(S.active) then
			S.offSince = S.offSince or now
			if now - S.offSince > 1 then return SKATE.Result(S.active, false, {}, now) end
		else
			S.offSince = nil
		end
		if now > S.deadline then
			if ph == "attempt" then
				S.phase, S.deadline = "finish", now + SKATE.FINISH
				Broadcast(now)
			else
				SKATE.Result(S.active, false, {}, now)
			end
		end
	elseif ph == "between" and now > S.deadline then
		NextGo(now)
	elseif ph == "results" and now > S.deadline then
		ToLobby(now)
	end
end
SKATE.mode:OnThink(function(now) SKATE.Tick(now) end)

---------------------------------------------------------------------------
-- players leaving
---------------------------------------------------------------------------
function SKATE.Remove(ply, why, now)
	now = now or CurTime()
	local i = IndexOf(ply)
	if not i then return end
	if IsValid(ply) then ply:Freeze(false) end
	table.remove(S.players, i)
	S.entries[Key(ply)] = nil
	if S.queue then
		local q = SKATEGM_MODES.IndexOf(S.queue, ply)
		if q then table.remove(S.queue, q) end
	end
	if #S.players == 0 then return Stop("everyone left: S.K.A.T.E. is over", now) end
	if S.host == ply then
		S.host = S.players[1]
		Tell(nil, S.host:Nick() .. " is the host now")
	end
	Tell(nil, ply:Nick() .. " " .. why)
	if PLAYING[S.phase] then
		if S.setter == ply then
			S.setter = NextSetter(ply)
			if S.active ~= ply then S.set, S.queue = nil, nil end
		end
		if S.active == ply then
			S.last = { name = ply:Nick(), how = "left" }
			return Continue(now)
		end
		if #AliveList() <= 1 then return Results(now) end
	end
	Broadcast(now)
end
SKATE.mode:OnPlayerLeave(function(ply) SKATE.Remove(ply, "left the game") end)

---------------------------------------------------------------------------
-- commands
---------------------------------------------------------------------------
local handlers = {}
local function Host(ply) return S.phase ~= "idle" and S.host == ply end

function handlers.create(ply, m, now)
	if S.phase ~= "idle" then return Tell(ply, "a game is already open") end
	if SKATE.mode:CantSkate(ply, m, "host") then return end
	S.phase, S.host = "lobby", ply
	S.spot, S.yaw = SKATEGM_MODES.HostStart(ply, m)
	S.time = SKATE.ClampTime(m.time)
	S.players, S.entries = { ply }, {}
	S.entries[Key(ply)] = { name = ply:Nick(), letters = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " is hosting S.K.A.T.E.: join with LB + D-pad left")
end

function handlers.join(ply, m, now)
	if S.phase == "idle" then return Tell(ply, "no game is open") end
	if S.phase ~= "lobby" then return Tell(ply, "a game is on: wait for the next one") end
	if IndexOf(ply) then return end
	if SKATE.mode:CantSkate(ply, m, "play") then return end
	S.players[#S.players + 1] = ply
	S.entries[Key(ply)] = { name = ply:Nick(), letters = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " joined")
end

function handlers.leave(ply, m, now) SKATE.Remove(ply, "left the game", now) end

function handlers.begin(ply, m, now)
	if not Host(ply) then return Tell(ply, "only the host can start") end
	if S.phase ~= "lobby" then return end
	if #S.players < 2 then return Tell(ply, "S.K.A.T.E. needs at least 2 players") end
	S.order = {}
	for i, p in ipairs(S.players) do S.order[i] = p end
	for i = #S.order, 2, -1 do
		local j = math.random(1, i)
		S.order[i], S.order[j] = S.order[j], S.order[i]
	end
	for _, e in pairs(S.entries) do e.letters, e.out = 0, nil end
	S.setter, S.set, S.queue = S.order[1], nil, nil
	Go(S.setter, now)
end

function handlers.stop(ply, m, now)
	if S.phase == "idle" then return end
	if not (Host(ply) or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
	if m.close or S.phase == "lobby" then return Stop("S.K.A.T.E. was closed by " .. ply:Nick(), now) end
	ToLobby(now)
	Tell(nil, ply:Nick() .. " stopped the game")
end

function handlers.ready(ply, m, now)
	if S.phase ~= "prep" or S.active ~= ply then return end
	S.phase, S.deadline = "countdown", now + SKATE.COUNTDOWN
	Broadcast(now)
end

function handlers.attempt(ply, m, now) SKATE.Result(ply, m.landed == true, m.tricks, now) end

SKATE.Command = SKATE.mode:Serve(S, handlers, function(why) SKATE.Stop(why) end, function() Broadcast() end)
