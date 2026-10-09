-- Race, server: the race itself. Uses only SkateGM.API from the skating add-on.

local R = { phase = "idle" }
RACE.session = R
RACE.mode:UseSessions(R)

local API, Allowed, Skating = SKATEGM_MODES.API, SKATEGM_MODES.Allowed, SKATEGM_MODES.Skating

local function Tell(ply, text) RACE.mode:Tell(ply, text) end

local function Key(ply) return SKATEGM_MODES.Key(ply) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(R.players, ply) end

---------------------------------------------------------------------------
-- what every client sees
---------------------------------------------------------------------------
local function Public(now)
	local t = { phase = R.phase }
	if R.phase == "idle" then return t end
	t.host = IsValid(R.host) and R.host:EntIndex() or 0
	t.start = R.start and { R.start.x, R.start.y, R.start.z } or nil
	t.yaw = R.yaw or 0
	t.finish = R.finish and { R.finish.x, R.finish.y, R.finish.z } or nil
	t.radius, t.limit = R.radius, R.limit
	t.timeLeft = R.deadline and math.max(0, R.deadline - now) or 0
	t.elapsed = R.startedAt and math.max(0, now - R.startedAt) or 0
	t.players = {}
	for i, p in ipairs(R.players) do
		local e = R.entries[Key(p)]
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), racing = e.racing, time = e.time, place = e.place, out = e.dnf }
	end
	t.count = #R.players
	t.gone = {}
	for _, e in pairs(R.entries) do
		if e.left and e.time then t.gone[#t.gone + 1] = { name = e.name, time = e.time, place = e.place } end
	end
	return t
end

local function Broadcast(now)
	RACE.mode:Broadcast(Public(now or CurTime()), now)
	R.lastBroadcast = now or CurTime()
end
RACE.Broadcast = Broadcast

---------------------------------------------------------------------------
-- flow
---------------------------------------------------------------------------
local function Stop(reason, now)
	for k in pairs(R) do R[k] = nil end
	R.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
RACE.Stop = Stop

-- back to the lobby for a rematch (start, finish and players kept)
local function ToLobby(now)
	R.phase, R.deadline, R.startedAt = "lobby", nil, nil
	for _, e in pairs(R.entries) do e.racing, e.time, e.place, e.dnf = nil, nil, nil, nil end
	for key, e in pairs(R.entries) do if e.left then R.entries[key] = nil end end
	Broadcast(now)
end

local function Results(now, why)
	R.phase, R.deadline = "results", now + RACE.RESULTS
	local finished = 0
	local racers = 0
	for _, e in pairs(R.entries) do
		if e.time then finished = finished + 1 end
		if e.racing then racers = racers + 1 end
	end
	Broadcast(now)
	Tell(nil, (why or "race over") .. string.format(" - %d of %d finished", finished, racers))
end

-- still racing: in this race, not finished, not out of it
local function Racing(e) return e and e.racing and not e.time and not e.dnf end

-- the host pressed start: everyone in Skater mode races, straight to the
-- countdown on the start; anyone still loading sits this one out (and is
-- ready for the next)
local function Begin(now)
	local n = 0
	for _, p in ipairs(R.players) do
		local e = R.entries[Key(p)]
		e.racing = Skating(p) or nil
		if e.racing then n = n + 1 else Tell(p, "not in Skater mode yet: you sit this race out") end
	end
	if n == 0 then return Tell(R.host, "nobody's in Skater mode yet") end
	R.phase, R.deadline = "countdown", now + RACE.COUNTDOWN
	Broadcast(now)
end

local function Go(now)
	R.phase, R.startedAt, R.deadline = "racing", now, now + R.limit
	R.nextPlace = 1
	Broadcast(now)
end

local function Finished(ply, now)
	local e = R.entries[Key(ply)]
	if not Racing(e) or R.phase ~= "racing" then return end
	local t = now - R.startedAt
	if t < 1 then return end -- nobody finishes in under a second
	e.time, e.place = t, R.nextPlace
	R.nextPlace = R.nextPlace + 1
	Tell(nil, string.format("%s finished %s in %s", ply:Nick(), e.place == 1 and "FIRST" or ("#" .. e.place), RACE.Time(t)))
	-- everyone still racing done? (someone out of the race doesn't count)
	for _, p in ipairs(R.players) do
		if Racing(R.entries[Key(p)]) then return Broadcast(now) end
	end
	Results(now, "everyone's in")
end

local function RemovePlayer(ply, now, quiet)
	local i = IndexOf(ply)
	if not i then return end
	table.remove(R.players, i)
	local e = R.entries[Key(ply)]
	if e then
		if e.time then e.left = true else R.entries[Key(ply)] = nil end
	end
	if ply == R.host then
		R.host = R.players[1]
		if not IsValid(R.host) then return Stop("the host left: race closed", now) end
		Tell(R.host, "you're the race host now")
	end
	if not quiet then Tell(nil, ply:Nick() .. " left the race") end
	-- nobody left racing: straight to the results
	if R.phase == "racing" then
		for _, p in ipairs(R.players) do if Racing(R.entries[Key(p)]) then return Broadcast(now) end end
		return Results(now, "everyone's in")
	end
	Broadcast(now)
end

local function AddPlayer(ply, now)
	if IndexOf(ply) then return end
	if #R.players >= RACE.MAX_PLAYERS then return Tell(ply, "the race is full") end
	R.players[#R.players + 1] = ply
	R.entries[Key(ply)] = { name = ply:Nick() }
	Tell(nil, ply:Nick() .. " joined the race")
	Broadcast(now)
end

---------------------------------------------------------------------------
-- commands (from the menu or the console)
---------------------------------------------------------------------------
local function Vec(t) local v = SKATEGM_MODES.Vec(t) return v and Vector(v[1], v[2], v[3]) or nil end

function RACE.Command(ply, m, now)
	now = now or CurTime()
	if type(m) ~= "table" or type(m.cmd) ~= "string" then return end
	local cmd = m.cmd
	local host = R.phase ~= "idle" and ply == R.host
	if not RACE.Allowed() and cmd ~= "leave" then return Tell(ply, "races are turned off on this server") end
	if cmd == "create" then
		if R.phase ~= "idle" then return Tell(ply, "a race is already set up: join it") end
		if not Allowed(ply) then return Tell(ply, "you're not allowed to skate on this server") end
		R.phase, R.host, R.players, R.entries = "lobby", ply, {}, {}
		R.radius, R.limit = RACE.ClampRadius(m.radius), RACE.ClampLimit(m.limit)
		AddPlayer(ply, now)
		Tell(nil, ply:Nick() .. " is hosting a race: join with LB + D-pad left")
	elseif cmd == "join" then
		if R.phase ~= "lobby" then return Tell(ply, R.phase == "idle" and "no race set up" or "the race has started: wait for the next one") end
		if not Allowed(ply) then return Tell(ply, "you're not allowed to skate on this server") end
		AddPlayer(ply, now)
	elseif cmd == "leave" then
		RemovePlayer(ply, now)
	elseif cmd == "start" and host and R.phase == "lobby" then
		local p = Vec(m.pos)
		if not p then return end
		R.start, R.yaw = p, math.NormalizeAngle(tonumber(m.yaw) or 0)
		Tell(ply, "start placed")
		Broadcast(now)
	elseif cmd == "finish" and host and R.phase == "lobby" then
		local p = Vec(m.pos)
		if not p then return end
		R.finish = p
		Tell(ply, "finish placed")
		Broadcast(now)
	elseif cmd == "settings" and host and R.phase == "lobby" then
		R.radius, R.limit = RACE.ClampRadius(m.radius or R.radius), RACE.ClampLimit(m.limit or R.limit)
		Broadcast(now)
	elseif cmd == "begin" and host and R.phase == "lobby" then
		if not (R.start and R.finish) then return Tell(ply, "place the start and the finish first") end
		if R.start:Distance(R.finish) < R.radius * 2 then return Tell(ply, "the finish is too close to the start") end
		Begin(now)
	elseif cmd == "stop" and host then
		if R.phase == "lobby" or m.close then Stop("the host closed the race", now) else ToLobby(now) Tell(nil, "the host stopped the race") end
	elseif cmd == "finished" then
		Finished(ply, now)
	end
end

function RACE.Think(now)
	if R.phase == "idle" then return end
	for i = #(R.players or {}), 1, -1 do
		if not IsValid(R.players[i]) then RemovePlayer(R.players[i], now, true) if R.phase == "idle" then return end end
	end
	if R.phase == "countdown" and now >= R.deadline then Go(now)
	elseif R.phase == "racing" and now >= R.deadline then Results(now, "time's up")
	elseif R.phase == "results" and now >= R.deadline then ToLobby(now)
	end
	-- a racer who drops out of Skater mode mid-race is out of it
	if R.phase == "racing" then
		for _, p in ipairs(R.players) do
			local e = R.entries[Key(p)]
			if Racing(e) and not Skating(p) then
				e.dnf = true
				Tell(p, "you left Skater mode: you're out of this race")
			end
		end
		local left = 0
		for _, p in ipairs(R.players) do if Racing(R.entries[Key(p)]) then left = left + 1 end end
		if left == 0 then return Results(now, "everyone's in") end
	end
	if now - (R.lastBroadcast or 0) > 1 then Broadcast(now) end
end

RACE.mode:OnThink(function(now) RACE.Think(now) end)
RACE.mode:OnPlayerLeave(function() if R.phase ~= "idle" then timer.Simple(0, function() RACE.mode:RunThink(CurTime()) end) end end)
RACE.mode:OnCommand(function(ply, m) RACE.Command(ply, m) end)
RACE.mode:OnPlayerJoin(function(ply)
	if R.phase ~= "idle" then timer.Simple(3, function() if IsValid(ply) then Broadcast() end end) end
end)
RACE.mode:OnDisallowed(function() if R.phase ~= "idle" then Stop("races were turned off on this server") end end)
