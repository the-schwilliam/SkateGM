dofile("gmock.lua")
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
function ScrW() return 1600 end
function ScrH() return 900 end

local style = 0
CreateClientConVar = function() return { GetInt = function() return style end, GetBool = function() return false end, GetFloat = function() return 0 end, GetString = function() return tostring(style) end } end
local padType
SkateGM = { API = { PadType = function() return padType end } }

local texts, shapes = {}, {}
draw = draw or {}
draw.SimpleText = function(t) texts[#texts + 1] = t end
draw.RoundedBox = function() shapes[#shapes + 1] = "box" end
draw.NoTexture = function() end
surface = surface or {}
surface.SetDrawColor = function() end
surface.DrawRect = function() shapes[#shapes + 1] = "rect" end
surface.DrawPoly = function() shapes[#shapes + 1] = "poly" end
surface.DrawTexturedRectRotated = function() shapes[#shapes + 1] = "line" end
surface.CreateFont = function() end

dofile("../../addon/skategm/lua/skategm_ui/cl_pad.lua")
local PAD = SKATEGM_UI.pad

check("an Xbox pad (or none): Xbox icons", PAD.Style() == "xbox" and PAD.T("LB + D-pad left") == "LB + D-pad left")
padType = "playstation"
check("a PlayStation pad: PlayStation icons", PAD.Style() == "playstation")
check("... text names its buttons: LB + D-pad left", PAD.T("you're the host: LB + D-pad left to start") == "you're the host: L1 + D-pad left to start")
check("... LB + X, LB + RB, (A)", PAD.T("LB + X") == "L1 + Square" and PAD.T("LB + RB > Replays") == "L1 + R1 > Replays" and PAD.T("press (A)") == "press (Cross)")
check("... ordinary words left alone", PAD.T("A race, an ALB, Bingo X") == "A race, an ALB, Bingo X")
texts, shapes = {}, {}
PAD.Glyph("Y", 0, 0, 20)
check("... the face buttons are drawn as shapes, not letters: triangle", #texts == 0 and shapes[#shapes] == "poly")
shapes = {}
PAD.Glyph("A", 0, 0, 20)
check("... cross", shapes[#shapes] == "line" and shapes[#shapes - 1] == "line")
texts = {}
PAD.Glyph("LB", 0, 0, 20)
check("... shoulders read L1 / R1", texts[1] == "L1")
padType = "nintendo"
texts = {}
PAD.Glyph("A", 0, 0, 20)
check("a Switch pad: the bottom button reads B (Nintendo's layout)", texts[1] == "B")
texts = {}
PAD.Glyph("RT", 0, 0, 20)
check("... triggers ZL / ZR", texts[1] == "ZR" and PAD.T("LB + Y") == "L + X")
style = 2
check("the setting overrides it (PlayStation pad through Steam Input looks like Xbox)", PAD.Style() == "playstation")
style = 1
check("... or forces Xbox icons", PAD.Style() == "xbox")
texts = {}
style = 2
PAD.Text("LB + A", "f", 0, 0)
check("menu text goes through the same names", texts[#texts] == "L1 + Cross")

surface.SetFont = function() end
surface.GetTextSize = function(t) return #t * 8, 14 end
draw.RoundedBox = function() end
local many = {}
for i = 1, 14 do many[i] = { keys = { "A" }, text = "Some action " .. i } end
check("a long hint bar wraps onto more lines instead of running off the screen", PAD.Legend(many, 1600, 900, "bottom") >= 2 and PAD.Legend({ many[1] }, 1600, 900, "bottom") == 1)

local boxes, lastText = {}, nil
draw.RoundedBox = function(_, x, y, w, h) boxes[#boxes + 1] = { x = x, w = w } end
draw.SimpleText = function(t, font, x) texts[#texts + 1] = t lastText = { t = t, x = x } end
PAD.GLYPHS.Y = PAD.GLYPHS.Y
local wide = { { keys = { "LB", "LS" }, join = "+", text = "Trim start" }, { keys = { "LB", "RS" }, join = "+", text = "Trim end" }, { keys = { "LB", "LEFT" }, join = "+", text = "Previous keyframe" }, { keys = { "LB", "RIGHT" }, join = "+", text = "Next keyframe" }, { keys = { "LB", "Y" }, join = "+", text = "Delete nearest keyframe" } }
boxes = {}
style = 1
PAD.Legend(wide, 1600, 900, "bottom")
local box = boxes[1]
check("the bar's box reaches past its last words (wide LB buttons counted)", box and lastText and lastText.t == "Delete nearest keyframe" and lastText.x + #lastText.t * 8 <= box.x + box.w)
local List = SKATEGM_UI.List
local above, below = List.ScrollInfo(1, 9, 18)
local a2, b2 = List.ScrollInfo(5, 9, 18)
local a3, b3 = List.ScrollInfo(10, 9, 18)
check("long lists say how many more rows are above / below", above == 0 and below == 9 and a2 == 4 and b2 == 5 and a3 == 9 and b3 == 0)
surface.GetTextSize = function(t) return #t * 8, 14 end
local fit = List.Fit("a very long description of the minigame", "f", 120)
check("a description too long for its row is cut short with ...", #fit * 8 <= 120 and fit:sub(-3) == "..." and List.Fit("short", "f", 120) == "short")
local UI = SKATEGM_UI
local opened = {}
UI.Combo(PAD.B.LEFT, { open = function() opened[#opened + 1] = "minigames" end, whileWatching = true })
UI.Combo(PAD.B.RB, { open = function() opened[#opened + 1] = "replays" end, label = "replay" })
SKATEGM_MODES = SKATEGM_MODES or {}
SKATEGM_MODES.spectate = { on = true }
UI.Press(PAD.B.RB, bit.bor(PAD.B.LB, PAD.B.RB))
UI.Press(PAD.B.LEFT, bit.bor(PAD.B.LB, PAD.B.LEFT))
check("watching someone: only the minigame menu opens (no replays)", #opened == 1 and opened[1] == "minigames")
SKATEGM_MODES.spectate.on = nil
UI.Press(PAD.B.RB, bit.bor(PAD.B.LB, PAD.B.RB))
check("... and everything again once not watching", opened[2] == "replays")
