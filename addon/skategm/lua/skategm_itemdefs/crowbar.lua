-- Crowbar: three swings. A huge crowbar comes down in front of you and
-- knocks off whoever's there.
local REACH, SPAN, SWING = 120, 0.25, 0.3
local SCALE, HIT_AT = 4, 0.6
local FROM, TO = -25, 115
local GRIP = Vector(13.64, 0.13, -0.34)
local W = { swings = {} }

local CROWBAR = ITEMS.Register({ id = "crowbar", title = "Crowbar", model = "models/weapons/w_crowbar.mdl", scale = 1.4, uses = 3, weight = 1, color = Color(255, 210, 120) })

function CROWBAR.use(arena, ply, m)
	local pos, fwd = arena:Pos(ply), arena:Forward(ply)
	arena:Fx({ item = "crowbar", from = ply:EntIndex(), f = { fwd.x, fwd.y } })
	arena:Later(SWING * 0.6, function()
		if arena.closed then return end
		for _, p in ipairs(arena:Players()) do
			if p ~= ply then
				local d = arena:Pos(p) - pos
				d.z = 0
				if d:Length() < REACH and d:GetNormalized():Dot(fwd) > SPAN then arena:Hit(p, ply, "crowbar") end
			end
		end
	end)
end

function CROWBAR.fx(ev, now)
	local a = SkateGM and SkateGM.API
	local ply = Entity(ev.from)
	local P = a and IsValid(ply) and a.PoseOf and a.PoseOf(ply)
	if not (P and P.HIPS) then return end
	sound.Play("weapons/iceaxe/iceaxe_swing1.wav", P.HIPS, 80, 80, 1)
	W.swings[#W.swings + 1] = { ent = ev.from, start = now, fwd = Vector(ev.f[1], ev.f[2], 0):GetNormalized() }
end

function W.Pose(hips, fwd, k)
	local e = math.min(1, k / HIT_AT)
	local theta = math.rad(FROM + (TO - FROM) * e * e)
	local up = Vector(0, 0, 1)
	local dir = up * math.cos(theta) + fwd * math.sin(theta)
	local side = fwd:Cross(up):GetNormalized()
	local x, y = -dir, -side
	local top = x:Cross(y)
	local ang = x:AngleEx(top)
	local pivot = hips + fwd * 16 + up * 46
	local grip = x * GRIP.x + y * GRIP.y + top * GRIP.z
	return ang, pivot - grip * SCALE, dir
end

CROWBAR.Pose = W.Pose

function CROWBAR.draw(now)
	local a = SkateGM and SkateGM.API
	for i = #W.swings, 1, -1 do
		local s = W.swings[i]
		local k = (now - s.start) / SWING
		local ply = Entity(s.ent)
		local P = a and IsValid(ply) and a.PoseOf and a.PoseOf(ply)
		if k > 1.3 or not (P and P.HIPS) then
			if IsValid(s.model) then s.model:Remove() end
			table.remove(W.swings, i)
		else
			if not IsValid(s.model) then s.model = ITEMS.client.Model("models/weapons/w_crowbar.mdl", SCALE) end
			if IsValid(s.model) then
				local ang, pos = W.Pose(P.HIPS, s.fwd, k)
				s.model:SetAngles(ang)
				s.model:SetPos(pos)
			end
			if k >= HIT_AT and not s.thud then
				s.thud = true
				sound.Play("physics/metal/metal_solid_impact_hard" .. math.random(1, 5) .. ".wav", P.HIPS + s.fwd * 80, 80, 100, 1)
			end
		end
	end
end
