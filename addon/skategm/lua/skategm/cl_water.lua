local S = SkateGM
local L = S.L
local WATER, cvSounds = L.WATER, L.cvSounds

---------------------------------------------------------------------------
-- Water: as in the original game, falling in isn't swimming. Splash, fade out, back to
-- the engine's automatic checkpoint (the last safe spot it recorded), fade in.
---------------------------------------------------------------------------
S.WATER = WATER
local SPLASH = { "ambient/water/water_splash1.wav", "ambient/water/water_splash2.wav", "ambient/water/water_splash3.wav" }
local dryRing = {} -- recent dry, grounded spots: a fallback if the engine can't return

-- S.WaterLevel (set by a map module, e.g. InfMap's flat sea): the height
-- of water that isn't Source water, in Lua's frame, or nil
local function ExtraLevel(p) return S.WaterLevel and p and S.WaterLevel(p) or nil end
local function InWater(p)
	if not p then return false end
	local lvl = ExtraLevel(p)
	if lvl and p.z < lvl then return true end
	return bit.band(util.PointContents(p), CONTENTS_WATER) ~= 0
end

local function Splash(pos, loud)
	-- find the water's surface above the point
	local lvl = ExtraLevel(pos)
	local tr = not lvl and util.TraceLine({ start = pos + Vector(0, 0, 64), endpos = pos, mask = MASK_WATER })
	local at = lvl and Vector(pos.x, pos.y, lvl) or (tr.Hit and tr.HitPos or pos)
	local fx = EffectData()
	fx:SetOrigin(at)
	fx:SetScale(loud and 12 or 8)
	util.Effect("watersplash", fx)
	if cvSounds:GetBool() then sound.Play(SPLASH[math.random(#SPLASH)], at, 80, math.random(90, 105), loud and 1 or 0.8) end
end
S.Splash = Splash

function S.WaterThink(P, state, now)
	S.WaterPlateThink(state, now)
	local hover = S.HoverWanted and S.HoverWanted(LocalPlayer())
	if hover or S.wakes[LocalPlayer()] then S.WakeThink(LocalPlayer(), hover and S.phase == "on" and S.anchor or nil, now, S.P) end
	local board = S.anchor
	local wet = P and P.HIPS and (InWater(board and board + Vector(0, 0, 3)) or InWater(P.HIPS))
	if WATER.state == "dry" then
		if wet then
			WATER.state, WATER.t = "splash", now
			Splash(board or P.HIPS, true)
		elseif P and P.HIPS and state and not string.find(state, "Air", 1, true) and state ~= "WipeoutGround" and RealTime() > (WATER.nextDry or 0) then
			WATER.nextDry = RealTime() + 0.5
			local f, b = P.TRUCK_FRONT, P.TRUCK_BACK
			local yaw = (f and b) and math.deg(math.atan2(f.y - b.y, f.x - b.x)) or 0
			table.insert(dryRing, 1, { pos = Vector(P.HIPS.x, P.HIPS.y, P.HIPS.z), yaw = yaw, t = now })
			while #dryRing > 20 do table.remove(dryRing) end
		end
	elseif WATER.state == "splash" and now - WATER.t > 0.55 then
		-- screen is dark: back to the checkpoint
		WATER.state, WATER.t = "returning", now
		local ok = skategm and skategm.ReturnToCheckpoint and skategm.ReturnToCheckpoint()
		if not ok then WATER.fallback = true end
	elseif WATER.state == "returning" and now - WATER.t > 0.6 then
		if wet or WATER.fallback then
			-- the engine didn't take us out: use a dry spot from a few seconds ago
			for _, d in ipairs(dryRing) do
				if now - d.t > 1.5 and not InWater(d.pos) then
					skategm.Activate(d.pos.x, d.pos.y, d.pos.z - 36, d.yaw)
					break
				end
			end
			WATER.fallback = false
		end
		WATER.state, WATER.t = "fadein", now
	elseif WATER.state == "fadein" and now - WATER.t > 0.5 then
		WATER.state = "dry"
	end
	-- screen fade: dark by the time we return, then back in
	if WATER.state == "splash" then WATER.fade = math.Clamp((now - WATER.t) / 0.5, 0, 1)
	elseif WATER.state == "returning" then WATER.fade = 1
	elseif WATER.state == "fadein" then WATER.fade = 1 - math.Clamp((now - WATER.t) / 0.5, 0, 1)
	else WATER.fade = 0 end
end

-- other skaters: splash when they go in (their own game resets them)
local remoteWet = {}
function S.RemoteWater(key, P)
	local wet = P and P.HIPS and InWater(P.HIPS)
	if wet and not remoteWet[key] then Splash(P.HIPS, false) end
	remoteWet[key] = wet
	local w = P and P.RIGHT_WHEELFRONT and P.LEFT_WHEELFRONT and P.RIGHT_WHEELBACK and P.LEFT_WHEELBACK
	local hover = S.HoverWanted and S.HoverWanted(key)
	if hover or S.wakes[key] then
		S.WakeThink(key, hover and w and (P.RIGHT_WHEELFRONT + P.LEFT_WHEELFRONT + P.RIGHT_WHEELBACK + P.LEFT_WHEELBACK) / 4 or nil, RealTime(), P)
	end
end

---------------------------------------------------------------------------
-- Hoverboard on water: a flat plate at the water's surface under the board,
-- in the moving collision layer (no rebuilds; it follows the board in 512-unit
-- steps). Only while riding: bail or step off and it's gone, so you fall in
-- and the usual splash and return happen.
---------------------------------------------------------------------------
S.WATER_PLATE = "skategm/water_plate"
S.WATER_PLATE_HALF, S.WATER_PLATE_TILE, S.WATER_PLATE_SNAP = 1536, 256, 512
S.WATER_REACH = 1500
S.WATER_LIFT = 1

function S.WaterPlateHull()
	local c = {}
	local h, t = S.WATER_PLATE_HALF, S.WATER_PLATE_TILE
	for x = -h, h - t, t do
		for y = -h, h - t, t do
			for _, v in ipairs({ { x, y }, { x + t, y }, { x + t, y + t }, { x, y }, { x + t, y + t }, { x, y + t } }) do
				c[#c + 1] = v[1] c[#c + 1] = v[2] c[#c + 1] = 0
			end
		end
	end
	return { c }
end

-- the water's surface below p (within reach, nothing solid in between unless
-- it's just under the board, e.g. a beach running into the water), or nil
function S.WaterSurface(p)
	if not p then return nil end
	local lvl = ExtraLevel(p)
	if lvl and p.z > lvl - 4 and p.z - lvl < S.WATER_REACH then
		if p.z - lvl > 64 then
			local solid = util.TraceLine({ start = p + Vector(0, 0, 2), endpos = Vector(p.x, p.y, lvl), mask = MASK_PLAYERSOLID_BRUSHONLY })
			if solid.Hit then return nil end
		end
		return lvl
	end
	local tr = util.TraceLine({ start = p + Vector(0, 0, 64), endpos = p - Vector(0, 0, S.WATER_REACH), mask = MASK_WATER })
	if not tr.Hit or tr.StartSolid or bit.band(tr.Contents or CONTENTS_WATER, CONTENTS_WATER) == 0 then return nil end
	local z = tr.HitPos.z
	if p.z - z > 64 then
		local solid = util.TraceLine({ start = p + Vector(0, 0, 2), endpos = Vector(p.x, p.y, z), mask = MASK_PLAYERSOLID_BRUSHONLY })
		if solid.Hit then return nil end
	end
	return z
end

S.waterPlate = nil
function S.WaterPlateThink(state, now)
	local want = S.phase == "on" and S.HoverWanted and S.HoverWanted(LocalPlayer()) and WATER.state == "dry"
		and state ~= nil and not state:find("Biped", 1, true) and not state:find("Wipeout", 1, true)
	local board = S.anchor
	if not (want and board) then S.waterPlate = nil return end
	if S.waterPlate and now < (S.waterNext or 0) then return end
	S.waterNext = now + 0.1
	local z = S.WaterSurface(board)
	if not z then S.waterPlate = nil return end
	local snap = S.WATER_PLATE_SNAP
	S.waterPlate = { math.floor(board.x / snap + 0.5) * snap, math.floor(board.y / snap + 0.5) * snap, z + S.WATER_LIFT }
end

function S.WaterPlateFeed(centre, list)
	local p = S.waterPlate
	if p then list[#list + 1] = { S.WATER_PLATE, p[1], p[2], p[3], 0, 0, 0 } end
end
S.MoverFeeds = S.MoverFeeds or {}
S.MoverFeeds[#S.MoverFeeds + 1] = S.WaterPlateFeed

---------------------------------------------------------------------------
-- Wakes: the airboat's own (Source SDK 2013 c_vehicle_airboat.cpp, ported
-- as it is; the airboat draws it from C++ for itself only), sized for a
-- board: a 16-point foam trail (effects/splashwake4) widening as it fades
-- over half a second, swirling foam along the board (effects/splashwake1),
-- and spray off the nose (effects/splash1/2 particles)
---------------------------------------------------------------------------
S.WAKE = { points = 16, life = 0.5, size = 0.35, near = 14, spray = 60 }
S.wakes = S.wakes or {}

local function Remap(v, a, b, c, d) return c + (d - c) * (v - a) / (b - a) end
local function RemapClamped(v, a, b, c, d) return Remap(math.Clamp(v, math.min(a, b), math.max(a, b)), a, b, c, d) end
local function SimpleSplineRemap(v, a, b, c, d)
	local t = (v - a) / (b - a)
	t = t * t * (3 - 2 * t)
	return c + (d - c) * t
end

-- the board's direction (back truck to front), flat
local function BoardDir(P)
	local tf, tb = P and P.TRUCK_FRONT, P and P.TRUCK_BACK
	if not (tf and tb) then return nil, 0 end
	local d = Vector(tf.x - tb.x, tf.y - tb.y, 0)
	local len = d:Length()
	if len < 1e-3 then return nil, 0 end
	return d / len, len
end

function S.WakeThink(key, board, now, P)
	local W = S.wakes[key] or { pts = {} }
	S.wakes[key] = W
	local K = S.WAKE
	local dt = now - (W.t or now)
	if board and W.last and dt > 0 then
		local v = (board - W.last) / dt
		v.z = 0
		W.vel = W.vel and (W.vel * 0.7 + v * 0.3) or v
	end
	W.last, W.t = board, now
	if board and (now >= (W.nextTrace or 0) or not W.z) then W.z, W.nextTrace = S.WaterSurface(board), now + 0.1 end
	W.on = board ~= nil and W.z ~= nil and board.z - W.z < K.near and board.z - W.z > -4
	W.board, W.P = board, P
	-- UpdateWake: a point every 0.5 / 16 s once it's moved 2 units
	if W.on and now >= (W.nextPoint or 0) then
		local at = Vector(board.x, board.y, W.z + 2)
		-- (the last point placed, even once it's faded: standing still adds none)
		local last = W.lastPt
		if not last or last.pos:DistToSqr(at) > 4 then
			if #W.pts >= K.points then table.remove(W.pts, 1) end
			local pt = {
				pos = at, die = now + K.life, var = math.Rand(-16, 16) * K.size,
				tex = last and (last.tex + last.pos:Distance(at)) % 1 or 0,
			}
			W.pts[#W.pts + 1] = pt
			W.lastPt = pt
		end
		W.nextPoint = now + K.life / K.points
	end
	if not board then W.vel = nil end
	while W.pts[1] and W.pts[1].die < now do table.remove(W.pts, 1) end
	if #W.pts == 0 and not board then
		if W.emitter then W.emitter:Finish() W.emitter = nil end
		S.wakes[key] = nil
	end
end

-- DrawPontoonSplash: spray particles, 60 a second
function S.WakeSplash(W, origin, dir, speed, dt)
	local K = S.WAKE
	W.splashAcc = (W.splashAcc or 0) + dt * K.spray
	if W.splashAcc < 1 then return 0 end
	if not W.emitter then W.emitter = ParticleEmitter and ParticleEmitter(origin) end
	local em = W.emitter
	if not em then W.splashAcc = 0 return 0 end
	em:SetPos(origin)
	local scale = Remap(speed, 64, 256, 0.75, 1) * K.size * 1.6
	local made = 0
	while W.splashAcc >= 1 do
		W.splashAcc = W.splashAcc - 1
		local off = Vector(math.Rand(-8, 8) * scale, math.Rand(-8, 8) * scale, 0)
		local p = em:Add(math.random(0, 1) == 1 and "effects/splash1" or "effects/splash2", origin + off)
		if p then
			made = made + 1
			p:SetLifeTime(0)
			p:SetDieTime(0.25)
			local v = Vector(math.Rand(-0.4, 0.4), math.Rand(-0.4, 0.4), math.Rand(-0.4, 0.4)) + dir * 5 + Vector(0, 0, 1)
			v:Normalize()
			p:SetVelocity(v * (speed + math.Rand(-128, 128)) * 0.6)
			local ramp = math.Rand(0.75, 1.25)
			p:SetColor(math.min(1, 0.8 * ramp) * 255, math.min(1, 0.8 * ramp) * 255, math.min(1, 0.75 * ramp) * 255)
			local size = math.Rand(8, 16) * scale
			p:SetStartSize(size)
			p:SetEndSize(size * 2)
			p:SetStartAlpha(255)
			p:SetEndAlpha(0)
			p:SetRoll(math.Rand(0, 360))
			p:SetRollDelta(math.Rand(-4, 4))
			p:SetGravity(Vector(0, 0, -600))
		end
	end
	return made
end

local mats = {}
local function Mat(name) mats[name] = mats[name] or Material(name) return mats[name] end

-- DrawPontoonWake: 6 foam quads along the board, randomly turned each frame
function S.DrawPontoonWake(W, start, dir, length, speed, now)
	local K = S.WAKE
	render.SetMaterial(Mat("effects/splashwake1"))
	local steps = 6
	local alpha = RemapClamped(speed, 128, 600, 0.05, 0.25) * 255
	mesh.Begin(MATERIAL_QUADS, steps)
	for i = 0, steps - 1 do
		local o = start + dir * (length / steps * i)
		o = Vector(o.x + math.Rand(-4, 4) * K.size, o.y + math.Rand(-4, 4) * K.size, W.z + 2)
		local scale = (Remap(i, 0, steps - 1, 32, 64) + 8 * math.sin(now * 5 * i)) * K.size
		local yaw = math.rad(math.Rand(0, 360))
		local r = Vector(math.cos(yaw), -math.sin(yaw), 0)
		local u = Vector(math.cos(yaw + math.pi / 2), -math.sin(yaw + math.pi / 2), 0)
		for _, c in ipairs({ { -1, -1, 0, 1 }, { 1, -1, 0, 0 }, { 1, 1, 1, 0 }, { -1, 1, 1, 1 } }) do
			mesh.Color(255, 255, 255, alpha)
			mesh.TexCoord(0, c[3], c[4])
			mesh.Position(o + r * (scale * c[1]) + u * (scale * c[2]))
			mesh.AdvanceVertex()
		end
	end
	mesh.End()
end

-- DrawWake: the trail, one strip from the oldest point to the board
function S.DrawWakeTrail(W, speed, now)
	local K = S.WAKE
	local pts = W.pts
	if #pts < 1 then return 0 end
	local list = {}
	for i, p in ipairs(pts) do list[i] = p end
	if W.on and W.board then
		local last = pts[#pts]
		local cur = Vector(W.board.x, W.board.y, W.z + 2)
		list[#list + 1] = { pos = cur, die = now + K.life, var = 0, tex = (last.tex + cur:Distance(last.pos)) % 1 }
	end
	if #list < 3 then return 0 end
	render.SetMaterial(Mat("effects/splashwake4"))
	local fade = RemapClamped(speed, 128, 600, 0, 1)
	local widthBase = SimpleSplineRemap(math.Clamp(speed, 128, 600), 128, 600, 32, 48) * K.size
	mesh.Begin(MATERIAL_TRIANGLE_STRIP, (#list - 2) * 2)
	for i = 2, #list do
		local p, prev = list[i], list[i - 1]
		local life = RemapClamped(p.die - now, 0, K.life, 0, 1)
		local a = 0.25 * life * fade * 255
		local w = math.max(0, Lerp(life, widthBase * 6, widthBase) + p.var)
		local seg = prev.pos - p.pos
		seg.z = 0
		seg:Normalize()
		local n = seg:Cross(Vector(0, 0, -1))
		mesh.Position(p.pos + n * (w * 0.5)) mesh.Color(255, 255, 255, a) mesh.TexCoord(0, 0, p.tex) mesh.AdvanceVertex()
		mesh.Position(p.pos - n * (w * 0.5)) mesh.Color(255, 255, 255, a) mesh.TexCoord(0, 1, p.tex) mesh.AdvanceVertex()
	end
	mesh.End()
	return #list - 1
end

function S.DrawWakes(now)
	local dt = math.min(FrameTime and FrameTime() or 0, 0.1)
	for _, W in pairs(S.wakes) do
		local speed = W.vel and W.vel:Length() or 0
		if W.on and speed > 128 then
			local dir, len = BoardDir(W.P)
			if dir then
				local nose = W.board + dir * (len * 0.5)
				nose.z = W.z
				local side = Vector(-dir.y, dir.x, 0)
				S.DrawPontoonWake(W, nose + side * 3, -dir, len, speed, now)
				S.DrawPontoonWake(W, nose - side * 3, -dir, len, speed, now)
				W.splashSide = -(W.splashSide or 1)
				local sd = (-dir + side * (W.splashSide * 1.2)):GetNormalized()
				S.WakeSplash(W, nose + side * (W.splashSide * 3), sd, speed, dt)
			end
		end
		S.DrawWakeTrail(W, speed, now)
	end
end
if hook then
	hook.Add("PostDrawTranslucentRenderables", "skategm_wakes", function(depth, sky)
		if depth or sky then return end
		local ok, err = pcall(S.DrawWakes, RealTime())
		if not ok and not S.wakeErr then S.wakeErr = tostring(err) print("[SkateGM] wake: " .. S.wakeErr) end
	end)
end

-- while skating, GMod's own binds (flashlight, reload, use, jump...) are off;
-- these stay usable
local KEEP_BINDS = { "skategm_toggle", "messagemode", "messagemode2", "+showscores", "toggleconsole", "cancelselect",
	"+voicerecord", "+menu", "+menu_context", "jpeg", "screenshot", "gm_showhelp", "gm_showteam", "gm_showspare1", "gm_showspare2" }
hook.Add("PlayerBindPress", "skategm", function(ply, bind, pressed, code)
	if S.phase ~= "on" then return end
	if S.KeyboardUses and S.KeyboardUses(code) then return true end
	local b = string.lower(bind)
	for _, k in ipairs(KEEP_BINDS) do
		if string.find(b, k, 1, true) then return end
	end
	return true
end)
