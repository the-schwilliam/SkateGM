-- Race, client: follows the server's race state, runs your race, and draws
-- the start, the finish and the times. Uses only SkateGM.API.
local C = { state = { phase = "idle" } }
RACE.client = C

local API = SKATEGM_MODES.API
local function Send(t) RACE.mode:Send(t) end
C.Send = Send
local function Say(text, bad) RACE.mode:Say(text, bad) end

-- where I am, for placing the start and finish: my skater if skating, else me
local Here = SKATEGM_MODES.Here

function C.Me(st) return RACE.mode:Me(st) end
function C.IsHost(st) return RACE.mode:IsHost(st) end

local RACING = { countdown = true, racing = true, results = true }

---------------------------------------------------------------------------
-- following the server
---------------------------------------------------------------------------
function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	st.startV = st.start and Vector(st.start[1], st.start[2], st.start[3]) or nil
	st.finishV = st.finish and Vector(st.finish[1], st.finish[2], st.finish[3]) or nil
	local me, a = C.Me(st), API()
	-- other skaters aren't solid to me while I race
	RACE.mode:NoCollide(me and RACING[st.phase])
	if not me then C.finishedSent, C.switchedOn = nil, nil return end
	-- in a race: into Skater mode now, so I'm loaded when the host starts it
	if not C.switchedOn and a and not a.IsSkating() then
		C.switchedOn = true
		a.StartSkating()
	end
	if st.phase == "countdown" and prev.phase ~= "countdown" then
		C.finishedSent = nil
		if not me.racing then Say("you weren't in Skater mode in time: this one's without you", true) end
	end
	if st.phase == "racing" and prev.phase ~= "racing" then
		C.goAt = now
		C.finishedSent = nil
	end
	if st.phase == "lobby" then C.finishedSent = nil end
end

function C.Think(now)
	local st, a = C.state, API()
	local me = C.Me(st)
	RACE.mode:HoldAtStart(me ~= nil and me.racing and st.phase == "countdown", st.startV and RACE.Slot(st.startV), st.yaw, now)
	if not me or not a then return end
	if not me.racing then return end
	-- at GO: exactly on the start, once
	if st.phase == "racing" and st.startV and not C.launched then
		C.launched = true
		a.TeleportTo(RACE.Slot(st.startV), st.yaw)
	end
	if st.phase ~= "racing" then C.launched = nil end
	-- over the line
	if st.phase == "racing" and not C.finishedSent and not me.time and st.finishV then
		local p = a.SkaterPos and a.SkaterPos()
		if p and p:Distance(st.finishV) <= (st.radius or RACE.RADIUS_DEFAULT) then
			C.finishedSent = true
			Send({ cmd = "finished" })
		end
	end
end

RACE.mode:OnState(function(st, now) C.OnState(st, now) end)
hook.Add("Think", "skategm_race", function() C.Think(RealTime()) end)

---------------------------------------------------------------------------
-- in the world: the start gate and the finish
---------------------------------------------------------------------------
local BLUE, GREEN = Color(120, 220, 255), Color(120, 255, 140)
local Ring = SKATEGM_MODES.Ring
-- a gate across the start, and an arrow the way to go
function C.DrawStart(pos, yaw, alpha)
	render.SetColorMaterial()
	local r0 = math.rad(yaw or 0)
	local right = Vector(math.sin(r0), -math.cos(r0), 0)
	local col = Color(BLUE.r, BLUE.g, BLUE.b, 200 * (alpha or 1))
	local a, b = pos - right * 48, pos + right * 48
	render.DrawLine(a, b, col, true)
	render.DrawBox(a, angle_zero, Vector(-1, -1, 0), Vector(1, 1, 64), col)
	render.DrawBox(b, angle_zero, Vector(-1, -1, 0), Vector(1, 1, 64), col)
	local fwd = Vector(math.cos(r0), math.sin(r0), 0)
	render.DrawLine(pos + Vector(0, 0, 4), pos + Vector(0, 0, 4) + fwd * 64, col, true)
	render.DrawLine(pos + Vector(0, 0, 4) + fwd * 64, pos + Vector(0, 0, 4) + fwd * 48 + right * 12, col, true)
	render.DrawLine(pos + Vector(0, 0, 4) + fwd * 64, pos + Vector(0, 0, 4) + fwd * 48 - right * 12, col, true)
end

-- the finish: a ring on the ground as big as it counts, and a beacon
function C.DrawFinish(pos, radius, pulse, alpha)
	render.SetColorMaterial()
	local k = alpha or 1
	Ring(pos + Vector(0, 0, 2), radius or RACE.RADIUS_DEFAULT, Color(GREEN.r, GREEN.g, GREEN.b, 255 * pulse * k))
	SKATEGM_MODES.Beacon(pos, Color(GREEN.r, GREEN.g, GREEN.b, (160 + 95 * pulse) * k), 8000, C.BeaconWidth(EyePos():Distance(pos)))
end

function C.DrawWorld()
	local st = C.state
	if st.phase == "idle" then return end
	render.SetColorMaterial()
	local pulse = 0.6 + 0.4 * math.sin(RealTime() * 3)
	if st.startV then C.DrawStart(st.startV, st.yaw) end
	if st.finishV then C.DrawFinish(st.finishV, st.radius, pulse) end
	local me = C.Me(st)
	local a = API()
	local p = a and a.SkaterPos and a.SkaterPos()
	if st.finishV and p and me and me.racing and not me.time and (st.phase == "racing" or st.phase == "countdown") then
		C.DrawArrow(p + Vector(0, 0, 46 + math.sin(RealTime() * 4) * 2), st.finishV)
	end
end

function C.BeaconWidth(dist) return math.max(40, dist * 0.015) end

function C.ArrowShape(at, target)
	local dir = Vector(target.x - at.x, target.y - at.y, 0)
	if dir:LengthSqr() < 1 then return nil end
	dir = dir:GetNormalized()
	local side = Vector(-dir.y, dir.x, 0)
	local tail, neck, tip = at - dir * 14, at + dir * 4, at + dir * 16
	return {
		{ tail - side * 3, neck - side * 3, neck + side * 3, tail + side * 3 },
		{ neck - side * 9, tip, tip, neck + side * 9 },
	}, dir
end

local ARROW_FILL, ARROW_EDGE = Color(120, 255, 140, 230), Color(20, 80, 30, 255)
function C.DrawArrow(at, target)
	local quads = C.ArrowShape(at, target)
	if not quads then return end
	render.SetColorMaterial()
	for _, q in ipairs(quads) do
		render.DrawQuad(q[1], q[2], q[3], q[4], ARROW_FILL)
		render.DrawQuad(q[4], q[3], q[2], q[1], ARROW_FILL)
		for i = 1, 4 do render.DrawLine(q[i], q[i % 4 + 1], ARROW_EDGE, true) end
	end
	local dist = math.floor(at:Distance(target) * 0.0254)
	cam.Start3D2D(at + Vector(0, 0, 8), Angle(0, EyeAngles().y - 90, 90), 0.12)
		draw.SimpleTextOutlined(dist .. " m", "DermaLarge", 0, 0, ARROW_FILL, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 2, ARROW_EDGE)
	cam.End3D2D()
end
hook.Add("PostDrawTranslucentRenderables", "skategm_race", function(depth, sky) if not (depth or sky) then C.DrawWorld() end end)

---------------------------------------------------------------------------
-- on screen
---------------------------------------------------------------------------
surface.CreateFont("skategm_race_big", { font = "Roboto", size = math.max(24, math.floor(ScrH() * 0.08)), weight = 900 })
surface.CreateFont("skategm_race_mid", { font = "Roboto", size = math.max(16, math.floor(ScrH() * 0.03)), weight = 700 })
surface.CreateFont("skategm_race_small", { font = "Roboto", size = math.max(12, math.floor(ScrH() * 0.02)), weight = 600 })
local Text = SKATEGM_MODES.Text

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" then return end
	local me = C.Me(st)
	local since = now - (C.stateAt or now)
	if st.phase == "countdown" then
		Text(tostring(math.max(1, math.ceil((st.timeLeft or 0) - since))), "skategm_race_big", w / 2, h * 0.3, color_white)
	elseif st.phase == "racing" then
		if C.goAt and now - C.goAt < 1.2 then Text("GO!", "skategm_race_big", w / 2, h * 0.3, GREEN) end
		Text(RACE.Time((st.elapsed or 0) + since), "skategm_race_mid", w / 2, h * 0.04, color_white)
		Text("time left " .. RACE.Time((st.timeLeft or 0) - since), "skategm_race_small", w / 2, h * 0.04 + h * 0.035, Color(200, 200, 200))
		if me and me.time then Text("FINISHED #" .. me.place .. " - " .. RACE.Time(me.time), "skategm_race_mid", w / 2, h * 0.22, GREEN) end
	end
	if st.phase == "results" or st.phase == "racing" then
		-- standings: finishers by place, then who's still going
		local rows = {}
		for _, p in ipairs(st.players or {}) do rows[#rows + 1] = p end
		for _, g in ipairs(st.gone or {}) do rows[#rows + 1] = g end
		table.sort(rows, function(a, b)
			if a.place and b.place then return a.place < b.place end
			if a.place then return true end
			if b.place then return false end
			return (a.name or "") < (b.name or "")
		end)
		local y = h * 0.3
		if st.phase == "results" then Text("RESULTS", "skategm_race_mid", w - w * 0.12, y - h * 0.05, color_white) end
		for _, r in ipairs(rows) do
			local label = r.place and string.format("%d. %s  %s", r.place, r.name, RACE.Time(r.time)) or ("-  " .. (r.name or "?"))
			Text(label, "skategm_race_small", w - w * 0.12, y, r.place == 1 and GREEN or color_white)
			y = y + h * 0.028
		end
	end
end
hook.Add("HUDPaint", "skategm_race", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

---------------------------------------------------------------------------
-- console and spawn menu (Utilities > SkateGM > Game modes > Race)
---------------------------------------------------------------------------
local cvRadius = CreateClientConVar("skategm_race_radius", tostring(RACE.RADIUS_DEFAULT), true, false, "Finish size (units)", RACE.RADIUS_MIN, RACE.RADIUS_MAX)
local cvLimit = CreateClientConVar("skategm_race_limit", tostring(RACE.LIMIT_DEFAULT), true, false, "Race time limit (seconds)", RACE.LIMIT_MIN, RACE.LIMIT_MAX)
function C.Create() Send({ cmd = "create", radius = cvRadius:GetInt(), limit = cvLimit:GetInt() }) end
function C.PlaceStart()
	local p = Here()
	Send({ cmd = "start", pos = { p.x, p.y, p.z }, yaw = LocalPlayer():EyeAngles().y })
end
function C.PlaceFinish()
	local p = Here()
	Send({ cmd = "finish", pos = { p.x, p.y, p.z } })
end
function C.Settings() Send({ cmd = "settings", radius = cvRadius:GetInt(), limit = cvLimit:GetInt() }) end
concommand.Add("skategm_race_create", C.Create)
concommand.Add("skategm_race_join", function() Send({ cmd = "join" }) end)
concommand.Add("skategm_race_leave", function() Send({ cmd = "leave" }) end)
concommand.Add("skategm_race_start_here", C.PlaceStart)
concommand.Add("skategm_race_finish_here", C.PlaceFinish)
concommand.Add("skategm_race_go", function() Send({ cmd = "begin" }) end)
concommand.Add("skategm_race_stop", function() Send({ cmd = "stop" }) end)

RACE.mode:Host({
	useStart = false,
	description = "be first to the finish",
	about = "Everyone starts together. The first one to the finish line wins.",
	options = {
		{ key = "start", label = "Start", type = "object", help = "where everyone starts; the arrow is the way to go",
			draw = function(obj, alpha) C.DrawStart(obj.pos, obj.yaw + 180, alpha) end, summary = function() return "placed" end },
		{ key = "finish", label = "Finish", type = "object", rotate = false, draw = function(obj, alpha) C.DrawFinish(obj.pos, obj.scale, 1, alpha) end,
			scale = { label = "Size", min = RACE.RADIUS_MIN, max = RACE.RADIUS_MAX, step = 25, default = RACE.RADIUS_DEFAULT, format = function(v) return math.floor(v * 2) .. " across" end } },
		{ key = "limit", label = "Time limit", type = "number", min = RACE.LIMIT_MIN, max = RACE.LIMIT_MAX, step = 15, default = RACE.LIMIT_DEFAULT, format = function(v) return v .. " s" end },
	},
	start = function(v, mode)
		mode:SendSequence({
			{ cmd = "create", radius = v.finish.scale, limit = v.limit },
			{ cmd = "start", pos = SKATEGM_MODES.PosTable(v.start.pos), yaw = (v.start.yaw + 180) % 360 },
			{ cmd = "finish", pos = SKATEGM_MODES.PosTable(v.finish.pos) },
		})
	end,
})
