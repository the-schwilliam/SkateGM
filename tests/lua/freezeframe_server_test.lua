dofile("gmock.lua")
local roles = {}
local cur
util = { AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }
net = { Start = function(n) cur = { name = n } end, WriteString = function() end, WriteBool = function(b) cur.imposter = b end,
	WriteUInt = function(v) cur.target = v end, Send = function(p) if cur and cur.name == "skategm_imposter_role" then roles[p] = cur end end,
	Broadcast = function() end, Receive = function() end }
local chatlog = {}
function PrintMessage(_, t) chatlog[#chatlog + 1] = t end
HUD_PRINTTALK = 3
hook = { Add = function() end }
timer = { Simple = function() end }
function IsValid(x) return x ~= nil and x.valid ~= false end
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
dofile("../../addon/skategm/lua/skategm_freezeframe/sh_freezeframe.lua")
dofile("../../addon/skategm/lua/skategm_freezeframe/sv_freezeframe.lua")
local FF = FREEZEFRAME
local S = FF.session
local A, B, Cc, D = P("Ann", 1), P("Bob", 2), P("Cat", 3), P("Dan", 4)
local now = 100
local function cmd(p, m) FF.Command(p, m, now) end
local function tick(dt) for _ = 1, math.floor(dt / 0.1 + 0.5) do now = now + 0.1 FF.Tick(now) end end
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local function E(p) return S.entries[SKATEGM_MODES.Key(p)] end
local function photo(x) return { cmd = "photo", pose = { HIPS = { x, 0, 40 }, HEAD = { x, 0, 70 } }, cam = { pos = { x - 100, 0, 60 }, ang = { 10, 0, 0 }, fov = 70 }, filter = "sepia" } end
check("a photo: skeleton and camera kept, numbers rounded", FF.CleanPhoto(photo(1.234)).pose.HIPS[1] == 1.2 and FF.CleanPhoto(photo(0)).filter == "sepia")
local far = photo(0) far.cam.pos = { 5000, 0, 0 }
check("a camera far from the skater: refused", FF.CleanPhoto(far) == nil)
local bad = photo(0) bad.pose.HIPS = { 0 / 0, 0, 0 }
check("NaN in the skeleton: refused", FF.CleanPhoto(bad) == nil)
local nohips = photo(0) nohips.pose.HIPS = nil
check("no hips: refused", FF.CleanPhoto(nohips) == nil)
local odd = photo(0) odd.filter = "lol" odd.cam.fov = 500
check("an unknown filter: none; FOV clamped", FF.CleanPhoto(odd).filter == "none" and FF.CleanPhoto(odd).cam.fov == FF.FOV_MAX)
check("a photo far from where the server saw the skater: refused", FF.CleanPhoto(photo(0), { x = 3000, y = 0, z = 0 }) == nil)
check("most votes is out", FF.Worst({ [1] = 3, [2] = 3, [4] = 2 }, { 2, 3 }) == 3)
check("a tie: the roll picks among the tied", FF.Worst({ [1] = 2, [3] = 3 }, { 2, 3 }, function(n) return n end) == 3)
check("no votes at all: still someone (the roll)", FF.Worst({}, { 2, 3 }, function() return 1 end) == 2)
cmd(A, { cmd = "create", time = 30, canSkate = true })
for _, p in ipairs({ B, Cc, D }) do cmd(p, { cmd = "join", canSkate = true }) end
for _, p in ipairs({ A, B, Cc, D }) do p.SkateGMHips = { x = p.id * 1000, y = 0, z = 40 } end
cmd(A, { cmd = "begin" })
check("round 1 counts down", S.phase == "countdown" and S.round == 1)
tick(FF.COUNTDOWN + 0.1)
check("then everyone shoots at once", S.phase == "shoot")
cmd(A, photo(1000))
cmd(A, photo(1000))
cmd(B, photo(2000))
cmd(D, photo(3000))
check("Ann and Bob took theirs; Dan's was far from where Dan is: refused", S.shots[1] and S.shots[2] and not S.shots[4])
cmd(D, photo(4000))
tick(30.2)
check("time's up: Cat sent nothing (not skating), so Cat's out", E(Cc).alive == nil and E(A).alive and S.phase == "show" and #S.photos == 3)
tick((FF.SHOW + 0.1) * 3)
check("every photo shown, then the vote", S.phase == "vote")
cmd(A, { cmd = "vote", target = 1 })
check("you can't vote for your own", S.votes[1] == nil)
cmd(A, { cmd = "vote", target = 2 })
cmd(B, { cmd = "vote", target = 4 })
cmd(Cc, { cmd = "vote", target = 2 })
check("the ones out vote too", S.votes[3] == 2)
cmd(D, { cmd = "vote", target = 2 })
tick(0.1)
check("everyone voted: Bob's photo is the worst, Bob's out", S.phase == "out" and S.out.ent == 2 and E(B).alive == nil)
tick(FF.OUT + 0.1)
check("round 2 with Ann and Dan", S.phase == "countdown" and S.round == 2)
tick(FF.COUNTDOWN + 0.1)
cmd(A, photo(1000))
cmd(D, photo(4000))
tick(0.1)
check("both photos in: straight to the show", S.phase == "show" and #S.photos == 2)
tick((FF.SHOW + 0.1) * 2)
cmd(A, { cmd = "vote", target = 4 })
for _, p in ipairs({ B, Cc }) do cmd(p, { cmd = "vote", target = 1 }) end
cmd(D, { cmd = "vote", target = 1 })
tick(0.1)
tick(FF.OUT + 0.1)
check("one left: Dan wins", S.phase == "results" and S.winner and S.winner.name == "Dan")
