dofile("gmock.lua")
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
function IsValid(x) return x ~= nil and (type(x) ~= "table" or not x.IsValid or x:IsValid()) end
function ScrW() return 1600 end
function ScrH() return 900 end
local clock = 0
RealTime = function() return clock end
MASK_SOLID_BRUSHONLY = 16395

-- the floor at z 0, a roof at z 300 over x < 0
util.TraceLine = function(t)
	local x = t.start.x
	local z = (x < 0 and t.start.z > 300) and 300 or 0
	return { Hit = true, HitPos = Vector(t.start.x, t.start.y, z), HitNormal = Vector(0, 0, 1) }
end

local pad = { buttons = 0, lx = 0, ly = 0, rx = 0, ry = 0, lt = 0, rt = 0 }
local api = {}
SkateGM = { API = {
	Pad = function() return pad end,
	SkaterPos = function() return Vector(100, 200, 10) end,
	Freeze = function(on) api.frozen = on end,
	BlockInput = function(on) api.blocked = on end,
	SetView = function(fn) api.view = fn end,
	TeleportTo = function(p, yaw) api.tele = { p, yaw } return true end,
	View = function() return { angles = Angle(0, 45, 0) } end,
	Skaters = function() return {} end,
} }
SKATEGM_MODES = { menu = {}, MyGame = function() return nil end, InPlay = function(st) return st ~= nil and st.phase == "playing" end }
function SKATEGM_MODES.Playing() return SKATEGM_MODES.InPlay(select(2, SKATEGM_MODES.MyGame())) end
function LocalPlayer() return { GetPos = function() return Vector() end } end

CLIENT = true
dofile("../../addon/skategm/lua/skategm_ui/cl_pad.lua")
dofile("../../addon/skategm/lua/skategm_ui/cl_map.lua")
local UI = SKATEGM_UI
local MAP, B = UI.map, UI.pad.B

local now = 0
local function frame(buttons, dt)
	pad.buttons = buttons or 0
	now = now + (dt or 0.05)
	clock = now
	UI.Think(now, dt or 0.05)
end
local function press(b) frame(b) frame(0) end

frame(B.LB)
frame(bit.bor(B.LB, B.Y))
frame(0)
check("LB + Y opens the map", MAP.Active() and api.frozen == true and api.blocked == true and type(api.view) == "function")
local v = api.view(nil, nil, 90)
check("... looking straight down, orthographic, from the cut above me", v.angles.p == 90 and v.ortho and v.origin.x == 100 and v.origin.y == 200 and v.origin.z == 10 + MAP.CUT_ABOVE)
check("... the dot finds the floor under it", MAP.target and MAP.target.z == 0)

pad.ly = 1
frame(0, 0.5)
pad.ly = 0
check("left stick up pans north (+y)", MAP.centre.y > 200 and MAP.centre.x == 100)
local z0 = MAP.zoom
pad.lt = 1
frame(0, 0.5)
pad.lt = 0
check("LT zooms out", MAP.zoom > z0)

MAP.centre = Vector(-500, 0, 0)
MAP.cut = 1000
frame(0)
check("over a roof, from above the roof: the dot is on the roof", MAP.target and MAP.target.z == 300)
press(B.DOWN)
press(B.DOWN)
press(B.DOWN)
press(B.DOWN)
press(B.DOWN)
press(B.DOWN)
frame(0)
check("D-pad down lowers the cut under the roof: the dot finds the floor inside", MAP.cut < 300 and MAP.target and MAP.target.z == 0)

SKATEGM_MODES.MyGame = function() return {}, { phase = "playing" } end
press(B.A)
check("in a minigame: no teleporting", MAP.Active() and api.tele == nil and MAP.note ~= nil)
SKATEGM_MODES.MyGame = function() return nil end
press(B.A)
check("A teleports to the dot, facing the way I was, and closes the map", api.tele and api.tele[1].x == -500 and api.tele[1].z > 0 and api.tele[2] == 45 and not MAP.Active() and api.frozen == false and api.view == nil)

frame(B.LB)
frame(bit.bor(B.LB, B.Y))
frame(0)
press(B.B)
check("B goes back without moving", not MAP.Active() and api.blocked == false)

UI.Take("minigames", {})
frame(B.LB)
frame(bit.bor(B.LB, B.Y))
frame(0)
check("not over another screen (the minigame menu)", not MAP.Active() and UI.IsOpen("minigames"))
UI.Give("minigames")

local mapName = "gm_construct"
game = { GetMap = function() return mapName end }
local globals = {}
function GetGlobal2String(k, d) return globals[k] or d end
check("an ordinary map: the screen says Map", MAP.Title() == "Map")
mapName = "sgm_skate3_maloof"
globals.SkateGMTitle = "Maloof Money Cup"
check("a Skate 3 map names its place (from the map's own info entity, via the server)", MAP.Title() == "Skate 3: Maloof Money Cup")
