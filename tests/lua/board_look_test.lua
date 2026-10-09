dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end

local function sha(s)
	local h = 0
	for i = 1, #s do h = (h * 31 + s:byte(i)) % 4294967296 end
	return string.format("%08x%08x%08x%08x", h, #s, h % 65521, (#s * 7) % 65521)
end
local function json(t)
	local parts = {}
	for k, v in pairs(t) do parts[#parts + 1] = k .. "=" .. type(v) .. ":" .. tostring(v) end
	table.sort(parts)
	return table.concat(parts, "")
end
local function unjson(s)
	if type(s) ~= "string" then return nil end
	local t = {}
	for part in (s .. ""):gmatch("(.-)") do
		local k, ty, v = part:match("^([^=]+)=(%a+):(.*)$")
		if k then
			if ty == "number" then v = tonumber(v) elseif ty == "boolean" then v = v == "true" end
			t[k] = v
		end
	end
	return t
end
util = setmetatable({ AddNetworkString = function() end, SHA256 = sha, TableToJSON = json, JSONToTable = unjson }, { __index = util })

local sent, sends = {}, {}
local cur
net = {
	Start = function(n) cur = { name = n, vals = {} } end,
	WriteString = function(v) cur.vals[#cur.vals + 1] = v end,
	WriteUInt = function(v) cur.vals[#cur.vals + 1] = v end,
	WriteData = function(v) cur.vals[#cur.vals + 1] = v end,
	WriteBool = function(v) cur.vals[#cur.vals + 1] = v end,
	Send = function(ply) sends[#sends + 1] = { to = ply, msg = cur } end,
	SendToServer = function() sent[#sent + 1] = cur end,
	Receive = function() end,
}
local timers = {}
timer = { Simple = function(_, f) timers[#timers + 1] = f end, Create = function(_, _, _, f) timers[#timers + 1] = f end }
local function runTimers() local t = timers timers = {} for _, f in ipairs(t) do f() end end
function IsValid(x) return x ~= nil end
local players = {}
player = { GetAll = function() return players end }
local function Player(id)
	local p = { id = id, nw = {} }
	function p:SetNW2String(k, v) self.nw[k] = v end
	function p:GetNW2String(k, d) return self.nw[k] or d end
	players[#players + 1] = p
	return p
end

SERVER = true
dofile("../../addon/skategm/lua/skategm_board/sh_board.lua")
dofile("../../addon/skategm/lua/skategm_board/sv_board.lua")
dofile("../../addon/skategm/lua/skategm_boards/classic.lua")
dofile("../../docs/example_board/lua/skategm_boards/model.lua")
for _, f in ipairs({ "underglow", "trails", "sparks" }) do dofile("../../addon/skategm/lua/skategm_fx/" .. f .. ".lua") end
SERVER = nil

check("colours parse; nonsense doesn't", BOARD.ParseColor("10 20 255")[3] == 255 and not BOARD.ParseColor("1 2 300") and not BOARD.ParseColor("red") and not BOARD.ParseColor(nil))
local PNG = "\137PNG\r\n\26\n" .. string.rep("x", 70000)
local JPG = "\255\216\255\224" .. string.rep("y", 100)
check("images are told apart by their first bytes", BOARD.ImageType(PNG) == "png" and BOARD.ImageType(JPG) == "jpg" and not BOARD.ImageType("GIF89a......"))
check("image names: only letters, digits and _", BOARD.ValidName("abc123_x") and not BOARD.ValidName("../evil") and not BOARD.ValidName("a/b"))

local ann, ben = Player(1), Player(2)
local t = 100
BOARD.OnLook(ann, "0 120 255", "255 0 0", 0, t)
local look = BOARD.Decode(ann.nw.skategm_look)
check("colours go on the player for everyone", look and look.d[3] == 255 and look.w[1] == 255 and not look.i)
check("a second look within 0.4 s is ignored", BOARD.OnLook(ann, "1 1 1", "", 0, t + 0.1) == false)
BOARD.OnLook(ben, "999 0 0", "x", 0, t)
look = BOARD.Decode(ben.nw.skategm_look)
check("bad colours are dropped (default board)", look and not look.d and not look.w)

t = t + 1
BOARD.OnLook(ann, "0 120 255", "255 0 0", #PNG, t)
local name
for k = 1, math.ceil(#PNG / BOARD.CHUNK) do
	name = BOARD.OnChunk(ann, k, PNG:sub((k - 1) * BOARD.CHUNK + 1, k * BOARD.CHUNK), t) or name
end
look = BOARD.Decode(ann.nw.skategm_look)
check("an image arrives in chunks and is named by its hash", name == sha(PNG) and look.i == name and BOARD.images[name].kind == "png")

t = t + 5
BOARD.OnLook(ben, "", "", 20, t)
BOARD.OnChunk(ben, 1, "GIF89a" .. string.rep("z", 14), t)
look = BOARD.Decode(ben.nw.skategm_look)
check("a file that isn't PNG/JPG is refused", not look.i)
t = t + 5
BOARD.OnLook(ben, "", "", #JPG, t)
BOARD.OnChunk(ben, 1, JPG .. "extra", t)
check("more bytes than announced: refused", not BOARD.Decode(ben.nw.skategm_look).i and not ben.Sk8Up)
t = t + 5
BOARD.OnLook(ben, "", "", BOARD.MAX_BYTES + 1, t)
check("too big: no upload started", ben.Sk8Up == nil)

t = t + 5
BOARD.OnLook(ann, "1 2 3", "", BOARD.KEEP_IMAGE, t)
look = BOARD.Decode(ann.nw.skategm_look)
check("changing colours keeps the image", look.i == name and look.d[1] == 1)
t = t + 5
BOARD.OnLook(ann, "1 2 3", "", #JPG, t)
BOARD.OnLook(ann, "1 2 3", "", #JPG, t + 1)
check("a new upload within 3 s of the last doesn't start", ann.Sk8Up and ann.Sk8UpAt == t)

BOARD.Send(ben, name, t)
runTimers()
check(string.format("asking for an image sends it in %d chunks", #sends), #sends == 3 and sends[1].msg.vals[1] == name and sends[1].msg.vals[2] == "png")
local n = #sends
BOARD.Send(ben, name, t + 1)
runTimers()
check("asking again straight away sends nothing", #sends == n)
check("unknown or bad names send nothing", BOARD.Send(ben, "deadbeef", t) == false and BOARD.Send(ben, "../x", t) == false)

BOARD.KEEP_SPARE = 1
BOARD.images.old1 = { data = "a", kind = "png", at = 1 }
BOARD.images.old2 = { data = "b", kind = "png", at = 2 }
BOARD.Prune()
check("spare images are pruned, the oldest first; ones in use stay", BOARD.images[name] and BOARD.images.old2 and not BOARD.images.old1)

local files = {}
file = {
	CreateDir = function() end,
	Exists = function(f) return files[f] ~= nil end,
	Read = function(f) return files[f] end,
	Write = function(f, d) files[f] = d end,
	Find = function(pat)
		local out = {}
		local dir, ext = pat:match("^(.-)%*%.(%a+)$")
		for f in pairs(files) do
			local rest = f:sub(#dir + 1)
			if f:sub(1, #dir) == dir and not rest:find("/") and rest:lower():match("%.(%a+)$") == ext then out[#out + 1] = rest end
		end
		return out
	end,
}
local convars, callbacks = {}, {}
function CreateClientConVar(n, d)
	convars[n] = d
	return { GetName = function() return n end, GetString = function() return convars[n] end, GetBool = function() return convars[n] == "1" end,
		GetFloat = function() return tonumber(convars[n]) or 0 end, GetInt = function() return math.floor(tonumber(convars[n]) or 0) end }
end
function RunConsoleCommand(n, v) convars[n] = v end
convars.skategm_rocket = "0"
function GetConVar(n) if convars[n] == nil then return nil end return { GetBool = function() return convars[n] == "1" end, GetString = function() return convars[n] end } end
cvars = { AddChangeCallback = function(n, f) callbacks[n] = f end }
local said = {}
chat = { AddText = function(...) said[#said + 1] = table.concat({ select(4, ...) }) end }
hook = { Add = function() end }
local me = Player(3)
function LocalPlayer() return me end
function RealTime() return t end
local made = {}
function Material(path) return { IsError = function() return files[path:gsub("^%.%./data/", "")] == nil end, GetTexture = function() return "tex:" .. path end } end
function CreateMaterial(n) local m = { name = n } function m:SetTexture(_, tex) self.tex = tex end made[#made + 1] = m return m end
dofile("../../addon/skategm/lua/skategm_board/cl_board.lua")
CLIENT = true
dofile("../../addon/skategm/lua/skategm_boards/classic.lua")
dofile("../../docs/example_board/lua/skategm_boards/model.lua")
for _, f in ipairs({ "underglow", "trails", "sparks" }) do dofile("../../addon/skategm/lua/skategm_fx/" .. f .. ".lua") end
local C = BOARD.client
local MODEL = BOARD.Type("model")

files["skategm/boards/Mine.PNG"] = PNG
files["skategm/boards/b.jpg"] = JPG
files["skategm/boards/notes.txt"] = "hi"
local list = C.ImageFiles()
check("the image list: PNG and JPG files in data/skategm/boards", #list == 2 and list[1] == "b.jpg" and list[2] == "Mine.PNG")
check("file names can't leave the folder", not C.ValidFile("../cfg/x.png") and not C.ValidFile("a/b.png") and C.ValidFile("Mine.PNG"))

sent, timers = {}, {}
C.SendLook()
check("default look: the normal grip, default wheels, no image", sent[1].vals[1] == "40 40 43" and sent[1].vals[2] == "238 236 222" and sent[1].vals[3] == 0)

RunConsoleCommand("skategm_deck_color", "10 200 30")
RunConsoleCommand("skategm_board_image", "Mine.PNG")
callbacks.skategm_board_image()
sent = {}
runTimers()
check("a change sends my look after a moment", sent[1] and sent[1].vals[1] == "10 200 30" and sent[1].vals[3] == #PNG)
runTimers()
check(string.format("... then the image in %d chunks", #sent - 1), #sent == 4 and sent[2].name == BOARD.NET_UP)
check("my own image goes into the cache straight away", files["skategm/cache/" .. sha(PNG) .. ".png"] == PNG)
files["skategm/cache/" .. sha(PNG) .. ".png"] = nil
C.mats, C.retryAt, C.myImage = {}, {}, nil
local look = C.MyLookNow()
check("the settings preview shows my own image (by its cache name, not its file name)", look.mat ~= nil and look.mat.name == "skategm_under_" .. sha(PNG))

local up = {}
for _, m in ipairs(sent) do if m.name == BOARD.NET_UP then up[#up + 1] = m end end
BOARD.OnLook(me, sent[1].vals[1], sent[1].vals[2], sent[1].vals[3], t + 100)
for _, m in ipairs(up) do BOARD.OnChunk(me, m.vals[1], m.vals[3], t + 100) end
check("the server takes it", BOARD.Decode(me.nw.skategm_look).i == sha(PNG))
sent = {}
C.SendLook()
runTimers()
check("sending again: the server already has it, no re-upload", #sent == 1 and sent[1].vals[3] == BOARD.KEEP_IMAGE)

files["skategm/boards/huge.png"] = "\137PNG\r\n\26\n" .. string.rep("q", BOARD.MAX_BYTES)
RunConsoleCommand("skategm_board_image", "huge.png")
sent, said = {}, {}
C.SendLook()
check("too big: told why, and no image sent", said[1] and said[1]:find("KB") and sent[1].vals[3] == 0)

local other = Player(4)
BOARD.OnLook(other, "5 6 7", "8 9 10", 0, t + 200)
other.nw.skategm_look = BOARD.Encode({ d = "5 6 7", w = "8 9 10", i = "abcd1234abcd1234" })
sent = {}
local L = C.LookFor(other)
check("another player's look: their colours", L.deck.r == 5 and L.wheels.b == 10)
check("... and their image is asked for once", not L.mat and #sent == 1 and sent[1].name == BOARD.NET_REQ and sent[1].vals[1] == "abcd1234abcd1234")
C.LookFor(other)
check("... not again every frame", #sent == 1)

local img = JPG .. string.rep("w", 40000)
local iname = sha(img)
other.nw.skategm_look = BOARD.Encode({ d = "", w = "", i = iname })
C.LookFor(other)
local parts = math.ceil(#img / BOARD.CHUNK)
check("bad chunks are ignored", C.OnImage("../x", "jpg", 1, 1, "a", t) == nil and C.OnImage(iname, "gif", 1, 1, "a", t) == nil)
for k = parts, 1, -1 do C.OnImage(iname, "jpg", k, parts, img:sub((k - 1) * BOARD.CHUNK + 1, k * BOARD.CHUNK), t) end
check("an image arriving out of order is put together and kept", files["skategm/cache/" .. iname .. ".jpg"] == img)
C.OnImage("abcdabcdabcd", "jpg", 1, 1, JPG, t)
check("an image that doesn't match its name is thrown away", files["skategm/cache/abcdabcdabcd.jpg"] == nil)
L = C.LookFor(other)
check("then it's drawn under their board", L.mat and L.mat.tex == "tex:../data/skategm/cache/" .. iname .. ".jpg" and not L.deck)
RunConsoleCommand("skategm_show_board_images", "0")
check("hiding other players' images", C.LookFor(other).mat == nil)
check("... but not my own", C.LookFor(me).mat ~= nil)
check("no look yet: the normal board", C.LookFor(Player(9)) == nil)

-- reset (Settings > Board on the controller has the button)
RunConsoleCommand("skategm_board_image", "b.jpg")
RunConsoleCommand("skategm_hoverboard", "1")
RunConsoleCommand("skategm_rocket", "1")
RunConsoleCommand("skategm_grip_pattern", "3")
C.Reset()
check("reset: normal grip, default wheels, no image", convars.skategm_deck_color == "40 40 43" and convars.skategm_wheel_color == "238 236 222" and convars.skategm_board_image == "")
check("... and everything else: no hover, no rocket, plain grip, the skateboard", convars.skategm_hoverboard == "0" and convars.skategm_rocket == "0" and convars.skategm_grip_pattern == "1" and convars.skategm_board_type == "classic")

BOARD.OnLook(other, "1 1 1", "", 0, t + 400, true)
check("a rocket on the board travels with the look", BOARD.Decode(other.nw.skategm_look).r == true and C.LookFor(other).rocket == true)
BOARD.OnLook(other, "1 1 1", "", 0, t + 401, false)
check("... and goes when it's switched off", BOARD.Decode(other.nw.skategm_look).r == false and not C.LookFor(other).rocket)
RunConsoleCommand("skategm_rocket", "1")
sent = {}
C.SendLook()
check("my rocket switch is sent with my look", sent[1].vals[4] == true)

check("board types: the skateboard first, then any model", BOARD.TYPES[1].id == "classic" and BOARD.TYPES[2].id == "model")
local x = BOARD.CleanExtra({ bt = "model", o_path = "models/props_debris/wood_board04a.mdl", o_scale = 99, o_up = -999, o_forward = 3, o_yaw = 90, o_wheels = false, rs = 3, ks = 99 })
check("a board model's settings are kept within limits", x.bt == "model" and x.o_path and x.o_scale == 4 and x.o_up == -48 and x.o_forward == 3 and x.o_yaw == 90 and x.o_wheels == false and x.rs == 3 and x.ks == #BOARD.ROCKET_SOUNDS)
check("only real model paths are accepted", BOARD.CleanExtra({ bt = "model", o_path = "../../cfg/x.mdl" }).o_path == MODEL.fields[1].default and BOARD.CleanExtra({ bt = "model", o_path = "materials/x.vmt" }).o_path == MODEL.fields[1].default)
check("an unknown board type: the skateboard, with no stray options", BOARD.CleanExtra({ bt = "nope", o_path = "models/a.mdl" }).bt == "classic" and BOARD.CleanExtra({ bt = "nope", o_path = "models/a.mdl" }).o_path == nil)
BOARD.OnLook(other, "1 1 1", "", 0, t + 500, false, { bt = "model", o_path = "models/props_c17/door01_left.mdl", o_scale = 0.5, o_up = 2, o_yaw = 90, o_wheels = false, rs = 4, ks = 2 })
L = C.LookFor(other)
check("everyone sees the board type with its options", L.type == "model" and L.opts.path == "models/props_c17/door01_left.mdl" and L.opts.scale == 0.5 and L.opts.up == 2 and L.opts.yaw == 90 and L.opts.wheels == false)
check("... and hears its sounds", L.rollSound == BOARD.ROLL_SOUNDS[4][2] and L.rocketSound == BOARD.ROCKET_SOUNDS[2][2])
BOARD.OnLook(other, "1 1 1", "", 0, t + 501, false, {})
L = C.LookFor(other)
check("nothing chosen: the skateboard, default sounds", L.type == "classic" and L.rollSound == BOARD.ROLL_SOUNDS[1][2] and L.rocketSound == BOARD.ROCKET_SOUNDS[1][2])

local parts
local function drawBoard(_, o) parts = o end
local P = { TRUCK_FRONT = Vector(10, 0, 3), TRUCK_BACK = Vector(-10, 0, 3), RIGHT_WHEELFRONT = Vector(10, -4, 1), LEFT_WHEELFRONT = Vector(10, 4, 1), RIGHT_WHEELBACK = Vector(-10, -4, 1), LEFT_WHEELBACK = Vector(-10, 4, 1) }
check("the skateboard type draws the built-in board", C.Draw(other, P, L, nil, false, false, drawBoard) and parts and parts.trucks == true and parts.deck == nil)
C.Draw(other, P, L, nil, false, true, drawBoard)
check("... without trucks or wheels in hoverboard mode", parts.trucks == false)
local made2 = {}
ClientsideModel = function(path) local e = { path = path, drawn = 0 } function e:SetNoDraw() end function e:SetPos(p) self.pos = p end function e:SetAngles(a) self.ang = a end function e:SetModelScale(s) self.scale = s end function e:DrawModel() self.drawn = self.drawn + 1 end function e:Remove() end made2[#made2 + 1] = e return e end
util.IsValidModel = function(p) return BOARD.ValidModel(p) end
local ML = { type = "model", opts = { path = "models/props_c17/door01_left.mdl", scale = 0.5, up = 0, forward = 0, yaw = 0, pitch = 0, roll = 0, wheels = true } }
parts = nil
check("the model type draws the model", C.Draw(other, P, ML, nil, true, false, drawBoard) and made2[1] and made2[1].drawn == 1 and made2[1].scale == 0.5)
check("... with trucks, the rocket, and no deck", parts and parts.deck == false and parts.trucks == true and parts.rocket == true)
ML.opts.wheels = false
C.Draw(other, P, ML, nil, false, false, drawBoard)
check("... or without the trucks", parts.trucks == false)
parts = nil
local bad = { type = "model", opts = { path = "models/missing/../x.mdl" } }
check("a model that can't be made: the skateboard instead", C.Draw(Player(11), P, bad, nil, false, false, drawBoard) and parts and parts.deck == nil)
parts = nil
check("a board type this client doesn't have: the skateboard", C.Draw(other, P, { type = "gone", opts = {} }, nil, false, false, drawBoard) and parts ~= nil)

RunConsoleCommand("skategm_board_type", "model")
RunConsoleCommand("skategm_board_model", "models/props_junk/sawblade001a.mdl")
RunConsoleCommand("skategm_board_model_scale", "2")
RunConsoleCommand("skategm_roll_sound", "3")
RunConsoleCommand("skategm_board_image", "b.jpg")
sent = {}
C.SendLook()
check("my board type, model, fit and sounds are sent with my look", sent[1] and type(sent[1].vals[5]) == "string" and sent[1].vals[5]:find("sawblade") ~= nil and sent[1].vals[5]:find("bt=string:model", 1, true) ~= nil)
check("... and no deck image (the model type has none)", sent[1].vals[3] == 0)

local pos = MODEL.Placement(P, { up = 5, forward = 3 })
check("the model sits on the board, moved by the up / forward offsets", pos and math.abs(pos.z - (1 + 2 + 5)) < 1e-4 and math.abs(pos.x - 3) < 1e-4)

-- the controller's Settings > Board page (skategm_ui/cl_settings.lua)
RealTime = RealTime or function() return 0 end
local SET
local function Names()
	if not SET then
		dofile("../../addon/skategm/lua/skategm_ui/cl_pad.lua")
		dofile("../../addon/skategm/lua/skategm_ui/cl_settings.lua")
		SET = SKATEGM_UI.settings
	end
	SET.pending = {}
	local names = {}
	for _, r in ipairs(SET.BoardPage().rows) do names[#names + 1] = r.label end
	return "|" .. table.concat(names, "|") .. "|"
end
local function Row(label)
	for _, r in ipairs(SET.BoardPage().rows) do if r.label == label then return r end end
	for _, r in ipairs(SET.AudioPage().rows) do if r.label == label then return r end end
end
RunConsoleCommand("skategm_board_type", "model")
local all = Names()
check("Board page, model type: its own fields", all:find("|Scale|", 1, true) and all:find("|Up / down|", 1, true))
check("... its sounds are on the Audio page", Row("Rolling sound") and Row("Rocket sound"))
check("... none of the skateboard's options", not all:find("Image under the deck", 1, true) and not all:find("Grip tape pattern", 1, true))
check("... the board type row reads the type", Row("Board type").value() == "Any model")
Row("Board type").change(-1)
all = Names()
check("picking the skateboard: its options replace the model's", convars.skategm_board_type == "classic" and all:find("Image under the deck", 1, true) and not all:find("|Scale|", 1, true))
check("... the shared options stay", all:find("|Hoverboard|", 1, true) and all:find("|Rocket board|", 1, true))

local played, stopped = nil, false
CreateSound = function(ent, path) played = path return { Play = function() end, Stop = function() stopped = true end } end
local timers2 = {}
timer.Create = function(name, delay, reps, f) timers2[#timers2 + 1] = { delay, f } end
convars.skategm_roll_sound = "2"
Row("Rolling sound").change(1)
check("a sound: changing it plays the chosen loop...", played == BOARD.ROLL_SOUNDS[3][2])
check("... for 2 seconds", timers2[#timers2] and timers2[#timers2][1] == 2 and (timers2[#timers2][2]() or true) and stopped)

local extra = BOARD.RegisterType({ id = "glow", title = "Glow stick", order = 5, fields = { { key = "bright", kind = "number", convar = "skategm_glow_bright", min = 0, max = 10, default = 4, label = "Brightness" } } })
check("an add-on can register its own board type", BOARD.Type("glow") == extra and convars.skategm_glow_bright == "4")
check("... its options are cleaned by its own rules", BOARD.CleanExtra({ bt = "glow", o_bright = 50 }).o_bright == 10)
RunConsoleCommand("skategm_board_type", "glow")
check("... and its options show on the Board page", Names():find("|Brightness|", 1, true) ~= nil)


check("effects: underglow, trails, grind sparks, in that order", #BOARD.EFFECTS == 3 and BOARD.EFFECTS[1].id == "underglow" and BOARD.EFFECTS[2].id == "trails" and BOARD.EFFECTS[3].id == "sparks")
local fx = BOARD.CleanExtra({ f_trails_length = 99, f_trails_style = 3, f_underglow_color = "red", f_underglow_on = true })
check("effect options are cleaned too", fx.f_trails_length == 3 and fx.f_trails_style == 3 and fx.f_underglow_color == "0 200 255" and fx.f_underglow_on == true and fx.f_sparks_on == false)
BOARD.OnLook(other, "1 1 1", "", 0, t + 600, false, { f_trails_style = 2, f_trails_mode = 3, f_trails_color = "1 2 3", f_underglow_on = true })
L = C.LookFor(other)
check("everyone sees my effects", L.effects.trails.style == 2 and L.effects.trails.color == "1 2 3" and L.effects.underglow.on == true and L.effects.sparks.on == false)
RunConsoleCommand("skategm_trail", "4")
RunConsoleCommand("skategm_underglow", "1")
sent = {}
C.SendLook()
check("my effects are sent with my look", sent[1].vals[5]:find("f_trails_style=number:4", 1, true) and sent[1].vals[5]:find("f_underglow_on=boolean:true", 1, true))
RunConsoleCommand("skategm_board_type", "classic")
all = Names()
check("Board page: each effect's options", all:find("Trail length", 1, true) ~= nil)
RunConsoleCommand("skategm_trail_mode", "1")
check("an effect's custom colour row is hidden unless Custom colour is picked", not Names():find("|Trail: custom colour|", 1, true))
RunConsoleCommand("skategm_trail_mode", "3")
check("... and shown once it is", Names():find("|Trail: custom colour|", 1, true) ~= nil and BOARD.COLOUR_MODES[3] == "Custom colour")
RunConsoleCommand("skategm_trail_mode", "1")
check("grind sparks are off unless turned on", convars.skategm_sparks == "0")
RunConsoleCommand("skategm_sparks", "1")

local quads, beams, beamPoints, lights, particles = 0, 0, 0, 0, 0
render = render or {}
render.SetMaterial = function() end
render.DrawQuad = function() quads = quads + 1 end
render.StartBeam = function() beams = beams + 1 end
render.AddBeam = function() beamPoints = beamPoints + 1 end
render.EndBeam = function() end
function CurTime() return t end
DynamicLight = function() lights = lights + 1 return {} end
local pmock = setmetatable({}, { __index = function() return function() end end })
ParticleEmitter = function() return { SetPos = function() end, Add = function() particles = particles + 1 return pmock end, Finish = function() end } end
me.EntIndex = function() return 3 end
local function moved(dx) local Q = {} for k, v in pairs(P) do Q[k] = v + Vector(dx, 0, 0) end return Q end
C.DrawEffects(me, moved(0), nil, "PhysicsGround", 1, 1)
C.DrawEffects(me, moved(8), nil, "PhysicsGround", 1.05, 2)
check("underglow: a glow under the board and a light on the ground", quads >= 2 and lights >= 1)
check("trails: a beam from each back wheel", beams >= 2 and beamPoints >= 4)
check("no sparks while rolling", particles == 0)
C.DrawEffects(me, moved(16), nil, "GrindFiftyFifty", 1.1, 3)
check("sparks while grinding", particles > 0)
local before = particles
C.DrawEffects(me, moved(16), nil, "GrindFiftyFifty", 1.1, 3)
check("drawn twice in one frame (mirrors): no extra sparks", particles == before)
RunConsoleCommand("skategm_underglow", "0")
RunConsoleCommand("skategm_trail", "1")
quads, beams = 0, 0
C.DrawEffects(me, moved(24), nil, "PhysicsGround", 1.15, 4)
check("effects off: nothing drawn", quads == 0 and beams == 0)

local CL = BOARD.Type("classic")
check("the skateboard has grip tape patterns", CL.fields[1].key == "pattern" and #CL.patterns >= 9 and CL.patterns[1][1] == "None")
local px = BOARD.CleanExtra({ bt = "classic", o_pattern = 4, o_pattern_color = "200 10 10" })
check("the pattern and its colour travel with the look", px.o_pattern == 4 and px.o_pattern_color == "200 10 10")
check("... checked like any option", BOARD.CleanExtra({ bt = "classic", o_pattern = 99 }).o_pattern == #CL.patterns and BOARD.CleanExtra({ bt = "classic", o_pattern_color = "x" }).o_pattern_color == "255 255 255")
Material = function(path) return { path = path, IsError = function() return false end } end
local gotParts
C.Draw(other, P, { type = "classic", opts = { pattern = 4, pattern_color = "200 10 10" } }, nil, false, false, function(_, o) gotParts = o end)
check("drawn with the pattern's texture, in its colour", gotParts and gotParts.pattern and gotParts.pattern.path == "skategm/grip/checker" and gotParts.patternColor.r == 200)
C.Draw(other, P, { type = "classic", opts = { pattern = 1 } }, nil, false, false, function(_, o) gotParts = o end)
check("no pattern: plain grip", gotParts and gotParts.pattern == nil)
RunConsoleCommand("skategm_board_type", "classic")
check("Board page: a pattern list and a pattern colour", Names():find("|Grip tape pattern|", 1, true) and Names():find("|Pattern colour|", 1, true))

-- adding a picked image: small ones as they are, big ones shrunk to a JPG
do
	local renderHooks = {}
	hook.Add = function(ev, id, f) if ev == "PostRender" then renderHooks[id] = f end end
	hook.Remove = function(ev, id) if ev == "PostRender" then renderHooks[id] = nil end end
	file.Size = function(f) return files[f] and #files[f] or nil end
	file.Delete = function(f) files[f] = nil end
	Material = function(path) return { IsError = function() return false end, Width = function() return 3000 end, Height = function() return 1000 end } end
	GetRenderTargetEx = function(name, w, h) return { name = name, w = w, h = h } end
	cam = cam or {}
	cam.Start2D, cam.End2D = function() end, function() end
	surface = surface or {}
	surface.SetDrawColor, surface.SetMaterial, surface.DrawTexturedRect = function() end, function() end, function() end
	local captures = {}
	render = render or {}
	render.PushRenderTarget, render.PopRenderTarget, render.Clear = function() end, function() end, function() end
	render.Capture = function(o) captures[#captures + 1] = o return string.rep("j", o.quality >= 90 and BOARD.MAX_BYTES + 1 or 1000) end
	RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, IMAGE_FORMAT_RGB888 = 0, 0, 0
	local got
	files["skategm/boards/small.png"] = PNG
	C.AddImage("small.png", function(n) got = n end)
	check("a picked image under the limit is used as it is", got == "small.png")
	files["skategm/boards/photo.png"] = "\137PNG\r\n\26\n" .. string.rep("p", BOARD.MAX_BYTES + 10)
	got = nil
	C.AddImage("photo.png", function(n, err) got = n or err end)
	for _ = 1, 10 do if renderHooks.skategm_board_shrink then renderHooks.skategm_board_shrink() end end
	check("a big one is shrunk to a JPG under the limit, longest side 1024 at most", got == "photo.jpg" and #files["skategm/boards/photo.jpg"] <= BOARD.MAX_BYTES
		and captures[1].w == 1024 and captures[1].h == 341 and captures[1].format == "jpeg")
	check("... trying lower quality before giving up", #captures == 2 and captures[2].quality < captures[1].quality)
	check("... the oversized copy is removed, and the drawing hook too", files["skategm/boards/photo.png"] == nil and renderHooks.skategm_board_shrink == nil)
	render.Capture = function() return string.rep("j", BOARD.MAX_BYTES + 1) end
	files["skategm/boards/huge.png"] = "\137PNG\r\n\26\n" .. string.rep("p", BOARD.MAX_BYTES + 10)
	got = nil
	C.AddImage("huge.png", function(n, err) got = n and "ok" or err end)
	for _ = 1, 10 do if renderHooks.skategm_board_shrink then renderHooks.skategm_board_shrink() end end
	check("... and if nothing fits, it says so", got == "the image is too big even shrunk")
end

files["skategm/boards/del.png"] = PNG
RunConsoleCommand("skategm_board_image", "del.png")
check("deleting the image in use: the file goes, the board shows none", C.DeleteImage("del.png") and files["skategm/boards/del.png"] == nil and convars.skategm_board_image == "")
check("... nothing outside the images folder can be deleted", C.DeleteImage("../config.txt") == false)
