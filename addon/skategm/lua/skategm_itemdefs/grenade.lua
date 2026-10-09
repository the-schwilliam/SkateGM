-- Grenade: thrown straight ahead; it goes off where it lands, when it
-- reaches a skater, or after a few seconds, and knocks off everyone near it.
local THROW, LOB, GRAVITY = 760, 330, 650
local FUSE, NEAR, BLAST = 2.6, 64, 210
local G = { live = {} }

local GRENADE = ITEMS.Register({ id = "grenade", title = "Grenade", model = "models/weapons/w_grenade.mdl", scale = 1.6, weight = 1, color = Color(110, 230, 90) })

-- one step of the flight: the same on server and clients
function GRENADE.Step(g, dt)
	g.vel.z = g.vel.z - GRAVITY * dt
	local next = g.pos + g.vel * dt
	local hit = false
	if util and util.TraceLine then
		local tr = util.TraceLine({ start = g.pos, endpos = next, mask = MASK_SOLID_BRUSHONLY })
		if tr.Hit then
			local n = tr.HitNormal
			g.vel = (g.vel - n * 2 * g.vel:Dot(n)) * 0.45
			next = tr.HitPos + n * 2
			hit = true
		end
	end
	g.pos = next
	return hit
end

function GRENADE.Throw(hips, fwd)
	return hips + Vector(0, 0, 48) + fwd * 24, fwd * THROW + Vector(0, 0, LOB)
end

GRENADE.PREVIEW_STEP, GRENADE.PREVIEW_MAX = 1 / 60, 3
function GRENADE.Predict(hips, fwd)
	local start, vel = GRENADE.Throw(hips, fwd)
	local g = { pos = start, vel = vel }
	local path = { start }
	local t = 0
	while t < GRENADE.PREVIEW_MAX do
		local hit = GRENADE.Step(g, GRENADE.PREVIEW_STEP)
		t = t + GRENADE.PREVIEW_STEP
		path[#path + 1] = g.pos
		if hit then return path, g.pos end
	end
	return path, nil
end

function GRENADE.use(arena, ply, m)
	local fwd = arena:Forward(ply)
	local start, vel = GRENADE.Throw(arena:Pos(ply), fwd)
	local g = { pos = start, vel = vel, born = CurTime(), owner = ply }
	arena.objects.grenades = arena.objects.grenades or {}
	table.insert(arena.objects.grenades, g)
	arena:Fx({ item = "grenade", p = { start.x, start.y, start.z }, v = { g.vel.x, g.vel.y, g.vel.z } })
end

function GRENADE.think(arena, now)
	local list = arena.objects.grenades
	if not list then return end
	for i = #list, 1, -1 do
		local g = list[i]
		local landed = GRENADE.Step(g, FrameTime())
		local boom = landed or now - g.born >= FUSE
		if not boom then
			for _, p in ipairs(arena:Players()) do
				if p ~= g.owner or now - g.born > 0.6 then
					if arena:Pos(p):Distance(g.pos) < NEAR + 30 then boom = true end
				end
			end
		end
		if boom then
			table.remove(list, i)
			arena:Fx({ item = "grenade", boom = { g.pos.x, g.pos.y, g.pos.z } })
			for _, p in ipairs(arena:Players()) do
				if arena:Pos(p):Distance(g.pos) < BLAST then arena:Hit(p, g.owner, "grenade") end
			end
		end
	end
end

function GRENADE.fx(ev, now)
	if ev.boom then
		local pos = Vector(ev.boom[1], ev.boom[2], ev.boom[3])
		local ed = EffectData()
		ed:SetOrigin(pos)
		util.Effect("Explosion", ed)
		local best, bestD
		for i, g in ipairs(G.live) do
			local d = g.pos:Distance(pos)
			if not bestD or d < bestD then best, bestD = i, d end
		end
		if best then
			if IsValid(G.live[best].ent) then G.live[best].ent:Remove() end
			table.remove(G.live, best)
		end
		return
	end
	local pos = Vector(ev.p[1], ev.p[2], ev.p[3])
	sound.Play("weapons/slam/throw.wav", pos, 75, 100, 1)
	G.live[#G.live + 1] = { pos = pos, vel = Vector(ev.v[1], ev.v[2], ev.v[3]), born = now, last = now }
end

local dotMat, ringMat
function GRENADE.aim(now, hips, fwd)
	local path, land = GRENADE.Predict(hips, fwd)
	dotMat = dotMat or Material("sprites/light_glow02_add")
	ringMat = ringMat or Material("trails/laser")
	render.SetMaterial(dotMat)
	local col = Color(110, 230, 90, 200)
	for i = 4, #path, 3 do render.DrawSprite(path[i], 7, 7, col) end
	if not land then return end
	render.SetMaterial(ringMat)
	local pulse = 0.85 + 0.15 * math.sin(now * 6)
	local up = Vector(0, 0, 2)
	for _, r in ipairs({ BLAST * pulse, 18 }) do
		local n = r > 30 and 48 or 16
		local prev
		for i = 0, n do
			local a = i / n * math.pi * 2
			local p = land + up + Vector(math.cos(a) * r, math.sin(a) * r, 0)
			if prev then render.DrawBeam(prev, p, r > 30 and 5 or 4, 0, 1, Color(255, 80, 60, 220)) end
			prev = p
		end
	end
end

function GRENADE.draw(now)
	for i = #G.live, 1, -1 do
		local g = G.live[i]
		local dt = math.min(now - g.last, 0.1)
		g.last = now
		if dt > 0 then GRENADE.Step(g, dt) end
		if now - g.born > FUSE + 1 then
			if IsValid(g.ent) then g.ent:Remove() end
			table.remove(G.live, i)
		else
			if not IsValid(g.ent) then g.ent = ITEMS.client.Model("models/weapons/w_grenade.mdl", 1.6) end
			if IsValid(g.ent) then
				g.ent:SetPos(g.pos)
				g.ent:SetAngles(Angle(now * 400 % 360, now * 200 % 360, 0))
			end
			local blink = math.floor((now - g.born) * (4 + (now - g.born) * 4)) % 2 == 0
			if blink then
				render.SetMaterial(Material("sprites/light_glow02_add"))
				render.DrawSprite(g.pos, 24, 24, Color(255, 40, 40))
			end
		end
	end
end
