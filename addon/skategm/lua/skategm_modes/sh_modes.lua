SKATEGM_MODES = SKATEGM_MODES or { modes = {}, VERSION = 1 }
local M = SKATEGM_MODES
M.modes = M.modes or {}
M.CMD_RATE = 30  -- commands a second from a player (on average)
M.CMD_BURST = 10 -- ...and this many at once (two in the same frame are normal)
M.CMD_MAX_BITS = 4096 * 8


function M.API()
	if SERVER then return SkateGM and SkateGM.API end
	return SkateGM and SkateGM.API
end

function M.Get(id) return M.modes[id] end

local Mode = {}
Mode.__index = Mode
M.Mode = Mode

function Mode:Allowed() return self.cvAllowed == nil or self.cvAllowed:GetBool() end

local function Encode(t) return util.TableToJSON(t or {}) end
local function Decode(s)
	local ok, t = pcall(util.JSONToTable, s or "")
	if ok and type(t) == "table" then return t end
end
M.Encode, M.Decode = Encode, Decode

-- Several games of one mode at once, one per host. A mode opts in with
-- mode:UseSessions(G), G being the table its server code keeps the game in.
-- Each game's fields are kept apart and swapped into G before the mode's
-- code runs for it (a command from one of its players, a think, a player
-- leaving), so the mode's code is written as if there were only one game.
function M.Has(list, x)
	for _, v in ipairs(list or {}) do if v == x then return true end end
	return false
end

-- phases where a game isn't being played (setting up, showing who won):
-- respawning and teleporting to players are fine then, not in between
M.FREE_PHASES = { idle = true, lobby = true, results = true, final = true }

-- the board rules: off (nobody has it) or on (everyone in the game has it,
-- whatever their own setting); a mode can force the rocket to fire ("force").
-- The rocket on can be metered: fuel = seconds of thrust, refilling when not
-- in use (nil = infinite)
M.ROCKET_FUELS = { 1, 3, 5 }
M.ROCKET_CHOICES = { { 0, "off" }, { 1, "metered (1s)" }, { 3, "metered (3s)" }, { 5, "metered (5s)" }, { -1, "infinite" } }
function M.CleanFuel(v)
	v = tonumber(v)
	for _, f in ipairs(M.ROCKET_FUELS) do if f == v then return f end end
	return nil
end
M.BOARD_OPTIONS = {
	{ key = "_rocket", label = "Rocket board", type = "choice", choices = M.ROCKET_CHOICES, default = 0, help = "every player has the rocket board (right stick in to fire); metered: seconds of fuel, refilling when not in use" },
	{ key = "_hover", label = "Hoverboard", type = "bool", default = false, help = "on: every player rides the hoverboard" },
}
function M.CleanRules(r)
	if type(r) ~= "table" then return nil end
	local rocket = r.rocket == "force" and "force" or ((r.rocket == "on" or r.rocket == true) and "on" or false)
	return { rocket = rocket, fuel = rocket == "on" and M.CleanFuel(r.fuel) or nil, hover = (r.hover == "on" or r.hover == true) and "on" or false }
end
-- where a game starts: the host's spot and facing ("Here"), or wherever
-- they put it with the object placer (an arrow shows the way to go). Every
-- mode gets it unless its Host def says useStart = false. Arrives on the
-- server as create's _start = { pos = { x, y, z }, yaw }: M.HostStart.
M.START_OPTION = { key = "_start", label = "Start", type = "object", here = true, required = false,
	help = "here: where you stand, facing where you look. A: put it somewhere else (D-pad turns the arrow)" }
function M.CleanStart(t)
	if type(t) ~= "table" then return nil end
	local p = M.Vec(t.pos)
	local yaw = tonumber(t.yaw)
	if not p or not yaw or yaw ~= yaw or math.abs(p[1]) > 1e6 or math.abs(p[2]) > 1e6 or math.abs(p[3]) > 1e6 then return nil end
	return { pos = p, yaw = yaw % 360 }
end

function M.InPlay(st) return st ~= nil and st.phase ~= nil and not M.FREE_PHASES[st.phase] end

-- a no-zone (Bullseye's ring, Basketboard's circle): a flat band around
-- centre {x, y, z} from inner to outer, height units up and down. Touching
-- it ends the go
-- (z within low below to high above the zone's surface: touching it, not
-- riding a platform over it or a floor under it)
M.NO_ZONE_LOW, M.NO_ZONE_HIGH = 8, 16
function M.InNoZone(centre, inner, outer, x, y, z, low, high)
	if not (centre and outer and outer > inner) then return false end
	local d = math.sqrt((x - centre[1]) ^ 2 + (y - centre[2]) ^ 2)
	local dz = z - centre[3]
	return d > inner and d <= outer and dz >= -(low or M.NO_ZONE_LOW) and dz <= (high or M.NO_ZONE_HIGH)
end

-- a skater touching it: the board, the feet, or (lying, after a bail) the
-- body, each at the height it has when it's down on that surface
M.NO_ZONE_BONES = { SKATEBOARD_ROOT = 16, RIGHTFOOT = 14, LEFTFOOT = 14 }
M.NO_ZONE_LYING = 16
function M.TouchingNoZone(P, centre, inner, outer, lying)
	if not P then return false end
	if lying and P.HIPS and M.InNoZone(centre, inner, outer, P.HIPS.x, P.HIPS.y, P.HIPS.z, M.NO_ZONE_LOW, M.NO_ZONE_LYING) then return true end
	for bone, high in pairs(M.NO_ZONE_BONES) do
		local p = P[bone]
		if p and M.InNoZone(centre, inner, outer, p.x, p.y, p.z, M.NO_ZONE_LOW, high) then return true end
	end
	return false
end

---------------------------------------------------------------------------
-- small helpers every mode uses
---------------------------------------------------------------------------
-- where x is in list (or nil)
function M.IndexOf(list, x)
	for i, v in ipairs(list or {}) do if v == x then return i end end
end
-- a number from a message, or nil if it's missing, NaN or past limit
function M.Num(v, limit)
	v = tonumber(v)
	if not v or v ~= v or math.abs(v) > (limit or 32768) then return nil end
	return v
end
-- { x, y, z } from a message (inside the map), or nil
function M.Vec(t)
	if type(t) ~= "table" then return nil end
	local x, y, z = M.Num(t[1]), M.Num(t[2]), M.Num(t[3])
	if not (x and y and z) then return nil end
	return { x, y, z }
end
-- a player's key for a game's tables: their UserID (it outlives a rejoin's entity)
function M.Key(ply, keys)
	local k = keys and keys[ply]
	if k then return k end
	return tostring(ply:UserID())
end
-- a setting's cleaner: a whole number from lo to hi, default when missing
function M.Clamper(lo, hi, default)
	return function(v) return math.Clamp(math.floor(tonumber(v) or default), lo, hi) end
end
-- 1234567 -> "1,234,567"
function M.Commas(n)
	n = math.floor((n or 0) + 0.5)
	local s = tostring(math.abs(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return (n < 0 and "-" or "") .. s
end
-- seconds as m:ss
function M.Clock(t)
	t = math.max(0, math.ceil(t or 0))
	return string.format("%d:%02d", math.floor(t / 60), t % 60)
end


-- the walkable surface at (x, y) closest in height to ref: every surface down a
-- vertical line through world and props (hills, ramps, a floor under a roof),
-- not just brushes, so props-made maps get it right
M.GROUND_SPAN, M.GROUND_STEPS = 1536, 16
function M.Ground(x, y, ref)
	if not (util and util.TraceLine) then return ref end
	local best, bestGap
	local function down(from, bottom)
		local z = from
		for _ = 1, M.GROUND_STEPS do
			if z <= bottom then return end
			local tr = util.TraceLine({ start = Vector(x, y, z), endpos = Vector(x, y, bottom), mask = MASK_PLAYERSOLID })
			if not tr.Hit or tr.HitSky then return end
			if tr.StartSolid then
				-- inside a brush (a roof, a wall top): carry on from where the trace left it
				local left = tr.FractionLeftSolid or 0
				if left <= 0 or left >= 1 then return end
				z = z - (z - bottom) * left - 1
			else
				local hz = tr.HitPos.z
				if tr.HitNormal and tr.HitNormal.z > 0.5 then
					local gap = math.abs(hz - ref)
					if not bestGap or gap < bestGap then best, bestGap = hz, gap end
				end
				z = hz - 8
			end
		end
	end
	-- just over the height asked about first (the usual case: the floor is
	-- right under it), then from high up for hills and floors above
	down(ref + 72, ref - M.GROUND_SPAN)
	if not bestGap or bestGap > 72 then down(ref + M.GROUND_SPAN, ref - M.GROUND_SPAN) end
	return best or ref
end

local function SegDist(p, a, b)
	local abx, aby, abz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
	local apx, apy, apz = p[1] - a[1], p[2] - a[2], p[3] - a[3]
	local len = abx * abx + aby * aby + abz * abz
	local t = len > 0 and math.max(0, math.min(1, (apx * abx + apy * aby + apz * abz) / len)) or 0
	local dx, dy, dz = apx - abx * t, apy - aby * t, apz - abz * t
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function Nearest(p, to)
	if #to == 1 then return SegDist(p, to[1], to[1]) end
	local best = math.huge
	for i = 1, #to - 1 do
		local d = SegDist(p, to[i], to[i + 1])
		if d < best then best = d end
	end
	return best
end

-- the average, over the points of one path, of how close each is to the
-- line of the other (close(d): 1 near, falling to 0 far)
function M.Closeness(from, to, close)
	if #from == 0 or #to == 0 then return 0 end
	local sum = 0
	for _, p in ipairs(from) do sum = sum + close(Nearest(p, to)) end
	return sum / #from
end

-- 0-100 (Copycat, Telephone): how near the copy stays to the setter's line (half at scale / 2
-- off it), times how much of the setter's line it covers (in full within
-- scale / 2). Point by point, so a stray sample or a slower copy costs a
-- little, not everything
function M.PathMatch(lead, copy, scale)
	if not (lead and copy) or #lead < 2 or #copy < 2 then return 0 end
	local half = (scale or 192) / 2
	local near = M.Closeness(copy, lead, function(d) return 1 / (1 + (d / half) ^ 2) end)
	local covered = M.Closeness(lead, copy, function(d) return d <= half and 1 or 1 / (1 + ((d - half) / (half / 2)) ^ 2) end)
	return math.floor(100 * near * covered + 0.5)
end

if SERVER then
	function M.PlayerInPlay(ply)
		local mode, key = M.SessionOf(ply)
		if not mode then return false end
		local st = (mode.live and key ~= true) and mode:SessionData(key) or mode.lastState
		return M.InPlay(st)
	end

	-- where the host's game starts: the Start they set, or where they stand
	function M.HostStart(ply, m)
		local s = M.CleanStart(type(m) == "table" and m._start or nil)
		if s then return Vector(s.pos[1], s.pos[2], s.pos[3]), s.yaw end
		return ply:GetPos(), ply:EyeAngles().y
	end

	-- LB + X during a game: where the game says (mode:RespawnAt), or not at all
	function Mode:RespawnAt(fn) self.respawnFn = fn end
	function M.RespawnPointFor(ply)
		local mode, key = M.SessionOf(ply)
		if not (mode and mode.respawnFn) then return nil end
		if mode.live and key ~= true then mode:Enter(key) end
		local ok, pos, yaw = pcall(mode.respawnFn, ply)
		if mode.live and key ~= true then mode:Settle() end
		if ok and pos then return pos, yaw end
	end

	hook.Add("SkateGMCanRespawn", "skategm_modes", function(ply)
		if M.PlayerInPlay(ply) and not M.RespawnPointFor(ply) then return false end
	end)
	hook.Add("SkateGMRespawnPoint", "skategm_modes", function(ply)
		if M.PlayerInPlay(ply) then return M.RespawnPointFor(ply) end
	end)

	function Mode:UseSessions(live)
		self.live, self.stash, self.current = live, self.stash or {}, nil
	end

	-- the game with this id into the mode's table (nil: a fresh, idle one)
	function Mode:Enter(key)
		if not self.live or key == self.current then return end
		local live = self.live
		if self.current ~= nil then
			local saved = {}
			for k, v in pairs(live) do saved[k] = v end
			if saved.phase ~= "idle" then self.stash[self.current] = saved end
		end
		for k in pairs(live) do live[k] = nil end
		local load = key ~= nil and self.stash[key] or { phase = "idle" }
		if key ~= nil then self.stash[key] = nil end
		for k, v in pairs(load) do live[k] = v end
		self.current = key
	end

	-- a game that ended (idle) is gone
	function Mode:Settle()
		if self.live and self.current ~= nil and self.live.phase == "idle" then self.current = nil end
	end

	function Mode:SessionKeys()
		-- (a game set up without going through a command: adopt it)
		if self.live and self.current == nil and self.live.phase ~= "idle" then
			self.nextSession = (self.nextSession or 0) + 1
			self.current = self.nextSession
		end
		local keys = {}
		if self.current ~= nil and self.live and self.live.phase ~= "idle" then keys[#keys + 1] = self.current end
		for k in pairs(self.stash or {}) do keys[#keys + 1] = k end
		table.sort(keys)
		return keys
	end

	function Mode:SessionData(key)
		if key == self.current then return self.live end
		return self.stash and self.stash[key]
	end

	local function Member(data, ply)
		return data ~= nil and data.phase ~= "idle" and (data.host == ply or M.Has(data.players, ply))
	end

	-- the game ply is in (host or player), in this mode
	function Mode:SessionOf(ply)
		for _, key in ipairs(self:SessionKeys()) do
			if Member(self:SessionData(key), ply) then return key end
		end
	end

	-- ...in any mode
	M.NET_INVITE = "skategm_modes_invite"
	util.AddNetworkString(M.NET_INVITE)
	function Mode:Invite(ply, m)
		local live = self.live
		if not live or live.phase ~= "lobby" then return self:Tell(ply, "invites are for the lobby, before the game starts") end
		local member = live.host == ply
		for _, p in ipairs(live.players or {}) do if p == ply then member = true end end
		if not member then return end
		local target = Entity(tonumber(m.target) or 0)
		if not (IsValid(target) and target:IsPlayer()) or target == ply then return end
		if M.SessionOf(target) ~= nil then return self:Tell(ply, target:Nick() .. " is already in a minigame") end
		net.Start(M.NET_INVITE)
		net.WriteString(self.id)
		net.WriteString(tostring(self.current or ""))
		net.WriteString(ply:Nick())
		net.Send(target)
		self:Tell(ply, "invited " .. target:Nick())
	end

	function M.SessionOf(ply)
		for _, mode in pairs(M.modes) do
			if mode.live then
				local key = mode:SessionOf(ply)
				if key ~= nil then return mode, key end
			elseif mode.lastState and mode.lastState.phase and mode.lastState.phase ~= "idle" then
				local st = mode.lastState
				if st.host == (IsValid(ply) and ply:EntIndex()) then return mode, true end
			end
		end
	end

	-- run fn once for each game (fn sees that game in the mode's table)
	function Mode:EachSession(fn)
		if not self.live then return fn() end
		for _, key in ipairs(self:SessionKeys()) do
			self:Enter(key)
			fn(key)
			self:Settle()
		end
	end

	function Mode:RunThink(now)
		if self.thinkHandler then self:EachSession(function() self.thinkHandler(now) end) end
		self:Resend(now)
	end

	-- every game still going is sent again at least every RESEND seconds: the
	-- Join menu forgets one it hasn't heard of for a while, and a quiet lobby
	-- (nothing changing) went unheard - other players couldn't see it
	M.RESEND = 1
	-- (a resent state's clocks count on from when it was made: resending the
	-- old timeLeft put every countdown back to where it started each second)
	M.CLOCK_KEYS = { "timeLeft" }
	function M.Aged(state, seconds)
		if seconds <= 0 then return state end
		local copy
		for _, k in ipairs(M.CLOCK_KEYS) do
			if type(state[k]) == "number" then
				if not copy then
					copy = {}
					for key, v in pairs(state) do copy[key] = v end
				end
				copy[k] = math.max(0, state[k] - seconds)
			end
		end
		return copy or state
	end

	function Mode:Resend(now)
		for key, entry in pairs(self.lastStates or {}) do
			if now - entry.at >= M.RESEND then
				entry.at = now
				net.Start(self.NET_STATE)
				net.WriteString(Encode(M.Aged(entry.state, now - (entry.made or now))))
				net.Broadcast()
			end
		end
	end

	function Mode:Broadcast(state, now)
		state.session = self.live and self.current or nil
		state.rules = self.live and state.phase ~= "idle" and self.live._boardRules or nil
		state.placed = self.live and state.phase == "lobby" and self.live._placedStart or nil
		self.lastState = state
		self.lastBroadcast = now or CurTime()
		self.lastStates = self.lastStates or {}
		self.lastStates[state.session or "only"] = state.phase ~= "idle" and { state = state, at = self.lastBroadcast, made = self.lastBroadcast } or nil
		net.Start(self.NET_STATE)
		net.WriteString(Encode(state))
		net.Broadcast()
	end

	function Mode:SendState(ply, state)
		net.Start(self.NET_STATE)
		net.WriteString(Encode(state or self.lastState))
		net.Send(ply)
	end

	function Mode:OnCommand(fn) self.commandHandler = fn end
	function Mode:OnThink(fn) self.thinkHandler = fn end
	function Mode:OnPlayerJoin(fn) self.joinHandler = fn end
	function Mode:OnPlayerLeave(fn) self.leaveHandler = fn end
	function Mode:OnDisallowed(fn) self.disallowedHandler = fn end

	-- turn games: who goes after order[index] (an entity index; nil when
	-- that was the last turn, or there's nobody else)
	function M.UpNext(order, index, wrap)
		if not order or #order < 2 or not index or index < 1 then return nil end
		local i = index + 1
		if i > #order then
			if not wrap then return nil end
			i = 1
		end
		local p = order[i]
		return IsValid(p) and p:EntIndex() or nil
	end

	-- turn games: everyone taking part but the active player stays put while
	-- they watch (on), or everyone's free (off)
	function M.FreezeWatchers(players, active, on)
		for _, p in ipairs(players or {}) do
			if IsValid(p) then p:Freeze(on and p ~= active) end
		end
	end

	-- someone hosting or joining can't skate here (not allowed, or no working
	-- Skater mode: m.canSkate from their client): told why, true
	function Mode:CantSkate(ply, m, verb)
		if not M.Allowed(ply) then self:Tell(ply, "you're not allowed to skate on this server") return true end
		if not m.canSkate then self:Tell(ply, "you need Skater mode working (the module and your data) to " .. verb) return true end
		return false
	end

	-- the usual wiring of a mode's commands: handlers[cmd](ply, m, now), refused
	-- while the mode is turned off (all but "leave"); turned off mid-game, the
	-- game stops; someone joining the server mid-game gets the state. Returns
	-- the command function (tests call it directly).
	function Mode:Serve(S, handlers, stop, broadcast)
		local mode = self
		local function Command(ply, m, now)
			local h = type(m) == "table" and handlers[m.cmd]
			if h and not mode:Allowed() and m.cmd ~= "leave" then return mode:Tell(ply, mode.title .. " is turned off on this server") end
			if h then h(ply, m, now or CurTime()) end
		end
		self:OnCommand(function(ply, m) Command(ply, m) end)
		self:OnDisallowed(function() if S.phase ~= "idle" then stop(mode.title .. " was turned off on this server") end end)
		self:OnPlayerJoin(function(ply)
			if S.phase ~= "idle" then timer.Simple(3, function() if IsValid(ply) then broadcast() end end) end
		end)
		return Command
	end

	function Mode:HandleCommand(ply, len, text, now)
		if len and len > (self.maxBits or M.CMD_MAX_BITS) then return false end
		-- (a bucket per player: refills at CMD_RATE a second, holds CMD_BURST.
		-- A minimum gap between commands dropped real ones: Hall of Meat's
		-- "ready" right after "begin" got lost, and the turn waited it out)
		self.lastCommand = self.lastCommand or {}
		local b = self.lastCommand[ply]
		if type(b) ~= "table" then b = { tokens = M.CMD_BURST, at = now } self.lastCommand[ply] = b end
		b.tokens = math.min(M.CMD_BURST, b.tokens + (now - b.at) * M.CMD_RATE)
		b.at = now
		if b.tokens < 1 then return false end
		b.tokens = b.tokens - 1
		local m = Decode(text)
		if not m or not self.commandHandler then return false end
		if m.cmd == "_invite" and self.live then
			local inMode, inKey = M.SessionOf(ply)
			if inMode ~= self then self:Tell(ply, "you're not in a game to invite anyone to") return true end
			self:Enter(inKey)
			self:Invite(ply, m)
			self:Settle()
			return true
		end
		if not self.live then
			self.commandHandler(ply, m, CurTime())
			return true
		end
		local key = self:RouteCommand(ply, m)
		if key == false then return true end
		self:Enter(key)
		self.commandHandler(ply, m, CurTime())
		if m.cmd == "create" and self.live.phase ~= "idle" and self.live.host == ply and self.live._boardRules == nil and self.live._placedStart == nil then
			self.live._boardRules = M.CleanRules(m.rules)
			self.live._placedStart = type(m._start) == "table" and m._start.placed == true and M.CleanStart(m._start) or nil
			if self.live._boardRules or self.live._placedStart then self:Broadcast(self.lastState or { phase = self.live.phase }) end
		end
		self:Settle()
		return true
	end

	-- which game a command is for: a new one (create), the one asked for
	-- (join), else the one the player is in. false = refused (told why)
	function Mode:RouteCommand(ply, m)
		local inMode, inKey = M.SessionOf(ply)
		if m.cmd == "create" then
			if inMode then
				self:Tell(ply, "you're already in " .. inMode.title .. ": leave it first (LB + D-pad left)")
				return false
			end
			self.nextSession = (self.nextSession or 0) + 1
			return self.nextSession
		end
		if m.cmd == "join" then
			local want = tonumber(m.session)
			if inMode and not (inMode == self and inKey == want) then
				self:Tell(ply, "you're already in " .. inMode.title .. ": leave it first (LB + D-pad left)")
				return false
			end
			if want ~= nil then return want end
			local open = {}
			for _, key in ipairs(self:SessionKeys()) do
				if (self:SessionData(key) or {}).phase == "lobby" then open[#open + 1] = key end
			end
			if #open == 1 then return open[1] end
			if #open == 0 then return nil end
			self:Tell(ply, "more than one " .. self.title .. " game is open: pick one with LB + D-pad left > Join")
			return false
		end
		if inMode == self then return inKey end
		local want = tonumber(m.session)
		if want ~= nil then return want end
		local keys = self:SessionKeys()
		if #keys == 1 then return keys[1] end
		return nil
	end

	function Mode:Install()
		util.AddNetworkString(self.NET_STATE)
		util.AddNetworkString(self.NET_CMD)
		local mode = self
		net.Receive(self.NET_CMD, function(len, ply) mode:HandleCommand(ply, len, net.ReadString(), SysTime()) end)
		hook.Add("Think", "skategm_mode_" .. self.id, function() mode:RunThink(CurTime()) end)
		hook.Add("PlayerDisconnected", "skategm_mode_" .. self.id, function(ply)
			if mode.lastCommand then mode.lastCommand[ply] = nil end
			if mode.leaveHandler then mode:EachSession(function() mode.leaveHandler(ply) end) end
		end)
		hook.Add("PlayerInitialSpawn", "skategm_mode_" .. self.id, function(ply)
			if mode.joinHandler then mode:EachSession(function() mode.joinHandler(ply) end) end
		end)
		if self.cvAllowed and cvars and cvars.AddChangeCallback then
			cvars.AddChangeCallback(self.allowedName, function(_, _, new)
				if new == "0" and mode.disallowedHandler then mode:EachSession(function() mode.disallowedHandler() end) end
			end, "skategm_mode_" .. self.id)
		end
	end
else
	-- On maps where Lua's positions are relative to the player (the original
	-- InfMap: SkateGM.Offset), the server and other players work in absolute
	-- ones: minigame messages are shifted on the way out and back in. The
	-- forms the modes use: Vectors, {x, y, z(, r)} under a position key,
	-- tables with x / y / z numbers, flat x, y, z lists under "p".
	M.POINT_KEYS = { pos = true, centre = true, center = true, start = true, finish = true, spot = true, area = true, target = true }
	M.FLAT_KEYS = { p = true }
	local vecMeta = getmetatable(Vector(0, 0, 0))
	local function IsVec(v) return (isvector and isvector(v)) or (vecMeta ~= nil and getmetatable(v) == vecMeta) end
	M.IsVec = IsVec
	local function Num3(t) return type(t[1]) == "number" and type(t[2]) == "number" and type(t[3]) == "number" end
	function M.ShiftPositions(t, o, depth)
		if type(t) ~= "table" or (depth or 0) > 8 then return t end
		local out = {}
		for k, v in pairs(t) do
			if IsVec(v) then
				out[k] = v + o
			elseif type(v) == "table" and M.POINT_KEYS[k] and Num3(v) then
				local c = {}
				for i, x in pairs(v) do c[i] = x end
				c[1], c[2], c[3] = v[1] + o.x, v[2] + o.y, v[3] + o.z
				out[k] = c
			elseif type(v) == "table" and M.FLAT_KEYS[k] then
				local c = {}
				for i, x in ipairs(v) do
					local axis = (i - 1) % 3
					c[i] = type(x) == "number" and x + (axis == 0 and o.x or axis == 1 and o.y or o.z) or x
				end
				out[k] = c
			elseif type(v) == "table" then
				out[k] = M.ShiftPositions(v, o, (depth or 0) + 1)
			else
				out[k] = v
			end
		end
		if type(t.x) == "number" and type(t.y) == "number" and type(t.z) == "number" then
			out.x, out.y, out.z = t.x + o.x, t.y + o.y, t.z + o.z
		end
		return out
	end
	function M.FrameOffset()
		local o = SkateGM and SkateGM.Offset and SkateGM.Offset()
		return o
	end
	-- my frame moved (into another InfMap chunk): every game's last state again,
	-- in the new frame
	-- Modes that keep positions of their own (a trail, a path) hear by how
	-- much the frame moved, in mode:OnFrameShift(function(delta) ... end):
	-- a position kept in my frame becomes p - delta.
	function M.FrameThink(now)
		local o = M.FrameOffset()
		local key = o and string.format("%d %d %d", o.x, o.y, o.z) or ""
		if key == (M.lastFrame or "") then return end
		local before = M.lastFrameOffset
		M.lastFrame, M.lastFrameOffset = key, o
		local delta = before and o and (o - before) or nil
		for _, mode in pairs(M.modes or {}) do
			if delta and mode.frameShiftHandler then mode.frameShiftHandler(delta) end
			for _, text in pairs(mode.texts or {}) do mode:HandleState(text, now) end
		end
	end
	if hook and hook.Add then hook.Add("Think", "skategm_modes_frame", function() M.FrameThink(RealTime()) end) end

	function M.ToAbs(t) local o = M.FrameOffset() if not o then return t end return M.ShiftPositions(t, o) end
	function M.FromAbs(t) local o = M.FrameOffset() if not o then return t end return M.ShiftPositions(t, -o) end

	function Mode:Send(cmd)
		if type(cmd) == "table" and cmd.cmd == "create" and self.pendingRules then
			cmd.rules, self.pendingRules = self.pendingRules, nil
		end
		-- (the Start goes with create; modes that send their own spot get it too)
		if type(cmd) == "table" and cmd.cmd == "create" and self.pendingStart then
			local s = self.pendingStart
			self.pendingStart = nil
			cmd._start = { pos = { s.pos.x, s.pos.y, s.pos.z }, yaw = s.yaw, placed = s.placed or nil }
			if s.placed then
				if type(cmd.pos) == "table" then cmd.pos = { s.pos.x, s.pos.y, s.pos.z } end
				if cmd.x ~= nil and cmd.y ~= nil and cmd.z ~= nil then cmd.x, cmd.y, cmd.z = s.pos.x, s.pos.y, s.pos.z end
				if cmd.yaw ~= nil then cmd.yaw = s.yaw end
			end
		end
		net.Start(self.NET_CMD)
		net.WriteString(Encode(M.ToAbs(cmd)))
		net.SendToServer()
	end

	function Mode:OnState(fn) self.stateHandler = fn end
	function Mode:OnFrameShift(fn) self.frameShiftHandler = fn end
	function Mode:OnChat(fn)
		self.chatHandler = fn
		local mode = self
		hook.Add("OnPlayerChat", "skategm_mode_" .. self.id, function(ply, text)
			if ply ~= LocalPlayer() then return end
			if mode:HandleChat(text) then return true end
		end)
	end

	function Mode:HandleState(text, now)
		local st = Decode(text)
		if not st then return false end
		-- (kept as sent: re-read when my frame moves, M.FrameThink)
		self.texts = self.texts or {}
		self.texts[st.session or "only"] = st.phase ~= "idle" and text or nil
		st = M.FromAbs(st)
		if st.session == nil then
			local prev = self.state
			self.state = st
			local ok, mine = pcall(function() return st.phase ~= "idle" and (self:IsHost(st) or self:Me(st) ~= nil) end)
			mine = ok and mine
			if M.RELEASED[st.phase] and (prev and prev.phase) ~= st.phase then self:ReleaseHolds() end
			if self.stateHandler then self.stateHandler(st, now) end
			if M.polish and (mine or (prev and prev.phase ~= "idle" and st.phase == "idle")) then M.polish.Observe(self, prev, st, now) end
			return true
		end
		-- several games: every one is listed (the Join menu); the mode itself
		-- follows only the one I'm in
		self.seen = self.seen or {}
		local key = st.session
		if st.phase == "idle" then self.seen[key] = nil else self.seen[key] = { st = st, at = now } end
		local mine = st.phase ~= "idle" and (self:IsHost(st) or self:Me(st) ~= nil)
		if mine then
			self.mySession = key
			local prev = self.state
			local before = prev and prev.phase
			self.state = st
			if M.RELEASED[st.phase] and before ~= st.phase then self:ReleaseHolds() end
			if self.stateHandler then self.stateHandler(st, now) end
			if M.polish then M.polish.Observe(self, prev, st, now) end
		elseif key == self.mySession then
			self.mySession = nil
			self.state = { phase = "idle" }
			self:ReleaseHolds()
			if self.stateHandler then self.stateHandler(self.state, now) end
			if M.polish then M.polish.Observe(self, nil, self.state, now) end
		end
		return true
	end

	-- every game of this mode going on now (fresh ones), each as Info()
	function Mode:Games(now)
		now = now or RealTime()
		local out = {}
		if not self.seen then
			local info = self:Info()
			if info then out[1] = info end
			return out
		end
		for key, entry in pairs(self.seen) do
			if now - entry.at < 3 then
				local info = self:InfoFor(entry.st)
				if info then info.session = key out[#out + 1] = info end
			else
				self.seen[key] = nil
			end
		end
		table.sort(out, function(a, b) return a.session < b.session end)
		return out
	end

	-- the no-zone on the ground: red, hatched with dark red lines
	M.NO_ZONE_RED, M.NO_ZONE_STRIPE, M.NO_ZONE_STRIPES, M.NO_ZONE_SEGMENTS = Color(220, 40, 40, 110), Color(110, 0, 0, 230), 48, 64
	local zoneMat
	function M.DrawNoZone(centre, inner, outer, z)
		if not (outer and outer > inner and mesh and render) then return end
		zoneMat = zoneMat or CreateMaterial("skategm_nozone", "UnlitGeneric", { ["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$translucent"] = 1, ["$nocull"] = 1 })
		render.SetMaterial(zoneMat)
		local n, c = M.NO_ZONE_SEGMENTS, M.NO_ZONE_RED
		mesh.Begin(MATERIAL_QUADS, n)
		for k = 0, n - 1 do
			local a0, a1 = k / n * math.pi * 2, (k + 1) / n * math.pi * 2
			local c0, s0, c1, s1 = math.cos(a0), math.sin(a0), math.cos(a1), math.sin(a1)
			for _, v in ipairs({ { c0 * inner, s0 * inner }, { c0 * outer, s0 * outer }, { c1 * outer, s1 * outer }, { c1 * inner, s1 * inner } }) do
				mesh.Position(Vector(centre.x + v[1], centre.y + v[2], z))
				mesh.Color(c.r, c.g, c.b, c.a)
				mesh.AdvanceVertex()
			end
		end
		mesh.End()
		render.SetColorMaterial()
		local skew = (outer - inner) / math.max(outer, 1)
		for k = 0, M.NO_ZONE_STRIPES - 1 do
			local a = k / M.NO_ZONE_STRIPES * math.pi * 2
			local p0 = Vector(centre.x + math.cos(a) * inner, centre.y + math.sin(a) * inner, z + 0.5)
			local p1 = Vector(centre.x + math.cos(a + skew) * outer, centre.y + math.sin(a + skew) * outer, z + 0.5)
			render.DrawBeam(p0, p1, 5, 0, 1, M.NO_ZONE_STRIPE)
		end
	end

	-- where a skater's hips are drawn this frame (me too): for things that
	-- follow a skater on screen, so they move with them instead of jittering
	function M.DrawnHips(ent)
		local a = M.API()
		local ply = ent == LocalPlayer():EntIndex() and LocalPlayer() or Entity(ent)
		local P = a and a.PoseOf and IsValid(ply) and a.PoseOf(ply)
		return P and P.HIPS or nil
	end

	-- a mode done with the camera it took (owner: what it was set under):
	-- whatever was showing before comes back (the spectator's, the player's own)
	-- recording runs on every client (poses reach every player): C.clips[ent]
	-- = { { t, P }, ... } from C.recStart, rate frames a second. keep: the
	-- other clips stay (Copycat keeps the setter's while the copies record)
	function M.StartRecording(C, ents, now, keep)
		if not keep or not C.clips then C.clips = {} end
		C.recStart, C.nextRec, C.recording = now, now, {}
		for _, ent in ipairs(ents) do
			C.clips[ent] = {}
			C.recording[#C.recording + 1] = ent
		end
	end

	-- skip(ent): not this one now; extra(ent): a state kept with the frame
	function M.RecordPoses(C, rate, now, skip, extra)
		if not C.recStart or now < (C.nextRec or 0) then return end
		C.nextRec = now + 1 / rate
		local a = M.API()
		if not (a and a.PoseOf) then return end
		local me = LocalPlayer():EntIndex()
		for _, ent in ipairs(C.recording or {}) do
			local clip = C.clips[ent]
			local ply = clip and not (skip and skip(ent)) and (ent == me and LocalPlayer() or Entity(ent)) or nil
			local P = ply and IsValid(ply) and a.PoseOf(ply)
			if P and P.HIPS then
				local c = {}
				for k, v in pairs(P) do c[k] = Vector(v.x, v.y, v.z) end
				clip[#clip + 1] = { t = now - C.recStart, P = c, state = extra and extra(ent) or nil }
			end
		end
	end

	-- the replay camera: behind whoever is watched (C.watch = { target }),
	-- back units behind and up above; hold: no pose, the last view stays
	function M.ChaseWatch(C, target, owner, back, up, hold)
		local a = M.API()
		C.watch = target and { target = target } or nil
		if a and a.SetView then
			if target then a.SetView(function(_, _, fov) return M.ChaseView(C, fov, back, up, hold) end, owner) else M.GiveViewBack(owner) end
		end
	end

	function M.ChaseView(C, fov, back, up, hold)
		local w = C.watch
		local a = M.API()
		local P = w and a and a.PoseOf(w.target)
		if not (P and P.HIPS) then return hold and w and w.pos and { origin = w.pos, angles = w.ang, fov = fov } or nil end
		local target = P.HIPS + Vector(0, 0, 10)
		if w.last then
			local moved = target - w.last
			moved.z = 0
			if moved:LengthSqr() > 0.25 then w.dir = LerpVector(0.08, w.dir or moved:GetNormalized(), moved:GetNormalized()) end
		end
		w.last = target
		local dir = w.dir or Vector(1, 0, 0)
		local want = target - dir:GetNormalized() * (back or 160) + Vector(0, 0, up or 64)
		w.pos = w.pos and LerpVector(0.12, w.pos, want) or want
		w.ang = (target - w.pos):Angle()
		return { origin = w.pos, angles = w.ang, fov = fov }
	end

	function M.GiveViewBack(owner)
		local a = M.API()
		if a and a.SetView then a.SetView(nil, owner) end
	end

	-- while a game runs where players share a spot or take over from each
	-- other: only who I watch is drawn and nobody is solid to me (hidden flags
	-- reach everyone late: a teleport onto the start met the others there)
	function Mode:KeepApart(on)
		on = on and true or false
		local a = M.API()
		if not a then return end
		if a.HideOthers then a.HideOthers(on, self.id .. "_apart") end
		if a.SetPlayerCollision then if on then a.SetPlayerCollision(false, self.id .. "_apart") else a.SetPlayerCollision(nil, self.id .. "_apart") end end
	end

	-- nobody solid to me while on (others still drawn): games where everyone skates at once
	function Mode:NoCollide(on)
		on = on and true or false
		local a = M.API()
		if not a then return end
		if a.SetPlayerCollision then if on then a.SetPlayerCollision(false, self.id .. "_solid") else a.SetPlayerCollision(nil, self.id .. "_solid") end end
	end

	-- playing a minigame right now (not its lobby or results): no respawning
	-- or teleporting then
	function M.Playing() return M.InPlay(select(2, M.MyGame())) end

	-- who's in a game that's being played: entity index -> that game (mode id
	-- and session), from the states every client already gets (refreshed a
	-- few times a second, it's asked every frame)
	M.PLAY_MAP_EVERY = 0.25
	function M.PlayMap(now)
		now = now or RealTime()
		if M.playMap and now - (M.playMapAt or -1) < M.PLAY_MAP_EVERY then return M.playMap end
		local map, out = {}, {}
		local function add(mode, key, st)
			if not M.InPlay(st) then return end
			local game = mode.id .. ":" .. tostring(key)
			for _, p in ipairs(st.players or {}) do
				if p.ent then
					map[p.ent] = game
					if p.out == true or p.alive == false then out[p.ent] = true end
				end
			end
		end
		for _, mode in pairs(M.modes) do
			if mode.seen then
				for key, entry in pairs(mode.seen) do
					if now - entry.at < 3 then add(mode, key, entry.st) end
				end
			end
			if mode.state then add(mode, mode.mySession or "only", mode.state) end
		end
		M.playMap, M.playOut, M.playMapAt = map, out, now
		return map, out
	end

	-- how another player is kept apart from me: "hide" (I'm playing a game
	-- they're not in: unseen, I pass through them), "ghost" (they're playing
	-- one and I'm not: see-through, I pass through them), or nil
	function M.Separation(ply)
		if not (IsValid(ply) and ply.EntIndex) then return nil end
		local map, out = M.PlayMap()
		out = out or M.playOut or {}
		local me = LocalPlayer():EntIndex()
		local mine, theirs = map[me], map[ply:EntIndex()]
		-- (someone out of my game, while I'm still in it, is gone too)
		if mine then return (theirs ~= mine or (out[ply:EntIndex()] and not out[me])) and "hide" or nil end
		return theirs and "ghost" or nil
	end

	-- the game I'm in, in any mode (host or player)
	function M.MyGame()
		for _, mode in pairs(M.modes) do
			local st = mode.state
			if st and st.phase and st.phase ~= "idle" and (mode:IsHost(st) or mode:Me(st) ~= nil) then return mode, st end
		end
	end

	-- watching someone else's turn: out of Skater mode (the mode's CalcView
	-- shows them) - or, where Skater mode stays on (the SkateGM gamemode),
	-- the skater frozen and the camera given to view(). Call it with each
	-- state; it only acts when watching changes.
	function Mode:Spectate(ents, opts)
		local SP = M.spectate
		self.spectating = (ents and #ents > 0) and ents or nil
		-- (a list, even an empty one, means it isn't my go: my skater waits
		-- frozen, rather than riding off unseen when there's nobody to watch)
		self:Wait(ents ~= nil)
		if not (SP and SP.Start) then return end
		if self.spectating then SP.Start(self, ents, opts) elseif SP.owner == self then SP.Stop() end
	end

	function Mode:Watch(watching, view)
		local a = M.API()
		if not a then return end
		if a.IsLocked and a.IsLocked() then
			if watching and not self.watching then
				self.watching = true
				if a.Freeze then a.Freeze(true, self.id .. "_watch") end
				if a.SetView then a.SetView(view, self.id .. "_watch") end
			elseif not watching and self.watching then
				self.watching = nil
				if a.SetView then a.SetView(nil, self.id .. "_watch") end
				if a.Freeze then a.Freeze(false, self.id .. "_watch") end
			end
		elseif watching and (a.IsSkating() or a.IsLoading()) then
			a.StopSkating()
		end
	end

	-- chat commands: "!<mode> word args" runs map[word] - a console command
	-- (given the args) or a function(words). join, start, stop and leave
	-- work without being listed. Returns the chat handler (text -> handled).
	function Mode:ChatCommands(map, usage)
		local mode = self
		local defaults = {
			join = function() mode:Join() end, leave = function() mode:Leave() end,
			start = function() mode:Send({ cmd = "begin" }) end, stop = function() mode:Send({ cmd = "stop" }) end,
		}
		self:OnChat(function(words)
			local word = (words[1] or ""):lower()
			local cmd = map[word] or defaults[word]
			if not cmd then
				mode:Say(mode.chat .. " " .. (usage or "join, start, stop, leave") .. " - or host and join from the controller: LB + D-pad left")
				return true
			end
			for i = 2, #words do words[i] = words[i]:lower() end
			if type(cmd) == "function" then cmd(words) else RunConsoleCommand(cmd, words[2], words[3]) end
			return true
		end)
		return function(text) return mode:HandleChat(text) end
	end

	function Mode:HandleChat(text)
		if not self.chatHandler or type(text) ~= "string" then return false end
		local words = {}
		for w in text:gmatch("%S+") do words[#words + 1] = w end
		if (words[1] or ""):lower() ~= self.chat then return false end
		table.remove(words, 1)
		return self.chatHandler(words) ~= false
	end

	function Mode:Install()
		local mode = self
		net.Receive(self.NET_STATE, function() mode:HandleState(net.ReadString(), RealTime()) end)
	end
end

function M.Allowed(ply) local a = M.API() return a ~= nil and a.Allowed(ply) end
function M.Skating(ply) local a = M.API() return a ~= nil and a.IsSkating(ply) end

if SERVER then
	function Mode:Tell(ply, text)
		local line = "[" .. self.title .. "] " .. text
		if IsValid(ply) then ply:ChatPrint(line) else PrintMessage(HUD_PRINTTALK, line) end
	end
else
	function M.CanSkate() local a = M.API() return a ~= nil and a.CanSkate() end

	-- the start marker: a gate across the start and an arrow the way to go
	M.START_COLOR = Color(120, 220, 255)
	function M.DrawStartMarker(pos, yaw, alpha)
		if not (render and render.SetColorMaterial) then return end
		render.SetColorMaterial()
		local c = M.START_COLOR
		local col = Color(c.r, c.g, c.b, 220 * (alpha or 1))
		local r0 = math.rad(yaw or 0)
		local fwd, right = Vector(math.cos(r0), math.sin(r0), 0), Vector(math.sin(r0), -math.cos(r0), 0)
		local a, b = pos - right * 40, pos + right * 40
		render.DrawBox(a, angle_zero, Vector(-1.5, -1.5, 0), Vector(1.5, 1.5, 64), col)
		render.DrawBox(b, angle_zero, Vector(-1.5, -1.5, 0), Vector(1.5, 1.5, 64), col)
		render.DrawBeam(a + Vector(0, 0, 64), b + Vector(0, 0, 64), 3, 0, 1, col)
		local base = pos + Vector(0, 0, 3)
		local tip = base + fwd * 80
		render.DrawBeam(base, tip, 6, 0, 1, col)
		render.DrawBeam(tip, tip - fwd * 24 + right * 18, 6, 0, 1, col)
		render.DrawBeam(tip, tip - fwd * 24 - right * 18, 6, 0, 1, col)
	end

	function M.Here()
		local a = M.API()
		local p = a and a.SkaterPos and a.SkaterPos()
		if p then return p end
		return LocalPlayer():GetPos()
	end

	function Mode:Say(text, bad)
		text = M.ButtonWords and M.ButtonWords(text) or text
		local a = M.API()
		if a then a.Say(self.title .. ": " .. text, bad) else chat.AddText(self.color or Color(120, 220, 255), "[" .. self.title .. "] ", color_white, text) end
	end

	function Mode:Me(st)
		local me = LocalPlayer():EntIndex()
		for _, p in ipairs(st.players or {}) do if p.ent == me then return p end end
	end

	function Mode:IsHost(st) return st.host ~= nil and st.host ~= 0 and st.host == LocalPlayer():EntIndex() end

	function Mode:LobbyLines(fn) self.lobbyLines = fn end
	M.LOBBY_ROWS = 10

	-- the lobby, the same for every mode: who's in, who hosts, what to press
	function M.LobbyRows(mode, st)
		local me = LocalPlayer():EntIndex()
		local rows = { title = string.upper(mode.title), about = mode.hostDef and mode.hostDef.about, players = {}, lines = {} }
		local list = st.players or {}
		for i, p in ipairs(list) do
			if i > M.LOBBY_ROWS then
				rows.players[#rows.players + 1] = { name = "+" .. (#list - M.LOBBY_ROWS) .. " more" }
				break
			end
			rows.players[#rows.players + 1] = { name = p.name or "?", host = p.ent == st.host, me = p.ent == me }
		end
		if mode.lobbyLines then
			local ok, extra = pcall(mode.lobbyLines, st)
			if ok and type(extra) == "table" then for _, l in ipairs(extra) do rows.lines[#rows.lines + 1] = l end end
		end
		if st.rules then
			if st.rules.rocket == false then rows.lines[#rows.lines + 1] = "no rocket board" end
			if st.rules.rocket == "force" then rows.lines[#rows.lines + 1] = "rocket boards on" end
			if st.rules.rocket == "on" then rows.lines[#rows.lines + 1] = st.rules.fuel and string.format("rocket boards: %d s of fuel", st.rules.fuel) or "rocket boards on" end
			if st.rules.hover == false then rows.lines[#rows.lines + 1] = "no hoverboard" end
		end
		local n, min = #rows.players, mode.minPlayers or 1
		local hostName
		for _, p in ipairs(rows.players) do if p.host then hostName = p.name end end
		if n < min then
			rows.hint = string.format("waiting for %d more player%s (%d / %d)", min - n, min - n == 1 and "" or "s", n, min)
		elseif mode:IsHost(st) then
			rows.hint, rows.ready = "ready: LB + D-pad left to start", true
		else
			rows.hint, rows.ready = "ready: waiting for " .. (hostName or "the host") .. " to start", true
		end
		return rows
	end

	function M.TextWidth(text, font)
		if not (surface and surface.SetFont and surface.GetTextSize) then return 0 end
		surface.SetFont(font)
		local PAD = SKATEGM_UI and SKATEGM_UI.pad
		local tw = surface.GetTextSize(PAD and PAD.T and PAD.T(text) or text)
		return tw or 0
	end

	function M.Wrap(text, font, maxW)
		if M.TextWidth(text, font) <= maxW then return { text } end
		local out, cur = {}, ""
		for word in tostring(text):gmatch("%S+") do
			local try = cur == "" and word or (cur .. " " .. word)
			if cur ~= "" and M.TextWidth(try, font) > maxW then
				out[#out + 1] = cur
				cur = word
			else
				cur = try
			end
		end
		if cur ~= "" then out[#out + 1] = cur end
		return out
	end

	-- a menu is open (the minigame menu, settings, the map, replays, the park
	-- editor): game HUDs step aside for it. (A minigame's own screen, like
	-- Freeze Frame's photo, isn't one)
	M.MENU_SCREENS = { minigames = true, settings = true, map = true, replay = true, editor = true }
	function M.HudHidden()
		local UI = SKATEGM_UI
		return UI ~= nil and UI.open ~= nil and M.MENU_SCREENS[UI.open] == true
	end

	-- a line too wide for the screen is drawn smaller to fit
	M.TEXT_MAX = 0.94

	function M.DrawLobby(w, h)
		if M.HudHidden() then return end
		local mode, st = M.MyGame()
		if not (mode and st and st.phase == "lobby") then return end
		local rows = M.LobbyRows(mode, st)
		local PAD = SKATEGM_UI and SKATEGM_UI.pad
		if PAD and PAD.Fonts then PAD.Fonts() end
		local big, small = PAD and "skategm_ui_title" or "DermaLarge", PAD and "skategm_ui_row" or "DermaDefaultBold"
		local x, y, line = w * 0.02, h * 0.22, h * 0.03
		local col = mode.color or Color(255, 210, 90)
		local maxW = w * 0.4
		local lines = {}
		for _, l in ipairs(rows.lines) do
			for _, piece in ipairs(M.Wrap(l, small, maxW)) do lines[#lines + 1] = piece end
		end
		local about = rows.about and M.Wrap(rows.about, small, maxW) or {}
		local widest = math.max(w * 0.24 - 20, M.TextWidth(rows.title, big), M.TextWidth(rows.hint, small))
		for _, l in ipairs(about) do widest = math.max(widest, M.TextWidth(l, small)) end
		for _, p in ipairs(rows.players) do widest = math.max(widest, M.TextWidth(p.name .. "  (host)", small)) end
		for _, l in ipairs(lines) do widest = math.max(widest, M.TextWidth(l, small)) end
		local count = #rows.players + #lines + (#about > 0 and #about + 0.5 or 0)
		if draw and draw.RoundedBox then draw.RoundedBox(8, x - 10, y - 8, widest + 20, line * (count + 4.6), Color(0, 0, 0, 170)) end
		M.Text(rows.title, big, x, y, col, TEXT_ALIGN_LEFT)
		y = y + line * 1.6
		for _, l in ipairs(about) do
			M.Text(l, small, x, y, Color(225, 225, 225), TEXT_ALIGN_LEFT)
			y = y + line
		end
		if #about > 0 then y = y + line * 0.5 end
		for _, p in ipairs(rows.players) do
			M.Text(p.name .. (p.host and "  (host)" or ""), small, x, y, p.me and col or color_white, TEXT_ALIGN_LEFT)
			y = y + line
		end
		for _, l in ipairs(lines) do
			M.Text(l, small, x, y, Color(190, 190, 190), TEXT_ALIGN_LEFT)
			y = y + line
		end
		M.Text(rows.hint, small, x, y + line * 0.3, rows.ready and Color(140, 230, 140) or Color(200, 200, 200), TEXT_ALIGN_LEFT)
	end
	if hook and hook.Add then hook.Add("HUDPaint", "skategm_modes_lobby", function() M.DrawLobby(ScrW(), ScrH()) end) end

	-- a game's boundary wall: outside it the screen fades to black; back
	-- inside before it's black, nothing happened. Fully black: the game's
	-- penalty (out(), e.g. the melon dropped, eliminated) and back to the
	-- start. fn(st) -> { area = { x, y, z, radius }, pos, yaw, out } while it applies
	M.BOUNDARY_FADE = 3
	function Mode:Boundary(fn) self.boundaryFn = fn end

	function M.BoundaryThink(now)
		local B = M.boundary
		local mode, st = M.MyGame()
		local ok, b = false, nil
		if mode and mode.boundaryFn and M.InPlay(st) then ok, b = pcall(mode.boundaryFn, st) end
		local a = M.API()
		local pos = a and a.SkaterPos and a.SkaterPos()
		if not (ok and b and b.area and pos and a.IsSkating and a.IsSkating()) then
			M.boundary = nil
			return
		end
		local ar = b.area
		local outside = (pos.x - ar[1]) ^ 2 + (pos.y - ar[2]) ^ 2 > ar[4] ^ 2
		if not outside then
			M.boundary = nil
			return
		end
		B = B or { since = now }
		M.boundary = B
		if now - B.since < M.BOUNDARY_FADE then return end
		M.boundary = nil
		if b.out then pcall(b.out) end
		if b.pos and a.TeleportTo and a.TeleportTo(b.pos, b.yaw or 0) and M.polish then M.polish.Fade(now) end
		if a.Say then a.Say("out of bounds: back to the start") end
	end

	-- how far into the fade (0-1), for the black and the warning
	function M.BoundaryFade(now)
		local B = M.boundary
		return B and math.Clamp((now - B.since) / M.BOUNDARY_FADE, 0, 1) or 0
	end

	function M.DrawBoundary(w, h, now)
		local k = M.BoundaryFade(now)
		if k <= 0 then return end
		surface.SetDrawColor(0, 0, 0, 255 * k)
		surface.DrawRect(0, 0, w, h)
		local PAD = SKATEGM_UI and SKATEGM_UI.pad
		if PAD and PAD.Fonts then PAD.Fonts() end
		M.Text(string.format("OUT OF BOUNDS: GET BACK IN  %.1f", math.max(0, M.BOUNDARY_FADE * (1 - k))), PAD and "skategm_ui_title" or "DermaLarge", w / 2, h * 0.45, Color(255, 120, 100), TEXT_ALIGN_CENTER, 2)
	end
	if hook and hook.Add then
		hook.Add("Think", "skategm_modes_boundary", function() M.BoundaryThink(RealTime()) end)
		hook.Add("HUDPaint", "skategm_modes_boundary", function() M.DrawBoundary(ScrW(), ScrH(), RealTime()) end)
	end

	function Mode:Host(def)
		if def.boardRules ~= false and not def.wrappedRules then
			def.wrappedRules = true
			def.options = def.options or {}
			local have = {}
			for _, o in ipairs(def.options) do have[o.key] = true end
			for _, o in ipairs(M.BOARD_OPTIONS) do
				if not have[o.key] and not (o.key == "_rocket" and def.rocket == "force") then def.options[#def.options + 1] = o end
			end
			local start = def.start
			def.start = function(v, mode)
				local rk = v._rocket
				local on = rk == true or (type(rk) == "number" and rk ~= 0)
				mode.pendingRules = { rocket = def.rocket == "force" and "force" or (on and "on" or false), fuel = def.rocket ~= "force" and M.CleanFuel(rk) or nil, hover = v._hover == true and "on" or false }
				return start(v, mode)
			end
		end
		if def.useStart ~= false and not def.wrappedStart then
			def.wrappedStart = true
			def.options = def.options or {}
			local o = {}
			for k, val in pairs(M.START_OPTION) do o[k] = val end
			o.draw = function(obj, alpha) M.DrawStartMarker(obj.pos, (obj.yaw + 180) % 360, alpha) end
			o.summary = function() return "placed" end
			table.insert(def.options, 1, o)
			local start = def.start
			def.start = function(v, mode)
				local s = v._start
				local resolved
				if s then
					resolved = { pos = s.pos, yaw = (s.yaw + 180) % 360, placed = true }
				else
					local a = M.API()
					local view = a and a.View and a.View()
					local me = LocalPlayer()
					local yaw = view and view.angles and view.angles.y or (me.EyeAngles and me:EyeAngles().y) or 0
					resolved = { pos = M.Here(), yaw = yaw }
				end
				v._start = resolved
				mode.pendingStart = resolved
				return start(v, mode)
			end
		end
		self.hostDef = def
	end

	-- the board rules of the game a player is playing (nil: no game, or no rules)
	function M.RulesFor(ply)
		local ent = IsValid(ply) and ply.EntIndex and ply:EntIndex()
		if not ent then return nil end
		local function has(st)
			if not (st and st.rules and M.InPlay(st)) then return false end
			for _, p in ipairs(st.players or {}) do if p.ent == ent then return true end end
			return false
		end
		for _, mode in pairs(M.modes) do
			if has(mode.state) then return mode.state.rules end
			for _, entry in pairs(mode.seen or {}) do if has(entry.st) then return entry.st.rules end end
		end
	end
	-- before the go (a countdown, getting to the start): no rocket, so nobody
	-- builds up speed on the line
	M.STARTING_PHASES = { countdown = true, prep = true, leadcount = true, copycount = true }
	function M.Starting(ply)
		if not (IsValid(ply) and ply == LocalPlayer()) then return false end
		local _, st = M.MyGame()
		return st ~= nil and M.STARTING_PHASES[st.phase] == true
	end
	function M.RocketAllowed(ply)
		if M.Starting(ply) then return false end
		local r = M.RulesFor(ply)
		return r == nil or r.rocket ~= false
	end
	function M.RocketForced(ply) local r = M.RulesFor(ply) return r ~= nil and r.rocket == "force" and not M.Starting(ply) end
	function M.RocketOn(ply) local r = M.RulesFor(ply) return r ~= nil and (r.rocket == "on" or r.rocket == "force") end
	-- the game's rocket fuel for this player: seconds, nil (infinite), or
	-- false (no game rule: their own setting decides)
	function M.RocketFuel(ply)
		local r = M.RulesFor(ply)
		if r and r.rocket == "on" then return r.fuel end
		if r and r.rocket == "force" then return nil end
		return false
	end
	function M.HoverAllowed(ply) local r = M.RulesFor(ply) return r == nil or r.hover ~= false end
	function M.HoverOn(ply) local r = M.RulesFor(ply) return r ~= nil and r.hover == "on" end

	function Mode:HoldAtStart(holding, pos, yaw, now)
		local a = M.API()
		if not a then return end
		if holding and pos then
			if not self.holdPlaced and now >= (self.nextHoldTry or 0) then
				self.nextHoldTry = now + 0.3
				if a.TeleportTo(pos, yaw) then
					if M.polish then M.polish.Fade(now) end
					self.holdPlaced = true
					if a.Freeze then a.Freeze(true, self.id .. "_hold") end
				end
			end
		elseif self.holdPlaced then
			self.holdPlaced, self.nextHoldTry = nil, nil
			if a.Freeze then a.Freeze(false, self.id .. "_hold") end
		end
	end

	-- my turn just ended (st.last.ent is me): I stay where I am, in control
	-- (goof off in the bail), until the next one starts
	function M.JustDone(st) return st.phase == "between" and st.last ~= nil and st.last.ent == LocalPlayer():EntIndex() end

	-- my turn's prep, every frame (C.prep set when it began; C.IsMine): held
	-- at the start through prep and the countdown; once skating, moved there,
	-- and "ready" sent after settle seconds. True while it's my prep.
	function Mode:TurnPrep(C, st, a, now, pos, yaw, settle)
		local mine = C.IsMine(st)
		self:HoldAtStart(mine and a.IsSkating() and (st.phase == "countdown" or (st.phase == "prep" and C.prep ~= nil and C.prep.teleported)), pos, yaw, now)
		if not (st.phase == "prep" and mine and C.prep) then return false end
		if a.IsSkating() and not C.prep.teleported and pos then
			a.TeleportTo(pos, yaw)
			C.prep.teleported, C.prep.at = true, now
		end
		if C.prep.teleported and not C.prep.readySent and now - C.prep.at > (settle or 0.5) then
			C.prep.readySent = true
			self:Send({ cmd = "ready" })
		end
		return true
	end

	-- waiting (not my turn, or done): my skater frozen and the controller
	-- kept from it, whether or not there's anyone to watch
	function Mode:Wait(waiting)
		local a = M.API()
		if not a or (waiting or false) == (self.waiting or false) then return end
		self.waiting = waiting or nil
		if a.Freeze then a.Freeze(waiting, self.id .. "_wait") end
		if a.BlockInput then a.BlockInput(waiting, self.id .. "_wait") end
	end

	-- a game over (or back in its lobby, or I left): everything a mode holds
	-- on my skater is let go, whatever its own code forgot
	M.RELEASED = { idle = true, lobby = true, results = true }
	function Mode:ReleaseHolds()
		local a = M.API()
		if not a then return end
		self:Spectate(nil)
		self:Wait(false)
		self:HoldAtStart(false)
		if self.watching then self:Watch(false) end
		if a.ReleaseHolds then
			a.ReleaseHolds(self.id)
		else
			if a.Freeze then a.Freeze(false, self.id) end
			if a.BlockInput then a.BlockInput(false, self.id) end
			if a.SetHidden then a.SetHidden(self.id, false) end
		end
	end

	-- the safety net: in no game at all, nothing any game held stays held
	-- (a mode whose own code stops running when its game closes - an early
	-- return on "idle" - could leave its freeze, its camera or its hiding)
	M.SWEEP_EVERY = 1
	function M.Sweep(now)
		if now < (M.nextSweep or 0) then return end
		M.nextSweep = now + M.SWEEP_EVERY
		if M.MyGame() then return end
		local a = M.API()
		if not a then return end
		for id, mode in pairs(M.modes or {}) do
			if a.ReleaseHolds then a.ReleaseHolds(id) end
		end
		for _, why in ipairs(M.SWEPT) do if a.ReleaseHolds then a.ReleaseHolds(why) end end
		local SP = M.spectate
		if SP and SP.on and SP.Stop then SP.Stop() end
	end
	-- holds that aren't a mode's but only make sense in a game (items)
	M.SWEPT = { "items" }
	if hook and hook.Add then hook.Add("Think", "skategm_modes_sweep", function() M.Sweep(RealTime()) end) end

	function M.PosTable(v) return { v.x, v.y, v.z } end
	function Mode:JoinInfo(fn) self.joinInfoFn = fn end
	function Mode:HostActions(fn) self.hostActionsFn = fn end
	function Mode:OnJoin(fn) self.joinFn = fn end

	function Mode:SendSequence(list)
		local mode = self
		for i, cmd in ipairs(list) do
			if i == 1 then mode:Send(cmd) else timer.Simple((i - 1) * 0.12, function() mode:Send(cmd) end) end
		end
	end

	function Mode:Info() return self:InfoFor(self.state or {}) end

	function Mode:InfoFor(st)
		st = st or {}
		if self.joinInfoFn then return self.joinInfoFn(st) end
		if not st.phase or st.phase == "idle" then return nil end
		local host = st.host and st.host ~= 0 and Entity(st.host)
		local name = (host and IsValid(host) and host.Nick) and host:Nick() or "someone"
		return { host = name, phase = st.phase, joinable = st.phase == "lobby" and self:Me(st) == nil, mine = self:IsHost(st), playing = self:Me(st) ~= nil }
	end

	function Mode:Join(session)
		if self.joinFn then return self.joinFn(session) end
		self:Send({ cmd = "join", session = session, canSkate = M.CanSkate() })
	end

	function Mode:Leave() self:Send({ cmd = "leave" }) end

	-- invites: a member of a game in its lobby asks the server to send one;
	-- it lasts while that game is still in its lobby (LB + RT joins)
	M.NET_INVITE = "skategm_modes_invite"
	M.INVITE_TOAST = 8
	function M.ReceiveInvite(id, session, from, now)
		local mode = M.modes[id]
		if not mode then return end
		M.invite = { mode = id, session = tonumber(session) or (session ~= "" and session or nil), from = from, at = now or RealTime() }
		mode:Say(from .. " invited you to " .. mode.title .. ": LB + RT to join")
		if surface and surface.PlaySound then surface.PlaySound("buttons/button17.wav") end
	end
	if net and net.Receive then
		net.Receive(M.NET_INVITE, function() M.ReceiveInvite(net.ReadString(), net.ReadString(), net.ReadString()) end)
	end
	function M.InviteState(inv)
		local mode = inv and M.modes[inv.mode]
		if not mode then return nil end
		if inv.session ~= nil and mode.seen then
			local entry = mode.seen[inv.session]
			return mode, entry and entry.st
		end
		return mode, mode.lastSeenState or mode.state
	end
	function M.InviteActive()
		local inv = M.invite
		if not inv then return false end
		local mode, st = M.InviteState(inv)
		local mine = M.MyGame and M.MyGame()
		if not (mode and st and st.phase == "lobby") or mine ~= nil then
			M.invite = nil
			return false
		end
		return true
	end
	function M.AcceptInvite()
		if not M.InviteActive() then return end
		local inv = M.invite
		M.invite = nil
		M.modes[inv.mode]:Join(inv.session)
	end
	function M.DrawInvite(w, h, now)
		if M.HudHidden() then return end
		local inv = M.invite
		if not inv or (now - inv.at) > M.INVITE_TOAST or not M.InviteActive() then return end
		local mode = M.modes[inv.mode]
		local text = M.ButtonWords(inv.from .. " invited you to " .. mode.title .. "   LB + RT to join")
		local PAD = SKATEGM_UI and SKATEGM_UI.pad
		if PAD and PAD.Fonts then PAD.Fonts() end
		local font = PAD and "skategm_ui_row" or "DermaDefaultBold"
		surface.SetFont(font)
		local tw = surface.GetTextSize(text)
		local k = math.min(1, (M.INVITE_TOAST - (now - inv.at)) * 2)
		draw.RoundedBox(8, w / 2 - tw / 2 - 16, h * 0.14, tw + 32, h * 0.05, Color(0, 0, 0, 200 * k))
		M.Text(text, font, w / 2, h * 0.14 + h * 0.012, Color(255, 255, 255, 255 * k), TEXT_ALIGN_CENTER)
	end
	if hook and hook.Add then hook.Add("HUDPaint", "skategm_modes_invite", function() M.DrawInvite(ScrW(), ScrH(), RealTime()) end) end

	function Mode:Restart()
		self:Send({ cmd = "stop" })
		self:Send({ cmd = "begin" })
	end

	function Mode:Actions()
		if self.hostActionsFn then return self.hostActionsFn(self.state or {}) end
		local mode = self
		local st = self.state or {}
		-- (in the lobby: start it or close it; once it's going: restart it -
		-- back to its lobby and straight off again, same players and settings -
		-- or close the whole game)
		if st.phase == nil or st.phase == "lobby" then
			return {
				{ label = "Start the game", run = function() mode:Send({ cmd = "begin" }) end },
				{ label = "Close the game", sub = "ends it for everyone", run = function() mode:Send({ cmd = "stop", close = true }) end },
			}
		end
		return {
			{ label = "Restart", sub = "start it again now: same players, same settings", run = function() mode:Restart() end },
			{ label = "Close the game", sub = "ends it for everyone", run = function() mode:Send({ cmd = "stop", close = true }) end },
		}
	end

	function Mode:Fonts(spec)
		local h = ScrH()
		if self.fontsAt == h then return end
		self.fontsAt = h
		for name, f in pairs(spec) do
			surface.CreateFont(name, { font = f[1], size = math.max(f[4] or 0, math.floor(h * f[2])), weight = f[3], antialias = true })
		end
	end

	local shadow = Color(0, 0, 0, 180)
	function M.ButtonWords(t)
		local P = SKATEGM_UI and SKATEGM_UI.pad
		return P and P.T and P.T(t) or t
	end

	function M.ChatLine(text, kind)
		if kind ~= "none" or type(text) ~= "string" or not text:match("^%[[^%]]+%] ") then return nil end
		local out = M.ButtonWords(text)
		if out ~= text then return out end
	end
	if hook and hook.Add then
		hook.Add("ChatText", "skategm_modes_buttons", function(_, _, text, kind)
			local line = M.ChatLine(text, kind)
			if line then
				chat.AddText(color_white, line)
				return true
			end
		end)
	end

	function M.Text(t, font, x, y, col, ax, offset)
		offset = offset or 2
		t = M.ButtonWords(t)
		local maxW = ScrW and ScrW() * M.TEXT_MAX
		local tw = maxW and M.TextWidth(t, font) or 0
		local fit = maxW and tw > maxW and Matrix and cam and cam.PushModelMatrix
		if fit then
			local s = maxW / tw
			local m = Matrix()
			m:Translate(Vector(x, y, 0))
			m:Scale(Vector(s, s, 1))
			m:Translate(Vector(-x, -y, 0))
			cam.PushModelMatrix(m)
		end
		draw.SimpleText(t, font, x + offset, y + offset, shadow, ax or TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
		draw.SimpleText(t, font, x, y, col or color_white, ax or TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
		if fit then cam.PopModelMatrix() end
	end

	-- the entity indexes of the others in a game's player list (filter: which)
	function M.Others(st, filter)
		local me, out = LocalPlayer():EntIndex(), {}
		for _, p in ipairs(st and st.players or {}) do
			if p.ent ~= me and (not filter or filter(p)) then out[#out + 1] = p.ent end
		end
		return out
	end

	M.WALL_SEGMENTS = 96
	M.walls = {}
	function M.AreaWall(center, radius, col)
		local key = string.format("%.0f %.0f %.0f", center.x, center.y, radius)
		local edges = M.walls[key]
		if not edges then
			edges = {}
			for i = 1, M.WALL_SEGMENTS do
				local a0, a1 = (i - 1) / M.WALL_SEGMENTS * math.pi * 2, i / M.WALL_SEGMENTS * math.pi * 2
				edges[i] = { Vector(center.x + math.cos(a0) * radius, center.y + math.sin(a0) * radius, 0),
					Vector(center.x + math.cos(a1) * radius, center.y + math.sin(a1) * radius, 0) }
			end
			M.walls[key] = edges
		end
		local B = SkateGM and SkateGM.boundary
		if B and B.DrawBand then B.DrawBand(edges, col, center.z) end
		if B and B.DrawEdges then B.DrawEdges(edges, col) end
	end

	function M.Ring(center, radius, col, segments)
		segments = segments or 32
		local prev = center + Vector(radius, 0, 0)
		for i = 1, segments do
			local a = i / segments * math.pi * 2
			local p = center + Vector(math.cos(a) * radius, math.sin(a) * radius, 0)
			render.DrawLine(prev, p, col, true)
			prev = p
		end
	end
end

function M.Register(def)
	assert(type(def) == "table" and type(def.id) == "string" and def.id:match("^[%w_]+$"), "SKATEGM_MODES.Register: needs an id (letters, digits, _)")
	local old = M.modes[def.id]
	local mode = old or setmetatable({}, Mode)
	mode.id = def.id
	mode.title = def.title or def.id
	mode.color = def.color or mode.color
	mode.minPlayers = def.minPlayers or mode.minPlayers
	mode.order = def.order or 100
	mode.category = def.category or mode.category
	mode.music = def.music or mode.music
	mode.chat = (def.chat or ("!" .. def.id)):lower()
	mode.NET_STATE = def.netState or ("skategm_mode_" .. def.id .. "_state")
	mode.NET_CMD = def.netCommand or ("skategm_mode_" .. def.id .. "_cmd")
	mode.maxBits = def.maxCommandBytes and def.maxCommandBytes * 8 or nil
	if def.allowed ~= false and CreateConVar and not mode.cvAllowed then
		local name = def.allowedConVar or ("skategm_" .. def.id .. "_allowed")
		mode.allowedName = name
		mode.cvAllowed = GetConVar and GetConVar(name) or CreateConVar(name, def.allowedDefault == false and "0" or "1",
			bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY), "1 = " .. mode.title .. " can be played on this server, 0 = it can't", 0, 1)
	end
	M.modes[def.id] = mode
	if not old then mode:Install() end
	if hook and hook.Run then hook.Run("Sk8ModeRegistered", mode) end
	return mode
end

if SERVER then AddCSLuaFile("skategm_modes/cl_menu.lua") AddCSLuaFile("skategm_modes/cl_spectate.lua") AddCSLuaFile("skategm_modes/cl_music.lua") AddCSLuaFile("skategm_modes/cl_polish.lua") AddCSLuaFile("skategm_modes/cl_spotgame.lua") end
if CLIENT and not M.menu then include("skategm_modes/cl_menu.lua") end
if CLIENT and not M.spectate then include("skategm_modes/cl_spectate.lua") end
if CLIENT and not M.music then include("skategm_modes/cl_music.lua") end
if CLIENT and not M.polish then include("skategm_modes/cl_polish.lua") end

if not M.announced then
	M.announced = true
	if hook and hook.Run then hook.Run("Sk8ModesReady", M) end
end
