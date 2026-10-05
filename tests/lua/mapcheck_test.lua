dofile("gmock.lua")
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
gameevent = nil
local MC = dofile("../../addon/skategm/lua/autorun/server/skategm_mapcheck.lua")
local map = "sgm_skate3_maloof"

MC.Connected(5)
local line = MC.Disconnected({ userid = 5, name = "Ann", reason = "Your map [maps/sgm_skate3_maloof.bsp] differs from the server's." }, map)
check("a friend whose map differs: everyone is told why, and the fix", line and line:find("Ann couldn't join", 1, true) and line:find("Generate maps", 1, true))
MC.Connected(6)
line = MC.Disconnected({ userid = 6, name = "Bob", reason = "Disconnect by user." }, map)
check("left while loading for another reason: the hint, worded as a maybe", line and line:find("left while loading", 1, true) and line:find("If ", 1, true))
MC.Connected(7)
MC.Spawned(7)
check("someone leaving after they got in: nothing", MC.Disconnected({ userid = 7, name = "Cy", reason = "Disconnect by user." }, map) == nil)
MC.Connected(8)
check("other maps: nothing (only the generated Skate 3 maps can differ)", MC.Disconnected({ userid = 8, name = "Di", reason = "differs" }, "gm_construct") == nil)
MC.Connected(9)
check("bots: nothing", MC.Disconnected({ userid = 9, name = "Bot", bot = 1, reason = "differs" }, map) == nil)
