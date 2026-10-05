---------------------------------------------------------------------------
-- The controller park editor (like Halo's Forge), client side. LB + B while
-- skating: your skater waits where it is and you fly a free camera - to
-- everyone else, a floating watermelon with a glowing eye. Pick parts from a
-- menu, see them where you aim, and they snap to the parts next to them.
-- The server half (sv_editor.lua) places, moves and removes them.
--
--   left stick: fly           right stick: look      RT / LT: up / down
--   RB (held): fly faster     X: parts menu           A: place / drop
--   Y: pick up the part you aim at                    B: cancel / back
--   D-pad left / right: turn  D-pad up: snapping on / off
--   D-pad down: remove the part you aim at            LB + B: back to skating
---------------------------------------------------------------------------
if not (SKATEGM_UI and SKATEGM_UI.pad) then include("skategm_ui/cl_pad.lua") end
local UI = SKATEGM_UI
local PAD = UI.pad
local List = UI.List
local P = SKATEGM_PARTS
local ED = P.editor or {}
P.editor = ED
ED.active = false
ED.remote = ED.remote or {}

local B = PAD.B
ED.BUTTONS = B
ED.FLY, ED.FAST, ED.LOOK = 450, 3, 120
ED.SNAP_REACH = 72
ED.TURN_STEP = 15
ED.AIM_RANGE = 6000
ED.CAM_RATE = 0.1
ED.MELON = "models/props_junk/watermelon01.mdl"
ED.MELON_SCALE = 1.6

local function API() return SkateGM and SkateGM.API end
if language and language.Add then
	language.Add("Cleanup_skategm_parts", "SkateGM park parts")
	language.Add("Cleaned_skategm_parts", "Cleaned up the park parts")
	language.Add("SBoxLimit_skategm_parts", "You've hit the park parts limit!")
end

---------------------------------------------------------------------------
-- the parts menu (X): list pages - the groups, the parts in one (each
-- turning slowly beside its name), and the Park page
---------------------------------------------------------------------------
function ED.Catalog()
	local cats, byName = {}, {}
	for _, def in ipairs(P.Ordered()) do
		local name = def.category or P.CATEGORY or "SkateGM"
		local c = byName[name]
		if not c then
			c = { title = name:gsub("^SkateGM ", ""), parts = {} }
			byName[name] = c
			cats[#cats + 1] = c
		end
		c.parts[#c.parts + 1] = def
	end
	return cats
end

local CLOSE = { { keys = { "X" }, text = "Close" } }
local function InlinePreview(row, x, ry, pw, rowH)
	if not row.def then return end
	local ph = rowH * 1.5
	ED.PaintPreview(row.def, x + pw - ph * 1.6, ry - 3 + (rowH - 3) / 2 - ph / 2, ph * 1.6, ph, RealTime())
end

function ED.CategoryPage(c)
	local rows = {}
	for _, def in ipairs(c.parts) do
		rows[#rows + 1] = { label = def.title or def.id, def = def, aText = "Place it", run = function() ED.Select(def) ED.menu = nil end }
	end
	return { title = c.title, rows = rows, inline = InlinePreview, hints = CLOSE }
end

-- the Park page: snapping, saving and loading (Garry's Mod's own saves,
-- cl_saves.lua), clearing
function ED.ParkRows()
	local rows = { List.Bool("Snapping", function() return ED.snap end, function(v) ED.snap = v end) }
	for _, r in ipairs(P.saves and P.saves.Rows() or {}) do rows[#rows + 1] = r end
	rows[#rows + 1] = { label = "Remove every part", run = function() RunConsoleCommand("skategm_park_clear") end }
	return rows
end

function ED.PartsPage()
	return { title = "Parts", hints = CLOSE, rows = function()
		local rows = {}
		for _, c in ipairs(ED.Catalog()) do rows[#rows + 1] = { label = c.title, sub = #c.parts .. " parts", page = function() return ED.CategoryPage(c) end } end
		rows[#rows + 1] = { label = "Park", sub = "save, load, clear", page = function() return { title = "Park", rows = ED.ParkRows, hints = CLOSE } end }
		return rows
	end }
end

function ED.OpenMenu()
	ED.menu = {}
	List.Push(ED.menu, ED.PartsPage())
end

function ED.MenuInput(btn)
	if btn == B.X or List.Input(ED.menu, btn) == "empty" then ED.menu = nil end
end

---------------------------------------------------------------------------
-- placing: where the selected (or carried) part goes for this aim
---------------------------------------------------------------------------
function ED.Settings()
	local num = function(name, d) local cv = GetConVar and GetConVar(name) return cv and cv:GetFloat() or d end
	return { snap = ED.snap, grid = num("skategm_parts_grid", 0), turn = 0 }
end

function ED.IsPart(e) return IsValid(e) and e.SkateGMPart == true and e.PartId ~= nil end

-- the other parts near pos, as { id, pos, yaw, ent }
function ED.Neighbours(pos, except)
	local out = {}
	for _, e in ipairs(ents.FindInSphere(pos, 1200)) do
		if e ~= except and ED.IsPart(e) then out[#out + 1] = { id = e.PartId, pos = e:GetPos(), yaw = e:GetAngles().y, ent = e } end
	end
	return out
end

-- where def goes when aimed at `hit` (a point on the ground or a part) turned
-- to `yaw`: snapped to its neighbours or on the grid
function ED.Placement(def, hit, yaw, neighbours, settings)
	local pos, nyaw, joined = P.Place(def, hit, yaw, neighbours, settings, ED.SNAP_REACH)
	return pos, nyaw % 360, joined
end

function ED.Trace(from, dir, ignore)
	return util.TraceLine({ start = from, endpos = from + dir * ED.AIM_RANGE, mask = MASK_SOLID, filter = ignore })
end

function ED.UpdateAim()
	local cam = ED.cam
	local ignore = { LocalPlayer() }
	if ED.carry and IsValid(ED.carry.ent) then ignore[#ignore + 1] = ED.carry.ent end
	local tr = ED.Trace(cam.pos, cam.ang:Forward(), ignore)
	ED.aim = tr.Hit and { pos = tr.HitPos, normal = tr.HitNormal, ent = ED.IsPart(tr.Entity) and tr.Entity or nil } or nil
	local def = ED.carry and P.Get(ED.carry.id) or ED.selected
	ED.ghost = nil
	if def and ED.aim then
		local pos, yaw, joined = ED.Placement(def, ED.aim.pos, ED.yaw, ED.Neighbours(ED.aim.pos, ED.carry and ED.carry.ent), ED.Settings())
		ED.ghost = { def = def, pos = pos, yaw = yaw, joined = joined }
	end
end

function ED.Select(def)
	ED.CancelCarry()
	ED.selected = def
end

function ED.Pickup(e)
	if not ED.IsPart(e) then return end
	ED.carry = { ent = e, id = e.PartId, from = e:GetPos(), fromYaw = e:GetAngles().y }
	ED.yaw = e:GetAngles().y
	e:SetNoDraw(true)
end

function ED.CancelCarry()
	local c = ED.carry
	if c and IsValid(c.ent) then c.ent:SetNoDraw(false) end
	ED.carry = nil
end

function ED.PlaceGhost()
	local g = ED.ghost
	if not g then return false end
	if ED.carry then
		net.Start("skategm_editor_move")
		net.WriteEntity(ED.carry.ent)
		net.WriteVector(g.pos)
		net.WriteFloat(g.yaw)
		net.SendToServer()
		ED.CancelCarry()
	else
		net.Start("skategm_editor_place")
		net.WriteString(g.def.id)
		net.WriteVector(g.pos)
		net.WriteFloat(g.yaw)
		net.SendToServer()
	end
	ED.yaw = g.yaw
	surface.PlaySound("buttons/lightswitch2.wav")
	return true
end

function ED.RemoveAimed()
	local e = ED.aim and ED.aim.ent
	if not IsValid(e) then return false end
	net.Start("skategm_editor_remove")
	net.WriteEntity(e)
	net.SendToServer()
	surface.PlaySound("buttons/button15.wav")
	return true
end

---------------------------------------------------------------------------
-- entering and leaving
---------------------------------------------------------------------------
function ED.InMinigame()
	local M = SKATEGM_MODES
	return M ~= nil and M.Playing ~= nil and M.Playing()
end

function ED.Allowed()
	if ED.InMinigame() then return false end
	local cv = GetConVar and GetConVar("skategm_park_editor")
	local v = cv and cv:GetInt() or 1
	if v == 0 then return false end
	if v == 2 then
		local me = LocalPlayer()
		return (game and game.SinglePlayer and game.SinglePlayer()) or (IsValid(me) and me:IsAdmin())
	end
	return true
end

function ED.Enter()
	local a = API()
	if ED.active or not a or UI.Busy() then return end
	local view = a.View and a.View()
	local origin = view and view.origin or (LocalPlayer():EyePos())
	local ang = view and view.angles or LocalPlayer():EyeAngles()
	ED.active = true
	ED.cam = { pos = origin + Vector(0, 0, 24), ang = Angle(math.Clamp(ang.p, -60, 80), ang.y, 0) }
	ED.yaw = math.Round(ang.y / ED.TURN_STEP) * ED.TURN_STEP
	if ED.snap == nil then
		local cv = GetConVar and GetConVar("skategm_parts_snap")
		ED.snap = not cv or cv:GetBool()
	end
	ED.menu, ED.carry, ED.lastCam = nil, nil, 0
	UI.Take("editor", { press = ED.Input, think = ED.Think, close = function() ED.Exit(true) end },
		function(_, _, fov) return ED.active and { origin = ED.cam.pos, angles = ED.cam.ang, fov = fov } or nil end)
	net.Start("skategm_editor_state") net.WriteBool(true) net.SendToServer()
	surface.PlaySound("buttons/button9.wav")
end

-- back on the board: on the ground under the camera, facing its way
function ED.Exit(stay)
	if not ED.active then return end
	local a = API()
	ED.CancelCarry()
	ED.active, ED.menu = false, nil
	UI.Give("editor")
	if a then
		if not stay and a.TeleportTo then
			local tr = ED.Trace(ED.cam.pos, Vector(0, 0, -1), { LocalPlayer() })
			if tr.Hit and tr.HitNormal.z > 0.7 then a.TeleportTo(tr.HitPos + Vector(0, 0, 2), ED.cam.ang.y) end
		end
	end
	net.Start("skategm_editor_state") net.WriteBool(false) net.SendToServer()
end

---------------------------------------------------------------------------
-- the controller
---------------------------------------------------------------------------
function ED.Input(btn, buttons)
	if bit.band(buttons, B.LB) ~= 0 then
		if btn == B.B then ED.Exit() end
		return
	end
	if ED.menu then return ED.MenuInput(btn) end
	if btn == B.X then
		ED.OpenMenu()
	elseif btn == B.A then
		ED.PlaceGhost()
	elseif btn == B.Y then
		if ED.carry then ED.CancelCarry()
		elseif ED.aim and ED.aim.ent then ED.Pickup(ED.aim.ent) end
	elseif btn == B.B then
		if ED.carry then ED.CancelCarry() else ED.selected = nil end
	elseif btn == B.LEFT then
		ED.yaw = (ED.yaw + ED.TURN_STEP) % 360
	elseif btn == B.RIGHT then
		ED.yaw = (ED.yaw - ED.TURN_STEP) % 360
	elseif btn == B.UP then
		ED.snap = not ED.snap
	elseif btn == B.DOWN then
		if not ED.carry then ED.RemoveAimed() end
	end
end

function ED.Think(pad, now, dt)
	if ED.InMinigame() then ED.Exit(true) return end
	UI.Fly(ED.cam, pad, dt, ED.FLY, ED.LOOK, ED.FAST)
	ED.UpdateAim()
	if now - (ED.lastCam or 0) > ED.CAM_RATE then
		ED.lastCam = now
		net.Start("skategm_editor_cam", true)
		net.WriteVector(ED.cam.pos)
		net.WriteAngle(ED.cam.ang)
		net.SendToServer()
	end
end

UI.Combo(B.B, { open = ED.Enter, allowed = ED.Allowed, label = "park editor" })

---------------------------------------------------------------------------
-- everyone else's editor: a floating watermelon with a glowing eye
---------------------------------------------------------------------------
net.Receive("skategm_editor_cam", function()
	local ply, pos, ang = net.ReadEntity(), net.ReadVector(), net.ReadAngle()
	if not IsValid(ply) then return end
	local r = ED.remote[ply] or {}
	r.from, r.fromAng = r.pos or pos, r.ang or ang
	r.to, r.toAng, r.t = pos, ang, RealTime()
	r.pos, r.ang = r.pos or pos, r.ang or ang
	ED.remote[ply] = r
end)

net.Receive("skategm_editor_state", function()
	if not net.ReadBool() and ED.active then ED.Exit(true) end
end)

function ED.Remote(now)
	for ply, r in pairs(ED.remote) do
		local editing = IsValid(ply) and ply:GetNW2Bool("SkateGMEditing", false)
		if not editing or now - r.t > 3 then
			if IsValid(r.model) then r.model:Remove() end
			ED.remote[ply] = nil
		else
			local k = math.Clamp((now - r.t) / ED.CAM_RATE, 0, 1)
			r.pos = LerpVector(k, r.from, r.to)
			r.ang = LerpAngle(k, r.fromAng, r.toAng)
		end
	end
end

local glow
function ED.DrawMelons()
	glow = glow or Material("sprites/light_glow02_add")
	for _, r in pairs(ED.remote) do
		if not IsValid(r.model) then
			r.model = ClientsideModel(ED.MELON, RENDERGROUP_OPAQUE)
			if IsValid(r.model) then
				r.model:SetModelScale(ED.MELON_SCALE)
				r.model:SetNoDraw(true)
			end
		end
		if IsValid(r.model) and r.pos then
			local bob = math.sin(RealTime() * 2.2) * 2
			local pos = r.pos + Vector(0, 0, bob)
			r.model:SetPos(pos)
			r.model:SetAngles(Angle(r.ang.p, r.ang.y + 90, 0))
			r.model:DrawModel()
			local eye = pos + r.ang:Forward() * 6 * ED.MELON_SCALE + Vector(0, 0, 1.5 * ED.MELON_SCALE)
			render.SetMaterial(glow)
			render.DrawSprite(eye, 14, 14, Color(255, 70, 60))
			render.DrawSprite(eye, 5, 5, Color(255, 230, 220))
		end
	end
end

---------------------------------------------------------------------------
-- drawing: the ghost, what's aimed at, the HUD
---------------------------------------------------------------------------
local ghostMat
local GREEN, WHITE, YELLOW, RED = Color(90, 255, 140), PAD.WHITE, Color(255, 220, 80), Color(255, 90, 80)

function ED.DrawGhost()
	local g = ED.ghost
	if not g then return end
	local shape = P.Shape(g.def)
	ghostMat = ghostMat or CreateMaterial("skategm_part_ghost", "UnlitGeneric", { ["$basetexture"] = "color/white", ["$vertexcolor"] = "1", ["$vertexalpha"] = "1", ["$translucent"] = "1", ["$model"] = "1" })
	local M = Matrix()
	M:SetTranslation(g.pos)
	M:SetAngles(Angle(0, g.yaw, 0))
	cam.PushModelMatrix(M)
	render.SetBlend(0.45)
	render.SetColorModulation(g.joined and 0.6 or 1, 1, g.joined and 0.7 or 1)
	for _, m in ipairs(P.Meshes(g.def, 1)) do
		render.SetMaterial(ghostMat)
		m.mesh:Draw()
	end
	render.SetColorModulation(1, 1, 1)
	render.SetBlend(1)
	cam.PopModelMatrix()
	render.DrawWireframeBox(g.pos, Angle(0, g.yaw, 0), shape.mins, shape.maxs, g.joined and GREEN or WHITE, true)
end

function ED.DrawAimed()
	local e = ED.aim and ED.aim.ent
	if not (IsValid(e) and not ED.carry) then return end
	local def = P.Get(e.PartId)
	if not def then return end
	local shape = P.Shape(def)
	render.DrawWireframeBox(e:GetPos(), e:GetAngles(), shape.mins - Vector(1, 1, 0), shape.maxs + Vector(1, 1, 1), ED.selected and WHITE or YELLOW, true)
end

local function Text(t, font, x, y, col, ax) PAD.Text(t, font, x, y, col, ax or TEXT_ALIGN_CENTER) end

-- the controls, as rows of { buttons, what they do now, lit } for this moment
function ED.Legend()
	local aimingPart = ED.aim and ED.aim.ent ~= nil and not ED.carry
	local placing = ED.ghost ~= nil
	local rows = {}
	local function row(keys, text, lit) rows[#rows + 1] = { keys = keys, text = text, lit = lit } end
	if ED.carry then
		row({ "A" }, "Put it down here", placing)
		row({ "B" }, "Put it back where it was")
	elseif ED.selected then
		row({ "A" }, "Place " .. (ED.selected.title or ED.selected.id), placing)
		row({ "B" }, "Stop placing")
	else
		row({ "X" }, "Choose a part to place")
	end
	if ED.selected or ED.carry then
		row({ "LEFT", "RIGHT" }, "Turn it")
		row({ "X" }, "Choose another part")
	end
	if not ED.carry then
		row({ "Y" }, "Pick up the part under the dot", aimingPart)
		row({ "DOWN" }, "Remove the part under the dot", aimingPart)
	end
	row({ "UP" }, "Snapping: " .. (ED.snap and "ON" or "OFF"))
	rows[#rows + 1] = { gap = true }
	row({ "LS" }, "Fly")
	row({ "RS" }, "Look")
	row({ "LT", "RT" }, "Down / up")
	row({ "RB" }, "Hold to fly fast")
	rows[#rows + 1] = { keys = { "LB", "B" }, join = "+", text = "Back to skating" }
	return rows
end

-- the part, turning slowly, drawn into a box on the HUD (x, y, w, h)
ED.PREVIEW_SPIN = 40
function ED.PreviewCamera(def, t, aspect)
	local shape = P.Shape(def)
	local lo, hi = shape.mins, shape.maxs
	local centre = Vector(0, 0, (lo.z + hi.z) / 2)
	local radius = math.max(8, (hi - lo):Length() / 2)
	local fov = 30
	local dist = radius / math.sin(math.rad(fov / 2)) * (aspect < 1 and 1 / aspect or 1)
	local ang = Angle(22, 0, 0)
	return centre - ang:Forward() * dist, ang, fov, Angle(0, (t * ED.PREVIEW_SPIN) % 360, 0)
end

function ED.PaintPreview(def, x, y, w, h, t)
	if not (cam and cam.Start3D) then return end
	local origin, ang, fov, spin = ED.PreviewCamera(def, t, w / h)
	cam.Start3D(origin, ang, fov, x, y, w, h, 1, 100000)
	render.ClearDepth()
	local M = Matrix()
	M:SetAngles(spin)
	cam.PushModelMatrix(M)
	for _, g in ipairs(P.Meshes(def, 1)) do
		render.SetMaterial(P.Material(g.surface))
		g.mesh:Draw()
	end
	cam.PopModelMatrix()
	cam.End3D()
end

function ED.Paint(w, h)
	if not ED.active then return end
	PAD.Fonts()
	-- the eye: a glowing dot in the middle
	local c = ED.ghost and (ED.ghost.joined and GREEN or WHITE) or (ED.aim and ED.aim.ent and YELLOW or RED)
	draw.RoundedBox(5, w / 2 - 5, h / 2 - 5, 10, 10, Color(c.r, c.g, c.b, 230))
	draw.RoundedBox(2, w / 2 - 2, h / 2 - 2, 4, 4, WHITE)
	Text("Park editor", "skategm_ui_title", w / 2, h * 0.03, WHITE)
	local what = ED.carry and ("Moving: " .. ((P.Get(ED.carry.id) or {}).title or ED.carry.id)) or ED.selected and ("Placing: " .. (ED.selected.title or ED.selected.id)) or "Press X to choose a part"
	Text(what, "skategm_ui_row", w / 2, h * 0.075, ED.ghost and ED.ghost.joined and GREEN or WHITE)
	if ED.ghost and ED.ghost.joined then Text("snaps onto the part next to it", "skategm_ui_sub", w / 2, h * 0.11, GREEN) end
	-- what the dot is on, under it
	local aimed = ED.aim and ED.aim.ent and not ED.carry and P.Get(ED.aim.ent.PartId)
	if aimed then Text(aimed.title or aimed.id, "skategm_ui_sub", w / 2, h / 2 + 14, YELLOW) end
	if not ED.menu then PAD.Legend(ED.Legend(), w, h, "right") return end
	List.Paint(ED.menu, w, h, { width = 0.32, note = P.saves and P.saves.note })
end

if hook and hook.Add then
	hook.Add("Think", "skategm_park_editor", function() ED.Remote(RealTime()) end)
	hook.Add("HUDPaint", "skategm_park_editor", function() ED.Paint(ScrW(), ScrH()) end)
	hook.Add("PostDrawTranslucentRenderables", "skategm_park_editor", function(depth, sky)
		if depth or sky then return end
		ED.DrawMelons()
		if ED.active then
			ED.DrawAimed()
			ED.DrawGhost()
		end
	end)
end
