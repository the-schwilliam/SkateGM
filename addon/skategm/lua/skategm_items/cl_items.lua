-- Items, client: the crates (see-through, floating, turning), picking them
-- up, aiming, using (left stick in), the item panel (top right, where the
-- total score was) and each holder's item floating behind them.
local IT = ITEMS
IT.client = IT.client or { arenas = {}, holds = {}, models = {}, held = {} }
local C = IT.client

local function API() return SkateGM and SkateGM.API end
local function Send(t)
	net.Start(IT.NET)
	net.WriteString(util.TableToJSON(t))
	net.SendToServer()
end
C.Send = Send

local function Model(path, scale, alpha)
	local e = ClientsideModel(path, RENDERGROUP_TRANSLUCENT)
	if not IsValid(e) then return nil end
	e:SetModelScale(scale or 1, 0)
	if alpha then
		e:SetRenderMode(RENDERMODE_TRANSALPHA)
		e:SetColor(Color(255, 255, 255, alpha))
	end
	return e
end
C.Model = Model

function C.RemoveCrates(a)
	for _, c in pairs(a.crates or {}) do if IsValid(c.ent) then c.ent:Remove() end end
	a.crates = {}
end

---------------------------------------------------------------------------
-- the server
---------------------------------------------------------------------------
function C.Handle(m, now)
	if m.k == "arena" then
		local old = C.arenas[m.a]
		if old then C.RemoveCrates(old) end
		local a = { id = m.a, mode = m.m, session = m.s, crates = {} }
		for _, c in ipairs(m.crates or {}) do a.crates[c[1]] = { pos = Vector(c[2], c[3], c[4]) } end
		C.arenas[m.a] = a
	elseif m.k == "close" then
		local a = C.arenas[m.a]
		if a then C.RemoveCrates(a) end
		C.arenas[m.a] = nil
		for _, def in pairs(ITEMS.defs or {}) do
			if def.clear then pcall(def.clear, m.a) end
		end
	elseif m.k == "crate" then
		local a = C.arenas[m.a]
		if not a then return end
		local c = a.crates[m.i]
		if m.broken then
			if c then
				local pos = c.pos + Vector(0, 0, IT.CRATE_FLOAT)
				sound.Play("physics/wood/wood_box_break" .. math.random(1, 2) .. ".wav", pos, 75, 100, 1)
				local ed = EffectData()
				ed:SetOrigin(pos)
				util.Effect("WheelDust", ed)
				if IsValid(c.ent) then c.ent:Remove() end
			end
			a.crates[m.i] = nil
		elseif m.p then
			if c and IsValid(c.ent) then c.ent:Remove() end
			a.crates[m.i] = { pos = Vector(m.p[1], m.p[2], m.p[3]) }
		end
	elseif m.k == "hold" then
		C.holds[m.e] = m.id and { id = m.id, uses = m.uses } or nil
		if m.e == LocalPlayer():EntIndex() and m.id and C.mine ~= m.id then
			surface.PlaySound("buttons/button9.wav")
		end
	elseif m.k == "fx" then
		local def = IT.Get(m.item)
		if def and def.fx then
			local ok, err = pcall(def.fx, m, RealTime())
			if not ok then print("[SkateGM items] " .. tostring(err)) end
		end
	elseif m.k == "hit" then
		local a = API()
		if a and a.Wipeout then a.Wipeout() end
	elseif m.k == "freeze" then
		local a = API()
		if a and a.Freeze then
			a.Freeze(true, "items")
			C.frozenUntil = RealTime() + (tonumber(m.s) or 2)
		end
	end
end

if net and net.Receive then
	net.Receive(IT.NET, function()
		local m = util.JSONToTable(net.ReadString() or "")
		if type(m) == "table" then C.Handle(m, RealTime()) end
	end)
end

---------------------------------------------------------------------------
-- my arena: the game I'm in, if it has items on
---------------------------------------------------------------------------
function C.MyArena()
	local M = SKATEGM_MODES
	if not (M and M.MyGame) then return nil end
	local mode, st = M.MyGame()
	if not mode then return nil end
	for _, a in pairs(C.arenas) do
		if a.mode == mode.id and (a.session == nil or st.session == nil or a.session == st.session) then return a, mode, st end
	end
end

function C.Mine()
	local h = C.holds[LocalPlayer():EntIndex()]
	return h and IT.Get(h.id) and h or nil
end

-- the player nearest the middle of my view, for an aimed item: by the angle
-- off the camera's forward (ToScreen in Think doesn't see the frame's view);
-- the one already aimed at keeps it unless another is clearly nearer
C.AIM_COS = math.cos(math.rad(35))
function C.Target(def)
	local _, mode, st = C.MyArena()
	local a = API()
	if not (mode and a and a.PoseOf) then return nil end
	local me = a.SkaterPos and a.SkaterPos()
	local view = a.View and a.View()
	local eye = view and view.origin or me
	local fwd = view and view.angles and view.angles:Forward()
	if not (eye and fwd) then return nil end
	local best, bestD
	for _, p in ipairs(st.players or {}) do
		local ply = Entity(p.ent)
		if IsValid(ply) and ply ~= LocalPlayer() then
			local P = a.PoseOf(ply)
			local pos = P and P.HIPS
			if pos and (not me or me:Distance(pos) <= (def.target.range or 3000)) then
				local to = pos - eye
				local len = to:Length()
				local cos = len > 1 and fwd:Dot(to) / len or 1
				local d = cos >= C.AIM_COS and (1 - cos) * (ply == C.aim and 0.5 or 1) or nil
				if d and (not bestD or d < bestD) then best, bestD = ply, d end
			end
		end
	end
	return best
end

function C.Think(now)
	local a = API()
	if C.frozenUntil and now >= C.frozenUntil then
		C.frozenUntil = nil
		if a and a.Freeze then a.Freeze(false, "items") end
	end
	local arena = C.MyArena()
	local masking = arena ~= nil
	if a and a.SetButtonMask and masking ~= (C.masking or false) then
		C.masking = masking
		a.SetButtonMask(masking and IT.BUTTON or 0)
	end
	if not (arena and a and a.IsSkating and a.IsSkating()) then C.padPrev = nil return end
	local me = a.SkaterPos and a.SkaterPos()
	if me then
		C.picked = C.picked or {}
		for i, c in pairs(arena.crates) do
			if me:Distance(c.pos + Vector(0, 0, IT.CRATE_FLOAT)) < IT.TOUCH and now >= (C.picked[i] or 0) then
				C.picked[i] = now + 0.5
				Send({ k = "pick", i = i })
			end
		end
	end
	local h = C.Mine()
	C.mine = h and h.id or nil
	local def = h and IT.Get(h.id)
	C.aim = def and def.target and C.Target(def) or nil
	local pad = a.Pad and a.Pad()
	local buttons = pad and pad.buttons or 0
	local pressed = bit.band(buttons, IT.BUTTON) ~= 0 and bit.band(C.padPrev or 0, IT.BUTTON) == 0
	C.padPrev = buttons
	if pressed and def and not (SKATEGM_UI and SKATEGM_UI.Busy and SKATEGM_UI.Busy()) then
		if def.target and not C.aim then
			surface.PlaySound("buttons/button10.wav")
		else
			local f = (a.View and a.View() and a.View().angles or EyeAngles()):Forward()
			Send({ k = "use", target = C.aim and C.aim:EntIndex() or nil, dir = { f.x, f.y, f.z } })
		end
	end
end
hook.Add("Think", "skategm_items", function() C.Think(RealTime()) end)

---------------------------------------------------------------------------
-- in the world: crates, held items behind their holders, the items' own
---------------------------------------------------------------------------
function C.DrawCrates(now)
	for _, a in pairs(C.arenas) do
		for i, c in pairs(a.crates) do
			if not IsValid(c.ent) then c.ent = Model(IT.CRATE_MODEL, IT.CRATE_SCALE, 150) end
			local pos = c.pos + Vector(0, 0, IT.CRATE_FLOAT + math.sin(now * 2 + i) * 5)
			if IsValid(c.ent) then
				c.ent:SetAngles(Angle(math.sin(now * 1.3 + i) * 10, (now * 75 + i * 37) % 360, math.cos(now * 1.1 + i) * 6))
				local centre = c.ent:LocalToWorld(c.ent:OBBCenter()) - c.ent:GetPos()
				c.ent:SetPos(pos - centre)
			end
		end
	end
end

-- behind a skater: away from where they're going (they ride side-on, so
-- not the chest); standing still, along the board
C.trail = C.trail or {}
C.HELD_SIZE, C.HELD_BACK, C.HELD_UP, C.HIPS_UP = 24, 38, 24, 34
C.TURN_TIME, C.SPEED_TIME, C.MOVING = 0.25, 0.15, 40
function C.Behind(ent, P, now)
	local t = C.trail[ent] or {}
	C.trail[ent] = t
	local dt = t.at and math.Clamp(now - t.at, 0, 0.1) or 0
	if t.pos and dt > 0 then
		local v = (P.HIPS - t.pos) / dt
		v.z = 0
		t.vel = t.vel and LerpVector(1 - math.exp(-dt / C.SPEED_TIME), t.vel, v) or v
	end
	t.pos, t.at = P.HIPS, now
	local want
	if t.vel and t.vel:Length() > C.MOVING then
		want = t.vel:GetNormalized()
	elseif P.TRUCK_FRONT and P.TRUCK_BACK then
		want = P.TRUCK_FRONT - P.TRUCK_BACK
		want.z = 0
		want = want:LengthSqr() > 0 and want:GetNormalized() or nil
		if want and t.dir and want:Dot(t.dir) < 0 then want = -want end
	end
	if want then
		t.dir = t.dir and LerpVector(1 - math.exp(-dt / C.TURN_TIME), t.dir, want) or want
		if t.dir:LengthSqr() < 1e-4 then t.dir = want end
		t.dir = t.dir:GetNormalized()
	end
	return -(t.dir or Vector(1, 0, 0))
end

function C.DrawHeld(now)
	local a = API()
	local seen = {}
	for ent, h in pairs(C.holds) do
		local def = IT.Get(h.id)
		local ply = Entity(ent)
		local P = a and IsValid(ply) and a.PoseOf and a.PoseOf(ply)
		if def and P and P.HIPS then
			seen[ent] = true
			local m = C.held[ent]
			if not (m and IsValid(m.ent) and m.id == h.id) then
				if m and IsValid(m.ent) then m.ent:Remove() end
				m = { id = h.id, ent = Model(def.model, 1) }
				if IsValid(m.ent) then
					local mn, mx = m.ent:GetModelBounds()
					local r = mn and mx and (mx - mn):Length() or 0
					m.ent:SetModelScale(r > 1 and math.Clamp(C.HELD_SIZE / r, 0.2, 3) or 1, 0)
				end
				C.held[ent] = m
			end
			local back = C.Behind(ent, P, now)
			if IsValid(m.ent) then
				m.ent:SetAngles(Angle(0, (now * 90) % 360, 0))
				local want = P.HIPS + back * C.HELD_BACK + Vector(0, 0, C.HELD_UP - C.HIPS_UP + math.sin(now * 3 + ent) * 2)
				m.at = want
				local centre = m.ent:LocalToWorld(m.ent:OBBCenter()) - m.ent:GetPos()
				m.ent:SetPos(want - centre)
			end
		end
	end
	for ent, m in pairs(C.held) do
		if not seen[ent] then
			if IsValid(m.ent) then m.ent:Remove() end
			C.held[ent] = nil
		end
	end
end

local aura
function C.DrawAuras(now)
	aura = aura or Material("sprites/light_glow02_add")
	render.SetMaterial(aura)
	for ent, m in pairs(C.held) do
		if m.at then
			local def = IT.Get(m.id)
			local col = def and def.color or Color(255, 220, 120)
			local pulse = 0.8 + 0.2 * math.sin(now * 5 + ent)
			render.DrawSprite(m.at, 64 * pulse, 64 * pulse, Color(col.r, col.g, col.b, 170))
			render.DrawSprite(m.at, 30, 30, Color(255, 255, 255, 120))
		end
	end
end

-- every crate outlined (GMod's halo: an even glowing edge, not seen through walls)
function C.CrateEntities()
	local list = {}
	for _, a in pairs(C.arenas) do
		for _, c in pairs(a.crates) do if IsValid(c.ent) then list[#list + 1] = c.ent end end
	end
	return list
end
if hook and hook.Add then
	hook.Add("PreDrawHalos", "skategm_items", function()
		local list = C.CrateEntities()
		if #list > 0 and halo and halo.Add then
			local pulse = 0.75 + 0.25 * math.sin(RealTime() * 3)
			local c = IT.CRATE_OUTLINE
			halo.Add(list, Color(c.r, c.g, c.b, 255 * pulse), 3, 3, 2, true, false)
		end
	end)
end

hook.Add("PostDrawTranslucentRenderables", "skategm_items", function(depth, sky)
	if depth or sky then return end
	local now = RealTime()
	C.DrawCrates(now)
	C.DrawHeld(now)
	C.DrawAuras(now)
	for _, id in ipairs(IT.order) do
		local def = IT.defs[id]
		if def.draw then
			local ok, err = pcall(def.draw, now)
			if not ok and not C.drawErr then C.drawErr = true print("[SkateGM items] " .. id .. ": " .. tostring(err)) end
		end
	end
	local mine = C.mine and IT.Get(C.mine)
	if mine and mine.aim then
		local hips, fwd = C.MyThrow()
		if hips then
			local ok, err = pcall(mine.aim, now, hips, fwd)
			if not ok and not C.aimErr then C.aimErr = true print("[SkateGM items] " .. C.mine .. " aim: " .. tostring(err)) end
		end
	end
end)

function C.MyThrow()
	local a = API()
	local ply = LocalPlayer()
	local P = a and a.PoseOf and a.PoseOf(ply)
	if not (P and P.HIPS) then return nil end
	local t = C.trail[ply:EntIndex()]
	local fwd = t and t.dir
	if not fwd then
		fwd = EyeAngles():Forward()
		fwd.z = 0
		fwd = fwd:GetNormalized()
	end
	return P.HIPS, fwd
end

---------------------------------------------------------------------------
-- on screen: the aim box and the item panel
---------------------------------------------------------------------------
function C.CornerTaken() return C.Mine() ~= nil and C.MyArena() ~= nil end

-- the preview: the item turning and bobbing in its own little 3D view
function C.DrawPreview(def, x, y, size, now)
	local e = C.preview
	if not (IsValid(e) and C.previewFor == def.id) then
		if IsValid(e) then e:Remove() end
		e = Model(def.model, 1)
		if not IsValid(e) then return end
		e:SetNoDraw(true)
		C.preview, C.previewFor = e, def.id
	end
	local mn, mx = e:GetModelBounds()
	local r = mn and mx and (mx - mn):Length() or 32
	e:SetAngles(Angle(0, (now * 70) % 360, 0))
	local centre = e:LocalToWorld(e:OBBCenter()) - e:GetPos()
	e:SetPos(Vector(0, 0, math.sin(now * 2.5) * r * 0.03) - centre)
	local eye = Vector(r * 0.95, 0, r * 0.4)
	cam.Start3D(eye, (-eye):Angle(), 40, x, y, size, size, 1, r * 4)
	render.SuppressEngineLighting(true)
	render.SetLightingOrigin(Vector(0, 0, 0))
	render.ResetModelLighting(0.55, 0.55, 0.6)
	render.SetModelLighting(BOX_TOP, 1, 1, 1)
	render.SetModelLighting(BOX_FRONT, 0.9, 0.9, 0.9)
	e:DrawModel()
	render.SuppressEngineLighting(false)
	cam.End3D()
end

-- what to press, in the words of what I'm holding (keyboard: Alt)
function C.UseKey()
	local PAD = SKATEGM_UI and SKATEGM_UI.pad
	if PAD and PAD.KeyboardHints and PAD.KeyboardHints() then return "Alt" end
	if PAD and PAD.Style and PAD.Style() == "playstation" then return "L3" end
	return "Left stick in"
end

function C.Paint(w, h)
	if SKATEGM_MODES.HudHidden() then return end
	local hold = C.Mine()
	local show = hold ~= nil and C.MyArena() ~= nil
	if not show then return end
	local def = IT.Get(hold.id)
	local size = math.floor(h * 0.12)
	local x, y = w - size - w * 0.02, h * 0.03
	draw.RoundedBox(10, x - 8, y - 8, size + 16, size + h * 0.06 + 16, Color(0, 0, 0, 170))
	C.DrawPreview(def, x, y, size, RealTime())
	local M = SKATEGM_MODES
	local font = SKATEGM_UI and SKATEGM_UI.pad and "skategm_ui_row" or "DermaDefaultBold"
	if SKATEGM_UI and SKATEGM_UI.pad then SKATEGM_UI.pad.Fonts() end
	local label = string.upper(def.title) .. ((hold.uses or 1) > 1 and ("  x" .. hold.uses) or "")
	M.Text(label, font, x + size / 2, y + size + h * 0.005, color_white, TEXT_ALIGN_CENTER)
	M.Text(C.UseKey() .. ": use", "DermaDefault", x + size / 2, y + size + h * 0.032, Color(200, 200, 200), TEXT_ALIGN_CENTER)
	if C.aim and def.target then
		local a = API()
		local P = a and a.PoseOf and a.PoseOf(C.aim)
		local s = P and P.HIPS and P.HIPS:ToScreen()
		if s and s.visible then
			local col = def.target.color or Color(255, 40, 40)
			local r = math.floor(h * 0.04)
			surface.SetDrawColor(col.r, col.g, col.b, 230)
			for k = 0, 2 do surface.DrawOutlinedRect(s.x - r - k, s.y - r - k, (r + k) * 2, (r + k) * 2) end
		end
	end
end
hook.Add("HUDPaint", "skategm_items", function() C.Paint(ScrW(), ScrH()) end)
