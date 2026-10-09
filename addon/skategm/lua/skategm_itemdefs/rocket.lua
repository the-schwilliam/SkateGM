-- Rocket: aimed at the skater nearest the middle of your view (a red box
-- over them); a homing RPG missile that knocks them off.
local SPEED = 1700
local R = { live = {} }

local ROCKET = ITEMS.Register({
	id = "rocket", title = "Rocket", model = "models/weapons/w_rocket_launcher.mdl", scale = 1, weight = 1, color = Color(255, 70, 50),
	target = { range = 4000, color = Color(255, 40, 40) },
})

function ROCKET.use(arena, ply, m)
	local target = m.targetEnt
	local from, to = arena:Pos(ply), arena:Pos(target)
	local flight = math.Clamp(from:Distance(to) / SPEED, 0.3, 3)
	arena:Fx({ item = "rocket", from = ply:EntIndex(), to = target:EntIndex(), t = flight })
	arena:Later(flight, function()
		if arena.closed or not IsValid(target) then return end
		arena:Fx({ item = "rocket", boom = { arena:Pos(target).x, arena:Pos(target).y, arena:Pos(target).z } })
		arena:Hit(target, ply, "rocket")
	end)
end

local function Hips(ent)
	local a = SkateGM and SkateGM.API
	local ply = Entity(ent)
	local P = a and IsValid(ply) and a.PoseOf and a.PoseOf(ply)
	return P and P.HIPS
end

function ROCKET.fx(ev, now)
	if ev.boom then
		local ed = EffectData()
		ed:SetOrigin(Vector(ev.boom[1], ev.boom[2], ev.boom[3]))
		util.Effect("Explosion", ed)
		return
	end
	local from = Hips(ev.from)
	if not from then return end
	sound.Play("weapons/rpg/rocketfire1.wav", from, 80, 100, 1)
	R.live[#R.live + 1] = { from = from + Vector(0, 0, 40), to = ev.to, start = now, t = ev.t or 1 }
end

function ROCKET.draw(now)
	for i = #R.live, 1, -1 do
		local r = R.live[i]
		local k = (now - r.start) / r.t
		local to = Hips(r.to)
		if k >= 1 or not to then
			if IsValid(r.ent) then r.ent:Remove() end
			table.remove(R.live, i)
		else
			if not IsValid(r.ent) then r.ent = ITEMS.client.Model("models/weapons/w_missile_launch.mdl", 1.2) end
			local mid = (r.from + to) / 2 + Vector(0, 0, r.from:Distance(to) * 0.15)
			local a, b = LerpVector(k, r.from, mid), LerpVector(k, mid, to)
			local pos = LerpVector(k, a, b)
			if IsValid(r.ent) then
				r.ent:SetPos(pos)
				r.ent:SetAngles((b - a):Angle())
			end
			render.SetMaterial(Material("sprites/light_glow02_add"))
			render.DrawSprite(pos, 40, 40, Color(255, 160, 60))
		end
	end
end
