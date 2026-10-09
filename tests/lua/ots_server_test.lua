dofile("gmock.lua")
-- mocks
local sent = {}
util = { AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }
net = { Start = function() end, WriteString = function(t) sent[#sent + 1] = t end, Broadcast = function() end, Receive = function() end }
local chatlog = {}
function PrintMessage(_, t) chatlog[#chatlog + 1] = t end
HUD_PRINTTALK = 3
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
timer = { Simple = function() end }
function IsValid(x) return x ~= nil and x.valid ~= false end
string.Comma = function(n) return tostring(n) end
math.Clamp = function(v, a, b) return math.max(a, math.min(b, v)) end
local skating = {}
local function P(name, id)
	local p = { name = name, id = id, frozen = false, valid = true }
	function p:Nick() return self.name end
	function p:UserID() return self.id end
	function p:EntIndex() return self.id end
	function p:GetPos() return { x = 10, y = 20, z = 0 } end
	function p:EyeAngles() return { y = 90 } end
	function p:Freeze(b) self.frozen = b end
	function p:ChatPrint(t) chatlog[#chatlog + 1] = self.name .. ": " .. t end
	function p:IsAdmin() return false end
	return p
end
SkateGM = { API = { Allowed = function() return true end, IsSkating = function(p) return skating[p] == true end } }
SERVER = true
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_ots/sh_ots.lua")
dofile("../../addon/skategm/lua/skategm_ots/sv_ots.lua")
local S = OTS.session
local A, B, Cc = P("Ann", 1), P("Bob", 2), P("Cat", 3)
local now = 100
local function cmd(p, m) OTS.Command(p, m, now) end
local function tick(dt) local steps = math.floor(dt / 0.1) for _ = 1, steps do now = now + 0.1 OTS.Tick(now) end end
local function last() return chatlog[#chatlog] or "" end
local function check(label, ok) print(string.format("%-60s %s", label, ok and "OK" or "<-- WRONG")) end

cmd(A, { cmd = "create", turn = 20, rounds = 2, canSkate = true })
check("host opens a lobby at their spot", S.phase == "lobby" and S.host == A and S.turn == 20 and S.rounds == 2 and S.spot.x == 10)
cmd(B, { cmd = "join", canSkate = true })
cmd(Cc, { cmd = "join", canSkate = false })
check("a player joins; one without working Skate 3 mode is refused", #S.players == 2 and last():find("Cat") ~= nil)
cmd(B, { cmd = "settings", turn = 99 })
check("only the host changes settings", S.turn == 20 and last():find("only the host") ~= nil)
cmd(A, { cmd = "settings", turn = 1000, rounds = 0 })
check("host settings are clamped (turn 10-300, rounds 1-10)", S.turn == 300 and S.rounds == 1)
cmd(A, { cmd = "settings", turn = 20, rounds = 2 })
tick(30)
check("nothing starts until the host says so", S.phase == "lobby")
cmd(B, { cmd = "begin" })
check("only the host starts", S.phase == "lobby")
cmd(A, { cmd = "begin" })
check("start: Ann's turn (prep); Bob frozen to watch, Ann free", S.phase == "prep" and S.active == A and B.frozen and not A.frozen)
skating[A] = true
cmd(A, { cmd = "ready" })
check("Ann at the spot: countdown", S.phase == "countdown")
tick(3.2)
check("then the clock runs", S.phase == "turn")
cmd(A, { cmd = "live", score = 1200 })
cmd(B, { cmd = "live", score = 999999 })
check("live score only from the active player", S.live == 1200)
tick(20.2)
check("time up: Ann's turn recorded", S.phase == "between" and S.entries["1"].turns[1] == 1200)
cmd(A, { cmd = "final", score = 1350 })
check("her final score replaces the last live one", S.entries["1"].best == 1350 and S.last.score == 1350)
tick(4.2)
check("next: Bob's turn", S.phase == "prep" and S.active == B and A.frozen and not B.frozen)
tick(OTS.PREP_TIMEOUT + 0.5)
check("Bob never got onto the spot: skipped, no score", S.phase == "between" and #S.entries["2"].turns == 0)
tick(4.2)
check("round 2: Ann again", S.phase == "prep" and S.active == A and S.round == 2)
cmd(A, { cmd = "ready" }) tick(3.2) cmd(A, { cmd = "live", score = 400 })
skating[A] = false
tick(1.3)
check("Ann leaves Skate 3 mode mid-turn: turn ends, score kept", S.phase == "between" and S.entries["1"].turns[2] == 400 and S.entries["1"].best == 1350)
tick(4.2)
check("Bob's round-2 turn", S.phase == "prep" and S.active == B)
skating[B] = true
cmd(B, { cmd = "ready" }) tick(3.2) cmd(B, { cmd = "live", score = 900 })
A.valid = false
OTS.Remove(A, "left the game", now)
check("Ann disconnects (not her turn): Bob carries on, Bob is host", S.phase == "turn" and S.active == B and S.host == B and #S.players == 1)
tick(20.2)
tick(4.2)
check("last turn done: final standings, Ann (gone) still owns it", S.phase == "final" and S.winner and S.winner.name == "Ann" and S.winner.score == 1350)
check("nobody frozen at the end", not B.frozen)
tick(OTS.FINAL + 0.5)
check("then the session closes", S.phase == "idle")

-- the active player disconnecting mid-turn skips to the next player
A = P("Ann", 1) B = P("Bob", 2) Cc = P("Cat", 3)
skating = { [A] = true, [B] = true, [Cc] = true }
cmd(A, { cmd = "create", turn = 20, rounds = 1, canSkate = true })
cmd(B, { cmd = "join", canSkate = true }) cmd(Cc, { cmd = "join", canSkate = true })
cmd(A, { cmd = "begin" }) cmd(A, { cmd = "ready" }) tick(3.2) tick(20.2) tick(4.2)
check("second session: Bob's turn", S.active == B and S.phase == "prep")
cmd(B, { cmd = "ready" }) tick(3.2)
B.valid = false
OTS.Remove(B, "left the game", now)
tick(1.2)
check("Bob disconnects on his own turn: straight to Cat", S.phase == "prep" and S.active == Cc)
Cc.valid = false OTS.Remove(Cc, "left the game", now)
A.valid = false OTS.Remove(A, "left the game", now)
check("everyone leaves: the challenge stops", S.phase == "idle" and last():find("everyone left") ~= nil)
OTS.Stop(nil, now)
A, B = P("Ann", 1), P("Bob", 2)
cmd(A, { cmd = "create", turn = 20, rounds = 1, canSkate = true })
cmd(B, { cmd = "join", canSkate = true })
cmd(A, { cmd = "begin" })
check("Ann's turn in the only round: Bob is up next", sent[#sent].nextUp == 2)
check("the last turn of the last round: nobody next", SKATEGM_MODES.UpNext({ A, B }, 2, false) == nil)
check("... with rounds to go: back to the first", SKATEGM_MODES.UpNext({ A, B }, 2, true) == 1)
OTS.Stop(nil, now)
A, B = P("Ann", 1), P("Bob", 2)
cmd(A, { cmd = "create", turn = 20, rounds = 2, canSkate = true })
cmd(B, { cmd = "join", canSkate = true })
skating[A], skating[B] = true, true
cmd(A, { cmd = "begin" })
cmd(A, { cmd = "stop" })
check("the host stops mid-game: back to the lobby, everyone still in", S.phase == "lobby" and #S.players == 2 and not A.frozen and not B.frozen)
cmd(A, { cmd = "begin" })
check("... begin again: a restart, same players and settings", S.phase == "prep" and #S.players == 2 and S.turn == 20 and S.rounds == 2)
cmd(A, { cmd = "stop" })
cmd(A, { cmd = "stop" })
check("... and stopping in the lobby closes it", S.phase == "idle")
