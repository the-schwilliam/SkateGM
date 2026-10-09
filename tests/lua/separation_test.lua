dofile("gmock.lua")
local ME = { EntIndex = function() return 3 end }
function LocalPlayer() return ME end
RealTime = RealTime or function() return 0 end
skategm = { SetFrozen = function() end, SetInputBlocked = function() end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
local M = SKATEGM_MODES
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local function P(i) return { EntIndex = function() return i end, GetNW2Bool = function() return false end } end
local ANN, BOB = P(1), P(2)
local realValid = IsValid
IsValid = function(x) return x == ANN or x == BOB or realValid(x) end
local mode = M.Register({ id = "septest", title = "Separation test" })
local clock = 0
local function now() clock = clock + 1 return clock end
mode.state = { phase = "playing", players = { { ent = 3 }, { ent = 1 } } }
M.PlayMap(now())
check("I'm playing with Ann: she's there as usual", M.Separation(ANN) == nil and not S.IsHidden(ANN))
check("... Bob isn't in our game: hidden from me, and not solid", M.Separation(BOB) == "hide" and S.IsHidden(BOB))
mode.state = { phase = "playing", players = { { ent = 1 } } }
M.PlayMap(now())
check("I'm free skating, Ann's in a game: see-through, not solid", M.Separation(ANN) == "ghost" and not S.IsHidden(ANN))
check("... Bob (free skating too) as usual", M.Separation(BOB) == nil)
mode.state = { phase = "lobby", players = { { ent = 3 }, { ent = 1 } } }
M.PlayMap(now())
check("a game's lobby keeps nobody apart", M.Separation(ANN) == nil and M.Separation(BOB) == nil)
IsValid = realValid
SKATEGM_UI = SKATEGM_UI or {}
SKATEGM_UI.open = "settings"
check("a menu open (settings): game HUDs step aside", M.HudHidden())
SKATEGM_UI.open = "freezeframe"
check("... a minigame's own screen (Freeze Frame's photo) isn't a menu", not M.HudHidden())
SKATEGM_UI.open = nil
check("... nothing open: HUDs drawn", not M.HudHidden())
