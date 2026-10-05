dofile("gmock.lua")
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
scripted_ents = { Register = function() end }
local partFiles = {}
for _, f in ipairs({ "deck", "quarter_pipe" }) do partFiles[#partFiles + 1] = f .. ".lua" end
file = { Find = function() return partFiles end, CreateDir = function() end, Write = function() end, Read = function() end }
function include(f) dofile("../../addon/skategm/lua/" .. f) end
function AddCSLuaFile() end
function IsValid(x) return x ~= nil and (type(x) ~= "table" or not x.IsValid or x:IsValid()) end
game = { SinglePlayer = function() return false end }
timer = { Simple = function(_, f) f() end }

-- net: handlers by name; a message is read back from a queue
local handlers, queue, out = {}, {}, {}
local current
local function pop() return table.remove(queue, 1) end
net = {
	Receive = function(name, f) handlers[name] = f end,
	ReadBool = pop, ReadString = pop, ReadVector = pop, ReadFloat = pop, ReadAngle = pop, ReadEntity = pop,
	Start = function(name) current = { name = name } end,
	WriteBool = function(v) current[#current + 1] = v end,
	WriteEntity = function(v) current[#current + 1] = v end,
	WriteVector = function(v) current[#current + 1] = v end,
	WriteAngle = function(v) current[#current + 1] = v end,
	Send = function(to) current.to = to out[#out + 1] = current end,
	SendOmit = function(omit) current.omit = omit out[#out + 1] = current end,
}
local function send(ply, name, ...)
	queue = { ... }
	handlers[name](0, ply)
end
hook = { Add = function() end, Run = function() end, Call = function() end }

-- entities
local world = {}
ents = {
	GetAll = function() return world end,
	FindInSphere = function() return world end,
	Create = function(class)
		local e = { class = class, PartId = class:gsub("^skategm_part_", ""), SkateGMPart = true, nw = {} }
		function e:IsValid() return not self.removed end
		function e:SetPos(p) self.pos = p end
		function e:GetPos() return self.pos end
		function e:SetAngles(a) self.ang = a end
		function e:GetAngles() return self.ang end
		function e:Spawn() world[#world + 1] = self end
		function e:Activate() end
		function e:SetNW2Entity(k, v) self.nw[k] = v end
		function e:GetPhysicsObject() return nil end
		function e:Remove() self.removed = true for i, o in ipairs(world) do if o == self then table.remove(world, i) break end end end
		return e
	end,
}
local function Player(name, admin)
	local p = { name = name, admin = admin, said = {}, nw = {} }
	function p:IsValid() return true end
	function p:IsAdmin() return self.admin end
	function p:GetPos() return Vector(0, 0, 0) end
	function p:ChatPrint(t) self.said[#self.said + 1] = t end
	function p:SetNW2Bool(k, v) self.nw[k] = v end
	function p:CheckLimit() return true end
	function p:AddCleanup() end
	function p:AddCount() end
	return p
end

SERVER, CLIENT = true, false
dofile("../../addon/skategm/lua/autorun/skategm_parts_load.lua")
local P = SKATEGM_PARTS
local ED = P.editorServer

local amy, bob, admin = Player("amy"), Player("bob"), Player("admin", true)

-- who may edit
send(amy, "skategm_editor_state", true)
check("anyone can open the editor by default", amy.SkateGMEditing == true and amy.nw.SkateGMEditing == true)
MOCK_SET_CVAR("skategm_park_editor", 2)
out = {}
send(bob, "skategm_editor_state", true)
check("set to admins only, a player is turned away (and told)", not bob.SkateGMEditing and out[1] and out[1].name == "skategm_editor_state" and out[1][1] == false and #bob.said == 1)
send(admin, "skategm_editor_state", true)
check("... an admin isn't", admin.SkateGMEditing == true)
MOCK_SET_CVAR("skategm_park_editor", 1)

-- placing
send(amy, "skategm_editor_place", "deck_96x128", Vector(100, 50, 0), 90)
local deck = world[#world]
check("a part is placed where the editor says, owned by its placer", deck and deck.PartId == "deck_96x128" and deck.pos.x == 100 and deck.ang.y == 90 and deck.SkateGMOwner == amy)
local n = #world
send(bob, "skategm_editor_place", "deck_96x128", Vector(0, 0, 0), 0)
check("... but not by someone who isn't in the editor", #world == n)
send(amy, "skategm_editor_place", "no_such_part", Vector(0, 0, 0), 0)
check("... nor a part that doesn't exist", #world == n)

-- moving and removing: shared by default, otherwise your own (admins always)
send(bob, "skategm_editor_state", true)
send(bob, "skategm_editor_move", deck, Vector(300, 0, 0), 0)
check("by default editors can move each other's parts", deck.pos.x == 300)
MOCK_SET_CVAR("skategm_park_editor_shared", 0)
send(bob, "skategm_editor_move", deck, Vector(500, 0, 0), 0)
check("not shared: someone else's part stays put", deck.pos.x == 300)
send(bob, "skategm_editor_remove", deck)
check("... and isn't removed", not deck.removed)
send(admin, "skategm_editor_move", deck, Vector(600, 0, 0), 180)
check("... an admin can still move it", deck.pos.x == 600 and deck.ang.y == 180)
send(amy, "skategm_editor_remove", deck)
check("its owner can remove it", deck.removed == true)
MOCK_SET_CVAR("skategm_park_editor_shared", 1)

-- the camera goes to everyone else
out = {}
send(amy, "skategm_editor_cam", Vector(1, 2, 3), Angle(10, 20, 0))
check("the editor's camera is passed on to everyone else", out[1] and out[1].name == "skategm_editor_cam" and out[1].omit == amy and out[1][1] == amy)
send(amy, "skategm_editor_state", false)
out = {}
send(amy, "skategm_editor_cam", Vector(1, 2, 3), Angle(10, 20, 0))
check("... only while editing", #out == 0 and amy.nw.SkateGMEditing == false)

-- a full park
local keep = ED.MAX_PARTS
ED.MAX_PARTS = #world + 1
send(admin, "skategm_editor_place", "deck_96x128", Vector(0, 0, 0), 0)
local before = #world
send(admin, "skategm_editor_place", "deck_96x128", Vector(0, 0, 0), 0)
check("no more parts than the limit", #world == before and admin.said[#admin.said]:find("full", 1, true) ~= nil)
ED.MAX_PARTS = keep

SKATEGM_MODES = { PlayerInPlay = function(p) return p == amy end }
send(amy, "skategm_editor_state", true)
check("the server refuses the editor during the player's minigame", amy.nw.SkateGMEditing ~= true and amy.said[#amy.said]:find("minigame", 1, true) ~= nil)
SKATEGM_MODES = nil
