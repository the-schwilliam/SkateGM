-- Melon King, server: the game, the melon and everyone's time with it. Uses
-- only SkateGM.API from the skating add-on.

local G = { phase = "idle" }
MELON.session = G
MELON.mode:UseSessions(G)

local API, Allowed, Skating = SKATEGM_MODES.API, SKATEGM_MODES.Allowed, SKATEGM_MODES.Skating

local function Tell(ply, text) MELON.mode:Tell(ply, text) end

local function Key(ply) return SKATEGM_MODES.Key(ply, G.keys) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(G.players, ply) end
local function Entry(ply) return IndexOf(ply) and G.entries[Key(ply)] or nil end
local function Playing(ply) local e = Entry(ply) return e ~= nil and e.playing end

local Vec = SKATEGM_MODES.Vec
local function V(t) return Vector(t[1], t[2], t[3]) end

-- where a player's skater is, as their pose updates tell the server
local function SkaterPos(ply) return IsValid(ply) and ply.SkateGMHips or nil end
MELON.SkaterPos = SkaterPos

---------------------------------------------------------------------------
-- what every client sees
---------------------------------------------------------------------------
local function Public(now)
	local t = { phase = G.phase }
	if G.phase == "idle" then return t end
	t.host = IsValid(G.host) and G.host:EntIndex() or 0
	t.start, t.yaw, t.area, t.target = G.start, G.yaw or 0, G.area, G.target
	t.timeLeft = G.deadline and math.max(0, G.deadline - now) or 0
	t.king = IsValid(G.king) and G.king:EntIndex() or nil
	t.kingFor = IsValid(G.king) and (now - G.kingSince) or nil
	t.from = IsValid(G.kingFrom) and G.kingFrom:EntIndex() or nil
	t.melon = IsValid(G.melonEnt) and G.melonEnt:EntIndex() or nil
	t.dropper = IsValid(G.dropper) and G.dropper:EntIndex() or nil
	t.dropLock = G.dropAt and math.max(0, G.dropAt + MELON.DROP_LOCK - now) or nil
	t.dropIn = G.dropTime and math.max(0, G.dropTime - now) or nil
	t.players = {}
	for _, p in ipairs(G.players) do
		local e = G.entries[Key(p)]
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), held = e.held or 0, playing = e.playing }
	end
	t.winner = G.winner
	return t
end

local function Broadcast(now)
	MELON.mode:Broadcast(Public(now or CurTime()), now)
	G.lastBroadcast = now or CurTime()
end
MELON.Broadcast = Broadcast

---------------------------------------------------------------------------
-- the melon
---------------------------------------------------------------------------
local function RemoveMelon()
	if IsValid(G.melonEnt) then G.melonEnt:Remove() end
	G.melonEnt, G.lostSince = nil, nil
end

local function MakeMelon(pos, vel)
	RemoveMelon()
	local e = ents.Create("prop_physics")
	if not IsValid(e) then return nil end
	e:SetModel(MELON.MODEL)
	e:SetPos(pos)
	e:SetAngles(Angle(0, math.random(0, 359), 0))
	e.SkateGMMelon = true
	e:SetNWBool("SkateGMMelon", true)
	-- (a watermelon is breakable: falling into the area it smashed on landing)
	e:SetKeyValue("physdamagescale", "0")
	e:SetKeyValue("minhealthdmg", "999999")
	e:SetKeyValue("spawnflags", "256")
	e:Spawn()
	e:SetCollisionGroup(COLLISION_GROUP_WEAPON)
	local phys = e:GetPhysicsObject()
	if IsValid(phys) then
		phys:Wake()
		if vel then phys:SetVelocity(vel) end
	end
	G.melonEnt = e
	return e
end

-- a random spot on the ground inside the area, the melon falling onto it.
-- Searched from the area's own height (from above it found roofs, and a
-- start inside the sky's solid found nothing): up to the ceiling or the drop
-- height, then down from there to the ground.
function MELON.DropSpot(area)
	local mask = MASK_SOLID
	for _ = 1, 16 do
		local a, r = math.random() * math.pi * 2, math.sqrt(math.random()) * area[4] * 0.8
		local x, y = area[1] + math.cos(a) * r, area[2] + math.sin(a) * r
		local from = Vector(x, y, area[3] + 48)
		if not util.TraceLine({ start = from, endpos = from + Vector(0, 0, 1), mask = mask }).StartSolid then
			local up = util.TraceLine({ start = from, endpos = from + Vector(0, 0, MELON.DROP_HEIGHT), mask = mask })
			local top = up.HitPos - Vector(0, 0, 16)
			local down = util.TraceLine({ start = top, endpos = top - Vector(0, 0, 4096), mask = mask })
			if down.Hit and not down.StartSolid and not down.HitSky and down.HitNormal.z > 0.5 and down.HitPos.z > area[3] - 1024 then
				return top
			end
		end
	end
	return Vector(area[1], area[2], area[3] + 64)
end

local function DropFromSky(now)
	G.dropTime = nil
	MakeMelon(MELON.DropSpot(G.area))
	Tell(nil, "the melon is loose!")
	Broadcast(now)
end

local function Seize(ply, from, now)
	RemoveMelon()
	G.king, G.kingSince = ply, now
	G.kingFrom, G.kingFromAt = from, from and now or nil
	G.dropper, G.dropAt = nil, nil
	Tell(nil, ply:Nick() .. " seized the melon!")
	Broadcast(now)
end
MELON.Seize = Seize

local function Drop(now, pos, why)
	local king = G.king
	if not king then return end
	local valid = IsValid(king)
	local e = G.entries and G.keys and G.keys[king] and G.entries[G.keys[king]]
	local name = valid and king:Nick() or (e and e.name) or "the Melon King"
	G.king, G.kingSince, G.kingFrom = nil, nil, nil
	G.dropper, G.dropAt = valid and king or nil, now
	pos = pos or SkaterPos(king) or G.kingPos or Vector(G.area[1], G.area[2], G.area[3])
	MakeMelon(pos + Vector(0, 0, 24), Vector(math.Rand(-60, 60), math.Rand(-60, 60), 180))
	Tell(nil, name .. " " .. (why or "bailed") .. " and dropped the melon!")
	Broadcast(now)
end
MELON.Drop = Drop

---------------------------------------------------------------------------
-- flow
---------------------------------------------------------------------------
local function Stop(reason, now)
	RemoveMelon()
	for k in pairs(G) do G[k] = nil end
	G.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
MELON.Stop = Stop

local function ToLobby(now)
	RemoveMelon()
	G.phase, G.deadline, G.winner = "lobby", nil, nil
	G.king, G.kingFrom, G.dropper, G.dropAt, G.dropTime = nil, nil, nil, nil, nil
	for key, e in pairs(G.entries) do
		if e.left then G.entries[key] = nil else e.playing, e.held = nil, 0 end
	end
	Broadcast(now)
end

local function Results(now, winner)
	RemoveMelon()
	G.phase, G.deadline, G.king = "results", now + MELON.RESULTS, nil
	G.winner = winner and { name = winner:Nick(), ent = winner:EntIndex() } or nil
	Tell(nil, winner and (winner:Nick() .. " is the Melon King!") or "nobody won")
	Broadcast(now)
end

local function PlayingCount()
	local n = 0
	for _, p in ipairs(G.players) do if Playing(p) then n = n + 1 end end
	return n
end

local function Begin(now)
	local n = 0
	for _, p in ipairs(G.players) do
		local e = G.entries[Key(p)]
		e.playing = Skating(p) or nil
		e.held = 0
		if e.playing then n = n + 1 else Tell(p, "not in Skater mode yet: you sit this one out") end
	end
	if n < 2 then return Tell(G.host, "Melon King needs at least two skaters in Skater mode") end
	G.phase, G.deadline, G.winner = "countdown", now + MELON.COUNTDOWN, nil
	Broadcast(now)
end

local function Go(now)
	G.phase, G.deadline = "playing", nil
	G.dropTime, G.lastTick = now + MELON.FIRST_DROP, now
	Broadcast(now)
end

local function AddPlayer(ply, now)
	if IndexOf(ply) then return end
	if #G.players >= MELON.MAX_PLAYERS then return Tell(ply, "the game is full") end
	local e = G.entries[Key(ply)]
	if e then e.left = nil else G.entries[Key(ply)] = { name = ply:Nick(), held = 0 } end
	G.players[#G.players + 1] = ply
	G.keys[ply] = Key(ply)
	Tell(nil, ply:Nick() .. " joined Melon King")
	Broadcast(now)
end

local function RemovePlayer(ply, now, quiet)
	local i = IndexOf(ply)
	if not i then return end
	if G.king == ply then Drop(now, nil, "left") end
	table.remove(G.players, i)
	G.entries[Key(ply)] = nil
	G.keys[ply] = nil
	if G.kingFrom == ply then G.kingFrom = nil end
	if G.dropper == ply then G.dropper = nil end
	if ply == G.host then
		G.host = G.players[1]
		if not IsValid(G.host) then return Stop("the host left: Melon King closed", now) end
		Tell(G.host, "you're the Melon King host now")
	end
	if not quiet then Tell(nil, (IsValid(ply) and ply:Nick() or "someone") .. " left Melon King") end
	if G.phase == "playing" and PlayingCount() < 2 then
		local last
		for _, p in ipairs(G.players) do if Playing(p) then last = p end end
		return Results(now, last)
	end
	Broadcast(now)
end

---------------------------------------------------------------------------
-- touches (each skater's own game sees them; the server checks they're near)
---------------------------------------------------------------------------
local SLACK = 96 -- network lag: how far off the server's idea of a skater may be

function MELON.Grab(ply, now)
	if G.phase ~= "playing" or IsValid(G.king) or not IsValid(G.melonEnt) then return false end
	if not (Playing(ply) and Skating(ply)) then return false end
	if ply == G.dropper and now - (G.dropAt or 0) < MELON.DROP_LOCK then return false end
	local pos = SkaterPos(ply)
	if not pos or pos:Distance(G.melonEnt:GetPos()) > MELON.GRAB_RADIUS + SLACK then return false end
	Seize(ply, nil, now)
	return true
end

function MELON.Steal(ply, target, now)
	if G.phase ~= "playing" or target ~= G.king or not IsValid(target) or target == ply then return false end
	if not (Playing(ply) and Skating(ply)) then return false end
	if now - (G.kingSince or now) < MELON.HOLD_GRACE then return false end
	if ply == G.kingFrom and now - (G.kingFromAt or 0) < MELON.NO_TAGBACK then return false end
	local a, b = SkaterPos(ply), SkaterPos(target)
	if not (a and b) or a:Distance(b) > MELON.STEAL_RADIUS + SLACK then return false end
	Seize(ply, target, now)
	return true
end

function MELON.Bail(ply, pos, now)
	if G.phase ~= "playing" or ply ~= G.king then return false end
	local here = SkaterPos(ply)
	local p = pos and V(pos)
	if not p or (here and p:Distance(here) > 200) then p = here end
	Drop(now, p, "bailed")
	return true
end

---------------------------------------------------------------------------
-- commands (from the menu, chat or the console)
---------------------------------------------------------------------------
function MELON.Command(ply, m, now)
	now = now or CurTime()
	if type(m) ~= "table" or type(m.cmd) ~= "string" then return end
	local cmd = m.cmd
	local host = G.phase ~= "idle" and ply == G.host
	if not MELON.Allowed() and cmd ~= "leave" then return Tell(ply, "Melon King is turned off on this server") end
	if cmd == "create" then
		if G.phase ~= "idle" then return Tell(ply, "a game is already set up: join it") end
		if MELON.mode:CantSkate(ply, m, "host") then return end
		local p = Vec(m.pos)
		if not p then return end
		local c = Vec(m.centre) or p
		G.phase, G.host, G.players, G.entries, G.keys = "lobby", ply, {}, {}, {}
		G.start, G.yaw = p, math.NormalizeAngle(tonumber(m.yaw) or 0)
		G.area = { c[1], c[2], c[3], MELON.ClampArea(m.radius) }
		G.target = MELON.ClampTarget(m.target)
		G.items = m.items == true
		AddPlayer(ply, now)
		Tell(nil, ply:Nick() .. " is hosting Melon King: join with LB + D-pad left")
	elseif cmd == "join" then
		if G.phase ~= "lobby" then return Tell(ply, G.phase == "idle" and "no game set up: !melon create starts one" or "a game is on: wait for the next one") end
		if MELON.mode:CantSkate(ply, m, "play") then return end
		AddPlayer(ply, now)
	elseif cmd == "leave" then
		RemovePlayer(ply, now)
	elseif cmd == "settings" then
		if not host then return Tell(ply, "only the host can change the settings") end
		if G.phase ~= "lobby" then return Tell(ply, "settings can be changed between games") end
		G.target = MELON.ClampTarget(m.target or G.target)
		if m.radius then G.area[4] = MELON.ClampArea(m.radius) end
		Broadcast(now)
		Tell(nil, string.format("hold the melon for %d s to win; the area is %d units across", G.target, G.area[4] * 2))
	elseif cmd == "begin" then
		if not host then return Tell(ply, "only the host can start") end
		if G.phase ~= "lobby" then return end
		Begin(now)
	elseif cmd == "stop" then
		if G.phase == "idle" then return end
		if not (host or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
		if G.phase == "lobby" or m.close then Stop("Melon King was closed by " .. ply:Nick(), now) else ToLobby(now) Tell(nil, ply:Nick() .. " stopped the game") end
	elseif cmd == "grab" then
		MELON.Grab(ply, now)
	elseif cmd == "steal" then
		local target
		for _, p in ipairs(G.players or {}) do if p:EntIndex() == tonumber(m.target) then target = p end end
		MELON.Steal(ply, target, now)
	elseif cmd == "bail" then
		MELON.Bail(ply, m.pos, now)
	elseif cmd == "outside" then
		if G.phase == "playing" and ply == G.king then Drop(now, MELON.DropSpot(G.area), "left the area") end
	end
end

function MELON.Think(now)
	if G.phase == "idle" then return end
	if ITEMS and ITEMS.server and G.area then
		ITEMS.server.Sync(MELON.mode, G, { on = G.items, centre = Vector(G.area[1], G.area[2], G.area[3]), radius = G.area[4] })
	end
	for i = #(G.players or {}), 1, -1 do
		if not IsValid(G.players[i]) then RemovePlayer(G.players[i], now, true) if G.phase == "idle" then return end end
	end
	if G.phase == "countdown" and now >= G.deadline then Go(now)
	elseif G.phase == "results" and now >= G.deadline then ToLobby(now)
	elseif G.phase == "playing" then
		local dt = math.max(0, now - (G.lastTick or now))
		G.lastTick = now
		local king = G.king
		if IsValid(king) then
			G.kingPos = SkaterPos(king) or G.kingPos
			if not Skating(king) then
				Drop(now, nil, "left Skater mode")
			else
				local e = Entry(king)
				-- the clock only runs inside the area
				if e and MELON.InArea(G.area, SkaterPos(king)) then
					e.held = (e.held or 0) + dt
					if e.held >= G.target then return Results(now, king) end
				end
			end
		elseif G.dropTime then
			if now >= G.dropTime then DropFromSky(now) end
		elseif not IsValid(G.melonEnt) then
			G.dropTime = now + 1
		else
			local pos = G.melonEnt:GetPos()
			local out = not MELON.InArea(G.area, pos) or pos.z < G.area[3] - 2048
			if out then
				G.lostSince = G.lostSince or now
				if now - G.lostSince > MELON.LOST_AFTER then
					RemoveMelon()
					G.dropTime = now + 0.5
					Tell(nil, "the melon rolled away: a new one drops in")
				end
			else
				G.lostSince = nil
			end
		end
	end
	if now - (G.lastBroadcast or 0) >= 0.5 then Broadcast(now) end
end

MELON.mode:OnThink(function(now) MELON.Think(now) end)
MELON.mode:OnPlayerLeave(function()
	if G.phase ~= "idle" then timer.Simple(0, function() MELON.mode:RunThink(CurTime()) end) end
end)
MELON.mode:OnCommand(function(ply, m) MELON.Command(ply, m) end)
MELON.mode:OnPlayerJoin(function(ply)
	if G.phase ~= "idle" then timer.Simple(3, function() if IsValid(ply) then Broadcast() end end) end
end)
MELON.mode:OnDisallowed(function() if G.phase ~= "idle" then Stop("Melon King was turned off on this server") end end)

-- nobody carries the melon off with the physgun, gravity gun or toolgun
local function NotTheMelon(_, ent) if IsValid(ent) and ent.SkateGMMelon then return false end end
hook.Add("PhysgunPickup", "skategm_melon", NotTheMelon)
hook.Add("GravGunPickupAllowed", "skategm_melon", NotTheMelon)
hook.Add("GravGunPunt", "skategm_melon", NotTheMelon)
hook.Add("CanTool", "skategm_melon", function(_, tr) if tr and IsValid(tr.Entity) and tr.Entity.SkateGMMelon then return false end end)
hook.Add("CanPlayerUnfreeze", "skategm_melon", NotTheMelon)
hook.Add("EntityTakeDamage", "skategm_melon", function(ent) if IsValid(ent) and ent.SkateGMMelon then return true end end)
