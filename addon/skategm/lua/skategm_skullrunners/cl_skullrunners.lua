-- Skull Runners, client: the skulls (floating, turning, glowing), grabbing
-- them, telling the server when I bail, the screens.
local SR = SKULLRUNNERS
local C = { state = { phase = "idle" }, models = {}, tried = {} }
SR.client = C

local API = SKATEGM_MODES.API
local function Send(t) SR.mode:Send(t) end
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) SR.mode:Say(text, bad) end
local Clock = SKATEGM_MODES.Clock
local GREEN, GREY, GOLD = Color(180, 255, 140), Color(190, 190, 190), Color(255, 210, 90)

function C.Me(st) return SR.mode:Me(st) end

SR.mode:Boundary(function(st)
	local me = SR.mode:Me(st)
	if st.phase ~= "playing" or not (me and me.playing) or not st.area then return nil end
	return { area = st.area, pos = C.slot or st.startV, yaw = st.yaw, out = function() Send({ cmd = "bailed" }) end }
end)

function C.SlotPos(st, me)
	if not (st.startV and me and me.slot) then return st.startV end
	local dx, dy = SR.SlotOffset(me.slot, st.slots or 1, st.yaw)
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
	local alive = {}
	local shown = st.phase == "playing" or st.phase == "countdown"
	if not shown then
		for id, m in pairs(C.models) do if IsValid(m) then m:Remove() end C.models[id] = nil end
	end
	for _, k in ipairs(shown and st.skulls or {}) do alive[k[1]] = Vector(k[2], k[3], k[4]) end
	for id, m in pairs(C.models) do
		if not alive[id] then
			if IsValid(m) then
				sound.Play("garrysmod/balloon_pop_cute.wav", m:GetPos(), 70, 120, 0.8)
				m:Remove()
			end
			C.models[id] = nil
		end
	end
	C.skulls = alive
	if st.phase == "results" and prev.phase ~= "results" and st.winners then
		local w = st.winners
		Say(#(w.names or {}) > 0 and (table.concat(w.names, " and ") .. " win with " .. (w.skulls or 0) .. " skulls") or "nobody won")
	end
end
SR.mode:OnState(function(st, now) C.OnState(st, now) end)

function C.Think(now)
	local st, a = C.state, API()
	local me = C.Me(st)
	local playing = me ~= nil and me.playing
	SR.mode:HoldAtStart(playing and st.phase == "countdown", C.slot or st.startV, st.yaw, now)
	if not (a and playing and st.phase == "playing") then C.wasBail = nil return end
	if not C.launched and (C.slot or st.startV) then
		C.launched = true
		a.TeleportTo(C.slot or st.startV, st.yaw)
	end
	local state = a.State and a.State() or ""
	local bail = state:find("Wipeout", 1, true) ~= nil
	if bail and not C.wasBail then Send({ cmd = "bailed" }) end
	C.wasBail = bail
	local pos = a.SkaterPos and a.SkaterPos()
	if not pos then return end
	for id, k in pairs(C.skulls or {}) do
		if pos:Distance(k + Vector(0, 0, SR.FLOAT)) < SR.TOUCH and now >= (C.tried[id] or 0) then
			C.tried[id] = now + 0.5
			Send({ cmd = "grab", id = id })
		end
	end
end
hook.Add("Think", "skategm_skullrunners", function() C.Think(RealTime()) end)

local glow
function C.DrawWorld()
	local st = C.state
	if st.phase == "idle" then return end
	local now = RealTime()
	if st.area and (st.phase == "countdown" or st.phase == "playing" or st.phase == "lobby") then
		SKATEGM_MODES.AreaWall(Vector(st.area[1], st.area[2], st.area[3]), st.area[4], Color(GREEN.r, GREEN.g, GREEN.b))
	end
	if st.phase ~= "playing" and st.phase ~= "countdown" then return end
	glow = glow or Material("sprites/light_glow02_add")
	for id, k in pairs(C.skulls or {}) do
		local m = C.models[id]
		if not IsValid(m) then
			m = ITEMS and ITEMS.client and ITEMS.client.Model("models/Gibs/HGIBS.mdl", 2.6) or ClientsideModel("models/Gibs/HGIBS.mdl")
			C.models[id] = m
		end
		local pos = k + Vector(0, 0, SR.FLOAT + math.sin(now * 2.2 + id) * 5)
		if IsValid(m) then
			m:SetPos(pos)
			m:SetAngles(Angle(0, (now * 80 + id * 31) % 360, 0))
		end
		local pulse = 0.75 + 0.25 * math.sin(now * 4 + id)
		render.SetMaterial(glow)
		render.DrawSprite(pos, 70 * pulse, 70 * pulse, Color(150, 255, 120, 140))
	end
end
hook.Add("PostDrawTranslucentRenderables", "skategm_skullrunners", function(depth, sky) if not (depth or sky) then C.DrawWorld() end end)

local FONTS = {
	skategm_sr_big = { "Coolvetica", 0.06, 500 },
	skategm_sr_mid = { "Coolvetica", 0.03, 500 },
	skategm_sr_small = { "Roboto", 0.018, 700 },
}
local function Text(t, font, x, y, col, ax) SKATEGM_MODES.Text(t, font, x, y, col, ax or TEXT_ALIGN_CENTER, 1) end

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" or st.phase == "lobby" then return end
	local me = C.Me(st)
	if not (me and me.playing) then return end
	SR.mode:Fonts(FONTS)
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
	local line = h * 0.035
	if st.phase == "countdown" then
		Text("SKULL RUNNERS", "skategm_sr_mid", w / 2, h * 0.22, GREEN)
		Text(tostring(math.max(1, math.ceil(left))), "skategm_sr_big", w / 2, h * 0.22 + line * 1.2, color_white)
	elseif st.phase == "playing" then
		Text(string.format("%d SKULLS   %s", me.skulls or 0, Clock(left)), "skategm_sr_mid", w / 2, h * 0.04, left <= 10 and Color(255, 110, 90) or GREEN)
	elseif st.phase == "results" and st.winners then
		local wn = st.winners.names or {}
		Text(#wn > 0 and (string.upper(table.concat(wn, " & ")) .. " WIN" .. (#wn == 1 and "S" or "")) or "NOBODY WON", "skategm_sr_big", w / 2, h * 0.12, GOLD)
	end
	local rows = {}
	for _, p in ipairs(st.players or {}) do if p.playing then rows[#rows + 1] = p end end
	table.sort(rows, function(x, y) return (x.skulls or 0) > (y.skulls or 0) end)
	local x, y = w * 0.98, h * 0.3
	for _, p in ipairs(rows) do
		Text(string.format("%s  %d", p.name, p.skulls or 0), "skategm_sr_small", x, y, color_white, TEXT_ALIGN_RIGHT)
		y = y + line * 0.8
	end
end
hook.Add("HUDPaint", "skategm_skullrunners", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

SR.mode:LobbyLines(function(st)
	return { string.format("%s, %d skulls, area %d", Clock(st.time or SR.TIME_DEFAULT), st.count or SR.SKULLS_DEFAULT, st.area and st.area[4] or 0), st.items and "items on (left stick in)" or "no items" }
end)
SR.mode:Host({
	description = "collect the most skulls",
	about = "Floating skulls fill the arena, so skate through them to collect them. A bail makes you drop some. The most skulls at the end wins.",
	options = {
		{ key = "area", label = "Play area", type = "region", min = SR.AREA_MIN, max = SR.AREA_MAX, step = 128, default = SR.AREA_DEFAULT },
		{ key = "time", label = "Time", type = "number", min = SR.TIME_MIN, max = SR.TIME_MAX, step = 15, default = SR.TIME_DEFAULT, format = function(v) return v .. " s" end },
		{ key = "skulls", label = "Skulls", type = "number", min = SR.SKULLS_MIN, max = SR.SKULLS_MAX, step = 5, default = SR.SKULLS_DEFAULT },
		{ key = "items", label = "Items", type = "bool", default = true },
	},
	start = function(v, mode)
		local c = v.area.centre
		mode:Send({ cmd = "create", centre = { c.x, c.y, c.z }, radius = v.area.radius, time = v.time, skulls = v.skulls, items = v.items, canSkate = CanSkate() })
	end,
})
