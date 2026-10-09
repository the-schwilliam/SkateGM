-- Physics Gun: aimed like the rocket. A blue beam holds the target frozen in
-- place for two seconds, glowing blue.
local HOLD = 2
local B = { beams = {} }

local PHYSGUN = ITEMS.Register({
	id = "physgun", title = "Physics Gun", model = "models/weapons/w_physics.mdl", scale = 1, weight = 1, color = Color(70, 170, 255),
	target = { range = 1800, color = Color(70, 170, 255) },
})

function PHYSGUN.use(arena, ply, m)
	local target = m.targetEnt
	arena:Freeze(target, HOLD)
	arena:Fx({ item = "physgun", from = ply:EntIndex(), to = target:EntIndex(), t = HOLD })
end

local function Hips(ent)
	local a = SkateGM and SkateGM.API
	local ply = Entity(ent)
	local P = a and IsValid(ply) and a.PoseOf and a.PoseOf(ply)
	return P, P and P.HIPS
end

function PHYSGUN.fx(ev, now)
	local _, from = Hips(ev.from)
	if from then sound.Play("weapons/physcannon/physcannon_pickup.wav", from, 80, 100, 1) end
	B.beams[#B.beams + 1] = { from = ev.from, to = ev.to, start = now, t = ev.t or HOLD }
end

local beam, glow
function PHYSGUN.draw(now)
	beam = beam or Material("sprites/physbeama")
	glow = glow or Material("sprites/light_glow02_add")
	for i = #B.beams, 1, -1 do
		local b = B.beams[i]
		local _, from = Hips(b.from)
		local P, to = Hips(b.to)
		if now - b.start > b.t or not (from and to) then
			table.remove(B.beams, i)
		else
			local col = Color(70, 170, 255)
			local start = from + Vector(0, 0, 30)
			render.SetMaterial(beam)
			render.StartBeam(8)
			for k = 0, 7 do
				local f = k / 7
				local p = LerpVector(f, start, to) + Vector(0, 0, math.sin(f * math.pi) * 40 + math.sin(now * 20 + f * 9) * 3)
				render.AddBeam(p, 10, f + now * 3, col)
			end
			render.EndBeam()
			render.SetMaterial(glow)
			local pulse = 0.7 + 0.3 * math.sin(now * 12)
			for _, v in pairs(P) do render.DrawSprite(v, 28 * pulse, 28 * pulse, Color(70, 170, 255, 160)) end
		end
	end
end
