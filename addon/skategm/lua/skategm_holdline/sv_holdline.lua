-- Hold the Line, server: the game. Uses only SkateGM.API from the skating add-on.

local HL = HOLDLINE
local S = { phase = "idle" }
HL.session = S
HL.mode:UseSessions(S)

local Allowed = SKATEGM_MODES.Allowed
local function Tell(ply, text) HL.mode:Tell(ply, text) end
local function Key(ply) return SKATEGM_MODES.Key(ply) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(S.players, ply) end
local function Ent(ply) return IsValid(ply) and ply:EntIndex() or 0 end
local PLAYING = { countdown = true, riding = true, handover = true }

local function Public(now)
	local t = { phase = S.phase }
	if S.phase == "idle" then return t end
	t.host = Ent(S.host)
	t.start, t.yaw, t.turnTime, t.minSpeed = S.start, S.yaw, S.turnTime, S.minSpeed
	t.active = Ent(S.active)
	t.handover = S.handover
	t.timeLeft = S.deadline and math.max(0, S.deadline - now) or 0
	t.total, t.passes, t.turns = S.total or 0, S.passes or 0, S.turns or 0
	t.lineTime = S.startedAt and math.floor(((S.endedAt or now) - S.startedAt) * 10 + 0.5) / 10 or 0
	t.over, t.best = S.over, S.best
	local nextUp = S.order and S.order[HL.NextIndex(S.index or 1, #S.order)]
	t.nextUp = Ent(nextUp)
	t.players = {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)] or {}
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), playing = e.playing or nil, score = e.score or 0 }
	end
	return t
end

local function Broadcast(now) HL.mode:Broadcast(Public(now or CurTime()), now) end
HL.Broadcast = Broadcast

local function Stop(reason, now)
	for k in pairs(S) do S[k] = nil end
	S.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
HL.Stop = Stop

local function ToLobby(now)
	S.phase, S.deadline, S.active, S.handover, S.order, S.index, S.over, S.live = "lobby", nil, nil, nil, nil, nil, nil, nil
	S.total, S.passes, S.turns, S.startedAt, S.endedAt = 0, 0, 0, nil, nil
	for _, e in pairs(S.entries) do e.playing, e.score = nil, 0 end
	Broadcast(now)
end

-- the line's over for everyone
function HL.End(reason, ply, now)
	if not PLAYING[S.phase] then return end
	S.endedAt = now
	S.over = { reason = reason, name = IsValid(ply) and ply:Nick() or nil }
	local line = S.total or 0
	if not S.best or line > S.best.total or (line == S.best.total and (S.passes or 0) > S.best.passes) then
		S.best = { total = line, passes = S.passes or 0 }
	end
	S.phase, S.active, S.handover, S.deadline = "results", nil, nil, now + HL.RESULTS
	Broadcast(now)
	local why = reason == "bail" and ((S.over.name or "someone") .. " bailed")
		or reason == "stall" and ("the line slowed to a stop with " .. (S.over.name or "someone"))
		or reason == "left" and ((S.over.name or "someone") .. " left mid-line") or "the line ended"
	Tell(nil, string.format("%s: %s points, %d handover%s", why, SKATEGM_MODES.Commas(line), S.passes or 0, S.passes == 1 and "" or "s"))
end

local function Begin(now)
	S.index = 1
	S.active = S.order[1]
	S.handover = { pos = S.start, yaw = S.yaw, vel = { 0, 0, 0 } }
	S.total, S.passes, S.turns, S.over, S.live, S.startedAt, S.endedAt = 0, 0, 0, nil, nil, nil, nil
	S.phase, S.deadline = "countdown", now + HL.COUNTDOWN
	Broadcast(now)
end

-- the line moves on to the next skater, from where it is now
function HL.Pass(ply, pos, yaw, vel, score, now)
	if S.phase ~= "riding" or S.active ~= ply then return end
	local e = S.entries[Key(ply)]
	local got = math.max(0, math.floor(tonumber(score) or 0))
	if e then e.score = (e.score or 0) + got end
	S.total = (S.total or 0) + got
	S.passes, S.turns = (S.passes or 0) + 1, (S.turns or 0) + 1
	S.index = HL.NextIndex(S.index, #S.order)
	S.active = S.order[S.index]
	S.handover = { pos = pos, yaw = yaw, vel = vel }
	S.live = nil
	S.phase, S.deadline = "handover", now + HL.HANDOVER
	Broadcast(now)
end

function HL.Tick(now)
	local ph = S.phase
	if ph == "idle" or ph == "lobby" then return end
	if (ph == "countdown" or ph == "handover") and now > S.deadline then
		if not IsValid(S.active) or not IndexOf(S.active) then return HL.End("left", S.active, now) end
		S.phase, S.deadline = "riding", now + S.turnTime
		S.startedAt = S.startedAt or now
		Broadcast(now)
	elseif ph == "riding" then
		-- (no pass from the skater well after their time: pass from the last place they reported)
		if now > S.deadline + HL.PASS_WAIT then
			local l = S.live
			local at = IsValid(S.active) and S.active.SkateGMHips
			if l then return HL.Pass(S.active, l.pos, l.yaw, l.vel, l.score, now) end
			if at then return HL.Pass(S.active, { at.x, at.y, at.z }, S.yaw, { 0, 0, 0 }, 0, now) end
			return HL.End("left", S.active, now)
		end
	elseif ph == "results" and now > S.deadline then
		ToLobby(now)
	end
end
HL.mode:OnThink(function(now) HL.Tick(now) end)

function HL.Remove(ply, why, now)
	now = now or CurTime()
	local i = IndexOf(ply)
	if not i then return end
	table.remove(S.players, i)
	S.entries[Key(ply)] = nil
	if #S.players == 0 then return Stop("everyone left: Hold the Line is over", now) end
	if S.host == ply then
		S.host = S.players[1]
		Tell(nil, S.host:Nick() .. " is the host now")
	end
	Tell(nil, ply:Nick() .. " " .. why)
	if S.order then
		local k = SKATEGM_MODES.IndexOf(S.order, ply)
		if k then
			table.remove(S.order, k)
			if k < S.index then S.index = S.index - 1 end
			if #S.order == 0 then return HL.End("left", ply, now) end
			if S.index > #S.order then S.index = 1 end
		end
		if S.active == ply and PLAYING[S.phase] then return HL.End("left", ply, now) end
	end
	Broadcast(now)
end
HL.mode:OnPlayerLeave(function(ply) HL.Remove(ply, "left the game") end)

local handlers = {}
local function Host(ply) return S.phase ~= "idle" and S.host == ply end

function handlers.create(ply, m, now)
	if S.phase ~= "idle" then return Tell(ply, "a game is already open") end
	if HL.mode:CantSkate(ply, m, "host") then return end
	local p, startYaw = SKATEGM_MODES.HostStart(ply, m)
	S.phase, S.host = "lobby", ply
	S.start, S.yaw = { p.x, p.y, p.z }, startYaw
	S.turnTime, S.minSpeed = HL.ClampTurn(m.turnTime), HL.MinSpeed(m.minSpeed)
	S.players, S.entries = { ply }, {}
	S.entries[Key(ply)] = { name = ply:Nick(), score = 0 }
	S.total, S.passes, S.turns = 0, 0, 0
	Broadcast(now)
	Tell(nil, ply:Nick() .. " is hosting Hold the Line: join with LB + D-pad left")
end

function handlers.join(ply, m, now)
	if S.phase == "idle" then return Tell(ply, "no game is open") end
	if S.phase ~= "lobby" then return Tell(ply, "a line is going: wait for the next one") end
	if IndexOf(ply) then return end
	if HL.mode:CantSkate(ply, m, "play") then return end
	S.players[#S.players + 1] = ply
	S.entries[Key(ply)] = { name = ply:Nick(), score = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " joined")
end

function handlers.leave(ply, m, now) HL.Remove(ply, "left the game", now) end

function handlers.begin(ply, m, now)
	if not Host(ply) then return Tell(ply, "only the host can start") end
	if S.phase ~= "lobby" then return end
	S.order = {}
	for _, p in ipairs(S.players) do
		S.order[#S.order + 1] = p
		S.entries[Key(p)].playing, S.entries[Key(p)].score = true, 0
	end
	Begin(now)
end

function handlers.stop(ply, m, now)
	if S.phase == "idle" then return end
	if not (Host(ply) or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
	if m.close or S.phase == "lobby" then return Stop("Hold the Line was closed by " .. ply:Nick(), now) end
	ToLobby(now)
	Tell(nil, ply:Nick() .. " stopped the game")
end

local function Clean(m, ply)
	local pos, vel = SKATEGM_MODES.Vec(m.pos), SKATEGM_MODES.Vec(m.vel)
	local yaw = tonumber(m.yaw)
	local at = ply.SkateGMHips
	if not pos or (at and math.sqrt((at.x - pos[1]) ^ 2 + (at.y - pos[2]) ^ 2 + (at.z - pos[3]) ^ 2) > HL.PASS_RANGE) then
		pos = at and { at.x, at.y, at.z } or nil
	end
	if not (yaw and yaw == yaw) then yaw = S.yaw end
	vel = vel or { 0, 0, 0 }
	local speed = math.sqrt(vel[1] ^ 2 + vel[2] ^ 2 + vel[3] ^ 2)
	if speed > HL.SPEED_CAP then vel = { vel[1] / speed * HL.SPEED_CAP, vel[2] / speed * HL.SPEED_CAP, vel[3] / speed * HL.SPEED_CAP } end
	return pos, yaw, vel
end

-- where the line is (a few times a second, from the skater holding it)
function handlers.live(ply, m, now)
	if S.phase ~= "riding" or S.active ~= ply then return end
	local pos, yaw, vel = Clean(m, ply)
	if pos then S.live = { pos = pos, yaw = yaw, vel = vel, score = tonumber(m.score) or 0 } end
end

-- my time's up and I'm rolling: the line goes on from here
function handlers.pass(ply, m, now)
	if S.phase ~= "riding" or S.active ~= ply or now < S.deadline - 0.5 then return end
	local pos, yaw, vel = Clean(m, ply)
	if not pos then return end
	HL.Pass(ply, pos, yaw, vel, m.score, now)
end

function handlers.bail(ply, m, now)
	if S.phase ~= "riding" or S.active ~= ply then return end
	HL.End("bail", ply, now)
end

function handlers.stall(ply, m, now)
	if S.phase ~= "riding" or S.active ~= ply or (S.minSpeed or 0) <= 0 then return end
	HL.End("stall", ply, now)
end

HL.Command = HL.mode:Serve(S, handlers, function(why) HL.Stop(why) end, function() Broadcast() end)
