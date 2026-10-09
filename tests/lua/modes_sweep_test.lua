dofile("gmock.lua")
local ME = { EntIndex = function() return 3 end }
function LocalPlayer() return ME end
skategm = { SetFrozen = function() end, SetInputBlocked = function() end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local A = SkateGM.API
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
local M = SKATEGM_MODES
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local mode = M.Register({ id = "golfy", title = "Golfy" })
A.Freeze(true, "golfy_cam")
A.Freeze(true, "ui")
A.BlockInput(true, "golfy")
A.SetHidden("golfy", true)
check("a closed game's leftovers are released by name", A.ReleaseHolds("golfy") and SkateGM.freezeWhy.golfy_cam == nil and not SkateGM.inputBlocked and not SkateGM.IsHidden())
check("... others' holds (a menu) are left alone", A.IsFrozen() and SkateGM.freezeWhy.ui)
A.Freeze(false, "ui")
A.Freeze(true, "golfy_cam")
mode.state = { phase = "roll", players = { { ent = LocalPlayer():EntIndex() } } }
M.Sweep(10)
check("still in the game: the sweep leaves it", A.IsFrozen())
mode.state = { phase = "idle" }
M.Sweep(10.5)
check("... (once a second)", A.IsFrozen())
M.Sweep(11.1)
check("in no game any more: nothing a game held stays held", not A.IsFrozen())
