-- Traffic Cone: dropped behind you. The next skater to touch it bails, and
-- the cone breaks.
local TOUCH, OWNER_SAFE, LIFE = 42, 1.5, 90
local K = { cones = {} }

local CONE = ITEMS.Register({ id = "cone", title = "Traffic Cone", model = "models/props_junk/TrafficCone001a.mdl", scale = 1, weight = 1, color = Color(255, 150, 40) })

function CONE.use(arena, ply, m)
	local spot = arena:Pos(ply) - arena:Forward(ply) * 56
	local z = SKATEGM_MODES.Ground(spot.x, spot.y, spot.z)
	arena.objects.cones = arena.objects.cones or {}
	arena.nextCone = (arena.nextCone or 0) + 1
	local c = { id = arena.nextCone, pos = Vector(spot.x, spot.y, z), owner = ply, at = CurTime() }
	table.insert(arena.objects.cones, c)
	arena:Fx({ item = "cone", id = c.id, p = { c.pos.x, c.pos.y, c.pos.z } })
end

function CONE.think(arena, now)
	local list = arena.objects.cones
	if not list then return end
	for i = #list, 1, -1 do
		local c = list[i]
		local hit
		for _, p in ipairs(arena:Players()) do
			if (p ~= c.owner or now - c.at > OWNER_SAFE) and arena:Pos(p):Distance(c.pos + Vector(0, 0, 20)) < TOUCH + 24 then hit = p break end
		end
		if hit or now - c.at > LIFE then
			table.remove(list, i)
			arena:Fx({ item = "cone", id = c.id, broken = hit ~= nil })
			if hit then arena:Hit(hit, c.owner, "cone") end
		end
	end
end

local function Key(ev) return tostring(ev.a) .. ":" .. tostring(ev.id) end

function CONE.fx(ev, now)
	if ev.p then
		K.cones[Key(ev)] = { pos = Vector(ev.p[1], ev.p[2], ev.p[3]), arena = ev.a }
		sound.Play("physics/plastic/plastic_box_impact_soft1.wav", K.cones[Key(ev)].pos, 70, 100, 1)
		return
	end
	local c = K.cones[Key(ev)]
	if not c then return end
	if ev.broken then
		sound.Play("physics/plastic/plastic_box_break" .. math.random(1, 2) .. ".wav", c.pos, 80, 100, 1)
		local ed = EffectData()
		ed:SetOrigin(c.pos + Vector(0, 0, 16))
		util.Effect("WheelDust", ed)
	end
	if IsValid(c.ent) then c.ent:Remove() end
	K.cones[Key(ev)] = nil
end

-- the game is over: its cones go with it
function CONE.clear(arena)
	for key, c in pairs(K.cones) do
		if c.arena == arena then
			if IsValid(c.ent) then c.ent:Remove() end
			K.cones[key] = nil
		end
	end
end

function CONE.draw(now)
	for _, c in pairs(K.cones) do
		if not IsValid(c.ent) then
			c.ent = ITEMS.client.Model("models/props_junk/TrafficCone001a.mdl", 1)
			if IsValid(c.ent) then c.ent:SetPos(c.pos + Vector(0, 0, 14)) end
		end
	end
end
