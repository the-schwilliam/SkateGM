dofile("gmock.lua")
local receivers, reads, netSent = {}, {}, {}
net = setmetatable({ Receive = function(n, f) receivers[n] = f end, ReadFloat = function() return table.remove(reads, 1) end,
	Start = function(n) netSent[#netSent + 1] = n end }, { __index = function() return function() end end })
concommand = { Add = function() end }
local clock = 0
function RealTime() return clock end
function FrameTime() return 1 / 60 end
function ScrW() return 1920 end
function ScrH() return 1080 end
function IsValid(x) if type(x) == "table" and x.IsValid then return x:IsValid() end return x ~= nil end
function CreateClientConVar(n, d) return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetInt = function() return 0 end, GetString = function() return d end } end
MsgC = function() end chat = { AddText = function() end } function LocalPlayer() return {} end
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
CONTENTS_WATER, MASK_WATER = 32, 16432
local effects, sounds, ui = {}, {}, {}
util = { PointContents = function(p) return p.z < 0 and CONTENTS_WATER or 0 end,
	TraceLine = function(t) return { Hit = true, HitPos = Vector(t.start.x, t.start.y, 0) } end,
	Effect = function(name, fx) effects[#effects + 1] = name end }
function EffectData() return { SetOrigin = function() end, SetScale = function() end } end
sound = { Play = function(s) sounds[#sounds + 1] = s end }
surface = setmetatable({ PlaySound = function(s) ui[#ui + 1] = s end }, { __index = function() return function() end end })
local keys = {}
input = { IsKeyDown = function(k) return keys[k] or false end, IsMouseDown = function() return false end }
KEY_W, KEY_S, KEY_Q, KEY_E, KEY_SPACE, KEY_A, KEY_D, KEY_UP, KEY_DOWN, KEY_LCONTROL, KEY_R, KEY_F = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
local calls = { checkpoint = 0, activate = {} }
local checkpointOK = true
skategm = { ReturnToCheckpoint = function() calls.checkpoint = calls.checkpoint + 1 return checkpointOK end,
	Activate = function(x, y, z, yaw) calls.activate[#calls.activate + 1] = Vector(x, y, z) end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
local W = S.WATER

-- ride on dry ground for 3 s, then go off the edge into the water (z < 0)
local function frame(z, state) clock = clock + 1 / 60 S.anchor = Vector(0, 0, z) S.WaterThink({ HIPS = Vector(0, 0, z + 36) }, state or "PhysicsGround", clock) end
for _ = 1, 180 do frame(10) end
for _ = 1, 20 do frame(-5, "PhysicsAir") end
print("splash on entering water (effect + sound):", effects[1] == "watersplash" and sounds[1] and sounds[1]:find("water_splash") and "OK" or "<-- WRONG")
local maxFade = 0
for _ = 1, 30 do frame(-20, "PhysicsAir") maxFade = math.max(maxFade, W.fade) end
print("screen fades to dark:", maxFade >= 0.99 and "OK" or "<-- WRONG " .. maxFade)
print("then back to Skate 3's checkpoint (once):", calls.checkpoint == 1 and "OK" or "<-- WRONG " .. calls.checkpoint)
for _ = 1, 90 do frame(10) end -- the engine put us back on dry ground
print("fades back in and is ready again:", W.state == "dry" and W.fade == 0 and #calls.activate == 0 and "OK" or "<-- WRONG " .. W.state)
-- if the engine can't return, a recent dry spot is used instead
checkpointOK = false
for _ = 1, 20 do frame(-5, "PhysicsAir") end
for _ = 1, 120 do frame(-20, "PhysicsAir") end
print("fallback to a recent dry spot:", #calls.activate == 1 and calls.activate[1].z >= 0 and "OK" or "<-- WRONG")

-- markers
S.H.events = {}
S.MarkerUpdate({ active = true, canPlace = true, canReturn = false, progress = 0 }, clock)
S.MarkerUpdate({ active = true, canPlace = true, canReturn = true, progress = 0, pos = { 100, 50, 10 } }, clock)
print("marker set: call-out + sound:", S.H.events[1] and S.H.events[1].text == "MARKER SET" and ui[#ui]:find("button9") and "OK" or "<-- WRONG")
-- (keyboard marker keys are gone: controller only)
S.MarkerUpdate({ active = true, canPlace = false, canReturn = true, progress = 0.8, pos = { 100, 50, 10 } }, clock)
S.MarkerUpdate({ active = false, canPlace = false, canReturn = true, progress = 0, pos = { 100, 50, 10 } }, clock, Vector(100, 50, 40))
print("return to marker: sound:", ui[#ui]:find("blip1") and "OK" or "<-- WRONG")

-- the marker display: a D-pad with the actions at their directions
local texts, rects = {}, 0
draw = draw or {}
local realSimple = draw.SimpleText
local at = {}
draw.SimpleText = function(t, font, x, y, col, ax, ay) texts[#texts + 1] = tostring(t) at[tostring(t)] = { x = x, y = y, ax = ax, ay = ay } end
draw.SimpleTextOutlined = function(t) texts[#texts + 1] = tostring(t) end
surface = surface or {}
surface.SetDrawColor = surface.SetDrawColor or function() end
local realRect = surface.DrawRect
surface.DrawRect = function() rects = rects + 1 end
S.MarkerUpdate({ active = true, canPlace = true, canReturn = true, progress = 0.4, pos = { 100, 50, 10 } }, clock)
local hadModes = SKATEGM_MODES
SKATEGM_MODES = { menu = {} }
S.MarkerPaint(1920, 1080)
SKATEGM_MODES = hadModes
local all = table.concat(texts, "|")
local cx, cy, u = 960, 1080 * 0.82, math.floor(1080 * 0.018)
local up, down, left, right = at["return to marker (hold)"], at["set marker"], at["minigames"], at["players"]
print("marker display: a D-pad, every action beyond its own arm:", up and down and left and right and rects >= 5
	and up.x == cx and up.y < cy - u * 1.5 and up.ay == TEXT_ALIGN_BOTTOM
	and down.x == cx and down.y > cy + u * 1.5 and down.ay == TEXT_ALIGN_TOP
	and left.x < cx - u * 1.5 and left.y == cy and left.ax == TEXT_ALIGN_RIGHT
	and right.x > cx + u * 1.5 and right.y == cy and right.ax == TEXT_ALIGN_LEFT and "OK" or ("<-- WRONG " .. all))
print("... with no \"LB +\" on it:", not all:find("LB", 1, true) and "OK" or "<-- WRONG")
local api = SkateGM.API
local hadHints = api.KeyboardHints
api.KeyboardHints = function() return true end
texts, at = {}, {}
SKATEGM_MODES = { menu = {} }
S.MarkerPaint(1920, 1080)
SKATEGM_MODES = hadModes
api.KeyboardHints = hadHints
local ki, kk, ku, ko = at["I"], at["K"], at["U"], at["O"]
print("keyboard: I / K / U / O written on the D-pad's arms", ki and kk and ku and ko and ki.x == cx and ki.y < cy and kk.x == cx and kk.y > cy
	and ku.x < cx and ku.y == cy and ko.x > cx and ko.y == cy and "OK" or ("<-- WRONG " .. table.concat(texts, "|")))
texts, at = {}, {}
-- the combos list themselves (each screen registers its own, with a label)
local UI = SKATEGM_UI
local PB = UI.pad.B
local editorAllowed = true
UI.Combo(PB.X, { open = function() end, label = "respawn" })
UI.Combo(PB.B, { open = function() end, label = "park editor", allowed = function() return editorAllowed end })
UI.Combo(PB.Y, { open = function() end, label = "map" })
UI.Combo(PB.A, { open = function() end, label = "settings" })
UI.Combo(PB.RB, { open = function() end, label = "replay" })
texts, at = {}, {}
S.MarkerPaint(1920, 1080)
print("... the LB combos in a column on the right: RB replay, X respawn, B park editor, Y map, A settings",
	at["replay"] and at["respawn"] and at["park editor"] and at["map"] and at["settings"] and at["respawn"].x > cx + u * 5
	and at["replay"].y < at["respawn"].y and at["respawn"].y < at["park editor"].y and at["park editor"].y < at["map"].y and at["map"].y < at["settings"].y and "OK" or "<-- WRONG")
editorAllowed = false
texts, at = {}, {}
S.MarkerPaint(1920, 1080)
print("... one that isn't allowed here isn't listed", not at["park editor"] and at["map"] and "OK" or "<-- WRONG")
texts = {}
S.inputBlocked = true
S.MarkerPaint(1920, 1080)
print("... hidden while a menu or the park editor has the controller:", #texts == 0 and "OK" or "<-- WRONG")
S.inputBlocked = nil
-- no markers while a minigame is played: the module keeps LB + D-pad from the engine
local markerCalls = {}
skategm.SetMarkerBlocked = function(on) markerCalls[#markerCalls + 1] = on end
SKATEGM_MODES = { Playing = function() return true end }
S.ApplyMarkerBlock()
S.ApplyMarkerBlock()
texts, at = {}, {}
S.MarkerPaint(1920, 1080)
print("in a minigame: the module blocks the marker, once:", #markerCalls == 1 and markerCalls[1] == 1 and "OK" or "<-- WRONG")
print("... and the D-pad says so instead of set / return:", at["no markers in a minigame"] and not at["set marker"] and not at["return to marker (hold)"] and "OK" or "<-- WRONG")
SKATEGM_MODES = { Playing = function() return false end }
S.ApplyMarkerBlock()
print("... back when it ends:", markerCalls[2] == 0 and "OK" or "<-- WRONG")
SKATEGM_MODES = hadModes
texts = {}
S.noPad = true
S.MarkerPaint(1920, 1080)
print("no controller: says so:", table.concat(texts, "|"):find("No controller found", 1, true) and "OK" or "<-- WRONG")
print("... and how to skate with the keyboard instead:", table.concat(texts, "|"):find("skate with the keyboard", 1, true) and "OK" or "<-- WRONG")
print("... and that PlayStation and other pads work too:", table.concat(texts, "|"):find("PlayStation", 1, true) and "OK" or "<-- WRONG")
texts = {}
S.padName = "none usable (not recognised as a gamepad: Redragon Harrow)"
S.MarkerPaint(1920, 1080)
print("... a pad it can't use: named, with where its mapping goes:", table.concat(texts, "|"):find("Redragon Harrow: add its mapping", 1, true) and "OK" or "<-- WRONG")
S.padName = nil
S.noPad = false
draw.SimpleText, surface.DrawRect = realSimple, realRect

-- a skating player's GMod model never draws
do
	local draw = hooks["PrePlayerDraw/skategm"]
	local other = { GetNW2Bool = function(_, k) return k == "SkateGMSkating" end, IsValid = function() return true end }
	local walker = { GetNW2Bool = function() return false end, IsValid = function() return true end }
	print("a skating player's own model is hidden, a walking one's isn't:", draw and draw(other) == true and draw(walker) == nil and "OK" or "<-- WRONG")
end

-- riding, for the rocket and the rest: powerslides and reverts count too
print("on the board: rolling, powersliding, reverting, in the air; not on foot or bailing:",
	S.OnBoard("PhysicsGround") and S.OnBoard("SlideGround") and S.OnBoard("RevertGround") and S.OnBoard("PhysicsAir")
	and not S.OnBoard("BipedGround") and not S.OnBoard("WipeoutGround") and not S.OnBoard("GrindFiftyFifty") and "OK" or "<-- WRONG")

-- the SkateGM gamemode: Skater mode can't be switched off
do
	local was = S.phase
	S.phase = "on"
	S.API.SetLocked(true)
	S.API.StopSkating()
	print("locked (the SkateGM gamemode): minigames can't switch Skater mode off:", S.phase == "on" and S.API.IsLocked() and "OK" or "<-- WRONG")
	S.API.SetLocked(false)
	S.phase = was
end

-- binds while skating
S.phase = "on"
local bind = hooks["PlayerBindPress/skategm"]
print("flashlight / reload blocked, chat + toggle + console kept:",
	bind(nil, "impulse 100", true) == true and bind(nil, "+reload", true) == true and bind(nil, "messagemode", true) == nil
	and bind(nil, "skategm_toggle", true) == nil and bind(nil, "toggleconsole", true) == nil and "OK" or "<-- WRONG")
S.phase = "off"
print("binds untouched when not skating:", bind(nil, "impulse 100", true) == nil and "OK" or "<-- WRONG")

-- LB + X: ask the server, go where it says
S.phase = "on"
S.Respawn()
print("respawn asks the server:", netSent[#netSent] == "skategm_respawn" and "OK" or "<-- WRONG")
local before = #calls.activate
reads = { -500, 300, 64, 90 }
receivers.skategm_respawn()
local got = calls.activate[#calls.activate]
print("... and puts my skater at the spawn it sends:", #calls.activate == before + 1 and got.x == -500 and got.y == 300 and got.z == 64 and "OK" or "<-- WRONG")
S.phase = "off"

-- hidden skaters (spectating, replays): mine everywhere, others' by their flag
local sends = 0
local realStart = net.Start
net.Start = function(n) if n == "skategm_hidden" then sends = sends + 1 end netSent[#netSent + 1] = n end
S.SetHidden("spectate", true)
S.SetHidden("replay", true)
print("hiding: told to the server once:", sends == 1 and S.IsHidden() and "OK" or "<-- WRONG")
S.SetHidden("spectate", false)
print("... still hidden while any reason holds:", sends == 1 and S.IsHidden() and "OK" or "<-- WRONG")
S.SetHidden("replay", false)
print("... and shown again (told once more):", sends == 2 and not S.IsHidden() and "OK" or "<-- WRONG")
local other = { IsValid = function() return true end, GetNW2Bool = function(_, k) return k == "SkateGMHidden" end }
print("another player's flag hides them:", S.IsHidden(other) and "OK" or "<-- WRONG")
net.Start = realStart
