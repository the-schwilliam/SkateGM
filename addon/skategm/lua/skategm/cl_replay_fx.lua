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
}
R.FISHEYE_FOV = 35

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

local function Grain(w, h, alpha)
	local noise = Mat("effects/tvscreen_noise002a")
	if not noise then return end
	surface.SetDrawColor(255, 255, 255, alpha)
	surface.SetMaterial(noise)
	surface.DrawTexturedRect(0, 0, w, h)
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
	local noise = Mat("effects/tvscreen_noise002a")
	if noise then
		surface.SetDrawColor(255, 255, 255, 40)
		surface.SetMaterial(noise)
		surface.DrawTexturedRect(0, band, w, 26)
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
	return fov
end

function R.DrawFilter(id, t, w, h, meta)
	if id == "none" or not id then return end
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
		Grain(w, h, 70)
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
