dofile("gmock.lua")
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local ply = { GetModel = function() return "models/custom/fancy.mdl" end, GetPlayerColor = function() return Vector(1, 0, 0) end,
	GetSkin = function() return 3 end, GetNumBodyGroups = function() return 2 end, GetBodygroup = function() return 1 end,
	GetNW2String = function(_, k, d) return k == "skategm_look" and "{\"d\":\"255 0 0\"}" or d end, Nick = function() return "Ann" end,
	GetNW2Bool = function() return false end }
function IsValid(x) return x ~= nil end
local ME = {}
function LocalPlayer() return ME end
local real = S.ClipProxy(ply, false)
local plain = S.ClipProxy(ply, true)
check("a replay ghost normally looks like its skater", real:GetModel() == "models/custom/fancy.mdl" and real:GetNW2String("skategm_look", "") ~= "")
check("plain: the same playermodel, colour, skin, bodygroups for everyone", plain:GetModel() == S.PLAIN_MODEL and plain:GetSkin() == 0 and plain:GetNumBodyGroups() == 0 and plain:GetPlayerColor().x == 0.6)
check("... and the default board (no board look at all), no name", plain:GetNW2String("skategm_look", "") == "" and plain:Nick() == "?")
S.API.HideOthers(true)
check("hiding the others: other skaters hidden, replay ghosts still shown", S.IsHidden(ply) == true and S.IsHidden(plain) == false)
S.API.HideOthers(false)
check("... and back", S.IsHidden(ply) == false)
RealTime = RealTime or function() return 0 end
S.API.PlayClip("alphatest", ply, { { t = 0, P = {} }, { t = 1, P = {} } }, { alpha = 0.45 })
check("a clip can be played see-through (Copycat's setter ghost)", S.clips.alphatest.key.alpha == 0.45)
S.API.PlayClip("alphatest2", ply, { { t = 0, P = {} } })
check("... others are drawn solid", S.clips.alphatest2.key.alpha == nil)
S.API.StopClip("alphatest") S.API.StopClip("alphatest2")
local BOB = { Nick = function() return "Bob" end, GetNW2Bool = function() return false end }
local realValid = IsValid
IsValid = function(x) return x ~= nil and (x == BOB or realValid(x)) end
S.cvNametags = { GetBool = function() return true end }
check("name tags: over another skater, by default", S.NametagFor(BOB) == "Bob")
S.cvNametags = { GetBool = function() return false end }
check("... none with the setting off", S.NametagFor(BOB) == nil)
S.cvNametags = { GetBool = function() return true end }
SKATEGM_MODES = SKATEGM_MODES or {}
SKATEGM_MODES.spectate = { on = true }
check("... not while watching a minigame", S.NametagFor(BOB) == nil)
S.API.PlayClip("tagtest", ply, { { t = 0, P = {} } }, { nametag = "Ann" })
check("... but a replay's clip that asks for one has it (Copycat's setter)", S.NametagFor(S.clips.tagtest.key) == "Ann")
S.API.PlayClip("tagtest2", ply, { { t = 0, P = {} } })
check("... and other clips don't", S.NametagFor(S.clips.tagtest2.key) == nil)
SKATEGM_MODES.spectate.on = nil
S.API.StopClip("tagtest") S.API.StopClip("tagtest2")
IsValid = realValid
local box
local ent = { SetRenderBoundsWS = function(_, a, b) box = { a, b } end }
S.FitBounds(ent, { HIPS = Vector(0, 0, 40), SKATEBOARD_ROOT = Vector(900, -50, 2) })
check("a skater's draw bounds reach their board, however far it rolled", box and box[2].x >= 900 and box[1].y <= -50 and box[1].z <= 2)
local CAL = { Nick = function() return "Cal" end, GetNW2Bool = function(_, k) return k == "SkateGMInMenu" end }
IsValid = function(x) return x ~= nil and (x == CAL or realValid(x)) end
S.cvNametags = { GetBool = function() return true end }
check("a skater stopped in a menu: drawn faded", S.InMenu(CAL) and S.IN_MENU_ALPHA < 1)
S.remote[CAL] = { snaps = { { t = 0, P = { HIPS = Vector(0, 0, 40), HEAD = Vector(0, 0, 70) } } }, last = 0 }
local tags = S.Nametags(0)
local tag
for _, t in ipairs(tags) do if t.text == "Cal" then tag = t end end
check("... and their name tag says (in a menu)", tag ~= nil and tag.sub == "(in a menu)")
S.remote[CAL] = nil
IsValid = realValid
