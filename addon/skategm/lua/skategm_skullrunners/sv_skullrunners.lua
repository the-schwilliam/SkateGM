-- Skull Runners, server: the game. Uses only SkateGM.API from the skating add-on.

local SR = SKULLRUNNERS
local S = { phase = "idle" }
SR.session = S
SR.mode:UseSessions(S)

local Allowed = SKATEGM_MODES.Allowed
local function Tell(ply, text) SR.mode:Tell(ply, text) end
local function Key(ply) return SKATEGM_MODES.Key(ply) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(S.players, ply) end
local function Ent(ply) return IsValid(ply) and ply:EntIndex() or 0 end

local function Spot(area)
	if ITEMS and ITEMS.RandomSpot then return ITEMS.RandomSpot(area, area[4]) end
	local r, a = area[4] * 0.9 * math.sqrt(math.random()), math.random() * math.pi * 2
	local x, y = area[1] + math.cos(a) * r, area[2] + math.sin(a) * r
	return { x, y, SKATEGM_MODES.Ground(x, y, area[3]) }
end

local function Public(now)
	local t = { phase = S.phase }
	if S.phase == "idle" then return t end
	t.host = Ent(S.host)
	t.start, t.yaw, t.area = { S.start.x, S.start.y, S.start.z }, S.yaw, S.area
	t.time, t.count, t.items = S.time, S.count, S.items
	t.timeLeft = S.deadline and math.max(0, S.deadline - now) or 0
	t.skulls = {}
	for id, k in pairs(S.skulls or {}) do t.skulls[#t.skulls + 1] = { id, k[1], k[2], k[3] } end
	t.players, t.slots, t.winners = {}, S.slots, S.winners
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)] or {}
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), skulls = e.skulls or 0, playing = e.playing or nil, slot = e.slot }
	end
	return t
end

local function Broadcast(now)
	SR.mode:Broadcast(Public(now or CurTime()), now)
	S.lastBroadcast = now or CurTime()
end
SR.Broadcast = Broadcast

local function Stop(reason, now)
	for k in pairs(S) do S[k] = nil end
	S.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
SR.Stop = Stop

local function ToLobby(now)
	S.phase, S.deadline, S.skulls, S.winners, S.slots = "lobby", nil, nil, nil, nil
	for _, e in pairs(S.entries) do e.skulls, e.playing, e.slot = 0, nil, nil end
	Broadcast(now)
end

function SR.AddSkull(pos)
	S.nextSkull = (S.nextSkull or 0) + 1
	S.skulls[S.nextSkull] = pos
	return S.nextSkull
end

local function SkullCount()
	local n = 0
	for _ in pairs(S.skulls or {}) do n = n + 1 end
	return n
end

local function Results(now)
	local best, names = -1, {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)]
		if e.playing then
			if e.skulls > best then best, names = e.skulls, { p:Nick() } elseif e.skulls == best then names[#names + 1] = p:Nick() end
		end
	end
	S.winners = { names = names, skulls = math.max(0, best) }
	S.phase, S.deadline = "results", now + SR.RESULTS
	Broadcast(now)
	Tell(nil, #names > 0 and (table.concat(names, " and ") .. " win" .. (#names == 1 and "s" or "") .. " with " .. best .. " skulls!") or "nobody's left")
end

-- someone bailed (an item's hit or their own): some of their skulls drop around them
function SR.Drop(ply, now)
	local e = IndexOf(ply) and S.entries[Key(ply)]
	if S.phase ~= "playing" or not (e and e.playing) then return end
	if (e.dropAt or 0) > now then return end
	e.dropAt = now + 2
	local n = math.min(e.skulls, SR.DROP)
	if n <= 0 then return end
	e.skulls = e.skulls - n
	local at = ply.SkateGMHips or ply:GetPos()
	for i = 1, n do
		local a = (i / n + math.random() * 0.3) * math.pi * 2
		local x, y = at.x + math.cos(a) * SR.DROP_SPREAD, at.y + math.sin(a) * SR.DROP_SPREAD
		SR.AddSkull({ x, y, SKATEGM_MODES.Ground(x, y, at.z) })
	end
	Tell(nil, string.format("%s bailed and dropped %d skull%s!", ply:Nick(), n, n == 1 and "" or "s"))
	Broadcast(now)
end

function SR.Tick(now)
	local ph = S.phase
	if ITEMS and ITEMS.server and ph ~= "idle" then
		ITEMS.server.Sync(SR.mode, S, { on = S.items, centre = Vector(S.area[1], S.area[2], S.area[3]), radius = S.area[4] })
	end
	if ph == "idle" or ph == "lobby" then return end
	if ph == "countdown" and now > S.deadline then
		S.phase, S.deadline = "playing", now + S.time
		Broadcast(now)
	elseif ph == "playing" then
		if now > S.deadline then return Results(now) end
		if now - (S.lastBroadcast or 0) > 1 then Broadcast(now) end
	elseif ph == "results" and now > S.deadline then
		ToLobby(now)
	end
end
SR.mode:OnThink(function(now) SR.Tick(now) end)

function SR.Remove(ply, why, now)
	now = now or CurTime()
	local i = IndexOf(ply)
	if not i then return end
	table.remove(S.players, i)
	S.entries[Key(ply)] = nil
	if #S.players == 0 then return Stop("everyone left: Skull Runners is over", now) end
	if S.host == ply then
		S.host = S.players[1]
		Tell(nil, S.host:Nick() .. " is the host now")
	end
	Tell(nil, ply:Nick() .. " " .. why)
	Broadcast(now)
end
SR.mode:OnPlayerLeave(function(ply) SR.Remove(ply, "left the game") end)

local handlers = {}
local function Host(ply) return S.phase ~= "idle" and S.host == ply end

function handlers.create(ply, m, now)
	if S.phase ~= "idle" then return Tell(ply, "a game is already open") end
	if SR.mode:CantSkate(ply, m, "host") then return end
	local c = SKATEGM_MODES.Vec(m.centre) or (function() local p = SKATEGM_MODES.HostStart(ply, m) return { p.x, p.y, p.z } end)()
	S.phase, S.host = "lobby", ply
	S.start, S.yaw = SKATEGM_MODES.HostStart(ply, m)
	S.area = { c[1], c[2], c[3], SR.ClampArea(m.radius) }
	S.time, S.count, S.items = SR.ClampTime(m.time), SR.ClampSkulls(m.skulls), m.items ~= false
	S.players, S.entries = { ply }, {}
	S.entries[Key(ply)] = { name = ply:Nick(), skulls = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " is hosting Skull Runners: join with LB + D-pad left")
end

function handlers.join(ply, m, now)
	if S.phase == "idle" then return Tell(ply, "no game is open") end
	if S.phase ~= "lobby" then return Tell(ply, "a game is on: wait for the next one") end
	if IndexOf(ply) then return end
	if SR.mode:CantSkate(ply, m, "play") then return end
	S.players[#S.players + 1] = ply
	S.entries[Key(ply)] = { name = ply:Nick(), skulls = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " joined")
end

function handlers.leave(ply, m, now) SR.Remove(ply, "left the game", now) end

function handlers.begin(ply, m, now)
	if not Host(ply) then return Tell(ply, "only the host can start") end
	if S.phase ~= "lobby" then return end
	S.skulls, S.nextSkull, S.slots = {}, 0, #S.players
	local spots = ITEMS and ITEMS.Spread and ITEMS.Spread(S.area, S.area[4], S.count) or nil
	for i = 1, S.count do SR.AddSkull(spots and spots[i] or Spot(S.area)) end
	for i, p in ipairs(S.players) do
		local e = S.entries[Key(p)]
		e.skulls, e.playing, e.slot, e.dropAt = 0, true, i, nil
	end
	S.phase, S.deadline = "countdown", now + SR.COUNTDOWN
	Broadcast(now)
end

function handlers.stop(ply, m, now)
	if S.phase == "idle" then return end
	if not (Host(ply) or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
	if m.close or S.phase == "lobby" then return Stop("Skull Runners was closed by " .. ply:Nick(), now) end
	ToLobby(now)
	Tell(nil, ply:Nick() .. " stopped the game")
end

function handlers.grab(ply, m, now)
	if S.phase ~= "playing" then return end
	local e = IndexOf(ply) and S.entries[Key(ply)]
	local id = tonumber(m.id)
	local k = id and S.skulls[id]
	if not (e and e.playing and k) then return end
	local at = ply.SkateGMHips or ply:GetPos()
	if at:Distance(Vector(k[1], k[2], k[3] + SR.FLOAT)) > SR.TOUCH_CHECK then return end
	S.skulls[id] = nil
	e.skulls = e.skulls + 1
	if SkullCount() < S.count then SR.AddSkull(Spot(S.area)) end
	Broadcast(now)
end

function handlers.bailed(ply, m, now) SR.Drop(ply, now) end

SR.Command = SR.mode:Serve(S, handlers, function(why) SR.Stop(why) end, function() Broadcast() end)
