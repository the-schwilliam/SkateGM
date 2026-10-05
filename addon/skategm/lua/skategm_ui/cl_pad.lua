---------------------------------------------------------------------------
-- The controller UI every SkateGM screen shares (the minigame menu, the park
-- editor, the map, settings, replays):
--   one controller loop     UI.Think feeds the open screen, else the LB combos
--   LB combos               UI.Combo(button, { open, allowed }) - LB + button
--   screens                 UI.Take(name, screen, view) / UI.Give(name):
--                           screen = { press(btn, buttons), think(pad, now, dt) }
--   list menus              UI.List.Input / UI.List.Paint over a page stack
--   control hints           PAD.Legend(rows, w, h, where), PAD.Glyph
--   a free camera           UI.Fly(cam, pad, dt, speed)
-- Any file using it loads it first (load order between add-on folders isn't
-- fixed): if not (SKATEGM_UI and SKATEGM_UI.pad) then include("skategm_ui/cl_pad.lua") end
---------------------------------------------------------------------------
SKATEGM_UI = SKATEGM_UI or {}
local UI = SKATEGM_UI
local PAD = UI.pad or {}
UI.pad = PAD
UI.combos = UI.combos or {}
PAD.loaded = true

PAD.B = { UP = 0x0001, DOWN = 0x0002, LEFT = 0x0004, RIGHT = 0x0008, START = 0x0010, LB = 0x0100, RB = 0x0200, A = 0x1000, B = 0x2000, X = 0x4000, Y = 0x8000 }
local B = PAD.B
PAD.DEADZONE = 0.2
PAD.REPEAT_DELAY, PAD.REPEAT_RATE = 0.35, 0.09
PAD.REPEATS = { [B.UP] = true, [B.DOWN] = true, [B.LEFT] = true, [B.RIGHT] = true }

function PAD.API() return SkateGM and SkateGM.API end
function PAD.Pad() local a = PAD.API() return a and a.Pad and a.Pad() end
function PAD.Dead(v) if math.abs(v or 0) < PAD.DEADZONE then return 0 end return v end
function PAD.Held(pad, b) return bit.band(pad.buttons or 0, b) ~= 0 end

-- presses (with repeat on the D-pad) for whoever feeds it: w:Feed(pad, now,
-- fn, repeating) calls fn(button, buttons) for each new press
function PAD.Watcher()
	local w = { held = {} }
	function w:Feed(pad, now, fn, repeating)
		for _, b in pairs(B) do
			local down = bit.band(pad.buttons or 0, b) ~= 0
			local h = self.held[b]
			if down and not h then
				self.held[b] = now + PAD.REPEAT_DELAY
				fn(b, pad.buttons)
			elseif down and PAD.REPEATS[b] and repeating ~= false and now >= h then
				self.held[b] = now + PAD.REPEAT_RATE
				fn(b, pad.buttons)
			elseif not down then
				self.held[b] = nil
			end
		end
	end
	function w:Reset() self.held = {} end
	-- (buttons already down don't count as presses until let go)
	function w:Prime(pad, now)
		for _, b in pairs(B) do
			if bit.band(pad.buttons or 0, b) ~= 0 then self.held[b] = now + 3600 end
		end
	end
	return w
end
UI.watch = UI.watch or PAD.Watcher()

---------------------------------------------------------------------------
-- screens: one open at a time; it gets the controller and (optionally) the
-- camera, and the skater waits
---------------------------------------------------------------------------
function UI.Busy() return UI.open ~= nil end
function UI.IsOpen(name) return UI.open == name end

function UI.Take(name, screen, view, keepSkater)
	local a = PAD.API()
	if UI.open and UI.open ~= name and UI.screen and UI.screen.close then UI.screen.close() end
	UI.open, UI.screen = name, screen or {}
	UI.screen.keepSkater = keepSkater
	if a then
		if a.Freeze and not keepSkater then a.Freeze(true) end
		if a.BlockInput then a.BlockInput(true) end
		if a.SetView then a.SetView(view) end
	end
	local pad = PAD.Pad()
	if pad then UI.watch:Prime(pad, RealTime()) end
end

-- (only the screen that's open gives it back)
function UI.Give(name)
	if name and UI.open ~= name then return end
	local a = PAD.API()
	local keep = UI.screen and UI.screen.keepSkater
	UI.open, UI.screen = nil, nil
	if a then
		if a.SetView then a.SetView(nil) end
		if a.BlockInput then a.BlockInput(false) end
		if a.Freeze and not keep then a.Freeze(false) end
	end
	local pad = PAD.Pad()
	if pad then UI.watch:Prime(pad, RealTime()) end
end

-- LB + button opens something: def = { open = fn, allowed = fn (optional),
-- label = what the LB overlay calls it (none: not listed there) }
function UI.Combo(button, def) UI.combos[button] = def end

-- the combos the LB overlay lists, in its order, when they're available
UI.COMBO_ORDER = { B.RB, B.X, B.B, B.Y, B.A }
function UI.ComboHints()
	local rows = {}
	for _, b in ipairs(UI.COMBO_ORDER) do
		local c = UI.combos[b]
		if c and c.label and (not c.allowed or c.allowed()) then rows[#rows + 1] = { keys = { PAD.NAMES[b] }, text = c.label } end
	end
	return rows
end

function UI.Press(btn, buttons)
	local s = UI.screen
	if UI.open then
		if s and s.press then s.press(btn, buttons) end
		return
	end
	if bit.band(buttons, B.LB) == 0 then return end
	-- (LB + RB: whichever of the two came second)
	local key = btn
	if btn == B.LB and bit.band(buttons, B.RB) ~= 0 then key = B.RB end
	local c = UI.combos[key]
	if c and (not c.allowed or c.allowed()) then c.open() end
end

function UI.Think(now, dt)
	local pad = PAD.Pad()
	if not pad then
		if UI.open and UI.screen and UI.screen.close then UI.screen.close() end
		if UI.open then UI.Give() end
		UI.watch:Reset()
		return
	end
	if UI.open and UI.screen and UI.screen.think then UI.screen.think(pad, now, dt) end
	UI.watch:Feed(pad, now, UI.Press, UI.open ~= nil)
end

-- a free camera: left stick flies, right stick looks, triggers down / up,
-- RB held faster
function UI.Fly(cam, pad, dt, speed, look, fast)
	local f = (fast and PAD.Held(pad, B.RB)) and fast or 1
	local fwd, right = cam.ang:Forward(), cam.ang:Right()
	local move = fwd * PAD.Dead(pad.ly) + right * PAD.Dead(pad.lx) + Vector(0, 0, (pad.rt or 0) - (pad.lt or 0))
	cam.pos = cam.pos + move * speed * f * dt
	look = look or 140
	cam.ang = Angle(math.Clamp(cam.ang.p - PAD.Dead(pad.ry) * look * 0.7 * dt, -89, 89), cam.ang.y - PAD.Dead(pad.rx) * look * dt, 0)
end

---------------------------------------------------------------------------
-- drawing: fonts, text, the pad's buttons, control hints
---------------------------------------------------------------------------
PAD.GLYPHS = {
	A = { Color(80, 180, 70), "A" }, B = { Color(210, 60, 50), "B" }, X = { Color(50, 120, 220), "X" }, Y = { Color(225, 180, 40), "Y", false, true },
	RB = { Color(200, 200, 200), "RB", true, true }, LB = { Color(200, 200, 200), "LB", true, true },
	RT = { Color(200, 200, 200), "RT", true, true }, LT = { Color(200, 200, 200), "LT", true, true },
	LS = { Color(90, 90, 90), "L" }, RS = { Color(90, 90, 90), "R" },
	START = { Color(90, 90, 90), "MENU", true },
	LEFT = { Color(90, 90, 90), "<" }, RIGHT = { Color(90, 90, 90), ">" }, UP = { Color(90, 90, 90), "^" }, DOWN = { Color(90, 90, 90), "v" },
}
PAD.STYLE_NAMES = { "Automatic", "Xbox", "PlayStation", "Switch" }
PAD.cvStyle = PAD.cvStyle or (CreateClientConVar and CreateClientConVar("skategm_button_style", "0", true, false,
	"Button icons: 0 = the controller in use, 1 = Xbox, 2 = PlayStation, 3 = Switch", 0, 3))
local STYLE_IDS = { "xbox", "playstation", "nintendo" }
function PAD.Style()
	local v = PAD.cvStyle and PAD.cvStyle:GetInt() or 0
	if STYLE_IDS[v] then return STYLE_IDS[v] end
	local a = PAD.API()
	local t = a and a.PadType and a.PadType()
	return (t == "playstation" or t == "nintendo") and t or "xbox"
end
local PS_FACE = {
	A = { Color(124, 178, 232), "cross" }, B = { Color(255, 102, 102), "circle" },
	X = { Color(225, 135, 200), "square" }, Y = { Color(64, 226, 160), "triangle" },
}
PAD.WORDS = {
	playstation = { LB = "L1", RB = "R1", LT = "L2", RT = "R2", A = "Cross", B = "Circle", X = "Square", Y = "Triangle", START = "OPTIONS" },
	nintendo = { LB = "L", RB = "R", LT = "ZL", RT = "ZR", A = "B", B = "A", X = "Y", Y = "X", START = "+" },
}
function PAD.T(text)
	local keys = PAD.KeyboardHints()
	local words = keys and PAD.KEYBOARD_LABELS or PAD.WORDS[PAD.Style()]
	if not words or type(text) ~= "string" then return text end
	local function word(k) return keys and PAD.KeyLabel(k) or words[k] end
	text = text:gsub("%f[%w]([LR][BT])%f[%W]", word)
	if keys then text = text:gsub("D%-pad (%a+)", function(d) return PAD.KeyLabel(d:upper()) or ("D-pad " .. d) end) end
	return (text:gsub("([%+%(] ?)([ABXY])%f[%W]", function(pre, k) return pre .. word(k) end))
end
PAD.KEYBOARD_LABELS = { A = "Space", B = "S", X = "Shift", Y = "F", LB = "Z", RB = "C", LT = "Q", RT = "E", LS = "WASD", RS = "Arrows",
	UP = "I", DOWN = "K", LEFT = "U", RIGHT = "O", START = "Enter" }
function PAD.KeyboardHints()
	local api = PAD.API()
	return api and api.KeyboardHints and api.KeyboardHints() or false
end
PAD.KEYBOARD_MENU_LABELS = { B = "Backspace", LS = "WASD" }
function PAD.KeyLabel(name)
	if PAD.KeyboardHints() then return (UI.open and PAD.KEYBOARD_MENU_LABELS[name]) or PAD.KEYBOARD_LABELS[name] end
end
function PAD.GlyphWidth(name, size)
	local label = PAD.KeyLabel(name)
	if label then
		surface.SetFont("skategm_ui_key")
		return math.max(size, (surface.GetTextSize(label) or 0) + size * 0.5)
	end
	local g = PAD.GLYPHS[name]
	return g and (g[3] and size * 1.6 or size) or 0
end
PAD.NAMES = { [B.A] = "A", [B.B] = "B", [B.X] = "X", [B.Y] = "Y", [B.LB] = "LB", [B.RB] = "RB", [B.UP] = "UP", [B.DOWN] = "DOWN", [B.LEFT] = "LEFT", [B.RIGHT] = "RIGHT" }
PAD.WHITE, PAD.DIM, PAD.GREY, PAD.BLUE = Color(255, 255, 255), Color(120, 120, 120), Color(170, 170, 170), Color(120, 220, 255)
PAD.PANEL, PAD.SEL = Color(0, 0, 0, 190), Color(120, 220, 255, 60)
local WHITE, DIM, GREY, BLUE, PANEL, SEL = PAD.WHITE, PAD.DIM, PAD.GREY, PAD.BLUE, PAD.PANEL, PAD.SEL

local fontsAt
function PAD.Fonts()
	local h = ScrH()
	if fontsAt == h then return end
	fontsAt = h
	surface.CreateFont("skategm_ui_title", { font = "Roboto", size = math.max(20, math.floor(h * 0.034)), weight = 900 })
	surface.CreateFont("skategm_ui_row", { font = "Roboto", size = math.max(16, math.floor(h * 0.024)), weight = 700 })
	surface.CreateFont("skategm_ui_sub", { font = "Roboto", size = math.max(12, math.floor(h * 0.017)), weight = 500 })
	surface.CreateFont("skategm_ui_key", { font = "Roboto", size = math.max(11, math.floor(h * 0.017)), weight = 900 })
end

function PAD.Text(t, font, x, y, col, ax, ay)
	t = PAD.T(t)
	draw.SimpleText(t, font, x + 2, y + 2, Color(0, 0, 0, 180), ax or TEXT_ALIGN_LEFT, ay or TEXT_ALIGN_TOP)
	draw.SimpleText(t, font, x, y, col or WHITE, ax or TEXT_ALIGN_LEFT, ay or TEXT_ALIGN_TOP)
end

-- one button as it looks on the pad; returns its width
local function Shape(kind, cx, cy, size, col)
	local r, t = size * 0.27, math.max(2, size * 0.11)
	local back = Color(35, 35, 40)
	if kind == "circle" then
		draw.RoundedBox(r, cx - r, cy - r, r * 2, r * 2, col)
		draw.RoundedBox(r - t, cx - r + t, cy - r + t, (r - t) * 2, (r - t) * 2, back)
	elseif kind == "square" then
		surface.SetDrawColor(col)
		surface.DrawRect(cx - r, cy - r, r * 2, r * 2)
		surface.SetDrawColor(back)
		surface.DrawRect(cx - r + t, cy - r + t, (r - t) * 2, (r - t) * 2)
	elseif kind == "cross" then
		draw.NoTexture()
		surface.SetDrawColor(col)
		surface.DrawTexturedRectRotated(cx, cy, r * 2.4, t, 45)
		surface.DrawTexturedRectRotated(cx, cy, r * 2.4, t, -45)
	else
		local function tri(k)
			return { { x = cx, y = cy - r * 1.05 * k }, { x = cx + r * 1.2 * k, y = cy + r * 0.65 * k }, { x = cx - r * 1.2 * k, y = cy + r * 0.65 * k } }
		end
		draw.NoTexture()
		surface.SetDrawColor(col)
		surface.DrawPoly(tri(1))
		surface.SetDrawColor(back)
		surface.DrawPoly(tri(1 - t * 1.2 / r))
	end
end

function PAD.Glyph(name, x, y, size)
	local label = PAD.KeyLabel(name)
	if label then
		local wide = PAD.GlyphWidth(name, size)
		draw.RoundedBox(4, x, y, wide, size, Color(55, 60, 68))
		draw.SimpleText(label, "skategm_ui_key", x + wide / 2, y + size / 2, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		return wide
	end
	local g = PAD.GLYPHS[name]
	if not g then return 0 end
	local style = PAD.Style()
	if style == "playstation" and PS_FACE[name] then
		draw.RoundedBox(size / 2, x, y, size, size, Color(35, 35, 40))
		Shape(PS_FACE[name][2], x + size / 2, y + size / 2, size, PS_FACE[name][1])
		return size
	end
	local words = PAD.WORDS[style]
	if words and words[name] then
		local face = style == "nintendo" and not g[3]
		g = { face and Color(55, 55, 60) or g[1], words[name], g[3], not face and g[4] }
	end
	local wide = g[3] and size * 1.6 or size
	draw.RoundedBox(g[3] and 4 or size / 2, x, y, wide, size, g[1])
	draw.SimpleText(g[2], "skategm_ui_key", x + wide / 2, y + size / 2, g[4] and Color(20, 20, 20) or WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	return wide
end

function PAD.KeySize(h) return math.max(16, math.floor(h * 0.026)) end

-- control hints: rows of { keys = { "A", ... }, text, lit = false greys it,
-- join = "+" between keys (a combo) }. where: "bottom" (one line, centred),
-- "right" (a column at the middle of the right edge), or { x, y } (one line
-- from there, left aligned)
function PAD.Legend(rows, w, h, where)
	PAD.Fonts()
	local size = PAD.KeySize(h)
	local function keys(r, x, y)
		for i, k in ipairs(r.keys) do
			x = x + PAD.Glyph(k, x, y, size) + 4
			if r.join and i < #r.keys then
				draw.SimpleText(r.join, "skategm_ui_row", x + 1, y + size / 2, WHITE, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				x = x + size * 0.6
			end
		end
		return x
	end
	if type(where) == "table" and where.column then
		local x, y = where[1], where[2]
		for _, r in ipairs(rows) do
			local tx = keys(r, x, y)
			PAD.Text(r.text, where.font or "skategm_ui_row", tx + 4, y + size / 2, r.lit == false and DIM or (where.color or WHITE), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			y = y + size * 1.4
		end
		return
	end
	if where == "right" then
		local rowH = size * 1.35
		local pw = w * 0.22
		local x = w - pw - w * 0.02
		local y = h * 0.5 - #rows * rowH / 2
		draw.RoundedBox(10, x - 12, y - 12, pw + 24, #rows * rowH + 24 - rowH * 0.35, PANEL)
		for _, r in ipairs(rows) do
			if r.gap then
				surface.SetDrawColor(255, 255, 255, 40)
				surface.DrawRect(x, y + rowH * 0.2, pw, 1)
				y = y + rowH * 0.5
			else
				keys(r, x, y)
				draw.SimpleText(r.text, "skategm_ui_row", x + size * 3.6, y + size / 2, r.lit == false and DIM or WHITE, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				y = y + rowH
			end
		end
		return
	end
	surface.SetFont("skategm_ui_sub")
	local function width(r)
		local kw = 0
		for _, k in ipairs(r.keys) do kw = kw + PAD.GlyphWidth(k, size) + 4 end
		surface.SetFont("skategm_ui_sub")
		return kw + (r.join and size * 0.6 * (#r.keys - 1) or 0) + 2 + surface.GetTextSize(r.text) + size * 1.2
	end
	local lines, line, lineW = {}, {}, 0
	local maxW = type(where) == "table" and math.huge or w * 0.94
	for _, r in ipairs(rows) do
		if not r.gap then
			local rw = width(r)
			if #line > 0 and lineW + rw > maxW then
				lines[#lines + 1] = { rows = line, w = lineW }
				line, lineW = {}, 0
			end
			line[#line + 1] = r
			lineW = lineW + rw
		end
	end
	if #line > 0 then lines[#lines + 1] = { rows = line, w = lineW } end
	local step = size + 22
	for n, l in ipairs(lines) do
		local x, y
		if type(where) == "table" then x, y = where[1], where[2] + (n - 1) * step
		else x, y = (w - l.w) / 2, h * 0.93 - (#lines - n) * step end
		if where == "bottom" or where == nil then draw.RoundedBox(8, x - 12, y - 8, l.w + 12, size + 16, PANEL) end
		for _, r in ipairs(l.rows) do
			x = keys(r, x, y)
			draw.SimpleText(r.text, "skategm_ui_sub", x + 2, y + size / 2, r.lit == false and DIM or WHITE, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			x = x + surface.GetTextSize(r.text) + size * 1.2
		end
	end
	return #lines
end

---------------------------------------------------------------------------
-- list menus: a stack of pages. page = { title, rows = list or fn,
-- sel, hints = { legend rows } or fn, preview = fn(row, x, y, w, h) }
-- row = { label, sub, value = fn -> text, change = fn(dir), page = fn ->
--   page, run = fn, press = fn (A), aText = what A says, heading, disabled,
--   mark = fn, actions = { [button] = fn }, hints = { legend rows } }
---------------------------------------------------------------------------
local List = UI.List or {}
UI.List = List
List.VISIBLE = 11

-- rows for values: each takes get / set functions (a setting, a host option...)
function List.Heading(label) return { label = label, heading = true } end
function List.Bool(label, get, set)
	return { label = label, value = function() return get() and "On" or "Off" end, change = function() set(not get()) end }
end
-- names: what each choice reads as; get returns 1..#names
function List.Choice(label, names, get, set, play)
	return { label = label, value = function() return names[get()] or "?" end, change = function(dir)
		local i = (get() - 1 + dir) % #names + 1
		set(i)
		if play then play(i) end
	end }
end
function List.Number(label, min, max, step, fmt, get, set)
	return { label = label, value = function() local v = get() return fmt and fmt(v) or tostring(v) end, change = function(dir)
		set(math.Clamp(math.Round((get() + dir * step) / step) * step, min, max))
	end }
end
-- palette = { { name, "r g b" }, ... }; get / set work in "r g b"
function List.Parse(s)
	local r, g, b = tostring(s or ""):match("^%s*(%d+)%s+(%d+)%s+(%d+)%s*$")
	if r then return Color(tonumber(r), tonumber(g), tonumber(b)) end
end
function List.Nearest(palette, s)
	local c = List.Parse(s)
	if not c then return 1, false end
	local best, bestD = 1, math.huge
	for i, e in ipairs(palette) do
		local o = List.Parse(e[2])
		local d = (o.r - c.r) ^ 2 + (o.g - c.g) ^ 2 + (o.b - c.b) ^ 2
		if d < bestD then best, bestD = i, d end
	end
	return best, bestD < 1
end
function List.Colour(label, palette, get, set)
	return { label = label, swatch = function() return List.Parse(get()) end,
		value = function() local i, exact = List.Nearest(palette, get()) return exact and palette[i][1] or "Custom" end,
		change = function(dir) local i = List.Nearest(palette, get()) set(palette[(i - 1 + dir) % #palette + 1][2]) end }
end

function List.Rows(page)
	if type(page.rows) == "function" then return page.rows() end
	return page.rows or {}
end

-- the next row from i in dir that isn't a heading
function List.Step(rows, i, dir)
	local n = #rows
	if n == 0 then return 1 end
	local j = i
	for _ = 1, n do
		j = (j - 1 + dir) % n + 1
		if not rows[j].heading then return j end
	end
	return i
end

function List.Push(stack, page)
	page.sel = page.sel or 1
	local rows = List.Rows(page)
	if rows[page.sel] and rows[page.sel].heading then page.sel = List.Step(rows, page.sel, 1) end
	stack[#stack + 1] = page
end

-- one press on the page on top; returns "empty" once B took the last page off
function List.Input(stack, btn)
	local page = stack[#stack]
	if not page then return "empty" end
	local rows = List.Rows(page)
	page.sel = math.Clamp(page.sel or 1, 1, math.max(1, #rows))
	local row = rows[page.sel]
	if btn == B.UP then page.sel = List.Step(rows, page.sel, -1)
	elseif btn == B.DOWN then page.sel = List.Step(rows, page.sel, 1)
	elseif (btn == B.LEFT or btn == B.RIGHT) and row and row.change and not row.disabled then
		row.change(btn == B.RIGHT and 1 or -1)
	elseif btn == B.A and row and not row.disabled then
		if row.page then List.Push(stack, row.page())
		elseif row.run then row.run()
		elseif row.press then row.press()
		elseif row.change then row.change(1) end
	elseif btn == B.B then
		stack[#stack] = nil
		if #stack == 0 then return "empty" end
	elseif row and not row.disabled and row.actions and row.actions[btn] then
		row.actions[btn]()
	end
end

-- what each button does on this row, for the hints
function List.Hints(stack, row, page)
	local out = { { keys = { "UP", "DOWN" }, text = "Choose" } }
	if row and row.change and not row.disabled then out[#out + 1] = { keys = { "LEFT", "RIGHT" }, text = "Change" } end
	if row and (row.page or row.run or row.press) then
		local aText = row.aText
		if type(aText) == "function" then aText = aText() end
		out[#out + 1] = { keys = { "A" }, text = aText or (row.page and "Open" or "Select"), lit = not row.disabled }
	end
	local rowHints = row and row.hints
	if type(rowHints) == "function" then rowHints = rowHints() end
	for _, h in ipairs(rowHints or {}) do out[#out + 1] = h end
	local extra = page and page.hints
	if type(extra) == "function" then extra = extra(row) end
	for _, h in ipairs(extra or {}) do out[#out + 1] = h end
	out[#out + 1] = { keys = { "B" }, text = #stack > 1 and "Back" or "Close" }
	return out
end

-- the page on top, as a panel on the left (opts.x, opts.width as fractions
-- of the screen, opts.note = { text, t } under it), its hints at the bottom
function List.Paint(stack, w, h, opts)
	opts = opts or {}
	local page = stack[#stack]
	if not page then return end
	PAD.Fonts()
	local rows = List.Rows(page)
	local x, y, pw, rowH = w * (opts.x or 0.05), h * (opts.y or 0.16), w * (opts.width or 0.38), h * 0.052
	local visible = math.min(#rows, opts.visible or List.VISIBLE)
	page.sel = math.Clamp(page.sel or 1, 1, math.max(1, #rows))
	local first = math.Clamp(page.sel - math.floor(visible / 2), 1, math.max(1, #rows - visible + 1))
	draw.RoundedBox(10, x - 16, y - h * 0.065, pw + 32, h * 0.085 + visible * rowH + h * 0.02, PANEL)
	PAD.Text(page.title or "", "skategm_ui_title", x, y - h * 0.055)
	for i = first, first + visible - 1 do
		local row = rows[i]
		local ry = y + (i - first) * rowH
		if row.heading then
			PAD.Text(row.label, "skategm_ui_sub", x, ry + rowH * 0.35, BLUE)
		else
			if i == page.sel then draw.RoundedBox(6, x - 8, ry - 3, pw + 16, rowH - 3, SEL) end
			local mark = row.mark and row.mark() and "  *" or ""
			PAD.Text(row.label .. mark, "skategm_ui_row", x, ry, row.disabled and GREY or WHITE)
			local v = row.value and row.value()
			local vx = x + pw
			if row.swatch then
				local c = row.swatch()
				if c then
					local sw = rowH * 0.5
					draw.RoundedBox(4, vx - sw, ry + rowH * 0.12, sw, sw, c)
					vx = vx - sw - 8
				end
			end
			if v then
				local text = (row.change and i == page.sel) and ("< " .. v .. " >") or v
				PAD.Text(text, "skategm_ui_row", vx, ry, i == page.sel and BLUE or GREY, TEXT_ALIGN_RIGHT)
			elseif row.sub then
				PAD.Text(row.sub, "skategm_ui_sub", x + pw, ry + rowH * 0.15, GREY, TEXT_ALIGN_RIGHT)
			end
			if i == page.sel and page.inline then page.inline(row, x, ry, pw, rowH) end
		end
	end
	local sel = rows[page.sel]
	if page.preview then page.preview(sel, w * 0.5, h * 0.12, w * 0.42, h * 0.68) end
	local note = opts.note
	if note and RealTime() - note.t < 3 then PAD.Text(note.text, "skategm_ui_sub", x, y + visible * rowH + h * 0.01, BLUE) end
	PAD.Legend(List.Hints(stack, sel, page), w, h, "bottom")
end

---------------------------------------------------------------------------
-- the one loop
---------------------------------------------------------------------------
if hook and hook.Add then
	hook.Add("Think", "skategm_ui", function() UI.Think(RealTime(), FrameTime()) end)
end
