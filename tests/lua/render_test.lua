dofile("gmock.lua")
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
local clock = 0
function RealTime() return clock end
function LerpVector(f, a, b) return a + (b - a) * f end
function IsValid(x) if type(x) == "table" and x.IsValid then return x:IsValid() end return x ~= nil end
function CreateClientConVar(name, default) return { GetBool = function() return default == "1" end, GetFloat = function() return 1 end, GetString = function() return default end } end
ACT_HL2MP_IDLE = 1
local drawn = { models = 0, quads = 0 }
render = setmetatable({ DrawQuad = function() drawn.quads = drawn.quads + 1 end, GetLightColor = function() return Vector(0.5, 0.5, 0.5) end }, { __index = function() return function() end end })
local made = {}
function ClientsideModel(mdl)
	local e = { mdl = mdl, nodraw = false, valid = true }
	function e:IsValid() return self.valid end
	function e:SetNoDraw(b) self.nodraw = b end
	function e:SetPos(p) self.pos = p end
	function e:Remove() self.valid = false end
	function e:DrawModel() drawn.models = drawn.models + 1 end
	function e:LookupBone() return nil end -- no ValveBiped: bones-only path is fine here
	for _, m in ipairs({ "DrawShadow", "SetSkin", "SetBodygroup", "ResetSequence", "AddCallback", "SetRenderBounds", "InvalidateBoneCache", "SetupBones", "SetPlaybackRate", "SetCycle" }) do e[m] = function() end end
	function e:SelectWeightedSequence() return 0 end
	function e:LookupSequence() return -1 end
	made[#made + 1] = e
	return e
end
local ME = { IsValid = function() return true end, GetModel = function() return "models/player/kleiner.mdl" end,
	GetPlayerColor = function() return Vector(1, 1, 1) end, GetSkin = function() return 0 end, GetNumBodyGroups = function() return 0 end }
local OTHER = { IsValid = function() return true end, GetModel = function() return "models/player/alyx.mdl" end,
	GetPlayerColor = function() return Vector(1, 1, 1) end, GetSkin = function() return 0 end, GetNumBodyGroups = function() return 0 end }
function LocalPlayer() return ME end
MsgC = function() end chat = { AddText = function() end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
local function pose(x)
	return { HIPS = Vector(x, 0, 40), TRUCK_FRONT = Vector(x + 7, 0, 3), TRUCK_BACK = Vector(x - 7, 0, 3),
		RIGHT_WHEELFRONT = Vector(x + 7, -4, 1), LEFT_WHEELFRONT = Vector(x + 7, 4, 1), RIGHT_WHEELBACK = Vector(x - 7, -4, 1), LEFT_WHEELBACK = Vector(x - 7, 4, 1) }
end

S.phase, S.P = "on", pose(500)
S.UpdateSkaters(clock)
local mine = made[1]
print("my skater shown at the skater's hips:", mine and not mine.nodraw and mine.pos.x == 500 and "OK" or "<-- WRONG")
mine:RenderOverride()   -- what the engine calls when it renders the model
print(string.format("rendering draws the board (%d quads) and bones:", drawn.quads), drawn.quads > 0 and "OK" or "<-- WRONG")
print("draw error:", S.drawErr)
print("counted as drawn:", S.drawCount == 1 and "OK" or "<-- WRONG")

S.remote[OTHER] = { snaps = { { t = 0, P = pose(900) } }, last = 0 }
S.UpdateSkaters(0.2)
local theirs = made[2]
print("other skater shown:", theirs and not theirs.nodraw and theirs.pos.x == 900 and "OK" or "<-- WRONG")

S.phase = "off"
S.UpdateSkaters(0.3)
print("mine hidden when I stop skating:", mine.nodraw and "OK" or "<-- WRONG")
S.UpdateSkaters(2.0) -- nothing from OTHER for 2 s
print("other removed after going quiet:", (not theirs.valid) and S.remote[OTHER] == nil and "OK" or "<-- WRONG")

local frame = 10
function FrameNumber() return frame end
S.phase, S.P = "on", pose(500)
S.UpdateSkaters(3.0)
local e = made[#made]
e.Sk8Rig = { fake = true }
local setups, fromCallback = 0, 0
function e:SetupBones() setups = setups + 1 if not self.Sk8Direct then fromCallback = fromCallback + 1 end end
e:RenderOverride()
e:RenderOverride()
print("posed once a frame however many times it's drawn (reflections, mirrors)", setups == 1 and "OK" or "<-- WRONG (" .. setups .. ")")
frame = 11
e:RenderOverride()
print("next frame: posed again", setups == 2 and "OK" or "<-- WRONG")

local r = { snaps = { { t = 0, P = pose(100) }, { t = 0.05, P = pose(120) } }, last = 0.05 }
local a1 = S.RemotePose(r, 0.125)
local a2 = S.RemotePose(r, 0.125)
print("another skater's pose is worked out once per moment, not per caller", a1 == a2 and math.abs(a1.HIPS.x - 110) < 0.05 and "OK" or "<-- WRONG")
r.snaps[#r.snaps + 1] = { t = 0.1, P = pose(140) }
local a3 = S.RemotePose(r, 0.125)
print("... and again once a newer snapshot arrives", a3 ~= a1 and math.abs(a3.HIPS.x - 110) < 0.05 and "OK" or "<-- WRONG")

local chats = 0
chat.AddText = function() chats = chats + 1 end
skategm = nil
S.API.CanSkate()
local first = chats
S.API.CanSkate()
S.API.CanSkate()
print("module missing: the error is said once, not every time something asks", first > 0 and chats == first and "OK" or "<-- WRONG (" .. first .. ", " .. chats .. ")")

local hv = GetConVar
local hoverOn = true
GetConVar = function(n) if n == "skategm_hoverboard" then return { GetBool = function() return hoverOn end } end return hv and hv(n) end
local hp = { HIPS = Vector(0, 0, 40), TRUCK_FRONT = Vector(10, 0, 4), TRUCK_BACK = Vector(-10, 0, 4) }
local he = {}
local me = LocalPlayer()
S.HoverPose(he, me, hp, "PhysicsGround", 10)
local H = S.HoverPose(he, me, hp, "PhysicsGround", 11)
local lift = H.TRUCK_FRONT.z + H.TRUCK_BACK.z - 8
print("hoverboard mode: the board floats above where the engine has it", lift > 2 * (S.HOVER.lift - S.HOVER.bob - S.HOVER.roll) and "OK" or "<-- WRONG (" .. lift .. ")")
print("  the engine's pose is left alone", hp.TRUCK_FRONT.z == 4 and "OK" or "<-- WRONG")
local H2 = S.HoverPose(he, me, hp, "PhysicsGround", 11.4)
print("  and it bobs", math.abs(H2.HIPS.z - H.HIPS.z) > 0.05 and "OK" or "<-- WRONG")
print("  the skater keeps its shape", math.abs((H.HIPS - (H.TRUCK_FRONT + H.TRUCK_BACK) / 2):Length() - 36) < 1e-3 and "OK" or "<-- WRONG")
S.HoverPose(he, me, hp, "Biped", 12)
local F = S.HoverPose(he, me, hp, "Biped", 12.1)
print("on foot: eases back down to the ground", F ~= hp and F.HIPS.z < 40 + 0.5 * (S.HOVER.lift - S.HOVER.bob) and "OK" or "<-- WRONG")
for i = 1, 20 do F = S.HoverPose(he, me, hp, "Biped", 12 + i * 0.05) end
print("  and ends on it", F == hp and "OK" or "<-- WRONG")
hoverOn = false
he = {}
print("hoverboard mode off: the pose as the engine has it", S.HoverPose(he, me, hp, "PhysicsGround", 20) == hp and "OK" or "<-- WRONG")

local owner = { IsValid = function() return true end, GetModel = function() return "m" end, GetNW2String = function(_, k, d) return k == "skategm_look" and "LOOK" or d end, Nick = function() return "Ann" end }
local clip = {}
for i = 0, 10 do clip[#clip + 1] = { t = i * 0.05, P = { HIPS = Vector(i, 0, 40) } } end
local key = S.API.PlayClip("t", owner, clip)
check = check or function(l, ok) print(l, ok and "OK" or "<-- WRONG") end
S.ClipsThink(RealTime())
print("a clip plays as a ghost that looks like its skater", key and key:GetNW2String("skategm_look") == "LOOK" and key:Nick() == "Ann" and S.remote[key] ~= nil and "OK" or "<-- WRONG")
print("  not solid to anyone", key.noCollide == true and "OK" or "<-- WRONG")
S.API.StopClip("t")
print("  and stops when asked", S.remote[key] == nil and "OK" or "<-- WRONG")

local focus = true
system = { HasFocus = function() return focus end }
S.inputBlocked = nil
print("window in front: the controller skates", not S.InputBlockWanted() and "OK" or "<-- WRONG")
focus = false
print("another window in front (a second copy of the game): it doesn't", S.InputBlockWanted() and "OK" or "<-- WRONG")
print("  and menus don't see the pad either", S.API.Pad() == nil and "OK" or "<-- WRONG")
focus = true
