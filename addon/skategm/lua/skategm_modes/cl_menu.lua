---------------------------------------------------------------------------
-- The minigame menu (LB + D-pad left: Minigames, LB + D-pad right: Players)
-- on the shared controller UI (skategm_ui/cl_pad.lua): its pages are list
-- pages, spectating and placing a point (a free camera) are its own modes.
---------------------------------------------------------------------------
if not (SKATEGM_UI and SKATEGM_UI.pad) then include("skategm_ui/cl_pad.lua") end
local UI = SKATEGM_UI
local PAD = UI.pad
local List = UI.List
local M = SKATEGM_MODES
local MENU = M.menu or { stack = {} }
M.menu = MENU
MENU.stack = MENU.stack or {}

local B = PAD.B
MENU.BUTTONS = B
local FLY_SPEED, LOOK_SPEED = 700, 140

local function API() return M.API() end

local function SortedModes(filter)
	local list = {}
	for _, mode in pairs(M.modes) do
		if filter(mode) then list[#list + 1] = mode end
	end
	table.sort(list, function(a, b)
		if a.order ~= b.order then return a.order < b.order end
		return a.title < b.title
	end)
	return list
end

function MENU.Top() return MENU.stack[#MENU.stack] end
function MENU.Push(screen) List.Push(MENU.stack, screen) end
function MENU.IsOpen() return UI.IsOpen("minigames") end

function MENU.Pop()
	MENU.stack[#MENU.stack] = nil
	if #MENU.stack == 0 then MENU.Close() end
end

-- (leaving whatever mode it was in: spectating, placing a point)
function MENU.Cleanup()
	if MENU.fc then MENU.EndFreecam() end
	if MENU.spec then MENU.StopSpectating() end
	MENU.stack = {}
end

function MENU.Close()
	MENU.Cleanup()
	UI.Give("minigames")
end

-- (the menu freezes the skater, as the settings do: no rolling off while you pick)
function MENU.Open(kind)
	if UI.Busy() then return end
	MENU.stack = {}
	local extra = MENU.SCREENS and MENU.SCREENS[kind]
	local mine = kind == "main" and MENU.MyGameScreen()
	MENU.Push(mine or extra and extra() or kind == "join" and MENU.JoinScreen() or kind == "host" and MENU.HostScreen() or (kind == "players" or kind == "spectate") and MENU.PlayersScreen() or MENU.MainScreen())
	UI.Take("minigames", { press = MENU.Input, think = MENU.Think, close = MENU.Cleanup })
end

local function DefaultValues(def)
	local v = {}
	for _, o in ipairs(def.options or {}) do
		if o.type ~= "point" and o.type ~= "object" then v[o.key] = o.default end
		if o.type == "region" and v[o.key] == nil then v[o.key] = o.min end
	end
	return v
end

function MENU.OptionText(o, v)
	if o.type == "bool" then return o.label .. ": " .. (v and "on" or "off") end
	if o.type == "choice" then
		for _, c in ipairs(o.choices) do if c[1] == v then return o.label .. ": " .. c[2] end end
		return o.label .. ": ?"
	end
	if o.type == "point" then return o.label .. ": " .. (v and "placed" or "not placed") end
	if o.type == "object" then return o.label .. ": " .. (v and MENU.ObjectSummary(o, v) or (o.here and "Here" or "not placed")) end
	local shown = o.format and o.format(v) or tostring(v)
	return o.label .. ": " .. shown
end

function MENU.Adjust(o, values, dir)
	local v = values[o.key]
	if o.type == "number" or o.type == "region" then
		local step = o.step or 1
		values[o.key] = math.Clamp((v or o.min) + dir * step, o.min, o.max)
	elseif o.type == "choice" then
		local idx = 1
		for i, c in ipairs(o.choices) do if c[1] == v then idx = i end end
		idx = (idx - 1 + dir) % #o.choices + 1
		values[o.key] = o.choices[idx][1]
	elseif o.type == "bool" then
		values[o.key] = not v
	end
end

function MENU.Missing(def, values)
	for _, o in ipairs(def.options or {}) do
		if (o.type == "point" or o.type == "object") and o.required ~= false and not values[o.key] then return o end
	end
end

function MENU.Resolve(def, values)
	local out = {}
	for k, v in pairs(values) do out[k] = v end
	for _, o in ipairs(def.options or {}) do
		if o.type == "region" then out[o.key] = { centre = values._start and values._start.pos or M.Here(), radius = values[o.key] } end
	end
	return out
end

---------------------------------------------------------------------------
-- presets: a minigame's host settings saved under a name, for this map
-- (data/skategm/presets/<map>/<mode>.json: name -> the options' values)
---------------------------------------------------------------------------
function MENU.PresetFile(mode)
	local map = (game and game.GetMap and game.GetMap() or "map"):gsub("[^%w_%-]", "_")
	return "skategm/presets/" .. map .. "/" .. mode.id .. ".json", "skategm/presets/" .. map
end

function MENU.Presets(mode)
	local path = MENU.PresetFile(mode)
	local text = file and file.Read and file.Read(path, "DATA")
	local t = text and util.JSONToTable(text)
	return type(t) == "table" and t or {}
end

function MENU.WritePresets(mode, presets)
	local path, dir = MENU.PresetFile(mode)
	file.CreateDir("skategm")
	file.CreateDir("skategm/presets")
	file.CreateDir(dir)
	file.Write(path, util.TableToJSON(presets, true))
end

-- only the options the minigame still has, so an old preset can't break it
function MENU.PresetValues(def, values)
	local out = {}
	for _, o in ipairs(def.options or {}) do
		if values[o.key] ~= nil then out[o.key] = values[o.key] end
	end
	return out
end

function MENU.SavePreset(mode, name, values)
	local presets = MENU.Presets(mode)
	presets[name] = { values = MENU.PresetValues(mode.hostDef, values), saved = os.date("%Y-%m-%d %H:%M") }
	MENU.WritePresets(mode, presets)
end

function MENU.DeletePreset(mode, name)
	local presets = MENU.Presets(mode)
	presets[name] = nil
	MENU.WritePresets(mode, presets)
end

-- loading puts the preset's values over the screen's
function MENU.LoadPreset(screen, preset)
	for k, v in pairs(MENU.PresetValues(screen.mode.hostDef, preset.values or {})) do screen.values[k] = v end
end

function MENU.PresetsScreen(screen)
	local mode = screen.mode
	local page = { title = mode.title .. " presets (this map)" }
	page.rows = function()
		local names = {}
		local presets = MENU.Presets(mode)
		for name in pairs(presets) do names[#names + 1] = name end
		table.sort(names, function(x, y) return x:lower() < y:lower() end)
		local rows = {}
		for _, name in ipairs(names) do
			rows[#rows + 1] = { label = name, sub = presets[name].saved, aText = "Load",
				run = function()
					MENU.LoadPreset(screen, presets[name])
					MENU.Pop()
				end,
				actions = { [B.X] = function() MENU.DeletePreset(mode, name) end },
				hints = { { keys = { "X" }, text = "Delete" } } }
		end
		if #rows == 0 then rows[1] = { label = "No presets saved for this map yet", disabled = true } end
		return rows
	end
	return page
end

-- X on the host settings: a name typed on the keyboard, then saved
function MENU.AskPresetName(screen)
	if MENU.naming or not Derma_StringRequest then return end
	local count = 0
	for _ in pairs(MENU.Presets(screen.mode)) do count = count + 1 end
	MENU.naming = true
	Derma_StringRequest("Save preset", "A name for these " .. screen.mode.title .. " settings (on this map):", "Preset " .. (count + 1),
		function(text)
			MENU.naming = nil
			text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
			if text == "" then return end
			MENU.SavePreset(screen.mode, text:sub(1, 48), screen.values)
			screen.note = { text = "saved preset " .. text:sub(1, 48), t = RealTime() }
		end,
		function() MENU.naming = nil end, "Save", "Cancel")
end

function MENU.OptionsScreen(mode)
	local def = mode.hostDef
	local screen = { title = "Host " .. mode.title, mode = mode, values = DefaultValues(def) }
	screen.actions = { [B.X] = function() MENU.AskPresetName(screen) end }
	screen.hints = { { keys = { "X" }, text = "Save as a preset" } }
	screen.preview = function(row, x, y, w, h) MENU.PaintAbout(mode, x, y, w, h) end
	screen.rows = function()
		local rows = {}
		for _, o in ipairs(def.options or {}) do
			local sub = o.help
			if o.type == "point" then sub = screen.values[o.key] and "A: fly there again to move it" or "A: fly there and place it" end
			if o.type == "object" then sub = screen.values[o.key] and "A: move, turn or size it again" or "A: place it (you see it as you go)" end
			if o.type == "object" and o.here then sub = screen.values[o.key] and "A: move it again; left / right: back to Here" or o.help end
			if o.type == "region" then sub = screen.values._start and "around the Start (the ring)" or "around the Start: where you're standing (the ring)" end
			local row = { label = o.label, sub = sub, option = o, value = function()
				local text = MENU.OptionText(o, screen.values[o.key])
				return text:sub(#o.label + 3)
			end }
			if o.type == "point" or o.type == "object" then
				row.press, row.aText = function() MENU.StartFreecam(screen, o) end, o.type == "object" and "Place it" or "Fly there"
				if o.here then row.change = function() screen.values[o.key] = nil end end
			else
				row.change = function(dir) MENU.Adjust(o, screen.values, dir) end
			end
			rows[#rows + 1] = row
		end
		rows[#rows + 1] = { label = "Load a preset", sub = "settings saved on this map", aText = "Open", page = function() return MENU.PresetsScreen(screen) end }
		local missing = MENU.Missing(def, screen.values)
		rows[#rows + 1] = {
			label = "Host it", sub = missing and ("place the " .. missing.label:lower() .. " first") or def.description,
			disabled = missing ~= nil,
			run = function()
				def.start(MENU.Resolve(def, screen.values), mode)
				MENU.Close()
			end,
		}
		return rows
	end
	return screen
end

-- everyone on the server: A invites them; those in a minigame already greyed out
function MENU.InviteScreen(mode)
	local invited = {}
	local screen = { title = "Invite to " .. mode.title, mode = mode }
	screen.rows = function()
		local rows = {}
		for _, ply in ipairs(player and player.GetAll and player.GetAll() or {}) do
			if ply ~= LocalPlayer() then
				local ent = ply:EntIndex()
				if M.GameOf(ply) then
					rows[#rows + 1] = { label = ply:Nick(), sub = "in a minigame already", disabled = true }
				else
					rows[#rows + 1] = { label = ply:Nick(), sub = invited[ent] and "invited" or "A: invite", run = function()
						invited[ent] = true
						mode:Send({ cmd = "_invite", target = ent })
					end }
				end
			end
		end
		if #rows == 0 then rows[1] = { label = "Nobody else is on the server", disabled = true } end
		return rows
	end
	return screen
end

function MENU.InviteRow(mode)
	local st = mode.state
	if not (st and st.phase == "lobby") then return nil end
	return { label = "Invite players", sub = "send someone on the server an invite", run = function() MENU.Push(MENU.InviteScreen(mode)) end }
end

function MENU.ActionsScreen(mode)
	local screen = { title = mode.title .. " (you're hosting)", mode = mode }
	screen.rows = function()
		local rows = {}
		for _, act in ipairs(mode:Actions()) do
			rows[#rows + 1] = { label = act.label, sub = act.sub, run = function() act.run() MENU.Close() end }
		end
		local invite = MENU.InviteRow(mode)
		if invite then table.insert(rows, math.min(2, #rows + 1), invite) end
		return rows
	end
	return screen
end

-- the host list's groups, in this order (a mode's own category comes after
-- them, none at all under Other)
M.CATEGORIES = M.CATEGORIES or { "Tricks", "Sports", "Arena", "Chaos", "Party" }
function MENU.ByCategory(modes)
	local groups, seen = {}, {}
	for i, name in ipairs(M.CATEGORIES) do seen[name] = i end
	for _, mode in ipairs(modes) do
		local name = mode.category or "Other"
		if not groups[name] then groups[name] = {} end
		table.insert(groups[name], mode)
	end
	local names = {}
	for name in pairs(groups) do names[#names + 1] = name end
	table.sort(names, function(a, b)
		local ia, ib = seen[a] or (a == "Other" and 1e6 or 1e5), seen[b] or (b == "Other" and 1e6 or 1e5)
		if ia ~= ib then return ia < ib end
		return a < b
	end)
	local out = {}
	for _, name in ipairs(names) do
		table.sort(groups[name], function(a, b) return a.title < b.title end)
		out[#out + 1] = { name = name, modes = groups[name] }
	end
	return out
end

-- what the game is, beside the list: its name, tagline and paragraph
function MENU.PaintAbout(mode, x, y, w, h)
	local def = mode and mode.hostDef
	if not (def and def.about) then return end
	local lines = M.Wrap(def.about, "skategm_ui_row", w - 32)
	local line = ScrH() * 0.034
	draw.RoundedBox(10, x, y, w, line * (#lines + 3.4) + 24, Color(0, 0, 0, 170))
	PAD.Text(mode.title, "skategm_ui_title", x + 16, y + 12, mode.color or PAD.WHITE)
	PAD.Text(def.description or "", "skategm_ui_sub", x + 16, y + 12 + line * 1.5, Color(200, 200, 200))
	for i, l in ipairs(lines) do PAD.Text(l, "skategm_ui_row", x + 16, y + 12 + line * (i + 1.8), PAD.WHITE) end
end

function MENU.HostScreen()
	local screen = { title = "Host a minigame" }
	screen.preview = function(row, x, y, w, h) MENU.PaintAbout(row and row.mode, x, y, w, h) end
	screen.rows = function()
		local rows = {}
		for _, group in ipairs(MENU.ByCategory(SortedModes(function(m) return m.hostDef ~= nil end))) do
			rows[#rows + 1] = List.Heading(group.name)
			for _, mode in ipairs(group.modes) do
				local others = #mode:Games()
				if not mode:Allowed() then
					rows[#rows + 1] = { label = mode.title, sub = "turned off on this server", disabled = true, mode = mode }
				else
					local sub = mode.hostDef.description .. (others > 0 and string.format(" (%d going already)", others) or "")
					rows[#rows + 1] = { label = mode.title, sub = sub, mode = mode, run = function() MENU.Push(MENU.OptionsScreen(mode)) end }
				end
			end
		end
		if #rows == 0 then rows[1] = { label = "No minigames installed", disabled = true } end
		return rows
	end
	return screen
end

function MENU.JoinScreen()
	local screen = { title = "Join a minigame" }
	screen.rows = function()
		local rows = {}
		for _, mode in ipairs(SortedModes(function() return true end)) do
			for _, info in ipairs(mode:Games()) do
				local hosted = "Hosted by " .. info.host
				if info.playing then
					rows[#rows + 1] = { label = mode.title, sub = hosted .. " - you're in (A: leave)", run = function() mode:Leave() MENU.Close() end }
				elseif info.joinable then
					rows[#rows + 1] = { label = mode.title, sub = hosted, run = function() mode:Join(info.session) MENU.Close() end }
				else
					rows[#rows + 1] = { label = mode.title, sub = hosted .. " - already playing", disabled = true }
				end
			end
		end
		if #rows == 0 then rows[1] = { label = "Nobody is hosting a minigame", sub = "LB + D-pad left to host one", disabled = true } end
		return rows
	end
	return screen
end

-- the game I'm in: hosting it, its host actions; playing, leave it
function MENU.PlayingScreen(mode, st)
	local host = st.host and st.host ~= 0 and Entity(st.host)
	local name = (host and IsValid(host) and host.Nick) and host:Nick() or "someone"
	return { title = mode.title, mode = mode, rows = function()
		local rows = { { label = "Leave the game", sub = "hosted by " .. name, run = function() mode:Leave() MENU.Close() end } }
		local invite = MENU.InviteRow(mode)
		if invite then rows[#rows + 1] = invite end
		return rows
	end }
end

function MENU.MyGameScreen()
	local mode, st = M.MyGame()
	if not mode then return nil end
	if mode:IsHost(st) then return MENU.ActionsScreen(mode) end
	return MENU.PlayingScreen(mode, st)
end

function MENU.MainScreen()
	return { title = "Minigames", rows = function()
		return {
			{ label = "Host", sub = "set up a minigame", run = function() MENU.Push(MENU.HostScreen()) end },
			{ label = "Join", sub = "join a minigame lobby", run = function() MENU.Push(MENU.JoinScreen()) end },
		}
	end }
end

function MENU.Skaters()
	local a = API()
	return a and a.Skaters and a.Skaters() or {}
end

-- the minigame ply is in (host or player), as Join lists it: mode, info
function M.GameOf(ply)
	if not IsValid(ply) then return nil end
	local idx = ply:EntIndex()
	local function member(st)
		if not st or not st.phase or st.phase == "idle" then return false end
		if st.host == idx then return true end
		for _, p in ipairs(st.players or {}) do if p.ent == idx then return true end end
		return false
	end
	for _, mode in pairs(M.modes) do
		if mode.seen then
			for key, entry in pairs(mode.seen) do
				if RealTime() - entry.at < 3 and member(entry.st) then
					local info = mode:InfoFor(entry.st)
					if info then info.session = key return mode, info end
				end
			end
		elseif member(mode.state) then
			local info = mode:Info()
			if info then return mode, info end
		end
	end
end

-- where to put my skater to be with ply: beside their skater (not inside
-- their collision box), else beside where they stand
function MENU.NextTo(ply)
	local a = API()
	local P = a and a.PoseOf and a.PoseOf(ply)
	local feet = P and P.HIPS and (P.TRUCK_FRONT and P.TRUCK_BACK and (P.TRUCK_FRONT + P.TRUCK_BACK) / 2 or P.HIPS - Vector(0, 0, 36)) or ply:GetPos()
	local yaw = P and P.TRUCK_FRONT and P.TRUCK_BACK and (P.TRUCK_FRONT - P.TRUCK_BACK):Angle().y or ply:EyeAngles().y
	local side = Angle(0, yaw + 90, 0):Forward()
	return feet + side * 64 + Vector(0, 0, 4), yaw
end

-- Players: everyone else. A watches them skate, X takes you to them, Y
-- joins the minigame they're in (when it's taking players)
function MENU.PlayersScreen()
	local screen = { title = "Players" }
	screen.rows = function()
		local rows = {}
		local skating = {}
		for _, ply in ipairs(MENU.Skaters()) do skating[ply] = true end
		local list = {}
		for _, ply in ipairs(player.GetAll()) do if ply ~= LocalPlayer() then list[#list + 1] = ply end end
		table.sort(list, function(x, y) return x:Nick():lower() < y:Nick():lower() end)
		local myMode = M.MyGame()
		for _, ply in ipairs(list) do
			local mode, info = M.GameOf(ply)
			local canJoin = mode ~= nil and info.joinable and not info.playing and myMode == nil
			local parts = { skating[ply] and "skating" or "on foot" }
			if mode then
				parts[#parts + 1] = "in " .. mode.title .. (info.playing and " with you" or info.joinable and " (open)" or " (playing)")
			end
			local row = { label = ply:Nick(), sub = table.concat(parts, ", "), ply = ply, actions = {} }
			local free = not M.Playing()
			row.aText = "Spectate"
			row.hints = {
				{ keys = { "X" }, text = free and "Teleport to them" or "Teleport (not during your game)", lit = free },
				{ keys = { "Y" }, text = mode and ("Join " .. mode.title) or "Join their minigame", lit = canJoin },
			}
			if skating[ply] then row.run = function() MENU.StartSpectating(ply) end end
			row.actions[B.X] = free and function()
				local a = API()
				local pos, yaw = MENU.NextTo(ply)
				if a and a.TeleportTo and a.TeleportTo(pos, yaw) then MENU.Close() end
			end or nil
			if canJoin then row.actions[B.Y] = function() mode:Join(info.session) MENU.Close() end end
			rows[#rows + 1] = row
		end
		if #rows == 0 then rows[1] = { label = "Nobody else is here", sub = "other players show up here", disabled = true } end
		return rows
	end
	return screen
end
MENU.SpectateScreen = MENU.PlayersScreen

function MENU.StartSpectating(ply)
	local a = API()
	MENU.spec = { target = ply }
	MENU.stack = {}
	if a and a.Freeze then a.Freeze(true, "menuspec") end
	if a and a.SetHidden then a.SetHidden("menuspec", true) end
	if a and a.SetView then a.SetView(function(_, _, fov) return MENU.SpectateView(fov) end, "menuspec") end
end

function MENU.StopSpectating()
	local a = API()
	MENU.spec = nil
	if a and a.Freeze then a.Freeze(false, "menuspec") end
	if a and a.SetHidden then a.SetHidden("menuspec", false) end
	M.GiveViewBack("menuspec")
end

function MENU.SwitchTarget(dir)
	local list = MENU.Skaters()
	if #list == 0 then return MENU.Close() end
	local idx = 0
	for i, p in ipairs(list) do if p == MENU.spec.target then idx = i end end
	idx = (idx - 1 + dir) % #list + 1
	MENU.spec = { target = list[idx] }
end

function MENU.SpectateView(fov)
	local spec = MENU.spec
	if not spec then return nil end
	local a = API()
	local P = a and IsValid(spec.target) and a.PoseOf and a.PoseOf(spec.target)
	if not (P and P.HIPS) then return nil end
	local target = P.HIPS + Vector(0, 0, 10)
	if spec.last then
		local moved = target - spec.last
		moved.z = 0
		if moved:LengthSqr() > 0.25 then spec.dir = LerpVector(0.08, spec.dir or moved:GetNormalized(), moved:GetNormalized()) end
	end
	spec.last = target
	local dir = spec.dir or Vector(1, 0, 0)
	local want = target - dir:GetNormalized() * 150 + Vector(0, 0, 60)
	spec.pos = spec.pos and LerpVector(0.12, spec.pos, want) or want
	return { origin = spec.pos, angles = (target - spec.pos):Angle(), fov = fov }
end

function MENU.Input(btn)
	if MENU.naming then return end
	if MENU.fc then return MENU.FreecamInput(btn) end
	if MENU.spec then
		if btn == B.B then MENU.Close()
		elseif btn == B.X and IsValid(MENU.spec.target) and not M.Playing() then
			local target = MENU.spec.target
			MENU.Close()
			local a = API()
			local pos, yaw = MENU.NextTo(target)
			if a and a.TeleportTo then a.TeleportTo(pos, yaw) end
		elseif btn == B.LEFT then MENU.SwitchTarget(-1)
		elseif btn == B.RIGHT then MENU.SwitchTarget(1) end
		return
	end
	if List.Input(MENU.stack, btn) == "empty" then MENU.Close() end
end

function MENU.PlacingOption(screen, option)
	local def = screen.mode and screen.mode.hostDef
	if option.key ~= "_start" or not def then return option end
	local sizes = {}
	for _, o in ipairs(def.options or {}) do
		if o.type == "region" then
			sizes[#sizes + 1] = { key = o.key, label = o.label, min = o.min, max = o.max, step = o.step, default = o.default, value = true,
				format = o.format or function(v) return (v * 2) .. " across" end }
		end
	end
	if #sizes == 0 then return option end
	local copy = {}
	for k, v in pairs(option) do copy[k] = v end
	copy.sizes = sizes
	return copy
end

function MENU.StartFreecam(screen, option)
	local a = API()
	local view = a and a.View and a.View()
	local origin = view and view.origin or (M.Here() + Vector(0, 0, 64))
	local ang = view and view.angles and Angle(view.angles.p, view.angles.y, 0) or Angle(20, LocalPlayer():EyeAngles().y, 0)
	local placed = screen.values[option.key]
	if placed then
		local look = option.type == "object" and (placed.yaw + 180) or placed.yaw
		origin = placed.pos + Vector(0, 0, 160) - Angle(30, look, 0):Forward() * 200
		ang = Angle(30, look, 0)
	end
	option = MENU.PlacingOption(screen, option)
	MENU.fc = { pos = origin, ang = ang, screen = screen, option = option }
	if option.type == "object" then
		MENU.fc.obj = MENU.NewObject(option, placed, (ang.y + 180) % 360)
		for _, p in ipairs(option.sizes or {}) do
			if p.value and screen.values[p.key] ~= nil then MENU.fc.obj[p.key] = screen.values[p.key] end
		end
	end
	if a and a.Freeze then a.Freeze(true, "menufc") end
	if a and a.SetView then
		a.SetView(function(_, _, fov) return MENU.fc and { origin = MENU.fc.pos, angles = MENU.fc.ang, fov = fov } or nil end, "menufc")
	end
end

function MENU.EndFreecam()
	MENU.fc = nil
	local a = API()
	M.GiveViewBack("menufc")
	if a and a.Freeze then a.Freeze(false, "menufc") end
end

function MENU.Think(pad, now, dt)
	local fc = MENU.fc
	if fc then
		UI.Fly(fc, pad, dt, FLY_SPEED, LOOK_SPEED)
		local tr = util.TraceLine({ start = fc.pos, endpos = fc.pos + fc.ang:Forward() * 8000, mask = MASK_SOLID_BRUSHONLY })
		fc.target = tr.Hit and tr.HitPos or nil
		if fc.obj then MENU.HoldTurn(fc, pad, now, dt) end
	end
	if MENU.spec and not IsValid(MENU.spec.target) then MENU.SwitchTarget(1) end
end

function MENU.FreecamInput(btn)
	local fc = MENU.fc
	if fc.obj then return MENU.ObjectInput(fc, btn) end
	if btn == B.A and fc.target then
		fc.screen.values[fc.option.key] = { pos = fc.target, yaw = fc.ang.y }
		MENU.EndFreecam()
	elseif btn == B.B then
		MENU.EndFreecam()
	end
end

---------------------------------------------------------------------------
-- placing an object (option type "object"): the mode's own drawing of it
-- follows where you look; the D-pad turns and sizes it, X / Y lower and
-- raise it, A puts it down. Option fields: draw(obj, alpha) with obj =
-- { pos, yaw, scale, lift, <each size's key> }; scale / lift = { min, max,
-- step, default, label, format } (either can be left out); sizes = a list
-- of more parts to size, each { key, label, min, max, step, default,
-- format } (with scale, RB picks which one the D-pad sizes); rotate (false:
-- no turning); turnStep (degrees, 15); summary(obj) for the menu row.
---------------------------------------------------------------------------
-- the parts the D-pad sizes: scale (key "scale") first, then sizes
function MENU.SizeParts(o)
	local parts = {}
	if o.scale then
		local s = {}
		for k, v in pairs(o.scale) do s[k] = v end
		s.key = "scale"
		parts[1] = s
	end
	for _, p in ipairs(o.sizes or {}) do parts[#parts + 1] = p end
	return parts
end

function MENU.NewObject(o, placed, yaw)
	local obj = { yaw = placed and placed.yaw or yaw, lift = placed and placed.lift or (o.lift and o.lift.default), part = 1 }
	for _, p in ipairs(MENU.SizeParts(o)) do obj[p.key] = placed and placed[p.key] or p.default end
	return obj
end

function MENU.ObjectNow(fc)
	if not fc.target then return nil end
	local out = { pos = fc.target, yaw = fc.obj.yaw, lift = fc.obj.lift }
	for _, p in ipairs(MENU.SizeParts(fc.option)) do out[p.key] = fc.obj[p.key] end
	return out
end

local function Step(spec, v, dir)
	if not spec then return v end
	local step = spec.step or 1
	return math.Clamp((v or spec.default or spec.min) + dir * step, spec.min, spec.max)
end

MENU.TURN_HOLD, MENU.TURN_RATE = 0.3, 90
function MENU.HoldTurn(fc, pad, now, dt)
	if fc.option.rotate == false then return end
	local dir = (PAD.Held(pad, B.LEFT) and 1 or 0) - (PAD.Held(pad, B.RIGHT) and 1 or 0)
	if dir == 0 then fc.turnSince = nil return end
	fc.turnSince = fc.turnSince or now
	if now - fc.turnSince >= MENU.TURN_HOLD then fc.obj.yaw = (fc.obj.yaw + dir * MENU.TURN_RATE * (dt or 0)) % 360 end
end

function MENU.ObjectInput(fc, btn)
	local o, obj = fc.option, fc.obj
	local turn = o.turnStep or 15
	if o.rotate ~= false and btn == B.LEFT then obj.yaw = (obj.yaw + turn) % 360
	elseif o.rotate ~= false and btn == B.RIGHT then obj.yaw = (obj.yaw - turn) % 360
	elseif btn == B.UP or btn == B.DOWN then
		local part = MENU.SizeParts(o)[obj.part or 1]
		if part then obj[part.key] = Step(part, obj[part.key], btn == B.UP and 1 or -1) end
	elseif btn == B.RB then
		local n = #MENU.SizeParts(o)
		if n > 1 then obj.part = (obj.part or 1) % n + 1 end
	elseif btn == B.Y then obj.lift = Step(o.lift, obj.lift, 1)
	elseif btn == B.X then obj.lift = Step(o.lift, obj.lift, -1)
	elseif btn == B.A and fc.target then
		local placed = MENU.ObjectNow(fc)
		for _, p in ipairs(o.sizes or {}) do
			if p.value then
				fc.screen.values[p.key] = placed[p.key]
				placed[p.key] = nil
			end
		end
		fc.screen.values[o.key] = placed
		MENU.EndFreecam()
	elseif btn == B.B then
		MENU.EndFreecam()
	end
end

local function Shown(spec, v)
	if not spec or v == nil then return nil end
	return spec.format and spec.format(v) or tostring(v)
end

function MENU.ObjectSummary(o, v)
	if o.summary then return o.summary(v) end
	local parts = { "placed" }
	for _, p in ipairs(MENU.SizeParts(o)) do parts[#parts + 1] = string.lower(p.label or "size") .. " " .. Shown(p, v[p.key]) end
	if o.lift then parts[#parts + 1] = string.lower(o.lift.label or "height") .. " " .. Shown(o.lift, v.lift) end
	return table.concat(parts, ", ")
end

function MENU.ObjectLegend(fc)
	local o, obj = fc.option, fc.obj
	local rows = {
		{ keys = { "LS" }, text = "Fly" },
		{ keys = { "RS" }, text = "Look" },
		{ keys = { "LT", "RT" }, text = "Down / up" },
	}
	if o.rotate ~= false then rows[#rows + 1] = { keys = { "LEFT", "RIGHT" }, text = "Turn" } end
	local sizes = MENU.SizeParts(o)
	local part = sizes[obj.part or 1]
	if part then rows[#rows + 1] = { keys = { "UP", "DOWN" }, text = (part.label or "Size") .. ": " .. Shown(part, obj[part.key]) } end
	if #sizes > 1 then
		rows[#rows + 1] = { keys = { "RB" }, text = "Next piece" }
	end
	if o.lift then rows[#rows + 1] = { keys = { "X", "Y" }, text = (o.lift.label or "Height") .. ": " .. Shown(o.lift, obj.lift) } end
	rows[#rows + 1] = { keys = { "A" }, text = "Put it here", lit = fc.target ~= nil }
	rows[#rows + 1] = { keys = { "B" }, text = "Cancel" }
	return rows
end

-- LB + D-pad left / right open the menu, LB + X respawns, LB + RB replays
UI.Combo(B.LEFT, { open = function() MENU.Open("main") end, whileWatching = true })
UI.Combo(B.RT, { open = function() M.AcceptInvite() end, allowed = function() return M.InviteActive() end, label = "join invite" })
UI.Combo(B.RIGHT, { open = function() MENU.Open("players") end })
UI.Combo(B.X, { open = function() local a = API() if a and a.Respawn then a.Respawn() end end, label = "respawn" })
UI.Combo(B.RB, { open = function() MENU.Open("replays") end, allowed = function() return MENU.SCREENS ~= nil and MENU.SCREENS.replays ~= nil end, label = "replay" })

local beamMat
function M.Beacon(pos, col, height, width)
	beamMat = beamMat or Material("trails/laser")
	render.SetMaterial(beamMat)
	render.DrawBeam(pos, pos + Vector(0, 0, height or 6000), width or 40, 0, 1, col)
	render.SetColorMaterial()
	render.DrawBox(pos, angle_zero, Vector(-3, -3, 0), Vector(3, 3, height or 6000), Color(col.r, col.g, col.b, 60))
end

local WHITE, BLUE = PAD.WHITE, PAD.BLUE
function MENU.DrawWorld()
	if not MENU.IsOpen() then return end
	local screen = (MENU.fc and MENU.fc.screen) or MENU.Top()
	if screen and screen.values and screen.mode and screen.mode.hostDef then
		for _, o in ipairs(screen.mode.hostDef.options or {}) do
			local v = screen.values[o.key]
			if o.type == "region" and v then
				local fc = MENU.fc
				local live = fc and fc.obj and fc.option and fc.option.key == "_start" and MENU.ObjectNow(fc)
				local centre = (live and live.pos) or (screen.values._start and screen.values._start.pos) or M.Here()
				local radius = (fc and fc.obj and fc.option and fc.option.key == "_start" and fc.obj[o.key]) or v
				M.Ring(centre + Vector(0, 0, 4), radius, BLUE, 64)
				M.AreaWall(centre, radius, BLUE)
			end
			if o.type == "point" and v then M.Beacon(v.pos, o.color or BLUE, 3000) end
			if o.type == "object" and v and o.draw and not (MENU.fc and MENU.fc.option and MENU.fc.option.key == o.key) then pcall(o.draw, v, 0.6) end
		end
	end
	local fc = MENU.fc
	if fc and fc.obj then
		local obj = MENU.ObjectNow(fc)
		if obj and fc.option.draw then pcall(fc.option.draw, obj, 1) end
	elseif fc and fc.target then
		M.Beacon(fc.target, WHITE, 3000)
	end
end

function MENU.Paint(w, h)
	if not MENU.IsOpen() then return end
	PAD.Fonts()
	if MENU.spec then
		local t = MENU.spec.target
		PAD.Text("Spectating " .. (IsValid(t) and t:Nick() or "?"), "skategm_ui_title", w / 2, h * 0.06, WHITE, TEXT_ALIGN_CENTER)
		PAD.Legend({
			{ keys = { "LEFT", "RIGHT" }, text = "Someone else" },
			{ keys = { "X" }, text = "Teleport to them", lit = not M.Playing() },
			{ keys = { "B" }, text = "Stop" },
		}, w, h, "bottom")
		return
	end
	if MENU.fc and MENU.fc.obj then
		PAD.Text("Place the " .. MENU.fc.option.label:lower(), "skategm_ui_title", w / 2, h * 0.06, WHITE, TEXT_ALIGN_CENTER)
		if not MENU.fc.target then PAD.Text("look at the ground to put it there", "skategm_ui_row", w / 2, h * 0.11, WHITE, TEXT_ALIGN_CENTER) end
		PAD.Legend(MENU.ObjectLegend(MENU.fc), w, h, "bottom")
		return
	end
	if MENU.fc then
		PAD.Text("Place the " .. MENU.fc.option.label:lower(), "skategm_ui_title", w / 2, h * 0.06, WHITE, TEXT_ALIGN_CENTER)
		surface.SetDrawColor(255, 255, 255, 200)
		surface.DrawRect(w / 2 - 1, h / 2 - 10, 2, 20)
		surface.DrawRect(w / 2 - 10, h / 2 - 1, 20, 2)
		PAD.Legend({
			{ keys = { "LS" }, text = "Fly" },
			{ keys = { "RS" }, text = "Look" },
			{ keys = { "LT", "RT" }, text = "Down / up" },
			{ keys = { "A" }, text = "Place it where you're looking", lit = MENU.fc.target ~= nil },
			{ keys = { "B" }, text = "Cancel" },
		}, w, h, "bottom")
		return
	end
	local top = MENU.Top()
	List.Paint(MENU.stack, w, h, { width = 0.34, note = top and top.note })
end

hook.Add("HUDPaint", "skategm_modes_menu", function() MENU.Paint(ScrW(), ScrH()) end)
hook.Add("PostDrawTranslucentRenderables", "skategm_modes_menu", function(depth, sky) if not (depth or sky) then MENU.DrawWorld() end end)
