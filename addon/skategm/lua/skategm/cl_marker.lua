local S = SkateGM
local L = S.L
local H, Shadowed, cvSounds = L.H, L.Shadowed, L.cvSounds

---------------------------------------------------------------------------
-- Session marker (the game's own: LB + D-pad down sets, LB + hold D-pad up
-- returns; on keyboard R sets, hold F returns). The engine does the placing,
-- validity checks and returning; this is the display and the sounds.
---------------------------------------------------------------------------
local MK = { pos = nil, events = {} }
S.MK = MK
local MARK_SOUNDS = { set = "buttons/button9.wav", deny = "buttons/button10.wav", back = "buttons/blip1.wav" }

function S.MarkerUpdate(m, now, skaterPos)
	if not m then return end
	local pos = m.pos and Vector(m.pos[1], m.pos[2], m.pos[3]) or nil
	local placed = pos and (not MK.pos or (pos - MK.pos):LengthSqr() > 1)
	if placed then
		table.insert(H.events, 1, { text = "MARKER SET", col = Color(120, 220, 255), t = now })
		if cvSounds:GetBool() then surface.PlaySound(MARK_SOUNDS.set) end
	end
	-- the return: progress was filling and the skater jumped to the marker
	if MK.progress and MK.progress > 0.5 and m.progress < 0.1 and pos and skaterPos and (skaterPos - pos):Length() < 80 then
		if cvSounds:GetBool() then surface.PlaySound(MARK_SOUNDS.back) end
	end
	MK.pos, MK.active, MK.canPlace, MK.canReturn, MK.progress = pos, m.active, m.canPlace, m.canReturn, m.progress or 0
end

-- while LB is held: a D-pad, each action written beyond its own arm (up
-- above, down below, left and right to the sides); RB and X in a column to
-- the right
CreateClientConVar("skategm_hud_lb", "1", true, false, "Show the LB overlay (marker and LB controls)", 0, 1)
CreateClientConVar("skategm_hud_marker", "1", true, false, "Show the marker beacon", 0, 1)
function S.MarkerPaint(w, h)
	if S.noPad then
		Shadowed("No controller found", "skategm_big", w / 2, h * 0.45, Color(255, 220, 120), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		local found = S.padName and S.padName:match("^none usable %((.+)%)$")
		local why = found and (found .. ": add its mapping to garrysmod/data/skategm/gamecontrollerdb.txt")
			or "Xbox, PlayStation, Switch Pro and most other pads work"
		Shadowed(why, "skategm_cmid", w / 2, h * 0.45 + h * 0.035, Color(230, 230, 230), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		Shadowed("or skate with the keyboard: W / Space push, A / D steer, arrows for tricks, Enter for menus", "skategm_cmid", w / 2, h * 0.45 + h * 0.065,
			Color(200, 220, 235), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
	-- (input taken by a menu or the park editor: the engine never saw LB let go)
	if not MK.active or S.inputBlocked or not S.HudShows("skategm_hud_lb") then return end
	local cx, cy = w / 2, h * 0.82
	local u = math.max(8, math.floor(h * 0.018)) -- one arm's width
	local gap = u * 0.45 -- between an arm and its words
	local on, offc = Color(120, 220, 255, 235), Color(150, 150, 150, 150)
	local games = SKATEGM_MODES ~= nil and SKATEGM_MODES.menu ~= nil
	local PAD = SKATEGM_UI and SKATEGM_UI.pad
	local keys = PAD and PAD.KeyboardHints and PAD.KeyboardHints()
	if keys and PAD.Fonts then PAD.Fonts() end
	local function arm(x, y, lit, name)
		surface.SetDrawColor(0, 0, 0, 160)
		surface.DrawRect(x - 2, y - 2, u + 4, u + 4)
		local c = lit and on or Color(70, 70, 70, 210)
		surface.SetDrawColor(c.r, c.g, c.b, c.a)
		surface.DrawRect(x, y, u, u)
		local label = keys and name and PAD.KeyLabel(name)
		if label then
			draw.SimpleText(label, "skategm_ui_key", x + u / 2, y + u / 2, lit and Color(10, 10, 10) or color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end
	local blocked = S.markerBlockSent
	local canReturn, canPlace = MK.canReturn and not blocked, MK.canPlace and not blocked
	arm(cx - u / 2, cy - u / 2, false)
	arm(cx - u / 2, cy - u * 1.5, canReturn, "UP")
	arm(cx - u / 2, cy + u / 2, canPlace, "DOWN")
	arm(cx - u * 1.5, cy - u / 2, games, "LEFT")
	arm(cx + u / 2, cy - u / 2, games, "RIGHT")
	local top, bottom, left, right = cy - u * 1.5 - gap, cy + u * 1.5 + gap, cx - u * 1.5 - gap, cx + u * 1.5 + gap
	if blocked then
		Shadowed("no markers in a minigame", "skategm_cmid", cx, top, offc, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM)
	else
		Shadowed("return to marker (hold)", "skategm_cmid", cx, top, canReturn and on or offc, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM)
		Shadowed("set marker", "skategm_cmid", cx, bottom, canPlace and on or offc, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	end
	if games then
		Shadowed("minigames", "skategm_cmid", left, cy, on, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		Shadowed("players", "skategm_cmid", right, cy, on, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end
	-- holding up: how far the return has got, between the arm and its words
	if canReturn and (MK.progress or 0) > 0 then
		local bw, bh = u * 3, math.max(2, math.floor(u * 0.18))
		local bx, by = cx - bw / 2, cy - u * 1.5 - gap / 2 - bh / 2
		surface.SetDrawColor(0, 0, 0, 150)
		surface.DrawRect(bx - 1, by - 1, bw + 2, bh + 2)
		surface.SetDrawColor(on.r, on.g, on.b, on.a)
		surface.DrawRect(bx, by, bw * math.Clamp(MK.progress, 0, 1), bh)
	end
	-- the LB combos (respawn, replays, park editor, map, settings...): a
	-- column to the right, as they registered themselves (skategm_ui)
	local UI = SKATEGM_UI
	if UI and UI.ComboHints then UI.pad.Legend(UI.ComboHints(), w, h, { cx + u * 7.5, cy - u * 1.8, column = true, font = "skategm_cmid", color = on }) end
end

-- a glowing post where the marker is
function S.MarkerDraw()
	if not MK.pos or not S.HudShows("skategm_hud_marker") then return end
	render.SetColorMaterial()
	local base = MK.pos - Vector(0, 0, 10)
	local pulse = 0.6 + 0.4 * math.sin(RealTime() * 4)
	render.DrawBox(base, angle_zero, Vector(-0.6, -0.6, 0), Vector(0.6, 0.6, 48), Color(120, 220, 255, 200 * pulse))
	for i = 0, 15 do
		local a0, a1 = i / 16 * math.pi * 2, (i + 1) / 16 * math.pi * 2
		render.DrawLine(base + Vector(math.cos(a0), math.sin(a0), 0) * 10, base + Vector(math.cos(a1), math.sin(a1), 0) * 10, Color(120, 220, 255, 255 * pulse), true)
	end
end
