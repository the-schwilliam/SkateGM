-- Basketboard, client: my turn (the loose board and my body watched against
-- the rim: either down through it scores), watching everyone else's, the
-- ghost hoop.
local BB = BASKETBOARD
local C = { state = { phase = "idle" } }
BB.client = C

local API = SKATEGM_MODES.API
local function Send(t) BB.mode:Send(t) end
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) BB.mode:Say(text, bad) end
local Clock = SKATEGM_MODES.Clock

local ACTIVE = { prep = true, countdown = true, turn = true, finish = true, between = true }
local TURN = { turn = true, finish = true }
C.JUMP = 200

function C.Me(st) return BB.mode:Me(st) end
function C.MyEnt() return LocalPlayer():EntIndex() end
function C.IsMine(st) return st.active ~= nil and st.active ~= 0 and st.active == C.MyEnt() end
function C.NameOf(st, ent)
	for _, p in ipairs(st.players or {}) do if p.ent == ent then return p.name end end
	return "?"
end

C.JustDone = SKATEGM_MODES.JustDone

function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	st.startV = st.start and Vector(st.start[1], st.start[2], st.start[3]) or nil
	st.hoopV = st.hoop and Vector(st.hoop[1], st.hoop[2], st.hoop[3]) or nil
	local me, a = C.Me(st), API()
	local mine, wasMine = C.IsMine(st), C.IsMine(prev)
	if a and a.SetHidden then a.SetHidden("basketboard", (ACTIVE[st.phase] and me ~= nil and not mine and not C.JustDone(st)) or false) end
	-- (everyone starts on the same spot: nobody collides, and only who I
	-- watch is drawn while their hidden flags reach everyone)
	BB.mode:KeepApart(ACTIVE[st.phase] and me ~= nil)
	if st.phase == "prep" and mine and not (prev.phase == "prep" and wasMine) then
		C.prep = { teleported = false, readySent = false }
		if a then a.StartSkating() end
		Say("your turn: one dismount or bail, get the board or yourself through the hoop")
	end
	if st.phase == "turn" and mine and not (prev.phase == "turn" and wasMine) then
		if a and st.startV then a.TeleportTo(st.startV, st.yaw) end
		C.shot = { sent = false }
	end
	if not (TURN[st.phase] and mine) then C.shot = nil end
	BB.mode:Spectate((ACTIVE[st.phase] and me ~= nil and not mine and not C.JustDone(st)) and SKATEGM_MODES.Others(st) or nil, { prefer = st.active })
	if st.phase == "between" and prev.phase ~= "between" and st.last and surface and surface.PlaySound then
		surface.PlaySound((st.last.points or 0) > 0 and "garrysmod/save_load4.wav" or "buttons/button10.wav")
	end
end
BB.mode:OnState(function(st, now) C.OnState(st, now) end)

local function V3(v) return { v.x, v.y, v.z } end

function C.Released(a)
	local state = a.State and a.State() or ""
	if state:find("Wipeout", 1, true) or state:find("Biped", 1, true) then return true end
	return a.OnBoard ~= nil and a.OnBoard() == false
end

function C.Finish(how)
	C.shot.sent = true
	Send({ cmd = "result", how = how })
end

-- any part of me on something in the no-zone (not flying over it)
function C.InZone(st, a, board, hips)
	if not (st.hoop and (st.zone or 0) > 0) then return false end
	local state = a.State and a.State() or ""
	if state:find("Air", 1, true) and not state:find("Biped", 1, true) then return false end
	local ground = { st.hoop[1], st.hoop[2], st.ground or st.hoop[3] }
	local P = a.PoseOf and a.PoseOf(LocalPlayer())
	return (st.zone or 0) > 0 and SKATEGM_MODES.TouchingNoZone(P, ground, 0, st.zone, state:find("Wipeout", 1, true) ~= nil) or false
end

-- my turn: the board, or me, down through the rim scores
function C.Track(st, a, now)
	local T = C.shot
	if not T or T.sent or not st.hoop then return end
	local P = a.PoseOf and a.PoseOf(LocalPlayer())
	local board, hips = P and P.SKATEBOARD_ROOT, P and P.HIPS
	if not (board and hips) then return end
	local r = st.radius or BB.RADIUS_DEFAULT
	if C.InZone(st, a, board, hips) then
		if surface and surface.PlaySound then surface.PlaySound("buttons/button10.wav") end
		return C.Finish("nozone")
	end
	if T.board and T.hips and board:Distance(T.board) < C.JUMP and hips:Distance(T.hips) < C.JUMP then
		local how = (BB.Through(V3(T.board), V3(board), st.hoop, r) and "basket") or (BB.Through(V3(T.hips), V3(hips), st.hoop, r + BB.BODY_MARGIN) and "player") or nil
		if how then
			if surface and surface.PlaySound then surface.PlaySound("garrysmod/balloon_pop_cute.wav") end
			return C.Finish(how)
		end
	end
	T.board, T.hips = board, hips
	if not T.released and C.Released(a) then T.released = now end
	if T.released and now >= T.released + BB.WATCH then C.Finish("miss") end
end

function C.Think(now)
	C.HookCollision()
	local st, a = C.state, API()
	if not a or st.phase == "idle" then return end
	if not BB.mode:TurnPrep(C, st, a, now, st.startV, st.yaw) and TURN[st.phase] and C.IsMine(st) then
		C.Track(st, a, now)
	end
end
hook.Add("Think", "skategm_basketboard", function() C.Think(RealTime()) end)

---------------------------------------------------------------------------
-- the ghost hoop: pole, backboard, rim and net, half see-through
---------------------------------------------------------------------------
C.SEGMENTS = 32
local GHOST, RIM, NET = Color(235, 240, 255), Color(255, 130, 40), Color(255, 255, 255)
local mat
local function Quad(a, b, c, d, col, alpha)
	for _, v in ipairs({ a, b, c, d }) do
		mesh.Position(v)
		mesh.Color(col.r, col.g, col.b, alpha)
		mesh.AdvanceVertex()
	end
end

function C.HoopFrame(st)
	local h = st.hoopV
	local f = st.facing and Angle(0, st.facing, 0):Forward() or (st.startV and Vector(st.startV.x - h.x, st.startV.y - h.y, 0)) or Vector(1, 0, 0)
	f = Vector(f.x, f.y, 0)
	if f:LengthSqr() < 1 then f = Vector(1, 0, 0) end
	f:Normalize()
	return h, f, Vector(-f.y, f.x, 0)
end

function C.DrawHoop(st, pulse)
	mat = mat or CreateMaterial("skategm_basketboard_ghost", "UnlitGeneric", { ["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$translucent"] = 1, ["$nocull"] = 1 })
	local h, f, side = C.HoopFrame(st)
	local r = st.radius or BB.RADIUS_DEFAULT
	local up = Vector(0, 0, 1)
	local bw = math.max(72, r * 2.4)
	local bh = bw * 0.6
	local back = h - f * (r + 6)
	local bottom = back - up * 8
	local ground = st.ground or (h.z - (st.height or BB.HEIGHT_DEFAULT))
	local poleAt = back - f * 16
	render.SetMaterial(mat)
	mesh.Begin(MATERIAL_QUADS, 7 + C.SEGMENTS * 3)
	Quad(bottom - side * bw / 2, bottom + side * bw / 2, bottom + side * bw / 2 + up * bh, bottom - side * bw / 2 + up * bh, GHOST, 55 * pulse)
	local sq = bottom + up * 6
	Quad(sq - side * r * 0.7, sq + side * r * 0.7, sq + side * r * 0.7 + up * r * 0.9, sq - side * r * 0.7 + up * r * 0.9, RIM, 90 * pulse)
	local top = bottom.z + bh * 0.5 - ground
	local c = Vector(poleAt.x, poleAt.y, ground)
	local corners = { c + side * 2.5 + f * 2.5, c - side * 2.5 + f * 2.5, c - side * 2.5 - f * 2.5, c + side * 2.5 - f * 2.5 }
	for k = 1, 4 do
		local a, b = corners[k], corners[k % 4 + 1]
		Quad(a, b, b + up * top, a + up * top, GHOST, 70 * pulse)
	end
	local arm = Vector(poleAt.x, poleAt.y, bottom.z + bh * 0.4)
	Quad(arm - up * 2, arm + up * 2, arm + up * 2 + f * 16, arm - up * 2 + f * 16, GHOST, 70 * pulse)
	local n, drop, low = C.SEGMENTS, r * 1.1, r * 0.55
	for k = 0, n - 1 do
		local a0, a1 = k / n * math.pi * 2, (k + 1) / n * math.pi * 2
		local c0 = h + Vector(math.cos(a0), math.sin(a0), 0) * r
		local c1 = h + Vector(math.cos(a1), math.sin(a1), 0) * r
		local o0 = h + Vector(math.cos(a0), math.sin(a0), 0) * (r + 2.5)
		local o1 = h + Vector(math.cos(a1), math.sin(a1), 0) * (r + 2.5)
		Quad(c0, c1, o1, o0, RIM, 230 * pulse)
		Quad(c0 - up * 2, c1 - up * 2, c1, c0, RIM, 200 * pulse)
		local l0 = h - up * drop + Vector(math.cos(a0), math.sin(a0), 0) * low
		local l1 = h - up * drop + Vector(math.cos(a1), math.sin(a1), 0) * low
		Quad(c0, c1, l1, l0, NET, 28 * pulse)
	end
	mesh.End()
	for k = 0, n - 1, 2 do
		for _, d in ipairs({ -2, 2 }) do
			local a0, a1 = k / n * math.pi * 2, (k + d) / n * math.pi * 2
			local top = h + Vector(math.cos(a0), math.sin(a0), 0) * r
			local bot = h - up * drop + Vector(math.cos(a1), math.sin(a1), 0) * low
			render.DrawLine(top, bot, Color(NET.r, NET.g, NET.b, 150 * pulse), true)
		end
	end
end

---------------------------------------------------------------------------
-- the hoop is solid to the skater: backboard, pole, arm and the rim (a ring
-- of thin segments; the net stays soft). Built in the hoop's own frame (+x
-- toward the open side, z up, the rim's centre at 0) and fed to the engine
-- like any moving thing, for as long as the game's being played
---------------------------------------------------------------------------
C.RIM_SEGMENTS, C.RIM_THICK = 16, 1.5

-- a box's twelve triangles, facing out: centre c, right-handed axes ax ay az, half sizes
function C.Box(out, c, ax, ay, az, hx, hy, hz)
	local axes, half = { ax, ay, az }, { hx, hy, hz }
	for i = 1, 3 do
		local j, k = i % 3 + 1, (i + 1) % 3 + 1
		for _, sgn in ipairs({ 1, -1 }) do
			local n = axes[i] * sgn
			local u, v, hu, hv = axes[j], axes[k], half[j], half[k]
			if sgn < 0 then u, v, hu, hv = axes[k], axes[j], half[k], half[j] end
			local f = c + n * half[i]
			local q = { f - u * hu - v * hv, f + u * hu - v * hv, f + u * hu + v * hv, f - u * hu + v * hv }
			for _, idx in ipairs({ 1, 2, 3, 1, 3, 4 }) do
				out[#out + 1] = q[idx].x
				out[#out + 1] = q[idx].y
				out[#out + 1] = q[idx].z
			end
		end
	end
end

function C.HoopMesh(r, lift)
	local out = {}
	local X, Y, Z = Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1)
	local bw = math.max(72, r * 2.4)
	local bh = bw * 0.6
	local back = -(r + 6)
	C.Box(out, Vector(back, 0, -8 + bh / 2), X, Y, Z, 1.5, bw / 2, bh / 2)
	local pole = back - 16
	local top, bottom = -8 + bh * 0.5, -lift
	C.Box(out, Vector(pole, 0, (top + bottom) / 2), X, Y, Z, 2.5, 2.5, (top - bottom) / 2)
	C.Box(out, Vector(back - 8, 0, -8 + bh * 0.4), X, Y, Z, 8, 2, 2)
	local n = C.RIM_SEGMENTS
	local len = 2 * math.pi * r / n
	for k = 0, n - 1 do
		local a = (k + 0.5) / n * math.pi * 2
		local radial, tangent = Vector(math.cos(a), math.sin(a), 0), Vector(-math.sin(a), math.cos(a), 0)
		C.Box(out, radial * (r + C.RIM_THICK), radial, tangent, Z, C.RIM_THICK, len / 2 + 0.5, 1)
	end
	return { out }
end

function C.HoopModel(st) return string.format("skategm_hoop:%d:%d", math.floor(st.radius or BB.RADIUS_DEFAULT), math.floor(st.height or BB.LIFT_DEFAULT)) end

function C.HoopShape(name)
	local r, lift = tostring(name):match("^skategm_hoop:(%d+):(%d+)$")
	if not r then return nil end
	return C.HoopMesh(tonumber(r), tonumber(lift)), true, "Basketboard's hoop"
end

function C.HoopFeed(centre, list, now)
	local st = C.state
	if not (st and ACTIVE[st.phase] and st.hoopV and C.Me(st)) then return end
	local h = st.hoopV
	local name = C.HoopModel(st)
	if skategm and skategm.DefineModel and (C.defined ~= name or now - (C.definedAt or -100) > 10) then
		C.defined, C.definedAt = name, now
		skategm.DefineModel(name, C.HoopShape(name), 1)
	end
	list[#list + 1] = { name, h.x, h.y, h.z, 0, st.facing or 0, 0 }
end

-- (the skating add-on may load after this file: hooked up once it's there)
function C.HookCollision()
	local S = SkateGM
	if C.hooked or not (S and S.HullProviders) then return end
	C.hooked = true
	S.HullProviders[#S.HullProviders + 1] = C.HoopShape
	S.MoverFeeds = S.MoverFeeds or {}
	S.MoverFeeds[#S.MoverFeeds + 1] = C.HoopFeed
end

-- the hoop the placer shows (obj = { pos on the ground, yaw it faces, scale = rim radius, lift = rim height })
function C.DrawHoopObject(obj, alpha)
	local lift = obj.lift or BB.LIFT_DEFAULT
	SKATEGM_MODES.DrawNoZone(obj.pos, 0, obj.zone or BB.ZONE_DEFAULT, obj.pos.z + 1)
	C.DrawHoop({ hoopV = obj.pos + Vector(0, 0, lift), facing = obj.yaw, radius = obj.scale or BB.RADIUS_DEFAULT, ground = obj.pos.z, height = lift }, alpha or 1)
end

function C.DrawWorld()
	local st = C.state
	if st.phase == "idle" or not st.hoopV then return end
	local pulse = 0.8 + 0.2 * math.sin(RealTime() * 3)
	if (st.zone or 0) > 0 then SKATEGM_MODES.DrawNoZone(Vector(st.hoopV.x, st.hoopV.y, 0), 0, st.zone, (st.ground or st.hoopV.z) + 1) end
	C.DrawHoop(st, pulse)
	if st.startV and (st.phase == "lobby" or st.phase == "prep" or st.phase == "countdown") then
		render.SetColorMaterial()
		render.DrawBox(st.startV, angle_zero, Vector(-2, -2, 0), Vector(2, 2, 64), Color(255, 130, 40, 160))
	end
end
hook.Add("PostDrawTranslucentRenderables", "skategm_basketboard", function(depth, sky) if not (depth or sky) then C.DrawWorld() end end)

---------------------------------------------------------------------------
-- on screen
---------------------------------------------------------------------------
local FONTS = {
	skategm_bkb_big = { "Coolvetica", 0.06, 500 },
	skategm_bkb_mid = { "Coolvetica", 0.03, 500 },
	skategm_bkb_small = { "Roboto", 0.018, 700 },
}
local ORANGE, GREY, RED, GREEN = Color(255, 130, 40), Color(190, 190, 190), Color(235, 85, 95), Color(110, 230, 120)
local function Text(t, font, x, y, col, ax) SKATEGM_MODES.Text(t, font, x, y, col, ax or TEXT_ALIGN_CENTER, 1) end

local OUTCOME = {
	basket = function(l) return l.name .. ": BASKET!  +1", true end,
	player = function(l) return l.name .. " DUNKED THEMSELVES!  +1", true end,
	nozone = function(l) return l.name .. " touched the no-zone: no point" end,
	miss = function(l) return l.name .. ": missed" end,
	skipped = function(l) return l.name .. " missed their turn" end,
	left = function(l) return l.name .. " left" end,
}

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" or st.phase == "lobby" then return end
	if not C.Me(st) then return end
	BB.mode:Fonts(FONTS)
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
	local cx, line = w / 2, h * 0.035
	local who = C.IsMine(st) and "YOUR TURN" or (string.upper(C.NameOf(st, st.active)) .. "'S TURN")
	if st.hoopV then
		local r = st.radius or BB.RADIUS_DEFAULT
		local s = (st.hoopV + Vector(0, 0, math.max(72, r * 2.4) * 0.6 + 4)):ToScreen()
		if s.visible then Text("HOOP", "skategm_bkb_small", s.x, s.y, ORANGE) end
	end
	if st.phase == "prep" then
		Text(C.NameOf(st, st.active) .. " is getting to the start...", "skategm_bkb_mid", cx, h * 0.08, GREY)
	elseif st.phase == "countdown" then
		Text(who, "skategm_bkb_mid", cx, h * 0.08, ORANGE)
		Text(tostring(math.max(1, math.ceil(left))), "skategm_bkb_big", cx, h * 0.08 + line * 1.3, color_white)
	elseif TURN[st.phase] then
		Text(who .. "   " .. (st.phase == "finish" and "let it go!" or Clock(left)), "skategm_bkb_mid", cx, h * 0.08, (st.phase == "finish" or left <= 5) and RED or color_white)
		Text(string.format("round %d / %d", st.round or 1, st.rounds or 1), "skategm_bkb_small", cx, h * 0.08 + line, GREY)
		local T = C.IsMine(st) and C.shot
		if T and not T.released then
			local hint = "one dismount (Y) or bail: then the board flies on its own"
			Text(PAD and PAD.T and PAD.T(hint) or hint, "skategm_bkb_small", cx, h * 0.08 + line * 2, GREY)
		end
	elseif st.phase == "between" and st.last then
		local fn = OUTCOME[st.last.how]
		local text, good = st.last.name .. ": " .. tostring(st.last.how or "out of time"), false
		if fn then text, good = fn(st.last) end
		Text(text, "skategm_bkb_mid", cx, h * 0.08, good and GREEN or RED)
	elseif st.phase == "results" and st.winners then
		local wn = st.winners.names or {}
		Text(#wn > 0 and (string.upper(table.concat(wn, " & ")) .. " WIN" .. (#wn == 1 and "S" or "")) or "NOBODY SCORED", "skategm_bkb_big", cx, h * 0.12, ORANGE)
		Text((st.winners.points or 0) .. " basket" .. (st.winners.points == 1 and "" or "s"), "skategm_bkb_mid", cx, h * 0.12 + line * 2, color_white)
	end
	local rows = {}
	for _, p in ipairs(st.players or {}) do rows[#rows + 1] = p end
	table.sort(rows, function(x, y) return (x.total or 0) > (y.total or 0) end)
	local x, y = w * 0.98, h * 0.3
	for _, p in ipairs(rows) do
		Text(string.format("%s  %d", p.name, p.total or 0), "skategm_bkb_small", x, y, p.ent == st.active and ORANGE or color_white, TEXT_ALIGN_RIGHT)
		y = y + line * 0.8
	end
end
hook.Add("HUDPaint", "skategm_basketboard", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

---------------------------------------------------------------------------
-- host menu
---------------------------------------------------------------------------

BB.mode:LobbyLines(function(st)
	return { string.format("%d round%s, %d s a turn, a hoop %d across", st.rounds or 1, st.rounds == 1 and "" or "s", st.time or BB.TIME_DEFAULT, math.floor((st.radius or BB.RADIUS_DEFAULT) * 2)),
		"the board or you down through the hoop: 1 point", (st.zone or 0) > 0 and "touch the red no-zone under it and the turn's over" or nil }
end)
BB.mode:Host({
	description = "get through the hoop",
	about = "The host puts a hoop somewhere. Take turns trying to get your board, or yourself, through it. You get one shot per turn. The most baskets wins.",
	options = {
		{ key = "hoop", label = "Hoop", type = "object", draw = function(obj, alpha) C.DrawHoopObject(obj, alpha) end,
			scale = { label = "Size", min = BB.RADIUS_MIN, max = BB.RADIUS_MAX, step = 4, default = BB.RADIUS_DEFAULT, format = function(v) return math.floor(v * 2) .. " across" end },
			lift = { label = "Height", min = BB.LIFT_MIN, max = BB.LIFT_MAX, step = 8, default = BB.LIFT_DEFAULT, format = function(v) return v .. " up" end },
			sizes = { { key = "zone", label = "No-zone", min = BB.ZONE_MIN, max = BB.ZONE_MAX, step = 16, default = BB.ZONE_DEFAULT, format = function(v) return v <= 0 and "off" or (math.floor(v * 2) .. " across") end } } },
		{ key = "rounds", label = "Rounds", type = "number", min = BB.ROUNDS_MIN, max = BB.ROUNDS_MAX, step = 1, default = BB.ROUNDS_DEFAULT },
		{ key = "time", label = "Time a turn", type = "number", min = BB.TIME_MIN, max = BB.TIME_MAX, step = 5, default = BB.TIME_DEFAULT, format = function(v) return v .. " s" end },
	},
	start = function(v, mode)
		local h = v.hoop
		mode:Send({ cmd = "create", hoop = h and { pos = { h.pos.x, h.pos.y, h.pos.z }, yaw = h.yaw, scale = h.scale, lift = h.lift, zone = h.zone } or nil, rounds = v.rounds, time = v.time, canSkate = CanSkate() })
	end,
})
