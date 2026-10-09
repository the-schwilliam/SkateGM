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

local store = {}
file = { Read = function(p) return store[p] end, Write = function(p, t) store[p] = t end, CreateDir = function() end }
local map = "sgm_warehouse"
game = { GetMap = function() return map end }
local typed
function Derma_StringRequest(title, text, default, ok, cancel) if typed then ok(typed) else cancel() end end
SERVER, CLIENT = nil, true
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
local MENU = SKATEGM_MODES.menu
local B = MENU.BUTTONS
local mode = SKATEGM_MODES.Register({ id = "presettest", title = "Preset test", order = 5 })
mode:Host({
	useStart = false,
	description = "a test",
	options = {
		{ key = "target", label = "Target", type = "object", rotate = false, draw = function() end, scale = { label = "Size", min = 20, max = 200, step = 10, default = 50 } },
		{ key = "rounds", label = "Rounds", type = "number", min = 1, max = 9, step = 1, default = 3 },
		{ key = "_rocket", label = "Rocket board", type = "bool", default = false },
	},
	start = function() end,
})
local screen = MENU.OptionsScreen(mode)
screen.values.target = { pos = Vector(100, 200, 0), yaw = 0, scale = 80 }
screen.values.rounds, screen.values._rocket = 7, true
typed = "Big ramp line"
screen.actions[B.X]()
local saved = MENU.Presets(mode)["Big ramp line"]
check("X: saved under the typed name, for this map", saved ~= nil and saved.values.rounds == 7 and saved.values._rocket == true and saved.values.target.scale == 80)
typed = nil
screen.actions[B.X]()
check("... cancelling the name saves nothing", next(MENU.Presets(mode), next(MENU.Presets(mode))) == nil)
local fresh = MENU.OptionsScreen(mode)
local rows = fresh.rows()
local load = rows[#rows - 1]
check("the host settings list Load a preset, just above Host it", load.label == "Load a preset" and load.page ~= nil and rows[#rows].label == "Host it")
local list = load.page()
list.screen = fresh
MENU.stack = { fresh, list }
local prow = list.rows()[1]
check("... it lists this minigame's presets on this map", prow.label == "Big ramp line")
prow.run()
check("... A loads it: start, target, rounds and switches back", fresh.values.rounds == 7 and fresh.values._rocket == true and fresh.values.target.pos.x == 100)
map = "gm_construct"
check("another map: its own presets (none)", next(MENU.Presets(mode)) == nil)
map = "sgm_warehouse"
prow.actions[B.X]()
check("X on a preset deletes it", MENU.Presets(mode)["Big ramp line"] == nil)
