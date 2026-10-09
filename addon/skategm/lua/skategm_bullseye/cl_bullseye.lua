-- Bullseye, client: your jump (where the board first lands after real air
-- is sent; a bail sends nothing), watching everyone else's, the rings.
local BE = BULLSEYE
local C = { state = { phase = "idle" } }
BE.client = C

local API = SKATEGM_MODES.API
local function Send(t) BE.mode:Send(t) end
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) BE.mode:Say(text, bad) end
local Clock = SKATEGM_MODES.Clock

local ACTIVE = { prep = true, countdown = true, shot = true, finish = true, between = true }
local SHOOTING = { shot = true, finish = true }

function C.Me(st) return BE.mode:Me(st) end
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
	st.targetV = st.target and Vector(st.target[1], st.target[2], st.target[3]) or nil
	local me, a = C.Me(st), API()
	local mine, wasMine = C.IsMine(st), C.IsMine(prev)
	if a and a.SetHidden then a.SetHidden("bullseye", (ACTIVE[st.phase] and me ~= nil and not mine and not C.JustDone(st)) or false) end
	BE.mode:KeepApart(ACTIVE[st.phase] and me ~= nil)
	if st.phase == "prep" and mine and not (prev.phase == "prep" and wasMine) then
		C.prep = { teleported = false, readySent = false }
		if a then a.StartSkating() end
		Say("your jump: land it in the rings")
	end
	if st.phase == "shot" and mine and not (prev.phase == "shot" and wasMine) then
		if a and st.startV then a.TeleportTo(st.startV, st.yaw) end
		C.jump = { sent = false }
	end
	if not (SHOOTING[st.phase] and mine) then C.jump = nil end
	BE.mode:Spectate((ACTIVE[st.phase] and me ~= nil and not mine and not C.JustDone(st)) and SKATEGM_MODES.Others(st) or nil, { prefer = st.active })
	if st.phase == "between" and prev.phase ~= "between" and st.last and st.last.ring then
		if surface and surface.PlaySound then surface.PlaySound(st.last.ring == "gold" and "garrysmod/save_load4.wav" or "buttons/button14.wav") end
	end
end
BE.mode:OnState(function(st, now) C.OnState(st, now) end)

function C.BoardPos(a)
	local P = a.PoseOf and a.PoseOf(LocalPlayer())
	local p = (P and (P.SKATEBOARD_ROOT or P.HIPS)) or (a.SkaterPos and a.SkaterPos())
	return p
end

-- my jump: real air, then the first touch down on the board locks it in
-- a landing in the rings, from a jump that took off outside them
function C.CountsAsShot(st, from, to)
	if not (st.target and to) then return false end
	local outer = (st.width or BE.WIDTH_DEFAULT) * #BE.RINGS
	local t = st.target
	local function d(p) return math.sqrt((p.x - t[1]) ^ 2 + (p.y - t[2]) ^ 2) end
	return d(to) <= outer and (from == nil or d(from) > outer)
end

-- any part of me on something in the no-zone (not flying over it)
function C.InZone(st, a, state)
	if not (st.target and (st.zone or 0) > 0) then return false end
	if state:find("Air", 1, true) and not state:find("Biped", 1, true) then return false end
	local P = a.PoseOf and a.PoseOf(LocalPlayer())
	return BE.Touching(P, st.target, st.width or BE.WIDTH_DEFAULT, st.zone, state:find("Wipeout", 1, true) ~= nil)
end

function C.Track(st, a, now)
	local J = C.jump
	if not J or J.sent then return end
	local state = a.State and a.State() or ""
	if C.InZone(st, a, state) then
		J.sent = true
		if surface and surface.PlaySound then surface.PlaySound("buttons/button10.wav") end
		return Send({ cmd = "landed", nozone = true })
	end
	if state:find("Wipeout", 1, true) then
		J.sent = true
		return Send({ cmd = "landed", bailed = true })
	end
	local air = state:find("Air", 1, true) ~= nil and not state:find("Biped", 1, true)
	if air then
		if not J.airSince then
			J.airSince = now
			local from = C.BoardPos(a)
			J.from = from and Vector(from.x, from.y, from.z) or nil
		end
		return
	end
	if J.airSince then
		-- (only a jump into the rings from outside them counts: a drop-in, a
		-- curb or an ollie on the way there doesn't end the go)
		local p = C.BoardPos(a)
		if p and now - J.airSince >= BE.MIN_AIR and (not a.OnBoard or a.OnBoard()) and C.CountsAsShot(st, J.from, p) then
			J.sent = true
			if a.Freeze then a.Freeze(true, "bullseye") C.froze = true end
			return Send({ cmd = "landed", pos = { p.x, p.y, p.z } })
		end
		J.airSince, J.from = nil, nil
	end
	if st.phase == "finish" then
		J.sent = true
		Send({ cmd = "landed", bailed = true })
	end
end

function C.Think(now)
	local st, a = C.state, API()
	if not a or st.phase == "idle" then return end
	if C.froze and not (SHOOTING[st.phase] and C.IsMine(st)) then
		C.froze = nil
		if a.Freeze then a.Freeze(false, "bullseye") end
	end
	if not BE.mode:TurnPrep(C, st, a, now, st.startV, st.yaw) and SHOOTING[st.phase] and C.IsMine(st) then
		C.Track(st, a, now)
	end
end
hook.Add("Think", "skategm_bullseye", function() C.Think(RealTime()) end)

---------------------------------------------------------------------------
-- the rings: half-see-through, from gold in the middle to green outside
---------------------------------------------------------------------------
C.SEGMENTS = 64
local mat
-- the no-zone: a red band past the rings, hatched with dark red lines
function C.DrawZone(target, inner, zone, z)
	if not zone or zone <= 0 then return end
	SKATEGM_MODES.DrawNoZone(target, inner, inner + zone, z)
	render.SetMaterial(mat)
end

function C.DrawRings(target, width, zone)
	mat = mat or CreateMaterial("skategm_bullseye_ring", "UnlitGeneric", { ["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$translucent"] = 1, ["$nocull"] = 1 })
	render.SetMaterial(mat)
	local z = target.z + 2
	local n = C.SEGMENTS
	for i, ring in ipairs(BE.RINGS) do
		local inner, outer = (i - 1) * width, i * width
		local c = ring.color
		local alpha = i == 1 and 150 or 110
		mesh.Begin(MATERIAL_QUADS, n)
		for k = 0, n - 1 do
			local a0, a1 = k / n * math.pi * 2, (k + 1) / n * math.pi * 2
			local c0, s0, c1, s1 = math.cos(a0), math.sin(a0), math.cos(a1), math.sin(a1)
			for _, v in ipairs({ { c0 * inner, s0 * inner }, { c0 * outer, s0 * outer }, { c1 * outer, s1 * outer }, { c1 * inner, s1 * inner } }) do
				mesh.Position(Vector(target.x + v[1], target.y + v[2], z))
				mesh.Color(c[1], c[2], c[3], alpha)
				mesh.AdvanceVertex()
			end
		end
		mesh.End()
	end
	C.DrawZone(target, width * #BE.RINGS, zone, z)
end

function C.DrawWorld()
	local st = C.state
	if st.phase == "idle" or not st.targetV then return end
	C.DrawRings(st.targetV, st.width or BE.RingWidth(st.size), st.zone)
	render.SetColorMaterial()
	for _, s in ipairs(st.shots or {}) do
		local ring = BE.RINGS[1]
		for _, r in ipairs(BE.RINGS) do if r.points == s.points then ring = r end end
		local col = s.points > 0 and Color(ring.color[1], ring.color[2], ring.color[3]) or Color(200, 200, 200)
		render.DrawBox(Vector(s.x, s.y, s.z), angle_zero, Vector(-3, -3, 0), Vector(3, 3, 40), col)
	end
	if st.startV and (st.phase == "lobby" or st.phase == "prep" or st.phase == "countdown") then
		render.DrawBox(st.startV, angle_zero, Vector(-2, -2, 0), Vector(2, 2, 64), Color(255, 200, 40, 160))
	end
end
hook.Add("PostDrawTranslucentRenderables", "skategm_bullseye", function(depth, sky) if not (depth or sky) then C.DrawWorld() end end)

---------------------------------------------------------------------------
-- on screen
---------------------------------------------------------------------------
local FONTS = {
	skategm_be_big = { "Coolvetica", 0.06, 500 },
	skategm_be_mid = { "Coolvetica", 0.03, 500 },
	skategm_be_small = { "Roboto", 0.018, 700 },
}
local GOLD, GREY, RED = Color(255, 200, 40), Color(190, 190, 190), Color(235, 85, 95)
local function Text(t, font, x, y, col, ax) SKATEGM_MODES.Text(t, font, x, y, col, ax or TEXT_ALIGN_CENTER, 1) end

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" or st.phase == "lobby" then return end
	if not C.Me(st) then return end
	BE.mode:Fonts(FONTS)
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
	local cx, line = w / 2, h * 0.035
	local who = C.IsMine(st) and "YOUR JUMP" or (string.upper(C.NameOf(st, st.active)) .. "'S JUMP")
	if st.phase == "prep" then
		Text(C.NameOf(st, st.active) .. " is getting to the start...", "skategm_be_mid", cx, h * 0.08, GREY)
	elseif st.phase == "countdown" then
		Text(who, "skategm_be_mid", cx, h * 0.08, GOLD)
		Text(tostring(math.max(1, math.ceil(left))), "skategm_be_big", cx, h * 0.08 + line * 1.3, color_white)
	elseif SHOOTING[st.phase] then
		Text(who .. "   " .. (st.phase == "finish" and "land it!" or Clock(left)), "skategm_be_mid", cx, h * 0.08, (st.phase == "finish" or left <= 5) and RED or color_white)
		Text(string.format("round %d / %d", st.round or 1, st.rounds or 1), "skategm_be_small", cx, h * 0.08 + line, GREY)
		if C.IsMine(st) then Text((st.zone or 0) > 0 and "jump over the red no-zone into the rings: touch the red and the go's over" or "jump into the rings from outside them: only that landing counts", "skategm_be_small", cx, h * 0.08 + line * 1.8, GREY) end
	elseif st.phase == "between" and st.last then
		local l = st.last
		local text = l.points > 0 and string.format("%s: %s!  +%d", l.name, string.upper(l.ring or ""), l.points)
			or (l.how == "nozone" and (l.name .. " touched the no-zone: no points"))
			or (l.how == "bailed" and (l.name .. " bailed: no points") or (l.name .. ": missed"))
		Text(text, "skategm_be_mid", cx, h * 0.08, l.points > 0 and GOLD or RED)
	elseif st.phase == "results" and st.winners then
		local wn = st.winners.names or {}
		Text(#wn > 0 and (string.upper(table.concat(wn, " & ")) .. " WIN" .. (#wn == 1 and "S" or "")) or "NOBODY SCORED", "skategm_be_big", cx, h * 0.12, GOLD)
		Text((st.winners.points or 0) .. " points", "skategm_be_mid", cx, h * 0.12 + line * 2, color_white)
	end
	local rows = {}
	for _, p in ipairs(st.players or {}) do rows[#rows + 1] = p end
	table.sort(rows, function(x, y) return (x.total or 0) > (y.total or 0) end)
	local x, y = w * 0.98, h * 0.3
	for _, p in ipairs(rows) do
		Text(string.format("%s  %d", p.name, p.total or 0), "skategm_be_small", x, y, p.ent == st.active and GOLD or color_white, TEXT_ALIGN_RIGHT)
		y = y + line * 0.8
	end
end
hook.Add("HUDPaint", "skategm_bullseye", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

---------------------------------------------------------------------------
-- host menu
---------------------------------------------------------------------------
BE.mode:LobbyLines(function(st)
	return { string.format("%d round%s, %d s a jump, a target %d across", st.rounds or 1, st.rounds == 1 and "" or "s", st.time or BE.TIME_DEFAULT, math.floor((st.width or BE.WIDTH_DEFAULT) * #BE.RINGS * 2)),
		"gold 6, purple 3, blue 2, green 1" }
end)
BE.mode:Host({
	description = "land closest to the middle",
	about = "Take turns launching from the start toward a target on the ground. Wherever you first land on your board is your score, with more points closer to the middle. Touch the red zone around the edge and the run doesn't count.",
	options = {
		{ key = "target", label = "Target", type = "object", rotate = false, draw = function(obj) C.DrawRings(obj.pos, obj.scale or BE.WIDTH_DEFAULT, obj.zone or BE.ZONE_DEFAULT) end,
			scale = { label = "Size", min = BE.WIDTH_MIN, max = BE.WIDTH_MAX, step = 8, default = BE.WIDTH_DEFAULT, format = function(v) return math.floor(v * #BE.RINGS * 2) .. " across" end },
			sizes = { { key = "zone", label = "No-zone", min = BE.ZONE_MIN, max = BE.ZONE_MAX, step = 16, default = BE.ZONE_DEFAULT, format = function(v) return v <= 0 and "off" or (v .. " wide") end } } },
		{ key = "rounds", label = "Rounds", type = "number", min = BE.ROUNDS_MIN, max = BE.ROUNDS_MAX, step = 1, default = BE.ROUNDS_DEFAULT },
		{ key = "time", label = "Time for a jump", type = "number", min = BE.TIME_MIN, max = BE.TIME_MAX, step = 5, default = BE.TIME_DEFAULT, format = function(v) return v .. " s" end },
	},
	start = function(v, mode)
		local t = v.target and v.target.pos
		mode:Send({ cmd = "create", target = t and { t.x, t.y, t.z } or nil, width = v.target and v.target.scale, zone = v.target and v.target.zone, rounds = v.rounds, time = v.time, canSkate = CanSkate() })
	end,
})
