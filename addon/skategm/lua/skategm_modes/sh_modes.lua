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
function M.InPlay(st) return st ~= nil and st.phase ~= nil and not M.FREE_PHASES[st.phase] end

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
	local z, bottom = ref + M.GROUND_SPAN, ref - M.GROUND_SPAN
	for _ = 1, M.GROUND_STEPS do
		if z <= bottom then break end
		local tr = util.TraceLine({ start = Vector(x, y, z), endpos = Vector(x, y, bottom), mask = MASK_PLAYERSOLID })
		if not tr.Hit or tr.HitSky then break end
		local hz = tr.HitPos.z
		if not tr.StartSolid and tr.HitNormal and tr.HitNormal.z > 0.5 then
			local gap = math.abs(hz - ref)
			if not bestGap or gap < bestGap then best, bestGap = hz, gap end
		end
		z = math.min(z, hz) - 8
	end
	return best or ref
end

if SERVER then
	function M.PlayerInPlay(ply)
		local mode, key = M.SessionOf(ply)
		if not mode then return false end
		local st = (mode.live and key ~= true) and mode:SessionData(key) or mode.lastState
		return M.InPlay(st)
	end

	hook.Add("SkateGMCanRespawn", "skategm_modes", function(ply)
		if M.PlayerInPlay(ply) then return false end
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
	function Mode:Resend(now)
		for key, entry in pairs(self.lastStates or {}) do
			if now - entry.at >= M.RESEND then
				entry.at = now
				net.Start(self.NET_STATE)
				net.WriteString(Encode(entry.state))
				net.Broadcast()
			end
		end
	end

	function Mode:Broadcast(state, now)
		state.session = self.live and self.current or nil
		self.lastState = state
		self.lastBroadcast = now or CurTime()
		self.lastStates = self.lastStates or {}
		self.lastStates[state.session or "only"] = state.phase ~= "idle" and { state = state, at = self.lastBroadcast } or nil
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
		if not self.live then
			self.commandHandler(ply, m, CurTime())
			return true
		end
		local key = self:RouteCommand(ply, m)
		if key == false then return true end
		self:Enter(key)
		self.commandHandler(ply, m, CurTime())
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
	M.POINT_KEYS = { pos = true, centre = true, center = true, start = true, finish = true, spot = true, area = true }
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
			self.state = st
			if self.stateHandler then self.stateHandler(st, now) end
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
			self.state = st
			if self.stateHandler then self.stateHandler(st, now) end
		elseif key == self.mySession then
			self.mySession = nil
			self.state = { phase = "idle" }
			if self.stateHandler then self.stateHandler(self.state, now) end
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

	-- playing a minigame right now (not its lobby or results): no respawning
	-- or teleporting then
	function M.Playing() return M.InPlay(select(2, M.MyGame())) end

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
	function Mode:Watch(watching, view)
		local a = M.API()
		if not a then return end
		if a.IsLocked and a.IsLocked() then
			if watching and not self.watching then
				self.watching = true
				if a.Freeze then a.Freeze(true) end
				if a.SetView then a.SetView(view) end
			elseif not watching and self.watching then
				self.watching = nil
				if a.SetView then a.SetView(nil) end
				if a.Freeze then a.Freeze(false) end
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

	function Mode:Host(def) self.hostDef = def end

	function Mode:HoldAtStart(holding, pos, yaw, now)
		local a = M.API()
		if not a then return end
		if holding and pos then
			if not self.holdPlaced and now >= (self.nextHoldTry or 0) then
				self.nextHoldTry = now + 0.3
				if a.TeleportTo(pos, yaw) then
					self.holdPlaced = true
					if a.Freeze then a.Freeze(true) end
				end
			end
		elseif self.holdPlaced then
			self.holdPlaced, self.nextHoldTry = nil, nil
			if a.Freeze then a.Freeze(false) end
		end
	end

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

	function Mode:Actions()
		if self.hostActionsFn then return self.hostActionsFn(self.state or {}) end
		local mode = self
		local st = self.state or {}
		-- (in the lobby: start it or close it; once it's going: end the round,
		-- back to the lobby with everyone still in, or close the whole game)
		if st.phase == nil or st.phase == "lobby" then
			return {
				{ label = "Start the game", run = function() mode:Send({ cmd = "begin" }) end },
				{ label = "Close the game", sub = "ends it for everyone", run = function() mode:Send({ cmd = "stop", close = true }) end },
			}
		end
		return {
			{ label = "End this round", sub = "back to the lobby, everyone still in", run = function() mode:Send({ cmd = "stop" }) end },
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
		draw.SimpleText(t, font, x + offset, y + offset, shadow, ax or TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
		draw.SimpleText(t, font, x, y, col or color_white, ax or TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
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
	mode.order = def.order or 100
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

if SERVER then AddCSLuaFile("skategm_modes/cl_menu.lua") end
if CLIENT and not M.menu then include("skategm_modes/cl_menu.lua") end

if not M.announced then
	M.announced = true
	if hook and hook.Run then hook.Run("Sk8ModesReady", M) end
end
