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

-- (the menu leaves the skater riding, only taking the controller; spectating
-- and placing a point freeze it themselves)
function MENU.Open(kind)
	if UI.Busy() then return end
	MENU.stack = {}
	local extra = MENU.SCREENS and MENU.SCREENS[kind]
	local mine = kind == "main" and MENU.MyGameScreen()
	MENU.Push(mine or extra and extra() or kind == "join" and MENU.JoinScreen() or kind == "host" and MENU.HostScreen() or (kind == "players" or kind == "spectate") and MENU.PlayersScreen() or MENU.MainScreen())
	UI.Take("minigames", { press = MENU.Input, think = MENU.Think, close = MENU.Cleanup }, nil, true)
end

local function DefaultValues(def)
	local v = {}
	for _, o in ipairs(def.options or {}) do
		if o.type ~= "point" then v[o.key] = o.default end
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
		if o.type == "point" and o.required ~= false and not values[o.key] then return o end
	end
end

function MENU.Resolve(def, values)
	local out = {}
	for k, v in pairs(values) do out[k] = v end
	for _, o in ipairs(def.options or {}) do
		if o.type == "region" then out[o.key] = { centre = M.Here(), radius = values[o.key] } end
	end
	return out
end

function MENU.OptionsScreen(mode)
	local def = mode.hostDef
	local screen = { title = "Host " .. mode.title, mode = mode, values = DefaultValues(def) }
	screen.rows = function()
		local rows = {}
		for _, o in ipairs(def.options or {}) do
			local sub = o.help
			if o.type == "point" then sub = screen.values[o.key] and "A: fly there again to move it" or "A: fly there and place it" end
			if o.type == "region" then sub = "around where you're standing (the ring)" end
			local row = { label = o.label, sub = sub, option = o, value = function()
				local text = MENU.OptionText(o, screen.values[o.key])
				return text:sub(#o.label + 3)
			end }
			if o.type == "point" then
				row.press, row.aText = function() MENU.StartFreecam(screen, o) end, "Fly there"
			else
				row.change = function(dir) MENU.Adjust(o, screen.values, dir) end
			end
			rows[#rows + 1] = row
		end
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

function MENU.ActionsScreen(mode)
	local screen = { title = mode.title .. " (you're hosting)", mode = mode }
	screen.rows = function()
		local rows = {}
		for _, act in ipairs(mode:Actions()) do
			rows[#rows + 1] = { label = act.label, sub = act.sub, run = function() act.run() MENU.Close() end }
		end
		return rows
	end
	return screen
end

function MENU.HostScreen()
	local screen = { title = "Host a minigame" }
	screen.rows = function()
		local rows = {}
		for _, mode in ipairs(SortedModes(function(m) return m.hostDef ~= nil end)) do
			local others = #mode:Games()
			if not mode:Allowed() then
				rows[#rows + 1] = { label = mode.title, sub = "turned off on this server", disabled = true }
			else
				local sub = mode.hostDef.description .. (others > 0 and string.format(" (%d going already)", others) or "")
				rows[#rows + 1] = { label = mode.title, sub = sub, run = function() MENU.Push(MENU.OptionsScreen(mode)) end }
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
		return {
			{ label = "Leave the game", sub = "hosted by " .. name, run = function() mode:Leave() MENU.Close() end },
		}
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
			{ label = "Host", sub = "set up a minigame for everyone", run = function() MENU.Push(MENU.HostScreen()) end },
			{ label = "Join", sub = "join a minigame someone is hosting", run = function() MENU.Push(MENU.JoinScreen()) end },
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
	if a and a.Freeze then a.Freeze(true) end
	if a and a.SetHidden then a.SetHidden("spectate", true) end
	if a and a.SetView then a.SetView(function(_, _, fov) return MENU.SpectateView(fov) end) end
end

function MENU.StopSpectating()
	local a = API()
	MENU.spec = nil
	if a and a.Freeze then a.Freeze(false) end
	if a and a.SetHidden then a.SetHidden("spectate", false) end
	if a and a.SetView then a.SetView(nil) end
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

function MENU.StartFreecam(screen, option)
	local a = API()
	local view = a and a.View and a.View()
	local origin = view and view.origin or (M.Here() + Vector(0, 0, 64))
	local ang = view and view.angles and Angle(view.angles.p, view.angles.y, 0) or Angle(20, LocalPlayer():EyeAngles().y, 0)
	local placed = screen.values[option.key]
	if placed then
		origin = placed.pos + Vector(0, 0, 160) - Angle(30, placed.yaw, 0):Forward() * 200
		ang = Angle(30, placed.yaw, 0)
	end
	MENU.fc = { pos = origin, ang = ang, screen = screen, option = option }
	if a and a.Freeze then a.Freeze(true) end
	if a and a.SetView then
		a.SetView(function(_, _, fov) return MENU.fc and { origin = MENU.fc.pos, angles = MENU.fc.ang, fov = fov } or nil end)
	end
end

function MENU.EndFreecam()
	MENU.fc = nil
	local a = API()
	if a and a.SetView then a.SetView(nil) end
	if a and a.Freeze then a.Freeze(false) end
end

function MENU.Think(pad, now, dt)
	local fc = MENU.fc
	if fc then
		UI.Fly(fc, pad, dt, FLY_SPEED, LOOK_SPEED)
		local tr = util.TraceLine({ start = fc.pos, endpos = fc.pos + fc.ang:Forward() * 8000, mask = MASK_SOLID_BRUSHONLY })
		fc.target = tr.Hit and tr.HitPos or nil
	end
	if MENU.spec and not IsValid(MENU.spec.target) then MENU.SwitchTarget(1) end
end

function MENU.FreecamInput(btn)
	local fc = MENU.fc
	if btn == B.A and fc.target then
		fc.screen.values[fc.option.key] = { pos = fc.target, yaw = fc.ang.y }
		MENU.EndFreecam()
	elseif btn == B.B then
		MENU.EndFreecam()
	end
end

-- LB + D-pad left / right open the menu, LB + X respawns, LB + RB replays
UI.Combo(B.LEFT, { open = function() MENU.Open("main") end })
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
	local screen = MENU.Top()
	if screen and screen.values and screen.mode and screen.mode.hostDef then
		for _, o in ipairs(screen.mode.hostDef.options or {}) do
			local v = screen.values[o.key]
			if o.type == "region" and v then
				M.Ring(M.Here() + Vector(0, 0, 4), v, BLUE, 64)
				M.AreaWall(M.Here(), v, BLUE)
			end
			if o.type == "point" and v then M.Beacon(v.pos, o.color or BLUE, 3000) end
		end
	end
	if MENU.fc and MENU.fc.target then M.Beacon(MENU.fc.target, WHITE, 3000) end
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
	List.Paint(MENU.stack, w, h, { width = 0.34 })
end

hook.Add("HUDPaint", "skategm_modes_menu", function() MENU.Paint(ScrW(), ScrH()) end)
hook.Add("PostDrawTranslucentRenderables", "skategm_modes_menu", function(depth, sky) if not (depth or sky) then MENU.DrawWorld() end end)
