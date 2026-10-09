-- Rocket Royale, server: the game. Uses only SkateGM.API from the skating add-on.

local RR = ROCKETROYALE
local S = { phase = "idle" }
RR.session = S
RR.mode:UseSessions(S)

local Allowed, Skating = SKATEGM_MODES.Allowed, SKATEGM_MODES.Skating
local function Tell(ply, text) RR.mode:Tell(ply, text) end
local function Key(ply) return SKATEGM_MODES.Key(ply) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(S.players, ply) end
local function Ent(ply) return IsValid(ply) and ply:EntIndex() or 0 end

local function Riding()
	local out = {}
	for _, p in ipairs(S.players or {}) do
		local e = S.entries[Key(p)]
		if e and e.playing and not e.out then out[#out + 1] = p end
	end
	return out
end

local function Public(now)
	local t = { phase = S.phase }
	if S.phase == "idle" then return t end
	t.host = Ent(S.host)
	t.start = { S.start.x, S.start.y, S.start.z }
	t.yaw, t.time = S.yaw, S.time
	t.timeLeft = S.deadline and math.max(0, S.deadline - now) or 0
	t.winners = S.winners
	t.players = {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)] or {}
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), playing = e.playing or nil, out = e.out or nil, slot = e.slot, lasted = e.lasted }
	end
	t.slots = S.slots
	return t
end

local function Broadcast(now) RR.mode:Broadcast(Public(now or CurTime()), now) end
RR.Broadcast = Broadcast

local function Stop(reason, now)
	for k in pairs(S) do S[k] = nil end
	S.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
RR.Stop = Stop

local function ToLobby(now)
	S.phase, S.deadline, S.winners, S.startedAt = "lobby", nil, nil, nil
	for _, e in pairs(S.entries) do e.playing, e.out, e.slot, e.lasted = nil, nil, nil, nil end
	Broadcast(now)
end

local function Results(now, why)
	local riding = Riding()
	S.winners = {}
	for _, p in ipairs(riding) do S.winners[#S.winners + 1] = p:Nick() end
	S.phase, S.deadline = "results", now + RR.RESULTS
	Broadcast(now)
	if #riding == 1 then Tell(nil, riding[1]:Nick() .. " wins Rocket Royale!")
	elseif #riding > 1 then Tell(nil, (why or "time's up") .. ": " .. table.concat(S.winners, ", ") .. " rode it out")
	else Tell(nil, "nobody's left") end
end

function RR.Out(ply, now, why)
	local e = IndexOf(ply) and S.entries[Key(ply)]
	if S.phase ~= "playing" or not e or not e.playing or e.out then return end
	e.out, e.lasted = true, math.floor((now - (S.startedAt or now)) * 10) / 10
	Tell(nil, string.format("%s %s after %.1f s", ply:Nick(), why or "bailed", e.lasted))
	if #Riding() <= 1 then return Results(now) end
	Broadcast(now)
end

function RR.Tick(now)
	local ph = S.phase
	if ph == "idle" or ph == "lobby" then return end
	if ph == "countdown" and now > S.deadline then
		S.phase, S.deadline, S.startedAt = "playing", now + S.time, now
		Broadcast(now)
	elseif ph == "playing" then
		for _, p in ipairs(Riding()) do
			local e = S.entries[Key(p)]
			if not Skating(p) then
				e.offSince = e.offSince or now
				if now - e.offSince > RR.OFF_GRACE then RR.Out(p, now, "left Skater mode") if S.phase ~= "playing" then return end end
			else
				e.offSince = nil
			end
		end
		if now > S.deadline then return Results(now) end
		if now - (RR.mode.lastBroadcast or 0) > 1 then Broadcast(now) end
	elseif ph == "results" and now > S.deadline then
		ToLobby(now)
	end
end
RR.mode:OnThink(function(now) RR.Tick(now) end)

function RR.Remove(ply, why, now)
	now = now or CurTime()
	local i = IndexOf(ply)
	if not i then return end
	table.remove(S.players, i)
	S.entries[Key(ply)] = nil
	if #S.players == 0 then return Stop("everyone left: Rocket Royale is over", now) end
	if S.host == ply then
		S.host = S.players[1]
		Tell(nil, S.host:Nick() .. " is the host now")
	end
	Tell(nil, ply:Nick() .. " " .. why)
	if (S.phase == "playing" or S.phase == "countdown") and #Riding() <= 1 then return Results(now) end
	Broadcast(now)
end
RR.mode:OnPlayerLeave(function(ply) RR.Remove(ply, "left the game") end)

local handlers = {}
local function Host(ply) return S.phase ~= "idle" and S.host == ply end

function handlers.create(ply, m, now)
	if S.phase ~= "idle" then return Tell(ply, "a game is already open") end
	if RR.mode:CantSkate(ply, m, "host") then return end
	S.phase, S.host = "lobby", ply
	S.start, S.yaw = SKATEGM_MODES.HostStart(ply, m)
	S.time = RR.ClampTime(m.time)
	S.players, S.entries = { ply }, {}
	S.entries[Key(ply)] = { name = ply:Nick() }
	S._boardRules = SKATEGM_MODES.CleanRules({ rocket = "force", hover = type(m.rules) == "table" and m.rules.hover })
	Broadcast(now)
	Tell(nil, ply:Nick() .. " is hosting Rocket Royale: join with LB + D-pad left")
end

function handlers.join(ply, m, now)
	if S.phase == "idle" then return Tell(ply, "no game is open") end
	if S.phase ~= "lobby" then return Tell(ply, "a game is on: wait for the next one") end
	if IndexOf(ply) then return end
	if RR.mode:CantSkate(ply, m, "play") then return end
	S.players[#S.players + 1] = ply
	S.entries[Key(ply)] = { name = ply:Nick() }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " joined")
end

function handlers.leave(ply, m, now) RR.Remove(ply, "left the game", now) end

function handlers.begin(ply, m, now)
	if not Host(ply) then return Tell(ply, "only the host can start") end
	if S.phase ~= "lobby" then return end
	if #S.players < 2 then return Tell(ply, "Rocket Royale needs at least 2 players") end
	S.slots = #S.players
	for i, p in ipairs(S.players) do
		local e = S.entries[Key(p)]
		e.playing, e.out, e.slot, e.lasted, e.offSince = true, nil, i, nil, nil
	end
	S.phase, S.deadline = "countdown", now + RR.COUNTDOWN
	Broadcast(now)
end

function handlers.stop(ply, m, now)
	if S.phase == "idle" then return end
	if not (Host(ply) or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
	if m.close or S.phase == "lobby" then return Stop("Rocket Royale was closed by " .. ply:Nick(), now) end
	ToLobby(now)
	Tell(nil, ply:Nick() .. " stopped the game")
end

function handlers.bailed(ply, m, now) RR.Out(ply, now, "bailed") end

RR.Command = RR.mode:Serve(S, handlers, function(why) RR.Stop(why) end, function() Broadcast() end)
