---------------------------------------------------------------------------
-- Skate 3's own trick display: the original movie, run inside gm_skategm
-- (skategm.HudLoad / HudDraws, from SK8-ENGINE/skate-3-rust-engine), drawn
-- here with its own textures. Needs garrysmod/data/skategm_hud/, made from
-- your copy of Skate 3 by the installer (exporter asset_pipeline/gmod_hud.py); without it the add-on's
-- own score display stays.
---------------------------------------------------------------------------
local S = SkateGM
local cvOriginal = CreateClientConVar("skategm_hud_original", "1", true, false, "1 = Skate 3's own trick display (when prepared in data/skategm_hud)", 0, 1)
local cvFolder = CreateClientConVar("skategm_hud_folder", "", true, false, "Where the prepared trick display is (empty = garrysmod/data/skategm_hud)")
local DIR = "skategm_hud/"
-- the display's colour (gm_sk8 addition): multiplies everything it draws
S.HudTints = {
	{ "Original", 255, 255, 255 }, { "Red", 255, 80, 80 }, { "Orange", 255, 160, 60 }, { "Yellow", 255, 235, 90 },
	{ "Green", 110, 255, 110 }, { "Cyan", 90, 235, 255 }, { "Blue", 100, 140, 255 }, { "Purple", 190, 110, 255 },
	{ "Pink", 255, 120, 210 }, { "Custom" },
}
local cvTint = CreateClientConVar("skategm_hud_tint", "1", true, false, "Skate 3 trick display colour (1 = original, last = skategm_hud_color)", 1, #S.HudTints)
local cvColor = CreateClientConVar("skategm_hud_color", "255 255 255", true, false, "Custom colour of the Skate 3 trick display: \"r g b\"")
local function Tint()
	local t = S.HudTints[math.Clamp(cvTint:GetInt(), 1, #S.HudTints)]
	if t[2] then return t[2] / 255, t[3] / 255, t[4] / 255 end
	local r, g, b = string.match(cvColor:GetString(), "(%d+)%D+(%d+)%D+(%d+)")
	return math.Clamp(tonumber(r) or 255, 0, 255) / 255, math.Clamp(tonumber(g) or 255, 0, 255) / 255, math.Clamp(tonumber(b) or 255, 0, 255) / 255
end
local W, H = 1280, 720

-- the display's font (gm_sk8 addition): empty = Skate 3's own; else any font
-- installed in Windows, by name. Each text field is drawn in it instead.
S.HudFonts = { "Skate 3", "Arial", "Arial Black", "Impact", "Segoe UI", "Bahnschrift", "Tahoma", "Verdana", "Trebuchet MS", "Comic Sans MS", "Consolas", "Custom" }
local cvFontPick = CreateClientConVar("skategm_hud_font_pick", "1", true, false, "Skate 3 trick display font (1 = Skate 3's own, last = skategm_hud_font)", 1, #S.HudFonts)
local cvFont = CreateClientConVar("skategm_hud_font", "", true, false, "Custom font of the Skate 3 trick display: any installed font's name")
local cvFontWeight = CreateClientConVar("skategm_hud_font_weight", "800", true, false, "Weight of the trick display's font (100-1000)", 100, 1000)
local function FontName()
	local i = math.Clamp(cvFontPick:GetInt(), 1, #S.HudFonts)
	if i == 1 then return nil end
	local name = i == #S.HudFonts and string.Trim(cvFont:GetString()) or S.HudFonts[i]
	return name ~= "" and name or nil
end
local fonts = {}
local function Font(name, px)
	px = math.Clamp(math.Round(px), 6, 200)
	local weight = cvFontWeight:GetInt()
	local key = name .. "|" .. px .. "|" .. weight
	if not fonts[key] then
		fonts[key] = "skategm_hudf_" .. util.CRC(key)
		surface.CreateFont(fonts[key], { font = name, size = px, weight = weight, antialias = true, extended = true })
	end
	return fonts[key]
end

local O = { tried = false, ok = false, mats = {} }
S.OriginalHud = O

local function Tell(msg)
	print("[SkateGM] Skate 3 trick display: " .. msg)
end

local function Load()
	if not (skategm and skategm.HudLoad) then O.err = "this gm_skategm has no HudLoad" return end
	O.tried = true
	if cvFolder:GetString() == "" and not file.Exists(DIR .. "runtime/trickdisplay.json", "DATA") then
		O.err = "not prepared (garrysmod/data/skategm_hud)" Tell(O.err) return
	end
	-- (empty: the module finds garrysmod/data/skategm_hud itself)
	local ok, err = skategm.HudLoad(cvFolder:GetString())
	O.ok, O.err = ok == true, err
	if not O.ok then Tell(tostring(err)) end
end


-- each texture as a material, and its alpha mask as an additive one (the
-- movie's colour transforms add a colour as well as multiply). Clamped at
-- the edges: wrapping showed the opposite edge as seams along each shape.
local function Mats(tex)
	local m = O.mats[tex]
	if m then return m end
	local base = string.gsub(tex, "%.rgba$", "")
	local color = Material("../data/" .. DIR .. base .. ".png", "smooth")
	local mask = Material("../data/" .. DIR .. base .. ".mask.png", "smooth")
	local add
	if mask and not mask:IsError() then
		add = CreateMaterial("skategm_hud_add_" .. util.CRC(tex), "UnlitGeneric", {
			["$basetexture"] = "vgui/white", ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$additive"] = 1, ["$translucent"] = 1,
		})
		add:SetTexture("$basetexture", mask:GetTexture("$basetexture"))
	end
	m = { color = (color and not color:IsError()) and color or nil, add = add }
	if not m.color and not O.texErr then O.texErr = true Tell("can't load texture " .. base .. ".png") end
	O.mats[tex] = m
	return m
end
local MASK

-- surface.DrawPoly culls counter-clockwise polygons, and the movie's
-- triangles come either way round: those are turned over (else half the
-- shapes went missing in pieces)
local poly, back = { {}, {}, {} }, {}
local function Triangles(v, sx, sy, ox, oy)
	for i = 1, #v, 12 do
		for k = 0, 2 do
			local p, j = poly[k + 1], i + k * 4
			p.x, p.y, p.u, p.v = ox + v[j] * sx, oy + v[j + 1] * sy, v[j + 2], v[j + 3]
		end
		local a, b, c = poly[1], poly[2], poly[3]
		if (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) < 0 then
			back[1], back[2], back[3] = a, c, b
			surface.DrawPoly(back)
		else
			surface.DrawPoly(poly)
		end
	end
end

function S.OriginalHudActive()
	if not cvOriginal:GetBool() then return false end
	if not O.tried then Load() end
	return O.ok
end

function S.OriginalHudPaint(w, h)
	local draws, err = skategm.HudDraws()
	if not draws then
		if not O.drawErr then O.drawErr = tostring(err) Tell("stopped: " .. O.drawErr) end
		return
	end
	-- the movie's 1280x720, fitted and centred
	local s = math.min(w / W, h / H)
	local ox, oy = (w - W * s) / 2, (h - H * s) / 2
	-- masks (APT clip depths) in the stencil: an open mask raises the level
	-- inside its shape by one; the movie draws only where the level is the
	-- number of masks open
	render.ClearStencil()
	render.SetStencilEnable(true)
	render.SetStencilWriteMask(255)
	render.SetStencilTestMask(255)
	render.SetStencilFailOperation(STENCIL_KEEP)
	render.SetStencilZFailOperation(STENCIL_KEEP)
	render.SetStencilCompareFunction(STENCIL_EQUAL)
	local level = 0
	local function Stencil(op)
		render.SetStencilReferenceValue(level)
		render.SetStencilPassOperation(op)
	end
	Stencil(STENCIL_KEEP)
	local tr, tg, tb = Tint()
	local fontName = FontName()
	local shadowed = false
	for _, d in ipairs(draws) do
		local mask = d.mask or 0
		if not d.text then shadowed = false end
		if fontName and mask == 0 and d.text then
			-- a text field in the chosen font, in its box (rotation ignored)
			local b, mul = d.tbox, d.mul
			if d.text ~= "" and mul[4] > 0.002 then
				local x0, y0, x1 = ox + b[1] * s, oy + b[2] * s, ox + b[3] * s
				surface.SetFont(Font(fontName, d.th * s))
				local tw = surface.GetTextSize(d.text)
				local x = d.talign == 1 and x1 - tw or d.talign == 2 and (x0 + x1 - tw) / 2 or x0
				if d.tshadow == 1 then
					surface.SetTextColor(0, 0, 0, math.min(mul[4], 1) * 255)
					surface.SetTextPos(x + 2, y0 + 2)
				else
					-- text without Skate 3's own shadow pass (the numbers) gets one too
					if not shadowed then
						surface.SetTextColor(0, 0, 0, math.min(mul[4], 1) * 255)
						surface.SetTextPos(x + 2, y0 + 2)
						surface.DrawText(d.text)
					end
					surface.SetTextColor(math.min(mul[1], 1) * tr * 255, math.min(mul[2], 1) * tg * 255, math.min(mul[3], 1) * tb * 255, math.min(mul[4], 1) * 255)
					surface.SetTextPos(x, y0)
				end
				surface.DrawText(d.text)
			end
			shadowed = d.tshadow == 1
		elseif mask == 2 then
			level = level + 1 Stencil(STENCIL_KEEP)
		elseif mask == -2 then
			level = math.max(level - 1, 0) Stencil(STENCIL_KEEP)
		elseif mask ~= 0 then
			-- a mask's shape changes the stencil only, never the screen
			Stencil(mask > 0 and STENCIL_INCR or STENCIL_DECR)
			MASK = MASK or Material("vgui/white")
			surface.SetMaterial(MASK)
			surface.SetDrawColor(255, 255, 255, 0)
			Triangles(d.v, s, s, ox, oy)
			Stencil(STENCIL_KEEP)
		else
			local mul, add = d.mul, d.add
			local m = Mats(d.tex)
			if m.color and mul[4] > 0.002 then
				surface.SetMaterial(m.color)
				surface.SetDrawColor(math.min(mul[1], 1) * tr * 255, math.min(mul[2], 1) * tg * 255, math.min(mul[3], 1) * tb * 255, math.min(mul[4], 1) * 255)
				Triangles(d.v, s, s, ox, oy)
			end
			if m.add and (add[1] > 0.004 or add[2] > 0.004 or add[3] > 0.004) then
				local a = math.Clamp(mul[4] + add[4], 0, 1)
				surface.SetMaterial(m.add)
				surface.SetDrawColor(math.min(add[1], 1) * tr * 255, math.min(add[2], 1) * tg * 255, math.min(add[3], 1) * tb * 255, a * 255)
				Triangles(d.v, s, s, ox, oy)
			end
		end
	end
	render.SetStencilEnable(false)
end
-- a new skating session reloads it (the module's movie restarts on its own)
concommand.Add("skategm_hud_reload", function()
	O.tried, O.ok, O.err, O.drawErr = false, false, nil, nil
	Load()
	print("[SkateGM] Skate 3 trick display: " .. (O.ok and "loaded" or tostring(O.err)))
end, nil, "Load Skate 3's trick display again (after preparing it)")

---------------------------------------------------------------------------
-- The multiplier's sounds (Skate 3's fe records multiplyer_2 / multiplyer_3,
-- as the game spells them, from sk8_menu.bnk; data/skategm_hud/sound/
-- multiplier_2 / multiplier_3): each time the multiplier goes up
---------------------------------------------------------------------------
local cvHudSounds = CreateClientConVar("skategm_hud_sounds", "1", true, false, "1 = Skate 3's multiplier sounds", 0, 1)
local LEVELS = {}
local function Level(name)
	if LEVELS[name] == nil then
		LEVELS[name] = tonumber(file.Read(DIR .. "sound/" .. name .. ".txt", "DATA") or "") or 1
	end
	return LEVELS[name]
end
local function PlayFe(name)
	local path = DIR .. "sound/" .. name .. ".wav"
	if not file.Exists(path, "DATA") then return end
	local cv = GetConVar("skategm_sound_volume")
	local volume = Level(name) * (cv and cv:GetFloat() or 1)
	sound.PlayFile("data/" .. path, "noplay", function(ch)
		if not IsValid(ch) then return end
		ch:SetVolume(math.Clamp(volume, 0, 1))
		ch:Play()
	end)
end
S.PlayFeSound = PlayFe

local lastMult
hook.Add("Think", "skategm_hud_sounds", function()
	local sc = S.phase == "on" and S.pose and S.pose.score
	if not sc then lastMult = nil return end
	local m = sc.multiplier or 1
	-- (x2 and x3 only: x1.5 has no sound)
	if lastMult and m > lastMult + 0.01 and m >= 1.99 and cvHudSounds:GetBool() then
		PlayFe(m >= 2.99 and "multiplier_3" or "multiplier_2")
	end
	lastMult = m
end)
