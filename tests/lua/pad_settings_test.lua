dofile("gmock.lua")
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
function IsValid(x) return x ~= nil and (type(x) ~= "table" or not x.IsValid or x:IsValid()) end
function ScrW() return 1600 end
function ScrH() return 900 end
local clock = 0
RealTime = function() return clock end
timer = { Simple = function(_, f) f() end }

-- convars, as GMod keeps them; RunConsoleCommand sets them
local cvars_ = { cl_playermodel = "kleiner", cl_playercolor = "0.24 0.34 0.41", skategm_camera_shake = "0", skategm_camera_distance = "1", skategm_camera_fov = "0",
	skategm_board_type = "classic", skategm_deck_color = "255 255 255", skategm_wheel_color = "25 25 25", skategm_board_image = "", skategm_rocket = "0",
	skategm_hoverboard = "0", skategm_roll_sound = "1", skategm_rocket_sound = "1", skategm_grip_pattern = "1",
	skategm_hud = "1", skategm_hud_total = "1", skategm_flickit_hud = "0" }
function GetConVar(n) if cvars_[n] == nil then return nil end return { GetString = function() return cvars_[n] end, GetFloat = function() return tonumber(cvars_[n]) or 0 end } end
local played, reset = {}, false
RunConsoleCommand = function(n, v) cvars_[n] = v end

local function ParseColor(s) local r, g, b = tostring(s):match("^(%d+) (%d+) (%d+)$") if r then return { tonumber(r), tonumber(g), tonumber(b) } end end
BOARD = { DEFAULT_TYPE = "classic", ParseColor = ParseColor,
	TYPES = { { id = "classic", title = "Skateboard", image = true, fields = { { key = "pattern", kind = "choice", convar = "skategm_grip_pattern", choices = { { "None" }, { "Stripes" } }, label = "Grip tape pattern" } } },
		{ id = "model", title = "Any model", fields = {} } },
	EFFECTS = {}, ROLL_SOUNDS = { { "Urethane", "a.wav" }, { "Metal", "b.wav" } }, ROCKET_SOUNDS = { { "Rocket", "r.wav" } } }
function BOARD.Type(id) for _, d in ipairs(BOARD.TYPES) do if d.id == id then return d end end end
BOARD.client = { ImageFiles = function() return { "flame.png" } end, TestSound = function(p) played[#played + 1] = p end, Reset = function() reset = true end }
player_manager = { AllValidModels = function() return { kleiner = "models/kleiner.mdl", alyx = "models/alyx.mdl", barney = "models/barney.mdl" } end }

local pad = { buttons = 0, lx = 0, ly = 0, rx = 0, ry = 0, lt = 0, rt = 0 }
local api = {}
SkateGM = { API = { Pad = function() return pad end, Freeze = function(on) api.frozen = on end, BlockInput = function(on) api.blocked = on end, SetView = function() end } }
SKATEGM_MODES = { menu = { open = false } }

dofile("../../addon/skategm/lua/skategm_ui/cl_pad.lua")
dofile("../../addon/skategm/lua/skategm_ui/cl_settings.lua")
local UI = SKATEGM_UI
local SET, B = UI.settings, UI.pad.B
local now = 0
local function frame(buttons, dt) pad.buttons = buttons or 0 now = now + (dt or 0.05) clock = now UI.Think(now, dt or 0.05) end
local function press(b) frame(b) frame(0) end
local function go(label)
	for _ = 1, 40 do
		local p = SET.Top()
		if UI.List.Rows(p)[p.sel].label == label then return true end
		press(B.DOWN)
	end
end

frame(B.LB)
frame(bit.bor(B.LB, B.A))
frame(0)
local labels = {}
for _, r in ipairs(SET.Top().rows) do labels[#labels + 1] = r.label end
check("LB + A opens Settings: Playermodel, Board, Camera, Display, Advanced", SET.Active() and table.concat(labels, ",") == "Playermodel,Board,Camera,Display,Advanced" and api.frozen and api.blocked)

go("Display")
press(B.A)
local dlabels = {}
for _, r in ipairs(UI.List.Rows(SET.Top())) do dlabels[#dlabels + 1] = r.label end
local dl = table.concat(dlabels, ",")
check("Display: the HUD switch, each HUD part, other players' images", SET.Top().title == "Display" and dl:find("Show the HUD", 1, true) and dl:find("Total score", 1, true)
	and dl:find("Flick-it stick", 1, true) and dl:find("board images", 1, true))
go("Flick-it stick")
press(B.A)
check("... the Flick-it stick (off by default) turns on from there", cvars_.skategm_flickit_hud == "1")
go("Total score")
press(B.A)
check("... and the total score off", cvars_.skategm_hud_total == "0")
press(B.B)
check("B goes back to the main page", SET.Top().title == "Settings")

-- Camera
go("Camera")
press(B.A)
check("Camera has wobble, distance and field of view", SET.Top().title == "Camera" and #SET.Top().rows == 3)
press(B.A)
check("A turns the wobble on", cvars_.skategm_camera_shake == "1")
press(B.DOWN)
press(B.RIGHT)
press(B.RIGHT)
check("D-pad right moves the camera further away", math.abs(tonumber(cvars_.skategm_camera_distance) - 1.2) < 1e-6)
check("... and it reads as further", SET.Top().rows[2].value():find("further", 1, true) ~= nil)
press(B.DOWN)
press(B.RIGHT)
check("field of view: one step from Skate's own is 50 degrees", tonumber(cvars_.skategm_camera_fov) == 50)
press(B.LEFT)
check("... and back to Skate's own (0)", tonumber(cvars_.skategm_camera_fov) == 0)
press(B.B)
check("B goes back to the main page", SET.Top().title == "Settings")

-- Playermodel
go("Playermodel")
press(B.A)
check("the playermodel page has a model preview", type(SET.Top().preview) == "function")
press(B.A)
local names = {}
for _, r in ipairs(SET.Top().rows) do names[#names + 1] = r.label end
check("Model lists every playermodel, the current one picked", table.concat(names, ",") == "alyx,barney,kleiner" and SET.Top().sel == 3)
press(B.UP)
press(B.A)
check("A picks it and goes back", cvars_.cl_playermodel == "barney" and SET.Top().title == "Playermodel")
press(B.DOWN)
press(B.RIGHT)
check("colour: D-pad right picks the next colour", cvars_.cl_playercolor ~= "0.24 0.34 0.41")
press(B.B)

-- Board
local picks, pickStatus, pickValue, added = 0, "open", nil, nil
skategm = { PickImage = function() picks = picks + 1 return true end, PickedImage = function() return pickStatus, pickValue end }
BOARD.client.AddImage = function(name, done) added = name done(name) end
go("Board")
press(B.A)
check("the board page has a board preview", type(SET.Top().preview) == "function")
local rows = {}
for _, r in ipairs(SET.Top().rows) do rows[#rows + 1] = r.label end
local all = table.concat(rows, "|")
check("board options: type, colours, image, the type's own, extras, sounds, reset", all:find("Board type|Deck colour|Wheel colour|Image under the deck|Grip tape pattern|Rocket board|Hoverboard|Rolling sound|Rocket sound|Reset", 1, true) ~= nil)
go("Deck colour")
press(B.RIGHT)
check("deck colour: next in the palette", cvars_.skategm_deck_color == SET.COLOURS[2][2])
go("Image under the deck")
press(B.RIGHT)
check("image: from the images folder", cvars_.skategm_board_image == "flame.png")
go("Image under the deck")
local function imageValue() local p = SET.Top() return UI.List.Rows(p)[p.sel].value() end
press(B.RIGHT)
check("the image list ends with Add new...: landing on it changes nothing yet", imageValue() == "Add new..." and cvars_.skategm_board_image == "flame.png" and picks == 0)
press(B.A)
check("... A there opens the file picker, says so", picks == 1 and SET.note and SET.note.text:find("window", 1, true))
press(B.A)
check("... not twice while it's open", picks == 1)
pickStatus, pickValue = "done", "skull.png"
frame(0)
check("... the picked image is added and chosen", added == "skull.png" and cvars_.skategm_board_image == "skull.png" and SET.note.text:find("added", 1, true))
check("... then asks how it should fit, with an underside preview", SET.Top().title == "Fit the image" and UI.List.Rows(SET.Top())[1].label == "Stretch"
	and UI.List.Rows(SET.Top())[2].label == "Fill" and type(SET.Top().preview) == "function")
press(B.DOWN)
press(B.A)
check("... Fill: set, and back on the Board page", cvars_.skategm_board_image_fit == "2" and SET.Top().title == "Board")
local deleted = {}
BOARD.client.DeleteImage = function(f) deleted[#deleted + 1] = f return true end
cvars_.skategm_board_image = "flame.png"
SET.pending = nil
SET.RefreshBoard()
go("Image under the deck")
local function hintText() for _, hnt in ipairs(UI.List.Hints(SET.stack, UI.List.Rows(SET.Top())[SET.Top().sel], SET.Top())) do if hnt.keys[1] == "X" then return hnt.text end end end
check("an image shown on the row: X deletes it (says so in the hints)", hintText() == "Delete this image")
press(B.X)
check("... the first X only asks to press again", #deleted == 0 and hintText() == "Press again to delete" and SET.note.text:find("again", 1, true))
press(B.RIGHT)
press(B.LEFT)
check("... switching image cancels it: the prompt goes, X asks again", SET.deleteArmed == nil and SET.note == nil and hintText() == "Delete this image" and #deleted == 0)
press(B.X)
press(B.X)
check("... the second deletes it, back to no image", deleted[1] == "flame.png" and cvars_.skategm_board_image == "")
check("... None shown: nothing to delete", hintText() == nil)
pickStatus, pickValue = "idle", nil
SET.PickImage()
pickStatus, pickValue = "failed", "that isn't a PNG or JPG image"
frame(0)
check("... a file that isn't an image: says why", SET.note.text:find("isn't a PNG", 1, true) ~= nil)
pickStatus = "idle"
go("Rolling sound")
press(B.RIGHT)
check("a sound: changed, and played so you hear it", cvars_.skategm_roll_sound == "2" and played[#played] == "b.wav")
go("Board type")
press(B.RIGHT)
check("board type: changed, the page rebuilt for its options (no image row)", cvars_.skategm_board_type == "model" and not table.concat((function() local t = {} for _, r in ipairs(SET.Top().rows) do t[#t + 1] = r.label end return t end)(), "|"):find("Image", 1, true))
go("Reset my board to default")
press(B.A)
check("reset", reset)

-- the right stick turns the preview
local spin = SET.spin
pad.rx = 1
frame(0, 0.5)
pad.rx = 0
check("right stick turns the preview", math.abs(((SET.spin - spin) % 360) - SET.STICK_TURN * 0.5) < 1)
local held = SET.spin
frame(0, 0.5)
check("... and it holds there for a moment, then spins slowly again", SET.spin == held)

press(B.B)
-- Advanced: everything else, in sections
cvars_.skategm_hud, cvars_.skategm_speed_limit, cvars_.skategm_smooth, cvars_.skategm_smooth_creases, cvars_.skategm_smooth_steps = "1", "0", "1", "1", "8"
game = { SinglePlayer = function() return false end }
local admin = false
function LocalPlayer() return { IsValid = function() return true end, IsAdmin = function() return admin end } end
SkateGM.PRESETS = { { "None", 0, 0, 0 }, { "Light", 1, 1, 8 }, { "Strong", 2, 1, 12 } }
SkateGM.ApplyPreset = function(i) local p = SkateGM.PRESETS[i] cvars_.skategm_smooth, cvars_.skategm_smooth_creases, cvars_.skategm_smooth_steps = tostring(p[2]), tostring(p[3]), tostring(p[4]) end
go("Advanced")
press(B.A)
local adv = SET.Top()
local labels2 = {}
for _, r in ipairs(adv.rows) do labels2[#labels2 + 1] = (r.heading and "#" or "") .. r.label end
local all2 = table.concat(labels2, "|")
check("Advanced: screen and sound, riding, collision, engine, park editor, troubleshooting", all2:find("#Screen and sound", 1, true) and all2:find("#Riding", 1, true) and all2:find("#Collision", 1, true) and all2:find("#Engine", 1, true) and all2:find("#Park editor", 1, true) and all2:find("#Troubleshooting", 1, true))
check("... the cursor starts on a setting, not a heading", not adv.rows[adv.sel].heading and adv.rows[adv.sel].label == "Trick score display")
press(B.UP)
check("... and moving skips headings", not adv.rows[adv.sel].heading)
check("... no server section for a player", not all2:find("#Server", 1, true))
go("Smoothing preset")
check("the smoothing preset reads as the current one", adv.rows[adv.sel].value() == "Light")
press(B.RIGHT)
check("... and changing it applies the preset", cvars_.skategm_smooth == "2" and cvars_.skategm_smooth_steps == "12")
go("Bumpy terrain")
check("0-based settings read right (smooth 2 = strong)", adv.rows[adv.sel].value() == "strong")
press(B.LEFT)
check("... and set right (light = 1)", cvars_.skategm_smooth == "1")
go("Top speed")
press(B.RIGHT)
check("top speed in steps of 5 m/s", cvars_.skategm_speed_limit == "5")
press(B.B)
admin = true
go("Advanced")
press(B.A)
local labels3 = {}
for _, r in ipairs(SET.Top().rows) do labels3[#labels3 + 1] = r.label end
check("an admin also gets the server section", table.concat(labels3, "|"):find("Server (host and admins)", 1, true) ~= nil)
press(B.B)
press(B.B)
check("B on the main page closes Settings, control back", not SET.Active() and api.frozen == false and api.blocked == false)
