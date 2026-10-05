local S = SkateGM
local R = S.replay

R.MODES = { "chase", "tripod", "free" }
R.MODE_NAMES = { chase = "Chase", tripod = "Tripod", free = "Free" }
R.MODE_COLOURS = { chase = Color(120, 220, 255), tripod = Color(255, 200, 70), free = Color(150, 255, 140) }
R.SHAKE_NAMES = { [0] = "Off", "Light", "Strong" }
R.SHAKE_AMOUNTS = { [0] = 0, 0.6, 1.4 }
R.FOV_MIN, R.FOV_MAX, R.FOV_DEFAULT = 20, 120, 75
R.ZOOM_MIN, R.ZOOM_MAX = 40, 800
R.KEY_SNAP = 0.05
R.CHASE_PITCH_MIN, R.CHASE_PITCH_MAX = -10, 80
R.TRIPOD_BELOW = 15
R.WALL_GAP = 6

function R.KeepOut(target, origin)
	if not (util and util.TraceLine) then return origin end
	local tr = util.TraceLine({ start = target, endpos = origin, mask = MASK_SOLID_BRUSHONLY })
	if tr and tr.Hit and tr.HitPos then
		local n = tr.HitNormal or Vector(0, 0, 1)
		return tr.HitPos + n * R.WALL_GAP
	end
	return origin
end

function R.Target(clip, t)
	local P = R.PoseAt(clip, t)
	return P and P.HIPS and (P.HIPS + Vector(0, 0, 10)) or Vector(0, 0, 0)
end

function R.TravelDir(clip, t)
	local here = R.Target(clip, t)
	for back = 0.4, 3, 0.3 do
		local d = R.Target(clip, t + 0.1) - R.Target(clip, t - back)
		d.z = 0
		if d:LengthSqr() > 4 then return d:GetNormalized() end
	end
	local d = R.Target(clip, R.Duration(clip)) - R.Target(clip, 0)
	d.z = 0
	if d:LengthSqr() > 4 then return d:GetNormalized() end
	return Vector(1, 0, 0), here
end

local function Wave(t, a, b, c)
	return 0.6 * math.sin(t * a) + 0.3 * math.sin(t * b + 1.3) + 0.15 * math.sin(t * c + 2.1)
end

function R.Shake(t, k)
	return Angle(Wave(t, 1.9, 4.3, 9.7) * 1.4 * k, Wave(t, 1.3, 3.7, 8.1) * 1.8 * k, Wave(t, 0.9, 2.9, 6.3) * 0.8 * k)
end

function R.ShakeAmount(level)
	local lo = math.floor(level)
	local hi = math.min(lo + 1, #R.SHAKE_AMOUNTS)
	local a, b = R.SHAKE_AMOUNTS[lo] or 0, R.SHAKE_AMOUNTS[hi] or 0
	return a + (b - a) * (level - lo)
end

function R.NewCam(mode, clip, t, fov, view, shake)
	local target = R.Target(clip, t)
	local dir = R.TravelDir(clip, t)
	local p = { mode = mode, fov = fov or R.FOV_DEFAULT, shake = shake or 0 }
	if mode == "chase" then
		p.yaw, p.pitch, p.dist = 0, 15, 160
	elseif mode == "tripod" then
		p.pos = view and Vector(view.origin) or (target - dir * 220 + Vector(0, 0, 70))
	else
		p.pos = view and Vector(view.origin) or (target - dir * 160 + Vector(0, 0, 60))
		local a = view and Angle(view.angles.p, view.angles.y, 0) or (target - p.pos):Angle()
		p.ang = Angle(math.NormalizeAngle(a.p), a.y, 0)
	end
	return p
end

function R.CopyCam(p)
	local c = {}
	for k, v in pairs(p) do
		if type(v) == "Vector" or (type(v) == "table" and v.x and v.z and not v.p) then c[k] = Vector(v.x, v.y, v.z)
		elseif type(v) == "Angle" or (type(v) == "table" and v.p ~= nil) then c[k] = Angle(v.p, v.y, v.r)
		else c[k] = v end
	end
	return c
end

local ANGLES = { chase = { 3 }, tripod = {}, free = { 6, 7 } }

local function Channels(k)
	local c = { k.fov, k.shake or 0 }
	if k.mode == "chase" then
		c[3], c[4], c[5] = k.yaw, k.pitch, k.dist
	else
		c[3], c[4], c[5] = k.pos.x, k.pos.y, k.pos.z
		if k.mode == "free" then c[6], c[7] = k.ang.p, k.ang.y end
	end
	return c
end

local function Unwrap(c, ref, mode)
	for _, a in ipairs(ANGLES[mode]) do c[a] = ref[a] + math.NormalizeAngle(c[a] - ref[a]) end
	return c
end

function R.SplineCam(prev, k, n, nxt, f)
	local ck = Channels(k)
	local cn = Unwrap(Channels(n), ck, k.mode)
	local dt = n.t - k.t
	local f2, f3 = f * f, f * f * f
	local h00, h10, h01, h11 = 2 * f3 - 3 * f2 + 1, f3 - 2 * f2 + f, -2 * f3 + 3 * f2, f3 - f2
	local cp = prev and Unwrap(Channels(prev), ck, k.mode)
	local cx = nxt and Unwrap(Channels(nxt), cn, k.mode)
	local out = {}
	for j = 1, #ck do
		local m0 = cp and (cn[j] - cp[j]) / (n.t - prev.t) or 0
		local m1 = cx and (cx[j] - ck[j]) / (nxt.t - k.t) or 0
		out[j] = h00 * ck[j] + h10 * dt * m0 + h01 * cn[j] + h11 * dt * m1
	end
	local c = R.CopyCam(k)
	c.fov = math.Clamp(out[1], R.FOV_MIN, R.FOV_MAX)
	c.shake = math.max(0, out[2])
	if k.mode == "chase" then
		c.yaw, c.pitch, c.dist = math.NormalizeAngle(out[3]), out[4], math.max(1, out[5])
	else
		c.pos = Vector(out[3], out[4], out[5])
		if k.mode == "free" then c.ang = Angle(math.Clamp(out[6], -89, 89), out[7], 0) end
	end
	return c
end

function R.KeyedCam(keys, t)
	if not keys or #keys == 0 then return nil end
	local i = 0
	for n, k in ipairs(keys) do
		if k.t <= t + 1e-6 then i = n else break end
	end
	if i == 0 then return keys[1], 1 end
	local k, n = keys[i], keys[i + 1]
	if n and n.mode == k.mode and n.t > k.t then
		local prev, nxt = keys[i - 1], keys[i + 2]
		if not (prev and prev.mode == k.mode and prev.t < k.t) then prev = nil end
		if not (nxt and nxt.mode == k.mode and nxt.t > n.t) then nxt = nil end
		return R.SplineCam(prev, k, n, nxt, math.Clamp((t - k.t) / (n.t - k.t), 0, 1)), i
	end
	return k, i
end

function R.EvalCam(p, clip, t)
	local target = R.Target(clip, t)
	local origin, angles
	if p.mode == "chase" then
		local ang = Angle(p.pitch, R.TravelDir(clip, t):Angle().y + p.yaw, 0)
		origin = R.KeepOut(target, target - ang:Forward() * p.dist)
		angles = (target - origin):Angle()
	elseif p.mode == "tripod" then
		origin = R.KeepOut(target, p.pos)
		angles = (target - origin):Angle()
	else
		origin = p.pos
		angles = p.ang
	end
	local k = R.ShakeAmount(p.shake or 0)
	if k > 0 then angles = angles + R.Shake(t, k) end
	return origin, angles, p.fov
end

function R.SetKey(keys, cam, t)
	local key = R.CopyCam(cam)
	key.t = t
	for i = #keys, 1, -1 do
		if math.abs(keys[i].t - t) <= R.KEY_SNAP then table.remove(keys, i) end
	end
	keys[#keys + 1] = key
	table.sort(keys, function(a, b) return a.t < b.t end)
	return key
end

function R.KeyAt(keys, t)
	for i, k in ipairs(keys or {}) do
		if math.abs(k.t - t) <= R.KEY_SNAP then return i, k end
	end
end

function R.Steer(p, pad, dt, clip, t)
	local Dead = SKATEGM_UI.pad.Dead
	local lx, ly, rx, ry = Dead(pad.lx), Dead(pad.ly), Dead(pad.rx), Dead(pad.ry)
	local zoom = (pad.lt or 0) - (pad.rt or 0)
	if lx == 0 and ly == 0 and rx == 0 and ry == 0 and math.abs(zoom) < 0.05 then return false end
	if p.mode == "chase" then
		p.yaw = math.NormalizeAngle(p.yaw - rx * 120 * dt)
		p.pitch = math.Clamp(p.pitch - ry * 80 * dt, R.CHASE_PITCH_MIN, R.CHASE_PITCH_MAX)
		p.dist = math.Clamp(p.dist + zoom * 220 * dt, R.ZOOM_MIN, R.ZOOM_MAX)
	elseif p.mode == "tripod" then
		local target = R.Target(clip, t)
		local off = p.pos - target
		local a = off:Angle()
		local dist = math.Clamp(off:Length() + zoom * 260 * dt, R.ZOOM_MIN, R.ZOOM_MAX * 2)
		local ang = Angle(math.Clamp(math.NormalizeAngle(a.p) + ry * 70 * dt, -80, R.TRIPOD_BELOW), a.y - rx * 110 * dt, 0)
		local flat = Angle(0, (target - p.pos):Angle().y, 0)
		local move = (flat:Forward() * ly + flat:Right() * lx) * 300 * dt
		p.pos = R.KeepOut(target, target + ang:Forward() * dist + move)
	else
		p.ang = Angle(math.Clamp(math.NormalizeAngle(p.ang.p) - ry * 100 * dt, -89, 89), p.ang.y - rx * 140 * dt, 0)
		p.pos = p.pos + (p.ang:Forward() * ly + p.ang:Right() * lx + Vector(0, 0, -zoom)) * 500 * dt
	end
	return true
end

local function Num(v) return string.format("%.3f", v) end

function R.EncodeKey(k)
	local parts = { "key", Num(k.t), k.mode, Num(k.fov), tostring(math.floor((k.shake or 0) + 0.5)) }
	if k.mode == "chase" then
		parts[#parts + 1] = Num(k.yaw) parts[#parts + 1] = Num(k.pitch) parts[#parts + 1] = Num(k.dist)
	else
		parts[#parts + 1] = Num(k.pos.x) parts[#parts + 1] = Num(k.pos.y) parts[#parts + 1] = Num(k.pos.z)
		if k.mode == "free" then parts[#parts + 1] = Num(k.ang.p) parts[#parts + 1] = Num(k.ang.y) end
	end
	return table.concat(parts, " ")
end

function R.DecodeKey(line)
	local words = {}
	for w in line:gmatch("%S+") do words[#words + 1] = w end
	local t, mode, fov, shake = tonumber(words[2]), words[3], tonumber(words[4]), tonumber(words[5])
	if not (t and R.MODE_NAMES[mode] and fov and shake) then return nil end
	local n = {}
	for i = 6, #words do n[#n + 1] = tonumber(words[i]) end
	local k = { t = t, mode = mode, fov = math.Clamp(fov, R.FOV_MIN, R.FOV_MAX), shake = math.Clamp(math.floor(shake), 0, #R.SHAKE_AMOUNTS) }
	if mode == "chase" then
		if #n < 3 then return nil end
		k.yaw, k.pitch, k.dist = n[1], n[2], math.Clamp(n[3], R.ZOOM_MIN, R.ZOOM_MAX)
	else
		if #n < 3 then return nil end
		k.pos = Vector(n[1], n[2], n[3])
		if mode == "free" then
			if #n < 5 then return nil end
			k.ang = Angle(n[4], n[5], 0)
		end
	end
	return k
end
