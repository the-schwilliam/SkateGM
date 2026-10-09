dofile("gmock.lua")
local ME = { EntIndex = function() return 3 end }
function LocalPlayer() return ME end
skategm = { SetFrozen = function() end, SetInputBlocked = function() end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local A = SkateGM.API
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
local M = SKATEGM_MODES
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local pos, tele, outs = Vector(0, 0, 0), nil, 0
A.SkaterPos = function() return pos end
A.IsSkating = function() return true end
A.Say = function() end
A.TeleportTo = function(p, y) tele = { p = p, y = y } return true end
local mode = M.Register({ id = "boundtest", title = "Boundary test" })
mode:Boundary(function(st) return { area = { 0, 0, 0, 500 }, pos = Vector(10, 20, 0), yaw = 90, out = function() outs = outs + 1 end } end)
mode.state = { phase = "playing", players = { { ent = 3 } } }
M.BoundaryThink(10)
check("inside the wall: nothing", M.BoundaryFade(10) == 0)
pos = Vector(600, 0, 0)
M.BoundaryThink(11)
M.BoundaryThink(12.5)
check("outside it: the screen fades to black", math.abs(M.BoundaryFade(12.5) - 0.5) < 0.01 and outs == 0 and tele == nil)
pos = Vector(400, 0, 0)
M.BoundaryThink(13)
check("back inside before it's black: nothing happened", M.BoundaryFade(13) == 0 and outs == 0 and tele == nil)
pos = Vector(600, 0, 0)
M.BoundaryThink(14)
M.BoundaryThink(17.1)
check("fully black: the game's penalty, and back to the start", outs == 1 and tele and tele.p.x == 10 and tele.y == 90)
check("... once", M.BoundaryFade(17.1) == 0)
mode.state = { phase = "lobby", players = { { ent = 3 } } }
pos = Vector(600, 0, 0)
M.BoundaryThink(20)
M.BoundaryThink(25)
check("a lobby has no wall", outs == 1)
mode.state = { phase = "idle" }
