---------------------------------------------------------------------------
-- Settings on the controller (LB + A while skating): Playermodel, Board,
-- Camera and Advanced (everything else). Pages are the shared list menu
-- (cl_pad.lua). The playermodel and the board turn slowly on the right; the
-- right stick turns them. Every row is a convar, so the settings also work
-- from the console.
---------------------------------------------------------------------------
if not (SKATEGM_UI and SKATEGM_UI.pad) then include("skategm_ui/cl_pad.lua") end
local UI = SKATEGM_UI
local PAD = UI.pad
local B = PAD.B
local List = UI.List
local SET = UI.settings or {}
UI.settings = SET
SET.SPIN, SET.STICK_TURN = 25, 160
SET.stack = SET.stack or {}

local function CV(name) return GetConVar and GetConVar(name) end
local function Get(name, d) local c = CV(name) return c and c:GetString() or d end
local function Set(name, v) RunConsoleCommand(name, tostring(v)) SET.pending = SET.pending or {} SET.pending[name] = { v = tostring(v), t = RealTime() } end
-- (a console command lands next frame: what was just set, shown meanwhile)
local function Now(name, d)
	local p = SET.pending and SET.pending[name]
	if p and RealTime() - p.t < 0.5 then return p.v end
	return Get(name, d)
end
local function NowNum(name, d) return tonumber(Now(name, tostring(d))) or d end

-- colours to pick from (r g b)
SET.COLOURS = {
	{ "White", "255 255 255" }, { "Black", "25 25 25" }, { "Grey", "130 130 130" }, { "Red", "215 45 40" },
	{ "Orange", "240 130 30" }, { "Yellow", "245 215 50" }, { "Lime", "140 230 60" }, { "Green", "40 160 70" },
	{ "Teal", "30 170 160" }, { "Cyan", "70 200 240" }, { "Blue", "40 90 210" }, { "Purple", "130 60 200" },
	{ "Pink", "240 110 180" }, { "Brown", "120 75 40" }, { "Tan", "200 170 120" }, { "Navy", "25 35 90" },
}

---------------------------------------------------------------------------
-- rows for convars
---------------------------------------------------------------------------
local function BoolRow(label, convar)
	return List.Bool(label, function() return Now(convar, "0") ~= "0" end, function(v) Set(convar, v and 1 or 0) end)
end
-- (first = the convar's value for the first name: 1, or 0 for 0-based ones)
local function ChoiceRow(label, convar, names, play, first)
	first = first or 1
	return List.Choice(label, names, function() return math.Clamp(math.floor(NowNum(convar, first)) - first + 1, 1, #names) end,
		function(i) Set(convar, i + first - 1) end, play)
end
local function NumberRow(label, convar, min, max, step, fmt)
	return List.Number(label, min, max, step, fmt, function() return math.Clamp(NowNum(convar, min), min, max) end, function(v) Set(convar, v) end)
end
local function ColourRow(label, convar)
	return List.Colour(label, SET.COLOURS, function() return Now(convar, "255 255 255") end, function(s) Set(convar, s) end)
end
SET.BoolRow, SET.ChoiceRow, SET.NumberRow, SET.ColourRow = BoolRow, ChoiceRow, NumberRow, ColourRow

-- a board type's or effect's own fields, as rows (and any rows of its own:
-- def.rows(List) -> { rows })
function SET.FieldRows(def, rows)
	if def.rows then for _, r in ipairs(def.rows(List) or {}) do rows[#rows + 1] = r end end
	local byKey, shapesPage = {}, {}
	for _, f in ipairs(def.fields or {}) do
		byKey[f.key] = f
		if f.showWhen then shapesPage[f.showWhen[1]] = true end
	end
	local function shown(f)
		local w = f.showWhen
		local on = w and byKey[w[1]]
		return not on or math.floor(NowNum(on.convar, on.default or 1)) == w[2]
	end
	for _, f in ipairs(def.fields or {}) do
		if f.convar and shown(f) then
			local label = f.label or f.key
			if f.kind == "bool" then rows[#rows + 1] = BoolRow(label, f.convar)
			elseif f.kind == "choice" then
				local names = {}
				for i, c in ipairs(f.choices or {}) do names[i] = type(c) == "table" and c[1] or tostring(c) end
				rows[#rows + 1] = ChoiceRow(label, f.convar, names, shapesPage[f.key] and function() SET.RefreshBoard() end or nil)
			elseif f.kind == "number" then
				rows[#rows + 1] = NumberRow(label, f.convar, f.min, f.max, (f.max - f.min) / 20, function(v) return string.format("%." .. (f.decimals or 2) .. "f", v) end)
			elseif f.kind == "color" then rows[#rows + 1] = ColourRow(label, f.convar)
			end
		end
	end
end

---------------------------------------------------------------------------
-- pages
---------------------------------------------------------------------------
function SET.Models()
	local list = {}
	for name, path in pairs(player_manager and player_manager.AllValidModels and player_manager.AllValidModels() or {}) do list[#list + 1] = { name = name, path = path } end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end

local function ModelPreview(row, x, y, w, h) SET.PaintPreview("model", x, y, w, h, row and row.model) end
local function BoardPreview(row, x, y, w, h) SET.PaintPreview("board", x, y, w, h) end
local TURN = { { keys = { "RS" }, text = "Turn the preview" } }

function SET.ModelPage()
	local models = SET.Models()
	local page = { title = "Choose a playermodel", preview = ModelPreview, hints = TURN, rows = {} }
	local current = Get("cl_playermodel", "kleiner")
	for i, m in ipairs(models) do
		page.rows[i] = { label = m.name, model = m.path, mark = function() return Now("cl_playermodel", current) == m.name end,
			run = function() Set("cl_playermodel", m.name) SET.stack[#SET.stack] = nil end }
		if m.name == current then page.sel = i end
	end
	if #models == 0 then page.rows[1] = { label = "No playermodels found" } end
	return page
end

function SET.PlayerPage()
	return { title = "Playermodel", preview = ModelPreview, hints = TURN, rows = {
		{ label = "Model", page = SET.ModelPage, value = function() return Now("cl_playermodel", "kleiner") end },
		List.Colour("Colour", SET.COLOURS, function()
			local v = Vector(Now("cl_playercolor", "0.24 0.34 0.41"))
			return string.format("%d %d %d", v.x * 255, v.y * 255, v.z * 255)
		end, function(s)
			local c = List.Parse(s)
			Set("cl_playercolor", string.format("%.3f %.3f %.3f", c.r / 255, c.g / 255, c.b / 255))
		end),
	} }
end

function SET.BoardPage()
	local C = BOARD and BOARD.client
	if not C then return { title = "Board", rows = { { label = "The board add-on isn't loaded" } } } end
	local rows = {}
	local page = { title = "Board", preview = BoardPreview, hints = TURN, rows = rows }
	if #BOARD.TYPES > 1 then
		local names, ids = {}, {}
		for i, def in ipairs(BOARD.TYPES) do names[i], ids[i] = def.title, def.id end
		-- (a type brings its own options: the page is built again)
		rows[#rows + 1] = List.Choice("Board type", names, function()
			local cur = Now("skategm_board_type", BOARD.DEFAULT_TYPE)
			for i, id in ipairs(ids) do if id == cur then return i end end
			return 1
		end, function(i)
			Set("skategm_board_type", ids[i])
			local fresh = SET.BoardPage()
			fresh.sel = page.sel
			SET.stack[#SET.stack] = fresh
		end)
	end
	local def = BOARD.Type(Now("skategm_board_type", BOARD.DEFAULT_TYPE)) or BOARD.Type(BOARD.DEFAULT_TYPE)
	rows[#rows + 1] = ColourRow("Deck colour", "skategm_deck_color")
	rows[#rows + 1] = ColourRow("Wheel colour", "skategm_wheel_color")
	if def and def.image and C.ImageFiles then
		local files = C.ImageFiles()
		local can = skategm ~= nil and skategm.PickImage ~= nil
		local names = { "None" }
		for _, f in ipairs(files) do names[#names + 1] = f end
		local add = #names + 1
		if can then names[add] = "Add new..." end
		SET.addPending = nil
		local row = List.Choice("Image under the deck", names, function()
			if SET.addPending then return add end
			local cur = Now("skategm_board_image", "")
			for i, f in ipairs(files) do if f == cur then return i + 1 end end
			return 1
		end, function(i)
			SET.addPending = can and i == add or nil
			if not SET.addPending then Set("skategm_board_image", i == 1 and "" or files[i - 1]) end
		end)
		row.run = function()
			if SET.addPending then return SET.PickImage() end
			row.change(1)
		end
		row.aText = function() return SET.addPending and "Choose a file" or nil end
		local function shown()
			if SET.addPending then return nil end
			local cur = Now("skategm_board_image", "")
			for _, f in ipairs(files) do if f == cur then return f end end
		end
		local function armed(f) return SET.deleteArmed == f and RealTime() - (SET.deleteAt or 0) < 3 end
		row.actions = { [B.X] = function()
			local f = shown()
			if not f then return end
			if not armed(f) then
				SET.deleteArmed, SET.deleteAt = f, RealTime()
				SET.Say("press X again to delete " .. f)
				SET.deleteNote = SET.note
				return
			end
			SET.deleteArmed = nil
			if C.DeleteImage then C.DeleteImage(f) end
			Set("skategm_board_image", "")
			SET.Say("deleted " .. f)
			SET.RefreshBoard()
		end }
		row.hints = function()
			local f = shown()
			if not f then return {} end
			return { { keys = { "X" }, text = armed(f) and "Press again to delete" or "Delete this image" } }
		end
		rows[#rows + 1] = row
	end
	if def then SET.FieldRows(def, rows) end
	rows[#rows + 1] = BoolRow("Rocket board", "skategm_rocket")
	rows[#rows + 1] = BoolRow("Hoverboard", "skategm_hoverboard")
	for _, fx in ipairs(BOARD.EFFECTS) do SET.FieldRows(fx, rows) end
	local roll, rocket = {}, {}
	for i, s in ipairs(BOARD.ROLL_SOUNDS) do roll[i] = s[1] end
	for i, s in ipairs(BOARD.ROCKET_SOUNDS) do rocket[i] = s[1] end
	rows[#rows + 1] = ChoiceRow("Rolling sound", "skategm_roll_sound", roll, function(i) C.TestSound(BOARD.ROLL_SOUNDS[i][2]) end)
	rows[#rows + 1] = ChoiceRow("Rocket sound", "skategm_rocket_sound", rocket, function(i) C.TestSound(BOARD.ROCKET_SOUNDS[i][2]) end)
	rows[#rows + 1] = { label = "Reset my board to default", run = function() if C.Reset then C.Reset() end end }
	return page
end

function SET.CameraPage()
	local fovs, values = { "Skate's own" }, { 0 }
	for f = 50, 120, 5 do fovs[#fovs + 1] = f .. " degrees" values[#values + 1] = f end
	return { title = "Camera", rows = {
		BoolRow("Camera wobble", "skategm_camera_shake"),
		NumberRow("Distance", "skategm_camera_distance", 0.5, 2, 0.1, function(v)
			if math.abs(v - 1) < 0.01 then return "Skate's own" end
			return v < 1 and string.format("closer (%.0f%%)", v * 100) or string.format("further (%.0f%%)", v * 100)
		end),
		List.Choice("Field of view", fovs, function()
			local cur, best = NowNum("skategm_camera_fov", 0), 1
			for i, v in ipairs(values) do if math.abs(v - cur) < 2.5 then best = i end end
			return best
		end, function(i) Set("skategm_camera_fov", values[i]) end),
	} }
end

function SET.Admin()
	local me = LocalPlayer()
	return (game and game.SinglePlayer and game.SinglePlayer()) or (IsValid(me) and me:IsAdmin())
end

local function Percent(v) return string.format("%.0f%%", v * 100) end

-- everything else: screen and sound, riding, collision, the engine, the park
-- editor, the server (host and admins), troubleshooting
function SET.AdvancedPage()
	local S = SkateGM
	local rows = {
		List.Heading("Screen and sound"),
		BoolRow("Trick score display", "skategm_hud"),
		BoolRow("Board sounds", "skategm_sounds"),
		NumberRow("Sound volume", "skategm_sound_volume", 0, 2, 0.1, Percent),
		NumberRow("Boombox volume", "skategm_boombox_volume", 0, 1, 0.05, function(v) return v <= 0 and "muted" or Percent(v) end),
		List.Heading("Controller"),
		ChoiceRow("Button icons", "skategm_button_style", UI.pad.STYLE_NAMES, nil, 0),
		List.Heading("Riding"),
		NumberRow("Top speed", "skategm_speed_limit", 0, 60, 5, function(v) return v <= 0 and "no limit" or string.format("%d m/s", v) end),
		BoolRow("Other players are solid", "skategm_player_collision"),
		BoolRow("RB off the board uses doors and buttons", "skategm_rb_use"),
		BoolRow("Y does nothing in the air", "skategm_block_air_dismount"),
		List.Heading("Collision (applies when it's reloaded)"),
	}
	if S and S.PRESETS then
		local names = {}
		for i, p in ipairs(S.PRESETS) do names[i] = p[1] end
		rows[#rows + 1] = List.Choice("Smoothing preset", names, function()
			for i, p in ipairs(S.PRESETS) do
				if NowNum("skategm_smooth", 1) == p[2] and NowNum("skategm_smooth_creases", 1) == p[3] and NowNum("skategm_smooth_steps", 8) == p[4] then return i end
			end
			return 2
		end, function(i) S.ApplyPreset(i) end)
	end
	rows[#rows + 1] = ChoiceRow("Bumpy terrain", "skategm_smooth", { "as built", "light", "strong" }, nil, 0)
	rows[#rows + 1] = BoolRow("Curves where ramps meet the ground", "skategm_smooth_creases")
	rows[#rows + 1] = NumberRow("Ramp over ledges up to", "skategm_smooth_steps", 0, 12, 1, function(v) return v <= 0 and "off" or string.format("%d units", v) end)
	rows[#rows + 1] = ChoiceRow("Collision style", "skategm_collision_style", { "classic", "experimental" }, nil, 0)
	rows[#rows + 1] = BoolRow("Tiny props are solid", "skategm_tiny_props_solid")
	rows[#rows + 1] = BoolRow("Props with no physics are solid", "skategm_solid_no_physics")
	rows[#rows + 1] = NumberRow("World scale", "skategm_world_scale", 0.5, 1.5, 0.05, function(v) return string.format("%.2f", v) end)
	rows[#rows + 1] = { label = "Reload the collision now", run = function() if S and S.ApplyCollisionNow then S.ApplyCollisionNow() end end }
	rows[#rows + 1] = List.Heading("Engine")
	rows[#rows + 1] = BoolRow("Load the game data when you join", "skategm_warm_engine")
	rows[#rows + 1] = List.Heading("Park editor")
	rows[#rows + 1] = NumberRow("Grid for parts that don't snap", "skategm_parts_grid", 0, 128, 8, function(v) return v <= 0 and "off" or string.format("%d units", v) end)
	if SET.Admin() then
		rows[#rows + 1] = List.Heading("Server (host and admins)")
		rows[#rows + 1] = ChoiceRow("Park editor", "skategm_park_editor", { "off", "everyone", "admins only" }, nil, 0)
		rows[#rows + 1] = BoolRow("Editors can move anyone's parts", "skategm_park_editor_shared")
		rows[#rows + 1] = BoolRow("Skating knocks light props over", "skategm_knock_props")
		rows[#rows + 1] = NumberRow("Heaviest prop knocked over", "skategm_knock_mass", 10, 1000, 10, function(v) return string.format("%d kg", v) end)
		local M = SKATEGM_MODES
		local modes = {}
		for _, mode in pairs(M and M.modes or {}) do if mode.allowedName then modes[#modes + 1] = mode end end
		table.sort(modes, function(a, b) return (a.order or 99) < (b.order or 99) end)
		for _, mode in ipairs(modes) do rows[#rows + 1] = BoolRow("Allow " .. mode.title, mode.allowedName) end
	end
	rows[#rows + 1] = List.Heading("Troubleshooting")
	rows[#rows + 1] = { label = "Game data folder", value = function() return Now("skategm_data", "?") end }
	rows[#rows + 1] = { label = "Print a report to the console", run = function()
		RunConsoleCommand("skategm_report")
		SET.note = { text = "the report is in the console", t = RealTime() }
	end }
	return { title = "Advanced", rows = rows }
end

function SET.DisplayPage()
	return { title = "Display", rows = {
		BoolRow("Show the HUD", "skategm_hud"),
		List.Heading("HUD"),
		BoolRow("Total score", "skategm_hud_total"),
		BoolRow("Line score and multiplier", "skategm_hud_line"),
		BoolRow("Trick names", "skategm_hud_trick"),
		BoolRow("Call-outs (clean, sketchy, marker set...)", "skategm_hud_callouts"),
		BoolRow("LB overlay (marker and LB controls)", "skategm_hud_lb"),
		BoolRow("Marker beacon", "skategm_hud_marker"),
		BoolRow("Flick-it stick", "skategm_flickit_hud"),
		List.Heading("Other players"),
		BoolRow("Show other players' board images", "skategm_show_board_images"),
	} }
end

function SET.MainPage()
	return { title = "Settings", rows = {
		{ label = "Playermodel", page = SET.PlayerPage, sub = "your model and colour" },
		{ label = "Board", page = SET.BoardPage, sub = "colours, image, effects, sounds" },
		{ label = "Camera", page = SET.CameraPage, sub = "wobble, distance, field of view" },
		{ label = "Display", page = SET.DisplayPage, sub = "what the HUD shows" },
		{ label = "Advanced", page = SET.AdvancedPage, sub = "everything else" },
	} }
end

---------------------------------------------------------------------------
-- the screen
---------------------------------------------------------------------------
function SET.Active() return UI.IsOpen("settings") end

function SET.Open()
	if UI.Busy() then return end
	SET.stack, SET.spin = {}, 0
	List.Push(SET.stack, SET.MainPage())
	UI.Take("settings", { press = SET.Press, think = SET.Think })
end

function SET.Close() UI.Give("settings") end
function SET.Top() return SET.stack[#SET.stack] end

function SET.Press(btn)
	if btn ~= B.X and SET.deleteArmed then
		SET.deleteArmed = nil
		if SET.note and SET.note == SET.deleteNote then SET.note = nil end
	end
	if List.Input(SET.stack, btn) == "empty" then SET.Close() end
end

function SET.Say(text) SET.note = { text = text, t = RealTime() } end

function SET.RefreshBoard()
	local top = SET.Top()
	if not (top and top.title == "Board") then return end
	local fresh = SET.BoardPage()
	fresh.sel = top.sel
	SET.stack[#SET.stack] = fresh
end

function SET.FitPage()
	local function choose(fit)
		Set("skategm_board_image_fit", fit)
		SET.stack[#SET.stack] = nil
		SET.RefreshBoard()
	end
	return { title = "Fit the image", sel = math.Clamp(math.floor(NowNum("skategm_board_image_fit", 1)), 1, 2),
		preview = function(row, x, y, w, h) SET.PaintPreview("under", x, y, w, h, row and row.fit) end, hints = TURN,
		rows = {
			{ label = "Stretch", sub = "fills the whole underside", fit = 1, run = function() choose(1) end },
			{ label = "Fill", sub = "fills it, keeping the picture's shape (edges cut off)", fit = 2, run = function() choose(2) end },
		} }
end

function SET.PickImage()
	if SET.picking or not (skategm and skategm.PickImage) then return end
	if skategm.PickImage() then
		SET.picking = true
		SET.Say("choose a picture in the window that opened")
	end
end

function SET.PickThink()
	if not SET.picking then return end
	local status, value = skategm.PickedImage()
	if status == "open" then return end
	SET.picking = nil
	if status == "failed" then return SET.Say("couldn't add it: " .. tostring(value)) end
	if status ~= "done" then return end
	local C = BOARD and BOARD.client
	if not (C and C.AddImage) then return end
	SET.Say("adding " .. value .. "...")
	C.AddImage(value, function(name, err)
		if not name then return SET.Say("couldn't add it: " .. tostring(err)) end
		SET.addPending = nil
		Set("skategm_board_image", name)
		SET.Say("added " .. name)
		SET.RefreshBoard()
		List.Push(SET.stack, SET.FitPage())
	end)
end

function SET.Think(pad, now, dt)
	SET.PickThink()
	local stick = PAD.Dead(pad.rx)
	if stick ~= 0 then
		SET.spin = (SET.spin + stick * SET.STICK_TURN * dt) % 360
		SET.stickAt = now
	elseif now - (SET.stickAt or -10) > 1.5 then
		SET.spin = (SET.spin + SET.SPIN * dt) % 360
	end
	SET.tilt = math.Clamp((SET.tilt or 20) - PAD.Dead(pad.ry) * 90 * dt, -60, 80)
end

UI.Combo(B.A, { open = SET.Open, label = "settings" })

---------------------------------------------------------------------------
-- previews
---------------------------------------------------------------------------
-- the board laid out around the origin, turned (yaw) and tipped (pitch)
function SET.BoardPose(yaw, pitch)
	local ang = Angle(pitch or 0, yaw or 0, 0)
	local fwd, right = ang:Forward(), ang:Right()
	local tf, tb = fwd * 7.5, fwd * -7.5
	return { TRUCK_FRONT = tf, TRUCK_BACK = tb, RIGHT_WHEELFRONT = tf + right * 3.2, LEFT_WHEELFRONT = tf - right * 3.2,
		RIGHT_WHEELBACK = tb + right * 3.2, LEFT_WHEELBACK = tb - right * 3.2, HIPS = Vector(0, 0, 40) }
end

local function PlayerColour()
	local pc = Vector(Get("cl_playercolor", "0.24 0.34 0.41"))
	return pc, Color(math.Clamp(pc.x * 255, 30, 255), math.Clamp(pc.y * 255, 30, 255), math.Clamp(pc.z * 255, 30, 255))
end

function SET.DrawBoardPreview(x, y, w, h, under, fit)
	local C = BOARD and BOARD.client
	local S = SkateGM
	if not (C and S and S.DrawBoard) then return end
	local P = SET.BoardPose(SET.spin, 0)
	local look = C.MyLookNow and C.MyLookNow() or nil
	if look and fit then
		local opts = {}
		for k, v in pairs(look.opts or {}) do opts[k] = v end
		opts.fit = fit
		look.opts = opts
	end
	local _, graphic = PlayerColour()
	local ang = Angle(under and -70 or (SET.tilt or 20), 180, 0)
	cam.Start3D(-ang:Forward() * 46, ang, 40, x, y, w, h, 1, 2000)
	render.ClearDepth()
	render.SuppressEngineLighting(true)
	if not C.Draw(LocalPlayer(), P, look, graphic, look and look.rocket, look and look.hover, S.DrawBoard) then
		S.DrawBoard(P, { graphic = graphic })
	end
	render.SuppressEngineLighting(false)
	cam.End3D()
end

function SET.DrawModelPreview(x, y, w, h, path)
	if not ClientsideModel then return end
	path = path or (player_manager and player_manager.TranslatePlayerModel and player_manager.TranslatePlayerModel(Get("cl_playermodel", "kleiner")))
	if not path then return end
	if not (IsValid(SET.model) and SET.modelPath == path) then
		if IsValid(SET.model) then SET.model:Remove() end
		SET.model = ClientsideModel(path, RENDERGROUP_OPAQUE)
		SET.modelPath = path
		if IsValid(SET.model) then
			SET.model:SetNoDraw(true)
			local seq = SET.model:LookupSequence("idle_all_01")
			if seq and seq >= 0 then SET.model:ResetSequence(seq) end
		end
	end
	local e = SET.model
	if not IsValid(e) then return end
	local pc = PlayerColour()
	e.GetPlayerColor = function() return pc end
	e:SetAngles(Angle(0, SET.spin, 0))
	e:FrameAdvance(FrameTime())
	local lo, hi = e:GetRenderBounds()
	local height = math.max(hi.z - lo.z, 40)
	local ang = Angle(math.Clamp((SET.tilt or 20) * 0.4, -20, 35), 180, 0)
	cam.Start3D(Vector(0, 0, (lo.z + hi.z) / 2) - ang:Forward() * height * 1.7, ang, 40, x, y, w, h, 1, 4000)
	render.ClearDepth()
	render.SuppressEngineLighting(true)
	render.ResetModelLighting(0.75, 0.75, 0.75)
	render.SetModelLighting(0, 1, 1, 1)
	e:DrawModel()
	render.SuppressEngineLighting(false)
	cam.End3D()
end

function SET.PaintPreview(kind, x, y, w, h, path)
	if not (cam and cam.Start3D) then return end
	draw.RoundedBox(10, x, y, w, h, Color(0, 0, 0, 120))
	if kind == "model" then SET.DrawModelPreview(x, y, w, h, path)
	else SET.DrawBoardPreview(x, y, w, h, kind == "under", kind == "under" and path or nil) end
end

function SET.Paint(w, h)
	if not SET.Active() then return end
	List.Paint(SET.stack, w, h, { note = SET.note })
end

if hook and hook.Add then
	hook.Add("HUDPaint", "skategm_ui_settings", function() SET.Paint(ScrW(), ScrH()) end)
end
