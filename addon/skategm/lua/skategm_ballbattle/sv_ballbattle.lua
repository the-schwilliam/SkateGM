-- Ball Battle, server: the game. Uses only SkateGM.API from the skating add-on.

local BB = BALLBATTLE
local S = { phase = "idle" }
BB.session = S
BB.mode:UseSessions(S)

local Allowed = SKATEGM_MODES.Allowed
local function Tell(ply, text) BB.mode:Tell(ply, text) end
local function Key(ply) return SKATEGM_MODES.Key(ply) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(S.players, ply) end
local function Ent(ply) return IsValid(ply) and ply:EntIndex() or 0 end

local function Public(now)
	local t = { phase = S.phase }
	if S.phase == "idle" then return t end
	t.host = Ent(S.host)
	t.start, t.yaw, t.area = { S.start.x, S.start.y, S.start.z }, S.yaw, S.area
	t.time, t.balls, t.items = S.time, S.balls, S.items
	t.timeLeft = S.deadline and math.max(0, S.deadline - now) or 0
	t.players, t.slots, t.winners = {}, S.slots, S.winners
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)] or {}
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), balls = e.balls or 0, playing = e.playing or nil, out = e.out or nil, slot = e.slot }
	end
	return t
end

local function Broadcast(now)
	BB.mode:Broadcast(Public(now or CurTime()), now)
	S.lastBroadcast = now or CurTime()
end
BB.Broadcast = Broadcast

local function Stop(reason, now)
	for k in pairs(S) do S[k] = nil end
	S.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
BB.Stop = Stop

local function ToLobby(now)
	S.phase, S.deadline, S.winners, S.slots = "lobby", nil, nil, nil
	for _, e in pairs(S.entries) do e.balls, e.playing, e.out, e.slot = 0, nil, nil, nil end
	Broadcast(now)
end

local function Alive()
	local out = {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)]
		if e and e.playing and not e.out then out[#out + 1] = p end
	end
	return out
end

local function Results(now)
	local best, names = -1, {}
	for _, p in ipairs(Alive()) do
		local b = S.entries[Key(p)].balls
		if b > best then best, names = b, { p:Nick() } elseif b == best then names[#names + 1] = p:Nick() end
	end
	S.winners = { names = names }
	S.phase, S.deadline = "results", now + BB.RESULTS
	Broadcast(now)
	Tell(nil, #names > 0 and (table.concat(names, " and ") .. " win" .. (#names == 1 and "s" or "") .. " Ball Battle!") or "nobody's left")
end

function BB.Pop(ply, why, now)
	local e = IndexOf(ply) and S.entries[Key(ply)]
	if S.phase ~= "playing" or not (e and e.playing) or e.out then return false end
	if (e.popAt or 0) > now then return false end
	e.popAt = now + BB.GRACE
	e.balls = e.balls - 1
	if e.balls <= 0 then
		e.balls, e.out = 0, true
		Tell(nil, ply:Nick() .. " lost their last ball: out!")
		if #Alive() <= 1 then return Results(now) end
	end
	Broadcast(now)
	return true
end

function BB.Tick(now)
	local ph = S.phase
	if ITEMS and ITEMS.server and ph ~= "idle" then
		ITEMS.server.Sync(BB.mode, S, { on = S.items, centre = Vector(S.area[1], S.area[2], S.area[3]), radius = S.area[4],
			onHit = function(victim) BB.Pop(victim, "hit", CurTime()) end,
			canPlay = function(ply, G) local e = G and G.entries and G.entries[Key(ply)] return e ~= nil and e.playing and not e.out end })
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
BB.mode:OnThink(function(now) BB.Tick(now) end)

function BB.Remove(ply, why, now)
	now = now or CurTime()
	local i = IndexOf(ply)
	if not i then return end
	table.remove(S.players, i)
	S.entries[Key(ply)] = nil
	if #S.players == 0 then return Stop("everyone left: Ball Battle is over", now) end
	if S.host == ply then
		S.host = S.players[1]
		Tell(nil, S.host:Nick() .. " is the host now")
	end
	Tell(nil, ply:Nick() .. " " .. why)
	if S.phase == "playing" and #Alive() <= 1 then return Results(now) end
	Broadcast(now)
end
BB.mode:OnPlayerLeave(function(ply) BB.Remove(ply, "left the game") end)

local handlers = {}
local function Host(ply) return S.phase ~= "idle" and S.host == ply end

function handlers.create(ply, m, now)
	if S.phase ~= "idle" then return Tell(ply, "a game is already open") end
	if BB.mode:CantSkate(ply, m, "host") then return end
	local c = SKATEGM_MODES.Vec(m.centre) or (function() local p = SKATEGM_MODES.HostStart(ply, m) return { p.x, p.y, p.z } end)()
	S.phase, S.host = "lobby", ply
	S.start, S.yaw = SKATEGM_MODES.HostStart(ply, m)
	S.area = { c[1], c[2], c[3], BB.ClampArea(m.radius) }
	S.time, S.balls, S.items = BB.ClampTime(m.time), BB.ClampBalls(m.balls), m.items ~= false
	S.players, S.entries = { ply }, {}
	S.entries[Key(ply)] = { name = ply:Nick(), balls = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " is hosting Ball Battle: join with LB + D-pad left")
end

function handlers.join(ply, m, now)
	if S.phase == "idle" then return Tell(ply, "no game is open") end
	if S.phase ~= "lobby" then return Tell(ply, "a game is on: wait for the next one") end
	if IndexOf(ply) then return end
	if BB.mode:CantSkate(ply, m, "play") then return end
	S.players[#S.players + 1] = ply
	S.entries[Key(ply)] = { name = ply:Nick(), balls = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " joined")
end

function handlers.leave(ply, m, now) BB.Remove(ply, "left the game", now) end

function handlers.begin(ply, m, now)
	if not Host(ply) then return Tell(ply, "only the host can start") end
	if S.phase ~= "lobby" then return end
	if #S.players < 2 then return Tell(ply, "Ball Battle needs at least 2 players") end
	S.slots = #S.players
	for i, p in ipairs(S.players) do
		local e = S.entries[Key(p)]
		e.balls, e.playing, e.out, e.slot, e.popAt = S.balls, true, nil, i, nil
	end
	S.phase, S.deadline = "countdown", now + BB.COUNTDOWN
	Broadcast(now)
end

function handlers.stop(ply, m, now)
	if S.phase == "idle" then return end
	if not (Host(ply) or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
	if m.close or S.phase == "lobby" then return Stop("Ball Battle was closed by " .. ply:Nick(), now) end
	ToLobby(now)
	Tell(nil, ply:Nick() .. " stopped the game")
end

function handlers.bailed(ply, m, now) BB.Pop(ply, "bail", now) end

-- out of bounds for too long: out of the game
function handlers.outside(ply, m, now)
	local e = IndexOf(ply) and S.entries[Key(ply)]
	if S.phase ~= "playing" or not (e and e.playing) or e.out then return end
	e.balls, e.out = 0, true
	Tell(nil, ply:Nick() .. " went out of bounds: out!")
	if #Alive() <= 1 then return Results(now) end
	Broadcast(now)
end

BB.Command = BB.mode:Serve(S, handlers, function(why) BB.Stop(why) end, function() Broadcast() end)
