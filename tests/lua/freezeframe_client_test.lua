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
local ME = { EntIndex = function() return 2 end, GetPos = function() return Vector(0, 0, 0) end, EyeAngles = function() return { y = 0 } end }
function LocalPlayer() return ME end
function Entity() return nil end
local api = { skating = true, info = { total = 1000, line = 0 }, state = "PhysicsGround", pad = 0, frozen = nil, blocked = nil }
SkateGM = { API = {
	IsSkating = function() return api.skating end, IsLoading = function() return false end, CanSkate = function() return true end,
	StartSkating = function() end, TeleportTo = function() return true end, Freeze = function(on, why) api.holds = api.holds or {} api.holds[why or ""] = on or nil api.frozen = next(api.holds) ~= nil end,
	BlockInput = function(on) api.blocked = on end, SetHidden = function() end, SetView = function() end,
	IsLocked = function() return true end, ScoreInfo = function() return api.info end, State = function() return api.state end,
	Pad = function() return { buttons = api.pad } end, PoseOf = function() return nil end,
	Say = function(t) said[#said + 1] = t end,
} }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_freezeframe/sh_freezeframe.lua")
dofile("../../addon/skategm/lua/skategm_freezeframe/cl_freezeframe.lua")
RealTime = RealTime or function() return 0 end
local FF = FREEZEFRAME
local C = FF.client
local UI = SKATEGM_UI
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local played, view, mask = {}, nil, 0
SkateGM.API.PlayClip = function(id, ply, clip, opts) played[id] = { ply = ply, clip = clip } return {} end
SkateGM.API.StopClip = function(id) played[id] = nil end
SkateGM.API.SetView = function(f) view = f end
SkateGM.API.SetButtonMask = function(b) mask = b end
SkateGM.API.HideOthers = function() end
SkateGM.API.PoseOf = function() return { HIPS = Vector(100, 0, 40), HEAD = Vector(100, 0, 70) } end
SkateGM.view = { origin = Vector(0, 0, 60), angles = Angle(0, 0, 0) }
function EyeAngles() return Angle(0, 0, 0) end
local BOB = { EntIndex = function() return 1 end }
function Entity(i) return i == 1 and BOB or nil end
local players = { { ent = 1, name = "Bob", alive = true, playing = true }, { ent = 2, name = "Me", alive = true, playing = true }, { ent = 3, name = "Cat", playing = true } }
local function state(t, at) t.players = players C.OnState(t, at or 0) end
local function lastSent() return sent[#sent] end
state({ phase = "shoot", timeLeft = 30, round = 1 })
check("shooting: left stick in is kept from the engine", mask == FF.BUTTON)
UI.InMinigame = function() return true end
api.pad = 0x0040
C.Think(1)
check("left stick in: frozen, the photo camera open where the view was", api.frozen == true and C.shot ~= nil and UI.IsOpen("freezeframe") and C.shot.cam.pos.z == 60)
local v = view and view()
check("... I see through it", v and v.origin == C.shot.cam.pos and v.fov == FF.FOV_DEFAULT)
UI.screen.press(UI.pad.B.B)
check("B unfreezes: back to skating, nothing sent", api.frozen == false and C.shot == nil and not UI.IsOpen("freezeframe") and lastSent() == nil)
api.pad = 0
C.Think(1.1)
api.pad = 0x0040
C.Think(1.2)
check("... and left stick in freezes again", C.shot ~= nil and UI.IsOpen("freezeframe"))
UI.screen.press(UI.pad.B.UP)
UI.screen.press(UI.pad.B.RIGHT)
check("D-pad up zooms in, right picks the next filter", C.shot.fov == FF.FOV_DEFAULT - C.FOV_STEP and FF.FILTERS[C.shot.filter] == "bw")
UI.screen.press(UI.pad.B.A)
local m = lastSent()
check("A takes it: my skeleton, the camera, the filter sent", m.cmd == "photo" and m.pose.HIPS[1] == 100 and m.cam.fov == FF.FOV_DEFAULT - C.FOV_STEP and m.filter == "bw")
local n = #sent
UI.screen.press(UI.pad.B.A)
check("... once", #sent == n)
local photos = {
	{ ent = 1, name = "Bob", pose = { HIPS = { 5, 0, 40 } }, cam = { pos = { 0, 0, 60 }, ang = { 0, 90, 0 }, fov = 50 }, filter = "sepia" },
	{ ent = 2, name = "Me", pose = { HIPS = { 100, 0, 40 } }, cam = { pos = { 0, 0, 60 }, ang = { 0, 0, 0 }, fov = 70 }, filter = "bw" },
}
state({ phase = "show", photos = photos, showIndex = 1 })
check("the show: the camera closed, Bob's photo drawn from his camera", not UI.IsOpen("freezeframe") and C.shot == nil and played.freezeframe and played.freezeframe.ply == BOB and view().fov == 50)
check("... his skeleton frozen as it was", played.freezeframe.clip[1].P.HIPS.x == 5)
check("... with the button back for the engine", mask == 0)
state({ phase = "show", photos = photos, showIndex = 2 })
check("then mine", played.freezeframe.ply == LocalPlayer())
state({ phase = "vote", photos = photos, timeLeft = 20 })
check("the vote: only the others' photos to pick from", played.freezeframe.ply == BOB and #C.Choices(C.state) == 1)
api.pad = 0
C.Think(2)
api.pad = 0x1000
C.Think(2.1)
check("A votes for the one shown", lastSent().cmd == "vote" and lastSent().target == 1)
state({ phase = "out", photos = photos, out = { ent = 2, name = "Me", votes = 2 } })
check("out: the losing photo shown", played.freezeframe.ply == LocalPlayer())
state({ phase = "countdown", round = 2 })
check("next round: photos gone, the view back", played.freezeframe == nil and view == nil)
local cam = { pos = Vector(0, 0, 0), ang = Angle(348, 65, 0) }
UI.Fly(cam, { buttons = 0, lx = 0, ly = 0, rx = 0, ry = 0, lt = 0, rt = 0 }, 0.016, 100)
check("free camera: a pitch given as 348 (looking a little up) stays that, not 89 (straight down)", math.abs(cam.ang.p + 12) < 0.01)
state({ phase = "shoot", timeLeft = 30, round = 3 }, 10)
api.pad = 0
C.Think(10.1)
local before = #sent
C.Think(39.6)
check("never froze, time's up: the chase camera's view is sent as the photo", #sent == before + 1 and lastSent().cmd == "photo" and lastSent().cam.pos[3] == 60)
state({ phase = "shoot", timeLeft = 30, round = 4 }, 50)
api.pad = 0x0040
C.Think(50.5)
before = #sent
C.Think(79.6)
check("in the photo camera when time's up: taken as it is", #sent == before + 1 and lastSent().cmd == "photo")
