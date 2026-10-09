-- Watching other skaters, for every minigame: a mode calls
-- mode:Spectate(ents, { prefer = ent }) with who can be watched (nil or {}
-- stops). Following: a chase camera behind them, the right stick turns it
-- around them, D-pad left / right picks the next one. Y: a free camera (left
-- stick flies, right stick looks, triggers down / up), Y again follows.
-- My own skater stands still, hidden, without input, while I watch.
local M = SKATEGM_MODES
local SP = M.spectate or {}
M.spectate = SP
SP.DIST, SP.HEIGHT = 140, 20
SP.TURN_SPEED, SP.PITCH_MIN, SP.PITCH_MAX = 150, -20, 70
SP.FREE_SPEED, SP.FREE_LOOK = 650, 120
SP.LOST_SWITCH = 1.5
local B = { UP = 0x0001, DOWN = 0x0002, LEFT = 0x0004, RIGHT = 0x0008, Y = 0x8000 }
SP.B = B

local function Dead(v) v = v or 0 if math.abs(v) < 0.18 then return 0 end return v end

function SP.Has(list, ent)
	for _, e in ipairs(list or {}) do if e == ent then return true end end
	return false
end

function SP.Set(on)
	local a = M.API()
	if not a then return end
	if a.Freeze then a.Freeze(on, "spectate") end
	if a.SetHidden then a.SetHidden("spectate", on) end
	if a.BlockInput then a.BlockInput(on, "spectate") end
	if a.SetView then a.SetView(on and function(origin, angles, fov) return SP.View(origin, angles, fov) end or nil, "spectate") end
end

function SP.Start(owner, ents, opts)
	opts = opts or {}
	SP.owner, SP.ents = owner, ents
	if not SP.on then
		SP.on, SP.yaw, SP.pitch, SP.free, SP.cam, SP.padPrev = true, 0, 15, nil, nil, nil
		SP.Set(true)
	end
	if opts.prefer and opts.prefer ~= 0 and opts.prefer ~= SP.prefer and SP.Has(ents, opts.prefer) then
		SP.target, SP.cam = opts.prefer, nil
	end
	SP.prefer = opts.prefer
	if not SP.Has(ents, SP.target) then SP.target, SP.cam = ents[1], nil end
	SP.Watched()
end

function SP.Stop()
	if not SP.on then return end
	SP.on, SP.owner, SP.ents, SP.target, SP.prefer, SP.free, SP.cam = nil, nil, nil, nil, nil, nil, nil
	SP.Set(false)
	SP.Watched()
end

function SP.Watched()
	local a = M.API()
	if a and a.SetWatched then a.SetWatched(SP.on and SP.target and Entity(SP.target) or nil) end
end

function SP.Next(dir)
	local ents = SP.ents or {}
	if #ents == 0 then return end
	local i = 1
	for k, e in ipairs(ents) do if e == SP.target then i = k end end
	SP.target = ents[(i - 1 + dir) % #ents + 1]
	SP.cam, SP.free = nil, nil
	SP.Watched()
end

function SP.TargetPose()
	local a = M.API()
	local ply = SP.target and Entity(SP.target)
	local P = a and IsValid(ply) and a.PoseOf and a.PoseOf(ply)
	return P and P.HIPS and P or nil, ply
end

-- where to look: the watched skater's hips, else their player (no pose from
-- them yet, or they're on foot); nobody to see for a while: the next one who is
function SP.Aim()
	local P, ply = SP.TargetPose()
	if P then return P.HIPS + Vector(0, 0, 10) end
	if IsValid(ply) and ply.GetPos then
		local p = ply:GetPos()
		if p and (p.x ~= 0 or p.y ~= 0 or p.z ~= 0) then return p + Vector(0, 0, 40) end
	end
end

function SP.Follow()
	local target = SP.Aim()
	local now = RealTime and RealTime() or 0
	if target then SP.lostSince = nil else SP.lostSince = SP.lostSince or now end
	if not target and #(SP.ents or {}) > 1 and now - SP.lostSince > SP.LOST_SWITCH then
		SP.lostSince = nil
		SP.Next(1)
		target = SP.Aim()
	end
	local cam = SP.cam or {}
	SP.cam = cam
	if target then
		if cam.last then
			local moved = target - cam.last
			moved.z = 0
			if moved:LengthSqr() > 0.25 then cam.dir = LerpVector(0.08, cam.dir or moved:GetNormalized(), moved:GetNormalized()) end
		end
		cam.last = target
	end
	if not cam.last then return nil end
	local base = cam.dir and cam.dir:Angle().y or 0
	local ang = Angle(SP.pitch, base + SP.yaw, 0)
	local want = cam.last - ang:Forward() * SP.DIST + Vector(0, 0, SP.HEIGHT)
	if util and util.TraceLine then
		local tr = util.TraceLine({ start = cam.last, endpos = want, mask = MASK_SOLID_BRUSHONLY })
		if tr and tr.Hit and tr.HitPos then want = tr.HitPos + (cam.last - want):GetNormalized() * 6 end
	end
	cam.pos = cam.pos and LerpVector(0.15, cam.pos, want) or want
	return cam.pos, (cam.last - cam.pos):Angle()
end

function SP.View(origin, angles, fov)
	if not SP.on then return nil end
	if SP.free then return { origin = SP.free.pos, angles = SP.free.ang, fov = fov, drawviewer = false } end
	local pos, ang = SP.Follow()
	if not pos then return nil end
	return { origin = pos, angles = ang, fov = fov, drawviewer = false }
end

function SP.Input(pad, dt)
	local buttons = pad.buttons or 0
	local pressed = bit.band(buttons, bit.bnot(SP.padPrev or 0))
	SP.padPrev = buttons
	if bit.band(pressed, B.LEFT) ~= 0 then SP.Next(-1) end
	if bit.band(pressed, B.RIGHT) ~= 0 then SP.Next(1) end
	if bit.band(pressed, B.Y) ~= 0 then
		if SP.free then
			SP.free = nil
		else
			local pos, ang = SP.Follow()
			SP.free = { pos = pos or Vector(0, 0, 0), ang = ang or Angle(0, 0, 0) }
		end
	end
	local rx, ry = Dead(pad.rx), Dead(pad.ry)
	if SP.free then
		local f = SP.free
		f.ang = Angle(math.Clamp(f.ang.p - ry * SP.FREE_LOOK * dt, -89, 89), f.ang.y - rx * SP.FREE_LOOK * dt, 0)
		local lx, ly = Dead(pad.lx), Dead(pad.ly)
		local up = (pad.rt or 0) - (pad.lt or 0)
		f.pos = f.pos + (f.ang:Forward() * ly + f.ang:Right() * lx + Vector(0, 0, up)) * SP.FREE_SPEED * dt
	else
		SP.yaw = (SP.yaw - rx * SP.TURN_SPEED * dt) % 360
		SP.pitch = math.Clamp(SP.pitch - ry * SP.TURN_SPEED * 0.6 * dt, SP.PITCH_MIN, SP.PITCH_MAX)
	end
end

function SP.Think(dt)
	if not SP.on then return end
	local UI = SKATEGM_UI
	if UI and UI.Busy and UI.Busy() then SP.padPrev = 0xFFFF return end
	local a = M.API()
	local pad = a and a.Pad and a.Pad()
	if pad then SP.Input(pad, dt) end
end

function SP.Name()
	local ply = SP.target and Entity(SP.target)
	return IsValid(ply) and ply.Nick and ply:Nick() or "?"
end

function SP.Legend()
	if SP.free then
		return { { keys = { "LS" }, text = "Fly" }, { keys = { "RS" }, text = "Look" }, { keys = { "LT", "RT" }, text = "Down / up" }, { keys = { "Y" }, text = "Follow " .. SP.Name() } }
	end
	local rows = { { keys = { "RS" }, text = "Turn the camera" }, { keys = { "Y" }, text = "Free camera" } }
	if #(SP.ents or {}) > 1 then table.insert(rows, 1, { keys = { "LEFT", "RIGHT" }, text = "Watch someone else" }) end
	return rows
end

function SP.Paint(w, h)
	if not SP.on or M.HudHidden() then return end
	local PAD = SKATEGM_UI and SKATEGM_UI.pad
	M.Text(SP.free and "FREE CAMERA" or ("WATCHING " .. string.upper(SP.Name())), "DermaLarge", w / 2, h * 0.8, color_white)
	local score = not SP.free and M.polish and M.polish.ScoreLine and M.polish.ScoreLine(SP.target)
	if score then
		if PAD and PAD.Fonts then PAD.Fonts() end
		M.Text(score, PAD and "skategm_ui_row" or "DermaDefaultBold", w / 2, h * 0.8 + 36, Color(255, 210, 90))
	end
	if PAD and PAD.Legend then PAD.Legend(SP.Legend(), w, h, "bottom") end
end

if hook and hook.Add then
	hook.Add("Think", "skategm_spectate", function() SP.Think(FrameTime and FrameTime() or 0) end)
	hook.Add("HUDPaint", "skategm_spectate", function() SP.Paint(ScrW(), ScrH()) end)
	hook.Add("CalcView", "skategm_spectate", function(_, origin, angles, fov)
		local a = M.API()
		if SP.on and not (a and a.IsSkating and a.IsSkating()) then return SP.View(origin, angles, fov) end
	end)
end

return SP
