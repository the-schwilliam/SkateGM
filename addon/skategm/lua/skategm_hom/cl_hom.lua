local C = { state = { phase = "idle" }, injuries = {}, cam = nil }
HOM.client = C

local API = SKATEGM_MODES.API
local CanSkate = SKATEGM_MODES.CanSkate
local Text = SKATEGM_MODES.Text
local function Send(t) HOM.mode:Send(t) end
local function Say(text, bad) HOM.mode:Say(text, bad) end

function C.Me(st) return HOM.mode:Me(st) end
function C.IsHost(st) return HOM.mode:IsHost(st) end
function C.IsMine(st) return st.active and st.active ~= 0 and st.active == LocalPlayer():EntIndex() end
local ACTIVE = { prep = true, countdown = true, turn = true, between = true }

function C.LevelColor(level, a)
	local l = HOM.LEVELS[level]
	if not l then return Color(235, 235, 235, a or 140) end
	return Color(l.color[1], l.color[2], l.color[3], a or 255)
end

function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	local a = API()
	local mine, wasMine = C.IsMine(st), C.IsMine(prev)
	local me = C.Me(st)
	-- someone else's turn: watching them bail, out of sight and out of the way
	local waiting = (me and ACTIVE[st.phase] and not mine and not SKATEGM_MODES.JustDone(st)) or false
	if a and a.SetHidden then a.SetHidden("hom", waiting) end
	HOM.mode:KeepApart(me ~= nil and ACTIVE[st.phase])
	if st.phase == "prep" and mine and not (prev.phase == "prep" and wasMine) then
		C.readyAt, C.card = nil, nil
		if a and not a.IsSkating() and not a.IsLoading() then a.StartSkating() end
		Say("your turn: bail as hard as you can")
	end
	if st.phase == "turn" and mine and not (prev.phase == "turn" and wasMine) then
		C.tracker, C.resultSent, C.injuries, C.card = HOM.NewTracker(st.pain), nil, {}, nil
	end
	if prev.phase == "turn" and wasMine and not (st.phase == "turn" and mine) then
		C.tracker = nil
		C.EndSlowmo()
	end
	HOM.mode:Spectate(waiting and SKATEGM_MODES.Others(st) or nil, { prefer = st.active or (st.last and st.last.ent) })
	local live = st.live and st.live.injuries or {}
	if not mine and #live > (C.liveSeen or 0) then
		for i = (C.liveSeen or 0) + 1, #live do
			local inj = live[i]
			if inj.level >= HOM.BREAK_LEVEL then C.xrayUntil = now + 1.5 end
		end
	end
	C.liveSeen = #live
	if st.phase ~= prev.phase or st.active ~= prev.active then
		C.cam = nil
		if st.phase ~= "turn" then C.liveSeen = 0 end
	end
end

function C.StartSlowmo(now)
	local a = API()
	if a and a.SetTimeScale then a.SetTimeScale(HOM.SLOWMO_SCALE) end
	C.slowUntil = now + HOM.SLOWMO_TIME
end

function C.EndSlowmo()
	local a = API()
	if C.slowUntil and a and a.SetTimeScale then a.SetTimeScale(1) end
	C.slowUntil = nil
end

local function GroundBelow(p)
	if not (util and util.TraceLine) then return nil end
	local tr = util.TraceLine({ start = p, endpos = p - Vector(0, 0, 400), mask = MASK_SOLID_BRUSHONLY })
	return tr.Hit and (p.z - tr.HitPos.z) or 400
end

function C.Think(now)
	local st = C.state
	local a = API()
	local mine = C.IsMine(st)
	local spot = st.spot and Vector(st.spot[1], st.spot[2], st.spot[3]) or nil
	HOM.mode:HoldAtStart(mine and (st.phase == "prep" or st.phase == "countdown") and a ~= nil and a.IsSkating(), spot, st.yaw, now)
	-- (said again every second until the countdown starts: a lost one used
	-- to leave the turn waiting till it timed out)
	if st.phase == "prep" and mine and HOM.mode.holdPlaced and now >= (C.readyAt or 0) then
		C.readyAt = now + 1
		Send({ cmd = "ready" })
	end
	if C.slowUntil and now >= C.slowUntil then C.EndSlowmo() end
	if st.phase ~= "turn" or not mine or not C.tracker or not a then return end
	local P = a.PoseOf and a.PoseOf(LocalPlayer())
	local events = C.tracker:Feed(P, a.Tick and a.Tick(), a.State and a.State(), P and P.HIPS and GroundBelow(P.HIPS), now)
	for _, ev in ipairs(events) do
		if ev.kind == "start" then
			Send({ cmd = "bailing" })
		elseif ev.kind == "injury" then
			C.injuries[ev.part] = ev.level
			local live = HOM.Score(C.tracker.total, C.tracker.levels, C.tracker.air)
			Send({ cmd = "injury", part = ev.part, level = ev.level, score = live })
			C.popups = C.popups or {}
			table.insert(C.popups, 1, { text = string.upper(HOM.LEVELS[ev.level].name) .. "  " .. HOM.PART[ev.part].name, level = ev.level, t = now })
		elseif ev.kind == "break" then
			C.StartSlowmo(now)
			C.xrayUntil = now + HOM.SLOWMO_TIME + 0.4
			if surface and surface.PlaySound then surface.PlaySound(ev.level >= 4 and "physics/body/body_medium_break3.wav" or "physics/body/body_medium_break2.wav") end
		elseif ev.kind == "done" and not C.resultSent then
			C.resultSent = true
			C.card = ev.result
			C.EndSlowmo()
			local r = ev.result
			Send({ cmd = "result", score = r.score, damage = r.damage, air = r.air, bonus = r.bonus, injuries = r.injuries })
		end
	end
end

HOM.mode:OnState(function(st, now) C.OnState(st, now) end)
hook.Add("Think", "skategm_hom", function() C.Think(RealTime()) end)

function C.View(now, skating)
	local st = C.state
	if not ACTIVE[st.phase] or C.IsMine(st) or not C.Me(st) then return nil end
	local a = API()
	if a and a.IsSkating() and not skating then return nil end
	local active = st.active and Entity(st.active)
	local P = a and IsValid(active) and a.PoseOf and a.PoseOf(active) or nil
	if P and P.HIPS then
		local target = P.HIPS + Vector(0, 0, 10)
		local cam = C.cam or {}
		if cam.last then
			local moved = target - cam.last
			moved.z = 0
			if moved:LengthSqr() > 0.25 then cam.dir = LerpVector(0.08, cam.dir or moved:GetNormalized(), moved:GetNormalized()) end
		end
		cam.last = target
		local dir = cam.dir or Angle(0, st.yaw or 0, 0):Forward()
		local want = target - dir:GetNormalized() * 150 + Vector(0, 0, 60)
		cam.pos = cam.pos and LerpVector(0.12, cam.pos, want) or want
		C.cam = cam
		return { origin = cam.pos, angles = (target - cam.pos):Angle(), drawviewer = false }
	elseif st.spot then
		local spot = Vector(st.spot[1], st.spot[2], st.spot[3])
		local pos = spot + Angle(0, (st.yaw or 0) + 180, 0):Forward() * 180 + Vector(0, 0, 90)
		return { origin = pos, angles = (spot - pos):Angle(), drawviewer = false }
	end
end

function C.XrayInjuries()
	if C.IsMine(C.state) then return C.injuries end
	local map = {}
	for _, inj in ipairs(C.state.live and C.state.live.injuries or {}) do map[inj.part] = math.max(map[inj.part] or 0, inj.level) end
	return map
end

function C.DrawXray(P, injuries, alpha)
	cam.IgnoreZ(true)
	render.SetColorMaterial()
	local pulse = 0.7 + 0.3 * math.sin(RealTime() * 12)
	for _, seg in ipairs(HOM.SKELETON) do
		local a, b = P[seg[1]], P[seg[2]]
		if a and b then
			local lv = injuries[HOM.PART_OF_BONE[seg[1]]] or 0
			local col = C.LevelColor(lv, lv > 0 and math.floor(255 * alpha * (lv >= HOM.BREAK_LEVEL and pulse or 1)) or math.floor(110 * alpha))
			render.DrawBeam(a, b, lv >= HOM.BREAK_LEVEL and 2.6 or 1.4, 0, 1, col)
		end
	end
	for bone, part in pairs(HOM.PART_OF_BONE) do
		local v = P[bone]
		local lv = injuries[part] or 0
		if v and lv > 0 then render.DrawSphere(v, lv >= HOM.BREAK_LEVEL and 2.4 or 1.6, 8, 8, C.LevelColor(lv, math.floor(230 * alpha))) end
	end
	cam.IgnoreZ(false)
end

function C.DrawWorld()
	local st = C.state
	if st.phase == "idle" then return end
	if st.spot and (st.phase == "lobby" or st.phase == "prep" or st.phase == "between") then
		SKATEGM_MODES.Ring(Vector(st.spot[1], st.spot[2], st.spot[3] + 3), 48, Color(255, 70, 60, 220), 32)
	end
	local now = RealTime()
	if not (C.xrayUntil and now < C.xrayUntil) then return end
	local a = API()
	local who = C.IsMine(st) and LocalPlayer() or (st.active and Entity(st.active))
	local P = a and IsValid(who) and a.PoseOf and a.PoseOf(who)
	if P then C.DrawXray(P, C.XrayInjuries(), math.Clamp((C.xrayUntil - now) / 0.4, 0, 1)) end
end
hook.Add("PostDrawTranslucentRenderables", "skategm_hom", function(depth, sky) if not (depth or sky) then C.DrawWorld() end end)

local BODY = {
	HEAD = { 0, -92 }, NECK1 = { 0, -80 }, NECK = { 0, -74 }, SPINE3 = { 0, -64 }, SPINE2 = { 0, -50 }, SPINE1 = { 0, -36 }, SPINE = { 0, -24 }, HIPS = { 0, -12 },
	LEFTSHOULDER = { -6, -66 }, LEFTARM = { -20, -64 }, LEFTFOREARM = { -26, -40 }, LEFTHAND = { -30, -18 },
	RIGHTSHOULDER = { 6, -66 }, RIGHTARM = { 20, -64 }, RIGHTFOREARM = { 26, -40 }, RIGHTHAND = { 30, -18 },
	LEFTUPLEG = { -10, -8 }, LEFTLEG = { -12, 28 }, LEFTFOOT = { -13, 62 }, LEFTTOEBASE = { -18, 70 },
	RIGHTUPLEG = { 10, -8 }, RIGHTLEG = { 12, 28 }, RIGHTFOOT = { 13, 62 }, RIGHTTOEBASE = { 18, 70 },
}
function C.DrawBody(x, y, scale, injuries)
	for _, seg in ipairs(HOM.SKELETON) do
		local a, b = BODY[seg[1]], BODY[seg[2]]
		local lv = injuries[HOM.PART_OF_BONE[seg[1]]] or 0
		local col = C.LevelColor(lv, lv > 0 and 255 or 120)
		surface.SetDrawColor(col.r, col.g, col.b, col.a)
		local w = lv >= HOM.BREAK_LEVEL and 3 or 2
		for o = -math.floor(w / 2), math.floor(w / 2) do
			surface.DrawLine(x + a[1] * scale + o, y + a[2] * scale, x + b[1] * scale + o, y + b[2] * scale)
		end
	end
	for bone, part in pairs(HOM.PART_OF_BONE) do
		local lv = injuries[part] or 0
		local p = BODY[bone]
		if p and lv > 0 then
			local col = C.LevelColor(lv)
			draw.RoundedBox(4, x + p[1] * scale - 4, y + p[2] * scale - 4, 8, 8, col)
		end
	end
end

local FONTS = {
	skategm_hom_huge = { "Roboto", 0.075, 900, 26 },
	skategm_hom_big = { "Roboto", 0.045, 900, 20 },
	skategm_hom_mid = { "Roboto", 0.026, 700, 15 },
	skategm_hom_small = { "Roboto", 0.019, 600, 12 },
}
local RED, GREY = Color(255, 70, 60), Color(180, 180, 180)
local CARD_BG = Color(0, 0, 0, 200)

function C.DrawCard(w, h, name, r)
	local cw, ch = w * 0.36, h * 0.5
	local x, y = (w - cw) / 2, h * 0.2
	draw.RoundedBox(12, x, y, cw, ch, CARD_BG)
	Text("HALL OF MEAT", "skategm_hom_big", x + cw / 2, y + h * 0.015, RED)
	Text(name, "skategm_hom_small", x + cw / 2, y + h * 0.065, GREY)
	Text(HOM.Commas(r.score or 0), "skategm_hom_huge", x + cw / 2, y + h * 0.09, color_white)
	local map = {}
	for _, inj in ipairs(r.injuries or {}) do map[inj.part] = inj.level end
	C.DrawBody(x + cw * 0.2, y + ch * 0.58, h * 0.0022, map)
	local ty = y + h * 0.19
	for i, inj in ipairs(r.injuries or {}) do
		if i > 8 then break end
		local lv = HOM.LEVELS[inj.level]
		Text(string.format("%s %s  +%s", string.upper(lv.name), HOM.PART[inj.part].name, HOM.Commas(lv.bonus)), "skategm_hom_small", x + cw * 0.4, ty, C.LevelColor(inj.level), TEXT_ALIGN_LEFT, 1)
		ty = ty + h * 0.026
	end
	ty = math.max(ty, y + h * 0.33)
	Text(string.format("Damage  +%s", HOM.Commas(math.floor((r.damage or 0) * HOM.POINTS_PER_DAMAGE))), "skategm_hom_small", x + cw * 0.4, ty, color_white, TEXT_ALIGN_LEFT, 1)
	Text(string.format("Air %.2f s  +%s", r.air or 0, HOM.Commas(math.floor((r.air or 0) * HOM.POINTS_PER_AIR_SECOND))), "skategm_hom_small", x + cw * 0.4, ty + h * 0.026, color_white, TEXT_ALIGN_LEFT, 1)
end

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" then return end
	HOM.mode:Fonts(FONTS)
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
	local mine = C.IsMine(st)
	local active = st.active and Entity(st.active)
	local activeName = IsValid(active) and active.Nick and active:Nick() or "?"
	if st.phase == "lobby" then
	elseif st.phase == "prep" then
		Text(mine and "your turn: getting you to the spot" or (activeName .. " is up next"), "skategm_hom_mid", w / 2, h * 0.06, RED)
	elseif st.phase == "countdown" then
		Text(tostring(math.max(1, math.ceil(left))), "skategm_hom_huge", w / 2, h * 0.3, RED)
		Text(mine and string.format("start your bail within %d s, then keep it going as long as you can. Y in the air ditches the board", st.turn or HOM.TURN_DEFAULT) or (activeName .. " is about to bail"), "skategm_hom_small", w / 2, h * 0.3 + h * 0.09, color_white)
	elseif st.phase == "turn" then
		if mine and C.card then
			C.DrawCard(w, h, "you", C.card)
		elseif mine then
			local live = C.tracker and HOM.Score(C.tracker.total, C.tracker.levels, C.tracker.air) or 0
			if C.tracker and C.tracker.phase ~= "riding" then
				Text("KEEP IT GOING", "skategm_hom_mid", w / 2, h * 0.04, RED)
				Text(HOM.Commas(live), "skategm_hom_big", w / 2, h * 0.09, color_white)
			else
				Text(string.format("BAIL WITHIN %ds", math.max(0, math.ceil(left))), "skategm_hom_mid", w / 2, h * 0.04, left <= 5 and RED or color_white)
			end
		else
			Text(st.bailing and (activeName .. " is bailing") or string.format("%s: bail within %ds", activeName, math.max(0, math.ceil(left))), "skategm_hom_mid", w / 2, h * 0.04, RED)
			if st.live and (st.live.score or 0) > 0 then Text(HOM.Commas(st.live.score), "skategm_hom_big", w / 2, h * 0.09, color_white) end
		end
		local y = h * 0.62
		for i, pop in ipairs(C.popups or {}) do
			local age = now - pop.t
			if i > 5 or age > 3 then break end
			Text(pop.text, "skategm_hom_mid", w / 2, y + (i - 1) * h * 0.035, C.LevelColor(pop.level, math.floor(255 * math.Clamp(3 - age, 0, 1))))
		end
	elseif st.phase == "between" and st.last then
		C.DrawCard(w, h, st.last.name, st.last)
	elseif st.phase == "final" then
		Text(st.winner and (st.winner.name .. " takes the Hall of Meat") or "nobody bailed", "skategm_hom_big", w / 2, h * 0.22, RED)
		if st.winner then Text(HOM.Commas(st.winner.score), "skategm_hom_huge", w / 2, h * 0.28, color_white) end
	end
	local players = {}
	for _, p in ipairs(st.players or {}) do players[#players + 1] = p end
	table.sort(players, function(a, b) return (a.best or 0) > (b.best or 0) end)
	local y = h * 0.14
	for _, p in ipairs(players) do
		Text(string.format("%s  %s", p.name, HOM.Commas(p.best or 0)), "skategm_hom_small", w * 0.97, y, p.ent == st.active and RED or color_white, TEXT_ALIGN_RIGHT)
		y = y + h * 0.026
	end
end
hook.Add("HUDPaint", "skategm_hom", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

HOM.mode:ChatCommands({})
HOM.mode:JoinInfo(function(st)
	if not st.phase or st.phase == "idle" or st.phase == "final" then return nil end
	local host = st.host and st.host ~= 0 and Entity(st.host)
	local me = C.Me(st)
	return { host = (host and IsValid(host)) and host:Nick() or "someone", phase = st.phase, joinable = me == nil, mine = C.IsHost(st), playing = me ~= nil }
end)
HOM.mode:Host({
	description = "get hurt the most in one bail",
	about = "Take turns bailing as hard as you can. Every bone you hurt adds to your score. The most painful bail wins.",
	options = {
		{ key = "turn", label = "Time to start your bail", type = "number", min = HOM.TURN_MIN, max = HOM.TURN_MAX, step = 5, default = HOM.TURN_DEFAULT, format = function(v) return v .. " s" end },
		{ key = "rounds", label = "Rounds", type = "number", min = HOM.ROUNDS_MIN, max = HOM.ROUNDS_MAX, step = 1, default = HOM.ROUNDS_DEFAULT },
		{ key = "pain", label = "Pain", type = "choice", choices = HOM.PAINS, default = 1 },
	},
	start = function(v, mode)
		-- (everyone bails from where the host stands, facing their way)
		local pos = SKATEGM_MODES.Here()
		local a = SKATEGM_MODES.API()
		local view = a and a.View and a.View()
		local yaw = view and view.angles and view.angles.y or LocalPlayer():EyeAngles().y
		mode:Send({ cmd = "create", x = pos.x, y = pos.y, z = pos.z, yaw = yaw, turn = v.turn, rounds = v.rounds, pain = v.pain, canSkate = CanSkate() })
	end,
})

