-- Hot Potato, server: the game, the bomb and its fuse. Uses only SkateGM.API
-- from the skating add-on.

local G = { phase = "idle" }
POTATO.session = G
POTATO.mode:UseSessions(G)

local API, Allowed, Skating = SKATEGM_MODES.API, SKATEGM_MODES.Allowed, SKATEGM_MODES.Skating

local function Tell(ply, text) POTATO.mode:Tell(ply, text) end

-- (remembered when they join: a player who just disconnected can't be asked)
local function Key(ply) return SKATEGM_MODES.Key(ply, G.keys) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(G.players, ply) end
local function Entry(ply) return IndexOf(ply) and G.entries[Key(ply)] or nil end
local function Alive(ply) local e = Entry(ply) return e ~= nil and e.playing and not e.out end

local Vec = SKATEGM_MODES.Vec

---------------------------------------------------------------------------
-- what every client sees (when the bomb goes off isn't in it: only how much
-- of its fuse is left, for the ticking)
---------------------------------------------------------------------------
local function Public(now)
	local t = { phase = G.phase }
	if G.phase == "idle" then return t end
	t.host = IsValid(G.host) and G.host:EntIndex() or 0
	t.start, t.yaw = G.start, G.yaw or 0
	t.fuse, t.lives = G.fuse, G.lives
	t.timeLeft = G.deadline and math.max(0, G.deadline - now) or 0
	if IsValid(G.holder) then
		t.holder = G.holder:EntIndex()
		t.ticking = math.Clamp((G.fuseAt - now) / G.fuseLen, 0, 1)
		t.fuseLen = G.fuseLen
		t.from = IsValid(G.passedFrom) and G.passedFrom:EntIndex() or 0
	end
	t.armIn = G.armAt and math.max(0, G.armAt - now) or nil
	t.players = {}
	for _, p in ipairs(G.players) do
		local e = G.entries[Key(p)]
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), lives = e.lives, out = e.out, playing = e.playing, booms = e.booms or 0 }
	end
	t.boom = G.boom
	t.winner = G.winner
	return t
end

local function Broadcast(now)
	POTATO.mode:Broadcast(Public(now or CurTime()), now)
	G.lastBroadcast = now or CurTime()
end
POTATO.Broadcast = Broadcast

---------------------------------------------------------------------------
-- flow
---------------------------------------------------------------------------
local function Stop(reason, now)
	for k in pairs(G) do G[k] = nil end
	G.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
POTATO.Stop = Stop

local function ToLobby(now)
	G.phase, G.deadline, G.winner, G.boom = "lobby", nil, nil, nil
	G.holder, G.armAt, G.passedFrom = nil, nil, nil
	for key, e in pairs(G.entries) do
		if e.left then G.entries[key] = nil else e.playing, e.out, e.lives, e.booms = nil, nil, nil, nil end
	end
	Broadcast(now)
end

local function AlivePlayers()
	local list = {}
	for _, p in ipairs(G.players) do if Alive(p) then list[#list + 1] = p end end
	return list
end

local function Results(now, why)
	G.phase, G.deadline, G.holder, G.armAt = "results", now + POTATO.RESULTS, nil, nil
	local alive = AlivePlayers()
	if #alive == 1 then
		G.winner = { name = alive[1]:Nick() }
		Tell(nil, alive[1]:Nick() .. " survived the bomb and wins!")
	else
		G.winner = nil
		Tell(nil, why or "nobody's left")
	end
	Broadcast(now)
end

-- a fresh bomb, to someone still in (not `avoid` if anyone else is)
local function NewBomb(now, avoid)
	local alive = AlivePlayers()
	if #alive <= 1 then return Results(now, "the game's over") end
	local pick = {}
	for _, p in ipairs(alive) do if p ~= avoid then pick[#pick + 1] = p end end
	if #pick == 0 then pick = alive end
	G.holder = pick[math.random(#pick)]
	G.fuseLen = G.fuse * (1 + POTATO.FUSE_SPREAD * (2 * math.random() - 1))
	G.fuseAt, G.heldSince = now + G.fuseLen, now
	G.passedFrom, G.passedAt, G.armAt = nil, nil, nil
	Tell(nil, G.holder:Nick() .. " has the bomb!")
	Broadcast(now)
end

local function Boom(now, why)
	local p = G.holder
	G.holder = nil
	if not IsValid(p) then return NewBomb(now) end
	local e = G.entries[Key(p)]
	e.lives = e.lives - 1
	e.booms = (e.booms or 0) + 1
	G.boomId = (G.boomId or 0) + 1
	G.boom = { id = G.boomId, ent = p:EntIndex(), name = p:Nick() }
	if e.lives <= 0 then
		e.out = true
		Tell(nil, string.format("BOOM! %s %s - and they're out", p:Nick(), why or "was holding it"))
	else
		Tell(nil, string.format("BOOM! %s %s (%d %s left)", p:Nick(), why or "was holding it", e.lives, e.lives == 1 and "life" or "lives"))
	end
	if #AlivePlayers() <= 1 then return Results(now, "the game's over") end
	G.armAt, G.avoid = now + POTATO.BETWEEN, p
	Broadcast(now)
end

-- the host pressed start: everyone in Skater mode plays; anyone still
-- loading sits this one out
local function Begin(now)
	local n = 0
	for _, p in ipairs(G.players) do
		local e = G.entries[Key(p)]
		e.playing = Skating(p) or nil
		e.lives, e.out, e.booms = G.lives, nil, 0
		if e.playing then n = n + 1 else Tell(p, "not in Skater mode yet: you sit this one out") end
	end
	if n < 2 then return Tell(G.host, "Hot Potato needs at least two skaters in Skater mode") end
	G.phase, G.deadline, G.boom, G.winner = "countdown", now + POTATO.COUNTDOWN, nil, nil
	Broadcast(now)
end

local function Go(now)
	G.phase, G.deadline = "playing", nil
	G.armAt, G.avoid = now + POTATO.SCATTER, nil
	Broadcast(now)
end

local function AddPlayer(ply, now)
	if IndexOf(ply) then return end
	if #G.players >= POTATO.MAX_PLAYERS then return Tell(ply, "the game is full") end
	local e = G.entries[Key(ply)]
	if e then e.left = nil else G.entries[Key(ply)] = { name = ply:Nick() } end
	G.players[#G.players + 1] = ply
	G.keys[ply] = Key(ply)
	Tell(nil, ply:Nick() .. " joined Hot Potato")
	Broadcast(now)
end

local function RemovePlayer(ply, now, quiet)
	local i = IndexOf(ply)
	if not i then return end
	local key = Key(ply)
	local wasHolder = G.holder == ply
	table.remove(G.players, i)
	G.keys[ply] = nil
	G.entries[key] = nil
	if G.passedFrom == ply then G.passedFrom = nil end
	if ply == G.host then
		G.host = G.players[1]
		if not IsValid(G.host) then return Stop("the host left: Hot Potato closed", now) end
		Tell(G.host, "you're the Hot Potato host now")
	end
	if not quiet then Tell(nil, (IsValid(ply) and ply:Nick() or "someone") .. " left Hot Potato") end
	if G.phase == "playing" then
		if #AlivePlayers() <= 1 then return Results(now, "everyone else left") end
		-- the bomb doesn't leave with them: it jumps to someone else, fuse still burning
		if wasHolder then
			local alive = AlivePlayers()
			G.holder, G.heldSince, G.passedFrom = alive[math.random(#alive)], now, nil
			Tell(nil, "the bomb jumped to " .. G.holder:Nick() .. "!")
		end
	end
	Broadcast(now)
end

---------------------------------------------------------------------------
-- passing: the holder's game saw them skate into someone
---------------------------------------------------------------------------
function POTATO.Pass(ply, target, now)
	if G.phase ~= "playing" or ply ~= G.holder then return end
	if now - (G.heldSince or now) < POTATO.HOLD_GRACE then return end
	if not (IsValid(target) and target ~= ply and Alive(target) and Skating(target)) then return end
	if target == G.passedFrom and now - (G.passedAt or 0) < POTATO.NO_TAGBACK then return end
	G.passedFrom, G.passedAt = ply, now
	G.holder, G.heldSince = target, now
	Broadcast(now)
end

---------------------------------------------------------------------------
-- commands (from the menu, chat or the console)
---------------------------------------------------------------------------
function POTATO.Command(ply, m, now)
	now = now or CurTime()
	if type(m) ~= "table" or type(m.cmd) ~= "string" then return end
	local cmd = m.cmd
	local host = G.phase ~= "idle" and ply == G.host
	if not POTATO.Allowed() and cmd ~= "leave" then return Tell(ply, "Hot Potato is turned off on this server") end
	if cmd == "create" then
		if G.phase ~= "idle" then return Tell(ply, "a game is already set up: join it") end
		if POTATO.mode:CantSkate(ply, m, "host") then return end
		local p = Vec(m.pos)
		if not p then return end
		G.phase, G.host, G.players, G.entries, G.keys = "lobby", ply, {}, {}, {}
		G.start, G.yaw = p, math.NormalizeAngle(tonumber(m.yaw) or 0)
		G.fuse, G.lives = POTATO.ClampFuse(m.fuse), POTATO.ClampLives(m.lives)
		G.items = m.items == true
		AddPlayer(ply, now)
		Tell(nil, ply:Nick() .. " is hosting Hot Potato: join with LB + D-pad left")
	elseif cmd == "join" then
		if G.phase ~= "lobby" then return Tell(ply, G.phase == "idle" and "no game set up: !potato create starts one" or "a game is on: wait for the next one") end
		if POTATO.mode:CantSkate(ply, m, "play") then return end
		AddPlayer(ply, now)
	elseif cmd == "leave" then
		RemovePlayer(ply, now)
	elseif cmd == "startpoint" then
		if not host or G.phase ~= "lobby" then return end
		local p = Vec(m.pos)
		if not p then return end
		G.start, G.yaw = p, math.NormalizeAngle(tonumber(m.yaw) or 0)
		Broadcast(now)
	elseif cmd == "settings" then
		if not host then return Tell(ply, "only the host can change the settings") end
		if G.phase ~= "lobby" then return Tell(ply, "settings can be changed between games") end
		G.fuse, G.lives = POTATO.ClampFuse(m.fuse or G.fuse), POTATO.ClampLives(m.lives or G.lives)
		Broadcast(now)
		Tell(nil, string.format("fuse about %d s, %d %s each", G.fuse, G.lives, G.lives == 1 and "life" or "lives"))
	elseif cmd == "begin" then
		if not host then return Tell(ply, "only the host can start") end
		if G.phase ~= "lobby" then return end
		Begin(now)
	elseif cmd == "stop" then
		if G.phase == "idle" then return end
		if not (host or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
		if G.phase == "lobby" or m.close then Stop("Hot Potato was closed by " .. ply:Nick(), now) else ToLobby(now) Tell(nil, ply:Nick() .. " stopped the game") end
	elseif cmd == "pass" then
		local target
		for _, p in ipairs(G.players or {}) do if p:EntIndex() == tonumber(m.target) then target = p end end
		POTATO.Pass(ply, target, now)
	end
end

POTATO.ITEM_AREA = 2000
function POTATO.Think(now)
	if G.phase == "idle" then return end
	if ITEMS and ITEMS.server and G.start then
		ITEMS.server.Sync(POTATO.mode, G, { on = G.items, centre = Vector(G.start[1], G.start[2], G.start[3]), radius = POTATO.ITEM_AREA })
	end
	for i = #(G.players or {}), 1, -1 do
		if not IsValid(G.players[i]) then RemovePlayer(G.players[i], now, true) if G.phase == "idle" then return end end
	end
	if G.phase == "countdown" and now >= G.deadline then Go(now)
	elseif G.phase == "results" and now >= G.deadline then ToLobby(now)
	elseif G.phase == "playing" then
		-- a skater still in who drops out of Skater mode is out of the game
		for _, p in ipairs(G.players) do
			local e = G.entries[Key(p)]
			if Alive(p) and not Skating(p) then
				e.offSince = e.offSince or now
				if now - e.offSince > 1 then
					if G.holder == p then Boom(now, "ran off with it") if G.phase ~= "playing" then return end end
					e.out, e.lives = true, 0
					Tell(p, "you left Skater mode: you're out of this game")
					if #AlivePlayers() <= 1 then return Results(now, "the game's over") end
				end
			else
				e.offSince = nil
			end
		end
		if G.armAt and now >= G.armAt then
			local avoid = G.avoid
			G.avoid = nil
			return NewBomb(now, avoid)
		end
		if IsValid(G.holder) and now >= G.fuseAt then return Boom(now) end
	end
	if now - (G.lastBroadcast or 0) >= 0.5 then Broadcast(now) end
end

POTATO.mode:OnThink(function(now) POTATO.Think(now) end)
POTATO.mode:OnPlayerLeave(function(ply)
	if G.phase ~= "idle" then timer.Simple(0, function() POTATO.mode:RunThink(CurTime()) end) end
end)

POTATO.mode:OnCommand(function(ply, m) POTATO.Command(ply, m) end)

POTATO.mode:OnPlayerJoin(function(ply)
	if G.phase ~= "idle" then timer.Simple(3, function() if IsValid(ply) then Broadcast() end end) end
end)

-- turned off mid-game: it ends
POTATO.mode:OnDisallowed(function() if G.phase ~= "idle" then Stop("Hot Potato was turned off on this server") end end)
