-- Ball Battle, client: everyone's bouncy balls circling them, telling the
-- server when I bail, watching once I'm out, the screens.
local BB = BALLBATTLE
local C = { state = { phase = "idle" } }
BB.client = C

local API = SKATEGM_MODES.API
local function Send(t) BB.mode:Send(t) end
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) BB.mode:Say(text, bad) end
local Clock = SKATEGM_MODES.Clock
local PINK, GREY, GOLD = Color(255, 120, 200), Color(190, 190, 190), Color(255, 210, 90)

function C.Me(st) return BB.mode:Me(st) end

BB.mode:Boundary(function(st)
	local me = BB.mode:Me(st)
	if st.phase ~= "playing" or not (me and me.playing and not me.out) or not st.area then return nil end
	return { area = st.area, pos = C.slot or st.startV, yaw = st.yaw, out = function() Send({ cmd = "outside" }) end }
end)

function C.SlotPos(st, me)
	if not (st.startV and me and me.slot) then return st.startV end
	local dx, dy = BB.SlotOffset(me.slot, st.slots or 1, st.yaw)
	local p = st.startV + Vector(dx, dy, 0)
	return Vector(p.x, p.y, SKATEGM_MODES.Ground(p.x, p.y, st.startV.z) + 6)
end

function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	st.startV = st.start and Vector(st.start[1], st.start[2], st.start[3]) or nil
	local me, a = C.Me(st), API()
	if me and st.phase ~= "idle" and a and not a.IsSkating() and not a.IsLoading() and CanSkate() and not C.asked then
		C.asked = true
		a.StartSkating()
	end
	if not me then C.asked = nil end
	if st.phase == "countdown" and prev.phase ~= "countdown" then C.launched, C.slot = nil, C.SlotPos(st, me) end
	-- a ball popped: the sound where its owner is
	local before = {}
	for _, p in ipairs(prev.players or {}) do before[p.ent] = p.balls end
	for _, p in ipairs(st.players or {}) do
		if st.phase == "playing" and before[p.ent] and p.balls < before[p.ent] then
			local P = a and a.PoseOf and a.PoseOf(Entity(p.ent))
			if P and P.HIPS then sound.Play("garrysmod/balloon_pop_cute.wav", P.HIPS, 80, 100, 1) end
		end
	end
	local out = (me and me.playing and me.out and st.phase == "playing") or false
	if a and a.SetHidden then a.SetHidden("ballbattle", out) end
	BB.mode:Spectate(out and SKATEGM_MODES.Others(st, function(p) return p.playing and not p.out end) or nil)
	if st.phase == "results" and prev.phase ~= "results" and st.winners then
		local n = st.winners.names or {}
		Say(#n > 0 and (table.concat(n, " and ") .. " won") or "nobody won")
	end
end
BB.mode:OnState(function(st, now) C.OnState(st, now) end)

function C.Think(now)
	local st, a = C.state, API()
	local me = C.Me(st)
	local riding = me ~= nil and me.playing and not me.out
	BB.mode:HoldAtStart(riding and st.phase == "countdown", C.slot or st.startV, st.yaw, now)
	if not (a and riding and st.phase == "playing") then C.wasBail = nil return end
	if not C.launched and (C.slot or st.startV) then
		C.launched = true
		a.TeleportTo(C.slot or st.startV, st.yaw)
	end
	local state = a.State and a.State() or ""
	local bail = state:find("Wipeout", 1, true) ~= nil
	if bail and not C.wasBail then Send({ cmd = "bailed" }) end
	C.wasBail = bail
end
hook.Add("Think", "skategm_ballbattle", function() C.Think(RealTime()) end)

local ball
function C.DrawWorld()
	local st = C.state
	if st.phase == "idle" then return end
	if st.area and st.phase ~= "results" then
		SKATEGM_MODES.AreaWall(Vector(st.area[1], st.area[2], st.area[3]), st.area[4], Color(PINK.r, PINK.g, PINK.b))
	end
	if st.phase ~= "playing" and st.phase ~= "countdown" then return end
	local a = API()
	if not (a and a.PoseOf) then return end
	ball = ball or Material("sprites/sent_ball")
	render.SetMaterial(ball)
	local now = RealTime()
	for _, p in ipairs(st.players or {}) do
		local P = p.playing and not p.out and a.PoseOf(Entity(p.ent))
		if P and P.HIPS then
			local col = BB.Colour(p.ent)
			for i = 1, p.balls or 0 do
				local ang = now * 2 + i / (p.balls or 1) * math.pi * 2
				local pos = P.HIPS + Vector(math.cos(ang) * 30, math.sin(ang) * 30, 26 + math.sin(now * 4 + i) * 4)
				render.DrawSprite(pos, 20, 20, col)
			end
		end
	end
end
hook.Add("PostDrawTranslucentRenderables", "skategm_ballbattle", function(depth, sky) if not (depth or sky) then C.DrawWorld() end end)

local FONTS = {
	skategm_bb_big = { "Coolvetica", 0.06, 500 },
	skategm_bb_mid = { "Coolvetica", 0.03, 500 },
	skategm_bb_small = { "Roboto", 0.018, 700 },
}
local function Text(t, font, x, y, col, ax) SKATEGM_MODES.Text(t, font, x, y, col, ax or TEXT_ALIGN_CENTER, 1) end

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" or st.phase == "lobby" then return end
	local me = C.Me(st)
	if not (me and me.playing) then return end
	BB.mode:Fonts(FONTS)
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
	local line = h * 0.035
	if st.phase == "countdown" then
		Text("BALL BATTLE", "skategm_bb_mid", w / 2, h * 0.22, PINK)
		Text(tostring(math.max(1, math.ceil(left))), "skategm_bb_big", w / 2, h * 0.22 + line * 1.2, color_white)
	elseif st.phase == "playing" then
		Text(me.out and ("OUT   " .. Clock(left)) or string.format("%s   %s", string.rep("O ", me.balls or 0), Clock(left)), "skategm_bb_mid", w / 2, h * 0.04, me.out and GREY or PINK)
	elseif st.phase == "results" and st.winners then
		local n = st.winners.names or {}
		Text(#n > 0 and (string.upper(table.concat(n, " & ")) .. " WIN" .. (#n == 1 and "S" or "")) or "NOBODY WON", "skategm_bb_big", w / 2, h * 0.12, GOLD)
	end
	local x, y = w * 0.98, h * 0.3
	for _, p in ipairs(st.players or {}) do
		if p.playing then
			Text(p.name .. "  " .. (p.out and "out" or string.rep("o", p.balls or 0)), "skategm_bb_small", x, y, p.out and GREY or BB.Colour(p.ent), TEXT_ALIGN_RIGHT)
			y = y + line * 0.8
		end
	end
end
hook.Add("HUDPaint", "skategm_ballbattle", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

BB.mode:LobbyLines(function(st)
	return { string.format("%d balls each, %s, area %d", st.balls or BB.BALLS_DEFAULT, Clock(st.time or BB.TIME_DEFAULT), st.area and st.area[4] or 0), st.items and "items on (left stick in)" or "no items" }
end)
BB.mode:Host({
	description = "hit others and keep your balls",
	about = "Everyone starts with bouncy balls. Getting hit or bailing pops some. Lose them all and you're out. The last one with balls left wins.",
	options = {
		{ key = "area", label = "Play area", type = "region", min = BB.AREA_MIN, max = BB.AREA_MAX, step = 128, default = BB.AREA_DEFAULT },
		{ key = "time", label = "Time limit", type = "number", min = BB.TIME_MIN, max = BB.TIME_MAX, step = 30, default = BB.TIME_DEFAULT, format = function(v) return v .. " s" end },
		{ key = "balls", label = "Balls each", type = "number", min = BB.BALLS_MIN, max = BB.BALLS_MAX, step = 1, default = BB.BALLS_DEFAULT },
		{ key = "items", label = "Items", type = "bool", default = true },
	},
	start = function(v, mode)
		local c = v.area.centre
		mode:Send({ cmd = "create", centre = { c.x, c.y, c.z }, radius = v.area.radius, time = v.time, balls = v.balls, items = v.items, canSkate = CanSkate() })
	end,
})
