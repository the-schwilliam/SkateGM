---------------------------------------------------------------------------
-- A replay left looping: from the editor's Start menu you get
-- off the board and walk about while the clip (its trimmed part, at its
-- speed) goes round and round as a ghost of you, seen only by you; getting
-- back on removes it.
-- H hides the HUD while a replay is open or looping (for clean shots).
--   skategm_replay_walk        leave the open replay looping and walk about
--   skategm_replay_stop_loop   stop the looping one
--   skategm_replay_hud         hide / show the HUD
---------------------------------------------------------------------------
local S = SkateGM
local R = S.replay
local UI = SKATEGM_UI
local function API() return S.API end

local close = R.Close
function R.Close()
	if R.on and not R.leavingToLoop then
		R.SetHUDHidden(false)
	end
	close()
end

---------------------------------------------------------------------------
-- the HUD hidden (H): the game's HUD and menus, and the editor's own
---------------------------------------------------------------------------
function R.SetHUDHidden(hidden)
	if hidden and not R.hudBackup then
		R.hudBackup = {}
		for _, name in ipairs({ "cl_drawhud", "r_drawvgui" }) do
			local cv = GetConVar(name)
			if cv then R.hudBackup[name] = cv:GetString() RunConsoleCommand(name, "0") end
		end
	elseif not hidden and R.hudBackup then
		for name, value in pairs(R.hudBackup) do RunConsoleCommand(name, value) end
		R.hudBackup = nil
	end
	R.hudHidden = hidden or nil
end

function R.ToggleHUD()
	if R.on or R.loop then R.SetHUDHidden(not R.hudHidden) end
end

local paint = R.Paint
function R.Paint(w, h)
	if R.hudHidden then return end
	paint(w, h)
end

hook.Add("ShutDown", "skategm_replay_restore_hud", function() R.SetHUDHidden(false) end)

---------------------------------------------------------------------------
-- looping
---------------------------------------------------------------------------
-- leaves the open replay looping: you get off the board (Skater mode off)
-- and walk about; getting back on (skategm_toggle) removes the ghost. (Not
-- in the SkateGM gamemode, which keeps Skater mode on.)
function R.Detach()
	local v = R.on
	if not v then return end
	if S.locked then return R.Note("not available in this gamemode") end
	local a, b = R.Trim()
	if b - a < 0.2 then return R.Note("the trimmed part is too short to loop") end
	R.leavingToLoop = true
	R.Close()
	R.leavingToLoop = nil
	API().StopSkating()
	if S.phase ~= "off" then R.SetHUDHidden(false) return end
	R.loop = { clip = v.clip, a = a, b = b, t = math.Clamp(v.t, a, b), speed = R.speeds[v.speed] or 1, key = S.ClipProxy(LocalPlayer()), last = RealTime() }
	API().Say("your replay is looping: getting back on the board removes it")
end

function R.StopLoop()
	local l = R.loop
	if not l then return end
	R.loop = nil
	S.ForgetSkater(l.key)
	R.SetHUDHidden(false)
end

function R.LoopThink(now)
	local l = R.loop
	if not l then return end
	-- (back on the board, or a replay opened: the ghost goes)
	if S.phase == "on" or R.on then return R.StopLoop() end
	local dt = math.max(0, now - (l.last or now))
	l.last = now
	l.t = l.t + dt * l.speed
	if l.t > l.b then l.t = l.a + (l.t - l.b) % (l.b - l.a) end
	local P, frame = R.PoseAt(l.clip, l.t)
	if not P then return end
	S.remote[l.key] = { snaps = { { t = now - 1, P = P }, { t = now + 1, P = P } }, last = now, state = frame and frame.state }
	if frame and frame.rocket and S.RocketFlames then pcall(S.RocketFlames, P, now, l.key, true) end
end

hook.Add("Think", "skategm_replay_loop", function() R.LoopThink(RealTime()) end)

-- H hides / shows the HUD (the controller's buttons are all taken in the editor)
local keyWas = {}
hook.Add("Think", "skategm_replay_loop_key", function()
	local free = not gui.IsGameUIVisible() and not vgui.CursorVisible() and (not system.HasFocus or system.HasFocus())
	for _, key in ipairs({ KEY_H }) do
		local down = input.IsKeyDown(key)
		if down and not keyWas[key] and free and not R.exporting then R.ToggleHUD() end
		keyWas[key] = down
	end
end)

concommand.Add("skategm_replay_walk", function() R.Detach() end, nil, "Leave the open replay looping as a ghost and walk about (back on the board removes it)")
concommand.Add("skategm_replay_stop_loop", function() R.StopLoop() end, nil, "Stop the looping replay")
concommand.Add("skategm_replay_hud", function() R.ToggleHUD() end, nil, "Hide / show the HUD while a replay is open or looping")

---------------------------------------------------------------------------
-- in the menus: the editor's Start menu, and the replay list
---------------------------------------------------------------------------
local menuPage = R.MenuPage
function R.MenuPage()
	local page = menuPage()
	local rows = page.rows
	page.rows = function()
		local list = type(rows) == "function" and rows() or rows
		list[#list + 1] = { label = "Loop it in the world", sub = S.locked and "not available in this gamemode" or nil,
			disabled = S.locked == true, run = function() R.Detach() end }
		return list
	end
	return page
end

local screen = R.Screen
function R.Screen()
	local page = screen()
	local rows = page.rows
	page.rows = function()
		local list = type(rows) == "function" and rows() or rows
		if R.loop then table.insert(list, 1, { label = "Stop the looping replay", sub = "your ghost stops skating", run = function() R.StopLoop() end }) end
		return list
	end
	return page
end
local menu = SKATEGM_MODES and SKATEGM_MODES.menu
if menu and menu.SCREENS then menu.SCREENS.replays = R.Screen end
