local C = { state = { phase = "idle" }, trails = {}, queue = {}, eaten = {} }
SNAKE.client = C

local API = SKATEGM_MODES.API
local CanSkate = SKATEGM_MODES.CanSkate
local Text = SKATEGM_MODES.Text
local function Send(t) SNAKE.mode:Send(t) end
local function Say(text, bad) SNAKE.mode:Say(text, bad) end

function C.Me(st) return SNAKE.mode:Me(st) end
function C.IsHost(st) return SNAKE.mode:IsHost(st) end
function C.Colour(slot, a)
	local c = SNAKE.COLORS[((slot or 1) - 1) % #SNAKE.COLORS + 1]
	return Color(c[1], c[2], c[3], a or 255)
end

function C.Head()
	local a = API()
	local P = a and a.PoseOf and a.PoseOf(LocalPlayer())
	if P and P.RIGHT_WHEELFRONT and P.LEFT_WHEELFRONT and P.RIGHT_WHEELBACK and P.LEFT_WHEELBACK then
		local w = (P.RIGHT_WHEELFRONT + P.LEFT_WHEELFRONT + P.RIGHT_WHEELBACK + P.LEFT_WHEELBACK) / 4
		return { w.x, w.y, w.z }
	end
	local p = a and a.SkaterPos and a.SkaterPos()
	return p and { p.x, p.y, p.z - 36 } or nil
end

function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	local me = C.Me(st)
	local a = API()
	-- crashed out: watching the rest, out of sight and out of the way
	if a and a.SetHidden then a.SetHidden("snake", (me and st.phase == "playing" and (me.out or C.crashed)) or false) end
	if me and st.phase ~= "idle" and a and not a.IsSkating() and not a.IsLoading() and CanSkate() and not C.asked then
		C.asked = true
		a.StartSkating()
	end
	if not me then C.asked = nil end
	if st.phase == "countdown" and prev.phase ~= "countdown" then
		C.trails, C.queue, C.crashed, C.lastSample, C.eaten = {}, {}, nil, nil, {}
		if a then a.SetPlayerCollision(false) end
	end
	if (st.phase == "lobby" or st.phase == "idle") and prev.phase ~= st.phase then
		if a then a.SetPlayerCollision(nil) end
		if st.phase == "idle" then C.trails = {} end
	end
end

function C.OnTrail(msg, now)
	if type(msg) ~= "table" or not msg.ent then return end
	msg = SKATEGM_MODES.FromAbs and SKATEGM_MODES.FromAbs(msg) or msg
	if msg.ent == LocalPlayer():EntIndex() and not msg.clear then return end
	local t = C.trails[msg.ent]
	if msg.clear or not t then
		t = { pts = {}, len = msg.len or SNAKE.LENGTH_DEFAULT }
		C.trails[msg.ent] = t
	end
	t.len = msg.len or t.len
	local p = msg.p or {}
	for k = 1, #p - 2, 3 do t.pts[#t.pts + 1] = { p[k], p[k + 1], p[k + 2] } end
	SNAKE.Trim(t.pts, t.len)
end

function C.MyLength(st)
	local me = C.Me(st)
	return me and me.length or SNAKE.LENGTH_DEFAULT
end

function C.Crash(by, wall)
	if C.crashed then return end
	C.crashed = true
	local a = API()
	if a and a.SetHidden then a.SetHidden("snake", true) end
	Send({ cmd = "crash", by = by, wall = wall })
	Say(wall and "you hit the wall: you're out" or "you hit a tail: you're out", true)
	if surface and surface.PlaySound then surface.PlaySound("physics/body/body_medium_impact_hard1.wav") end
end

function C.Think(now)
	local st = C.state
	local me = C.Me(st)
	SNAKE.mode:HoldAtStart(me ~= nil and me.playing and st.phase == "countdown", me and me.start and Vector(me.start[1], me.start[2], me.start[3]) or nil, me and me.yaw, now)
	if st.phase ~= "playing" or not me or not me.playing or me.out or C.crashed then return end
	local head = C.Head()
	if not head then return end
	local mine = C.trails[LocalPlayer():EntIndex()]
	if not mine then
		mine = { pts = {}, len = C.MyLength(st) }
		C.trails[LocalPlayer():EntIndex()] = mine
	end
	mine.len = C.MyLength(st)
	local last = C.lastSample
	if not last or (head[1] - last[1]) ^ 2 + (head[2] - last[2]) ^ 2 >= SNAKE.SPACING ^ 2 then
		C.lastSample = head
		mine.pts[#mine.pts + 1] = head
		SNAKE.Trim(mine.pts, mine.len)
		C.queue[#C.queue + 1] = head
	end
	if #C.queue > 0 and now >= (C.nextSend or 0) then
		C.nextSend = now + 0.15
		local flat = {}
		for i = 1, math.min(#C.queue, SNAKE.MAX_POINTS) do
			local q = C.queue[i]
			flat[#flat + 1] = math.floor(q[1] * 10) / 10
			flat[#flat + 1] = math.floor(q[2] * 10) / 10
			flat[#flat + 1] = math.floor(q[3] * 10) / 10
		end
		local rest = {}
		for i = SNAKE.MAX_POINTS + 1, #C.queue do rest[#rest + 1] = C.queue[i] end
		C.queue = rest
		Send({ cmd = "trail", p = flat })
	end
	if SNAKE.Outside(st.area, head[1], head[2]) then return C.Crash(0, true) end
	for ent, t in pairs(C.trails) do
		local own = ent == LocalPlayer():EntIndex()
		if SNAKE.HitsTrail(head, t.pts, own and SNAKE.NECK or 0) then return C.Crash(ent) end
	end
	for _, pel in pairs(st.pellets or {}) do
		if (head[1] - pel.x) ^ 2 + (head[2] - pel.y) ^ 2 < SNAKE.EAT_RADIUS ^ 2 and math.abs(head[3] - pel.z) < 96 and now >= (C.eaten[pel.id] or 0) then
			C.eaten[pel.id] = now + 1
			Send({ cmd = "eat", id = pel.id })
			if surface and surface.PlaySound then surface.PlaySound("buttons/blip1.wav") end
		end
	end
end

-- (an infinite map: my frame moved a chunk over - the trails kept here move
-- with it, so the walls stay where they are in the world)
function C.OnFrameShift(delta)
	-- (each point once: the newest one is in the trail, the queue and lastSample)
	local done = {}
	local function shift(q)
		if done[q] then return end
		done[q] = true
		q[1], q[2], q[3] = q[1] - delta.x, q[2] - delta.y, q[3] - delta.z
	end
	for _, t in pairs(C.trails) do for _, q in ipairs(t.pts) do shift(q) end end
	for _, q in ipairs(C.queue) do shift(q) end
	if C.lastSample then shift(C.lastSample) end
end

SNAKE.mode:OnState(function(st, now) C.OnState(st, now) end)
SNAKE.mode:OnFrameShift(function(delta) C.OnFrameShift(delta) end)
net.Receive(SNAKE.NET_TRAIL, function()
	local ok, msg = pcall(util.JSONToTable, net.ReadString())
	if ok then C.OnTrail(msg, RealTime()) end
end)
hook.Add("Think", "skategm_snake", function() C.Think(RealTime()) end)

local up = Vector(0, 0, SNAKE.WALL_HEIGHT)
function C.SlotOf(ent)
	for _, p in ipairs(C.state.players or {}) do if p.ent == ent then return p.slot, p.out end end
end

function C.DrawWorld()
	local st = C.state
	if st.phase == "idle" then return end
	if st.area then SKATEGM_MODES.AreaWall(Vector(st.area[1], st.area[2], st.area[3]), st.area[4], Color(120, 255, 120)) end
	render.SetColorMaterial()
	for ent, t in pairs(C.trails) do
		local slot, out = C.SlotOf(ent)
		if slot and not out then
			local col = C.Colour(slot, 110)
			local edge = C.Colour(slot, 255)
			local pts = t.pts
			for i = 1, #pts - 1 do
				local a, b = Vector(pts[i][1], pts[i][2], pts[i][3]), Vector(pts[i + 1][1], pts[i + 1][2], pts[i + 1][3])
				render.DrawQuad(a, b, b + up, a + up, col)
				render.DrawQuad(a + up, b + up, b, a, col)
				render.DrawLine(a + up, b + up, edge, true)
			end
		end
	end
	local bob = math.sin(RealTime() * 3) * 4
	for _, pel in pairs(st.pellets or {}) do
		render.DrawSphere(Vector(pel.x, pel.y, pel.z + 22 + bob), 9, 12, 12, Color(255, 240, 120, 230))
	end
end
hook.Add("PostDrawTranslucentRenderables", "skategm_snake", function(depth, sky) if not (depth or sky) then C.DrawWorld() end end)

local FONTS = {
	skategm_snake_big = { "Roboto", 0.07, 900, 24 },
	skategm_snake_mid = { "Roboto", 0.03, 700, 16 },
	skategm_snake_small = { "Roboto", 0.02, 600, 12 },
}
local GREEN, GREY = Color(120, 255, 120), Color(170, 170, 170)
function C.Paint(w, h, now)
	local st = C.state
	if st.phase == "idle" then return end
	SNAKE.mode:Fonts(FONTS)
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
	if st.phase == "lobby" then
		Text("SNAKE", "skategm_snake_mid", w / 2, h * 0.04, GREEN)
		Text(C.IsHost(st) and "you're the host: LB + D-pad left to start" or (C.Me(st) and "waiting for the host to start" or "LB + D-pad left to join"), "skategm_snake_small", w / 2, h * 0.08, color_white)
	elseif st.phase == "countdown" then
		Text(tostring(math.max(1, math.ceil(left))), "skategm_snake_big", w / 2, h * 0.3, GREEN)
		Text("don't hit any tail, or the wall. Eat the yellow orbs to grow", "skategm_snake_small", w / 2, h * 0.3 + h * 0.09, color_white)
	elseif st.phase == "playing" then
		Text("SNAKE  " .. SNAKE.Clock(left), "skategm_snake_mid", w / 2, h * 0.04, GREEN)
		if C.crashed or (C.Me(st) and C.Me(st).out) then Text("you're out", "skategm_snake_mid", w / 2, h * 0.09, Color(255, 110, 90)) end
	elseif st.phase == "results" then
		Text(st.winner and (st.winner.name .. " wins!") or "nobody survived", "skategm_snake_big", w / 2, h * 0.25, GREEN)
	end
	local y = h * 0.14
	for _, p in ipairs(st.players or {}) do
		local col = p.out and GREY or C.Colour(p.slot)
		Text(string.format("%s  %s", p.name, p.out and "out" or (math.floor((p.length or 0) / 10) .. " long")), "skategm_snake_small", w * 0.88, y, col, TEXT_ALIGN_RIGHT)
		y = y + h * 0.028
	end
end
hook.Add("HUDPaint", "skategm_snake", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

SNAKE.mode:ChatCommands({})
SNAKE.mode:Host({
	description = "don't hit a tail; eat to grow; last one left wins",
	options = {
		{ key = "area", label = "Arena", type = "region", min = SNAKE.RADIUS_MIN, max = SNAKE.RADIUS_MAX, step = 128, default = SNAKE.RADIUS_DEFAULT, format = function(v) return (v * 2) .. " units across" end },
		{ key = "time", label = "Time limit", type = "number", min = SNAKE.TIME_MIN, max = SNAKE.TIME_MAX, step = 15, default = SNAKE.TIME_DEFAULT, format = SNAKE.Clock },
		{ key = "length", label = "Starting tail", type = "number", min = SNAKE.LENGTH_MIN, max = SNAKE.LENGTH_MAX, step = 100, default = SNAKE.LENGTH_DEFAULT, format = function(v) return v .. " units" end },
		{ key = "pellets", label = "Orbs", type = "number", min = SNAKE.PELLETS_MIN, max = SNAKE.PELLETS_MAX, step = 1, default = SNAKE.PELLETS_DEFAULT },
	},
	start = function(v, mode)
		local c = v.area.centre
		mode:Send({ cmd = "create", x = c.x, y = c.y, z = c.z, radius = v.area.radius, time = v.time, length = v.length, pellets = v.pellets, canSkate = CanSkate() })
	end,
})

