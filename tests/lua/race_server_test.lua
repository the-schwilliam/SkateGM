dofile("gmock.lua")
SERVER = true
CurTime = CurTime or function() return 0 end
local chats = {}
util = setmetatable({ AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
local last
net = { Start = function() end, WriteString = function(t) last = t end, Broadcast = function() end, Receive = function() end, ReadString = function() end, Send = function() end }
local hooks = {}
hook = { Add = function(n, id, f) hooks[n] = f end }
timer = { Simple = function(_, f) f() end }
PrintMessage = function(_, t) chats[#chats + 1] = t end
HUD_PRINTTALK = 3
math.NormalizeAngle = math.NormalizeAngle or function(a) return (a + 180) % 360 - 180 end
table.Count = table.Count or function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
function IsValid(x) return x ~= nil and (type(x) ~= "table" or not x.gone) end
local skating = {}
SkateGM = { API = { Allowed = function() return true end, IsSkating = function(p) return skating[p] == true end } }
local function Player(id, name)
	local p = { id = id, name = name }
	function p:EntIndex() return self.id end
	function p:UserID() return self.id end
	function p:Nick() return self.name end
	function p:ChatPrint(t) chats[#chats + 1] = self.name .. ": " .. t end
	return p
end
do local mt = getmetatable(Vector(0, 0, 0)) local idx = type(mt.__index) == "table" and mt.__index or mt idx.Distance = idx.Distance or function(a, b) return (a - b):Length() end end
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_race/sh_race.lua")
dofile("../../addon/skategm/lua/skategm_race/sv_race.lua")
local R = RACE.session
local host, bob, cat = Player(1, "Host"), Player(2, "Bob"), Player(3, "Cat")
local function revive() host.gone, bob.gone, cat.gone = nil, nil, nil end
local function check(label, ok) print(string.format("%-66s %s", label, ok and "OK" or "<-- WRONG")) end
local t = 100
RACE.Command(host, { cmd = "create" }, t)
RACE.Command(bob, { cmd = "join" }, t)
RACE.Command(cat, { cmd = "join" }, t)
check("created, two joined: a lobby of three", R.phase == "lobby" and #R.players == 3 and R.host == host)
RACE.Command(host, { cmd = "begin" }, t)
check("can't start without a start and a finish", R.phase == "lobby")
RACE.Command(bob, { cmd = "start", pos = { 0, 0, 0 }, yaw = 0 }, t)
check("only the host places them", R.start == nil)
RACE.Command(host, { cmd = "start", pos = { 0, 0, 0 }, yaw = 90 }, t)
RACE.Command(host, { cmd = "finish", pos = { 0 / 0, 0, 0 } }, t)
check("nonsense positions are ignored", R.finish == nil)
RACE.Command(host, { cmd = "finish", pos = { 100, 0, 0 } }, t)
RACE.Command(host, { cmd = "begin" }, t)
check("a finish right next to the start is refused", R.phase == "lobby")
RACE.Command(host, { cmd = "finish", pos = { 3000, 0, 0 } }, t)
skating[host], skating[bob] = true, true -- joining switched them on; Cat is still loading
RACE.Command(host, { cmd = "begin" }, t)
check("start: straight to the countdown, no waiting", R.phase == "countdown" and R.deadline == t + 3)
check("Cat wasn't in Skate 3 mode: she sits this one out, stays for the next", R.entries["3"].racing == nil and #R.players == 3)
RACE.Think(t + RACE.COUNTDOWN)
t = t + RACE.COUNTDOWN
check("GO: racing", R.phase == "racing" and R.startedAt == t)
RACE.Command(bob, { cmd = "finished" }, t + 0.5)
check("nobody finishes in under a second", R.entries["2"].time == nil)
RACE.Command(bob, { cmd = "finished" }, t + 30)
check("Bob finishes first, timed by the server", R.entries["2"].place == 1 and math.abs(R.entries["2"].time - 30) < 1e-6)
RACE.Command(bob, { cmd = "finished" }, t + 31)
check("finishing twice doesn't count", R.entries["2"].time == 30 and R.nextPlace == 2)
RACE.Command(host, { cmd = "finished" }, t + 42)
check("everyone racing is in (Cat sat out): results", R.phase == "results" and R.entries["1"].place == 2)
RACE.Think(t + 42 + RACE.RESULTS)
check("then back to the lobby, same course, times cleared", R.phase == "lobby" and R.start and R.finish and R.entries["2"].time == nil)
-- a second race: the host drops out of Skate 3 mode, Bob finishes
skating[cat] = true
RACE.Command(host, { cmd = "begin" }, t + 100)
check("the rematch: Cat's loaded now, she races", R.entries["3"].racing == true)
RACE.Think(t + 100 + RACE.COUNTDOWN)
skating[host] = false
RACE.Think(t + 110)
check("leaving Skate 3 mode mid-race: out of it", R.entries["1"].dnf == true and R.phase == "racing")
RACE.Command(bob, { cmd = "finished" }, t + 120)
RACE.Command(cat, { cmd = "finished" }, t + 125)
check("the rest finished: results", R.phase == "results")
-- the host leaves: Bob takes over
RACE.Think(t + 120 + RACE.RESULTS)
host.gone = true
RACE.Think(t + 200)
check("the host left: Bob hosts now", R.host == bob and R.phase == "lobby")
bob.gone, cat.gone = true, true
RACE.Think(t + 201)
check("everyone gone: race closed", R.phase == "idle")
-- turned off on this server
revive()
RACE.Command(host, { cmd = "create" }, t + 300)
check("a race can be set up while allowed", R.phase == "lobby")
MOCK_SET_CVAR("skategm_race_allowed", 0)
check("turned off mid-race: the race ends", R.phase == "idle")
RACE.Command(host, { cmd = "create" }, t + 301)
check("and while off, none can be set up", R.phase == "idle")
MOCK_SET_CVAR("skategm_race_allowed", 1)
