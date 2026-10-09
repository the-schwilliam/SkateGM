dofile("gmock.lua")
local sent, receivers = {}, {}
util = setmetatable({ TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
local reading = {}
net = { Start = function() end, WriteString = function(t) sent[#sent + 1] = t end, SendToServer = function() end,
	Receive = function(n, f) receivers[n] = f end, ReadBool = function() return table.remove(reading, 1) end, ReadUInt = function() return table.remove(reading, 1) end }
hook = { Add = function() end }
concommand = { Add = function() end }
function IsValid(x) return x ~= nil end
local said = {}
chat = { AddText = function(...) local t = { ... } said[#said + 1] = t[#t] end }
local ME = { EntIndex = function() return 2 end, GetPos = function() return Vector(0, 0, 0) end, EyeAngles = function() return { y = 0 } end, Nick = function() return "Me" end }
function LocalPlayer() return ME end
function Entity() return nil end
local api = { skating = true, info = { total = 1000, line = 0 }, state = "PhysicsGround", pad = 0, frozen = nil, blocked = nil }
SkateGM = { API = {
	IsSkating = function() return api.skating end, IsLoading = function() return false end, CanSkate = function() return true end,
	StartSkating = function() end, TeleportTo = function() return true end, Freeze = function(on) api.frozen = on end,
	BlockInput = function(on) api.blocked = on end, SetHidden = function() end, SetView = function(fn) api.view = fn end,
	IsLocked = function() return true end, ScoreInfo = function() return api.info end, State = function() return api.state end,
	Pad = function() return { buttons = api.pad } end, PoseOf = function() return nil end,
	Say = function(t) said[#said + 1] = t end,
} }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
if not SKATEGM_MODES.spectate then dofile("../../addon/skategm/lua/skategm_modes/cl_spectate.lua") end
dofile("../../addon/skategm/lua/skategm_copycat/sh_copycat.lua")
dofile("../../addon/skategm/lua/skategm_copycat/cl_copycat.lua")
local CC = COPYCAT
local C = CC.client
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local played, hidden = {}, nil
SkateGM.API.PlayClip = function(id, ply, clip, opts) played[id] = { ply = ply, clip = clip, opts = opts } return { id = id } end
SkateGM.API.StopClip = function(id) played[id] = nil end
SkateGM.API.HideOthers = function(on) hidden = on end
SkateGM.API.PoseOf = function() return { HIPS = Vector(0, 0, 0) } end
local ANN = { EntIndex = function() return 1 end, Nick = function() return "Ann" end }
function Entity(i) return i == 1 and ANN or nil end
local players = { { ent = 1, name = "Ann", playing = true }, { ent = 2, name = "Me", playing = true } }
local function state(t) t.players = players t.start = { 0, 0, 0 } t.yaw = 0 t.runTime = 5 C.OnState(t, 0) end
state({ phase = "leadcount", leader = 1, copiers = { 2 } })
local nocollide
SkateGM.API.SetPlayerCollision = function(on) nocollide = on == false end
state({ phase = "leadcount", leader = 1, copiers = { 2 } })
check("Ann sets the line: I watch her live", CC.mode.spectating ~= nil and CC.mode.spectating[1] == 1)
check("... everyone else out of sight (only who I watch is drawn), nobody collides", hidden == true and nocollide == true)
state({ phase = "lead", leader = 1, copiers = { 2 } })
C.Think(1) C.Think(1.2) C.Think(1.4)
check("... and record it here", #C.clips[1] >= 2)
state({ phase = "copycount", leader = 1, copiers = { 2 } })
check("my copy: I stop watching, the others are hidden", CC.mode.spectating == nil and hidden == true)
state({ phase = "copy", leader = 1, copiers = { 2 } })
C.Think(2) C.Think(2.2) C.Think(2.4)
state({ phase = "replay", leader = 1, copiers = { 2 }, replay = { index = 1, total = 1, ent = 2 }, paths = { lead = {}, copy = {} } })
check("the replay: my copy, and Ann's line beside it with her name tag",
	played.copycat_copy and played.copycat_copy.ply == ME and played.copycat_copy.opts == nil
	and played.copycat_lead and played.copycat_lead.ply == ANN and played.copycat_lead.opts.nametag == ANN:Nick())
check("... nobody hidden any more", hidden == false)
state({ phase = "score", leader = 1, copiers = { 2 }, replay = { index = 1, total = 1, ent = 2 }, last = { ent = 2, name = "Me", points = 80 } })
state({ phase = "leadcount", leader = 2, copiers = { 1 } })
check("after the score: the replay ghosts are gone", played.copycat_copy == nil and played.copycat_lead == nil)
check("my turn to set it: nothing to watch", CC.mode.spectating == nil)
state({ phase = "copy", leader = 2, copiers = { 1 } })
check("they copy me: I watch them", CC.mode.spectating ~= nil and CC.mode.spectating[1] == 1)
state({ phase = "replay", leader = 2, copiers = { 1 }, replay = { index = 1, total = 1, ent = 1 }, paths = { lead = {}, copy = {} } })
state({ phase = "score", leader = 2, copiers = { 1 }, replay = { index = 1, total = 1, ent = 1 }, last = { ent = 1, name = "Ann", points = 60 } })
state({ phase = "leadcount", leader = 1, copiers = { 2 } })
check("the replays over, Ann sets the next line: my camera follows her (the replay's end doesn't take it)", CC.mode.spectating ~= nil and api.view ~= nil and SKATEGM_MODES.spectate.on)
