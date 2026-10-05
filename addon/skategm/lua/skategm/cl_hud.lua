local S = SkateGM
local L = S.L
local Say, WATER = L.Say, L.WATER

---------------------------------------------------------------------------
-- Score display. The numbers are the game's own scoring (the game's score
-- accounting, run inside the engine from your game data); only the look is
-- ours. Drawn on its own panel, so other add-ons' hooks can't block it.
---------------------------------------------------------------------------
local cvHud = CreateClientConVar("skategm_hud", "1", true, false, "Show the HUD (all of it)", 0, 1)
local cvTotal = CreateClientConVar("skategm_hud_total", "1", true, false, "Show the total score", 0, 1)
local cvLine = CreateClientConVar("skategm_hud_line", "1", true, false, "Show the line score, multiplier and timer", 0, 1)
local cvTrick = CreateClientConVar("skategm_hud_trick", "1", true, false, "Show trick names", 0, 1)
local cvCallouts = CreateClientConVar("skategm_hud_callouts", "1", true, false, "Show call-outs (clean, sketchy, marker set...)", 0, 1)
function S.HudShows(cv)
	if not cvHud:GetBool() then return false end
	local c = cv and GetConVar(cv)
	return not c or c:GetBool()
end
local H = { total = 0, line = 0, seq = 0, mult = 1, lineT = 0, lineCap = 1, trick = "", trickT = -10, events = {}, init = false }
S.H = H

local function Commas(n)
	n = math.floor((n or 0) + 0.5)
	local s = tostring(math.abs(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return (n < 0 and "-" or "") .. out
end
S.Commas = Commas

-- Trick names arrive as the game's text IDs ("ID_POP_SHUVIT") unless the module
-- found the game's English table; make IDs readable in skate terms.
local TRICK_WORDS = {
	FS = "Frontside", BS = "Backside", SW = "Switch", SWITCH = "Switch", FAKIE = "Fakie", NOLLIE = "Nollie",
	SHUVIT = "Shove-it", SHOVEIT = "Shove-it", SHOVIT = "Shove-it", POP = "Pop", OLLIE = "Ollie",
	KICKFLIP = "Kickflip", HEELFLIP = "Heelflip", HARDFLIP = "Hardflip", VARIAL = "Varial", TRE = "Tre", TREFLIP = "Tre Flip",
	BIGSPIN = "Bigspin", IMPOSSIBLE = "Impossible", CASPER = "Casper", PRIMO = "Primo", DARKSLIDE = "Darkslide",
	BOARDSLIDE = "Boardslide", LIPSLIDE = "Lipslide", NOSESLIDE = "Noseslide", TAILSLIDE = "Tailslide",
	NOSEGRIND = "Nosegrind", FIFTYFIFTY = "50-50", FIVEO = "5-0", SMITH = "Smith", FEEBLE = "Feeble",
	CROOKED = "Crooked", CROOK = "Crooked Grind", SALAD = "Salad", SUSKI = "Suski", WILLY = "Willy", BLUNT = "Blunt",
	MANUAL = "Manual", NOSEMANUAL = "Nose Manual", GRAB = "Grab", INDY = "Indy", MELON = "Melon", STALEFISH = "Stalefish",
	METHOD = "Method", MUTE = "Mute", AIR = "Air", REVERT = "Revert", PLANT = "Plant", HANDPLANT = "Handplant",
	FOOTPLANT = "Footplant", BONELESS = "Boneless", BODYVARIAL = "Body Varial", LATE = "Late", DOUBLE = "Double", TRIPLE = "Triple",
}
function S.TrickName(id)
	if not id or id == "" then return "" end
	if not string.find(id, "^ID_") and string.find(id, "%l") then return id end -- already real text
	local s = string.gsub(id, "^ID_", "")
	s = string.gsub(s, "(%d+)_(%d+)", "%1-%2") -- 5_0 -> 5-0, 50_50 -> 50-50
	local words = {}
	for w in string.gmatch(s, "[^_]+") do
		words[#words + 1] = TRICK_WORDS[w] or (string.find(w, "^[%d%-]+$") and w) or (string.sub(w, 1, 1) .. string.lower(string.sub(w, 2)))
	end
	return table.concat(words, " ")
end

local function Event(text, col, now, big)
	table.insert(H.events, 1, { text = text, col = col, t = now, big = big })
	while #H.events > 4 do table.remove(H.events) end
end

-- per poll: turn the engine's scoring into on-screen events
function S.HudUpdate(sc, now)
	if not sc then return end
	local total, line, seq = sc.total or 0, sc.line or 0, sc.sequence or 0
	if not H.init then
		H.total, H.line, H.seq, H.init = total, line, seq, true
	end
	local trick = S.TrickName(sc.trick)
	if trick ~= "" and trick ~= H.trick then
		H.trick, H.trickT = trick, now
	end
	if sc.clean and not H.clean then Event("CLEAN", Color(120, 255, 140), now) end
	if sc.sketchy and not H.sketchy then Event("SKETCHY", Color(255, 170, 60), now) end
	if total > H.total + 0.5 then
		Event("LINE  +" .. Commas(total - H.total), Color(255, 220, 90), now, true)
	elseif H.seq > 0 and seq <= 0 and line < H.line + H.seq * 0.5 then
		Event("BAILED", Color(255, 80, 70), now)          -- the sequence was lost, not landed
	end
	H.total, H.line, H.seq = total, line, seq
	H.mult, H.clean, H.sketchy, H.switch = sc.multiplier or 1, sc.clean, sc.sketchy, sc.switch
	H.lineT, H.lineCap = sc.lineTime or 0, math.max(sc.lineCapacity or 1, 0.01)
end

local fontsMade
local function Fonts()
	local h = ScrH()
	if fontsMade == h then return end
	fontsMade = h
	-- the centre of the screen (line, trick names, call-outs) is kept small
	surface.CreateFont("skategm_huge", { font = "Coolvetica", size = math.floor(h * 0.0375), weight = 500, antialias = true })
	surface.CreateFont("skategm_big", { font = "Coolvetica", size = math.floor(h * 0.025), weight = 500, antialias = true })
	surface.CreateFont("skategm_cmid", { font = "Coolvetica", size = math.floor(h * 0.017), weight = 500, antialias = true })
	surface.CreateFont("skategm_csmall", { font = "Roboto", size = math.floor(h * 0.011), weight = 800, antialias = true })
	-- the session total in the corner stays as it was
	surface.CreateFont("skategm_mid", { font = "Coolvetica", size = math.floor(h * 0.034), weight = 500, antialias = true })
	surface.CreateFont("skategm_small", { font = "Roboto", size = math.floor(h * 0.02), weight = 800, antialias = true })
end

local shadowCol, textCol = Color(0, 0, 0, 0), Color(0, 0, 0, 0)
local function Shadowed(text, font, x, y, col, ax, ay, alpha)
	local a = (col.a or 255) * (alpha or 1)
	shadowCol.a = a * 0.7
	draw.SimpleText(text, font, x + 2, y + 2, shadowCol, ax, ay)
	textCol.r, textCol.g, textCol.b, textCol.a = col.r, col.g, col.b, a
	draw.SimpleText(text, font, x, y, textCol, ax, ay)
end

S.HELD_SHOW = 0.25
function S.HudPaint(w, h, now)
	if S.phase ~= "on" then return end
	Fonts()
	-- teleported somewhere the collision wasn't built yet: held there until it is
	-- (said only once it lasts: a hold of a few frames flashing it up is worse)
	if S.pose and S.pose.held then S.heldSince = S.heldSince or now else S.heldSince = nil end
	if S.heldSince and now - S.heldSince >= S.HELD_SHOW then
		local bw, bh = w * 0.42, h * 0.13
		if draw.RoundedBox then draw.RoundedBox(12, (w - bw) / 2, h * 0.42 - bh / 2, bw, bh, Color(0, 0, 0, 170)) end
		Shadowed("Waiting for collision to load...", "skategm_big", w / 2, h * 0.42 - bh * 0.15, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
	local show = cvHud:GetBool()
	local white = Color(255, 255, 255)
	if show and cvTotal:GetBool() then
		Shadowed("TOTAL", "skategm_small", w - w * 0.03, h * 0.04, Color(220, 220, 220), TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)
		Shadowed(Commas(H.total), "skategm_mid", w - w * 0.03, h * 0.065, white, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)
	end
	-- the current line, bottom left: call-outs above the trick name above the
	-- line score (with its multiplier), its timer bar, the pending sequence
	local lx, base = w * 0.03, h * 0.78
	local active = H.line > 0 or H.seq > 0 or H.lineT > 0
	if active and show and cvLine:GetBool() then
		local y = base
		Shadowed(Commas(H.line), "skategm_huge", lx, y, white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		if H.mult > 1.001 then
			surface.SetFont("skategm_huge")
			local tw = surface.GetTextSize(Commas(H.line))
			Shadowed(string.format("x%s", (H.mult % 1 == 0) and tostring(math.floor(H.mult)) or string.format("%.1f", H.mult)),
				"skategm_big", lx + tw + h * 0.01, y + h * 0.006, Color(255, 220, 90), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		end
		local bw, bh, by = w * 0.11, math.max(3, h * 0.004), y + h * 0.045
		local frac = math.Clamp(H.lineT / H.lineCap, 0, 1)
		surface.SetDrawColor(0, 0, 0, 150)
		surface.DrawRect(lx - 2, by - 2, bw + 4, bh + 4)
		surface.SetDrawColor(255, 220, 90, 230)
		surface.DrawRect(lx, by, bw * frac, bh)
		if H.seq > 0 then
			Shadowed("+" .. Commas(H.seq), "skategm_cmid", lx, by + bh + h * 0.006, Color(180, 230, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		end
	end
	-- trick name, just above the line score, fading out after it was last done
	local age = now - H.trickT
	local ty = base - h * 0.035
	if H.trick ~= "" and age < 2.5 and show and cvTrick:GetBool() then
		local a = age < 1.8 and 1 or 1 - (age - 1.8) / 0.7
		Shadowed(string.upper(H.trick), "skategm_big", lx, ty, white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, a)
		if H.switch then Shadowed("SWITCH", "skategm_csmall", lx, ty - h * 0.0125, Color(200, 200, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, a) end
	end
	S.MarkerPaint(w, h)
	if WATER.fade > 0 then
		surface.SetDrawColor(8, 20, 30, 255 * WATER.fade)
		surface.DrawRect(0, 0, w, h)
	end
	-- call-outs: clean / sketchy / line banked / bailed - stacked upward above
	-- the trick name, newest nearest it
	local ey = ty - h * 0.045
	for i = #H.events, 1, -1 do
		local e = H.events[i]
		local eage = now - e.t
		if eage > 1.8 then table.remove(H.events, i) end
	end
	for _, e in ipairs((show and cvCallouts:GetBool()) and H.events or {}) do
		local eage = now - e.t
		local a = eage < 1.2 and 1 or 1 - (eage - 1.2) / 0.6
		Shadowed(e.text, e.big and "skategm_big" or "skategm_cmid", lx, ey, e.col, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, a)
		ey = ey - h * (e.big and 0.03 or 0.0225)
	end
end

local hudPanel
local function EnsureHud()
	if IsValid(hudPanel) then return end
	hudPanel = vgui.Create("DPanel")
	hudPanel:SetPos(0, 0)
	hudPanel:SetSize(ScrW(), ScrH())
	hudPanel:SetMouseInputEnabled(false)
	hudPanel:SetKeyboardInputEnabled(false)
	hudPanel.Paint = function(self, w, h)
		if self:GetWide() ~= ScrW() or self:GetTall() ~= ScrH() then self:SetSize(ScrW(), ScrH()) end
		local ok, err = pcall(S.HudPaint, w, h, RealTime())
		if not ok and not S.hudErr then S.hudErr = tostring(err) Say("score display error: " .. S.hudErr, true) end
	end
end
S.EnsureHud = EnsureHud

-- hide GMod's own health / ammo boxes while skating
-- (while loading too, and the other bits of that corner: the skater can't be
-- hurt, so health means nothing)
local HIDDEN = { CHudHealth = true, CHudBattery = true, CHudAmmo = true, CHudSecondaryAmmo = true, CHudCrosshair = true,
	CHudSuitPower = true, CHudDamageIndicator = true, CHudPoisonDamageIndicator = true, CHudGeiger = true,
	CHudWeaponSelection = true }
hook.Add("HUDShouldDraw", "skategm", function(name)
	if S.phase ~= "off" and HIDDEN[name] then
		return false
	end
end)

L.EnsureHud, L.H, L.Shadowed, L.cvHud = EnsureHud, H, Shadowed, cvHud
