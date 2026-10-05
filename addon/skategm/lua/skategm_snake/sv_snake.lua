util.AddNetworkString(SNAKE.NET_TRAIL)

local G = { phase = "idle" }
SNAKE.session = G
SNAKE.mode:UseSessions(G)

local Allowed, Skating = SKATEGM_MODES.Allowed, SKATEGM_MODES.Skating
local function Tell(ply, text) SNAKE.mode:Tell(ply, text) end

local function IndexOf(ply) return SKATEGM_MODES.IndexOf(G.players, ply) end
local function Entry(ply) return IndexOf(ply) and G.entries[ply] or nil end
local function Alive(ply) local e = Entry(ply) return e ~= nil and e.playing and not e.out end

local Num = SKATEGM_MODES.Num

local function Ground(x, y, z) return SKATEGM_MODES.Ground(x, y, z) end

local function Public(now)
	local t = { phase = G.phase }
	if G.phase == "idle" then return t end
	t.host = IsValid(G.host) and G.host:EntIndex() or 0
	t.area = G.area
	t.time, t.length, t.pelletCount = G.time, G.length, G.pelletCount
	t.timeLeft = G.deadline and math.max(0, G.deadline - now) or 0
	t.players = {}
	for _, p in ipairs(G.players) do
		local e = G.entries[p]
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), slot = e.slot, playing = e.playing, out = e.out, length = e.length, eaten = e.eaten or 0, start = e.start, yaw = e.yaw, place = e.place }
	end
	t.pellets = G.pellets
	t.winner = G.winner
	return t
end

local function Broadcast(now)
	SNAKE.mode:Broadcast(Public(now or CurTime()), now)
	G.lastBroadcast = now or CurTime()
end
SNAKE.Broadcast = Broadcast

local function SendTrail(ply, pts, clear)
	net.Start(SNAKE.NET_TRAIL)
	net.WriteString(util.TableToJSON({ ent = ply:EntIndex(), p = pts, len = G.entries[ply] and G.entries[ply].length or 0, clear = clear }))
	net.Broadcast()
end

local function Stop(reason, now)
	for k in pairs(G) do G[k] = nil end
	G.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
SNAKE.Stop = Stop

local function ToLobby(now)
	G.phase, G.deadline, G.winner, G.pellets = "lobby", nil, nil, {}
	for _, e in pairs(G.entries) do e.playing, e.out, e.place, e.trail, e.pending, e.eaten = nil, nil, nil, nil, nil, nil end
	Broadcast(now)
end

local function NewPellet(id)
	local a = G.area
	local ang, r = math.random() * math.pi * 2, math.sqrt(math.random()) * a[4] * 0.9
	local x, y = a[1] + math.cos(ang) * r, a[2] + math.sin(ang) * r
	return { id = id, x = x, y = y, z = Ground(x, y, a[3]) }
end

local function AliveList()
	local list = {}
	for _, p in ipairs(G.players) do if Alive(p) then list[#list + 1] = p end end
	return list
end

local function Results(now, why)
	G.phase, G.deadline = "results", now + SNAKE.RESULTS
	local best, bestLen
	local alive = AliveList()
	if #alive == 1 and G.started > 1 then
		best = alive[1]
	else
		for _, p in ipairs(alive) do
			local e = G.entries[p]
			if not bestLen or e.length > bestLen then best, bestLen = p, e.length end
		end
	end
	if best then
		G.winner = { name = best:Nick(), ent = best:EntIndex() }
		Tell(nil, best:Nick() .. " wins Snake" .. (why and (" (" .. why .. ")") or ""))
	else
		G.winner = nil
		Tell(nil, "nobody survived")
	end
	Broadcast(now)
end

local function Begin(now)
	local n = 0
	for _, p in ipairs(G.players) do
		local e = G.entries[p]
		e.playing = Skating(p) or nil
		if e.playing then n = n + 1 else Tell(p, "not in Skater mode yet: you sit this one out") end
	end
	if n < 1 then return Tell(G.host, "nobody's in Skater mode yet") end
	local a, i = G.area, 0
	for _, p in ipairs(G.players) do
		local e = G.entries[p]
		if e.playing then
			local ang = i / n * math.pi * 2
			local x, y = a[1] + math.cos(ang) * a[4] * 0.6, a[2] + math.sin(ang) * a[4] * 0.6
			e.start = { x, y, Ground(x, y, a[3]) }
			e.yaw = math.deg(ang) + 90
			e.length, e.trail, e.pending, e.eaten, e.out, e.place = G.length, {}, {}, 0, nil, nil
			SendTrail(p, {}, true)
			i = i + 1
		end
	end
	G.started = n
	G.pellets = {}
	for k = 1, G.pelletCount do G.pellets[k] = NewPellet(k) end
	G.phase, G.deadline, G.winner = "countdown", now + SNAKE.COUNTDOWN, nil
	Broadcast(now)
end

local function AddPlayer(ply, now)
	if IndexOf(ply) then return end
	if #G.players >= SNAKE.MAX_PLAYERS then return Tell(ply, "the game is full") end
	local used = {}
	for _, e in pairs(G.entries) do used[e.slot] = true end
	local slot = 1
	while used[slot] do slot = slot + 1 end
	G.entries[ply] = { name = ply:Nick(), slot = slot, length = G.length }
	G.players[#G.players + 1] = ply
	Tell(nil, ply:Nick() .. " joined Snake")
	Broadcast(now)
end

local function Out(ply, now, why)
	local e = Entry(ply)
	if not e or not e.playing or e.out then return end
	e.out = true
	e.place = #AliveList() + 1
	SendTrail(ply, {}, true)
	e.trail = {}
	Tell(nil, ply:Nick() .. " is out" .. (why and (": " .. why) or ""))
	local alive = AliveList()
	if (G.started > 1 and #alive <= 1) or #alive == 0 then return Results(now) end
	Broadcast(now)
end

local function RemovePlayer(ply, now)
	local i = IndexOf(ply)
	if not i then return end
	if G.phase == "playing" then Out(ply, now, "left") end
	table.remove(G.players, i)
	G.entries[ply] = nil
	if ply == G.host then
		G.host = G.players[1]
		if not IsValid(G.host) then return Stop("the host left: Snake closed", now) end
		Tell(G.host, "you're the Snake host now")
	end
	Broadcast(now)
end

function SNAKE.Command(ply, m, now)
	now = now or CurTime()
	if type(m) ~= "table" then return end
	local cmd = m.cmd
	local host = G.phase ~= "idle" and ply == G.host
	if not SNAKE.Allowed() and cmd ~= "leave" then return Tell(ply, "Snake is turned off on this server") end
	if cmd == "create" then
		if G.phase ~= "idle" then return Tell(ply, "a game is already set up: join it") end
		if not Allowed(ply) then return Tell(ply, "you're not allowed to skate on this server") end
		if not m.canSkate then return Tell(ply, "you need Skater mode working to host") end
		local x, y, z = Num(m.x), Num(m.y), Num(m.z)
		if not (x and y and z) then return end
		G.phase, G.host, G.players, G.entries = "lobby", ply, {}, {}
		G.area = { x, y, z, SNAKE.ClampRadius(m.radius) }
		G.time, G.length, G.pelletCount = SNAKE.ClampTime(m.time), SNAKE.ClampLength(m.length), SNAKE.ClampPellets(m.pellets)
		G.pellets = {}
		AddPlayer(ply, now)
		Tell(nil, ply:Nick() .. " is hosting Snake: join with LB + D-pad left")
	elseif cmd == "join" then
		if G.phase ~= "lobby" then return Tell(ply, G.phase == "idle" and "no game set up" or "a game is on: wait for the next one") end
		if not Allowed(ply) then return Tell(ply, "you're not allowed to skate on this server") end
		if not m.canSkate then return Tell(ply, "you need Skater mode working to play") end
		AddPlayer(ply, now)
	elseif cmd == "leave" then
		RemovePlayer(ply, now)
	elseif cmd == "begin" then
		if not host then return Tell(ply, "only the host can start") end
		if G.phase ~= "lobby" then return end
		Begin(now)
	elseif cmd == "stop" then
		if G.phase == "idle" then return end
		if not (host or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
		if G.phase == "lobby" or m.close then Stop("Snake was closed by " .. ply:Nick(), now) else ToLobby(now) Tell(nil, ply:Nick() .. " stopped the game") end
	elseif cmd == "trail" then
		if G.phase ~= "playing" or not Alive(ply) or type(m.p) ~= "table" then return end
		local e = G.entries[ply]
		local a = G.area
		local added = 0
		for k = 1, math.min(#m.p, SNAKE.MAX_POINTS * 3) - 2, 3 do
			local x, y, z = Num(m.p[k]), Num(m.p[k + 1]), Num(m.p[k + 2])
			if x and y and z and (x - a[1]) ^ 2 + (y - a[2]) ^ 2 < (a[4] * 1.5) ^ 2 then
				e.trail[#e.trail + 1] = { x, y, z }
				e.pending[#e.pending + 1] = x
				e.pending[#e.pending + 1] = y
				e.pending[#e.pending + 1] = z
				added = added + 1
			end
		end
		if added > 0 then SNAKE.Trim(e.trail, e.length) end
	elseif cmd == "crash" then
		if G.phase ~= "playing" then return end
		local by = tonumber(m.by)
		local who = by and by > 0 and Entity(by)
		Out(ply, now, m.wall and "hit the wall" or (IsValid(who) and who ~= ply and ("hit " .. who:Nick() .. "'s tail")) or "hit their own tail")
	elseif cmd == "eat" then
		if G.phase ~= "playing" or not Alive(ply) then return end
		local id = tonumber(m.id)
		local pellet = id and G.pellets[id]
		local e = G.entries[ply]
		local head = e.trail[#e.trail]
		if not (pellet and head) then return end
		if (head[1] - pellet.x) ^ 2 + (head[2] - pellet.y) ^ 2 > (SNAKE.EAT_RADIUS * 3) ^ 2 then return end
		e.length = e.length + SNAKE.GROWTH
		e.eaten = (e.eaten or 0) + 1
		G.pellets[id] = NewPellet(id)
		Broadcast(now)
	end
end

function SNAKE.Think(now)
	if G.phase == "idle" or G.phase == "lobby" then return end
	if G.phase == "countdown" and now >= G.deadline then
		G.phase, G.deadline = "playing", now + G.time
		Broadcast(now)
	elseif G.phase == "playing" then
		if now >= G.deadline then return Results(now, "time's up: longest tail") end
		if now >= (G.nextTrail or 0) then
			G.nextTrail = now + 0.15
			for _, p in ipairs(G.players) do
				local e = G.entries[p]
				if e.pending and #e.pending > 0 then
					SendTrail(p, e.pending)
					e.pending = {}
				end
			end
		end
	elseif G.phase == "results" and now >= G.deadline then
		ToLobby(now)
	end
	if now - (G.lastBroadcast or 0) >= 0.5 then Broadcast(now) end
end

SNAKE.mode:OnThink(function(now) SNAKE.Think(now) end)
SNAKE.mode:OnCommand(function(ply, m) SNAKE.Command(ply, m) end)
SNAKE.mode:OnPlayerLeave(function(ply) if G.phase ~= "idle" then RemovePlayer(ply, CurTime()) end end)
SNAKE.mode:OnPlayerJoin(function(ply) if G.phase ~= "idle" then timer.Simple(3, function() if IsValid(ply) then Broadcast() end end) end end)
SNAKE.mode:OnDisallowed(function() if G.phase ~= "idle" then Stop("Snake was turned off on this server") end end)
