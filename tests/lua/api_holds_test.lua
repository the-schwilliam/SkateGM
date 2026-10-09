dofile("gmock.lua")
local frozenCalls = {}
skategm = { SetFrozen = function(v) frozenCalls[#frozenCalls + 1] = v end, SetInputBlocked = function() end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
local A = S.API
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
A.Freeze(true, "ui")
A.Freeze(true, "boardgolf")
A.Freeze(false, "ui")
check("two holds on the skater, one lets go: still frozen", A.IsFrozen() and frozenCalls[#frozenCalls] == 1)
A.Freeze(false, "boardgolf")
check("... both let go: free", not A.IsFrozen() and frozenCalls[#frozenCalls] == 0)
A.Freeze(true)
A.Freeze(false)
check("an old caller without a reason still works", not A.IsFrozen())
A.BlockInput(true, "menu")
A.BlockInput(true, "spectate")
A.BlockInput(false, "menu")
check("input blocks work the same way", S.inputBlocked == true)
A.BlockInput(false, "spectate")
check("... and clear when the last one lets go", not S.inputBlocked)
dofile("../../addon/skategm/lua/skategm_ui/cl_pad.lua")
local UI = SKATEGM_UI
local playing = false
SKATEGM_MODES = { Playing = function() return playing end }
UI.Take("settings", {})
check("a menu in free skate: the skater stops", A.IsFrozen())
UI.Give("settings")
playing = true
UI.Take("settings", {})
check("a menu during a minigame: the skater keeps going", not A.IsFrozen())
UI.Give("settings")
playing = false
UI.Take("minigames", {})
playing = true
UI.Think(1, 0.016)
check("a minigame starts while the menu has me stopped: let go", not A.IsFrozen())
UI.Give("minigames")
