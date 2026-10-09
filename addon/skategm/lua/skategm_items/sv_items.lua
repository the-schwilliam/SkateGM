-- Items, server: arenas (one per minigame game that has items on), crates,
-- who holds what, uses and hits. Positions come from ply.SkateGMHips.
local IT = ITEMS
IT.server = IT.server or { arenas = {} }
local SV = IT.server
util.AddNetworkString(IT.NET)

local function Send(t, to)
	net.Start(IT.NET)
	net.WriteString(util.TableToJSON(t))
	if to then net.Send(to) else net.Broadcast() end
end
SV.Send = Send

local function V(t) return Vector(t[1], t[2], t[3]) end

local Arena = {}
Arena.__index = Arena
SV.Arena = Arena

-- run fn as the arena's game (a mode keeps several games in one table)
function Arena:InGame(fn, ...)
	local mode = self.mode
	if mode and mode.live and self.session ~= nil then
		local was = mode.current
		mode:Enter(self.session)
		local ok, err = pcall(fn, ...)
		if was ~= nil and was ~= self.session then mode:Enter(was) else mode:Settle() end
		if not ok then ErrorNoHalt("[SkateGM items] " .. tostring(err) .. "\n") end
		return
	end
	local ok, err = pcall(fn, ...)
	if not ok then ErrorNoHalt("[SkateGM items] " .. tostring(err) .. "\n") end
end

function Arena:Players()
	local out = {}
	for _, p in ipairs(self.players or {}) do if IsValid(p) then out[#out + 1] = p end end
	return out
end

function Arena:Has(ply)
	if not IsValid(ply) then return false end
	for _, p in ipairs(self.players or {}) do if p == ply then return not (self.canPlay and not self.canPlay(ply, self:Game())) end end
	return false
end

function Arena:Pos(ply) return ply.SkateGMHips or ply:GetPos() end

function Arena:Forward(ply)
	local h = self.hist[ply]
	if h and h.dir then return h.dir end
	local f = ply:EyeAngles():Forward()
	f.z = 0
	return f:GetNormalized()
end

function Arena:Fx(ev)
	ev.k, ev.a = "fx", self.id
	Send(ev)
end

function Arena:Later(delay, fn) self.timers[#self.timers + 1] = { at = CurTime() + delay, fn = fn } end

function Arena:Hit(victim, attacker, id)
	if not self:Has(victim) then return false end
	local now = CurTime()
	if (self.hitAt[victim] or 0) > now then return false end
	self.hitAt[victim] = now + 1.5
	Send({ k = "hit" }, victim)
	if self.onHit then self:InGame(self.onHit, victim, attacker, id) end
	return true
end

function Arena:Freeze(ply, seconds)
	if not self:Has(ply) then return false end
	Send({ k = "freeze", s = seconds }, ply)
	return true
end

function Arena:Give(ply, id)
	self.holding[ply] = { id = id, uses = IT.Get(id).uses }
	Send({ k = "hold", e = ply:EntIndex(), id = id, uses = self.holding[ply].uses })
end

function Arena:Drop(ply)
	if not self.holding[ply] then return end
	self.holding[ply] = nil
	if IsValid(ply) then Send({ k = "hold", e = ply:EntIndex() }) end
end

function Arena:Public()
	local crates = {}
	for i, c in ipairs(self.crates) do if c.alive then crates[#crates + 1] = { i, c.pos[1], c.pos[2], c.pos[3] } end end
	return { k = "arena", a = self.id, m = self.mode and self.mode.id or "", s = self.session, crates = crates }
end

-- a mode turns items on for one of its games:
-- ITEMS.server.Open(mode, session, { centre = Vector, radius = n, players = list (the game's own table),
--   onHit = function(victim, attacker, id) end (run as that game), canPlay = function(ply) end, crates = n })
function SV.Open(mode, session, opts)
	local id = (mode and mode.id or "items") .. ":" .. tostring(session or 0)
	SV.Close(SV.arenas[id])
	local centre = opts.centre
	local radius = opts.radius or 2000
	local count = opts.crates or math.Clamp(math.floor((radius / 300) ^ 2 * 0.6), 6, 40)
	local a = setmetatable({ id = id, mode = mode, session = session, centre = { centre.x, centre.y, centre.z }, radius = radius,
		players = opts.players or {}, onHit = opts.onHit, canPlay = opts.canPlay, crates = {}, holding = {}, objects = {},
		hist = {}, hitAt = {}, timers = {} }, Arena)
	for i, p in ipairs(IT.Spread(a.centre, radius, count)) do a.crates[i] = { pos = p, alive = true } end
	SV.arenas[id] = a
	Send(a:Public())
	return a
end

function SV.Close(a)
	if not a or SV.arenas[a.id] ~= a then return end
	for ply in pairs(a.holding) do a:Drop(ply) end
	SV.arenas[a.id] = nil
	a.closed = true
	Send({ k = "close", a = a.id })
end

-- the game this arena belongs to (its table), nil once it's gone
function Arena:Game()
	local mode = self.mode
	if not mode then return self.gameTable end
	if not mode.live then return mode.lastState end
	return mode:SessionData(self.session)
end

-- the one call a mode makes from its think: items on while its game is
-- being played (opts.on), off otherwise. G is the game's own table.
function SV.Sync(mode, G, opts)
	local playing = opts.on and SKATEGM_MODES.InPlay(G)
	if playing and not (G._items and not G._items.closed) then
		G._items = SV.Open(mode, mode.live and mode.current or nil, { centre = opts.centre, radius = opts.radius, players = G.players,
			onHit = opts.onHit, canPlay = opts.canPlay, crates = opts.crates })
	elseif not playing and G._items then
		SV.Close(G._items)
		G._items = nil
	end
	return G._items
end

function SV.ArenaOf(ply)
	for _, a in pairs(SV.arenas) do if a:Has(ply) then return a end end
end

function SV.Think(now)
	for _, a in pairs(SV.arenas) do
		local game = a:Game()
		if not (game and game._items == a and SKATEGM_MODES.InPlay(game)) and a.mode then
			SV.Close(a)
		end
	end
	for _, a in pairs(SV.arenas) do
		for i, c in ipairs(a.crates) do
			if not c.alive and now >= c.back then
				c.pos, c.alive = IT.RandomSpot(a.centre, a.radius), true
				Send({ k = "crate", a = a.id, i = i, p = c.pos })
			end
		end
		if now >= (a.nextHist or 0) then
			a.nextHist = now + 0.1
			for _, p in ipairs(a:Players()) do
				local pos = a:Pos(p)
				local h = a.hist[p] or {}
				if h.pos then
					local d = pos - h.pos
					d.z = 0
					if d:LengthSqr() > 4 then h.dir = d:GetNormalized() end
				end
				h.pos = pos
				a.hist[p] = h
			end
		end
		for i = #a.timers, 1, -1 do
			local t = a.timers[i]
			if now >= t.at then
				table.remove(a.timers, i)
				local ok, err = pcall(t.fn)
				if not ok then ErrorNoHalt("[SkateGM items] " .. tostring(err) .. "\n") end
			end
		end
		for _, id in ipairs(IT.order) do
			local def = IT.defs[id]
			if def.think then
				local ok, err = pcall(def.think, a, now)
				if not ok then ErrorNoHalt("[SkateGM items] " .. id .. ": " .. tostring(err) .. "\n") end
			end
		end
		for ply in pairs(a.holding) do if not a:Has(ply) then a:Drop(ply) end end
	end
end
hook.Add("Think", "skategm_items", function() SV.Think(CurTime()) end)

function SV.Pick(ply, a, i, now)
	local c = a.crates[tonumber(i) or 0]
	if not (c and c.alive) then return end
	if a:Pos(ply):Distance(V(c.pos) + Vector(0, 0, IT.CRATE_FLOAT)) > IT.TOUCH_CHECK then return end
	c.alive, c.back = false, now + IT.CRATE_RESPAWN
	Send({ k = "crate", a = a.id, i = tonumber(i), broken = true, e = ply:EntIndex() })
	if not a.holding[ply] then
		local id = IT.Pick()
		if id then a:Give(ply, id) end
	end
end

function SV.Use(ply, a, m)
	local h = a.holding[ply]
	if not h then return end
	local def = IT.Get(h.id)
	if not def then return a:Drop(ply) end
	if def.target then
		local t = Entity(tonumber(m.target) or 0)
		if not (IsValid(t) and t ~= ply and a:Has(t)) then return end
		if a:Pos(ply):Distance(a:Pos(t)) > (def.target.range or 3000) then return end
		m.targetEnt = t
	end
	local ok, used = pcall(def.use, a, ply, m)
	if not ok then ErrorNoHalt("[SkateGM items] " .. h.id .. ": " .. tostring(used) .. "\n") return end
	if used == false then return end
	h.uses = h.uses - 1
	if h.uses <= 0 then a:Drop(ply) else Send({ k = "hold", e = ply:EntIndex(), id = h.id, uses = h.uses }) end
end

net.Receive(IT.NET, function(len, ply)
	if len > 4096 or not IsValid(ply) then return end
	local m = util.JSONToTable(net.ReadString() or "")
	if type(m) ~= "table" then return end
	local now = CurTime()
	ply.SkateGMItemsRate = ply.SkateGMItemsRate or { t = now, n = 0 }
	local r = ply.SkateGMItemsRate
	if now - r.t > 1 then r.t, r.n = now, 0 end
	r.n = r.n + 1
	if r.n > 30 then return end
	local a = SV.ArenaOf(ply)
	if not a then return end
	if m.k == "pick" then SV.Pick(ply, a, m.i, now)
	elseif m.k == "use" then SV.Use(ply, a, m) end
end)

hook.Add("PlayerInitialSpawn", "skategm_items", function(ply)
	timer.Simple(4, function()
		if not IsValid(ply) then return end
		for _, a in pairs(SV.arenas) do
			Send(a:Public(), ply)
			for holder, h in pairs(a.holding) do if IsValid(holder) then Send({ k = "hold", e = holder:EntIndex(), id = h.id, uses = h.uses }, ply) end end
		end
	end)
end)
