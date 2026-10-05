-- Melon King, client: follows the server's game, grabs and steals the melon
-- when you skate into it, drops it when you bail, and draws the melon, the
-- area and the clocks. Uses only SkateGM.API (and the board's effects for
-- the Melon King's trail).
local C = { state = { phase = "idle" } }
MELON.client = C

local API = SKATEGM_MODES.API
local function Send(t) MELON.mode:Send(t) end
C.Send = Send
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) MELON.mode:Say(text, bad) end
local Here = SKATEGM_MODES.Here

function C.Me(st) return MELON.mode:Me(st) end
function C.IsHost(st) return MELON.mode:IsHost(st) end
function C.IsKing(st) return st.king ~= nil and st.king == LocalPlayer():EntIndex() end
function C.NameOf(st, ent)
	for _, p in ipairs(st.players or {}) do if p.ent == ent then return p.name end end
	return "?"
end

function C.SkaterOf(ent)
	local a = API()
	if not a then return nil end
	if ent == LocalPlayer():EntIndex() then return a.SkaterPos and a.SkaterPos() end
	local ply = Entity(ent)
	local P = IsValid(ply) and a.PoseOf(ply)
	return P and P.HIPS or nil
end

function C.MelonPos(st)
	local e = st.melon and Entity(st.melon)
	if IsValid(e) then return e:GetPos() end
end

-- my time with the melon so far (the King's runs on between server updates)
function C.Held(st, p, now)
	local held = p.held or 0
	if st.phase == "playing" and p.ent == st.king and MELON.InArea(st.area, C.SkaterOf(p.ent)) then
		held = held + (now - (C.stateAt or now))
	end
	return math.min(held, st.target or MELON.TARGET_DEFAULT)
end

local PLAYING = { countdown = true, playing = true }

---------------------------------------------------------------------------
-- following the server
---------------------------------------------------------------------------
function C.SetTrail(kingEnt)
	local fx = BOARD and BOARD.client and BOARD.client.Force
	if not fx then return end
	if C.trailOn and C.trailOn ~= kingEnt then
		local old = Entity(C.trailOn)
		if IsValid(old) then fx(old, "trails", nil) end
		C.trailOn = nil
	end
	if kingEnt and C.trailOn ~= kingEnt then
		local ply = Entity(kingEnt)
		if IsValid(ply) then fx(ply, "trails", MELON.TRAIL) C.trailOn = kingEnt end
	end
end

function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	st.startV = st.start and Vector(st.start[1], st.start[2], st.start[3]) or nil
	local me, a = C.Me(st), API()
	if a and a.SetPlayerCollision then
		if me and PLAYING[st.phase] then a.SetPlayerCollision(false) else a.SetPlayerCollision(nil) end
	end
	C.SetTrail(st.phase == "playing" and st.king or nil)
	if st.king ~= prev.king then C.bailSent = nil end
	C.kingAt = st.king and (now - (st.kingFor or 0)) or nil
	if not me then C.switchedOn = nil return end
	if not C.switchedOn and a and not a.IsSkating() then
		C.switchedOn = true
		a.StartSkating()
	end
	if st.phase == "countdown" and prev.phase ~= "countdown" and not me.playing then
		Say("you weren't in Skater mode in time: this one's without you", true)
	end
	if st.phase == "playing" and prev.phase ~= "playing" then C.goAt = now end
end
MELON.mode:OnState(function(st, now) C.OnState(st, now) end)

---------------------------------------------------------------------------
-- touching it: what my game sends
---------------------------------------------------------------------------
function C.Bailing(state) return type(state) == "string" and state:find("Wipeout", 1, true) ~= nil end

-- what I should ask the server for right now, if anything
function C.Want(st, now)
	if st.phase ~= "playing" then return nil end
	local me = C.Me(st)
	if not (me and me.playing) then return nil end
	local a = API()
	local mine = C.SkaterOf(LocalPlayer():EntIndex())
	if not (a and mine) then return nil end
	if C.IsKing(st) then
		if C.Bailing(a.State and a.State()) and now - (C.bailSent or -10) > 1 then return { cmd = "bail", pos = { mine.x, mine.y, mine.z } } end
		return nil
	end
	if st.king then
		if now - (C.kingAt or now) < MELON.HOLD_GRACE then return nil end
		if st.from == LocalPlayer():EntIndex() and now - (C.kingAt or now) < MELON.NO_TAGBACK then return nil end
		local k = C.SkaterOf(st.king)
		if k and k:Distance(mine) <= MELON.STEAL_RADIUS then return { cmd = "steal", target = st.king } end
		return nil
	end
	local m = C.MelonPos(st)
	if not m then return nil end
	if st.dropper == LocalPlayer():EntIndex() and (st.dropLock or 0) - (now - (C.stateAt or now)) > 0 then return nil end
	if m:Distance(mine) <= MELON.GRAB_RADIUS then return { cmd = "grab" } end
end

function C.Think(now)
	local st, a = C.state, API()
	local me = C.Me(st)
	MELON.mode:HoldAtStart(me ~= nil and me.playing and st.phase == "countdown", st.startV, st.yaw, now)
	if not me or not a or not me.playing then return end
	if st.phase == "playing" and st.startV and not C.launched then
		C.launched = true
		a.TeleportTo(st.startV, st.yaw)
	end
	if st.phase ~= "playing" then C.launched = nil return end
	if now >= (C.nextSend or 0) then
		local want = C.Want(st, now)
		if want then
			C.nextSend = now + 0.25
			if want.cmd == "bail" then C.bailSent = now end
			Send(want)
		end
	end
end
hook.Add("Think", "skategm_melon", function() C.Think(RealTime()) end)

---------------------------------------------------------------------------
-- in the world: the melon over the King's head, a beacon on a loose one,
-- and the edge of the area
---------------------------------------------------------------------------
local glow
function C.CrownMelon()
	if IsValid(C.crown) then return C.crown end
	if not ClientsideModel then return nil end
	C.crown = ClientsideModel(MELON.MODEL, RENDERGROUP_OPAQUE)
	if IsValid(C.crown) then C.crown:SetNoDraw(true) end
	return C.crown
end

local GREEN = Color(90, 230, 90)
function C.DrawWorld()
	local st = C.state
	if st.phase == "idle" then return end
	local now = RealTime()
	render.SetColorMaterial()
	if st.area then
		local a = st.area
		SKATEGM_MODES.AreaWall(Vector(a[1], a[2], a[3]), a[4], Color(GREEN.r, GREEN.g, GREEN.b))
	end
	if st.phase ~= "playing" then return end
	glow = glow or (Material and Material("sprites/light_glow02_add"))
	if st.king then
		local pos = C.SkaterOf(st.king)
		local m = pos and C.CrownMelon()
		if m then
			m:SetPos(pos + Vector(0, 0, 44 + 3 * math.sin(now * 3)))
			m:SetAngles(Angle(0, now * 90 % 360, 15))
			m:DrawModel()
			if glow then
				render.SetMaterial(glow)
				render.DrawSprite(pos + Vector(0, 0, 44), 40, 40, Color(120, 255, 120, 120))
			end
		end
	else
		local m = C.MelonPos(st)
		if m and glow then
			render.SetMaterial(glow)
			local pulse = 0.5 + 0.5 * math.sin(now * 4)
			render.DrawSprite(m, 48 + 24 * pulse, 48 + 24 * pulse, Color(120, 255, 120, 200))
			render.SetColorMaterial()
			render.DrawBeam(m, m + Vector(0, 0, 600), 6, 0, 1, Color(120, 255, 120, 90 + 60 * pulse))
		end
	end
end
hook.Add("PostDrawTranslucentRenderables", "skategm_melon", function(depth, sky) if not (depth or sky) then C.DrawWorld() end end)

---------------------------------------------------------------------------
-- on screen
---------------------------------------------------------------------------
local FONTS = {
	skategm_melon_big = { "Roboto", 0.07, 900, 24 },
	skategm_melon_mid = { "Roboto", 0.03, 700, 16 },
	skategm_melon_small = { "Roboto", 0.02, 600, 12 },
}
local function Fonts() MELON.mode:Fonts(FONTS) end
local Text = SKATEGM_MODES.Text
local GREY = Color(170, 170, 170)

function C.Standings(st, now)
	local rows = {}
	for _, p in ipairs(st.players or {}) do
		if p.playing then rows[#rows + 1] = { ent = p.ent, name = p.name, left = (st.target or 0) - C.Held(st, p, now) } end
	end
	table.sort(rows, function(a, b) if a.left ~= b.left then return a.left < b.left end return a.name < b.name end)
	return rows
end

function C.Paint(w, h, now)
	local st = C.state
	if st.phase == "idle" then return end
	Fonts()
	local me = C.Me(st)
	local since = now - (C.stateAt or now)
	if st.phase == "lobby" then
		Text("MELON KING", "skategm_melon_mid", w / 2, h * 0.04, GREEN)
		local line = C.IsHost(st) and "you're the host: LB + D-pad left to start" or (me and "waiting for the host to start" or "LB + D-pad left to join")
		Text(line, "skategm_melon_small", w / 2, h * 0.04 + h * 0.035, color_white)
		return
	end
	if st.phase == "countdown" then
		Text(tostring(math.max(1, math.ceil((st.timeLeft or 0) - since))), "skategm_melon_big", w / 2, h * 0.3, color_white)
	elseif st.phase == "playing" then
		if C.IsKing(st) then
			local mine = me and (st.target - C.Held(st, me, now)) or 0
			Text("YOU ARE THE MELON KING", "skategm_melon_big", w / 2, h * 0.06, GREEN)
			Text(MELON.Clock(mine) .. " s to go", "skategm_melon_mid", w / 2, h * 0.06 + h * 0.08, color_white)
			if not MELON.InArea(st.area, C.SkaterOf(st.king)) then Text("outside the area: your clock is stopped", "skategm_melon_small", w / 2, h * 0.06 + h * 0.12, Color(255, 180, 120)) end
		elseif st.king then
			Text(string.upper(C.NameOf(st, st.king)) .. " HAS THE MELON", "skategm_melon_mid", w / 2, h * 0.05, GREEN)
			Text("skate into them to take it", "skategm_melon_small", w / 2, h * 0.05 + h * 0.04, color_white)
		elseif st.dropIn and st.dropIn - since > 0 then
			Text(string.format("the melon drops in %d...", math.max(1, math.ceil(st.dropIn - since))), "skategm_melon_mid", w / 2, h * 0.05, GREEN)
		else
			Text("THE MELON IS LOOSE!", "skategm_melon_mid", w / 2, h * 0.05, GREEN)
		end
	elseif st.phase == "results" then
		Text(st.winner and (string.upper(st.winner.name) .. " IS THE MELON KING") or "NOBODY WON", "skategm_melon_big", w / 2, h * 0.12, GREEN)
	end
	local x, y = w - w * 0.02, h * 0.3
	for _, r in ipairs(C.Standings(st, now)) do
		Text(string.format("%s  %s", r.name, MELON.Clock(r.left)), "skategm_melon_small", x, y, r.ent == st.king and GREEN or color_white, TEXT_ALIGN_RIGHT)
		y = y + h * 0.028
	end
end
hook.Add("HUDPaint", "skategm_melon", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

---------------------------------------------------------------------------
-- console, chat and the spawn menu (Utilities > SkateGM > Game modes > Melon King)
---------------------------------------------------------------------------
local cvTarget = CreateClientConVar("skategm_melon_pref_target", tostring(MELON.TARGET_DEFAULT), true, false, "Melon King: seconds with the melon to win, in games you host", MELON.TARGET_MIN, MELON.TARGET_MAX)
local cvArea = CreateClientConVar("skategm_melon_pref_area", tostring(MELON.AREA_DEFAULT), true, false, "Melon King: play area radius (units), in games you host", MELON.AREA_MIN, MELON.AREA_MAX)
local function Num(cv, default) local v = cv.GetInt and cv:GetInt() or tonumber(cv:GetString()) return v or default end

function C.Create(centre, radius, target)
	local p = Here()
	local c = centre or p
	Send({ cmd = "create", pos = { p.x, p.y, p.z }, centre = { c.x, c.y, c.z }, yaw = LocalPlayer():EyeAngles().y,
		radius = radius or Num(cvArea, MELON.AREA_DEFAULT), target = target or Num(cvTarget, MELON.TARGET_DEFAULT), canSkate = CanSkate() })
end
function C.Settings(target, radius) Send({ cmd = "settings", target = target or Num(cvTarget, MELON.TARGET_DEFAULT), radius = radius or Num(cvArea, MELON.AREA_DEFAULT) }) end

concommand.Add("skategm_melon_create", function() C.Create() end, nil, "Melon King: set up a game here (the area is around you)")
concommand.Add("skategm_melon_join", function() Send({ cmd = "join", canSkate = CanSkate() }) end)
concommand.Add("skategm_melon_leave", function() Send({ cmd = "leave" }) end)
concommand.Add("skategm_melon_start", function() Send({ cmd = "begin" }) end)
concommand.Add("skategm_melon_stop", function() Send({ cmd = "stop" }) end)
concommand.Add("skategm_melon_target", function(_, _, args) C.Settings(tonumber(args[1]), nil) end)
concommand.Add("skategm_melon_area", function(_, _, args) C.Settings(nil, tonumber(args[1])) end)

local CHAT = { create = "skategm_melon_create", join = "skategm_melon_join", leave = "skategm_melon_leave", start = "skategm_melon_start",
	stop = "skategm_melon_stop", target = "skategm_melon_target", area = "skategm_melon_area" }
C.Chat = MELON.mode:ChatCommands(CHAT, "create, join, leave, start, stop, target N, area N")

MELON.mode:Host({
	description = "hold the melon the longest; skate into the King to take it",
	options = {
		{ key = "area", label = "Play area", type = "region", min = MELON.AREA_MIN, max = MELON.AREA_MAX, step = 128, default = MELON.AREA_DEFAULT, format = function(v) return (v * 2) .. " units across" end },
		{ key = "target", label = "Time to win", type = "number", min = MELON.TARGET_MIN, max = MELON.TARGET_MAX, step = 5, default = MELON.TARGET_DEFAULT, format = function(v) return v .. " s" end },
	},
	start = function(v) C.Create(v.area.centre, v.area.radius, v.target) end,
})
