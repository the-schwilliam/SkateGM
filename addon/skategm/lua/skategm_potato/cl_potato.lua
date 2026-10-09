-- Hot Potato, client: follows the server's game, passes the bomb when you
-- skate into someone, and draws the bomb, the ticking and the blast. Uses
-- only SkateGM.API.
local C = { state = { phase = "idle" } }
POTATO.client = C

local API = SKATEGM_MODES.API
local function Send(t) POTATO.mode:Send(t) end
C.Send = Send
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) POTATO.mode:Say(text, bad) end

-- where I am, for placing the start: my skater if skating, else me
local Here = SKATEGM_MODES.Here

function C.Me(st) return POTATO.mode:Me(st) end
function C.IsHost(st) return POTATO.mode:IsHost(st) end
function C.IsHolder(st) return st.holder ~= nil and st.holder == LocalPlayer():EntIndex() end
function C.NameOf(st, ent)
	for _, p in ipairs(st.players or {}) do if p.ent == ent then return p.name end end
	return "?"
end

-- a skater's position: mine, or another player's as their pose arrives
function C.SkaterOf(ent)
	local a = API()
	if not a then return nil end
	if ent == LocalPlayer():EntIndex() then return a.SkaterPos and a.SkaterPos() end
	local ply = Entity(ent)
	local P = IsValid(ply) and a.PoseOf(ply)
	return P and P.HIPS or nil
end

local PLAYING = { countdown = true, playing = true }

---------------------------------------------------------------------------
-- following the server
---------------------------------------------------------------------------
function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	st.startV = st.start and Vector(st.start[1], st.start[2], st.start[3]) or nil
	local me, a = C.Me(st), API()
	-- knocked out: watching the rest, out of sight and out of the way
	local out = (me and me.out and st.phase ~= "idle" and st.phase ~= "results") or false
	if a and a.SetHidden then a.SetHidden("potato", out) end
	POTATO.mode:Spectate(out and SKATEGM_MODES.Others(st, function(p) return p.playing and not p.out end) or nil)
	-- other skaters aren't solid while we play: a bump is just being close
	POTATO.mode:NoCollide(me and PLAYING[st.phase])
	-- the bomb changed hands: a fresh hold, as far as passing goes
	if st.holder ~= prev.holder or st.from ~= prev.from then C.holdingSince = now end
	-- a blast: everyone sees it; if it was me, I go flying
	if st.boom and st.boom.id ~= (prev.boom and prev.boom.id) and st.boom.id ~= C.lastBoom then
		C.lastBoom = st.boom.id
		C.Blast(st.boom.ent, now)
	end
	if not me then C.switchedOn = nil return end
	-- in the game: into Skater mode now, so I'm loaded when the host starts it
	if not C.switchedOn and a and not a.IsSkating() then
		C.switchedOn = true
		a.StartSkating()
	end
	if st.phase == "countdown" and prev.phase ~= "countdown" and not me.playing then
		Say("you weren't in Skater mode in time: this one's without you", true)
	end
	if st.phase == "playing" and prev.phase ~= "playing" then C.goAt = now end
end

POTATO.mode:OnState(function(st, now) C.OnState(st, now) end)

-- the explosion, at whoever was holding it
function C.Blast(ent, now)
	local a = API()
	local pos = C.SkaterOf(ent)
	if pos and util and util.Effect and EffectData then
		local fx = EffectData()
		fx:SetOrigin(pos)
		util.Effect("Explosion", fx)
	end
	if ent == LocalPlayer():EntIndex() and a and a.Launch then
		-- sky-high, and a little sideways so it's never the same twice
		a.Launch(Vector((math.random() - 0.5) * 12, (math.random() - 0.5) * 12, 22))
	end
	C.blastAt, C.blastEnt = now, ent
end

---------------------------------------------------------------------------
-- holding it: pass it on by skating into someone
---------------------------------------------------------------------------
-- who I'd pass it to now: the nearest player still in, close enough
function C.PassTarget(st, now)
	if st.phase ~= "playing" or not C.IsHolder(st) then return nil end
	if now - (C.holdingSince or now) < POTATO.HOLD_GRACE then return nil end
	local mine = C.SkaterOf(LocalPlayer():EntIndex())
	if not mine then return nil end
	local best, bestD
	for _, p in ipairs(st.players or {}) do
		if p.ent ~= LocalPlayer():EntIndex() and p.playing and not p.out
			and not (p.ent == st.from and now - (C.holdingSince or now) < POTATO.NO_TAGBACK) then
			local pos = C.SkaterOf(p.ent)
			local d = pos and pos:Distance(mine)
			if d and d <= POTATO.PASS_RADIUS and (not bestD or d < bestD) then best, bestD = p.ent, d end
		end
	end
	return best
end

function C.Think(now)
	local st, a = C.state, API()
	local me = C.Me(st)
	-- the ticking, for everyone watching: faster as the fuse burns down
	if st.phase == "playing" and st.holder and st.fuseLen then
		local left = (st.ticking or 1) - (now - (C.stateAt or now)) / st.fuseLen
		if now >= (C.nextBeep or 0) then
			C.nextBeep = now + POTATO.BeepGap(left)
			local pos = C.SkaterOf(st.holder)
			if C.IsHolder(st) and surface and surface.PlaySound then
				surface.PlaySound("buttons/blip1.wav")
			elseif pos and sound and sound.Play then
				sound.Play("buttons/blip1.wav", pos, 70, 100 + math.floor((1 - math.Clamp(left, 0, 1)) * 60), 0.7)
			end
		end
	end
	POTATO.mode:HoldAtStart(me ~= nil and me.playing and st.phase == "countdown", st.startV, st.yaw, now)
	if not me or not a or not me.playing then return end
	if st.phase == "playing" and st.startV and not C.launched then
		C.launched = true
		a.TeleportTo(st.startV, st.yaw)
	end
	if st.phase ~= "playing" then C.launched = nil return end
	if now >= (C.nextPass or 0) then
		local target = C.PassTarget(st, now)
		if target then
			C.nextPass = now + 0.25
			Send({ cmd = "pass", target = target })
		end
	end
end
hook.Add("Think", "skategm_potato", function() C.Think(RealTime()) end)

---------------------------------------------------------------------------
-- in the world: the bomb over the holder's head, and a ring at their feet
---------------------------------------------------------------------------
local glow
function C.DrawWorld()
	local st = C.state
	if st.phase == "idle" then return end
	local now = RealTime()
	render.SetColorMaterial()
	if st.phase == "playing" and st.holder then
		local pos = SKATEGM_MODES.DrawnHips(st.holder) or C.SkaterOf(st.holder)
		if pos then
			local left = math.Clamp((st.ticking or 1) - (now - (C.stateAt or now)) / (st.fuseLen or 30), 0, 1)
			local rate = 3 + (1 - left) * 18
			local pulse = 0.5 + 0.5 * math.sin(now * rate)
			local bomb = pos + Vector(0, 0, 46)
			render.DrawSphere(bomb, 7, 12, 12, Color(25, 25, 25))
			render.DrawBox(bomb + Vector(0, 0, 6), angle_zero, Vector(-0.6, -0.6, 0), Vector(0.6, 0.6, 5), Color(160, 140, 100))
			if not glow and Material then glow = Material("sprites/light_glow02_add") end
			if glow then
				render.SetMaterial(glow)
				render.DrawSprite(bomb + Vector(0, 0, 12), 10 + 6 * pulse, 10 + 6 * pulse, Color(255, 170, 60))
				render.SetColorMaterial()
			end
			local ring = Color(255, 60, 40, 120 + 135 * pulse)
			local foot = pos - Vector(0, 0, 36)
			for i = 0, 23 do
				local a0, a1 = i / 24 * math.pi * 2, (i + 1) / 24 * math.pi * 2
				render.DrawLine(foot + Vector(math.cos(a0), math.sin(a0), 0) * POTATO.PASS_RADIUS, foot + Vector(math.cos(a1), math.sin(a1), 0) * POTATO.PASS_RADIUS, ring, false)
			end
		end
	end
	if st.startV and st.phase == "lobby" then
		render.DrawBox(st.startV, angle_zero, Vector(-2, -2, 0), Vector(2, 2, 64), Color(255, 90, 60, 180))
	end
end
hook.Add("PostDrawTranslucentRenderables", "skategm_potato", function(depth, sky) if not (depth or sky) then C.DrawWorld() end end)

---------------------------------------------------------------------------
-- on screen
---------------------------------------------------------------------------
local FONTS = {
	skategm_potato_big = { "Roboto", 0.07, 900, 24 },
	skategm_potato_mid = { "Roboto", 0.03, 700, 16 },
	skategm_potato_small = { "Roboto", 0.02, 600, 12 },
}
local function Fonts() POTATO.mode:Fonts(FONTS) end
local Text = SKATEGM_MODES.Text
local RED, ORANGE, GREY = Color(255, 70, 50), Color(255, 170, 60), Color(170, 170, 170)

-- still in first (by lives), then who's out
function C.Standings(st)
	local rows = {}
	for _, p in ipairs(st.players or {}) do if p.playing then rows[#rows + 1] = p end end
	table.sort(rows, function(a, b)
		if (a.out or false) ~= (b.out or false) then return not a.out end
		if (a.lives or 0) ~= (b.lives or 0) then return (a.lives or 0) > (b.lives or 0) end
		return (a.name or "") < (b.name or "")
	end)
	return rows
end

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" then return end
	Fonts()
	local me = C.Me(st)
	local since = now - (C.stateAt or now)
	if st.phase == "lobby" then
		return
	end
	if st.phase == "countdown" then
		Text(tostring(math.max(1, math.ceil((st.timeLeft or 0) - since))), "skategm_potato_big", w / 2, h * 0.3, color_white)
	elseif st.phase == "playing" then
		if st.holder then
			if C.IsHolder(st) then
				Text("YOU HAVE THE BOMB", "skategm_potato_big", w / 2, h * 0.08, RED)
				Text("skate into someone to pass it on!", "skategm_potato_mid", w / 2, h * 0.08 + h * 0.08, color_white)
			else
				Text(string.upper(C.NameOf(st, st.holder)) .. " HAS THE BOMB", "skategm_potato_mid", w / 2, h * 0.06, ORANGE)
			end
		elseif st.armIn then
			Text(string.format("the bomb lands on someone in %d...", math.max(1, math.ceil(st.armIn - since))), "skategm_potato_mid", w / 2, h * 0.06, ORANGE)
		end
		if C.blastAt and now - C.blastAt < 2 then
			Text("BOOM! " .. string.upper(C.NameOf(st, C.blastEnt)), "skategm_potato_big", w / 2, h * 0.3, RED)
		end
		if me and me.out then Text("you're out - watch the rest", "skategm_potato_small", w / 2, h * 0.86, GREY) end
	elseif st.phase == "results" then
		Text(st.winner and (string.upper(st.winner.name) .. " SURVIVED!") or "NOBODY SURVIVED", "skategm_potato_big", w / 2, h * 0.12, ORANGE)
	end
	-- who's still in, down the right
	local x, y = w - w * 0.02, h * 0.3
	for _, r in ipairs(C.Standings(st)) do
		local label = r.out and (r.name .. "  out") or string.format("%s  %s", r.name, string.rep("o", r.lives or 0))
		Text(label, "skategm_potato_small", x, y, r.out and GREY or (r.ent == st.holder and RED or color_white), TEXT_ALIGN_RIGHT)
		y = y + h * 0.028
	end
end
hook.Add("HUDPaint", "skategm_potato", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

---------------------------------------------------------------------------
-- console, chat and the spawn menu (Utilities > SkateGM > Game modes > Hot Potato)
---------------------------------------------------------------------------
local cvFuse = CreateClientConVar("skategm_potato_pref_fuse", tostring(POTATO.FUSE_DEFAULT), true, false, "Hot Potato: about how long the fuse burns (seconds) in games you host", POTATO.FUSE_MIN, POTATO.FUSE_MAX)
local cvLives = CreateClientConVar("skategm_potato_pref_lives", tostring(POTATO.LIVES_DEFAULT), true, false, "Hot Potato: lives each in games you host", POTATO.LIVES_MIN, POTATO.LIVES_MAX)
local function Num(cv, default) local v = cv.GetInt and cv:GetInt() or tonumber(cv:GetString()) return v or default end

function C.Create()
	local p = Here()
	Send({ cmd = "create", pos = { p.x, p.y, p.z }, yaw = LocalPlayer():EyeAngles().y, fuse = Num(cvFuse, POTATO.FUSE_DEFAULT), lives = Num(cvLives, POTATO.LIVES_DEFAULT), canSkate = CanSkate() })
end
function C.StartPoint()
	local p = Here()
	Send({ cmd = "startpoint", pos = { p.x, p.y, p.z }, yaw = LocalPlayer():EyeAngles().y })
end
function C.Settings(fuse, lives) Send({ cmd = "settings", fuse = fuse or Num(cvFuse, POTATO.FUSE_DEFAULT), lives = lives or Num(cvLives, POTATO.LIVES_DEFAULT) }) end

concommand.Add("skategm_potato_create", C.Create, nil, "Hot Potato: set up a game here (this is the start)")
concommand.Add("skategm_potato_join", function() Send({ cmd = "join", canSkate = CanSkate() }) end)
concommand.Add("skategm_potato_leave", function() Send({ cmd = "leave" }) end)
concommand.Add("skategm_potato_startpoint", C.StartPoint)
concommand.Add("skategm_potato_start", function() Send({ cmd = "begin" }) end)
concommand.Add("skategm_potato_stop", function() Send({ cmd = "stop" }) end)
concommand.Add("skategm_potato_fuse", function(_, _, args) C.Settings(tonumber(args[1]), nil) end)
concommand.Add("skategm_potato_lives", function(_, _, args) C.Settings(nil, tonumber(args[1])) end)

-- !potato create | join | leave | startpoint | start | stop | fuse N | lives N
local CHAT = { create = "skategm_potato_create", join = "skategm_potato_join", leave = "skategm_potato_leave", startpoint = "skategm_potato_startpoint",
	start = "skategm_potato_start", stop = "skategm_potato_stop", fuse = "skategm_potato_fuse", lives = "skategm_potato_lives" }
C.Chat = POTATO.mode:ChatCommands(CHAT, "create, join, leave, startpoint, start, stop, fuse N, lives N")

POTATO.mode:Host({
	description = "don't be caught with the bomb",
	about = "One player has a ticking bomb. Skate close to someone to pass it. Nobody knows when it will go off. Whoever has it when it blows loses a life, and the last player with lives left wins.",
	options = {
		{ key = "fuse", label = "Fuse", type = "number", min = POTATO.FUSE_MIN, max = POTATO.FUSE_MAX, step = 5, default = POTATO.FUSE_DEFAULT, format = function(v) return "about " .. v .. " s" end },
		{ key = "lives", label = "Lives", type = "number", min = POTATO.LIVES_MIN, max = POTATO.LIVES_MAX, step = 1, default = POTATO.LIVES_DEFAULT },
		{ key = "items", label = "Items", type = "bool", default = false },
	},
	start = function(v, mode)
		mode:Send({ cmd = "create", pos = SKATEGM_MODES.PosTable(SKATEGM_MODES.Here()), yaw = LocalPlayer():EyeAngles().y, fuse = v.fuse, lives = v.lives, items = v.items, canSkate = CanSkate() })
	end,
})
-- keep the menu's status up to date
