local S = SkateGM
local L = S.L
local H, ROCKET_NOZZLE, ROCKET_Z = L.H, L.ROCKET_NOZZLE, L.ROCKET_Z

---------------------------------------------------------------------------
-- Board (drawn from the SKATEBOARD / truck / wheel bones)
---------------------------------------------------------------------------
local LIGHT = Vector(0.35, 0.25, 0.9):GetNormalized()
local FACES = { { 0, 2, 6, 4 }, { 1, 5, 7, 3 }, { 0, 4, 5, 1 }, { 2, 3, 7, 6 }, { 0, 1, 3, 2 }, { 4, 6, 7, 5 } }
local function Box(pos, ang, mins, maxs, col, light)
	local f, r, u = ang:Forward(), -ang:Right(), ang:Up()
	local v = {}
	for i = 0, 7 do
		local x = bit.band(i, 1) ~= 0 and maxs.x or mins.x
		local y = bit.band(i, 2) ~= 0 and maxs.y or mins.y
		local z = bit.band(i, 4) ~= 0 and maxs.z or mins.z
		v[i] = pos + f * x + r * y + u * z
	end
	for _, fc in ipairs(FACES) do
		local a, b, c, d = v[fc[1]], v[fc[2]], v[fc[3]], v[fc[4]]
		local nrm = (b - a):Cross(c - a):GetNormalized()
		local k = (0.55 + 0.45 * math.max(0, nrm:Dot(LIGHT))) * light
		local sc = Color(math.min(255, col.r * k), math.min(255, col.g * k), math.min(255, col.b * k))
		render.DrawQuad(a, b, c, d, sc)
		render.DrawQuad(d, c, b, a, sc)
	end
end
local WOOD, GRIP, GRAPHIC, METAL, WHEEL = Color(196, 150, 96), Color(32, 32, 34), Color(210, 64, 44), Color(170, 172, 178), Color(238, 236, 222)

-- A modelled board (our own geometry, so free to ship): a popsicle deck with
-- rounded nose and tail, kicktails and concave, grip on top, wood-ply edges and
-- a graphic underneath in the rider's player colour; trucks with round wheels,
-- each drawn at its own truck so steering shows. Built once as meshes (per light
-- level and colour), falling back to the box board if meshes aren't available.
local DECK_HALF, DECK_W, KICK_START, THICK = 16, 4, 10.5, 0.45
local KICK = math.tan(math.rad(18))

local function DeckZ(u, y)
	local a = math.abs(u)
	local kick = 0
	if a > KICK_START then
		local k = a - KICK_START
		kick = k < 1 and k * k * 0.5 * KICK or (k - 0.5) * KICK -- eased into the kick
	end
	local concave = 0.22 * (y / DECK_W) ^ 2 * (a < KICK_START and 1 or 0.4)
	return kick + concave
end
local function DeckHalfWidth(u)
	local a = math.abs(u)
	if a <= DECK_HALF - DECK_W then return DECK_W end
	local t = (a - (DECK_HALF - DECK_W)) / DECK_W
	return DECK_W * math.sqrt(math.max(0, 1 - t * t)) -- round nose / tail
end

-- triangles as { {pos, normal, color} x3 }
local function DeckTriangles(graphic, grip)
	local tris = {}
	local NU, NV = 48, 8
	local GRIPC, WOODC = grip or Color(40, 40, 43), Color(206, 162, 108)
	local WHITE = Color(236, 236, 230)
	local function surf(ui, vi, top)
		local u = -DECK_HALF + (ui / NU) * DECK_HALF * 2
		local w = DeckHalfWidth(u)
		local y = -w + (vi / NV) * 2 * w
		local z = DeckZ(u, y) + (top and THICK or 0)
		return Vector(u, y, z)
	end
	local function colorAt(p, top)
		if top then return GRIPC end
		-- graphic: player colour with a white band and darker tips
		if math.abs(p.x) < 2.2 then return WHITE end
		if math.abs(p.x) > DECK_HALF - 3 then return Color(graphic.r * 0.55, graphic.g * 0.55, graphic.b * 0.55) end
		return graphic
	end
	local function add(a, b, c, col, cols)
		local n = (b - a):Cross(c - a):GetNormalized()
		tris[#tris + 1] = { a, b, c, n, cols or { col, col, col } }
	end
	for ui = 0, NU - 1 do
		for vi = 0, NV - 1 do
			for _, top in ipairs({ true, false }) do
				local a, b, c, d = surf(ui, vi, top), surf(ui + 1, vi, top), surf(ui + 1, vi + 1, top), surf(ui, vi + 1, top)
				local col = colorAt((a + c) / 2, top)
				if top then add(a, b, c, col) add(a, c, d, col) else add(a, c, b, col) add(a, d, c, col) end
			end
		end
		-- edges (the ply): both sides
		for _, side in ipairs({ 0, NV }) do
			local a, b = surf(ui, side, false), surf(ui + 1, side, false)
			local c, d = surf(ui + 1, side, true), surf(ui, side, true)
			if side == 0 then add(a, b, c, WOODC) add(a, c, d, WOODC) else add(a, c, b, WOODC) add(a, d, c, WOODC) end
		end
	end
	return tris
end

-- a truck in its own frame: origin at the axle centre, y along the axle
local function TruckTriangles(wheel)
	local tris = {}
	local METALC, BUSH, WHEELC, CORE = Color(176, 178, 184), Color(226, 190, 60), wheel or Color(238, 236, 222), Color(120, 120, 126)
	local function add(a, b, c, col)
		local n = (b - a):Cross(c - a):GetNormalized()
		tris[#tris + 1] = { a, b, c, n, { col, col, col } }
	end
	local function box(mn, mx, col)
		local v = {}
		for i = 0, 7 do
			v[i] = Vector(bit.band(i, 1) ~= 0 and mx.x or mn.x, bit.band(i, 2) ~= 0 and mx.y or mn.y, bit.band(i, 4) ~= 0 and mx.z or mn.z)
		end
		for _, f in ipairs({ { 0, 2, 3, 1 }, { 4, 5, 7, 6 }, { 0, 1, 5, 4 }, { 2, 6, 7, 3 }, { 0, 4, 6, 2 }, { 1, 3, 7, 5 } }) do
			add(v[f[1]], v[f[2]], v[f[3]], col) add(v[f[1]], v[f[3]], v[f[4]], col)
		end
	end
	-- a cylinder along y
	local function cyl(y0, y1, r, cx, cz, col, capcol, seg)
		seg = seg or 14
		for i = 0, seg - 1 do
			local a0, a1 = i / seg * math.pi * 2, (i + 1) / seg * math.pi * 2
			local p0 = Vector(cx + math.cos(a0) * r, 0, cz + math.sin(a0) * r)
			local p1 = Vector(cx + math.cos(a1) * r, 0, cz + math.sin(a1) * r)
			local A, B = Vector(p0.x, y0, p0.z), Vector(p1.x, y0, p1.z)
			local C, D = Vector(p1.x, y1, p1.z), Vector(p0.x, y1, p0.z)
			add(A, D, C, col) add(A, C, B, col)
			add(Vector(cx, y0, cz), A, B, capcol or col)
			add(Vector(cx, y1, cz), C, D, capcol or col)
		end
	end
	cyl(-3.9, 3.9, 0.16, 0, 0, METALC)                  -- axle
	box(Vector(-0.55, -2.9, -0.35), Vector(0.55, 2.9, 0.45), METALC) -- hanger
	box(Vector(-0.35, -0.5, 0.45), Vector(0.35, 0.5, 1.1), BUSH)     -- bushings / kingpin
	box(Vector(-1.1, -1.3, 1.1), Vector(1.1, 1.3, 1.45), METALC)     -- baseplate (under the deck)
	for _, s in ipairs({ 1, -1 }) do
		local inner, outer = s * 2.6, s * 3.75
		cyl(math.min(inner, outer), math.max(inner, outer), 1.08, 0, 0, WHEELC, CORE, 18) -- wheel
	end
	return tris
end

local function RocketTriangles()
	local tris = {}
	local BODY, NOZZLE, TIP = Color(200, 40, 36), Color(90, 92, 98), Color(235, 235, 230)
	local function add(a, b, c, col)
		local n = (b - a):Cross(c - a):GetNormalized()
		tris[#tris + 1] = { a, b, c, n, { col, col, col } }
	end
	local SEG, Z = 14, ROCKET_Z
	local function ring(x0, r0, x1, r1, col)
		for i = 0, SEG - 1 do
			local a0, a1 = i / SEG * math.pi * 2, (i + 1) / SEG * math.pi * 2
			local p00 = Vector(x0, math.cos(a0) * r0, Z + math.sin(a0) * r0)
			local p01 = Vector(x0, math.cos(a1) * r0, Z + math.sin(a1) * r0)
			local p10 = Vector(x1, math.cos(a0) * r1, Z + math.sin(a0) * r1)
			local p11 = Vector(x1, math.cos(a1) * r1, Z + math.sin(a1) * r1)
			add(p00, p10, p11, col) add(p00, p11, p01, col)
		end
	end
	ring(-9, 0.05, -10.5, 0.9, TIP)
	ring(-10.5, 0.9, -18, 0.9, BODY)
	ring(-18, 0.9, -ROCKET_NOZZLE, 1.25, NOZZLE)
	ring(-ROCKET_NOZZLE, 1.25, -ROCKET_NOZZLE, 0.6, NOZZLE)
	for _, s in ipairs({ 1, -1 }) do
		add(Vector(-15, 0.9 * s, Z), Vector(-18, 0.9 * s, Z), Vector(-18.5, 2.0 * s, Z - 0.4), BODY)
	end
	return tris
end

local UNDER_INSET, UNDER_DROP = 0.03, 0.04
function S.UnderFit(mat)
	local tex = mat.GetTexture and mat:GetTexture("$basetexture")
	local tw, th = tex and tex:Width() or 0, tex and tex:Height() or 0
	if tw <= 0 or th <= 0 then return nil end
	local deck = (DECK_W - UNDER_INSET) / (DECK_HALF - UNDER_INSET)
	local a = tw / th
	if a > deck then return { deck / a, 1 } end
	return { 1, a / deck }
end

local function UnderTriangles(cu, cv)
	local tris = {}
	local NU, NV = 48, 8
	local H, W = DECK_HALF - UNDER_INSET, DECK_W - UNDER_INSET
	cu, cv = cu or 1, cv or 1
	local WHITE = Color(255, 255, 255)
	local function pt(ui, vi)
		local u = -H + (ui / NU) * H * 2
		local w = math.max(0, DeckHalfWidth(u) - UNDER_INSET)
		local y = -w + (vi / NV) * 2 * w
		return Vector(u, y, DeckZ(u, y) - UNDER_DROP), { 0.5 + ((y + W) / (2 * W) - 0.5) * cu, 0.5 + ((H - u) / (2 * H) - 0.5) * cv }
	end
	for ui = 0, NU - 1 do
		for vi = 0, NV - 1 do
			local a, ta = pt(ui, vi)
			local b, tb = pt(ui + 1, vi)
			local c, tc = pt(ui + 1, vi + 1)
			local d, td = pt(ui, vi + 1)
			local n = Vector(0, 0, -1)
			tris[#tris + 1] = { a, c, b, n, { WHITE, WHITE, WHITE }, { ta, tc, tb } }
			tris[#tris + 1] = { a, d, c, n, { WHITE, WHITE, WHITE }, { ta, td, tc } }
		end
	end
	return tris
end

-- the grip's pattern layer: the deck's top a hair above the grip, the
-- pattern tiled 4 times along it (square tiles: the deck is 4 times longer
-- than it is wide)
local TOP_LIFT = 0.03
local function TopTriangles(col)
	local tris = {}
	local NU, NV = 48, 8
	local H, W = DECK_HALF, DECK_W
	local function pt(ui, vi)
		local u = -H + (ui / NU) * H * 2
		local w = DeckHalfWidth(u)
		local y = -w + (vi / NV) * 2 * w
		return Vector(u, y, DeckZ(u, y) + THICK + TOP_LIFT), { (y + W) / (2 * W), (H - u) / (2 * H) * 4 }
	end
	for ui = 0, NU - 1 do
		for vi = 0, NV - 1 do
			local a, ta = pt(ui, vi)
			local b, tb = pt(ui + 1, vi)
			local c, tc = pt(ui + 1, vi + 1)
			local d, td = pt(ui, vi + 1)
			local n = Vector(0, 0, 1)
			tris[#tris + 1] = { a, b, c, n, { col, col, col }, { ta, tb, tc } }
			tris[#tris + 1] = { a, c, d, n, { col, col, col }, { ta, tc, td } }
		end
	end
	return tris
end

local LIGHT_DIR = Vector(0.35, 0.25, 0.9):GetNormalized()
local meshCache = {}
local function BuildMesh(tris, light)
	-- every triangle both ways round, so the board shows from every side
	-- whichever winding the renderer treats as the front
	local m = Mesh()
	mesh.Begin(m, MATERIAL_TRIANGLES, #tris * 2)
	for _, t in ipairs(tris) do
		local k = (0.55 + 0.45 * math.max(0, t[4]:Dot(LIGHT_DIR))) * light
		for _, order in ipairs({ { 1, 2, 3 }, { 1, 3, 2 } }) do
			for _, i in ipairs(order) do
				local c = t[5][i]
				mesh.Position(t[i])
				mesh.Normal(t[4])
				if t[6] then mesh.TexCoord(0, t[6][i][1], t[6][i][2]) end
				mesh.Color(math.min(255, c.r * k), math.min(255, c.g * k), math.min(255, c.b * k), 255)
				mesh.AdvanceVertex()
			end
		end
	end
	mesh.End()
	return m
end
local function CachedMesh(kind, light, col, col2, fit)
	local level = math.Clamp(math.floor(light * 8 + 0.5), 2, 10) -- a few light levels
	local key = kind .. level .. (col and (col.r .. "," .. col.g .. "," .. col.b) or "") .. (col2 and ("/" .. col2.r .. "," .. col2.g .. "," .. col2.b) or "")
		.. (fit and string.format("|%.2f,%.2f", fit[1], fit[2]) or "")
	local m = meshCache[key]
	if m == nil then
		local ok, built = pcall(function()
			local tris = kind == "deck" and DeckTriangles(col, col2) or kind == "under" and UnderTriangles(fit and fit[1], fit and fit[2]) or kind == "top" and TopTriangles(col) or kind == "rocket" and RocketTriangles() or TruckTriangles(col)
			return BuildMesh(tris, level / 8)
		end)
		m = ok and built or false
		meshCache[key] = m
		if not ok and not S.meshErr then S.meshErr = tostring(built) end
	end
	return m or nil
end

-- the rocket: GMod's thruster model off the back of the tail, level with
-- the tail's tip, nozzle backwards (its nozzle is its +Z end; 20 across and
-- 18.5 long at full size, so 0.4 = the deck's width); the old modelled tube
-- if the model isn't there
L.ROCKET_MODEL = "models/maxofs2d/thruster_projector.mdl"
L.ROCKET_SCALE = 0.4
L.ROCKET_BASE_X, L.ROCKET_MOUNT_Z = -DECK_HALF, DeckZ(DECK_HALF, 0) + THICK / 2 -- deck units: where its base sits
local rocketEnt
local rocketRetry = -1
local function RocketModel()
	if rocketEnt and IsValid(rocketEnt) then return rocketEnt end
	local now = RealTime and RealTime() or 0
	if rocketEnt == false and now < rocketRetry then return nil end
	rocketEnt, rocketRetry = false, now + 5
	-- (not util.IsValidModel: on the client it's false until the model is precached)
	if not ClientsideModel or (file and file.Exists and not file.Exists(L.ROCKET_MODEL, "GAME")) then return nil end
	if util and util.PrecacheModel then util.PrecacheModel(L.ROCKET_MODEL) end
	rocketEnt = ClientsideModel(L.ROCKET_MODEL, RENDERGROUP_OPAQUE)
	if not IsValid(rocketEnt) then rocketEnt = false return nil end
	rocketEnt:SetNoDraw(true)
	rocketEnt:SetModelScale(L.ROCKET_SCALE, 0)
	return rocketEnt
end
L.RocketModel = RocketModel

local function DrawRocket(origin, fwd, up, half)
	local e = RocketModel()
	if not e then return false end
	e:SetPos(origin + fwd * (L.ROCKET_BASE_X * half / 7) + up * L.ROCKET_MOUNT_Z)
	e:SetAngles(up:AngleEx(-fwd))
	if e.InvalidateBoneCache then e:InvalidateBoneCache() end
	e:DrawModel()
	return true
end

local colorMat, ghostMat
local function DrawBoardModel(P, o)
	local graphic, wheel, under, grip, rocket = o.graphic or Color(210, 64, 44), o.wheel, o.under, o.grip, o.rocket
	local pattern, patternColor = o.pattern, o.patternColor or Color(255, 255, 255)
	local showDeck, showTrucks = o.deck ~= false, o.trucks ~= false
	local tf, tb = P.TRUCK_FRONT, P.TRUCK_BACK
	local rf, lf, rb, lb = P.RIGHT_WHEELFRONT, P.LEFT_WHEELFRONT, P.RIGHT_WHEELBACK, P.LEFT_WHEELBACK
	if not (tf and tb and rf and lf and rb and lb) then return true end
	local fwd = (tf - tb):GetNormalized()
	local right = ((rf + rb) - (lf + lb)):GetNormalized()
	local up = right:Cross(fwd):GetNormalized()
	local wheels = (rf + lf + rb + lb) / 4
	local half = (tf - tb):Length() / 2
	local c = render.GetLightColor(wheels + up * 2)
	local light = math.Clamp(0.3 + (c.x + c.y + c.z) / 3 * 1.4, 0.3, 1.15)
	local deck = CachedMesh("deck", light, graphic, grip)
	local truck = CachedMesh("truck", light, wheel)
	if not (deck and truck) then return false end
	-- opaque and depth-writing, so the deck hides the trucks and wheels behind
	-- it (GMod's "color" material is translucent: last drawn shows on top)
	colorMat = colorMat or (CreateMaterial and CreateMaterial("skategm_board_vc", "UnlitGeneric", {
		["$basetexture"] = "color/white", ["$vertexcolor"] = "1", ["$vertexalpha"] = "0",
		["$translucent"] = "0", ["$nocull"] = "1",
	})) or Material("color")
	local ghost = render.GetBlend ~= nil and (render.GetBlend() or 1) < 0.99
	if ghost then
		ghostMat = ghostMat or (CreateMaterial and CreateMaterial("skategm_board_vc_ghost", "UnlitGeneric", {
			["$basetexture"] = "color/white", ["$vertexcolor"] = "1", ["$vertexalpha"] = "0",
			["$translucent"] = "1", ["$nocull"] = "1",
		})) or colorMat
		if ghostMat.SetFloat then ghostMat:SetFloat("$alpha", render.GetBlend()) end
		pattern, under = nil, nil
	end
	local base = ghost and ghostMat or colorMat
	render.SetMaterial(base)
	-- deck: centred between the trucks, bottom ~2 units above the axles
	local M = Matrix()
	M:SetTranslation((tf + tb) / 2 - up * ((tf + tb) / 2 - wheels):Dot(up) + up * 2.0)
	M:SetAngles(fwd:AngleEx(up))
	M:Scale(Vector(half / 7, 1, 1)) -- match the engine's wheelbase
	cam.PushModelMatrix(M)
	if showDeck then deck:Draw() end
	local pm = showDeck and pattern and CachedMesh("top", light, patternColor)
	if pm then
		render.SetMaterial(pattern)
		pm:Draw()
		render.SetMaterial(base)
	end
	local rm = rocket and not RocketModel() and CachedMesh("rocket", light)
	if rm then rm:Draw() end
	local um = showDeck and under and CachedMesh("under", light, nil, nil, o.underFit and S.UnderFit(under) or nil)
	if um then
		render.SetMaterial(under)
		um:Draw()
		render.SetMaterial(base)
	end
	cam.PopModelMatrix()
	if rocket then DrawRocket((tf + tb) / 2 - up * ((tf + tb) / 2 - wheels):Dot(up) + up * 2.0, fwd, up, half) end
	if not showTrucks then return true end
	-- trucks: each at its own axle, turned with its wheels
	for _, t in ipairs({ { rf, lf }, { rb, lb } }) do
		local axle = (t[1] + t[2]) / 2
		local across = (t[2] - t[1]):GetNormalized() -- towards the left wheel = truck +y
		local tfwd = across:Cross(up):GetNormalized()
		local T = Matrix()
		T:SetTranslation(axle)
		T:SetAngles(tfwd:AngleEx(up))
		cam.PushModelMatrix(T)
		truck:Draw()
		cam.PopModelMatrix()
	end
	return true
end

local function DrawBoxBoard(P, o)
	local tf, tb = P.TRUCK_FRONT, P.TRUCK_BACK
	local rf, lf, rb, lb = P.RIGHT_WHEELFRONT, P.LEFT_WHEELFRONT, P.RIGHT_WHEELBACK, P.LEFT_WHEELBACK
	if not (tf and tb and rf and lf and rb and lb) then return end
	local fwd = (tf - tb):GetNormalized()
	local right = ((rf + rb) - (lf + lb)):GetNormalized()
	local up = right:Cross(fwd):GetNormalized()
	local wheels = (rf + lf + rb + lb) / 4
	local half = (tf - tb):Length() / 2
	local centre = wheels + up * 2.3
	local ang = fwd:AngleEx(up)
	local c = render.GetLightColor(centre)
	local light = math.Clamp(0.3 + (c.x + c.y + c.z) / 3 * 1.4, 0.3, 1.15)
	local len = half + 3
	render.SetColorMaterial()
	if not (o and o.deck == false) then
		Box(centre, ang, Vector(-len, -4, -0.3), Vector(len, 4, 0.2), WOOD, light)
		Box(centre, ang, Vector(-len, -3.9, 0.2), Vector(len, 3.9, 0.32), GRIP, light)
		Box(centre, ang, Vector(-len, -3.9, -0.36), Vector(len, 3.9, -0.3), GRAPHIC, light)
		for _, s in ipairs({ 1, -1 }) do
			local tipAng = Angle(ang.p, ang.y, ang.r)
			tipAng:RotateAroundAxis(ang:Right(), 17 * s)
			local tip = centre + fwd * len * s
			local mn, mx = Vector(s > 0 and 0 or -5, -3.7, -0.3), Vector(s > 0 and 5 or 0, 3.7, 0.32)
			Box(tip, tipAng, mn, mx, WOOD, light)
		end
	end
	if o and o.trucks == false then return end
	for _, t in ipairs({ tf, tb }) do
		Box(t + up * 0.4, ang, Vector(-0.45, -3.6, -0.4), Vector(0.45, 3.6, 0.4), METAL, light)
	end
	for _, w in ipairs({ rf, lf, rb, lb }) do
		render.DrawSphere(w, 1.15, 8, 8, Color(WHEEL.r * light * 0.9, WHEEL.g * light * 0.9, WHEEL.b * light * 0.9))
	end
end

-- collision view colours by source (tags from skategm.CollisionNear)
local function DrawBoard(P, o)
	o = o or {}
	if Mesh and mesh and cam and cam.PushModelMatrix then
		local ok, drawn = pcall(DrawBoardModel, P, o)
		if ok and drawn then return end
		if not ok and not S.meshErr then S.meshErr = tostring(drawn) end
	end
	DrawBoxBoard(P, o)
end
S.test.board = { DeckTriangles = DeckTriangles, TruckTriangles = TruckTriangles, UnderTriangles = UnderTriangles, RocketTriangles = RocketTriangles, DrawBoard = DrawBoard } -- for offline tests

L.TopTriangles = TopTriangles
L.DeckTriangles, L.DrawBoard, L.DrawBoxBoard, L.RocketTriangles, L.TruckTriangles, L.UnderTriangles = DeckTriangles, DrawBoard, DrawBoxBoard, RocketTriangles, TruckTriangles, UnderTriangles
