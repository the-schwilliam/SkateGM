local keyboard=include("skategm/cl_keyboard.lua")
local presentation=include("skategm/cl_presentation.lua")
local renderBuffer=presentation.New()
-- SkateGM (client). The real skate simulation (gm_skategm module)
-- skates the current map's collision; your player model is posed from the
-- simulated skater and the board from its truck and wheel bones.
--
-- Console:
--   skategm_toggle            Skater mode on / off   (bind a key: bind j skategm_toggle)
--   skategm_world_scale 0.75  make ramps smaller to the engine (1 = true size)
--   skategm_show_collision 1  wireframe of what the skater collides with
--   skategm_smooth 0/1/2      smoothing of bumpy displacement terrain (default 1)
--   skategm_hud 0/1           the score display
--   skategm_why               aim at something: is it solid to the skater, and if not, why
--   skategm_trace [seconds]   record a run (speed, height, state, surface) and summarise it
--   skategm_boost [m/s]       a push forward (bind it: bind b skategm_boost); skategm_boost_amount sets the default
-- Session marker (as in the original game): LB + D-pad down sets, LB + hold D-pad up
-- returns. Keyboard: R sets, hold F returns.
--   skategm_tiny_props_solid 0/1  tiny clutter (cans, rubble) solid to the skater (default 0)
--   skategm_data <path>       folder with your converted game data
--   skategm_report            print engine, map and performance numbers
--   skategm_bones 1           also draw the raw Skate bones (debug)

local cvData  = CreateClientConVar("skategm_data", "C:/skategm/assets", true, false, "Folder with your converted game data")
-- the installer writes where it put the converted data; it's used unless the
-- player has chosen a folder of their own. Worked out when the data is
-- needed, not by setting the convar at start: that was a console command run
-- a frame later, and config.txt could put the default back first (on a
-- server, the engine then looked in C:/skategm/assets and failed)
local DATA_DEFAULT = "C:/skategm/assets"
local function InstalledDataPath()
	local written = file and file.Read and file.Read("skategm/datapath.txt", "DATA")
	written = written and written:gsub("^%s+", ""):gsub("%s+$", "")
	if written and written ~= "" then return written end
	return nil
end
local function DataPath()
	local chosen = string.gsub(cvData:GetString() or "", "\\", "/")
	if chosen == "" or chosen == DATA_DEFAULT then
		local installed = InstalledDataPath()
		if installed then return (string.gsub(installed, "\\", "/")) end
	end
	return chosen ~= "" and chosen or DATA_DEFAULT
end
do
	local written = InstalledDataPath()
	if written and cvData:GetString() == DATA_DEFAULT and RunConsoleCommand then
		RunConsoleCommand("skategm_data", written)
	end
end
local cvBones = CreateClientConVar("skategm_bones", "0", false, false, "Draw the raw Skate bones", 0, 1)
local cvCollide = CreateClientConVar("skategm_player_collision", "1", true, false, "Other players are solid to your skater", 0, 1)
local cvScale = CreateClientConVar("skategm_world_scale", "1", true, false,
	"How big the map is to the engine: 1 = true size, 0.75 = ramps a quarter smaller (your skater still looks normal)", 0.5, 1.5)
local cvSmooth = CreateClientConVar("skategm_smooth", "1", true, false,
	"Smooth bumpy displacement ground/ramps for the engine: 0 = as built, 1 = light, 2 = strong", 0, 2)
local cvTinySolid = CreateClientConVar("skategm_tiny_props_solid", "0", true, false,
	"Tiny props (bottles, cans, rubble: at most 24 units across and 12 tall) are solid to the skater", 0, 1)
local cvCreases = CreateClientConVar("skategm_smooth_creases", "1", true, false,
	"Curves in creases (where ramps meet the ground, faceted quarter pipes and bowls)", 0, 1)
local cvSteps = CreateClientConVar("skategm_smooth_steps", "8", true, false,
	"Ramp over ledges up to this height, in units (0 = off, 2 = tiny lips only, 8 = curbs too)", 0, 12)
-- settings saved by older versions: the old presets' ledge heights move to the
-- new ones once (a value you chose yourself is left alone)
local cvSettingsVersion = CreateClientConVar("skategm_settings_version", "1", true, false, "(internal) settings format", 1, 99)
if cvSettingsVersion:GetFloat() < 2 then
	local old = cvSteps:GetFloat()
	if math.abs(old - 2) < 0.01 then RunConsoleCommand("skategm_smooth_steps", "8")
	elseif math.abs(old - 6) < 0.01 then RunConsoleCommand("skategm_smooth_steps", "12") end
	RunConsoleCommand("skategm_settings_version", "2")
end
-- Collision style: classic (the default: small curves, as before 5.19) or
-- experimental (5.20's bigger curves, crossing creases, rounded terrain creases
-- and tiny-step ramps) - to compare in the game, where it counts.
local cvStyle = CreateClientConVar("skategm_collision_style", "0", true, false,
	"0 = classic collision (default), 1 = experimental (5.20's bigger curves and extra smoothing)", 0, 1)
-- A top speed (m/s, 0 = none): the engine keeps speeding up down a long drop,
-- past what any collision handles smoothly.
local cvSpeedLimit = CreateClientConVar("skategm_speed_limit", "0", true, false,
	"Top speed in m/s (0 = no limit). For maps with huge drops: at 70 m/s every transition is violent.", 0, 200)
-- Y (get off the board) in the air: allowed (0, the default). Its in-air
-- version once hit a missing engine path; if it does, the engine recovers and
-- says which state it was in - set this to 1 to keep Y from it in the air.
local cvBlockAirY = CreateClientConVar("skategm_block_air_dismount", "0", true, false,
	"1 = Y (get off) does nothing while airborne (if the in-air dismount keeps failing)", 0, 1)
if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback("skategm_block_air_dismount", function() if skategm and skategm.SetAirDismountBlock then skategm.SetAirDismountBlock(cvBlockAirY:GetBool() and 1 or 0) end end, "skategm_airy")
end
local cvCamShake = CreateClientConVar("skategm_camera_shake", "0", true, false,
	"1 = the skater camera shakes at speed and on landings", 0, 1)
-- the camera nearer or further (a multiple of Skate's own distance from the
-- skater) and its field of view (0 = Skate's own)
local cvCamDist = CreateClientConVar("skategm_camera_distance", "1", true, false, "How far the camera sits from the skater (1 = Skate's own)", 0.5, 2)
local cvCamFov = CreateClientConVar("skategm_camera_fov", "0", true, false, "Camera field of view in degrees (0 = Skate's own)", 0, 120)
local function ApplyCameraShake() if skategm and skategm.SetCameraShake then skategm.SetCameraShake(cvCamShake:GetBool() and 1 or 0) end end
if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback("skategm_camera_shake", ApplyCameraShake, "skategm_shake")
end
local TUNING = {
	[0] = { SK8_CURVE_CAP = "16", SK8_TAPER = "linear", SK8_OFF = "crossings,bigterrain,shortsteps" },
	[1] = { SK8_CURVE_CAP = false, SK8_TAPER = false, SK8_OFF = false },
}
local function ApplyTuning()
	if not (skategm and skategm.SetTuning) then return end
	for name, value in pairs(TUNING[cvStyle:GetInt()] or TUNING[0]) do
		if name == "SK8_OFF" and SkateGM and SkateGM.extraOff and SkateGM.extraOff ~= "" then
			value = (value and value ~= "") and (value .. "," .. SkateGM.extraOff) or SkateGM.extraOff
		end
		skategm.SetTuning(name, value or nil)
	end
	if skategm.SetSpeedLimit then skategm.SetSpeedLimit(cvSpeedLimit:GetFloat()) end
	if skategm.SetAirDismountBlock then skategm.SetAirDismountBlock(cvBlockAirY:GetBool() and 1 or 0) end
	ApplyCameraShake()
end
if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback("skategm_speed_limit", function() if skategm and skategm.SetSpeedLimit then skategm.SetSpeedLimit(cvSpeedLimit:GetFloat()) end end, "skategm_speed")
end
local cvNoPhys = CreateClientConVar("skategm_solid_no_physics", "0", true, false,
	"Props with no physics model are solid to the skater (as their visible shape). Source doesn't make them solid for players, so this is off.", 0, 1)
local cvShowCol = CreateClientConVar("skategm_show_collision", "0", false, false,
	"Draw the collision around your skater: 1 = by slope, 2 = by what it's made of", 0, 2)

local S = {
	phase = "off",   -- off | loading | on
	map = nil,       -- map the engine was loaded for
	pose = nil,      -- newest Poll() result
	P = nil,         -- skate bone positions as Vectors, by name
	idx = nil,       -- skate bone name -> index
	nextSync = 0,
	remote = {},     -- other skaters: player -> { snaps = {...}, last = time }
}
SkateGM = S
S.L = {}
S.passSeen, S.passNext = {}, 0
S.ApplyTuning = ApplyTuning

local sent, lastSig = {}, nil -- model shapes already sent; last entity signature
local SOURCE_NAMES = { [0] = "map brush", [1] = "displacement", [2] = "static prop", [3] = "prop / entity", [4] = "other player", [5] = "ledge ramp (added)", [6] = "curve (added)" }
local SOURCE_COLOURS = { [0] = Color(120, 200, 255), [1] = Color(90, 255, 120), [2] = Color(255, 170, 60), [3] = Color(255, 90, 255), [4] = Color(255, 70, 70), [5] = Color(255, 255, 255), [6] = Color(255, 240, 150) }
local models = {}             -- player -> posed ClientsideModel
local PlayerBlocks            -- defined in the multiplayer section
local WATER = { state = "dry", t = 0, fade = 0 } -- falling in water (see the water section)

local function Say(msg, bad)
	MsgC(bad and Color(255, 90, 80) or Color(120, 200, 255), "[SkateGM] ", msg, "\n")
	if bad then chat.AddText(Color(255, 90, 80), "[SkateGM] ", msg) end
end

-- Where Lua's positions are relative to (S.frameOffset, set by a map module:
-- the original InfMap shows the client positions relative to the player's own
-- chunk, which moves; the engine needs one fixed frame). Everything crossing
-- into or out of the module is shifted by it; the network carries absolute
-- positions. No offset (every other map): nothing changes.
function S.Offset()
	local o = S.frameOffset and S.frameOffset()
	if o and (o.x ~= 0 or o.y ~= 0 or o.z ~= 0) then return o end
	return nil
end
function S.ToAbs(v)
	local o = S.Offset()
	if not (o and v) then return v end
	return v + o
end
function S.FromAbs(v)
	local o = S.Offset()
	if not (o and v) then return v end
	return v - o
end

local function Shift3(t, o, sign)
	if type(t) == "table" and t[3] then t[1], t[2], t[3] = t[1] + sign * o.x, t[2] + sign * o.y, t[3] + sign * o.z end
end

function S.WrapModule()
	if not skategm or rawget(skategm, "__frame") then return end
	local raw = skategm
	local W = setmetatable({ __frame = true, raw = raw }, { __index = raw })
	local function shiftList(list)
		local o = S.Offset()
		if not o then return list end
		local out = {}
		for i, e in ipairs(list) do
			out[i] = { e[1], e[2] + o.x, e[3] + o.y, e[4] + o.z, e[5], e[6], e[7] }
		end
		return out
	end
	W.Load = function(path, x, y, z, ...)
		local o = S.Offset()
		if o then x, y, z = x + o.x, y + o.y, z + o.z end
		return raw.Load(path, x, y, z, ...)
	end
	W.Activate = function(x, y, z, ...)
		local o = S.Offset()
		if o then x, y, z = x + o.x, y + o.y, z + o.z end
		return raw.Activate(x, y, z, ...)
	end
	W.CollisionHas = function(x, y, z, ...)
		local o = S.Offset()
		if o then x, y, z = x + o.x, y + o.y, z + o.z end
		return raw.CollisionHas(x, y, z, ...)
	end
	W.CollisionNear = function(x, y, z, ...)
		local o = S.Offset()
		if not o then return raw.CollisionNear(x, y, z, ...) end
		local t, tags = raw.CollisionNear(x + o.x, y + o.y, z + o.z, ...)
		if type(t) == "table" then
			for i = 1, #t - 2, 3 do t[i], t[i + 1], t[i + 2] = t[i] - o.x, t[i + 1] - o.y, t[i + 2] - o.z end
		end
		return t, tags
	end
	W.SetEntities = function(list) return raw.SetEntities(shiftList(list)) end
	if raw.SetMovers then W.SetMovers = function(list) return raw.SetMovers(shiftList(list)) end end
	W.Poll = function(...)
		local p = raw.Poll(...)
		keyboard.Decorate(S,p)
		local o = S.Offset()
		if o and type(p) == "table" then
			Shift3(p.pos, o, -1)
			if p.bones then for _, b in pairs(p.bones) do Shift3(b, o, -1) end end
			if p.cam then Shift3(p.cam.pos, o, -1) end
			if p.marker then Shift3(p.marker.pos, o, -1) end
		end
		return p
	end
	skategm = W
end

local function Native(retry)
	if skategm then S.WrapModule() return true end
	if S.nativeFailed and not retry then return false end
	local ok, err = pcall(require, "skategm")
	if not ok or not skategm then
		S.nativeFailed = true
		S.lastError = "the SkateGM module (gmcl_skategm_win64.dll) isn't installed or couldn't load: put it in garrysmod/lua/bin and use the x86-64 branch of Garry's Mod"
		Say("could not load the native module: " .. tostring(err), true)
		Say("Put gmcl_skategm_win64.dll in garrysmod/lua/bin and use the x86-64 branch.", true)
		return false
	end
	S.WrapModule()
	return true
end

-- Warm the engine: load the game data in the background when you join a map,
-- so switching Skater mode on doesn't wait for it. Quiet: if the module isn't
-- there (e.g. not on the x86-64 branch), it just doesn't happen.
local cvWarm = CreateClientConVar("skategm_warm_engine", "1", true, false,
	"Load the game data in the background when you join a map, so Skater mode starts quicker (uses memory even when you're not skating)", 0, 1)
function S.WarmEngine()
	if not cvWarm:GetBool() or S.warmStarted then return end
	if not skategm then
		local ok = pcall(require, "skategm")
		if not ok or not skategm then return end
	end
	if not skategm.Preload then return end
	S.warmStarted = true
	skategm.Preload(DataPath())
end
local function WarmSoon()
	if timer and timer.Simple then timer.Simple(2, function() pcall(S.WarmEngine) end) end
end
hook.Add("InitPostEntity", "skategm_warm", WarmSoon)
-- (the add-on reloaded mid-game: InitPostEntity has already happened)
if timer and timer.Simple then
	timer.Simple(0, function() if LocalPlayer and IsValid(LocalPlayer()) then WarmSoon() end end)
end
if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback("skategm_warm_engine", function(_, _, new) if new == "1" then WarmSoon() end end, "skategm_warm")
end

local function MapBytes()
	local path = "maps/" .. game.GetMap() .. ".bsp"
	local f = file.Open(path, "rb", "GAME")
	if not f then return nil end
	local data = f:Read(f:Size())
	f:Close()
	return data
end

local function V(t) return Vector(t[1], t[2], t[3]) end

---------------------------------------------------------------------------
-- Toggle
---------------------------------------------------------------------------
local function SendState(on, pos, yaw)
	net.Start("skategm_state")
	net.WriteBool(on)
	pos = S.ToAbs(pos or vector_origin)
	net.WriteFloat(pos.x) net.WriteFloat(pos.y) net.WriteFloat(pos.z)
	net.WriteFloat(yaw or 0)
	net.SendToServer()
end

local function Heading()
	local P = S.P
	if P and P.RIGHTUPLEG and P.LEFTUPLEG and P.HIPS and P.SPINE then
		local u = (P.SPINE - P.HIPS):GetNormalized()
		local r = P.RIGHTUPLEG - P.LEFTUPLEG
		r = (r - u * r:Dot(u)):GetNormalized()
		return u:Cross(r):Angle().y
	end
	return LocalPlayer():EyeAngles().y
end

local function Activate()
	presentation.Reset(renderBuffer) S.renderP=nil S.renderCam=nil S.renderState=nil S.renderFrame=nil
	local ply = LocalPlayer()
	local pos = ply:GetPos()
	skategm.Activate(pos.x, pos.y, pos.z, ply:EyeAngles().y)
	S.phase = "on"
	S.frozen = nil
	SendState(true)
end

-- in a minigame that's being played (not its lobby or results)
function S.InMinigamePlay()
	local M = SKATEGM_MODES
	return M ~= nil and M.Playing ~= nil and M.Playing()
end

-- LB + X: back to the map's spawn (the server picks it, as the gamemode would)
function S.Respawn()
	if S.phase ~= "on" or not skategm then return false end
	if S.InMinigamePlay() then Say("not while your minigame is on") return false end
	net.Start("skategm_respawn")
	net.SendToServer()
	return true
end
net.Receive("skategm_respawn", function()
	local pos = S.FromAbs(Vector(net.ReadFloat(), net.ReadFloat(), net.ReadFloat()))
	local yaw = net.ReadFloat()
	if S.phase ~= "on" or not skategm then return end
	skategm.Activate(pos.x, pos.y, pos.z, yaw)
	local hud = S.L and S.L.H
	if hud and hud.events then table.insert(hud.events, 1, { text = "RESPAWN", col = Color(120, 220, 255), t = RealTime() }) end
end)

local function TurnOff()
	presentation.Reset(renderBuffer) S.renderP=nil S.renderCam=nil S.renderState=nil S.renderFrame=nil
	if skategm and skategm.SetFrozen then skategm.SetFrozen(0) end
	if skategm and skategm.SetInputBlocked then skategm.SetInputBlocked(0) end
	if skategm and skategm.SetMarkerBlocked then skategm.SetMarkerBlocked(0) end
	S.frozen, S.inputBlocked, S.viewOverride, S.timeScale, S.inputBlockSent, S.lastMoversSig, S.markerBlockSent = nil, nil, nil, nil, nil, nil, nil
	if S.phase == "on" then
		local pos = S.pose and S.pose.pos and V(S.pose.pos) or LocalPlayer():GetPos()
		SendState(false, pos, Heading())
	end
	S.phase = "off"
end

concommand.Add("skategm_toggle", function()
	if S.phase == "on" or S.phase == "loading" then
		-- (the SkateGM gamemode keeps you skating)
		if S.locked then Say("Skater mode stays on in the SkateGM gamemode") return end
		TurnOff()
		Say("Skater mode off")
		return
	end
	if not LocalPlayer():Alive() then S.lastError = "you're not alive" return end
	if not Native(true) then return end
	S.lastError = nil
	local st = skategm.Poll()
	local scale = math.Clamp(cvScale:GetFloat(), 0.5, 1.5)
	local smooth = math.Clamp(math.floor(cvSmooth:GetFloat() + 0.5), 0, 2)
	local tiny = cvTinySolid:GetBool()
	local creases = cvCreases:GetBool() and 1 or 0
	local steps = math.Clamp(cvSteps:GetFloat(), 0, 12)
	-- any collision setting changed since loading: load again
	local key = string.format("%s|%.2f|%d|%s|%d|%.2f|%s|%d", game.GetMap(), scale, smooth, tostring(tiny), creases, steps, tostring(cvNoPhys:GetBool()), cvStyle:GetInt())
	if S.loadedKey == key and (st.status == "ready" or st.status == "active") then
		Activate()
		return
	end
	if st.status ~= "idle" then skategm.Stop() end
	local bytes = MapBytes()
	if bytes then
		S.mapInfo = string.format("maps/%s.bsp read, %.1f MB", game.GetMap(), #bytes / 1048576)
	else
		S.mapInfo = string.format("maps/%s.bsp could NOT be opened", game.GetMap())
		Say("could not open this map's file; skating on a flat floor", true)
	end
	local path = DataPath()
	local pos = LocalPlayer():GetPos()
	S.ApplyTuning()
	S.brushShape = {}
	local ok, err = skategm.Load(path, pos.x, pos.y, pos.z, LocalPlayer():EyeAngles().y, bytes, scale, smooth, creases, steps)
	S.loadedScale, S.loadedSmooth, S.loadedTiny = scale, smooth, tiny
	S.loadedKey = key
	S.tinyProps, S.boxProps, S.meshProps, S.tiny, S.boxed, S.shapeFrom = 0, 0, 0, {}, {}, {}
	S.passSeen = {}
	if not ok then S.lastError = tostring(err) Say(tostring(err), true) return end
	S.map = game.GetMap()
	S.phase = "loading"
	sent, lastSig = {}, nil
	S.idx = nil
	Say("loading...")
end)

concommand.Add("skategm_report", function()
	if not skategm then Say("module not loaded") return end
	local p = skategm.Poll()
	print(string.format("[SkateGM] engine=%s status=%s phase=%s state=%s load=%dms ticks/s=%d avgTick=%.3fms maxStep=%.2fms memory=%dMB pad=%s controller=%s",
		p.engine or "?", p.status or "?", S.phase, p.state or "-", p.loadMs or 0, p.ticksPerSec or 0,
		p.avgTickMs or 0, p.maxStepMs or 0, math.floor(p.memoryMB or -1), tostring(p.pad), tostring(p.padName)))
	if p.world then print("[SkateGM] " .. p.world) end
	if p.collision then print("[SkateGM] " .. p.collision) end
	local P = S.P
	local camDist = (P and P.HIPS and p.cam) and math.floor((P.HIPS - V(p.cam.pos)):Length()) or -1
	local e = S.skater
	print(string.format("[SkateGM] bones=%s hips-to-camera=%d units, pose callback ran %d times, direct %d times, model=%s rig=%s linkedBones=%s",
		tostring(p.boneSpace), camDist, S.cbCount or 0, S.directCount or 0,
		IsValid(e) and e:GetModel() or "none", tostring(IsValid(e) and e.Sk8Rig ~= nil), tostring(S.rigLinked)))
	local me = LocalPlayer()
	local function fmt(v) return v and string.format("%.0f %.0f %.0f", v.x, v.y, v.z) or "none" end
	local cam = p.cam and V(p.cam.pos)
	print(string.format("[SkateGM] %s | skater drawn %d frames (%d without a pose) | hips %s | camera %s (%.0f from hips) | you %s",
		S.mapInfo or "no map read", S.drawCount or 0, S.noPoseFrames or 0, fmt(P and P.HIPS), fmt(cam),
		(cam and P and P.HIPS) and (cam - P.HIPS):Length() or -1, fmt(IsValid(me) and me:GetPos())))
	local under = S.UnderBoard()
	print(string.format("[SkateGM] under the board: %s", under and string.format("%s, slope %.0f degrees, %.1f units below", under.what, under.slope, under.gap) or "nothing found"))
	if S.drawErr then Say("draw error: " .. S.drawErr, true) end
	if S.meshErr then Say("board model error (using the simple board): " .. S.meshErr, true) end
	local n = 0
	for _ in pairs(S.remote) do n = n + 1 end
	print("[SkateGM] trick names: " .. (p.language and ("the game's own trick names from " .. p.language) or "readable IDs (no trick name table found near the data folder)"))
	print(string.format("[SkateGM] collision rebuilds in the last 10 s: %d (last took %.0f ms)", p.builds10s or 0, p.buildMs or 0))
	if skategm.WarmStatus then
		local state, ms, err = skategm.WarmStatus()
		print(string.format("[SkateGM] engine warm-up (skategm_warm_engine %d): %s%s%s", cvWarm:GetBool() and 1 or 0, state,
			(state == "warm" or state == "failed") and string.format(" in %.0f ms", ms) or "", err and (": " .. err) or ""))
	end
	print(string.format("[SkateGM] tiny props left out (skategm_tiny_props_solid 0): %d, props colliding as their bounding box: %d, as their visible mesh: %d", S.tinyProps or 0, S.boxProps or 0, S.meshProps or 0))
	print(string.format("[SkateGM] other skaters in view: %d, player collision: %s, world scale %.2f, speed %.1f m/s",
		n, cvCollide:GetBool() and "on" or "off", S.loadedScale or 1,
		p.vel and V(p.vel):Length() * 0.0254 * (S.loadedScale or 1) or 0))
	if S.retargetErr then Say("pose error: " .. S.retargetErr, true) end
	if p.error then Say(p.error, true) end
end)

---------------------------------------------------------------------------
---------------------------------------------------------------------------
hook.Add("InputMouseApply", "skategm", function(cmd, x, y)
	keyboard.Mouse(S,x,y)
	if S.phase ~= "on" then return end
	return true
end)

hook.Add("CreateMove", "skategm", function(cmd)
	if S.phase ~= "on" then return end
	cmd:ClearMovement()
	cmd:SetButtons(0)
end)


---------------------------------------------------------------------------
-- Collision for props and entities
---------------------------------------------------------------------------
-- A model's collision hulls, read from GMod's own physics model.
-- the 12 triangles of a box, as one hull
local function BoxHull(mn, mx)
	local c = {}
	local function q(a, b, cc, d)
		for _, v in ipairs({ a, b, cc, a, cc, d }) do c[#c + 1] = v[1] c[#c + 1] = v[2] c[#c + 1] = v[3] end
	end
	local x0, y0, z0, x1, y1, z1 = mn.x, mn.y, mn.z, mx.x, mx.y, mx.z
	q({ x0, y0, z1 }, { x1, y0, z1 }, { x1, y1, z1 }, { x0, y1, z1 })
	q({ x0, y0, z0 }, { x0, y1, z0 }, { x1, y1, z0 }, { x1, y0, z0 })
	q({ x1, y0, z0 }, { x1, y1, z0 }, { x1, y1, z1 }, { x1, y0, z1 })
	q({ x0, y0, z0 }, { x0, y0, z1 }, { x0, y1, z1 }, { x0, y1, z0 })
	q({ x0, y1, z0 }, { x0, y1, z1 }, { x1, y1, z1 }, { x1, y1, z0 })
	q({ x0, y0, z0 }, { x1, y0, z0 }, { x1, y0, z1 }, { x0, y0, z1 })
	return c
end

-- A model's collision hulls. In order:
--   1. GMod's own physics for the model
--   2. the model's .phy file read directly (GMod refuses to build physics for
--      some models - e.g. custom ones packed inside a map - that players still
--      collide with), parsed by the module
--   3. the model's bounding box: for props with "bbox" solidity (asked for with
--      "#bbox"), and for models with no collision model at all
-- S.shapeFrom[model] records which one worked (or why none did).
local function ReadFile(path)
	local f = file.Open(path, "rb", "GAME")
	if not f then return nil end
	local data = f:Read(f:Size())
	f:Close()
	return data
end

S.HullProviders = S.HullProviders or {}
-- modules mark entities that aren't collision for the skater (InfMap's
-- helpers, props light enough to knock over)
S.EntitySkippers = S.EntitySkippers or {}
function S.SkipEntity(e)
	for _, skip in ipairs(S.EntitySkippers) do if skip(e) then return true end end
	return false
end
local function Hulls(name)
	for _, provide in ipairs(S.HullProviders) do
		local flat, isMesh, from = provide(name)
		if flat then
			S.shapeFrom = S.shapeFrom or {}
			S.shapeFrom[string.lower(name)] = from or "provided by a module"
			return flat, isMesh
		end
	end
	local part = SKATEGM_PARTS and SKATEGM_PARTS.FromEngineName(name)
	if part then
		S.shapeFrom = S.shapeFrom or {}
		S.shapeFrom[string.lower(name)] = "a SkateGM park part"
		return { SKATEGM_PARTS.Shape(part).flat }, true
	end
	local out = {}
	local mdl, wantBox = name, false
	if string.sub(name, -5) == "#bbox" then mdl, wantBox = string.sub(name, 1, -6), true end
	S.shapeFrom = S.shapeFrom or {}
	local from
	local okE, e = pcall(ents.CreateClientProp, mdl)
	if not okE or not IsValid(e) then
		-- some models (e.g. ones packed inside the map) load this way instead
		local okC, c = pcall(ClientsideModel, mdl)
		e = okC and c or nil
	end
	if IsValid(e) then
		e:SetPos(vector_origin)
		e:SetAngles(angle_zero)
	end
	local isMesh = false
	-- 1. GMod's physics
	if not wantBox and IsValid(e) and e.PhysicsInit then
		e:PhysicsInit(SOLID_VPHYSICS)
		local phys = e:GetPhysicsObject()
		if IsValid(phys) then
			for _, hull in ipairs(phys:GetMeshConvexes() or {}) do
				local flat = {}
				for _, v in ipairs(hull) do
					local p = v.pos
					flat[#flat + 1] = p.x
					flat[#flat + 1] = p.y
					flat[#flat + 1] = p.z
				end
				if #flat >= 9 then out[#out + 1] = flat end
			end
		end
		if #out > 0 then from = "GMod's physics model" end
	end
	-- 2. the .phy file itself
	if not wantBox and #out == 0 and skategm and skategm.PhyHulls then
		local data = ReadFile((string.gsub(mdl, "%.mdl$", ".phy")))
		if data then
			local hulls, err = skategm.PhyHulls(data)
			if hulls and #hulls > 0 then
				out = hulls
				from = "its .phy file (read directly)"
			else
				from = "none: its .phy file couldn't be read (" .. tostring(err) .. ")"
			end
		end
	end
	-- No physics model and no box solidity: Source doesn't make these solid
	-- for players either (decorative plants and the like), so neither do we -
	-- unless asked (skategm_solid_no_physics 1), then as the visible surface.
	local noPhysics = not wantBox and #out == 0 and IsValid(e) and not cvNoPhys:GetBool()
	if noPhysics then from = "none: no physics model (not solid for players either)" end
	-- 3. (asked for) the model's visible surface, each triangle facing the way
	-- its vertex normals say
	if not noPhysics and not wantBox and #out == 0 and util.GetModelMeshes then
		local okM, meshes = pcall(util.GetModelMeshes, mdl)
		if okM and meshes then
			local flat, count = {}, 0
			for _, m in ipairs(meshes) do
				local tr = m.triangles or {}
				for i = 1, #tr - 2, 3 do
					local a, b, c = tr[i], tr[i + 1], tr[i + 2]
					if a and b and c and a.pos and b.pos and c.pos and count < 30000 then
						local n = (b.pos - a.pos):Cross(c.pos - a.pos)
						local vn = (a.normal or n) + (b.normal or n) + (c.normal or n)
						if n:Dot(vn) < 0 then b, c = c, b end
						for _, v in ipairs({ a, b, c }) do
							flat[#flat + 1] = v.pos.x
							flat[#flat + 1] = v.pos.y
							flat[#flat + 1] = v.pos.z
						end
						count = count + 1
					end
				end
			end
			if count > 0 then
				out, isMesh = { flat }, true
				from = "its visible mesh (it has no physics model)"
				S.meshProps = (S.meshProps or 0) + 1
			end
		end
	end
	-- 4. the bounding box (box solidity, or asked for)
	if #out == 0 and not noPhysics then
		local mn, mx
		if IsValid(e) then
			mn, mx = e:GetModelBounds()
			if not (mn and mx) or (mx - mn):LengthSqr() < 1 then mn, mx = e:OBBMins(), e:OBBMaxs() end
		end
		if not (mn and mx) or (mx - mn):LengthSqr() < 1 then
			-- the .mdl header's collision box (hull_min / hull_max)
			local f = file.Open(mdl, "rb", "GAME")
			if f then
				if f:Read(4) == "IDST" then
					f:Seek(104)
					mn = Vector(f:ReadFloat(), f:ReadFloat(), f:ReadFloat())
					mx = Vector(f:ReadFloat(), f:ReadFloat(), f:ReadFloat())
				end
				f:Close()
			end
		end
		if mn and mx and (mx - mn):LengthSqr() >= 1 then
			out[1] = BoxHull(mn, mx)
			from = "its bounding box"
			S.boxProps = (S.boxProps or 0) + 1
			S.boxed = S.boxed or {}
			S.boxed[string.lower(mdl)] = true
		elseif not from then
			from = IsValid(e) and "none: no collision model and no size" or "none: the model couldn't be loaded"
		end
	end
	if IsValid(e) then e:Remove() end
	S.shapeFrom[string.lower(name)] = from
	-- tiny clutter that GMod players simply step over would stop a Skate
	-- wheel dead: leave it out unless asked (flat plates stay: they're wide)
	if #out > 0 and not cvTinySolid:GetBool() then
		local lo, hi = Vector(1e9, 1e9, 1e9), Vector(-1e9, -1e9, -1e9)
		for _, flat in ipairs(out) do
			for i = 1, #flat - 2, 3 do
				local x, y, z = flat[i], flat[i + 1], flat[i + 2]
				lo = Vector(math.min(lo.x, x), math.min(lo.y, y), math.min(lo.z, z))
				hi = Vector(math.max(hi.x, x), math.max(hi.y, y), math.max(hi.z, z))
			end
		end
		local size = hi - lo
		if math.max(size.x, size.y) <= 24 and size.z <= 12 then
			S.tinyProps = (S.tinyProps or 0) + 1
			S.tiny = S.tiny or {}
			S.tiny[string.lower(mdl)] = true
			return {}, false
		end
	end
	return out, isMesh
end
S.Hulls = Hulls

S.BIG_MESH_FLOATS = 30000
S.LATER = S.LATER or {}
local function FeedModels(list)
	local budget = 4 -- per frame, so loading shapes never hitches
	for _, mdl in ipairs(list or {}) do
		if budget <= 0 then break end
		if not sent[mdl] then
			sent[mdl] = true
			-- never let one odd model stop its shape being sent: on any error,
			-- fall back to its bounding box (and say so once)
			local ok, hulls, isMesh = pcall(Hulls, mdl)
			-- (a provider that can't read it yet: asked again later, not defined empty)
			if ok and hulls == S.LATER then
				sent[mdl] = nil
			else
				if not ok then
					if not S.hullErr then S.hullErr = tostring(hulls) print("[SkateGM] reading the shape of " .. mdl .. " failed: " .. S.hullErr .. " (using its bounding box)") end
					hulls = {}
					local base = string.gsub(mdl, "#bbox$", "")
					local okB, e = pcall(ClientsideModel, base)
					if okB and IsValid(e) then
						local mn, mx = e:GetModelBounds()
						if mn and mx then hulls = { BoxHull(mn, mx) } end
						e:Remove()
					end
				end
				skategm.DefineModel(mdl, hulls, (ok and isMesh) and (isMesh == 2 and 2 or 1) or 0)
				budget = budget - 1
				-- (a big mesh - a map's chunk collider - is the frame's whole budget)
				local floats = 0
				for _, h in ipairs(hulls or {}) do floats = floats + #h end
				if floats > S.BIG_MESH_FLOATS then budget = 0 end
			end
		end
	end
end

-- things players walk through aren't solid to the skater either
local PASS = {
	[COLLISION_GROUP_DEBRIS] = true, [COLLISION_GROUP_DEBRIS_TRIGGER] = true,
	[COLLISION_GROUP_WEAPON] = true, [COLLISION_GROUP_IN_VEHICLE] = true,
	[COLLISION_GROUP_PASSABLE_DOOR] = true, [COLLISION_GROUP_WORLD] = true,
}
local SKIP_CLASS = { prop_ragdoll = true, gmod_hands = true, predicted_viewmodel = true, viewmodel = true }

S.PLAYER_REBUILD_GAP = 1.0
-- The moving collision layer (module: SetMovers): other players, and anything
-- that moved in the last second, are placed straight into the engine every
-- frame instead of rebuilding the whole collision. Something that stops
-- moving goes back to the static collision, and stays in the moving layer a
-- little longer so it's never missing while that rebuild runs.
S.MOVING_HOLD, S.MOVING_OVERLAP = 1.0, 1.5
S.movingEnts = S.movingEnts or {}
function S.UseMovers() return skategm ~= nil and skategm.SetMovers ~= nil and not S.noMovers end

-- (map brush models come with the map, if the module places them: HasShape)
S.brushShape = S.brushShape or {}
function S.CanMove(mdl)
	if sent[mdl] then return true end
	if string.sub(mdl, 1, 1) ~= "*" or not skategm.HasShape then return false end
	if not S.brushShape[mdl] and skategm.HasShape(mdl) then S.brushShape[mdl] = true end
	return S.brushShape[mdl] == true
end

local function AngleOff(a, b) return math.abs(((a - b + 180) % 360) - 180) end
local function MovedSince(e, p, a, now)
	local last = e.Sk8LastPlace
	if last and (last[1]:DistToSqr(p) > 0.25 or AngleOff(last[2].p, a.p) > 0.5 or AngleOff(last[2].y, a.y) > 0.5 or AngleOff(last[2].r, a.r) > 0.5) then
		e.Sk8MovedAt = now
	end
	e.Sk8LastPlace = { p, a }
	return now - (e.Sk8MovedAt or -100)
end

local function FeedEntities(centre)
	local list, sig = {}, {}
	local movers = S.UseMovers()
	local now = RealTime()
	-- only things near the skater; far ones must move a lot before they cause
	-- a collision rebuild (a spinning fan across the map shouldn't stutter you)
	for _, e in ipairs(ents.FindInSphere(centre, 2500)) do
		if IsValid(e) and e ~= S.skater and not e:IsPlayer() and not e:IsNPC() and not e:IsWeapon()
			and not SKIP_CLASS[e:GetClass()] and not S.SkipEntity(e) and e:GetSolid() ~= SOLID_NONE
			and bit.band(e:GetSolidFlags(), bit.bor(FSOLID_NOT_SOLID, FSOLID_TRIGGER)) == 0
			and not PASS[e:GetCollisionGroup()] then
			local mdl = e:GetModel()
			if e.SkateGMPart and e.PartId and SKATEGM_PARTS then mdl = SKATEGM_PARTS.EngineName(e.PartId) end
			if mdl and mdl ~= "" and (e.SkateGMPart or string.sub(mdl, 1, 1) == "*" or string.EndsWith(string.lower(mdl), ".mdl")) then
				-- box solidity collides as the box (as Source does for players)
				local solid = e:GetSolid()
				if not e.SkateGMPart and string.sub(mdl, 1, 1) ~= "*" and (solid == SOLID_BBOX or solid == SOLID_OBB or solid == SOLID_OBB_YAW) then
					mdl = mdl .. "#bbox"
				end
				local p, a = e:GetPos(), e:GetAngles()
				local still = movers and S.CanMove(mdl) and MovedSince(e, p, a, now) or math.huge
				if still < S.MOVING_HOLD + S.MOVING_OVERLAP then
					S.movingEnts[e] = { mdl = mdl, at = e.Sk8MovedAt }
				end
				if still < S.MOVING_HOLD and string.sub(mdl, 1, 1) == "*" then
					-- (a map brush entity, moving: the map's copy must not stand in for it)
					list[#list + 1] = { mdl .. "#moving", p.x, p.y, p.z, a.p, a.y, a.r }
					sig[#sig + 1] = mdl .. "#moving"
				end
				if still >= S.MOVING_HOLD then
					list[#list + 1] = { mdl, p.x, p.y, p.z, a.p, a.y, a.r }
					local near = p:DistToSqr(centre) < 600 * 600
					local d, r = near and 2 or 24, near and 2 or 15
					sig[#sig + 1] = string.format("%s%d,%d,%d,%d,%d,%d", mdl, p.x / d, p.y / d, p.z / d, a.p / r, a.y / r, a.r / r)
				end
			end
		end
	end
	local psig = {}
	if not movers then PlayerBlocks(centre, list, psig) end
	for _, feed in ipairs(S.ExtraFeeds or {}) do feed(centre, list, sig) end
	table.sort(sig)
	table.sort(psig)
	local s, ps = table.concat(sig, ";"), table.concat(psig, ";")
	local now = RealTime()
	local playersMoved = ps ~= S.lastPlayerSig and now - (S.lastPlayerSend or -100) >= S.PLAYER_REBUILD_GAP
	if s ~= lastSig or playersMoved then
		lastSig = s
		if ps ~= S.lastPlayerSig then S.lastPlayerSig, S.lastPlayerSend = ps, now end
		skategm.SetEntities(list)
	end
end

-- a moving entity's velocity (units/s) from where it was a moment ago; doors
-- and lifts (pushers) don't report theirs on the client
-- (and how fast its angles change - pitch, yaw, roll - in degrees a second:
-- a turntable, a seesaw)
function S.MoverVelocity(e, p, now, ang)
	local prev = e.Sk8MoverPrev
	local v = e.Sk8MoverVel or Vector(0, 0, 0)
	local rates = e.Sk8MoverRates or { 0, 0, 0 }
	local cur = ang and { ang.p, ang.y, ang.r } or { 0, 0, 0 }
	if prev and now > prev.t then
		local dt = now - prev.t
		if dt < 0.5 then
			local raw = (p - prev.p) / dt
			-- (smoothed a little: frame times jitter)
			local k = math.min(1, dt * 15)
			v = v + (raw - v) * k
			for i = 1, 3 do
				local d = ((cur[i] - prev.ang[i]) + 180) % 360 - 180
				rates[i] = rates[i] + (d / dt - rates[i]) * k
			end
		else
			v, rates = Vector(0, 0, 0), { 0, 0, 0 }
		end
		e.Sk8MoverPrev = { p = p, t = now, ang = cur }
	elseif not prev then
		e.Sk8MoverPrev = { p = p, t = now, ang = cur }
	end
	e.Sk8MoverVel, e.Sk8MoverRates = v, rates
	return v, rates
end

-- every frame: other players and moving things, into the moving layer
function S.MoversList(centre, now)
	local list, psig = {}, {}
	PlayerBlocks(centre, list, psig)
	for _, feed in ipairs(S.MoverFeeds or {}) do feed(centre, list, now) end
	for e, info in pairs(S.movingEnts) do
		if IsValid(e) and now - (info.at or -100) < S.MOVING_HOLD + S.MOVING_OVERLAP then
			local p, a = e:GetPos(), e:GetAngles()
			if p:DistToSqr(centre) < 2500 * 2500 then
				-- (and how fast it's going, from its own movement frame to frame:
				-- the module carries a skater standing on it - a lift, a platform)
				local v, rates = S.MoverVelocity(e, p, now, a)
				list[#list + 1] = { info.mdl, p.x, p.y, p.z, a.p, a.y, a.r, v.x, v.y, v.z, rates[2], rates[1], rates[3] }
			end
		else
			S.movingEnts[e] = nil
		end
	end
	return list
end

function S.MoversThink(now)
	if S.phase ~= "on" or not S.UseMovers() then return end
	local centre = S.P and S.P.HIPS
	if not centre then return end
	local list = S.MoversList(centre, now)
	local parts = {}
	-- (its velocity too: one that stopped where it was must stop carrying)
	for i, m in ipairs(list) do parts[i] = string.format("%s%.1f,%.1f,%.1f,%.1f,%.1f,%.1f|%.0f,%.0f,%.0f,%.0f,%.0f,%.0f", m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8] or 0, m[9] or 0, m[10] or 0, m[11] or 0, m[12] or 0, m[13] or 0) end
	local sig = table.concat(parts, ";")
	if sig == S.lastMoversSig then return end
	S.lastMoversSig = sig
	skategm.SetMovers(list)
end

---------------------------------------------------------------------------
-- Multiplayer: pose snapshots to and from other players
---------------------------------------------------------------------------
-- Fixed wire order (the engine's skeleton, as skategm_names prints it). Must match
-- POSE_VALUES in skategm_sv.lua: 36 bones x 3 offsets.
local BONES = {
	"TRAJECTORY", "HIPS", "SPINE", "SPINE1", "SPINE2", "SPINE3", "NECK", "NECK1", "HEAD",
	"RIGHTSHOULDER", "RIGHTARM", "RIGHTFOREARM", "RIGHTHAND",
	"LEFTSHOULDER", "LEFTARM", "LEFTFOREARM", "LEFTHAND",
	"RIGHTUPLEG", "RIGHTLEG", "RIGHTFOOT", "RIGHTTOEBASE",
	"LEFTUPLEG", "LEFTLEG", "LEFTFOOT", "LEFTTOEBASE",
	"SKATEBOARD_ROOT", "TRUCK_FRONT", "RIGHT_WHEELFRONT", "LEFT_WHEELFRONT",
	"TRUCK_BACK", "LEFT_WHEELBACK", "RIGHT_WHEELBACK",
	"RIGHTTOEBASE_REPARENTED", "LEFTTOEBASE_REPARENTED", "RIGHTHAND_REPARENTED", "LEFTHAND_REPARENTED",
}
S.BONES = BONES
local SCALE = 16 -- offsets from the hips in 1/16 unit, 16 bits: +-2047 units

-- The engine's physical states (skate-core PhysicalStateId), sent as one byte
local STATES = {
	"PhysicsGround", "SlideGround", "RevertGround", "GroundAnimation", "Skitching", "FollowPath",
	"PhysicsAir", "KnownAir", "PhysicsAirSecondary", "WipeoutGround",
	"GrindBoardslide", "GrindFiftyFifty", "GrindTipslide", "GrindFiveO", "GrindBackslash", "GrindDarkslide",
	"BipedGround", "BipedAir", "OffBoardPushing", "LandingOnDeck", "HandPlant", "FootPlant", "Boneless",
	"Sleeping", "Nonspecific", "Teleporting",
}
local STATE_CODE = {}
for i, name in ipairs(STATES) do STATE_CODE[name] = i end
S.STATES = STATES

-- encode: hips as 3 floats, then each bone's offset from the hips
function S.Encode(P, write, state)
	local h = P.HIPS
	local abs = S.ToAbs(h)
	write.float(abs.x) write.float(abs.y) write.float(abs.z)
	for _, name in ipairs(BONES) do
		local d = (P[name] or h) - h
		write.int(math.Clamp(math.Round(d.x * SCALE), -32767, 32767))
		write.int(math.Clamp(math.Round(d.y * SCALE), -32767, 32767))
		write.int(math.Clamp(math.Round(d.z * SCALE), -32767, 32767))
	end
	write.u8(STATE_CODE[state or ""] or 0)
end

function S.Decode(read)
	local h = S.FromAbs(Vector(read.float(), read.float(), read.float()))
	local P = {}
	for _, name in ipairs(BONES) do
		local x, y, z = read.int(), read.int(), read.int()
		P[name] = Vector(h.x + x / SCALE, h.y + y / SCALE, h.z + z / SCALE)
	end
	P.HIPS = h
	return P, STATES[read.u8()]
end

local netWrite = { float = net.WriteFloat, int = function(v) net.WriteInt(v, 16) end, u8 = function(v) net.WriteUInt(v, 8) end }
local netRead = { float = net.ReadFloat, int = function() return net.ReadInt(16) end, u8 = function() return net.ReadUInt(8) end }

local POSE_KEEPALIVE = 0.4
local function PoseSignature(P, state)
	local parts = { state or "" }
	for _, name in ipairs({ "HIPS", "HEAD", "RIGHTHAND", "LEFTHAND", "RIGHTFOOT", "LEFTFOOT", "TRUCK_FRONT", "TRUCK_BACK" }) do
		local v = P[name]
		if v then parts[#parts + 1] = string.format("%d,%d,%d", v.x * 16, v.y * 16, v.z * 16) end
	end
	return table.concat(parts, ";")
end
S.PoseSignature = PoseSignature

local function SendPose()
	if not (S.P and S.P.HIPS) then return end
	local now = RealTime()
	local sig = PoseSignature(S.P, S.pose and S.pose.state)
	if sig == S.lastPoseSig and now - (S.lastPoseSent or -100) < POSE_KEEPALIVE then return end
	S.lastPoseSig, S.lastPoseSent = sig, now
	net.Start("skategm_pose", true)
	S.Encode(S.P, netWrite, S.pose and S.pose.state)
	net.SendToServer()
end
S.SendPose = SendPose

net.Receive("skategm_pose", function()
	local ply = net.ReadEntity()
	local P, state = S.Decode(netRead)
	if not IsValid(ply) or ply == LocalPlayer() then return end
	local r = S.remote[ply] or { snaps = {} }
	local now = RealTime()
	table.insert(r.snaps, { t = now, P = P })
	while #r.snaps > 4 do table.remove(r.snaps, 1) end
	r.last = now
	r.state = state
	S.remote[ply] = r
end)

net.Receive("skategm_off", function()
	local ply = net.ReadEntity()
	S.remote[ply] = nil
	S.StopSounds(ply)
	if IsValid(models[ply]) then models[ply]:Remove() end
	models[ply] = nil
end)

local DELAY = 0.1 -- draw remote skaters this far in the past, between two snapshots

-- pose of a remote skater at time `now`, blended between snapshots
function S.RemotePose(r, now)
	local snaps = r.snaps
	if #snaps == 0 then return nil end
	local newest = snaps[#snaps]
	if r.cacheT == now and r.cacheNewest == newest and r.cacheN == #snaps then return r.cacheP, r.cacheStale end
	local P, stale = S.InterpolatePose(snaps, now)
	r.cacheT, r.cacheNewest, r.cacheN, r.cacheP, r.cacheStale = now, newest, #snaps, P, stale
	return P, stale
end

function S.InterpolatePose(snaps, now)
	local t = now - DELAY
	if t <= snaps[1].t then return snaps[1].P end
	for i = 1, #snaps - 1 do
		local a, b = snaps[i], snaps[i + 1]
		if t >= a.t and t <= b.t then
			local f = (t - a.t) / math.max(b.t - a.t, 1e-3)
			local P = {}
			for name, v in pairs(a.P) do
				local w = b.P[name]
				P[name] = w and LerpVector(f, v, w) or v
			end
			return P
		end
	end
	return snaps[#snaps].P, true -- newest; don't extrapolate (true = stale: nothing newer arrived yet)
end

-- person-sized block other players become in your engine (feet at origin)
local function PlayerHull()
	local w, h = 14, 64
	local c = {}
	local function q(a, b, cc, d)
		for _, v in ipairs({ a, b, cc, a, cc, d }) do c[#c + 1] = v[1] c[#c + 1] = v[2] c[#c + 1] = v[3] end
	end
	q({ -w, -w, h }, { w, -w, h }, { w, w, h }, { -w, w, h })
	q({ -w, -w, 0 }, { -w, w, 0 }, { w, w, 0 }, { w, -w, 0 })
	q({ w, -w, 0 }, { w, w, 0 }, { w, w, h }, { w, -w, h })
	q({ -w, -w, 0 }, { -w, -w, h }, { -w, w, h }, { -w, w, 0 })
	q({ -w, w, 0 }, { -w, w, h }, { w, w, h }, { w, w, 0 })
	q({ -w, -w, 0 }, { w, -w, 0 }, { w, -w, h }, { -w, -w, h })
	return { c }
end

-- where other players stand now, for your engine's collision
function PlayerBlocks(centre, list, sig)
	if not cvCollide:GetBool() or S.noPlayerCollision then return end
	local me = LocalPlayer()
	local now = RealTime()
	for _, ply in ipairs(player.GetAll()) do
		if ply ~= me and ply:Alive() and not S.IsHidden(ply) then
			local pos
			local r = S.remote[ply]
			if r and now - r.last < 0.5 then
				local P = S.RemotePose(r, now)
				if P and P.HIPS then
					-- feet: the lower of the two foot bones, under the hips
					local fz = math.min((P.RIGHTFOOT or P.HIPS).z, (P.LEFTFOOT or P.HIPS).z)
					pos = Vector(P.HIPS.x, P.HIPS.y, fz - 4)
				end
			elseif not ply:GetNoDraw() then
				pos = ply:GetPos() -- walking normally
			end
			if pos and pos:DistToSqr(centre) < 1500 * 1500 then
				list[#list + 1] = { "skategm/player", pos.x, pos.y, pos.z, 0, 0, 0 }
				sig[#sig + 1] = string.format("p%d,%d,%d", pos.x / 16, pos.y / 16, pos.z / 16)
			end
		end
	end
	for key, r in pairs(S.remote) do
		if istable(key) and key.ghost and not key.noCollide and now - r.last < 0.5 then
			local P = S.RemotePose(r, now)
			if P and P.HIPS then
				local fz = math.min((P.RIGHTFOOT or P.HIPS).z, (P.LEFTFOOT or P.HIPS).z)
				local pos = Vector(P.HIPS.x, P.HIPS.y, fz - 4)
				if pos:DistToSqr(centre) < 1500 * 1500 then
					list[#list + 1] = { "skategm/player", pos.x, pos.y, pos.z, 0, 0, 0 }
					sig[#sig + 1] = string.format("g%d,%d,%d", pos.x / 16, pos.y / 16, pos.z / 16)
				end
			end
		end
	end
end


---------------------------------------------------------------------------
-- Ghost: replay your own last 10 s as another skater, for testing multiplayer
-- alone. It goes through the same drawing, smoothing and collision code as a
-- real remote skater (only the network hop is skipped).
--   skategm_ghost        start / stop replaying your recent skating
---------------------------------------------------------------------------
local record = {}          -- { t, P } of your own skating, 20 per second
local GHOST_SECONDS = 15
local ghost                -- stands in for a remote player

local function CopyPose(P)
	local c = {}
	for k, v in pairs(P) do c[k] = v end
	return c
end

function S.Record(now)
	if not (S.P and S.P.HIPS) then return end
	record[#record + 1] = { t = now, P = CopyPose(S.P), state = S.pose and S.pose.state, trick = S.H and S.H.trick ~= "" and now - (S.H.trickT or -10) < 2.5 and S.H.trick or nil, rocket = S.rocketOn or nil }
	while record[1] and now - record[1].t > GHOST_SECONDS do table.remove(record, 1) end
end

-- the last 15 s of my skating, oldest first, times from 0
function S.RecentClip()
	if #record == 0 then return nil end
	local t0, out = record[1].t, {}
	for i, r in ipairs(record) do out[i] = { t = r.t - t0, P = r.P, state = r.state, trick = r.trick, rocket = r.rocket } end
	return out
end

local function GhostPlayer()
	-- looks like you (your model, skin, colour), but isn't you
	local me = LocalPlayer()
	local g = { ghost = true }
	function g:IsValid() return IsValid(me) end
	function g:GetModel() return me:GetModel() end
	function g:GetPlayerColor() return me:GetPlayerColor() end
	function g:GetSkin() return me:GetSkin() end
	function g:GetNumBodyGroups() return me:GetNumBodyGroups() end
	function g:GetBodygroup(i) return me:GetBodygroup(i) end
	return g
end

concommand.Add("skategm_ghost", function()
	if ghost then
		S.remote[ghost.key] = nil
		S.StopSounds(ghost.key)
		if IsValid(models[ghost.key]) then models[ghost.key]:Remove() end
		models[ghost.key] = nil
		ghost = nil
		Say("ghost stopped")
		return
	end
	if #record < 20 then Say("skate for a few seconds first, then skategm_ghost", true) return end
	local clip = {}
	for i, r in ipairs(record) do clip[i] = r end
	ghost = { key = GhostPlayer(), clip = clip, start = RealTime(), index = 1 }
	Say(string.format("ghost replaying your last %.1f s (skategm_ghost again to stop)", clip[#clip].t - clip[1].t))
end)

-- clips game modes play back (a recorded run, as a ghost that looks like
-- whoever skated it): id -> { key, clip, start, index }
S.clips = S.clips or {}

function S.ClipProxy(ply)
	local g = { ghost = true, noCollide = true, of = ply }
	function g:IsValid() return IsValid(ply) end
	function g:GetModel() return ply:GetModel() end
	function g:GetPlayerColor() return ply:GetPlayerColor() end
	function g:GetSkin() return ply:GetSkin() end
	function g:GetNumBodyGroups() return ply:GetNumBodyGroups() end
	function g:GetBodygroup(i) return ply:GetBodygroup(i) end
	function g:GetNW2String(k, d) return ply:GetNW2String(k, d) end
	function g:Nick() return ply:Nick() end
	return g
end

function S.ForgetSkater(key)
	S.remote[key] = nil
	S.StopSounds(key)
	local em = S.emitters and S.emitters[key]
	if em then S.emitters[key] = nil pcall(function() em:Finish() end) end
	if IsValid(models[key]) then models[key]:Remove() end
	models[key] = nil
end

function S.StopClip(id)
	local c = S.clips[id]
	if not c then return end
	S.clips[id] = nil
	S.ForgetSkater(c.key)
end

function S.PlayClip(id, ply, clip, now)
	S.StopClip(id)
	if not (IsValid(ply) and clip and #clip > 0) then return nil end
	local c = { key = S.ClipProxy(ply), clip = clip, start = now or RealTime(), index = 1 }
	S.clips[id] = c
	return c.key
end

function S.ClipsThink(now)
	for id, c in pairs(S.clips) do
		local clip = c.clip
		local elapsed = now - c.start
		while c.index <= #clip and clip[c.index].t - clip[1].t <= elapsed do
			local r = S.remote[c.key] or { snaps = {} }
			table.insert(r.snaps, { t = now, P = clip[c.index].P })
			while #r.snaps > 4 do table.remove(r.snaps, 1) end
			r.last = now
			r.state = clip[c.index].state
			S.remote[c.key] = r
			c.rocket = clip[c.index].rocket
			c.index = c.index + 1
		end
		local r = S.remote[c.key]
		if c.rocket and r and r.snaps[#r.snaps] then pcall(S.RocketFlames, r.snaps[#r.snaps].P, now, c.key, true) end
		if c.index > #clip and elapsed > clip[#clip].t - clip[1].t + 1 then S.StopClip(id) end
	end
end

-- feed the ghost's snapshots as if they were arriving from the network
function S.GhostThink(now)
	if not ghost then return end
	local clip = ghost.clip
	local span = clip[#clip].t - clip[1].t
	local elapsed = now - ghost.start
	if elapsed > span then -- loop
		ghost.start, ghost.index, elapsed = now, 1, 0
		local r = S.remote[ghost.key]
		if r then r.snaps = {} end
	end
	while ghost.index <= #clip and clip[ghost.index].t - clip[1].t <= elapsed do
		local r = S.remote[ghost.key] or { snaps = {} }
		table.insert(r.snaps, { t = now, P = clip[ghost.index].P })
		while #r.snaps > 4 do table.remove(r.snaps, 1) end
		r.last = now
		r.state = clip[ghost.index].state
		S.remote[ghost.key] = r
		ghost.index = ghost.index + 1
	end
end

include("skategm/cl_sound.lua")
local cvSounds, cvVolume = S.L.cvSounds, S.L.cvVolume
S.L.Say, S.L.WATER = Say, WATER
include("skategm/cl_hud.lua")
local EnsureHud, H, Shadowed, cvHud = S.L.EnsureHud, S.L.H, S.L.Shadowed, S.L.cvHud
S.L.H, S.L.Shadowed, S.L.cvSounds = H, Shadowed, cvSounds
include("skategm/cl_marker.lua")
S.L.WATER, S.L.cvSounds = WATER, cvSounds
include("skategm/cl_water.lua")
include("skategm/cl_boundary.lua")
S.L.PASS, S.L.SOURCE_NAMES, S.L.Say = PASS, SOURCE_NAMES, Say
include("skategm/cl_why.lua")
---------------------------------------------------------------------------
-- Controller extras (the add-on's own, on top of the game's own controls)
--   Rocket board: hold the right stick in, riding or in the air - flames out
--   of the tail and a hard push forward. (Alone, the stick click does nothing
--   in the original game; it's only half of the both-sticks-and-triggers bail.)
--   Interact on foot: RB off the board uses what the skater faces, as E would.
---------------------------------------------------------------------------
local cvRocket = CreateClientConVar("skategm_rocket", "0", true, false, "Rocket board: a rocket on the tail; hold the right stick in to fire it", 0, 1)
local BTN_RS = 0x0080
local cvRBUse = CreateClientConVar("skategm_rb_use", "1", true, false, "RB while off the board uses what the skater faces (doors, buttons)", 0, 1)
local cvUnfocused = CreateClientConVar("skategm_input_unfocused", "0", true, false, "1 = the controller still skates while the game window isn't in front (0: only the window you're in, so two copies of the game on one PC don't both skate)", 0, 1)

-- the engine reads the first controller itself: blocked while a menu wants
-- the pad (API.BlockInput) or while this window isn't the one in front
function S.InputBlockWanted()
	if S.inputBlocked then return true end
	if cvUnfocused:GetBool() or not (system and system.HasFocus) then return false end
	return not system.HasFocus()
end
function S.ApplyInputBlock()
	local want = S.InputBlockWanted()
	if want == S.inputBlockSent then return end
	S.inputBlockSent = want
	if skategm and skategm.SetInputBlocked then skategm.SetInputBlocked(want and 1 or 0) end
end
-- no session marker (set / return) while a minigame is being played
function S.ApplyMarkerBlock()
	local want = S.InMinigamePlay()
	if want == S.markerBlockSent then return end
	S.markerBlockSent = want
	if skategm and skategm.SetMarkerBlocked then skategm.SetMarkerBlocked(want and 1 or 0) end
end
local BTN_RB = 0x0200
local ROCKET_ACCEL, ROCKET_TOP = 18, 30 -- m/s per second, top speed m/s
S.ROCKET_ACCEL, S.ROCKET_TOP = ROCKET_ACCEL, ROCKET_TOP
-- riding: rolling, powersliding, reverting, or in the air (not on foot, not bailing)
local BOARD_STATES = { "PhysicsGround", "SlideGround", "RevertGround", "Air" }
local function OnBoard(state)
	if state == nil or state:find("Biped", 1, true) or state:find("Wipeout", 1, true) then return false end
	for _, s in ipairs(BOARD_STATES) do if state:find(s, 1, true) then return true end end
	return false
end
local function OnFoot(state) return state ~= nil and state:find("Biped", 1, true) ~= nil end
S.OnBoard, S.OnFoot = OnBoard, OnFoot
local ROCKET_NOZZLE, ROCKET_Z = 13.2, -1.2 -- the thruster model's nozzle, under the tail
local function Tail(P)
	if not (P and P.TRUCK_FRONT and P.TRUCK_BACK) then return nil end
	local along = P.TRUCK_FRONT - P.TRUCK_BACK
	if along:LengthSqr() < 1e-4 then return nil end
	along = along:GetNormalized()
	local centre = (P.TRUCK_FRONT + P.TRUCK_BACK) / 2
	local half = (P.TRUCK_FRONT - P.TRUCK_BACK):Length() / 2
	local rf, lf, rb, lb = P.RIGHT_WHEELFRONT, P.LEFT_WHEELFRONT, P.RIGHT_WHEELBACK, P.LEFT_WHEELBACK
	local base
	if rf and lf and rb and lb then
		local up = ((rf + rb) - (lf + lb)):GetNormalized():Cross(along):GetNormalized()
		local wheels = (rf + lf + rb + lb) / 4
		base = centre - up * (centre - wheels):Dot(up) + up * (2.0 + ROCKET_Z)
	else
		base = centre + Vector(0, 0, 1)
	end
	return base - along * (half * ROCKET_NOZZLE / 7), along
end
S.Tail = Tail

S.emitters, S.rocketSound, S.rocketRemote = {}, {}, {}
S.rocketLoops = {}
function S.RocketSoundFor(ply)
	local look = BOARD and BOARD.client and IsValid(ply) and ply.GetNW2String and BOARD.client.LookFor(ply)
	return look and look.rocketSound or "weapons/rpg/rocket1.wav"
end

function S.RocketLoop(key, now)
	local ply = Entity and Entity(key)
	local path = S.RocketSoundFor(ply)
	local L = S.rocketLoops[key]
	if L and L.path ~= path then L.snd:Stop() L = nil end
	if not L then
		local ent = (IsValid(ply) and models[ply]) or ply or LocalPlayer()
		if not IsValid(ent) then return end
		local ok, snd = pcall(CreateSound, ent, path)
		if not ok or not snd then return end
		snd:PlayEx(0.8 * cvVolume:GetFloat(), 100)
		L = { snd = snd, path = path }
		S.rocketLoops[key] = L
	end
	L.last = now
end

function S.RocketLoopsThink(now)
	for key, L in pairs(S.rocketLoops) do
		if now - (L.last or 0) > 0.25 then
			L.snd:FadeOut(0.2)
			S.rocketLoops[key] = nil
		end
	end
end

function S.RocketFlames(P, now, key, quiet)
	local pos, fwd = Tail(P)
	if not pos then return end
	local em = S.emitters[key]
	if not em and ParticleEmitter then em = ParticleEmitter(pos) S.emitters[key] = em end
	if em then
		em:SetPos(pos)
		for i = 1, 3 do
			local pt = em:Add("particles/flamelet" .. math.random(1, 5), pos)
			if pt then
				pt:SetVelocity(-fwd * math.Rand(250, 400) + VectorRand() * 30)
				pt:SetDieTime(math.Rand(0.12, 0.25))
				pt:SetStartAlpha(255) pt:SetEndAlpha(0)
				pt:SetStartSize(math.Rand(5, 8)) pt:SetEndSize(1)
				pt:SetColor(255, math.random(140, 200), 60)
				pt:SetRoll(math.Rand(0, 360))
			end
		end
		local sm = em:Add("particle/particle_smokegrenade", pos)
		if sm then
			sm:SetVelocity(-fwd * 120 + VectorRand() * 20)
			sm:SetDieTime(math.Rand(0.8, 1.4))
			sm:SetStartAlpha(90) sm:SetEndAlpha(0)
			sm:SetStartSize(6) sm:SetEndSize(26)
			sm:SetColor(120, 120, 120)
			sm:SetRoll(math.Rand(0, 360))
		end
	end
	if DynamicLight then
		local dl = DynamicLight(4096 + (tonumber(key) or 0))
		if dl then
			dl.pos, dl.r, dl.g, dl.b = pos, 255, 150, 60
			dl.brightness, dl.Decay, dl.Size, dl.DieTime = 3, 1000, 180, CurTime() + 0.1
		end
	end
	if not quiet and cvSounds:GetBool() then S.RocketLoop(key, now) end
end

function S.RocketThink(p, now, dt)
	local on = cvRocket:GetBool() and S.phase == "on" and p ~= nil
		and bit.band(bit.bor(p.padButtons or 0, S.keyboardButtons or 0), BTN_RS) ~= 0 and OnBoard(p.state)
	on = on and true or false
	if not on and not S.rocketOn then return end
	local pos, fwd = Tail(S.P)
	if on ~= (S.rocketOn or false) then
		S.rocketOn = on
		net.Start("skategm_rocket") net.WriteBool(on) net.SendToServer()
		if on and pos and cvSounds:GetBool() then sound.Play("weapons/rpg/rocketfire1.wav", pos, 80, 100, cvVolume:GetFloat()) end
	end
	if not on or not fwd then return end
	local scale = S.loadedScale or 1
	local v = p.vel and Vector(p.vel[1], p.vel[2], p.vel[3]) or Vector()
	local speed = v:Length() * 0.0254 * scale
	local top = ROCKET_TOP
	local limit = cvSpeedLimit:GetFloat()
	if limit > 0 then top = math.min(top, limit) end
	if speed < top then
		local dv = math.min(ROCKET_ACCEL * dt, top - speed) / (0.0254 * scale)
		skategm.Push(fwd.x * dv, fwd.y * dv, fwd.z * dv)
	end
	local me = models[LocalPlayer()]
	S.RocketFlames(IsValid(me) and me.Sk8P or S.P, now, LocalPlayer():EntIndex())
end

-- which way the skater faces, from its shoulders (flat). (The engine's bones
-- are RIGHTSHOULDER / LEFTSHOULDER - no underscore; with one this was always
-- nil and RB never did anything.)
function S.Facing(P)
	if not (P and P.RIGHTSHOULDER and P.LEFTSHOULDER) then return nil end
	local right = P.RIGHTSHOULDER - P.LEFTSHOULDER
	right.z = 0
	if right:LengthSqr() < 1 then return nil end
	return Vector(0, 0, 1):Cross(right:GetNormalized())
end

function S.UseThink(p)
	local rb = p ~= nil and bit.band(p.padButtons or 0, BTN_RB) ~= 0
	local pressed = rb and not S.rbWas
	S.rbWas = rb
	if not pressed or not cvRBUse:GetBool() or S.phase ~= "on" or not OnFoot(p.state) or not S.P then return end
	local head = S.P.HEAD or S.P.NECK or S.P.HIPS
	local dir = S.Facing(S.P)
	if not (head and dir) then return end
	local abs = S.ToAbs(head)
	net.Start("skategm_use") net.WriteFloat(abs.x) net.WriteFloat(abs.y) net.WriteFloat(abs.z) net.WriteVector(dir) net.SendToServer()
end


hook.Add("Think", "skategm_controller", function()
	keyboard.Shortcuts(S)
	local now, p = RealTime(), S.pose
	if S.phase == "on" then S.ApplyInputBlock() S.ApplyMarkerBlock() end
	if S.phase == "on" and p and not S.InputBlockWanted() then
		pcall(S.RocketThink, p, now, FrameTime())
		pcall(S.UseThink, p)
	elseif S.rocketOn then
		S.rocketOn = false
		net.Start("skategm_rocket") net.WriteBool(false) net.SendToServer()
	end
	S.RocketLoopsThink(now)
	-- other skaters' rockets
	for ply, on in pairs(S.rocketRemote) do
		if not IsValid(ply) or not on then S.rocketRemote[ply] = nil
		else
			local r = S.remote[ply]
			local m = models[ply]
			local P = (IsValid(m) and m.Sk8P) or (r and S.RemotePose(r, now))
			if P then pcall(S.RocketFlames, P, now, ply:EntIndex()) end
		end
	end
end)
net.Receive("skategm_rocket", function()
	local ply, on = net.ReadEntity(), net.ReadBool()
	if IsValid(ply) then S.rocketRemote[ply] = on or nil end
end)

S.L.SOURCE_NAMES, S.L.Say, S.L.cvCreases, S.L.cvSteps = SOURCE_NAMES, Say, cvCreases, cvSteps
include("skategm/cl_trace.lua")
---------------------------------------------------------------------------
-- Simulation pump
---------------------------------------------------------------------------
hook.Add("Think", "skategm", function()
	S.GhostThink(RealTime())
	S.MoversThink(RealTime())
	S.ClipsThink(RealTime())
	S.UpdateSkaters(RealTime(), S.phase == "on" and "remote" or nil)
	if S.phase == "off" or not skategm then return end
	local p = skategm.Poll(S.idx == nil)
	if p.status == "error" then
		Say("engine error: " .. tostring(p.error), true)
		S.lastError = "the engine stopped: " .. tostring(p.error)
		TurnOff()
		return
	end
	if S.phase == "loading" then
		if p.status == "ready" or p.status == "active" then
			skategm.DefineModel("skategm/player", PlayerHull())
			if S.WaterPlateHull then skategm.DefineModel(S.WATER_PLATE, S.WaterPlateHull(), 1) end
			Say("Skater mode on")
			if p.world and string.find(p.world, "MAP NOT READABLE", 1, true) then
				Say("this map's collision couldn't be read: skating on what could be", true)
			end
			Activate()
		end
		return
	end

	if (p.recovered or 0) > (S.recovered or 0) then
		S.recovered = p.recovered
		Say("the engine hit an unsupported move and reset your skater: " .. tostring(p.warning))
	end

	keyboard.Step(S,p,FrameTime() * (S.timeScale or 1))
	if S.keyboardActive then S.keyboardUsed = true end
	S.noPad = p.pad == false and not (keyboard.Enabled() and S.keyboardUsed)
	S.padName = p.padName
	S.engineState = p.state

	S.pose = p
	if p.names and not S.idx then
		S.idx = {}
		for i, n in ipairs(p.names) do S.idx[n] = i end
	end
	if p.bones and S.idx then
		local P = S.P or {}
		for name, i in pairs(S.idx) do
			local b = p.bones[i]
			if b then P[name] = Vector(b[1], b[2], b[3]) end
		end
		-- With a world scale below 1 the engine's skater is proportionally bigger
		-- than the map. Shrink what we draw back to normal size around the wheels,
		-- so the board stays on the ground and the body looks right.
		local scale = S.loadedScale or 1
		local w = P.RIGHT_WHEELFRONT and P.LEFT_WHEELFRONT and P.RIGHT_WHEELBACK and P.LEFT_WHEELBACK
		local anchor = w and (P.RIGHT_WHEELFRONT + P.LEFT_WHEELFRONT + P.RIGHT_WHEELBACK + P.LEFT_WHEELBACK) / 4 or P.HIPS
		S.anchor = anchor
		if anchor and math.abs(scale - 1) > 1e-3 then
			for name, v in pairs(P) do P[name] = anchor + (v - anchor) * scale end
		end
		S.P = P
		presentation.Push(renderBuffer,p,P,RealTime())
		S.UpdateSkaters(RealTime(), "local") -- this frame's pose, so the skater never lags the camera
	end

	FeedModels(p.needModels)
	if p.score then S.HudUpdate(p.score, RealTime()) end
	if p.marker then S.MarkerUpdate(p.marker, RealTime(), S.P and S.P.HIPS) end
	pcall(S.PassThrough, RealTime())
	if S.trace then pcall(S.TraceThink, p, RealTime()) end
	-- water must never be able to stop the rest of this frame's work
	local okW, errW = pcall(S.WaterThink, S.P, p.state, RealTime())
	if not okW and not S.waterErr then S.waterErr = tostring(errW) Say("water check error: " .. S.waterErr, true) end
	if cvHud:GetBool() and vgui and vgui.Create then pcall(EnsureHud) end
	if RealTime() > (S.nextEnts or 0) and p.pos then
		S.nextEnts = RealTime() + 0.25
		FeedEntities(V(p.pos))
	end

	if cvShowCol:GetBool() and S.anchor and RealTime() > (S.nextCol or 0) and skategm.CollisionNear then
		S.nextCol = RealTime() + 0.5
		S.debugTris, S.debugTags = skategm.CollisionNear(S.anchor.x, S.anchor.y, S.anchor.z, 700, 4000)
	elseif not cvShowCol:GetBool() then
		S.debugTris = nil
	end

	if RealTime() > (S.nextPose or 0) then
		S.nextPose = RealTime() + 0.05
		SendPose()
		S.Record(RealTime())
	end

	if RealTime() > S.nextSync and p.pos and (not S.lastSyncPos or V(p.pos):DistToSqr(S.lastSyncPos) > 1 or RealTime() - (S.lastSyncAt or 0) > 2) then
		S.nextSync = RealTime() + 0.2
		S.lastSyncPos, S.lastSyncAt = V(p.pos), RealTime()
		net.Start("skategm_pos")
		local abs = S.ToAbs(V(p.pos))
		net.WriteFloat(abs.x) net.WriteFloat(abs.y) net.WriteFloat(abs.z)
		net.SendToServer()
	end
end)

---------------------------------------------------------------------------
-- Skater: your player model, retargeted from the Skate skeleton
---------------------------------------------------------------------------
-- GMod bone -> { skate bone, skate child it points at, GMod child it points with }
local SWING = {
	["ValveBiped.Bip01_Spine"]      = { "SPINE", "SPINE1", "ValveBiped.Bip01_Spine1" },
	["ValveBiped.Bip01_Spine1"]     = { "SPINE1", "SPINE2", "ValveBiped.Bip01_Spine2" },
	["ValveBiped.Bip01_Spine2"]     = { "SPINE2", "SPINE3", "ValveBiped.Bip01_Spine4" },
	["ValveBiped.Bip01_Spine4"]     = { "SPINE3", "NECK", "ValveBiped.Bip01_Neck1" },
	["ValveBiped.Bip01_Neck1"]      = { "NECK", "HEAD", "ValveBiped.Bip01_Head1" },
	["ValveBiped.Bip01_R_Clavicle"] = { "RIGHTSHOULDER", "RIGHTARM", "ValveBiped.Bip01_R_UpperArm" },
	["ValveBiped.Bip01_R_UpperArm"] = { "RIGHTARM", "RIGHTFOREARM", "ValveBiped.Bip01_R_Forearm" },
	["ValveBiped.Bip01_R_Forearm"]  = { "RIGHTFOREARM", "RIGHTHAND", "ValveBiped.Bip01_R_Hand" },
	["ValveBiped.Bip01_L_Clavicle"] = { "LEFTSHOULDER", "LEFTARM", "ValveBiped.Bip01_L_UpperArm" },
	["ValveBiped.Bip01_L_UpperArm"] = { "LEFTARM", "LEFTFOREARM", "ValveBiped.Bip01_L_Forearm" },
	["ValveBiped.Bip01_L_Forearm"]  = { "LEFTFOREARM", "LEFTHAND", "ValveBiped.Bip01_L_Hand" },
	["ValveBiped.Bip01_R_Thigh"]    = { "RIGHTUPLEG", "RIGHTLEG", "ValveBiped.Bip01_R_Calf" },
	["ValveBiped.Bip01_R_Calf"]     = { "RIGHTLEG", "RIGHTFOOT", "ValveBiped.Bip01_R_Foot" },
	["ValveBiped.Bip01_R_Foot"]     = { "RIGHTFOOT", "RIGHTTOEBASE", "ValveBiped.Bip01_R_Toe0" },
	["ValveBiped.Bip01_L_Thigh"]    = { "LEFTUPLEG", "LEFTLEG", "ValveBiped.Bip01_L_Calf" },
	["ValveBiped.Bip01_L_Calf"]     = { "LEFTLEG", "LEFTFOOT", "ValveBiped.Bip01_L_Foot" },
	["ValveBiped.Bip01_L_Foot"]     = { "LEFTFOOT", "LEFTTOEBASE", "ValveBiped.Bip01_L_Toe0" },
}

local function Basis(r, u)
	u = u:GetNormalized()
	r = (r - u * r:Dot(u)):GetNormalized()
	local f = u:Cross(r)
	return Matrix({
		{ r.x, f.x, u.x, 0 },
		{ r.y, f.y, u.y, 0 },
		{ r.z, f.z, u.z, 0 },
		{ 0, 0, 0, 1 },
	})
end

-- rotate world matrix m so that its child offset `off` (a local transform)
-- points along `to`. Checks the result and flips the rotation sense if needed,
-- so it doesn't depend on RotateAroundAxis's handedness.
local function Swing(m, off, to)
	local function dir() return ((m * off):GetTranslation() - m:GetTranslation()):GetNormalized() end
	local a, b = dir(), to:GetNormalized()
	local axis = a:Cross(b)
	local s = axis:Length()
	if s < 1e-4 then return end
	axis:Div(s)
	local deg = math.deg(math.atan2(s, a:Dot(b)))
	local base = m:GetAngles()
	local ang = Angle(base.p, base.y, base.r)
	ang:RotateAroundAxis(axis, deg)
	m:SetAngles(ang)
	if dir():Dot(b) < a:Dot(b) then
		ang = Angle(base.p, base.y, base.r)
		ang:RotateAroundAxis(axis, -deg)
		m:SetAngles(ang)
	end
end

local retailRig=include("skategm/cl_retarget.lua")
local function Retarget(ent)
	local P=ent.Sk8P
	if S.RenderSpace and P then P=S.RenderSpace(P) end
	if not (P and P.HIPS and ent.Sk8Rig) then return end
	if not ent.Sk8Bind then retailRig.Bind(ent) end
	retailRig.Apply(ent,P)
end

S.test = { Retarget = Retarget, Swing = Swing, Basis = Basis, FeedEntities = FeedEntities, sent = sent } -- for offline tests

local function Skater(ply)
	local mdl = ply:GetModel()
	local e = models[ply]
	if IsValid(e) and e.Sk8Model == mdl then
		local now = RealTime()
		if now >= (e.Sk8LookCheck or 0) then
			e.Sk8LookCheck = now + 0.5
			e:SetSkin(ply:GetSkin())
			for i = 0, ply:GetNumBodyGroups() - 1 do e:SetBodygroup(i, ply:GetBodygroup(i)) end
		end
		return e
	end
	if IsValid(e) then e:Remove() end
	e = ClientsideModel(mdl, RENDERGROUP_OPAQUE)
	if not IsValid(e) then return nil end
	e.Sk8Model = mdl
	e.Sk8Ply = ply
	e:SetNoDraw(true) -- shown once it has a pose
	e:DrawShadow(false)
	e.Sk8Render = function(self) S.RenderSkater(self) end
	e.RenderOverride = e.Sk8Render
	e:SetRenderBounds(Vector(-100, -100, -100), Vector(100, 100, 100))
	e.GetPlayerColor = function() return IsValid(ply) and ply:GetPlayerColor() or Vector(1, 1, 1) end
	e:SetSkin(ply:GetSkin())
	for i = 0, ply:GetNumBodyGroups() - 1 do e:SetBodygroup(i, ply:GetBodygroup(i)) end
	local seq=-1
	for _,name in ipairs({"reference","ragdoll","idle_all_01"}) do
		seq=e:LookupSequence(name) if seq>=0 then break end
	end
	e:ResetSequence(math.max(seq,0)) e:SetPlaybackRate(0) e:SetCycle(0)
	-- rig: bone indices for retargeting (parents are read at posing time)
	local R = { parent = {}, swing = {} }
	R.pelvis = e:LookupBone("ValveBiped.Bip01_Pelvis")
	R.spine = e:LookupBone("ValveBiped.Bip01_Spine")
	R.rthigh = e:LookupBone("ValveBiped.Bip01_R_Thigh")
	R.lthigh = e:LookupBone("ValveBiped.Bip01_L_Thigh")
	for gname, rule in pairs(SWING) do
		local gi, gc = e:LookupBone(gname), e:LookupBone(rule[3])
		if gi and gc then R.swing[gi] = { a = rule[1], b = rule[2], child = gc } end
	end
	if R.pelvis and R.spine and R.rthigh and R.lthigh then
		e.Sk8Rig = R
		e:AddCallback("BuildBonePositions", function(ent)
			S.cbCount = (S.cbCount or 0) + 1
			local ok, err = pcall(Retarget, ent)
			if not ok and not S.retargetErr then S.retargetErr = tostring(err) Say("pose error: " .. S.retargetErr, true) end
		end)
	elseif ply == LocalPlayer() then
		Say("this player model has no ValveBiped skeleton; showing bones only", true)
	end
	models[ply] = e
	if ply == LocalPlayer() then S.skater = e end
	return e
end

S.L.H, S.L.ROCKET_NOZZLE, S.L.ROCKET_Z = H, ROCKET_NOZZLE, ROCKET_Z
include("skategm/cl_board_model.lua")
local DrawBoard = S.L.DrawBoard
S.DrawBoard = DrawBoard

-- Draws one skater: called by the engine when it renders that skater's model
-- (RenderOverride), so it doesn't depend on any shared render hook. (A hook
-- can be silently cut short by another add-on returning a value from it.)
function S.RenderSkater(e)
	local P = e.Sk8P
	if not (P and P.HIPS) then return end
	local ok, err = pcall(function()
		local pc = e.Sk8Ply and e.Sk8Ply.GetPlayerColor and e.Sk8Ply:GetPlayerColor()
		local graphic = pc and Color(math.Clamp(pc.x * 255, 30, 255), math.Clamp(pc.y * 255, 30, 255), math.Clamp(pc.z * 255, 30, 255)) or nil
		local look = BOARD and BOARD.client and IsValid(e.Sk8Ply) and BOARD.client.LookFor(e.Sk8Ply)
		local rocket = (e.Sk8Ply == LocalPlayer() and cvRocket:GetBool()) or (look and look.rocket) or false
		local hover = S.HoverWanted(e.Sk8Ply)
		if not (BOARD and BOARD.client and BOARD.client.Draw(e.Sk8Ply, P, look, graphic, rocket, hover, DrawBoard)) then
			DrawBoard(P, { graphic = graphic, rocket = rocket, trucks = not hover })
		end
		if BOARD and BOARD.client and BOARD.client.DrawEffects then
			BOARD.client.DrawEffects(e.Sk8Ply, P, look, e.Sk8State, RealTime(), FrameNumber and FrameNumber())
		end
		if e.Sk8Rig then
			local frame = FrameNumber and FrameNumber()
			if not frame or e.Sk8PosedFrame ~= frame then
				e.Sk8PosedFrame = frame
				e:InvalidateBoneCache() -- make GMod rebuild (and re-pose) the bones this frame
				e:SetupBones()
			end
			e:DrawModel()
		end
		if cvBones:GetBool() or not e.Sk8Rig then
			render.SetColorMaterial()
			for _, v in pairs(P) do render.DrawSphere(v, 1.2, 6, 6, Color(255, 210, 60)) end
		end
	end)
	if e.Sk8Ply == LocalPlayer() then
		S.drawCount = (S.drawCount or 0) + 1
		pcall(S.MarkerDraw)
		local t = S.debugTris
		if t then
			local bySource = cvShowCol:GetInt() == 2
			local tags = S.debugTags or {}
			for i = 1, #t - 8, 9 do
				local a, b, c = Vector(t[i], t[i + 1], t[i + 2]), Vector(t[i + 3], t[i + 4], t[i + 5]), Vector(t[i + 6], t[i + 7], t[i + 8])
				local col
				if bySource then
					col = SOURCE_COLOURS[tags[(i - 1) / 9 + 1] or 0] or SOURCE_COLOURS[0]
				else
					-- green floors, yellow slopes/ramps, red walls
					local nz = math.abs((b - a):Cross(c - a):GetNormalized().z)
					col = nz > 0.95 and Color(80, 255, 80) or nz > 0.3 and Color(255, 220, 60) or Color(255, 80, 80)
				end
				render.DrawLine(a, b, col, true)
				render.DrawLine(b, c, col, true)
				render.DrawLine(c, a, col, true)
			end
		end
	end
	if not ok and not S.drawErr then S.drawErr = tostring(err) Say("draw error: " .. S.drawErr, true) end
end

S.HOVER = { lift = 7, bob = 1.6, bobRate = 2.3, roll = 5, rollRate = 1.3, pitch = 3, pitchRate = 1.9, blend = 4 }

local function Turn(v, axis, deg)
	local a = math.rad(deg)
	local c, s = math.cos(a), math.sin(a)
	return v * c + axis:Cross(v) * s + axis * (axis:Dot(v) * (1 - c))
end

function S.HoverWanted(ply)
	if ply == LocalPlayer() then
		local cv = GetConVar and GetConVar("skategm_hoverboard")
		return cv ~= nil and cv:GetBool()
	end
	local look = BOARD and BOARD.client and IsValid(ply) and BOARD.client.LookFor(ply)
	return look and look.hover or false
end

function S.HoverPose(e, ply, P, state, now)
	local want = S.HoverWanted(ply) and not OnFoot(state) and not (state and state:find("Wipeout", 1, true))
	local k = e.Sk8HoverK or 0
	local dt = math.min(now - (e.Sk8HoverT or now), 0.1)
	e.Sk8HoverT = now
	k = want and math.min(1, k + dt * S.HOVER.blend) or math.max(0, k - dt * S.HOVER.blend)
	e.Sk8HoverK = k
	local tf, tb = P.TRUCK_FRONT, P.TRUCK_BACK
	if k <= 0 or not (tf and tb) then return P end
	local H = S.HOVER
	local t = now + (IsValid(ply) and ply.EntIndex and ply:EntIndex() or 0) * 1.7
	local pivot = (tf + tb) / 2
	local fwd = Vector(tf.x - tb.x, tf.y - tb.y, 0)
	if fwd:Length() < 1e-3 then fwd = Vector(1, 0, 0) end
	fwd = fwd:GetNormalized()
	local side = Vector(-fwd.y, fwd.x, 0)
	local lift = Vector(0, 0, k * (H.lift + H.bob * math.sin(t * H.bobRate)))
	local roll = k * H.roll * math.sin(t * H.rollRate)
	local pitch = k * H.pitch * math.sin(t * H.pitchRate + 1)
	local out = {}
	for name, v in pairs(P) do
		local d = Turn(Turn(v - pivot, fwd, roll), side, pitch)
		out[name] = pivot + d + lift
	end
	return out
end

local function Show(ply, P, state, stale)
	local e = Skater(ply)
	if not IsValid(e) then return end
	local now = RealTime()
	S.UpdateSound(ply, e, P, state, now, stale)
	P = S.HoverPose(e, ply, P, state, now)
	e.Sk8P = P
	e.Sk8State = state
	e:SetPos(P.HIPS)
	if S.AfterPlace then S.AfterPlace(e) end
	e:SetNoDraw(false)
end

local function Hide(ply)
	local e = models[ply]
	if IsValid(e) then e:SetNoDraw(true) end
	S.StopSounds(ply)
end

-- Hidden skaters: while someone spectates, watches a replay, or has their run
-- replayed (Run Royale), their own skater stands frozen; nobody should see it
-- or bump into it. Reasons are kept apart (S.SetHidden(reason, on)); the
-- server carries "any reason" to everyone (NW2Bool SkateGMHidden).
S.hiddenWhy = S.hiddenWhy or {}
function S.SetHidden(reason, on)
	S.hiddenWhy[reason] = on and true or nil
	local any = next(S.hiddenWhy) ~= nil
	if any ~= (S.hiddenSent or false) then
		S.hiddenSent = any
		if net and net.Start then net.Start("skategm_hidden") net.WriteBool(any) net.SendToServer() end
	end
end
function S.IsHidden(ply)
	if ply == nil or ply == LocalPlayer() then return next(S.hiddenWhy) ~= nil end
	return IsValid(ply) and ply.GetNW2Bool and ply:GetNW2Bool("SkateGMHidden", false) or false
end

-- every frame: hand each skater's newest pose to its model
function S.UpdateSkaters(now, which)
	local me = LocalPlayer()
	if which ~= "remote" then
		if S.phase == "on" and S.P and S.P.HIPS and not S.hideSelf and not S.IsHidden(me) then
			Show(me, S.renderP or S.P, S.renderState or (S.pose and S.pose.state))
		else
			if S.phase == "on" then S.noPoseFrames = (S.noPoseFrames or 0) + 1 end
			Hide(me)
		end
	end
	if which == "local" then return end
	for ply, r in pairs(S.remote) do
		if not IsValid(ply) or now - r.last > 1.5 then
			S.remote[ply] = nil
			S.StopSounds(ply)
			if IsValid(models[ply]) then models[ply]:Remove() end
			models[ply] = nil
		else
			local P, stale = S.RemotePose(r, now)
			if P and P.HIPS and not S.IsHidden(ply) then Show(ply, P, r.state, stale) pcall(S.RemoteWater, ply, P) else Hide(ply) end
		end
	end
end

---------------------------------------------------------------------------
-- Camera and HUD
---------------------------------------------------------------------------
S.CAMERA_DIST_MIN, S.CAMERA_DIST_MAX = 0.5, 2
function S.CameraAdjust(pos, ang, fov, hips)
	local k = math.Clamp(cvCamDist:GetFloat(), S.CAMERA_DIST_MIN, S.CAMERA_DIST_MAX)
	if hips and math.abs(k - 1) > 1e-3 then pos = hips + (pos - hips) * k end
	local f = cvCamFov:GetFloat()
	if f >= 30 then fov = math.Clamp(f, 30, 120) end
	return pos, ang, fov
end
hook.Add("CalcView", "skategm", function(ply, origin, angles, fov)
	if S.phase ~= "on" or not (S.pose and S.pose.pos) then return end
	if S.SampleRender then S.SampleRender() end
	if S.viewOverride then
		local ok, view = pcall(S.viewOverride, origin, angles, fov)
		if ok and view then
			view.drawviewer = false
			return view
		end
	end
	local p = S.pose
	local cameraPose=S.renderCam or p.cam
	if cameraPose then
		local pos = V(cameraPose.pos)
		local scale = S.loadedScale or 1
		local anchor=S.anchor
		local rp=S.renderP
		if rp and rp.RIGHT_WHEELFRONT and rp.LEFT_WHEELFRONT and rp.RIGHT_WHEELBACK and rp.LEFT_WHEELBACK then
			anchor=(rp.RIGHT_WHEELFRONT+rp.LEFT_WHEELFRONT+rp.RIGHT_WHEELBACK+rp.LEFT_WHEELBACK)/4
		end
		if anchor and math.abs(scale - 1) > 1e-3 then pos = anchor + (pos - anchor) * scale end
		local ang = V(cameraPose.fwd):AngleEx(V(cameraPose.up))
		local f = cameraPose.fov or fov
		pos, ang, f = S.CameraAdjust(pos, ang, f, (S.renderP or S.P) and (S.renderP or S.P).HIPS)
		pos,ang=keyboard.Camera(S,pos,ang)
		S.view = { origin = pos, angles = ang }
		return { origin = pos, angles = ang, fov = f, drawviewer = false }
	end
	local target = V(p.pos) + Vector(0, 0, 40)
	return { origin = target - angles:Forward() * 150, angles = angles, fov = fov, drawviewer = false }
end)

hook.Add("PreDrawViewModel", "skategm", function() if S.phase == "on" then return true end end)
hook.Add("ShouldDrawLocalPlayer", "skategm", function() if S.phase == "on" then return false end end)
-- a skating player's own GMod model is never drawn, whatever else turns it
-- back on (respawns, model changes, other add-ons): only their skater shows
function S.IsSkatingPlayer(ply)
	if ply == LocalPlayer() then return S.phase == "on" end
	return (ply.GetNW2Bool and ply:GetNW2Bool("SkateGMSkating", false)) or (S.remote[ply] ~= nil and RealTime() - (S.remote[ply].last or 0) < 1.5)
end
hook.Add("PrePlayerDraw", "skategm", function(ply) if IsValid(ply) and S.IsSkatingPlayer(ply) then return true end end)
-- (weapon selection is hidden in the HUDShouldDraw hook above: a second hook
-- with the same name here used to replace that one, so health was never hidden)

hook.Add("HUDPaint", "skategm", function()
	if S.phase == "loading" then
		draw.SimpleTextOutlined("Loading the skater and map collision...", "DermaLarge", ScrW() / 2, ScrH() * 0.8,
			Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 2, Color(0, 0, 0))
	end
end)

-- leaving the map, dying, or switching models while on the board
hook.Add("ShutDown", "skategm", function() if skategm then skategm.Stop() end end)
gameevent.Listen("entity_killed")
hook.Add("entity_killed", "skategm", function(data)
	local ply = LocalPlayer()
	if IsValid(ply) and data.entindex_killed == ply:EntIndex() and S.phase ~= "off" then S.phase = "off" end
end)


S.L.Native, S.L.Say, S.L.TurnOff = Native, Say, TurnOff
S.KeyboardUses = keyboard.Uses
S.DataPath, S.InstalledDataPath = DataPath, InstalledDataPath
include("skategm/cl_settings.lua")
include("skategm/cl_replay.lua")
include("skategm/cl_infmap.lua")
---------------------------------------------------------------------------
-- Public interface for other add-ons and game modes (e.g. skategm_ots, Own
-- the Spot). They use only this; everything else here may change.
--   API.IsSkating()        true while in Skater mode (engine running)
--   API.IsLoading()        true while Skater mode is starting
--   API.CanSkate()         the module is installed and loaded
--   API.StartSkating()     switch Skater mode on (asynchronous)
--   API.StopSkating()      switch it off
--   API.TeleportTo(pos, yaw)  put your skater there (while skating)
--   API.Score()            points so far: banked lines + current line
--   API.PoseOf(ply)        a skater's bone positions (yours or a remote one)
--   API.State()            the engine's state for your skater ("PhysicsGround",
--                          "PhysicsAir", "GrindFiftyFifty"...), nil when not skating
--   API.Launch(vel)        add a velocity (m/s) to your skater, riding or in the air
--   API.Velocity()         your skater's velocity (map units/s), nil when not skating
--   API.Speed()            your skater's speed in m/s (0 when not skating)
--   API.Say(text, bad)     a chat line in the add-on's style
---------------------------------------------------------------------------
S.API = {
	KeyboardHints = keyboard.IsKeyboard,
	PadType = function() return S.pose and S.pose.padType or nil end,
	version = 1,
	IsSkating = function() return S.phase == "on" end,
	IsLoading = function() return S.phase == "loading" end,
	CanSkate = function() return Native() and true or false end,
	StartSkating = function() if S.phase == "off" then RunConsoleCommand("skategm_toggle") end end,
	StopSkating = function() if S.phase ~= "off" and not S.locked then TurnOff() end end,
	-- the SkateGM gamemode: always skating (Skater mode can't be turned off)
	SetLocked = function(on) S.locked = on and true or nil end,
	IsLocked = function() return S.locked == true end,
	-- why Skater mode last failed to start (nil when it didn't)
	LastError = function() return S.lastError end,
	TeleportTo = function(pos, yaw)
		if S.phase ~= "on" or not skategm then return false end
		skategm.Activate(pos.x, pos.y, pos.z, yaw or 0)
		return true
	end,
	Respawn = function() return S.Respawn() end,
	-- hide my skater from everyone (and from collision) while `reason` holds
	SetHidden = function(reason, on) S.SetHidden(reason, on) end,
	IsHidden = function(ply) return S.IsHidden(ply) end,
	Score = function() return (H.total or 0) + (H.line or 0) end,
	PoseOf = function(ply)
		if ply == LocalPlayer() then return S.phase == "on" and S.P or nil end
		local r = S.remote[ply]
		if r then return (S.RemotePose(r, RealTime())) end
	end,
	Say = function(text, bad) Say(text, bad) end,
	-- a game mode can switch other players' solidity off for a while (a race):
	-- false = off, nil = back to the player's own setting
	SetPlayerCollision = function(on) S.noPlayerCollision = (on == false) or nil end,
	-- where my skater is (its hips), or nil when not skating
	SkaterPos = function() return S.phase == "on" and S.P and S.P.HIPS or nil end,
	State = function() return S.phase == "on" and S.engineState or nil end,
	Freeze = function(on)
		S.frozen = on and true or nil
		if skategm and skategm.SetFrozen then skategm.SetFrozen(on and 1 or 0) end
	end,
	IsFrozen = function() return S.frozen == true end,
	SetTimeScale = function(scale) S.timeScale = (scale and scale ~= 1) and math.Clamp(scale, 0.05, 1) or nil end,
	Tick = function() local p = S.phase == "on" and S.pose return p and p.tick or nil end,
	ScoreInfo = function()
		if S.phase ~= "on" then return nil end
		return { trick = H.trick, trickT = H.trickT, line = H.line or 0, sequence = H.seq or 0, total = H.total or 0, multiplier = H.mult or 1, clean = H.clean }
	end,
	BlockInput = function(on)
		S.inputBlocked = on and true or nil
		S.ApplyInputBlock()
	end,
	Pad = function()
		if not S.inputBlocked and S.InputBlockWanted() then return nil end
		local p = S.phase == "on" and S.pose
		local virtual=keyboard.VirtualPad(S)
		if virtual then return virtual end
		if not p or p.pad == false then return nil end
		return { buttons = p.padButtons or 0, lt = p.padLT or 0, rt = p.padRT or 0, lx = p.padLX or 0, ly = p.padLY or 0, rx = p.padRX or 0, ry = p.padRY or 0 }
	end,
	-- (a mode taking over my camera means I'm watching someone: my skater,
	-- standing still meanwhile, is hidden from everyone)
	SetView = function(fn) S.viewOverride = fn S.SetHidden("view", fn ~= nil) end,
	Skaters = function()
		local list, now = {}, RealTime()
		for ply, r in pairs(S.remote) do
			if IsValid(ply) and ply.IsPlayer and ply:IsPlayer() and now - r.last < 1.5 then list[#list + 1] = ply end
		end
		table.sort(list, function(a, b) return a:Nick():lower() < b:Nick():lower() end)
		return list
	end,
	View = function() return S.view end,
	Velocity = function()
		local v = S.phase == "on" and S.pose and S.pose.vel
		return v and Vector(v[1], v[2], v[3]) or nil
	end,
	Speed = function()
		local v = S.phase == "on" and S.pose and S.pose.vel
		return v and math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3]) * 0.0254 * (S.loadedScale or 1) or 0
	end,
	-- add a velocity to my skater (m/s, world axes), riding or in the air
	-- play a recorded clip ({ { t, P, state }, ... }, as PoseOf gives) as a
	-- ghost that looks like ply; returns its key (PoseOf(key) follows it)
	PlayClip = function(id, ply, clip) return S.PlayClip(id, ply, clip, RealTime()) end,
	StopClip = function(id) S.StopClip(id) end,
	Launch = function(v)
		if S.phase ~= "on" or not (skategm and skategm.Push) then return false end
		local k = 0.0254 * (S.loadedScale or 1)
		return skategm.Push(v.x / k, v.y / k, v.z / k)
	end,
}

S.PLAYER_MODEL_CONVARS = { "cl_playermodel", "cl_playerskin", "cl_playerbodygroups", "cl_playercolor", "cl_weaponcolor" }
function S.PlayerModelChanged()
	if S.phase ~= "on" then return end
	if timer and timer.Create then
		timer.Create("skategm_model", 0.4, 1, function()
			net.Start("skategm_model")
			net.SendToServer()
		end)
	end
end
if cvars and cvars.AddChangeCallback then
	for _, name in ipairs(S.PLAYER_MODEL_CONVARS) do cvars.AddChangeCallback(name, S.PlayerModelChanged, "skategm_model") end
end

function S.MigrateOldSettings()
	if not (file and file.Read and file.Exists) then return 0 end
	if file.Exists("skategm/migrated.txt", "DATA") then return 0 end
	local n = 0
	for _, cfg in ipairs({ "cfg/client.vdf", "cfg/config.cfg" }) do
		local text = file.Read(cfg, "MOD") or ""
		for name, value in text:gmatch('"?sk8_([%w_]+)"?%s+"([^"]*)"') do
			if GetConVar and GetConVar("skategm_" .. name) then
				RunConsoleCommand("skategm_" .. name, value)
				n = n + 1
			end
		end
	end
	if file.CreateDir then
		file.CreateDir("skategm")
		file.CreateDir("skategm/boards")
	end
	if file.Exists("sk8/config.txt", "DATA") and not file.Exists("skategm/config.txt", "DATA") then
		file.Write("skategm/config.txt", file.Read("sk8/config.txt", "DATA"))
		n = n + 1
	end
	for _, f in ipairs(file.Find and file.Find("sk8/boards/*", "DATA") or {}) do
		if not file.Exists("skategm/boards/" .. f, "DATA") then
			file.Write("skategm/boards/" .. f, file.Read("sk8/boards/" .. f, "DATA"))
			n = n + 1
		end
	end
	file.Write("skategm/migrated.txt", tostring(n))
	return n
end

-- the advanced settings file: applied at start (and written the first time)
S.MigrateOldSettings()
S.LoadConfig(true)

function S.SampleRender()
	local frame=FrameNumber()
	if S.renderFrame==frame then return end
	S.renderFrame=frame
	if S.phase~="on" then return end
	S.renderP,S.renderCam,S.renderState=presentation.Sample(renderBuffer,RealTime())
	if S.renderP then S.UpdateSkaters(RealTime(),"local") end
end
hook.Add("PreRender","skategm_interpolated_pose",S.SampleRender)

include("skategm/cl_flickit_hud.lua")
