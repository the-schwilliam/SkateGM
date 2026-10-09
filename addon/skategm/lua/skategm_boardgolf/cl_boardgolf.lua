-- Board Golf, client: my shot (the shot clock; at its end the
-- board is let go as a physics prop and I'm out of the picture), watching
-- the others, the camera on the ball, the cup, the flag and everyone's lie.
local BG = BOARDGOLF
local C = { state = { phase = "idle" }, trail = {} }
BG.client = C

local API = SKATEGM_MODES.API
local function Send(t) BG.mode:Send(t) end
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) BG.mode:Say(text, bad) end
local GREEN, GREY, RED, GOLD = Color(110, 210, 110), Color(190, 190, 190), Color(235, 85, 95), Color(255, 210, 90)
local ACTIVE = { prep = true, countdown = true, shot = true, roll = true, between = true }
C.TRAIL = 0.12

function C.Me(st) return BG.mode:Me(st) end
function C.MyEnt() return LocalPlayer():EntIndex() end
function C.IsMine(st) return st.active ~= nil and st.active ~= 0 and st.active == C.MyEnt() end
function C.NameOf(st, ent)
	for _, p in ipairs(st.players or {}) do if p.ent == ent then return p.name end end
	return "?"
end
function C.MyLie(st)
	local me = C.Me(st)
	return me and me.lie or st.tee
end

local function V(t) return Vector(t[1], t[2], t[3]) end

function C.Watch(st)
	local me = C.Me(st)
	BG.mode:Spectate((ACTIVE[st.phase] and me ~= nil and me.playing and not C.IsMine(st)) and SKATEGM_MODES.Others(st, function(p) return p.playing end) or nil, { prefer = st.active })
end

-- out of the picture while my board is the ball: unseen, can't be bumped, still
function C.Gone(on)
	local a = API()
	if not a or (on or false) == (C.gone or false) then return end
	C.gone = on or nil
	if a.SetHidden then a.SetHidden("boardgolf", on) end
	if a.SetPlayerCollision then if on then a.SetPlayerCollision(false, "boardgolf_gone") else a.SetPlayerCollision(nil, "boardgolf_gone") end end
	if a.Freeze then a.Freeze(on, "boardgolf") end
end

function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	BG.mode:KeepApart((ACTIVE[st.phase] or st.phase == "flyover") and C.Me(st) ~= nil)
	local me, a = C.Me(st), API()
	local mine, wasMine = C.IsMine(st), C.IsMine(prev)
	if st.phase == "prep" and mine and not (prev.phase == "prep" and wasMine) then
		C.Gone(false)
		C.prep = { teleported = false, readySent = false }
		if a then a.StartSkating() end
		Say(me and (me.strokes or 0) > 0 and "your shot: from where your board stopped" or "your shot: off the tee")
	end
	if st.phase == "shot" and mine and not (prev.phase == "shot" and wasMine) then
		C.stroke = { start = now }
		C.trail = {}
	end
	if not (st.phase == "shot" and mine) then C.stroke = nil end
	if not ACTIVE[st.phase] then C.Gone(false) end
	if not C.boardCam then C.Watch(st) end
	if st.phase == "between" and prev.phase ~= "between" and st.last and surface and surface.PlaySound then
		surface.PlaySound(st.last.result == "holed" and "garrysmod/save_load4.wav" or "buttons/button15.wav")
	end
end
BG.mode:OnState(function(st, now) C.OnState(st, now) end)

-- the board as it is now: where, which way, how fast (from its recent path)
function C.BoardNow(a, now)
	local P = a.PoseOf and a.PoseOf(LocalPlayer())
	if not (P and P.SKATEBOARD_ROOT and P.TRUCK_FRONT and P.TRUCK_BACK and P.RIGHT_WHEELFRONT and P.LEFT_WHEELFRONT and P.RIGHT_WHEELBACK and P.LEFT_WHEELBACK) then return nil end
	local pos = P.SKATEBOARD_ROOT
	local fwd = (P.TRUCK_FRONT - P.TRUCK_BACK):GetNormalized()
	local right = ((P.RIGHT_WHEELFRONT + P.RIGHT_WHEELBACK) - (P.LEFT_WHEELFRONT + P.LEFT_WHEELBACK)):GetNormalized()
	local up = right:Cross(fwd):GetNormalized()
	local ang = fwd:AngleEx(up)
	local vel = Vector(0, 0, 0)
	local old = C.trail[1]
	if old and now - old.t > 0.02 then vel = (pos - old.pos) / (now - old.t) end
	return { pos = pos, ang = ang, vel = vel }
end

function C.Remember(a, now)
	local P = a.PoseOf and a.PoseOf(LocalPlayer())
	local pos = P and P.SKATEBOARD_ROOT
	if not pos then return end
	C.trail[#C.trail + 1] = { t = now, pos = Vector(pos.x, pos.y, pos.z) }
	while #C.trail > 1 and now - C.trail[1].t > C.TRAIL do table.remove(C.trail, 1) end
end

-- my shot: ride; when the clock runs out the board goes on alone
function C.Track(st, a, now)
	local T = C.stroke
	if not T or T.sent then return end
	C.Remember(a, now)
	if now - T.start < (st.shotTime or BG.SHOT_DEFAULT) then return end
	local b = C.BoardNow(a, now)
	if not b then return end
	T.sent = true
	Send({ cmd = "release", pos = { b.pos.x, b.pos.y, b.pos.z }, ang = { b.ang.p, b.ang.y, b.ang.r }, vel = { b.vel.x, b.vel.y, b.vel.z } })
	C.Gone(true)
end

---------------------------------------------------------------------------
-- the camera on the ball: everyone follows the rolling board
---------------------------------------------------------------------------
function C.Ball(st) local e = st.board and Entity(st.board) return IsValid(e) and e or nil end

function C.WantBoardCam(st)
	local me = C.Me(st)
	if not (me and me.playing) then return false end
	if st.phase == "roll" then return C.Ball(st) ~= nil end
	return st.phase == "between" and C.boardCam ~= nil
end

function C.BoardView(fov)
	local cam = C.boardCam
	local ball = cam and C.Ball(C.state)
	if not ball then return cam and cam.pos and { origin = cam.pos, angles = cam.ang, fov = fov } or nil end
	local board = ball:GetPos()
	if cam.last then
		local moved = board - cam.last
		moved.z = 0
		if moved:LengthSqr() > 0.04 then cam.dir = LerpVector(0.06, cam.dir or moved:GetNormalized(), moved:GetNormalized()) end
	end
	cam.last = Vector(board.x, board.y, board.z)
	local dir = cam.dir or ball:GetForward()
	dir = Vector(dir.x, dir.y, 0)
	if dir:LengthSqr() < 0.01 then dir = Vector(1, 0, 0) end
	local want = board - dir:GetNormalized() * 95 + Vector(0, 0, 45)
	cam.pos = cam.pos and LerpVector(0.1, cam.pos, want) or want
	cam.ang = (board - cam.pos):Angle()
	return { origin = cam.pos, angles = cam.ang, fov = fov }
end

function C.BoardCam(st, a)
	local want = C.WantBoardCam(st)
	if want and not C.boardCam then
		C.boardCam = {}
		BG.mode:Spectate(nil)
		if a.Freeze then a.Freeze(true, "boardgolf_cam") end
		if a.SetView then a.SetView(function(_, _, fov) return C.BoardView(fov) end, "boardgolf_cam") end
		if a.SetHidden then a.SetHidden("view", false) end
	elseif not want and C.boardCam then
		C.boardCam = nil
		SKATEGM_MODES.GiveViewBack("boardgolf_cam")
		if a.Freeze then a.Freeze(false, "boardgolf_cam") end
		C.Watch(st)
	end
end

---------------------------------------------------------------------------
-- the flyover: before the first shot, a camera from the tee to the cup,
-- looking at the cup the whole way. Its path:
--   1. points along the straight line, each knowing its room: the floor
--      under it (plus a clearance) and the ceiling over it
--   2. a rubber band over that floor: heights averaged with their
--      neighbours again and again, pushed back up wherever they'd go under
--      the clearance - straight runs from hilltop to hilltop, no dip into
--      every hollow and no bump over every slope
--   3. stretches that still don't see the next are lifted; where lifting
--      can't help (a wall up to the ceiling) they swing out sideways, the
--      least they need to
--   4. smoothed again in all three directions, each point moved only while
--      the stretches either side of it stay clear and it keeps its room
--   5. a spline through it, cut into even steps: an even pace, eased at
--      both ends (a stretch of spline that would clip something is flown
--      straight instead)
---------------------------------------------------------------------------
C.FLY_CLEAR, C.FLY_CEILING_GAP, C.FLY_STEP = 150, 40, 128
C.FLY_LIFT, C.FLY_TRIES, C.FLY_SIDE, C.FLY_SIDE_STEPS = 48, 24, 96, 16
C.FLY_BAND, C.FLY_SMOOTH, C.FLY_SAMPLES, C.FLY_SPLINE = 80, 30, 240, 8

local function Trace(a, b)
	local tr = util.TraceLine({ start = a, endpos = b, mask = MASK_SOLID_BRUSHONLY })
	return tr and tr.Hit and tr.HitPos or nil
end

local function Solid(p) return util.PointContents and bit.band(util.PointContents(p), CONTENTS_SOLID) ~= 0 end

-- heights a point at (x, y) can have: above the ground under it, below the ceiling over it
function C.FlyRoom(p)
	local q = Vector(p.x, p.y, p.z)
	for _ = 1, 40 do
		if not Solid(q) then break end
		q.z = q.z + 64
	end
	local floor = Trace(q, q - Vector(0, 0, 8000))
	local ceiling = Trace(q, q + Vector(0, 0, 8000))
	return floor and floor.z or (q.z - 8000), ceiling and ceiling.z or (q.z + 8000)
end

local function Room(p)
	local floor, ceiling = C.FlyRoom(p)
	local top = ceiling - C.FLY_CEILING_GAP
	return { low = math.min(floor + C.FLY_CLEAR, top), top = top }
end

-- steps 1-4: the path's points
function C.FlyRaw(tee, cup)
	local flat = Vector(cup.x - tee.x, cup.y - tee.y, 0)
	local dist = flat:Length()
	local dir = dist > 1 and flat / dist or Vector(1, 0, 0)
	local a = tee - dir * 120 + Vector(0, 0, 110)
	local b = cup - dir * 260 + Vector(0, 0, 180)
	local n = math.max(6, math.min(64, math.floor((a - b):Length() / C.FLY_STEP)))
	local pts, room = {}, {}
	for i = 0, n do
		local p = LerpVector(i / n, a, b)
		local r = Room(p)
		p.z = math.min(math.max(p.z, r.low), r.top)
		pts[#pts + 1], room[#room + 1] = p, r
	end
	for _ = 1, C.FLY_BAND do
		for i = 2, #pts - 1 do
			local z = (pts[i - 1].z + pts[i + 1].z) / 2
			pts[i].z = math.min(math.max(z, room[i].low), room[i].top)
		end
	end
	local function Blocked(k) return k >= 1 and k < #pts and Trace(pts[k], pts[k + 1]) ~= nil end
	local function Unblock()
		for _ = 1, C.FLY_TRIES do
			local clear = true
			for i = 1, #pts - 1 do
				if Blocked(i) then
					clear = false
					for _, k in ipairs({ i, i + 1 }) do pts[k].z = math.min(pts[k].z + C.FLY_LIFT, room[k].top) end
				end
			end
			if clear then return end
		end
	end
	local side = Vector(-dir.y, dir.x, 0)
	local function Detour()
		local i = 1
		while i < #pts do
			if Blocked(i) then
				local j = i
				while j + 1 < #pts and Blocked(j + 1) do j = j + 1 end
				local lo, hi = math.max(2, i - 1), math.min(#pts - 1, j + 2)
				local savedP, savedR = {}, {}
				for k = lo, hi do savedP[k], savedR[k] = pts[k], room[k] end
				local done = false
				for step = 1, C.FLY_SIDE_STEPS do
					for _, sgn in ipairs({ 1, -1 }) do
						local d = sgn * step * C.FLY_SIDE
						for k = lo, hi do
							local w = ((k == lo and lo > 2) or (k == hi and hi < #pts - 1)) and 0.5 or 1
							local p = savedP[k] + side * d * w
							local r = Room(p)
							pts[k] = Vector(p.x, p.y, math.min(math.max(savedP[k].z, r.low), r.top))
							room[k] = r
						end
						local ok = true
						for k = lo - 1, hi do if Blocked(k) then ok = false break end end
						if ok then done = true break end
					end
					if done then break end
				end
				if not done then for k = lo, hi do pts[k], room[k] = savedP[k], savedR[k] end end
				i = hi
			else
				i = i + 1
			end
		end
	end
	Unblock()
	Detour()
	for _ = 1, C.FLY_SMOOTH do
		for i = 2, #pts - 1 do
			local want = (pts[i - 1] + pts[i] * 2 + pts[i + 1]) / 4
			local r = Room(want)
			want.z = math.min(math.max(want.z, r.low), r.top)
			if not Trace(pts[i - 1], want) and not Trace(want, pts[i + 1]) then pts[i], room[i] = want, r end
		end
	end
	return pts
end

local function CatmullRom(p0, p1, p2, p3, t)
	local t2, t3 = t * t, t * t * t
	return (p1 * 2 + (p2 - p0) * t + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2 + (p1 * 3 - p0 - p2 * 3 + p3) * t3) * 0.5
end

-- step 5: the spline through the points, cut into count even steps
function C.FlyResample(pts, count)
	local dense = { pts[1] }
	for i = 1, #pts - 1 do
		local p0, p1, p2, p3 = pts[math.max(1, i - 1)], pts[i], pts[i + 1], pts[math.min(#pts, i + 2)]
		local run = {}
		for s = 1, C.FLY_SPLINE do run[s] = CatmullRom(p0, p1, p2, p3, s / C.FLY_SPLINE) end
		local clear = not Trace(p1, run[1])
		for s = 2, C.FLY_SPLINE do if clear and Trace(run[s - 1], run[s]) then clear = false end end
		for s = 1, C.FLY_SPLINE do dense[#dense + 1] = clear and run[s] or LerpVector(s / C.FLY_SPLINE, p1, p2) end
	end
	local along = { 0 }
	for i = 2, #dense do along[i] = along[i - 1] + (dense[i] - dense[i - 1]):Length() end
	local total = along[#along]
	if total <= 0 then return { dense[1] } end
	local out, j = {}, 1
	for k = 0, count - 1 do
		local want = total * k / (count - 1)
		while j < #dense - 1 and along[j + 1] < want do j = j + 1 end
		local span = along[j + 1] - along[j]
		out[#out + 1] = LerpVector(span > 0 and (want - along[j]) / span or 0, dense[j], dense[j + 1])
	end
	return out
end

function C.FlyPath(tee, cup) return C.FlyResample(C.FlyRaw(tee, cup), C.FLY_SAMPLES) end

-- where the camera is at k (0-1 along the flight): the path is in even steps, so this is an even pace
function C.FlyAt(pts, k)
	local n = #pts
	if n == 1 then return pts[1] end
	local f = math.Clamp(k, 0, 1) * (n - 1)
	local i = math.min(n - 1, math.floor(f) + 1)
	return LerpVector(f - (i - 1), pts[i], pts[i + 1])
end

-- the camera k of the way along, looking at the cup
function C.FlyCamera(F, k)
	k = math.Clamp(k, 0, 1)
	k = k * k * (3 - 2 * k)
	local pos = C.FlyAt(F.path, k)
	return pos, (F.cup - pos):Angle()
end

function C.FlyView(fov)
	local F = C.fly
	if not F then return nil end
	local st = C.state
	local left = (st.timeLeft or 0) - (RealTime() - (C.stateAt or RealTime()))
	local pos, ang = C.FlyCamera(F, 1 - left / F.time)
	return { origin = pos, angles = ang, fov = fov }
end

function C.Flyover(st, a)
	local want = st.phase == "flyover" and st.tee and st.cup and C.Me(st) ~= nil
	if want and not C.fly then
		local tee, cup = V(st.tee), V(st.cup)
		C.fly = { path = C.FlyPath(tee, cup), cup = cup, time = BG.FlyTime(BG.Distance(st.tee, st.cup)) }
		if a.Freeze then a.Freeze(true, "boardgolf_fly") end
		if a.SetView then a.SetView(function(_, _, fov) return C.FlyView(fov) end, "boardgolf_fly") end
	elseif not want and C.fly then
		C.fly = nil
		SKATEGM_MODES.GiveViewBack("boardgolf_fly")
		if a.Freeze then a.Freeze(false, "boardgolf_fly") end
	end
end

function C.Think(now)
	local st, a = C.state, API()
	if not a then return end
	C.Flyover(st, a)
	C.BoardCam(st, a)
	if st.phase == "idle" then return end
	local lie = C.MyLie(st)
	local at = lie and st.cup and (V(lie) + Vector(0, 0, 8))
	if not BG.mode:TurnPrep(C, st, a, now, at, at and BG.YawTo(lie, st.cup), 0.6) and st.phase == "shot" and C.IsMine(st) then
		C.Track(st, a, now)
	end
end
hook.Add("Think", "skategm_boardgolf", function() C.Think(RealTime()) end)

---------------------------------------------------------------------------
-- the cup, the flag, the tee and everyone's lie
---------------------------------------------------------------------------
C.SEGMENTS = 40
local mat
local function Disc(pos, r, col)
	local n = C.SEGMENTS
	mesh.Begin(MATERIAL_TRIANGLES, n)
	for k = 0, n - 1 do
		local a0, a1 = k / n * math.pi * 2, (k + 1) / n * math.pi * 2
		for _, v in ipairs({ pos, pos + Vector(math.cos(a0) * r, math.sin(a0) * r, 0), pos + Vector(math.cos(a1) * r, math.sin(a1) * r, 0) }) do
			mesh.Position(v)
			mesh.Color(col.r, col.g, col.b, col.a)
			mesh.AdvanceVertex()
		end
	end
	mesh.End()
end

function C.DrawCup(st, t) C.DrawCupAt(V(st.cup), st.radius or BG.RADIUS_DEFAULT, t) end

function C.DrawCupAt(cup, r, t)
	mat = mat or CreateMaterial("skategm_boardgolf", "UnlitGeneric", { ["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$translucent"] = 1, ["$nocull"] = 1 })
	render.SetMaterial(mat)
	Disc(cup + Vector(0, 0, 1.5), r * 1.35, Color(120, 230, 120, 70))
	Disc(cup + Vector(0, 0, 2), r, Color(15, 15, 15, 235))
	local top = cup + Vector(0, 0, 130)
	render.SetColorMaterial()
	render.DrawBox(cup, angle_zero, Vector(-1, -1, 0), Vector(1, 1, 130), Color(240, 240, 240, 255))
	mesh.Begin(MATERIAL_TRIANGLES, 8)
	local seg = 4
	for k = 0, seg - 1 do
		local x0, x1 = k / seg * 40, (k + 1) / seg * 40
		local w0, w1 = math.sin(t * 4 - k * 0.9) * 4, math.sin(t * 4 - (k + 1) * 0.9) * 4
		local h0, h1 = 13 * (1 - k / seg), 13 * (1 - (k + 1) / seg)
		local p00, p01 = top + Vector(x0, w0, -13 + h0), top + Vector(x0, w0, -13 - h0)
		local p10, p11 = top + Vector(x1, w1, -13 + h1), top + Vector(x1, w1, -13 - h1)
		for _, v in ipairs({ p00, p10, p01, p01, p10, p11 }) do
			mesh.Position(v)
			mesh.Color(220, 40, 40, 255)
			mesh.AdvanceVertex()
		end
	end
	mesh.End()
end

hook.Add("PostDrawTranslucentRenderables", "skategm_boardgolf", function(depth, sky)
	if depth or sky then return end
	local st = C.state
	if st.phase == "idle" or not st.cup then return end
	C.DrawCup(st, RealTime())
	render.SetColorMaterial()
	if st.tee then render.DrawBox(V(st.tee), angle_zero, Vector(-6, -6, 0), Vector(6, 6, 2), Color(255, 255, 255, 180)) end
	for _, p in ipairs(st.players or {}) do
		if p.lie and not p.holed and p.playing then
			local col = p.ent == C.MyEnt() and GREEN or Color(255, 255, 255)
			render.DrawSphere(V(p.lie) + Vector(0, 0, 4), 4, 10, 10, Color(col.r, col.g, col.b, 220))
		end
	end
end)

---------------------------------------------------------------------------
-- on screen
---------------------------------------------------------------------------
local FONTS = {
	skategm_bg_big = { "Coolvetica", 0.06, 500 },
	skategm_bg_mid = { "Coolvetica", 0.03, 500 },
	skategm_bg_small = { "Roboto", 0.018, 700 },
}
local function Text(t, font, x, y, col, ax) SKATEGM_MODES.Text(t, font, x, y, col, ax or TEXT_ALIGN_CENTER, 1) end
local RESULT = {
	holed = function(l) return string.format("%s: IN THE CUP! (%d)", l.name, l.strokes), GOLD end,
	picked = function(l) return string.format("%s picked up (%d)", l.name, l.strokes), RED end,
	lie = function(l) return string.format("%s: %d to the cup (stroke %d)", l.name, l.distance or 0, l.strokes), color_white end,
	lost = function(l) return string.format("%s: the board got away: same spot (stroke %d)", l.name, l.strokes), RED end,
	left = function(l) return string.format("%s left Skater mode: a stroke", l.name), RED end,
	skipped = function(l) return string.format("%s missed the shot: a stroke", l.name), RED end,
}

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" or st.phase == "lobby" then return end
	local me = C.Me(st)
	if not (me and me.playing) then return end
	BG.mode:Fonts(FONTS)
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
	local cx, line = w / 2, h * 0.035
	if st.cup then
		local s = (V(st.cup) + Vector(0, 0, 140)):ToScreen()
		if s.visible then Text("PAR " .. (st.par or 0), "skategm_bg_small", s.x, s.y, GREEN) end
	end
	local who = C.IsMine(st) and "YOUR SHOT" or (string.upper(C.NameOf(st, st.active)) .. "'S SHOT")
	if st.phase == "flyover" then
		Text("THE HOLE", "skategm_bg_big", cx, h * 0.08, GREEN)
		Text(string.format("par %d, %d units to the cup", st.par or 0, math.floor(BG.Distance(st.tee, st.cup))), "skategm_bg_mid", cx, h * 0.08 + line * 1.6, color_white)
	elseif st.phase == "prep" then
		Text(C.NameOf(st, st.active) .. " is walking to their ball...", "skategm_bg_mid", cx, h * 0.08, GREY)
	elseif st.phase == "countdown" then
		Text(who, "skategm_bg_mid", cx, h * 0.08, GREEN)
		Text(tostring(math.max(1, math.ceil(left))), "skategm_bg_big", cx, h * 0.08 + line * 1.3, color_white)
	elseif st.phase == "shot" then
		local T = C.IsMine(st) and C.stroke
		if T and not T.sent then
			local clock = (st.shotTime or BG.SHOT_DEFAULT) - (now - (T.start or now))
			Text(string.format("%s   %.1f", who, math.max(0, clock)), "skategm_bg_mid", cx, h * 0.08, clock < 1.5 and RED or color_white)
			local hint = "ride and aim (the rocket is on): when the clock runs out the board goes on alone"
			local P = SKATEGM_UI and SKATEGM_UI.pad
			Text(P and P.T and P.T(hint) or hint, "skategm_bg_small", cx, h * 0.08 + line, GREY)
		else
			Text(who, "skategm_bg_mid", cx, h * 0.08, color_white)
		end
	elseif st.phase == "roll" then
		Text("LET IT ROLL", "skategm_bg_mid", cx, h * 0.08, GREEN)
	elseif st.phase == "between" and st.last then
		local fn = RESULT[st.last.result] or RESULT.lie
		local text, col = fn(st.last)
		Text(text, "skategm_bg_mid", cx, h * 0.08, col)
	elseif st.phase == "results" and st.winners then
		local wn = st.winners.names or {}
		Text(#wn > 0 and (string.upper(table.concat(wn, " & ")) .. " WIN" .. (#wn == 1 and "S" or "")) or "NOBODY FINISHED", "skategm_bg_big", cx, h * 0.12, GOLD)
		local diff = (st.winners.strokes or 0) - (st.par or 0)
		Text(string.format("%d strokes (%s)", st.winners.strokes or 0, diff == 0 and "par" or (diff > 0 and ("+" .. diff) or tostring(diff))), "skategm_bg_mid", cx, h * 0.12 + line * 2, color_white)
	end
	local rows = {}
	for _, p in ipairs(st.players or {}) do if p.playing then rows[#rows + 1] = p end end
	table.sort(rows, function(x, y) return (x.strokes or 0) < (y.strokes or 0) end)
	local x, y = w * 0.98, h * 0.3
	Text("PAR " .. (st.par or 0), "skategm_bg_small", x, y, GREEN, TEXT_ALIGN_RIGHT)
	y = y + line * 0.9
	for _, p in ipairs(rows) do
		local mark = p.holed and (p.picked and "  picked up" or "  in") or ""
		Text(string.format("%s  %d%s", p.name, p.strokes or 0, mark), "skategm_bg_small", x, y, p.ent == st.active and GREEN or (p.holed and GREY or color_white), TEXT_ALIGN_RIGHT)
		y = y + line * 0.8
	end
end
hook.Add("HUDPaint", "skategm_boardgolf", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

---------------------------------------------------------------------------
-- host menu
---------------------------------------------------------------------------
BG.mode:LobbyLines(function(st)
	return { string.format("par %d, %d s a shot, a cup %d across", st.par or 0, st.shotTime or BG.SHOT_DEFAULT, math.floor((st.radius or BG.RADIUS_DEFAULT) * 2)),
		"bail and let the board fly: where it stops is your next shot" }
end)
BG.mode:Host({
	description = "bail your board into the hole",
	about = "Bail to launch your board toward the hole. Every bail is one shot, and your next shot starts from wherever the board stopped. The fewest shots wins.",
	options = {
		{ key = "cup", label = "Cup", type = "object", rotate = false, draw = function(obj) C.DrawCupAt(obj.pos, obj.scale or BG.RADIUS_DEFAULT, RealTime()) end,
			scale = { label = "Size", min = BG.RADIUS_MIN, max = BG.RADIUS_MAX, step = 4, default = BG.RADIUS_DEFAULT, format = function(v) return math.floor(v * 2) .. " across" end } },
		{ key = "friction", label = "Board rolling", type = "choice", choices = (function()
			local out = {}
			for _, f in ipairs(BG.FRICTIONS) do out[#out + 1] = { f[1], f[2] } end
			return out
		end)(), default = BG.FRICTION_DEFAULT },
		{ key = "par", label = "Par", type = "choice", choices = BG.PARS, default = 0 },
		{ key = "shotTime", label = "Shot clock", type = "number", min = BG.SHOT_MIN, max = BG.SHOT_MAX, step = 1, default = BG.SHOT_DEFAULT, format = function(v) return v .. " s" end },
		{ key = "maxStrokes", label = "Pick up after", type = "number", min = BG.STROKES_MIN, max = BG.STROKES_MAX, step = 1, default = BG.STROKES_DEFAULT, format = function(v) return v .. " strokes" end },
	},
	start = function(v, mode)
		local c = v.cup and v.cup.pos
		mode:Send({ cmd = "create", cup = c and { c.x, c.y, c.z } or nil, radius = v.cup and v.cup.scale, shotTime = v.shotTime, maxStrokes = v.maxStrokes, friction = v.friction, par = v.par, canSkate = CanSkate() })
	end,
})
