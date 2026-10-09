-- Board Golf, server: the game. Uses only SkateGM.API from the skating add-on.

local BG = BOARDGOLF
local S = { phase = "idle" }
BG.session = S
BG.mode:UseSessions(S)

local Allowed, Skating = SKATEGM_MODES.Allowed, SKATEGM_MODES.Skating
local function Tell(ply, text) BG.mode:Tell(ply, text) end
local function Key(ply) return SKATEGM_MODES.Key(ply) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(S.players, ply) end
local function Ent(ply) return IsValid(ply) and ply:EntIndex() or 0 end
local PLAYING = { flyover = true, prep = true, countdown = true, shot = true, roll = true, between = true }

local function Public(now)
	local t = { phase = S.phase }
	if S.phase == "idle" then return t end
	t.host = Ent(S.host)
	t.tee, t.cup, t.yaw = S.tee, S.cup, S.yaw
	t.cupSize, t.radius, t.shotTime, t.maxStrokes, t.par = S.cupSize, S.radius, S.shotTime, S.maxStrokes, S.par
	t.friction = S.friction
	t.active = Ent(S.active)
	t.timeLeft = S.deadline and math.max(0, S.deadline - now) or 0
	t.last, t.winners = S.last, S.winners
	t.board = IsValid(S.board) and S.board:EntIndex() or nil
	t.players = {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)] or {}
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), strokes = e.strokes or 0, holed = e.holed or nil,
			lie = e.lie, playing = e.playing or nil, picked = e.picked or nil }
	end
	return t
end

local function Broadcast(now) BG.mode:Broadcast(Public(now or CurTime()), now) end
BG.Broadcast = Broadcast

local function Freezes() SKATEGM_MODES.FreezeWatchers(S.players, S.active, PLAYING[S.phase] == true) end

local function DropBall()
	if IsValid(S.board) then S.board:Remove() end
	S.board, S.stillSince = nil, nil
end
BG.DropBall = DropBall

local function Stop(reason, now)
	DropBall()
	for _, p in ipairs(S.players or {}) do if IsValid(p) then p:Freeze(false) end end
	for k in pairs(S) do S[k] = nil end
	S.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
BG.Stop = Stop

local function ToLobby(now)
	DropBall()
	S.phase, S.active, S.deadline, S.last, S.winners = "lobby", nil, nil, nil, nil
	for _, e in pairs(S.entries) do e.strokes, e.holed, e.lie, e.playing, e.picked = 0, nil, nil, nil, nil end
	Freezes()
	Broadcast(now)
end

local function Results(now)
	local best, names = nil, {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)]
		if e.playing then
			if not best or e.strokes < best then best, names = e.strokes, { p:Nick() } elseif e.strokes == best then names[#names + 1] = p:Nick() end
		end
	end
	S.winners = { names = names, strokes = best or 0 }
	S.phase, S.active, S.deadline = "results", nil, now + BG.RESULTS
	Freezes()
	Broadcast(now)
	Tell(nil, #names > 0 and (table.concat(names, " and ") .. " win" .. (#names == 1 and "s" or "") .. " in " .. best .. " (par " .. S.par .. ")") or "nobody finished")
end

local function NextShot(now)
	DropBall()
	local list = {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)]
		if e.playing then list[#list + 1] = { ply = p, holed = e.holed, lie = e.lie } end
	end
	local up = BG.NextUp(list, S.cup)
	if not up then return Results(now) end
	S.active = up.ply
	S.phase, S.deadline, S.offSince = "prep", now + BG.PREP_TIMEOUT, nil
	Freezes()
	Broadcast(now)
end
BG.NextShot = NextShot

-- the active player's stroke is over: the board rests at pos (nil: it didn't count where it went)
function BG.Stroke(ply, pos, how, now)
	if S.active ~= ply or not (S.phase == "shot" or S.phase == "roll") then return end
	if IsValid(S.board) then
		local phys = S.board:GetPhysicsObject()
		if IsValid(phys) then phys:EnableMotion(false) end
	end
	local e = S.entries[Key(ply)]
	e.strokes = e.strokes + 1
	local result = how or "lie"
	if pos then
		if BG.InCup(pos, S.cup, S.radius) then
			e.holed, result = true, "holed"
		else
			e.lie = pos
		end
	end
	if not e.holed and e.strokes >= S.maxStrokes then
		e.strokes, e.holed, e.picked, result = S.maxStrokes + BG.PICKUP, true, true, "picked"
	end
	S.last = { name = ply:Nick(), ent = ply:EntIndex(), strokes = e.strokes, result = result,
		distance = (not e.holed) and math.floor(BG.Distance(e.lie, S.cup) + 0.5) or nil }
	S.phase, S.active, S.deadline = "between", nil, now + BG.BETWEEN
	Freezes()
	Broadcast(now)
	if result == "holed" then Tell(nil, string.format("%s holed out in %d!", ply:Nick(), e.strokes))
	elseif result == "picked" then Tell(nil, ply:Nick() .. " picked up (" .. e.strokes .. ")") end
end

function BG.Tick(now)
	local ph = S.phase
	if ph == "idle" or ph == "lobby" then return end
	if ph == "flyover" and now > S.deadline then
		NextShot(now)
	elseif ph == "prep" and now > S.deadline then
		Tell(nil, (IsValid(S.active) and S.active:Nick() or "?") .. " couldn't get to their lie in time: a stroke")
		S.phase = "shot"
		BG.Stroke(S.active, nil, "skipped", now)
	elseif ph == "countdown" and now > S.deadline then
		S.phase, S.deadline = "shot", now + S.shotTime + BG.RELEASE_GRACE
		Broadcast(now)
	elseif ph == "roll" then
		local ball = S.board
		if not IsValid(ball) then return BG.Stroke(S.active, nil, "lost", now) end
		local p = ball:GetPos()
		if S.sinkAt then
			if now - S.sinkAt >= BG.SINK_TIME then BG.Stroke(S.active, { S.cup[1], S.cup[2], S.cup[3] }, "lie", now) end
			return
		end
		if BG.InCup({ p.x, p.y, p.z }, S.cup, S.radius) and ball:Speed() < BG.CAPTURE_SPEED then
			S.sinkAt = now
			if ball.Sink then ball:Sink(Vector(S.cup[1], S.cup[2], S.cup[3])) end
			return
		end
		if ball:Speed() < BG.REST_SPEED then S.stillSince = S.stillSince or now else S.stillSince = nil end
		if (S.stillSince and now - S.stillSince >= BG.REST_TIME) or now > S.deadline then
			BG.Stroke(S.active, { p.x, p.y, p.z }, "lie", now)
		end
	elseif ph == "shot" then
		if not Skating(S.active) then
			S.offSince = S.offSince or now
			if now - S.offSince > 1 then return BG.Stroke(S.active, nil, "left", now) end
		else
			S.offSince = nil
		end
		if now > S.deadline then BG.Stroke(S.active, nil, "lost", now) end
	elseif ph == "between" and now > S.deadline then
		NextShot(now)
	elseif ph == "results" and now > S.deadline then
		ToLobby(now)
	end
end
BG.mode:OnThink(function(now) BG.Tick(now) end)

function BG.Remove(ply, why, now)
	now = now or CurTime()
	local i = IndexOf(ply)
	if not i then return end
	if IsValid(ply) then ply:Freeze(false) end
	table.remove(S.players, i)
	S.entries[Key(ply)] = nil
	if #S.players == 0 then return Stop("everyone left: Board Golf is over", now) end
	if S.host == ply then
		S.host = S.players[1]
		Tell(nil, S.host:Nick() .. " is the host now")
	end
	Tell(nil, ply:Nick() .. " " .. why)
	if S.active == ply then
		DropBall()
		S.active = nil
		S.phase, S.deadline = "between", now + 1
	end
	Broadcast(now)
end
BG.mode:OnPlayerLeave(function(ply) BG.Remove(ply, "left the game") end)

local handlers = {}
local function Host(ply) return S.phase ~= "idle" and S.host == ply end

function handlers.create(ply, m, now)
	if S.phase ~= "idle" then return Tell(ply, "a game is already open") end
	if BG.mode:CantSkate(ply, m, "host") then return end
	local cup = SKATEGM_MODES.Vec(m.cup)
	if not cup then return Tell(ply, "place the cup first") end
	local p = SKATEGM_MODES.HostStart(ply, m)
	S.phase, S.host = "lobby", ply
	S.tee = { p.x, p.y, p.z }
	S.cup = cup
	S.yaw = BG.YawTo(S.tee, cup)
	S.cupSize, S.shotTime, S.maxStrokes = BG.CupId(m.cupSize), BG.ClampShot(m.shotTime), BG.ClampStrokes(m.maxStrokes)
	S.radius = m.radius and BG.ClampRadius(m.radius) or BG.CupRadius(S.cupSize)
	S.par = BG.ParChoice(m.par) > 0 and BG.ParChoice(m.par) or BG.Par(BG.Distance(S.tee, cup))
	S.friction = BG.Friction(m.friction)
	S.players, S.entries = { ply }, {}
	S.entries[Key(ply)] = { name = ply:Nick(), strokes = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " is hosting Board Golf (par " .. S.par .. "): join with LB + D-pad left")
end

function handlers.join(ply, m, now)
	if S.phase == "idle" then return Tell(ply, "no game is open") end
	if S.phase ~= "lobby" then return Tell(ply, "a game is on: wait for the next one") end
	if IndexOf(ply) then return end
	if BG.mode:CantSkate(ply, m, "play") then return end
	S.players[#S.players + 1] = ply
	S.entries[Key(ply)] = { name = ply:Nick(), strokes = 0 }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " joined")
end

function handlers.leave(ply, m, now) BG.Remove(ply, "left the game", now) end

function handlers.begin(ply, m, now)
	if not Host(ply) then return Tell(ply, "only the host can start") end
	if S.phase ~= "lobby" then return end
	for _, e in pairs(S.entries) do
		e.playing, e.strokes, e.holed, e.picked = true, 0, nil, nil
		e.lie = { S.tee[1], S.tee[2], S.tee[3] }
	end
	S.phase, S.deadline = "flyover", now + BG.FlyTime(BG.Distance(S.tee, S.cup))
	Freezes()
	Broadcast(now)
end

function handlers.stop(ply, m, now)
	if S.phase == "idle" then return end
	if not (Host(ply) or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
	if m.close or S.phase == "lobby" then return Stop("Board Golf was closed by " .. ply:Nick(), now) end
	ToLobby(now)
	Tell(nil, ply:Nick() .. " stopped the game")
end

function handlers.ready(ply, m, now)
	if S.phase ~= "prep" or S.active ~= ply then return end
	S.phase, S.deadline = "countdown", now + BG.COUNTDOWN
	Broadcast(now)
end

-- the shot clock ran out (or B): my board, as it is, goes on as the ball
function handlers.release(ply, m, now)
	if S.phase ~= "shot" or S.active ~= ply then return end
	local pos, ang, vel = SKATEGM_MODES.Vec(m.pos), SKATEGM_MODES.Vec(m.ang), SKATEGM_MODES.Vec(m.vel)
	local at = ply.SkateGMHips
	if not pos or (at and math.sqrt((at.x - pos[1]) ^ 2 + (at.y - pos[2]) ^ 2 + (at.z - pos[3]) ^ 2) > BG.RELEASE_RANGE) then
		pos = at and { at.x, at.y, at.z } or nil
	end
	if not pos then return BG.Stroke(ply, nil, "lost", now) end
	local v = vel and Vector(vel[1], vel[2], vel[3]) or Vector(0, 0, 0)
	if v:Length() > BG.SPEED_MAX then v = v:GetNormalized() * BG.SPEED_MAX end
	local ball = ents.Create("skategm_golfboard")
	if not IsValid(ball) then return BG.Stroke(ply, { pos[1], pos[2], pos[3] }, "lie", now) end
	ball:SetPos(Vector(pos[1], pos[2], pos[3] + 3))
	ball:SetAngles(ang and Angle(ang[1], ang[2], ang[3]) or Angle(0, S.yaw or 0, 0))
	ball:SetSkater(ply)
	ball:Spawn()
	ball:Launch(v, S.friction)
	S.board, S.stillSince, S.sinkAt = ball, nil, nil
	S.phase, S.deadline = "roll", now + BG.SETTLE
	Broadcast(now)
end

BG.Command = BG.mode:Serve(S, handlers, function(why) BG.Stop(why) end, function() Broadcast() end)
