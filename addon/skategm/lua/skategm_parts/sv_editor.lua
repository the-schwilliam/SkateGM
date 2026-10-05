---------------------------------------------------------------------------
-- The controller park editor, server side (the client half is cl_editor.lua).
-- A skater in the editor flies a free camera (a floating watermelon to
-- everyone else) and places, moves and removes park parts. The client works
-- out where a part goes (P.Place, the same snapping as the physgun's); the
-- server checks who may do it and does it.
--   skategm_park_editor 1          who may use it: 0 nobody, 1 everyone, 2 admins
--   skategm_park_editor_shared 1   editors may move / remove anyone's parts
--                                  (0: only their own; admins always)
---------------------------------------------------------------------------
local P = SKATEGM_PARTS
local ED = {}
P.editorServer = ED
ED.MAX_PARTS = 300
ED.REACH = 6000
-- park parts count against their own sandbox limit (sbox_maxskategm_parts)
ED.LIMIT = "skategm_parts"
CreateConVar("sbox_max" .. ED.LIMIT, "300", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY, "Most park parts each player may place")
if cleanup and cleanup.Register then cleanup.Register(ED.LIMIT) end

-- the spawn menu too: a park part asks the parts limit, not the sents one
hook.Add("PlayerSpawnSENT", "skategm_parts_limit", function(ply, class)
	if type(class) == "string" and class:sub(1, 13) == "skategm_part_" and IsValid(ply) and ply.CheckLimit then
		return ply:CheckLimit(ED.LIMIT)
	end
end)
hook.Add("PlayerSpawnedSENT", "skategm_parts_limit", function(ply, e)
	if IsValid(e) and e.SkateGMPart and not e.SkateGMOwner and IsValid(ply) and ply.AddCount then ply:AddCount(ED.LIMIT, e) end
end)

local cvAllowed = CreateConVar("skategm_park_editor", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Who may use the controller park editor (LB + B): 0 nobody, 1 everyone, 2 admins", 0, 2)
local cvShared = CreateConVar("skategm_park_editor_shared", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Park editors may move and remove anyone's parts (0: only their own; admins always)", 0, 1)

for _, n in ipairs({ "skategm_editor_state", "skategm_editor_cam", "skategm_editor_place", "skategm_editor_move", "skategm_editor_remove" }) do
	util.AddNetworkString(n)
end

local function Admin(ply) return game.SinglePlayer() or (IsValid(ply) and ply:IsAdmin()) end

function ED.MayEdit(ply)
	local v = cvAllowed:GetInt()
	if v == 0 then return false, "the park editor is turned off on this server" end
	if v == 2 and not Admin(ply) then return false, "only admins can use the park editor here" end
	local M = SKATEGM_MODES
	if M and M.PlayerInPlay and M.PlayerInPlay(ply) then return false, "not while your minigame is on" end
	return true
end

function ED.MayChange(ply, e)
	if not (IsValid(e) and e.SkateGMPart) then return false end
	if Admin(ply) or cvShared:GetBool() then return true end
	return e.SkateGMOwner == ply
end

local function Editing(ply)
	if not (IsValid(ply) and ply.SkateGMEditing == true) then return false end
	local M = SKATEGM_MODES
	return not (M and M.PlayerInPlay and M.PlayerInPlay(ply))
end

local function Reply(ply, text) if IsValid(ply) then ply:ChatPrint("[SkateGM] " .. text) end end

function ED.SetEditing(ply, on)
	if on then
		local ok, why = ED.MayEdit(ply)
		if not ok then
			Reply(ply, why)
			net.Start("skategm_editor_state") net.WriteBool(false) net.Send(ply)
			return false
		end
	end
	ply.SkateGMEditing = on or nil
	ply:SetNW2Bool("SkateGMEditing", on and true or false)
	return true
end

local function PartCount()
	local n = 0
	for _, e in ipairs(ents.GetAll()) do if IsValid(e) and e.SkateGMPart then n = n + 1 end end
	return n
end

-- a part where the editor put it (already snapped by the client)
function ED.Place(ply, id, pos, yaw)
	if not Editing(ply) then return nil, "not in the park editor" end
	local def = P.Get(id)
	if not def then return nil, "no such part" end
	if pos:Distance(ply:GetPos()) > ED.REACH * 2 then return nil, "too far away" end
	if PartCount() >= ED.MAX_PARTS then return nil, "the park is full (" .. ED.MAX_PARTS .. " parts)" end
	local class = "skategm_part_" .. id
	-- (other add-ons' say, e.g. admin mods; park parts have their own limit,
	-- not sandbox's few scripted entities)
	if hook.Call("PlayerSpawnSENT", nil, ply, class) == false then return nil, "you can't spawn that here" end
	if ply.CheckLimit and not ply:CheckLimit(ED.LIMIT) then return nil end
	local e = ents.Create(class)
	if not IsValid(e) then return nil, "couldn't make it" end
	e:SetPos(pos)
	e:SetAngles(Angle(0, yaw, 0))
	e:Spawn()
	e:Activate()
	e.SkateGMOwner = ply
	e:SetNW2Entity("SkateGMOwner", ply)
	local phys = e:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
	if undo then
		undo.Create("SkateGM part")
		undo.AddEntity(e)
		undo.SetPlayer(ply)
		undo.Finish()
	end
	if ply.AddCleanup then ply:AddCleanup(ED.LIMIT, e) end
	if ply.AddCount then ply:AddCount(ED.LIMIT, e) end
	hook.Call("PlayerSpawnedSENT", nil, ply, e)
	return e
end

function ED.Move(ply, e, pos, yaw)
	if not Editing(ply) then return false end
	if not ED.MayChange(ply, e) then return false, "that part isn't yours to move" end
	if pos:Distance(ply:GetPos()) > ED.REACH * 2 then return false, "too far away" end
	e:SetPos(pos)
	e:SetAngles(Angle(0, yaw, 0))
	local phys = e:GetPhysicsObject()
	if IsValid(phys) then
		phys:EnableMotion(false)
		phys:Wake()
	end
	return true
end

function ED.Remove(ply, e)
	if not Editing(ply) then return false end
	if not ED.MayChange(ply, e) then return false, "that part isn't yours to remove" end
	e:Remove()
	return true
end

net.Receive("skategm_editor_state", function(_, ply)
	ED.SetEditing(ply, net.ReadBool())
end)

-- the editor's camera (the watermelon), passed on to everyone else
net.Receive("skategm_editor_cam", function(_, ply)
	if not Editing(ply) then return end
	local pos, ang = net.ReadVector(), net.ReadAngle()
	ply.SkateGMEditorCam = pos
	net.Start("skategm_editor_cam", true)
	net.WriteEntity(ply)
	net.WriteVector(pos)
	net.WriteAngle(ang)
	net.SendOmit(ply)
end)

net.Receive("skategm_editor_place", function(_, ply)
	local id, pos, yaw = net.ReadString(), net.ReadVector(), net.ReadFloat()
	local e, why = ED.Place(ply, id, pos, yaw)
	if not e and why then Reply(ply, why) end
end)

net.Receive("skategm_editor_move", function(_, ply)
	local e, pos, yaw = net.ReadEntity(), net.ReadVector(), net.ReadFloat()
	local ok, why = ED.Move(ply, e, pos, yaw)
	if not ok and why then Reply(ply, why) end
end)

net.Receive("skategm_editor_remove", function(_, ply)
	local e = net.ReadEntity()
	local ok, why = ED.Remove(ply, e)
	if not ok and why then Reply(ply, why) end
end)

hook.Add("PlayerDisconnected", "skategm_editor", function(ply) ply.SkateGMEditing = nil end)
hook.Add("PlayerDeath", "skategm_editor", function(ply) if ply.SkateGMEditing then ED.SetEditing(ply, false) end end)
