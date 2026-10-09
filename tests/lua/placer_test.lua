dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end

util = setmetatable({ AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
local sent = {}
net = { Receive = function() end, Start = function(n) sent[#sent + 1] = { name = n } end, WriteString = function(t) sent[#sent].msg = t end, SendToServer = function() end }
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end, Run = function() end }
cvars = { AddChangeCallback = function() end }
function GetConVar() return nil end
function CreateConVar(n, d) return { GetBool = function() return d == "1" end } end
FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY = 1, 2, 4
timer = { Simple = function(_, f) f() end }
local clock = 0
function RealTime() return clock end
function FrameTime() return 0.1 end
local ME = { EntIndex = function() return 1 end, GetPos = function() return Vector(0, 0, 0) end, EyeAngles = function() return Angle(0, 90, 0) end, Nick = function() return "Me" end }
local ANN = { EntIndex = function() return 2 end, Nick = function() return "Ann" end, IsValid = function() return true end }
function LocalPlayer() return ME end
function Entity(i) return ({ [1] = ME, [2] = ANN })[i] end
function IsValid(x) if type(x) == "table" and x.IsValid then return x:IsValid() end return x ~= nil end
MASK_SOLID_BRUSHONLY = 1
local traceHit = Vector(500, 20, 0)
util.TraceLine = function() return { Hit = traceHit ~= nil, HitPos = traceHit } end

local pad = { buttons = 0, lt = 0, rt = 0, lx = 0, ly = 0, rx = 0, ry = 0 }
local api = { blocked = false }
SkateGM = { API = {
	Pad = function() if api.nopad then return nil end return pad end,
	BlockInput = function(on) api.blocked = on end,
	SetView = function(fn) api.view = fn end,
	View = function() return { origin = Vector(0, -100, 80), angles = Angle(10, 90, 0) } end,
	SkaterPos = function() return Vector(10, 20, 0) end,
	CanSkate = function() return true end,
	Say = function() end,
} }

SERVER, CLIENT = nil, true
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
local MENU = SKATEGM_MODES.menu
check("the controller menu is part of the framework", MENU ~= nil and hooks["Think/skategm_ui"] ~= nil)
local B = MENU.BUTTONS

local hosted
local drawn = {}
local mode = SKATEGM_MODES.Register({ id = "placertest", title = "Placer test", order = 5 })
mode:Host({
	useStart = false,
	description = "a test",
	options = {
		{ key = "hoop", label = "Hoop", type = "object", draw = function(obj, alpha) drawn[#drawn + 1] = { obj = obj, alpha = alpha } end,
			scale = { label = "Size", min = 16, max = 96, step = 4, default = 34 },
			lift = { label = "Height", min = 24, max = 160, step = 8, default = 40 } },
		{ key = "flag", label = "Flag", type = "object", rotate = false, draw = function() end },
		{ key = "target", label = "Target", type = "object", rotate = false, draw = function() end,
			scale = { label = "Size", min = 20, max = 200, step = 10, default = 50 },
			sizes = { { key = "zone", label = "No-zone", min = 0, max = 400, step = 16, default = 128 } } },
	},
	start = function(v) hosted = v end,
})
local function press(b, hold)
	pad.buttons = (hold or 0) + b
	clock = clock + 0.05
	hooks["Think/skategm_ui"]()
	pad.buttons = hold or 0
	clock = clock + 0.05
	hooks["Think/skategm_ui"]()
end
press(B.LEFT, B.LB)
press(B.A)
press(B.A)
check("an object option: not placed yet, so the game can't be hosted", MENU.Top().values.hoop == nil and MENU.Missing(mode.hostDef, MENU.Top().values) ~= nil)
press(B.A)
check("A: a free camera with the object following where you look", MENU.fc ~= nil and MENU.fc.obj ~= nil and api.view ~= nil)
check("... at its default size and height, facing you", MENU.fc.obj.scale == 34 and MENU.fc.obj.lift == 40 and MENU.fc.obj.yaw == (90 + 180) % 360)
drawn = {}
hooks["PostDrawTranslucentRenderables/skategm_modes_menu"](false, false)
check("you see it there as you aim (the mode's own drawing)", #drawn == 1 and drawn[1].obj.pos == traceHit and drawn[1].alpha == 1)
press(B.LEFT)
check("D-pad left / right turn it", MENU.fc.obj.yaw == (270 + 15) % 360)
press(B.RIGHT) press(B.RIGHT)
check("... both ways", MENU.fc.obj.yaw == 255)
local fc = MENU.fc
MENU.HoldTurn(fc, { buttons = B.LEFT }, 100, 0.1)
MENU.HoldTurn(fc, { buttons = B.LEFT }, 100.2, 0.1)
check("holding left: a short hold doesn't turn it more", fc.obj.yaw == 255)
MENU.HoldTurn(fc, { buttons = B.LEFT }, 100.5, 0.5)
check("... held on, it turns smoothly", math.abs(fc.obj.yaw - (255 + MENU.TURN_RATE * 0.5)) < 1e-6)
MENU.HoldTurn(fc, { buttons = 0 }, 100.6, 0.1)
MENU.HoldTurn(fc, { buttons = B.RIGHT }, 100.7, 0.5)
check("... let go and hold right: waits again before turning back", math.abs(fc.obj.yaw - (255 + MENU.TURN_RATE * 0.5)) < 1e-6)
fc.obj.yaw = 255
press(B.UP) press(B.UP)
check("D-pad up / down size it", MENU.fc.obj.scale == 42)
for _ = 1, 30 do press(B.UP) end
check("... within its limits", MENU.fc.obj.scale == 96)
press(B.Y) press(B.Y) press(B.X)
check("Y / X raise and lower it", MENU.fc.obj.lift == 48)
traceHit = nil
hooks["Think/skategm_ui"]()
press(B.A)
check("looking at nothing: A doesn't put it down", MENU.fc ~= nil)
traceHit = Vector(500, 20, 0)
hooks["Think/skategm_ui"]()
press(B.A)
local v = MENU.Top().values.hoop
check("A puts it down: where, which way, how big, how high", v and v.pos == traceHit and v.yaw == 255 and v.scale == 96 and v.lift == 48 and MENU.fc == nil)
check("... the row says so", MENU.OptionText(mode.hostDef.options[1], v):find("placed", 1, true) ~= nil)
drawn = {}
hooks["PostDrawTranslucentRenderables/skategm_modes_menu"](false, false)
check("placed objects show in the world while you set the rest up", #drawn == 1 and drawn[1].alpha < 1)
press(B.A)
check("A again: back to it, from where it was", MENU.fc and MENU.fc.obj.scale == 96 and MENU.fc.obj.yaw == 255)
press(B.B)
check("B cancels, keeping it as it was", MENU.fc == nil and MENU.Top().values.hoop.scale == 96)
press(B.DOWN)
press(B.A)
press(B.LEFT)
MENU.HoldTurn(MENU.fc, { buttons = B.LEFT }, 200, 0.1)
MENU.HoldTurn(MENU.fc, { buttons = B.LEFT }, 201, 0.5)
check("an object that doesn't turn: left / right do nothing", MENU.fc.obj.yaw == (90 + 180) % 360)
press(B.A)
press(B.DOWN)
press(B.A)
check("an object with two parts to size: both at their defaults", MENU.fc.obj.scale == 50 and MENU.fc.obj.zone == 128)
press(B.UP)
check("... the D-pad sizes the first", MENU.fc.obj.scale == 60 and MENU.fc.obj.zone == 128)
press(B.RB)
press(B.UP)
press(B.UP)
check("... RB: now it sizes the second", MENU.fc.obj.scale == 60 and MENU.fc.obj.zone == 160)
press(B.A)
local tv = MENU.Top().values.target
check("... and both are kept when it's put down", tv and tv.scale == 60 and tv.zone == 160 and MENU.OptionText(mode.hostDef.options[3], tv):find("no%-zone 160") ~= nil)

-- the Start every mode gets: Here unless the host puts it somewhere
local started
local sm = SKATEGM_MODES.Register({ id = "starttest", title = "Start test", order = 7 })
sm:Host({ options = {}, start = function(v, m) started = v m:Send({ cmd = "create" }) end })
check("every mode's host options begin with Start", sm.hostDef.options[1].key == "_start" and sm.hostDef.options[1].label == "Start")
check("... shown as Here until it's put somewhere", MENU.OptionText(sm.hostDef.options[1], nil) == "Start: Here")
sm.hostDef.start({}, sm)
local m = sent[#sent].msg
check("hosting from Here: the host's spot and facing go with create", started._start.placed == nil and m._start and m._start.pos[1] == 10 and m._start.yaw == 90)
sm.hostDef.start({ _start = { pos = Vector(300, 40, 5), yaw = 270 } }, sm)
m = sent[#sent].msg
check("placed: that spot, the arrow's way (the marker faced the host: turned round)", m._start.pos[1] == 300 and m._start.yaw == 90)
local pm = SKATEGM_MODES.Register({ id = "spottest", title = "Spot test", order = 8 })
pm:Host({ options = {}, start = function(v, mm) mm:Send({ cmd = "create", pos = { 1, 2, 3 }, yaw = 5 }) end })
pm.hostDef.start({ _start = { pos = Vector(300, 40, 5), yaw = 0 } }, pm)
m = sent[#sent].msg
check("a mode that sends its own spot gets the Start in its place", m.pos[1] == 300 and m.yaw == 180)
check("a mode can do without it", mode.hostDef.options[1].key ~= "_start")

local rm = SKATEGM_MODES.Register({ id = "regiontest", title = "Region test", order = 8 })
rm:Host({ options = { { key = "area", label = "Play area", type = "region", min = 512, max = 2048, step = 128, default = 1024 } }, start = function() end })
local rscreen = MENU.OptionsScreen(rm)
check("a mode with a play area starts at its default size", rscreen.values.area == 1024)
MENU.StartFreecam(rscreen, rm.hostDef.options[1])
check("placing the Start: the D-pad sizes the play area", MENU.fc.obj.area == 1024 and MENU.SizeParts(MENU.fc.option)[1].key == "area")
MENU.ObjectInput(MENU.fc, B.UP)
MENU.ObjectInput(MENU.fc, B.UP)
check("... up grows it, live (the ring follows)", MENU.fc.obj.area == 1280)
local legend = MENU.ObjectLegend(MENU.fc)
local shown = false
for _, r in ipairs(legend) do if r.text:find("Play area: 2560 across", 1, true) then shown = true end end
check("... the hint says what it's sizing", shown)
MENU.fc.target = Vector(50, 60, 0)
MENU.ObjectInput(MENU.fc, B.A)
check("A: the play area is kept as the mode's own setting, the Start just a spot", rscreen.values.area == 1280 and rscreen.values._start and rscreen.values._start.area == nil and rscreen.values._start.pos.x == 50)
MENU.StartFreecam(rscreen, rm.hostDef.options[1])
check("placing it again starts from that size", MENU.fc.obj.area == 1280)
MENU.ObjectInput(MENU.fc, B.DOWN)
MENU.ObjectInput(MENU.fc, B.B)
check("B cancels, the size as it was", rscreen.values.area == 1280 and MENU.fc == nil)
