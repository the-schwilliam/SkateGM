local S = SkateGM
local R = S.replay

R.FILTERS = {
	{ id = "none", name = "None" },
	{ id = "bw", name = "Black & white" },
	{ id = "sepia", name = "Sepia" },
	{ id = "film", name = "Old film" },
	{ id = "vhs", name = "VHS" },
	{ id = "contrast", name = "High contrast" },
	{ id = "fisheye", name = "Fisheye" },
	{ id = "camcorder", name = "Camcorder" },
}
R.FISHEYE_FOV = 35
R.CAMCORDER_FOV = 60
R.CAMCORDER = { aspect = 1.5, low = { 480, 320 }, soft = { 200, 134 }, softness = 170, grid = { 48, 32 }, rx = 0.985, ry = 2.3, grain = 9 }

function R.FilterIndex(id)
	for i, f in ipairs(R.FILTERS) do if f.id == id then return i end end
	return 1
end

local function Colour(t)
	if not DrawColorModify then return end
	local tab = {
		["$pp_colour_addr"] = t.addr or 0, ["$pp_colour_addg"] = t.addg or 0, ["$pp_colour_addb"] = t.addb or 0,
		["$pp_colour_brightness"] = t.brightness or 0, ["$pp_colour_contrast"] = t.contrast or 1,
		["$pp_colour_colour"] = t.colour or 1,
		["$pp_colour_mulr"] = t.mulr or 0, ["$pp_colour_mulg"] = t.mulg or 0, ["$pp_colour_mulb"] = t.mulb or 0,
	}
	DrawColorModify(tab)
end

local function Hash(n)
	n = math.floor(n) % 2147483647
	n = (n * 16807) % 2147483647
	return n / 2147483647
end
local function Scatter(n)
	local x = math.sin(math.floor(n) * 12.9898 + 78.233) * 43758.5453
	return x - math.floor(x)
end
R.Scatter = Scatter

local mats = {}
local function Mat(path)
	if mats[path] == nil then
		local m = Material and Material(path)
		mats[path] = (m and not (m.IsError and m:IsError())) and m or false
	end
	return mats[path] or nil
end

local function Vignette(w, h, alpha)
	local side, up, down = Mat("gui/gradient"), Mat("gui/gradient_up"), Mat("gui/gradient_down")
	surface.SetDrawColor(0, 0, 0, alpha)
	local edge = math.floor(math.min(w, h) * 0.22)
	if side then
		surface.SetMaterial(side)
		surface.DrawTexturedRect(0, 0, edge, h)
		surface.DrawTexturedRectUV(w - edge, 0, edge, h, 1, 0, 0, 1)
	end
	if up and down then
		surface.SetMaterial(down)
		surface.DrawTexturedRect(0, 0, w, edge)
		surface.SetMaterial(up)
		surface.DrawTexturedRect(0, h - edge, w, edge)
	end
end

local function Grain(w, h, alpha, t)
	local frame = math.floor((t or 0) * 24)
	local size = math.max(1, math.floor(h / 360))
	for i = 1, 900 do
		local v = Hash(frame * 977 + i * 31)
		surface.SetDrawColor(v > 0.5 and 255 or 0, v > 0.5 and 250 or 0, v > 0.5 and 235 or 0, alpha * (0.35 + 0.65 * Hash(i * 7 + frame)))
		surface.DrawRect(math.floor(Hash(frame * 131 + i * 17) * w), math.floor(Hash(frame * 71 + i * 53) * h), size, size)
	end
end

local function Scratches(w, h, t)
	local frame = math.floor(t * 24)
	for i = 1, 3 do
		local r = Hash(frame * 7 + i * 131)
		if r > 0.55 then
			local x = Hash(frame * 13 + i * 17) * w
			surface.SetDrawColor(235, 230, 215, 40 + 90 * Hash(frame + i))
			surface.DrawRect(x, 0, 1 + math.floor(r * 2), h)
		end
	end
	if Hash(frame * 3 + 5) > 0.93 then
		surface.SetDrawColor(255, 250, 235, 18)
		surface.DrawRect(0, 0, w, h)
	end
end

local function Scanlines(w, h, t)
	surface.SetDrawColor(0, 0, 0, 45)
	for y = 0, h, 4 do surface.DrawRect(0, y, w, 1) end
	local band = (t * 0.25 % 1) * (h + 80) - 40
	surface.SetDrawColor(255, 255, 255, 14)
	surface.DrawRect(0, band, w, 26)
	for i = 1, 60 do
		local v = Hash(math.floor(t * 30) * 59 + i * 13)
		surface.SetDrawColor(255, 255, 255, 30 + 50 * v)
		surface.DrawRect(Hash(math.floor(t * 30) * 7 + i) * w, band + Hash(i * 3) * 26, 2 + v * 30, 1)
	end
end

local function VhsText(w, h, t, meta)
	if not R.vhsFont then
		R.vhsFont = true
		surface.CreateFont("skategm_vhs", { font = "Courier New", size = math.max(18, math.floor(h * 0.045)), weight = 800, antialias = false })
	end
	local white = Color(240, 240, 240, 230)
	if math.floor(t * 1.5) % 2 == 0 then draw.SimpleText("PLAY >", "skategm_vhs", w * 0.06, h * 0.07, white) end
	local stamp = (meta and meta.date) or ""
	draw.SimpleText(stamp:upper(), "skategm_vhs", w * 0.06, h * 0.88, white)
end

function R.FilterFov(id, fov)
	if id == "fisheye" then return math.min(fov + R.FISHEYE_FOV, 150) end
	if id == "camcorder" then return math.min(fov + R.CAMCORDER_FOV, 150) end
	return fov
end

local cc = {}
function R.CamcorderFailed(err)
	if cc.reported then return end
	cc.reported = true
	local text = "[SkateGM] Camcorder filter failed: " .. tostring(err)
	print(text)
	if file and file.Write then file.Write("skategm/camcorder_error.txt", text) end
end
local function CamcorderSetup()
	if cc.ready ~= nil then return cc.ready end
	cc.ready = false
	if not (GetRenderTargetEx and CreateMaterial and render and render.PushRenderTarget and render.UpdateScreenEffectTexture and mesh and mesh.Begin) then return false end
	local C = R.CAMCORDER
	cc.low = GetRenderTargetEx("skategm_cc_low", C.low[1], C.low[2], RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
	cc.soft = GetRenderTargetEx("skategm_cc_soft", C.soft[1], C.soft[2], RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
	cc.noise = GetRenderTargetEx("skategm_cc_noise", 256, 256, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
	local flat = { ["$ignorez"] = 1, ["$vertexcolor"] = 1, ["$vertexalpha"] = 1 }
	local function Mat2D(name, tex)
		local t = { ["$basetexture"] = tex }
		for k, v in pairs(flat) do t[k] = v end
		return CreateMaterial(name, "UnlitGeneric", t)
	end
	cc.screen = Mat2D("skategm_cc_screen", "_rt_FullFrameFB")
	cc.lowMat = Mat2D("skategm_cc_lowmat", cc.low:GetName())
	cc.softMat = Mat2D("skategm_cc_softmat", cc.soft:GetName())
	cc.noiseMat = Mat2D("skategm_cc_noisemat", cc.noise:GetName())
	render.PushRenderTarget(cc.noise)
	render.Clear(128, 128, 128, 255)
	cam.Start2D()
	math.randomseed(7)
	for y = 0, 255 do
		for x = 0, 255 do
			local v = math.random(0, 255)
			surface.SetDrawColor(v, v, v, 255)
			surface.DrawRect(x, y, 1, 1)
		end
	end
	cam.End2D()
	render.PopRenderTarget()
	math.randomseed(os.time())
	cc.ready = true
	return true
end

local QUAD = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }
function R.CamcorderUV(x, y, half, aspect)
	local r = math.sqrt(x * x + y * y)
	if r < 1e-6 then return 0.5, 0.5 end
	local k = math.tan(math.min(r * half, 1.45)) / (r * math.tan(half))
	return 0.5 + 0.5 * x * k, 0.5 + 0.5 * y * k * aspect
end

local function CamcorderWarp(lw, lh, half, aspect)
	local C = R.CAMCORDER
	local gx, gy = C.grid[1], C.grid[2]
	local key = string.format("%.4f %.4f", half, aspect)
	if cc.key ~= key then
		cc.key, cc.uv = key, {}
		for j = 0, gy do
			for i = 0, gx do
				local u, v = R.CamcorderUV(i / gx * 2 - 1, (j / gy * 2 - 1) / C.aspect, half, aspect)
				cc.uv[j * (gx + 1) + i] = { u, v }
			end
		end
	end
	render.SetMaterial(cc.screen)
	mesh.Begin(MATERIAL_QUADS, gx * gy)
	for j = 0, gy - 1 do
		for i = 0, gx - 1 do
			for _, c in ipairs(QUAD) do
				local a, b = i + c[1], j + c[2]
				local uv = cc.uv[b * (gx + 1) + a]
				mesh.Position(Vector(a / gx * lw, b / gy * lh, 0))
				mesh.TexCoord(0, uv[1], uv[2])
				mesh.Color(255, 255, 255, 255)
				mesh.AdvanceVertex()
			end
		end
	end
	mesh.End()
end

R.CAMCORDER_RIM = {
	{ 0.84, 0, 0, 0, 0 },
	{ 0.93, 35, 20, 8, 170 },
	{ 0.96, 50, 28, 10, 230 },
	{ 0.975, "warm", 0.55, 250 },
	{ 0.993, "warm", 1, 255 },
	{ 1.003, 28, 14, 5, 255 },
	{ 1.02, 0, 0, 0, 255 },
	{ 3.0, 0, 0, 0, 255 },
}
local function RimColour(stop, a)
	if stop[2] ~= "warm" then return stop[2], stop[3], stop[4], stop[5] end
	local k = math.Clamp(0.5 + 0.35 * math.cos(a) + 0.15 * math.cos(3 * a + 0.7), 0, 1) * stop[3]
	return 70 + (205 - 70) * k, 40 + (120 - 40) * k, 15 + (45 - 15) * k, stop[4]
end

local function CamcorderRim(cx, cy, rx, ry)
	local stops, n = R.CAMCORDER_RIM, 96
	render.SetColorMaterial()
	mesh.Begin(MATERIAL_QUADS, n * (#stops - 1))
	for s = 1, #stops - 1 do
		local s0, s1 = stops[s], stops[s + 1]
		for i = 0, n - 1 do
			local a0, a1 = i / n * math.pi * 2, (i + 1) / n * math.pi * 2
			for _, c in ipairs({ { a0, s0 }, { a0, s1 }, { a1, s1 }, { a1, s0 } }) do
				local r, g, b, al = RimColour(c[2], c[1])
				mesh.Position(Vector(cx + math.cos(c[1]) * rx * c[2][1], cy + math.sin(c[1]) * ry * c[2][1], 0))
				mesh.Color(r, g, b, al)
				mesh.AdvanceVertex()
			end
		end
	end
	mesh.End()
end

local function Camcorder(t, w, h)
	local C = R.CAMCORDER
	local cw = math.min(w, h * C.aspect)
	local x0 = math.floor((w - cw) / 2)
	local vs = render.GetViewSetup and render.GetViewSetup()
	local half = math.rad(math.Clamp(vs and vs.fov or 120, 30, 170) / 2)
	if DrawMotionBlur then DrawMotionBlur(0.35, 0.55, 0.01) end
	render.UpdateScreenEffectTexture()
	render.PushRenderTarget(cc.low)
	render.Clear(0, 0, 0, 255)
	cam.Start2D()
	CamcorderWarp(C.low[1], C.low[2], half, w / h)
	cam.End2D()
	render.PopRenderTarget()
	render.PushRenderTarget(cc.soft)
	cam.Start2D()
	surface.SetMaterial(cc.lowMat)
	surface.SetDrawColor(255, 255, 255, 255)
	surface.DrawTexturedRect(0, 0, C.soft[1], C.soft[2])
	cam.End2D()
	render.PopRenderTarget()
	render.Clear(0, 0, 0, 255)
	cam.Start2D()
	surface.SetMaterial(cc.lowMat)
	surface.SetDrawColor(255, 255, 255, 255)
	surface.DrawTexturedRect(x0, 0, cw, h)
	surface.SetMaterial(cc.softMat)
	surface.SetDrawColor(255, 255, 255, C.softness)
	surface.DrawTexturedRect(x0, 0, cw, h)
	surface.SetMaterial(cc.lowMat)
	surface.SetDrawColor(255, 90, 60, 45)
	surface.DrawTexturedRect(x0 + cw * 0.003, 0, cw, h)
	surface.SetDrawColor(70, 110, 255, 35)
	surface.DrawTexturedRect(x0 - cw * 0.002, 0, cw, h)
	surface.SetDrawColor(255, 255, 255, 22)
	surface.DrawTexturedRect(x0 + cw * 0.007, 0, cw, h)
	cam.End2D()
	Colour({ colour = 0.78, contrast = 1.05, brightness = 0.03, addr = -0.02, addb = 0.045 })
	cam.Start2D()
	local frame = math.floor((t or 0) * 30)
	local u0, v0 = Scatter(frame * 2 + 1), Scatter(frame * 2 + 2)
	surface.SetMaterial(cc.noiseMat)
	surface.SetDrawColor(255, 255, 255, C.grain)
	surface.DrawTexturedRectUV(x0, 0, cw, h, u0, v0, u0 + cw / 512, v0 + h / 512)
	CamcorderRim(w / 2, h / 2 + h * 0.02, cw / 2 * C.rx, h / 2 * C.ry)
	surface.SetDrawColor(0, 0, 0, 255)
	surface.DrawRect(0, 0, x0, h)
	surface.DrawRect(x0 + cw, 0, w - x0 - cw + 1, h)
	cam.End2D()
end

function R.DrawFilter(id, t, w, h, meta)
	if id == "none" or not id then return end
	if id == "camcorder" then
		local ok, err = pcall(CamcorderSetup)
		if ok and err then
			local depth = 0
			local push, pop = render.PushRenderTarget, render.PopRenderTarget
			render.PushRenderTarget = function(...) depth = depth + 1 return push(...) end
			render.PopRenderTarget = function(...) depth = depth - 1 return pop(...) end
			ok, err = pcall(Camcorder, t, w, h)
			render.PushRenderTarget, render.PopRenderTarget = push, pop
			for _ = 1, depth do pop() end
			if ok then return end
		end
		R.CamcorderFailed(err)
		id = "fisheye"
	end
	if id == "bw" then
		Colour({ colour = 0, contrast = 1.1 })
	elseif id == "sepia" then
		Colour({ colour = 0, contrast = 1.05 })
		Colour({ addr = 0.12, addg = 0.05, addb = -0.07 })
	elseif id == "film" then
		Colour({ colour = 0.15, contrast = 1.15, brightness = -0.02 })
		Colour({ addr = 0.06, addg = 0.03, addb = -0.03 })
	elseif id == "vhs" then
		Colour({ colour = 1.35, contrast = 1.08, addb = 0.02 })
	elseif id == "contrast" then
		Colour({ colour = 1.25, contrast = 1.6, brightness = -0.06 })
	elseif id == "fisheye" then
		local lens = Mat("models/props_c17/fisheyelens")
		if lens and DrawMaterialOverlay then DrawMaterialOverlay("models/props_c17/fisheyelens", -0.06) end
	end
	cam.Start2D()
	if id == "film" then
		Grain(w, h, 70, t)
		Scratches(w, h, t)
		Vignette(w, h, 230)
	elseif id == "vhs" then
		Scanlines(w, h, t)
		VhsText(w, h, t, meta)
	elseif id == "fisheye" then
		Vignette(w, h, 200)
	end
	cam.End2D()
end

hook.Add("RenderScreenspaceEffects", "skategm_replay_fx", function()
	local v = R.on
	if not (v and v.edit) then return end
	R.DrawFilter(v.edit.filter, v.t, ScrW(), ScrH(), v.meta)
end)
