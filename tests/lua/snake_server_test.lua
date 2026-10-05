dofile("gmock.lua")
SERVER = true
local chats = {}
util = setmetatable({ AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
local states, trails = {}, {}
local cur
net = { Start = function(n) cur = n end, WriteString = function(t) if cur == "skategm_mode_snake_trail" then trails[#trails + 1] = t else states[#states + 1] = t end end,
	Broadcast = function() end, Receive = function() end, ReadString = function() end, Send = function() end }
hook = { Add = function() end }
timer = { Simple = function(_, f) f() end }
PrintMessage = function(_, t) chats[#chats + 1] = t end
HUD_PRINTTALK = 3
function IsValid(x) return x ~= nil and (type(x) ~= "table" or not x.gone) end
local skating = {}
SkateGM = { API = { Allowed = function() return true end, IsSkating = function(p) return skating[p] == true end } }
local players = {}
local function Player(id, name)
	local p = { id = id, name = name }
	function p:EntIndex() return self.id end
	function p:Nick() return self.name end
	function p:IsAdmin() return false end
	function p:ChatPrint(t) chats[#chats + 1] = self.name .. ": " .. t end
	players[id] = p
	return p
end
function Entity(i) return players[i] end
math.randomseed(3)
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_snake/sh_snake.lua")
dofile("../../addon/skategm/lua/skategm_snake/sv_snake.lua")
local G = SNAKE.session
local function check(label, ok) print(string.format("%-70s %s", label, ok and "OK" or "<-- WRONG")) end
local function last() return states[#states] end
local host, bob, cat = Player(1, "Host"), Player(2, "Bob"), Player(3, "Cat")
local t = 100

SNAKE.Command(host, { cmd = "create", x = 0, y = 0, z = 0, radius = 99999, time = 60, length = 400, pellets = 3, canSkate = true }, t)
check("created around the host; radius kept within limits", G.phase == "lobby" and G.area[4] == SNAKE.RADIUS_MAX and G.length == 400)
SNAKE.Command(bob, { cmd = "join", canSkate = true }, t)
SNAKE.Command(cat, { cmd = "join", canSkate = true }, t)
check("players join, each with their own colour", #G.players == 3 and G.entries[bob].slot == 2 and G.entries[cat].slot == 3)
skating[host], skating[bob], skating[cat] = true, true, true
SNAKE.Command(bob, { cmd = "begin" }, t)
check("only the host starts", G.phase == "lobby")
SNAKE.Command(host, { cmd = "begin" }, t)
check("start: countdown, everyone on their own spot around the arena", G.phase == "countdown" and G.entries[bob].start and G.entries[bob].start[1] ~= G.entries[host].start[1])
check("... orbs scattered inside the arena", #G.pellets == 3 and (G.pellets[1].x ^ 2 + G.pellets[1].y ^ 2) < G.area[4] ^ 2)
SNAKE.Think(t + 3.1)
check("then GO", G.phase == "playing")
local n = #trails
SNAKE.Command(bob, { cmd = "trail", p = { 10, 0, 0, 26, 0, 0, 42, 0, 0 } }, t + 4)
SNAKE.Think(t + 4.2)
check("a skater's trail goes out to everyone", #trails > n and trails[#trails].ent == 2 and #trails[#trails].p == 9)
SNAKE.Command(bob, { cmd = "trail", p = { 1e9, 0, 0 } }, t + 4.3)
check("points far outside the arena are ignored", #G.entries[bob].trail == 3)
local pel = G.pellets[1]
SNAKE.Command(bob, { cmd = "trail", p = { pel.x, pel.y, pel.z } }, t + 4.4)
SNAKE.Command(bob, { cmd = "eat", id = 1 }, t + 4.5)
check("eating an orb grows the tail, and a new orb appears", G.entries[bob].length == 400 + SNAKE.GROWTH and G.entries[bob].eaten == 1 and G.pellets[1] ~= pel)
SNAKE.Command(cat, { cmd = "eat", id = 2 }, t + 4.6)
check("an orb can't be eaten from across the map", (G.entries[cat].eaten or 0) == 0)
local long = {}
for k = 1, 60 do long[#long + 1] = 100 + k * 20 long[#long + 1] = 0 long[#long + 1] = 0 end
SNAKE.Command(host, { cmd = "trail", p = long }, t + 5)
local len = 0
local tr = G.entries[host].trail
for i = 2, #tr do len = len + math.abs(tr[i][1] - tr[i - 1][1]) end
check(string.format("a tail is kept to its length (%d of 400 units)", len), len <= 400 and #tr <= SNAKE.MAX_POINTS)
SNAKE.Command(cat, { cmd = "crash", by = 2 }, t + 6)
check("hitting a tail: out, and everyone's told whose", G.entries[cat].out and chats[#chats]:find("Bob's tail") ~= nil)
SNAKE.Command(bob, { cmd = "crash", wall = true }, t + 7)
check("last one left wins", G.phase == "results" and G.winner and G.winner.name == "Host")
SNAKE.Think(t + 7 + SNAKE.RESULTS + 0.1)
check("then back to the lobby for another go", G.phase == "lobby" and not G.entries[cat].out)
SNAKE.Command(host, { cmd = "begin" }, t + 30)
SNAKE.Think(t + 33.1)
SNAKE.Think(t + 33.2 + 60)
check("at the time limit the longest tail wins", G.phase == "results" and G.winner ~= nil)
SNAKE.Command(host, { cmd = "stop" }, t + 200)
SNAKE.Command(host, { cmd = "stop" }, t + 201)
check("the host can close it", G.phase == "idle")

-- ground: every surface down the line, the one nearest the arena's own height
local floors = { 300, 0, -200 }
MASK_PLAYERSOLID = 1
local realTrace = util.TraceLine
util.TraceLine = function(t)
	for _, h in ipairs(floors) do
		if t.start.z > h and t.endpos.z <= h then return { Hit = true, HitPos = Vector(t.start.x, t.start.y, h), HitNormal = Vector(0, 0, 1) } end
	end
	return { Hit = false }
end
local M = SKATEGM_MODES
check("ground: under a roof, the floor nearest the arena (not the roof)", M.Ground(0, 0, 20) == 0)
floors = { 180 }
check("... on a hill above the arena's height, the hill's surface (not buried)", M.Ground(0, 0, 0) == 180)
floors = {}
check("... nothing there: the arena's own height", M.Ground(0, 0, 42) == 42)
util.TraceLine = realTrace
