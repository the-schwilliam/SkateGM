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
local mode = SKATEGM_MODES.Register({ id = "snakish", title = "Snakish", order = 5 })
mode:Host({
	useStart = false,
	description = "a test",
	options = {
		{ key = "area", label = "Play area", type = "region", min = 256, max = 2048, step = 128, default = 512 },
		{ key = "goal", label = "Goal", type = "point" },
		{ key = "time", label = "Time", type = "number", min = 30, max = 300, step = 30, default = 60 },
		{ key = "fast", label = "Fast", type = "bool", default = false },
	},
	start = function(v) hosted = v end,
})
local other = SKATEGM_MODES.Register({ id = "otherish", title = "Otherish", order = 6 })

local function press(b, hold)
	pad.buttons = (hold or 0) + b
	clock = clock + 0.05
	hooks["Think/skategm_ui"]()
	pad.buttons = hold or 0
	clock = clock + 0.05
	hooks["Think/skategm_ui"]()
end

press(B.LEFT)
check("D-pad left alone does nothing", not MENU.IsOpen())
press(B.LEFT, B.LB)
local main = MENU.Top()
check("LB + D-pad left opens Minigames: Host and Join", MENU.IsOpen() and main.title == "Minigames" and main.rows()[1].label == "Host" and main.rows()[2].label == "Join")
check("... and the skater gets no input meanwhile", api.blocked == true)
press(B.A)
check("Host opens the host list", MENU.Top().title == "Host a minigame")
local rows = MENU.Top().rows()
check("every hostable minigame is listed, under its category (none: Other)", #rows == 2 and rows[1].heading and rows[1].label == "Other" and rows[2].label == "Snakish")
local groups = MENU.ByCategory({ { title = "Zed", category = "Party" }, { title = "Bee", category = "Tricks" }, { title = "Ace", category = "Tricks" }, { title = "Odd" }, { title = "Mine", category = "Custom" } })
check("categories in their order (Tricks first, Party last of ours, an add-on's own next, Other at the end), games A to Z",
	groups[1].name == "Tricks" and groups[1].modes[1].title == "Ace" and groups[2].name == "Party" and groups[3].name == "Custom" and groups[4].name == "Other")
press(B.A)
check("A opens its options", MENU.Top().title == "Host Snakish")
press(B.RIGHT)
press(B.RIGHT)
check("left / right change the area slider", MENU.Top().values.area == 768)
press(B.DOWN)
press(B.DOWN)
press(B.LEFT)
check("... and a number", MENU.Top().values.time == 30)
press(B.DOWN)
press(B.A)
check("A toggles an on/off option", MENU.Top().values.fast == true)
press(B.DOWN)
check("every mode gets rocket board and hoverboard switches, off by default", MENU.Top().rows()[MENU.Top().sel].label == "Rocket board" and MENU.Top().values._rocket == 0 and MENU.Top().values._hover == false)
press(B.DOWN)
press(B.DOWN)
press(B.DOWN)
local hostRow = MENU.Top().rows()[MENU.Top().sel]
check("Host it waits until every point is placed", hostRow.label == "Host it" and hostRow.disabled)
press(B.A)
check("... so A does nothing yet", hosted == nil and MENU.IsOpen())
press(B.UP)
press(B.UP)
press(B.UP)
press(B.UP)
press(B.UP)
press(B.UP)
press(B.A)
check("a point opens a free camera to fly to it", MENU.fc ~= nil and api.view ~= nil)
local view = api.view(nil, nil, 75)
check("... starting from the current view", view.origin.y == -100 and view.fov == 75)
pad.ly = 1
hooks["Think/skategm_ui"]()
pad.ly = 0
check("the left stick flies the camera", api.view(nil, nil, 75).origin.y > -100)
press(B.A)
check("A places the point where you're looking", MENU.Top().values.goal and MENU.Top().values.goal.pos == traceHit and MENU.fc == nil and api.view == nil)
press(B.DOWN)
press(B.DOWN)
press(B.DOWN)
press(B.DOWN)
press(B.DOWN)
press(B.DOWN)
press(B.A)
check("Host it: the mode gets every value", hosted and hosted.time == 30 and hosted.fast == true and hosted.goal.pos == traceHit)
check("... the area as a circle around where the host stands", hosted.area.radius == 768 and hosted.area.centre.x == 10)
check("... the menu closes and the skater gets input back", not MENU.IsOpen() and api.blocked == false)

mode.state = { phase = "lobby", host = 1, players = { { ent = 1 } } }
press(B.LEFT, B.LB)
rows = MENU.Top().rows()
check("hosting: LB + D-pad left goes straight to my game", MENU.Top().title:find("you're hosting", 1, true) ~= nil)
check("... Start the game, Invite players, Close the game", rows[1].label == "Start the game" and rows[2].label == "Invite players" and rows[3].label == "Close the game")
sent = {}
press(B.A)
check("Start sends begin", sent[1] and sent[1].msg.cmd == "begin" and not MENU.IsOpen())
mode.state = { phase = "playing", host = 1, players = { { ent = 1 } } }
press(B.LEFT, B.LB)
rows = MENU.Top().rows()
check("a game going (even a countdown): Restart (same players and settings), or Close the game", rows[1].label == "Restart" and rows[2].label == "Close the game")
sent = {}
press(B.A)
check("Restart: back to its lobby and straight off again (stop, then begin)", sent[1] and sent[1].msg.cmd == "stop" and not sent[1].msg.close and sent[2] and sent[2].msg.cmd == "begin")
press(B.LEFT, B.LB)
sent = {}
press(B.DOWN)
press(B.A)
check("Close the game closes it in one go (stop + close)", sent[1] and sent[1].msg.cmd == "stop" and sent[1].msg.close == true and not MENU.IsOpen())
mode.state = { phase = "lobby", host = 1, players = { { ent = 1 } } }

mode.state = { phase = "idle" }
other.state = { phase = "lobby", host = 2, players = { { ent = 2 } } }
press(B.LEFT, B.LB)
press(B.DOWN)
press(B.A)
rows = MENU.Top().rows()
check("Minigames > Join lists hosted games", MENU.Top().title == "Join a minigame" and #rows == 1 and rows[1].label == "Otherish")
check("... with who's hosting underneath", rows[1].sub == "Hosted by Ann")
sent = {}
press(B.A)
check("A joins", sent[1] and sent[1].msg.cmd == "join" and not MENU.IsOpen())
-- several games of one mode at once
other.state = { phase = "idle" }
other:HandleState({ session = 4, phase = "lobby", host = 2, players = { { ent = 2 } } }, clock)
other:HandleState({ session = 7, phase = "lobby", host = 2, players = { { ent = 2 } } }, clock)
press(B.LEFT, B.LB)
press(B.DOWN)
press(B.A)
rows = MENU.Top().rows()
check("two games of the same mode: both listed to join", #rows == 2 and rows[1].label == "Otherish" and rows[2].label == "Otherish")
sent = {}
press(B.DOWN)
press(B.A)
check("... joining the one picked", sent[1] and sent[1].msg.cmd == "join" and sent[1].msg.session == 7)
other:HandleState({ session = 7, phase = "lobby", host = 2, players = { { ent = 2 }, { ent = 1 } } }, clock)
press(B.LEFT, B.LB)
rows = MENU.Top().rows()
check("in a game: LB + D-pad left goes straight to it, to leave it", rows[1].label == "Leave the game")
other:HandleState({ session = 4, phase = "idle" }, clock)
other:HandleState({ session = 7, phase = "idle" }, clock)
check("... the games end: I'm out of it", other.state.phase == "idle")
press(B.B)
press(B.B)
other.state = { phase = "idle" }
press(B.LEFT, B.LB)
press(B.DOWN)
press(B.A)
rows = MENU.Top().rows()
check("nothing hosted: says so", #rows == 1 and rows[1].disabled and rows[1].label:find("Nobody") ~= nil)
press(B.B)
check("B goes back", MENU.IsOpen() and MENU.Top().title == "Minigames")
press(B.B)
check("... and closes", not MENU.IsOpen() and api.blocked == false)

local BOB = { EntIndex = function() return 3 end, Nick = function() return "Bob" end, IsValid = function() return true end,
	GetPos = function() return Vector(-300, 0, 0) end, EyeAngles = function() return Angle(0, 0, 0) end }
local CAL = { EntIndex = function() return 4 end, Nick = function() return "Cal" end, IsValid = function() return true end,
	GetPos = function() return Vector(900, 900, 16) end, EyeAngles = function() return Angle(0, 180, 0) end }
ANN.GetPos = function() return Vector(100, 0, 0) end
ANN.EyeAngles = function() return Angle(0, 0, 0) end
player = { GetAll = function() return { ME, CAL, BOB, ANN } end }
local skaters = { ANN, BOB }
SkateGM.API.Skaters = function() return skaters end
SkateGM.API.Freeze = function(on) api.frozen = on end
SkateGM.API.SetHidden = function(why, on) api.hidden = api.hidden or {} api.hidden[why] = on end
SkateGM.API.PoseOf = function(ply)
	if ply ~= ANN and ply ~= BOB then return nil end
	local x = ply == ANN and 100 or -300
	return { HIPS = Vector(x, 0, 40), TRUCK_FRONT = Vector(x + 8, 0, 4), TRUCK_BACK = Vector(x - 8, 0, 4) }
end
local tele
SkateGM.API.TeleportTo = function(pos, yaw) tele = { pos = pos, yaw = yaw } return true end
-- Ann hosts a Snakish game that's taking players
mode.seen = { [7] = { st = { phase = "lobby", host = 2, players = { { ent = 2 } } }, at = clock } }
press(B.RIGHT, B.LB)
rows = MENU.Top().rows()
check("LB + D-pad right opens Players: everyone else, by name", MENU.Top().title == "Players" and #rows == 3 and rows[1].label == "Ann" and rows[2].label == "Bob" and rows[3].label == "Cal")
check("... each saying if they're skating and what game they're in", rows[1].sub == "skating, in Snakish (open)" and rows[2].sub == "skating" and rows[3].sub == "on foot")
-- (the hints the shared list shows for a row: { text, lit })
local function hint(row, key)
	for _, h in ipairs(SKATEGM_UI.List.Hints({ {} }, row)) do if h.keys[1] == key then return { h.text, h.lit ~= false } end end
	return { nil, false }
end
check("... the buttons on the selected one: A spectate, X teleport, Y join", hint(rows[1], "A")[1] == "Spectate" and hint(rows[1], "X")[1] == "Teleport to them" and hint(rows[1], "Y")[1] == "Join Snakish")
check("... lit only when they'd work", hint(rows[1], "Y")[2] and not hint(rows[2], "Y")[2] and hint(rows[2], "A")[2] and not hint(rows[3], "A")[2] and hint(rows[3], "X")[2])
sent = {}
press(B.Y)
check("Y: joins the game they're in (that game, not another)", sent[1] and sent[1].msg and sent[1].msg.cmd == "join" and sent[1].msg.session == 7 and not MENU.IsOpen())
press(B.RIGHT, B.LB)
press(B.DOWN)
sent = {}
press(B.Y)
check("Y on someone in no game: nothing", #sent == 0 and MENU.IsOpen())
press(B.X)
check("X: teleports me next to their skater (not into them), facing their way", tele and math.abs(tele.pos.x + 300) < 1 and math.abs(math.abs(tele.pos.y) - 64) < 1 and tele.yaw == 0 and not MENU.IsOpen())
press(B.RIGHT, B.LB)
press(B.DOWN) press(B.DOWN)
press(B.A)
check("A on someone on foot: no spectating", not MENU.spec and MENU.IsOpen())
tele = nil
press(B.X)
check("X on someone on foot: next to where they stand", tele and math.abs(tele.pos.x - 900) < 1)
press(B.RIGHT, B.LB)
press(B.A)
check("A: spectating them, my skater frozen, the camera on them", MENU.spec and MENU.spec.target == ANN and api.frozen == true and api.view ~= nil)
check("... and my skater hidden from everyone", api.hidden and api.hidden.menuspec == true)
local v = api.view(nil, nil, 70)
check("... a chase camera looking at them", v and (v.origin - Vector(100, 0, 50)):Length() < 200)
press(B.RIGHT)
check("D-pad right: the next skater", MENU.spec.target == BOB)
tele = nil
press(B.X)
check("X while spectating: teleport to them", tele and math.abs(tele.pos.x + 300) < 1 and not MENU.spec and api.frozen == false)
press(B.RIGHT, B.LB)
press(B.A)
press(B.B)
check("B stops: my skater and camera back", not MENU.spec and not MENU.IsOpen() and api.frozen == false and api.view == nil and api.blocked == false)
check("... visible again", api.hidden.menuspec == false)
player = { GetAll = function() return { ME } end }
press(B.RIGHT, B.LB)
rows = MENU.Top().rows()
check("nobody else here: says so", #rows == 1 and rows[1].disabled)
press(B.B)
press(B.LEFT, B.LB)
api.nopad = true
hooks["Think/skategm_ui"]()
check("leaving Skate 3 mode closes the menu", not MENU.IsOpen())
api.nopad = nil
MENU.SCREENS = { replays = function() return { title = "Replays", rows = function() return { { label = "Last 15 seconds" } } end } end }
press(B.DOWN, B.LB)
check("LB + D-pad down stays the marker's: no menu", not MENU.IsOpen())
press(B.RB, B.LB)
check("LB + RB opens Replays", MENU.IsOpen() and MENU.Top().title == "Replays")
MENU.Close()
local respawned = 0
SkateGM.API.Respawn = function() respawned = respawned + 1 return true end
press(0x4000, B.LB)
check("LB + X: respawn, no menu", respawned == 1 and not MENU.IsOpen())
press(0x4000)
check("X alone isn't respawn (it's the engine's)", respawned == 1)
SKATEGM_UI.Take("replay", {})
press(B.RB, B.LB)
check("while a replay plays, the menus stay shut", not MENU.IsOpen())
SKATEGM_UI.Give("replay")
local free = { EntIndex = function() return 21 end, Nick = function() return "Free" end }
local busy = { EntIndex = function() return 22 end, Nick = function() return "Busy" end }
player = { GetAll = function() return { LocalPlayer(), free, busy } end }
local oldGameOf = SKATEGM_MODES.GameOf
SKATEGM_MODES.GameOf = function(p) return p == busy and mode or nil end
local invRows = MENU.InviteScreen(mode).rows()
check("invite list: everyone else, those in a minigame greyed out", #invRows == 2 and invRows[1].label == "Free" and not invRows[1].disabled and invRows[2].disabled)
sent = {}
invRows[1].run()
check("... A sends the invite", sent[1] and sent[1].msg.cmd == "_invite" and sent[1].msg.target == 21 and MENU.InviteScreen(mode).rows()[1].sub ~= nil)
SKATEGM_MODES.GameOf = oldGameOf
local placed = MENU.Resolve(mode.hostDef, { _start = { pos = Vector(700, 800, 9), yaw = 0 }, area = 512 })
check("a placed Start: the play area is centred on it, not on me", placed.area.centre.x == 700 and placed.area.centre.y == 800 and placed.area.radius == 512)
