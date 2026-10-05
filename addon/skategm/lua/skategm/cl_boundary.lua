local S = SkateGM

local B = { NEAR = 394, FULL = 40, RADIUS = 520, SOFT = 0.35, GRID = 48, SPAN = 1040, COLOUR = Color(120, 220, 255) }
S.boundary = B

function B.Parse(text)
	local points = {}
	for x, y in tostring(text or ""):gmatch("(%-?[%d%.]+),(%-?[%d%.]+)") do points[#points + 1] = { tonumber(x), tonumber(y) } end
	return points
end

function B.Load()
	B.edges, B.source = nil, GetGlobal2String("SkateGMBoundary", "")
	local points = B.Parse(B.source)
	if #points < 3 then return end
	local edges = {}
	for i, p in ipairs(points) do
		local q = points[i % #points + 1]
		if tonumber(p[1]) and tonumber(p[2]) and tonumber(q[1]) and tonumber(q[2]) then
			edges[#edges + 1] = { Vector(p[1], p[2], 0), Vector(q[1], q[2], 0) }
		end
	end
	B.edges = #edges > 0 and edges or nil
end

function B.Nearest(a, b, pos)
	local d = b - a
	local len2 = d.x * d.x + d.y * d.y
	if len2 < 1 then return 0, a end
	local t = math.Clamp(((pos.x - a.x) * d.x + (pos.y - a.y) * d.y) / len2, 0, 1)
	local p = a + d * t
	return math.sqrt((pos.x - p.x) ^ 2 + (pos.y - p.y) ^ 2), p, t, math.sqrt(len2)
end

function B.Where()
	local P = S.renderP or S.P
	if S.phase == "on" and P and P.HIPS then return P.HIPS end
	local me = LocalPlayer()
	return IsValid(me) and me:GetPos() or nil
end

function B.Smooth(x)
	x = math.Clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

function B.Fade(dist)
	return B.Smooth((B.NEAR - dist) / (B.NEAR - B.FULL))
end

function B.Closest(pos, edges)
	local best, at
	for _, e in ipairs(edges or {}) do
		local d, p = B.Nearest(e[1], e[2], pos)
		if not best or d < best then best, at = d, p end
	end
	return best, at
end

function B.Panels(pos, edges)
	local out = {}
	edges = edges or B.edges
	local dist, centre = B.Closest(pos, edges)
	if not dist or dist >= B.NEAR then return out end
	local alpha = B.Fade(dist)
	local c = Vector(centre.x, centre.y, pos.z)
	for _, e in ipairs(edges) do
		local d = e[2] - e[1]
		local len = math.sqrt(d.x * d.x + d.y * d.y)
		if len >= 1 then
			local dir = d / len
			local along = (c.x - e[1].x) * dir.x + (c.y - e[1].y) * dir.y
			local side = math.abs((c.x - e[1].x) * dir.y - (c.y - e[1].y) * dir.x)
			if side < B.RADIUS * 0.9 then
				local half = math.sqrt(B.RADIUS * B.RADIUS - side * side)
				local from, to = math.max(0, along - half), math.min(len, along + half)
				if to > from then
					out[#out + 1] = { a = e[1] + dir * from, b = e[1] + dir * to, from = from, to = to, start = e[1], alpha = alpha, z = pos.z, dir = dir, centre = c }
				end
			end
		end
	end
	return out
end

function B.Weight(point, centre)
	local dx, dy, dz = point.x - centre.x, point.y - centre.y, point.z - centre.z
	local r = math.sqrt(dx * dx + dy * dy + dz * dz) / B.RADIUS
	return 1 - B.Smooth((r - B.SOFT) / (1 - B.SOFT))
end

local function steps(lo, hi, grid)
	local out = { lo }
	for v = math.floor(lo / grid + 1) * grid, hi - 0.001, grid do out[#out + 1] = v end
	out[#out + 1] = hi
	return out
end

local mat
function B.DrawEdges(edges, colour)
	local pos = B.Where()
	if not (pos and edges) then return end
	local panels = B.Panels(pos, edges)
	if #panels == 0 then return end
	mat = mat or CreateMaterial("skategm_boundary_glow", "UnlitGeneric", { ["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$translucent"] = 1, ["$nocull"] = 1 })
	local c = colour or B.COLOUR
	for _, panel in ipairs(panels) do
		local ss = steps(panel.from, panel.to, B.GRID)
		local zs = steps(panel.z - B.RADIUS, panel.z + B.RADIUS, B.GRID)
		local pts = {}
		for i, sv in ipairs(ss) do
			pts[i] = {}
			local p = panel.start + panel.dir * sv
			for j, zv in ipairs(zs) do
				local v = Vector(p.x, p.y, zv)
				pts[i][j] = { v = v, w = B.Weight(v, panel.centre) * panel.alpha }
			end
		end
		render.SetMaterial(mat)
		mesh.Begin(MATERIAL_QUADS, (#ss - 1) * (#zs - 1))
		for i = 1, #ss - 1 do
			for j = 1, #zs - 1 do
				for _, q in ipairs({ pts[i][j], pts[i + 1][j], pts[i + 1][j + 1], pts[i][j + 1] }) do
					mesh.Position(q.v)
					mesh.Color(c.r, c.g, c.b, math.floor(40 * q.w))
					mesh.AdvanceVertex()
				end
			end
		end
		mesh.End()
		local function line(p, q)
			local w = (p.w + q.w) / 2
			if w > 0.01 then render.DrawLine(p.v, q.v, Color(c.r, c.g, c.b, math.floor(170 * w)), true) end
		end
		for i = 1, #ss do
			for j = 1, #zs - 1 do
				if i > 1 and i < #ss or math.abs(ss[i] % B.GRID) < 0.01 then line(pts[i][j], pts[i][j + 1]) end
			end
		end
		for j = 2, #zs - 1 do
			for i = 1, #ss - 1 do line(pts[i][j], pts[i + 1][j]) end
		end
	end
end

B.BAND, B.BAND_ALPHA = 360, 55
function B.BandRows(z)
	return { { z - B.BAND, 0 }, { z - B.BAND * 0.25, 1 }, { z + B.BAND * 0.25, 1 }, { z + B.BAND, 0 } }
end

function B.DrawBand(edges, colour, z)
	if not (edges and z) then return end
	mat = mat or CreateMaterial("skategm_boundary_glow", "UnlitGeneric", { ["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$translucent"] = 1, ["$nocull"] = 1 })
	local c = colour or B.COLOUR
	local rows = B.BandRows(z)
	render.SetMaterial(mat)
	mesh.Begin(MATERIAL_QUADS, #edges * (#rows - 1))
	for _, e in ipairs(edges) do
		for r = 1, #rows - 1 do
			local lo, hi = rows[r], rows[r + 1]
			for _, q in ipairs({ { e[1], lo }, { e[2], lo }, { e[2], hi }, { e[1], hi } }) do
				mesh.Position(Vector(q[1].x, q[1].y, q[2][1]))
				mesh.Color(c.r, c.g, c.b, math.floor(B.BAND_ALPHA * q[2][2]))
				mesh.AdvanceVertex()
			end
		end
	end
	mesh.End()
	local line = Color(c.r, c.g, c.b, 200)
	for _, e in ipairs(edges) do render.DrawLine(Vector(e[1].x, e[1].y, z), Vector(e[2].x, e[2].y, z), line, true) end
end

concommand.Add("skategm_boundary_info", function()
	if B.source ~= GetGlobal2String("SkateGMBoundary", "") then B.Load() end
	local pos = B.Where()
	local nearest
	for _, e in ipairs(B.edges or {}) do
		local d = B.Nearest(e[1], e[2], pos or Vector())
		nearest = math.min(nearest or d, d)
	end
	print(string.format("[SkateGM] boundary: %d edges, nearest %s units (shown within %d)", #(B.edges or {}),
		nearest and string.format("%.0f", nearest) or "-", B.NEAR))
end)
hook.Add("PostDrawTranslucentRenderables", "skategm_boundary", function(depth, sky)
	if sky or depth then return end
	if B.source ~= GetGlobal2String("SkateGMBoundary", "") then B.Load() end
	if B.edges then B.DrawEdges(B.edges) end
end)

return B
