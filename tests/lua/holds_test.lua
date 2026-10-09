dofile("gmock.lua")
local ME = { EntIndex = function() return 3 end }
function LocalPlayer() return ME end
RealTime = RealTime or function() return 0 end
skategm = { SetFrozen = function() end, SetInputBlocked = function() end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S, A = SkateGM, SkateGM.API
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local replay, menu = function() return "replay" end, function() return "menu" end
A.SetView(replay, "copycat_replay")
A.SetView(nil, "ui")
check("a menu without a camera of its own leaves a minigame's camera alone", S.viewOverride == replay)
A.SetView(menu, "ui")
check("a menu with its own camera shows it while it's open", S.viewOverride == menu)
A.SetView(nil, "ui")
check("... and closing it brings the minigame's camera back", S.viewOverride == replay)
A.ReleaseHolds("copycat")
check("the game's holds released: its camera goes too", S.viewOverride == nil)
A.SetPlayerCollision(false, "race_solid")
A.SetPlayerCollision(nil, "boardgolf_gone")
check("one game turning collision back on doesn't undo another's", S.noPlayerCollision == true)
A.HideOthers(true, "copycat_apart")
A.HideOthers(false, "freezeframe_show")
check("... nor hiding the others", S.hideOthers == true)
A.ReleaseHolds("race")
A.ReleaseHolds("copycat")
check("released by name: solid and seen again", S.noPlayerCollision == nil and S.hideOthers == nil)
