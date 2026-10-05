dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
local globals = { SkateGMBoundary = "0,0;1000,0;1000,1000;0,1000" }
function GetGlobal2String(k, d) return globals[k] or d end
concommand = { Add = function() end }
local me = { pos = Vector(500, 500, 0) }
function me:GetPos() return self.pos end
function LocalPlayer() return me end
function IsValid(x) return x ~= nil end
SkateGM = {}
local B = dofile("../../addon/skategm/lua/skategm/cl_boundary.lua")

B.Load()
check("a Skate 3 map's boundary arrives from its info entity (four edges)", B.edges and #B.edges == 4)
check("in the middle of the map: no border shown", #B.Panels(Vector(500, 500, 0)) == 0)
local near = B.Panels(Vector(500, 100, 0))
check("10 m (394 units) from an edge: that edge shows", #near == 1 and near[1].alpha > 0)
local closer = B.Panels(Vector(500, 20, 0))
check("... more solid the closer you get", closer[1].alpha > near[1].alpha)
check("... only the stretch near you, not the whole edge", (closer[1].b - closer[1].a):Length2D() <= B.SPAN + 1)
check("in a corner: both edges show", #B.Panels(Vector(30, 30, 0)) == 2)
local far = B.Panels(Vector(500, 380, 0))
check("fades in slowly: barely there near 10 m, full right at the wall", far[1].alpha < 0.05 and B.Panels(Vector(500, 30, 0))[1].alpha > 0.99)
local c = closer[1].centre
check("a circle: solid at its middle, gone at its rim, soft in between", B.Weight(c, c) == 1 and B.Weight(c + Vector(0, 0, B.RADIUS), c) == 0
	and B.Weight(c + Vector(B.RADIUS * 0.7, 0, 0), c) > 0 and B.Weight(c + Vector(B.RADIUS * 0.7, 0, 0), c) < 1)
local corner = B.Panels(Vector(30, 30, 0))
check("... one circle across a corner (both edges share its middle)", corner[1].centre == corner[2].centre)
globals.SkateGMBoundary = nil
B.Load()
check("maps without a boundary: nothing", B.edges == nil and #B.Panels(Vector(10, 10, 0)) == 0)
local rows = B.BandRows(100)
check("minigame ring: always a band at the area's height, soft at top and bottom", rows[1][2] == 0 and rows[#rows][2] == 0 and rows[2][2] == 1
	and rows[1][1] < 100 and rows[#rows][1] > 100)
