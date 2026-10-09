-- Hold the Line, client: holding the line (the clock, a safe moment to pass,
-- bails and stalls told to the server), taking it over (held where it was,
-- then off at its speed), watching the others, the HUD.
local HL = HOLDLINE
local C = { state = { phase = "idle" }, trail = {} }
HL.client = C

local API = SKATEGM_MODES.API
local function Send(t) HL.mode:Send(t) end
HL.mode.ownQueue = true
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) HL.mode:Say(text, bad) end
local Commas = SKATEGM_MODES.Commas
local BLUE, GREY, RED, GOLD, GREEN = Color(90, 200, 255), Color(190, 190, 190), Color(235, 85, 95), Color(255, 210, 90), Color(110, 230, 120)
local PLAYING = { countdown = true, riding = true, handover = true }
C.TRAIL = 0.2

function C.Me(st) return HL.mode:Me(st) end
function C.MyEnt() return LocalPlayer():EntIndex() end
function C.IsMine(st) return st.active ~= nil and st.active ~= 0 and st.active == C.MyEnt() end
function C.NameOf(st, ent)
	for _, p in ipairs(st.players or {}) do if p.ent == ent then return p.name end end
	return "?"
end
local function V(t) return Vector(t[1], t[2], t[3]) end
function C.Scale() return 0.0254 * ((SkateGM and SkateGM.loadedScale) or 1) end

function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	local me, a = C.Me(st), API()
	local playing = me ~= nil and me.playing
	if playing and PLAYING[st.phase] and a and not a.IsSkating() and not a.IsLoading() and CanSkate() and not C.asked then
		C.asked = true
		a.StartSkating()
	end
	if not me then C.asked = nil end
	local mine, wasMine = C.IsMine(st), C.IsMine(prev)
	-- waiting skaters are out of the way of the line: unseen, not solid. And
	-- while the line's going nobody collides with anybody and only who I
	-- watch is drawn: at a handover the next skater lands right where the
	-- last one is, before that one's hidden flag has reached everyone
	local waiting = (playing and PLAYING[st.phase] and not mine) or false
	if a and waiting ~= (C.waiting or false) then
		C.waiting = waiting
		if a.SetHidden then a.SetHidden("holdline", waiting) end
	end
	HL.mode:KeepApart(playing and PLAYING[st.phase])
	HL.mode:Spectate(waiting and SKATEGM_MODES.Others(st, function(p) return p.playing end) or nil, { prefer = st.active })
	if st.phase == "riding" and mine and not (prev.phase == "riding" and wasMine) then
		C.turn = { start = now, launched = false, baseline = a and a.Score and a.Score() or 0 }
		C.trail = {}
	end
	if not (st.phase == "riding" and mine) then C.turn = nil end
	if st.phase == "handover" and mine and not (prev.phase == "handover" and wasMine) then
		Say("your turn: you take the line from here")
	end
end
HL.mode:OnState(function(st, now) C.OnState(st, now) end)

-- where the line is now: place, the way it's going, its speed (units/s)
function C.LineNow(a, now)
	local P = a.PoseOf and a.PoseOf(LocalPlayer())
	local board = P and P.SKATEBOARD_ROOT
	if not board then return nil end
	local vel = Vector(0, 0, 0)
	local old = C.trail[1]
	if old and now - old.t > 0.05 then vel = (board - old.pos) / (now - old.t) end
	local flat = Vector(vel.x, vel.y, 0)
	local yaw
	if flat:Length() > 20 then
		yaw = flat:Angle().y
	elseif P.TRUCK_FRONT and P.TRUCK_BACK then
		yaw = (P.TRUCK_FRONT - P.TRUCK_BACK):Angle().y
	end
	return { pos = board + Vector(0, 0, 4), yaw = yaw or 0, vel = vel, speed = flat:Length() }
end

function C.Remember(a, now)
	local P = a.PoseOf and a.PoseOf(LocalPlayer())
	local board = P and P.SKATEBOARD_ROOT
	if not board then return end
	C.trail[#C.trail + 1] = { t = now, pos = Vector(board.x, board.y, board.z) }
	while #C.trail > 1 and now - C.trail[1].t > C.TRAIL do table.remove(C.trail, 1) end
end

local function Packet(cmd, l, score)
	return { cmd = cmd, pos = { l.pos.x, l.pos.y, l.pos.z }, yaw = l.yaw, vel = { l.vel.x, l.vel.y, l.vel.z }, score = score }
end

-- holding the line: off at the handed-over speed, then the clock, bails, stalls, the pass
function C.Hold(st, a, now)
	local T = C.turn
	if not T or T.done then return end
	if not T.launched then
		T.launched = true
		local h = st.handover
		local v = h and h.vel and V(h.vel)
		if v and v:Length() > 1 and a.Launch then a.Launch(v * C.Scale()) end
	end
	C.Remember(a, now)
	local l = C.LineNow(a, now)
	if not l then return end
	local score = math.max(0, (a.Score and a.Score() or 0) - (T.baseline or 0))
	C.speed, C.score = l.speed, score
	local state = a.State and a.State() or ""
	local since = now - T.start
	if state:find("Wipeout", 1, true) then T.wipeSince = T.wipeSince or now else T.wipeSince = nil end
	if T.wipeSince and now - T.wipeSince >= HL.BAIL_HOLD and since >= HL.GRACE then
		T.done = true
		return Send({ cmd = "bail" })
	end
	local min = st.minSpeed or 0
	if min > 0 and since >= HL.GRACE and l.speed < min then T.slowSince = T.slowSince or now else T.slowSince = nil end
	if T.slowSince and now - T.slowSince >= HL.STALL_TIME then
		T.done = true
		return Send({ cmd = "stall" })
	end
	if now >= (T.nextLive or 0) then
		T.nextLive = now + 1 / HL.LIVE_RATE
		Send(Packet("live", l, score))
	end
	local P = a.PoseOf and a.PoseOf(LocalPlayer())
	if since >= (st.turnTime or HL.TURN_DEFAULT) and HL.SafeState(state) and (not a.OnBoard or a.OnBoard()) and HL.Flat(P) then
		T.done = true
		Send(Packet("pass", l, score))
	end
end

function C.Think(now)
	local st, a = C.state, API()
	if not a or st.phase == "idle" then return end
	local h = st.handover
	HL.mode:HoldAtStart(C.IsMine(st) and a.IsSkating() and (st.phase == "countdown" or st.phase == "handover") and h ~= nil,
		h and V(h.pos), h and h.yaw, now)
	if st.phase == "riding" and C.IsMine(st) then C.Hold(st, a, now) end
end
hook.Add("Think", "skategm_holdline", function() C.Think(RealTime()) end)

---------------------------------------------------------------------------
-- on screen
---------------------------------------------------------------------------
local FONTS = {
	skategm_hl_big = { "Coolvetica", 0.06, 500 },
	skategm_hl_mid = { "Coolvetica", 0.03, 500 },
	skategm_hl_small = { "Roboto", 0.018, 700 },
}
local function Text(t, font, x, y, col, ax) SKATEGM_MODES.Text(t, font, x, y, col, ax or TEXT_ALIGN_CENTER, 1) end
local REASONS = { bail = "BAILED", stall = "SLOWED TO A STOP", left = "LEFT MID-LINE" }

function C.SpeedBar(w, h, speed, min)
	local bw, bh = w * 0.18, h * 0.012
	local x, y = w / 2 - bw / 2, h * 0.86
	local top = math.max(min * 3, 400)
	surface.SetDrawColor(0, 0, 0, 150)
	surface.DrawRect(x - 2, y - 2, bw + 4, bh + 4)
	local f = math.Clamp(speed / top, 0, 1)
	local col = speed < min and RED or GREEN
	surface.SetDrawColor(col.r, col.g, col.b, 230)
	surface.DrawRect(x, y, bw * f, bh)
	if min > 0 then
		surface.SetDrawColor(255, 255, 255, 220)
		surface.DrawRect(x + bw * (min / top) - 1, y - 4, 2, bh + 8)
	end
	Text("keep moving", "skategm_hl_small", w / 2, y + bh + h * 0.015, speed < min and RED or GREY)
end

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" or st.phase == "lobby" then return end
	local me = C.Me(st)
	if not (me and me.playing) then return end
	HL.mode:Fonts(FONTS)
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
	local cx, line = w / 2, h * 0.035
	local mine = C.IsMine(st)
	local who = C.NameOf(st, st.active)
	if st.phase == "countdown" then
		Text(mine and "YOU START THE LINE" or (string.upper(who) .. " STARTS THE LINE"), "skategm_hl_mid", cx, h * 0.22, BLUE)
		Text(tostring(math.max(1, math.ceil(left))), "skategm_hl_big", cx, h * 0.22 + line * 1.2, color_white)
	elseif st.phase == "handover" then
		Text(mine and "YOU TAKE THE LINE" or (string.upper(who) .. " TAKES THE LINE"), "skategm_hl_mid", cx, h * 0.22, BLUE)
		Text(tostring(math.max(1, math.ceil(left))), "skategm_hl_big", cx, h * 0.22 + line * 1.2, color_white)
		if mine then Text("you'll go on at the same speed: be ready", "skategm_hl_small", cx, h * 0.22 + line * 3, GREY) end
	elseif st.phase == "riding" then
		if left > 0 then
			Text(string.format("%s   %.1f", mine and "YOUR TURN" or (string.upper(who) .. " HAS THE LINE"), left), "skategm_hl_mid", cx, h * 0.04, left <= 3 and GOLD or color_white)
		else
			Text(mine and "PASS IT ON: roll clean on flat ground" or (string.upper(who) .. " IS PASSING IT ON"), "skategm_hl_mid", cx, h * 0.04, GOLD)
		end
		local nextUp = st.nextUp and C.NameOf(st, st.nextUp)
		if nextUp then Text("next: " .. nextUp, "skategm_hl_small", cx, h * 0.04 + line, GREY) end
		if mine then C.SpeedBar(w, h, C.speed or 0, st.minSpeed or 0) end
	elseif st.phase == "results" and st.over then
		Text(REASONS[st.over.reason] or "LINE OVER", "skategm_hl_big", cx, h * 0.14, RED)
		if st.over.name then Text(st.over.name, "skategm_hl_mid", cx, h * 0.14 + line * 1.8, color_white) end
		Text(string.format("%s points, %d handover%s, %.1f s", Commas(st.total or 0), st.passes or 0, st.passes == 1 and "" or "s", st.lineTime or 0), "skategm_hl_mid", cx, h * 0.14 + line * 3, GOLD)
		if st.best then Text(string.format("best line: %s points, %d handovers", Commas(st.best.total or 0), st.best.passes or 0), "skategm_hl_small", cx, h * 0.14 + line * 4.2, GREY) end
	end
	if PLAYING[st.phase] then
		local x, y = w * 0.98, h * 0.3
		Text("TEAM LINE", "skategm_hl_small", x, y, BLUE, TEXT_ALIGN_RIGHT)
		y = y + line * 0.9
		local total = (st.total or 0) + ((mine and st.phase == "riding") and (C.score or 0) or 0)
		Text(Commas(total) .. " points", "skategm_hl_mid", x, y, color_white, TEXT_ALIGN_RIGHT)
		y = y + line * 1.1
		Text(string.format("%d handover%s", st.passes or 0, st.passes == 1 and "" or "s"), "skategm_hl_small", x, y, GREY, TEXT_ALIGN_RIGHT)
	end
end
hook.Add("HUDPaint", "skategm_holdline", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

hook.Add("PostDrawTranslucentRenderables", "skategm_holdline", function(depth, sky)
	local st = C.state
	if depth or sky or not st.start or not (st.phase == "lobby" or st.phase == "countdown") then return end
	render.SetColorMaterial()
	render.DrawBox(V(st.start), angle_zero, Vector(-2, -2, 0), Vector(2, 2, 64), Color(BLUE.r, BLUE.g, BLUE.b, 160))
end)

---------------------------------------------------------------------------
-- host menu
---------------------------------------------------------------------------
local speeds = {}
for _, s in ipairs(HL.SPEEDS) do speeds[#speeds + 1] = { s[1], s[2] } end
HL.mode:LobbyLines(function(st)
	local min = "off"
	for _, s in ipairs(HL.SPEEDS) do if s[1] == st.minSpeed then min = string.lower(s[2]) end end
	return { string.format("%d s each, then the next takes over; keep moving: %s", st.turnTime or HL.TURN_DEFAULT, min), "one bail ends the line for everyone" }
end)
HL.mode:Host({
	description = "take turns controlling one skater",
	about = "Everyone shares one skater. Each player controls it for a while, then the next player takes over exactly where it is. A bail or stopping ends the line for everyone. Keep it going as long as you can.",
	options = {
		{ key = "turnTime", label = "Each skater's turn", type = "number", min = HL.TURN_MIN, max = HL.TURN_MAX, step = 1, default = HL.TURN_DEFAULT, format = function(v) return v .. " s" end },
		{ key = "minSpeed", label = "Keep moving", type = "choice", choices = speeds, default = HL.SPEED_DEFAULT },
	},
	start = function(v, mode) mode:Send({ cmd = "create", turnTime = v.turnTime, minSpeed = v.minSpeed, canSkate = CanSkate() }) end,
})
