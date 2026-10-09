dofile("gmock.lua")
util = setmetatable({ TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
net = { Start = function() end, WriteString = function() end, SendToServer = function() end, Receive = function() end }
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
concommand = { Add = function() end }
function IsValid(x) return x ~= nil end
chat = { AddText = function() end }
local ME = { EntIndex = function() return 2 end }
function LocalPlayer() return ME end
local api = { teleports = {} }
SkateGM = { API = {
	IsSkating = function() return true end, IsLoading = function() return false end, CanSkate = function() return true end,
	StartSkating = function() end, TeleportTo = function(p, y) api.teleports[#api.teleports + 1] = { p, y } return true end,
	PoseOf = function() return { HIPS = Vector(900, 900, 40) } end, Tick = function() return 1 end, State = function() return "PhysicsGround" end,
	Freeze = function() end, BlockInput = function() end, Say = function() end,
} }
local feeds = {}
HOM = { PART = {}, LEVELS = {}, NewTracker = function() return { Feed = function() return table.remove(feeds, 1) or {} end } end }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_bodybingo/sh_bodybingo.lua")
dofile("../../addon/skategm/lua/skategm_bodybingo/cl_bodybingo.lua")
local BBc = BODYBINGO and BODYBINGO.client or BB.client
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local st = { phase = "playing", start = { 100, 200, 10 }, yaw = 90, pain = 1, players = { { ent = 1, name = "Ann" }, { ent = 2, name = "Me" } } }
BBc.OnState({ phase = "countdown", start = st.start, yaw = 90, players = st.players }, 0)
BBc.OnState(st, 1)
api.teleports = {}
BBc.Think(2)
check("skating about: left where I am", #api.teleports == 0)
feeds[1] = { { kind = "done" } }
BBc.Think(3)
local t = api.teleports[1]
check("a bail over: back to my place at the start, facing the start's way", t ~= nil and t[2] == 90 and math.abs(t[1].x - 100) < 200 and math.abs(t[1].y - 200) < 200)
