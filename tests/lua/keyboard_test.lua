dofile("gmock.lua")
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local n = 0
for _, k in ipairs({ "W", "A", "S", "D", "SPACE", "LSHIFT", "F", "Z", "C", "I", "K", "U", "O", "ENTER", "Q", "E", "LEFT", "RIGHT", "UP", "DOWN", "LALT", "R", "L", "T", "Y", "LCONTROL", "BACKSPACE" }) do
	n = n + 1
	_G["KEY_" .. k] = n
end
local enabled = "1"
CreateClientConVar = function(name, default)
	return { GetBool = function() if name == "skategm_keyboard" then return enabled == "1" end return default == "1" end }
end
local down = {}
input = { IsKeyDown = function(k) return down[k] == true end }
gui = { IsGameUIVisible = function() return false end }
vgui = { CursorVisible = function() return false end }
system = { HasFocus = function() return true end }
local steps = {}
skategm = { Step = function(...) steps[#steps + 1] = { ... } end }
local K = dofile("../../addon/skategm/lua/skategm/cl_keyboard.lua")

check("the keys it uses are known (so GMod's binds on them are blocked)", K.Uses(KEY_U) and K.Uses(KEY_ENTER) and K.Uses(KEY_W) and not K.Uses(KEY_T) and not K.Uses(KEY_Y))
local S = {}
down[KEY_W] = true
K.Step(S, { state = "Riding" }, 0.016)
local s = steps[#steps]
check("W pushes (A on the pad) and the keyboard drives the engine while used", s[2] == false and bit.band(s[3], 0x1000) ~= 0 and S.keyboardActive)
down[KEY_W] = nil
down[KEY_ENTER] = true
down[KEY_RIGHT] = true
K.Step(S, { state = "Riding" }, 0.016)
s = steps[#steps]
check("Enter is Start, the arrows are the right stick", bit.band(s[3], 0x10) ~= 0 and s[8] == 1)
down = { [KEY_LCONTROL] = true }
K.Step(S, { state = "Riding" }, 0.016)
s = steps[#steps]
check("Ctrl is the right stick click (the rocket board), seen by the add-on too", bit.band(s[3], 0x80) ~= 0 and S.keyboardButtons == s[3] and K.Uses(KEY_LCONTROL))
down = {}
K.Step(S, { state = "Riding" }, 0.016)
K.Step(S, { state = "Riding" }, 0.016)
s = steps[#steps]
check("nothing held: the pad is read again", s[2] == true and not S.keyboardActive)
enabled = "0"
down[KEY_W] = true
K.Step(S, { state = "Riding" }, 0.016)
s = steps[#steps]
check("turned off (skategm_keyboard 0): keys do nothing, the pad still works", s[2] == true and s[3] == 0 and not K.Uses(KEY_W))

local style = 0
CreateClientConVar = function() return { GetInt = function() return style end, GetBool = function() return false end, GetFloat = function() return 0 end, GetString = function() return "0" end } end
local hints = false
SkateGM = { API = { PadType = function() return nil end, KeyboardHints = function() return hints end } }
dofile("../../addon/skategm/lua/skategm_ui/cl_pad.lua")
local PAD = SKATEGM_UI.pad
check("pad hints: button names stay", PAD.T("LB + A > Settings") == "LB + A > Settings")
hints = true
check("keyboard hints: texts name the keys", PAD.T("LB + A > Settings") == "Z + Space > Settings" and PAD.T("press (B)") == "press (S)")
check("... the D-pad too: LB + D-pad left reads Z + U", PAD.T("join with LB + D-pad left") == "join with Z + U")

enabled = "1"
down = { [KEY_W] = true }
local v, active = K.Read("Riding", false, true)
check("in a menu (map, park editor): W is the left stick forward, not push", v[5] == 1 and bit.band(v[1], 0x1000) == 0)
down = { [KEY_S] = true }
v = K.Read("Riding", false, true)
check("... S backwards, not B", v[5] == -1 and bit.band(v[1], 0x2000) == 0)
down = { [KEY_BACKSPACE] = true }
v = K.Read("Riding", false, true)
check("... Backspace is B (back)", bit.band(v[1], 0x2000) ~= 0 and K.Uses(KEY_BACKSPACE))
down = { [KEY_W] = true }
v = K.Read("Riding", false, false)
check("riding: W still pushes", bit.band(v[1], 0x1000) ~= 0 and v[5] == 0)
SKATEGM_UI.open = "map"
check("menu hints name Backspace for B", PAD.T("press (B)") == "press (Backspace)")
SKATEGM_UI.open = nil

K.look = Angle(10, 20, 0)
K.Decorate(S, { pad = true, padButtons = 0, padLX = 0.6, padLY = 0, padRX = 0, padRY = 0, padLT = 0, padRT = 0 })
check("using the controller drops the mouse free camera", K.look == nil and K.owner == "hardware")
K.look = Angle(10, 20, 0)
K.Decorate(S, { pad = true, padButtons = 0, padLX = 0.05, padLY = 0, padRX = 0, padRY = 0, padLT = 0, padRT = 0 })
check("... but a resting stick doesn't", K.look ~= nil)
