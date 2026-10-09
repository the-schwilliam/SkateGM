dofile("gmock.lua")
local sent = {}
util = setmetatable({ TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
local receivers = {}
net = { Start = function() end, WriteString = function(t) sent[#sent + 1] = t end, SendToServer = function() end, Receive = function(n, f) receivers[n] = f end, ReadString = function() end }
hook = { Add = function() end }
concommand = { Add = function() end }
function IsValid(x) return x ~= nil and (type(x) ~= "table" or x.removed ~= true) end
surface = surface or {}
surface.PlaySound = function() end
sound = { Play = function() end }
function EffectData() return { SetOrigin = function() end } end
util.Effect = function() end
local models = {}
function ClientsideModel() local e = {} models[#models + 1] = e function e:SetModelScale() end function e:SetRenderMode() end function e:SetColor() end function e:SetPos(p) self.pos = p end function e:SetAngles() end function e:Remove() self.removed = true end return e end
RENDERMODE_TRANSALPHA = 4
function ScrW() return 1600 end
local clock = 0
function RealTime() return clock end
function ScrH() return 900 end
local ME = { EntIndex = function() return 2 end }
local BOB = { EntIndex = function() return 1 end }
local CAT = { EntIndex = function() return 3 end }
function LocalPlayer() return ME end
function Entity(i) return ({ [1] = BOB, [2] = ME, [3] = CAT })[i] end
local api = { pad = 0, pos = Vector(0, 0, 0) }
SkateGM = { API = {
	IsSkating = function() return true end, SkaterPos = function() return api.pos end, Pad = function() return { buttons = api.pad } end,
	Wipeout = function() api.wiped = true return true end, Freeze = function(on) api.frozen = on end, SetButtonMask = function(b) api.mask = b end,
	PoseOf = function(p) if p == BOB then return { HIPS = Vector(500, 0, 0) } elseif p == CAT then return { HIPS = Vector(500, 300, 0) } end end,
	View = function() return { angles = Angle(0, 0, 0) } end, Say = function() end,
} }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_items/sh_items.lua")
dofile("../../addon/skategm/lua/skategm_items/cl_items.lua")
dofile("../../addon/skategm/lua/skategm_itemdefs/rocket.lua")
dofile("../../addon/skategm/lua/skategm_itemdefs/cone.lua")
local C = ITEMS.client
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local mode = SKATEGM_MODES.Register({ id = "itemtest", title = "Item test" })
mode.state = { phase = "playing", host = 1, players = { { ent = 1 }, { ent = 2 }, { ent = 3 } } }
local screen = { [1] = { x = 800, y = 450, visible = true }, [3] = { x = 1300, y = 450, visible = true } }
local V = getmetatable(Vector(0, 0, 0))
V.ToScreen = function(v) if v.y > 100 then return screen[3] end return screen[1] end
C.Handle({ k = "arena", a = "itemtest:0", m = "itemtest", crates = { { 1, 0, 0, 0 }, { 2, 900, 0, 0 } } }, 0)
C.Think(1)
check("in a game with items: the left stick is kept from the engine", api.mask == ITEMS.BUTTON)
local picked
for _, m in ipairs(sent) do if m.k == "pick" then picked = m end end
check("skating through a crate asks the server for it (the far one isn't)", picked and picked.i == 1)
C.Handle({ k = "hold", e = 2, id = "rocket", uses = 1 }, 1)
C.Think(2)
check("holding the rocket: aimed at the player nearest the middle of the view", C.aim == BOB)
check("... the item takes the corner where the total score was", ITEMS.client.CornerTaken() == true)
api.pad = ITEMS.BUTTON
C.Think(3)
check("left stick in: fired at Bob", sent[#sent].k == "use" and sent[#sent].target == 1)
api.pad = 0
C.Think(3.1)
C.Handle({ k = "hit" }, 4)
check("hit: my skater bails", api.wiped == true)
C.Handle({ k = "freeze", s = 2 }, 4)
check("frozen by a physics gun ...", api.frozen == true)
clock = 10
C.Think(10)
check("... and free again after", api.frozen == false)
C.Handle({ k = "hold", e = 2 }, 5)
C.Handle({ k = "fx", a = "itemtest:0", item = "cone", id = 7, p = { 10, 10, 0 } }, 5)
check("everyone sees a dropped cone", ITEMS.Get("cone") ~= nil)
local before = #models
ITEMS.Get("cone").draw(5.1)
local cone = models[#models]
check("... drawn as a model", #models == before + 1)
C.Handle({ k = "close", a = "itemtest:0" }, 6)
check("the game closed: its cone goes too", cone.removed == true)
ITEMS.Get("cone").draw(6.1)
check("... and isn't drawn again", #models == before + 1)
mode.state = { phase = "results", host = 1, players = {} }
C.Think(7)
check("the game over: the left stick goes back to the engine", api.mask == 0)
ITEMS.Register({ id = "mine", title = "Land Mine", model = "models/props_combine/combine_mine01.mdl", use = function() end })
check("an add-on's item joins the list like any other", ITEMS.Get("mine") and ITEMS.order[#ITEMS.order] == "mine")
