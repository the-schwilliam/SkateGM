-- Minimal GMod math mock with Source conventions (mathlib AngleMatrix / MatrixAngles)
local V = {} V.__index = V
function Vector(x, y, z) if type(x) == "string" then local a, b, c = x:match("(%S+)%s+(%S+)%s+(%S+)") x, y, z = tonumber(a), tonumber(b), tonumber(c) end if type(x) == "table" then return setmetatable({ x = x.x, y = x.y, z = x.z }, V) end return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
V.__add = function(a, b) return Vector(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__mul = function(a, b) if type(a) == "number" then a, b = b, a end return Vector(a.x * b, a.y * b, a.z * b) end
V.__div = function(a, b) return Vector(a.x / b, a.y / b, a.z / b) end
V.__unm = function(a) return Vector(-a.x, -a.y, -a.z) end
function V:Dot(b) return self.x * b.x + self.y * b.y + self.z * b.z end
function V:Cross(b) return Vector(self.y * b.z - self.z * b.y, self.z * b.x - self.x * b.z, self.x * b.y - self.y * b.x) end
function V:Length() return math.sqrt(self:Dot(self)) end
function V:LengthSqr() return self:Dot(self) end
function V:Length2D() return math.sqrt(self.x * self.x + self.y * self.y) end
function V:Normalize() local l = self:Length() if l > 0 then self.x, self.y, self.z = self.x / l, self.y / l, self.z / l end end
function V:GetNormalized() local l = self:Length() return l > 0 and self / l or Vector() end
function V:DistToSqr(b) local d = self - b return d:Dot(d) end
function V:Distance(b) return (self - b):Length() end
function V:Div(s) self.x, self.y, self.z = self.x / s, self.y / s, self.z / s end

local A = {} A.__index = A
function Angle(p, y, r) return setmetatable({ p = p or 0, y = y or 0, r = r or 0 }, A) end
local function rad(d) return math.rad(d) end
local function AngleRot(a) -- 3x3 rows, columns = forward, left, up
	local sp, cp = math.sin(rad(a.p)), math.cos(rad(a.p))
	local sy, cy = math.sin(rad(a.y)), math.cos(rad(a.y))
	local sr, cr = math.sin(rad(a.r)), math.cos(rad(a.r))
	return {
		{ cp * cy, sr * sp * cy - cr * sy, cr * sp * cy + sr * sy },
		{ cp * sy, sr * sp * sy + cr * cy, cr * sp * sy - sr * cy },
		{ -sp, sr * cp, cr * cp },
	}
end
local function RotAngle(m)
	local fx, fy, fz = m[1][1], m[2][1], m[3][1]
	local lx, ly, lz = m[1][2], m[2][2], m[3][2]
	local uz = m[3][3]
	local xy = math.sqrt(fx * fx + fy * fy)
	if xy > 0.001 then
		return Angle(math.deg(math.atan2(-fz, xy)), math.deg(math.atan2(fy, fx)), math.deg(math.atan2(lz, uz)))
	end
	return Angle(math.deg(math.atan2(-fz, xy)), math.deg(math.atan2(-lx, ly)), 0)
end
-- right-handed rotation about a world axis (as Source's VMatrixBuildRotationAboutAxis)
function A:RotateAroundAxis(axis, deg)
	local m = AngleRot(self)
	local c, s = math.cos(rad(deg)), math.sin(rad(deg))
	local x, y, z = axis.x, axis.y, axis.z
	local R = {
		{ c + x * x * (1 - c), x * y * (1 - c) - z * s, x * z * (1 - c) + y * s },
		{ y * x * (1 - c) + z * s, c + y * y * (1 - c), y * z * (1 - c) - x * s },
		{ z * x * (1 - c) - y * s, z * y * (1 - c) + x * s, c + z * z * (1 - c) },
	}
	local o = {}
	for i = 1, 3 do o[i] = {} for j = 1, 3 do o[i][j] = R[i][1] * m[1][j] + R[i][2] * m[2][j] + R[i][3] * m[3][j] end end
	local a = RotAngle(o)
	self.p, self.y, self.r = a.p, a.y, a.r
end
function A:Forward() local m = AngleRot(self) return Vector(m[1][1], m[2][1], m[3][1]) end

local M = {} M.__index = M
function Matrix(t)
	local m = setmetatable({}, M)
	if getmetatable(t) == M then for i = 1, 4 do m[i] = { t[i][1], t[i][2], t[i][3], t[i][4] } end
	elseif t then for i = 1, 4 do m[i] = { t[i][1], t[i][2], t[i][3], t[i][4] } end
	else for i = 1, 4 do m[i] = { 0, 0, 0, 0 } m[i][i] = 1 end end
	return m
end
M.__mul = function(a, b)
	if getmetatable(b) == V then
		return Vector(a[1][1] * b.x + a[1][2] * b.y + a[1][3] * b.z + a[1][4], a[2][1] * b.x + a[2][2] * b.y + a[2][3] * b.z + a[2][4], a[3][1] * b.x + a[3][2] * b.y + a[3][3] * b.z + a[3][4])
	end
	local o = Matrix()
	for i = 1, 4 do for j = 1, 4 do local s = 0 for k = 1, 4 do s = s + a[i][k] * b[k][j] end o[i][j] = s end end
	return o
end
function M:GetTranslation() return Vector(self[1][4], self[2][4], self[3][4]) end
function M:SetTranslation(v) self[1][4], self[2][4], self[3][4] = v.x, v.y, v.z end
function M:GetAngles() return RotAngle(self) end
function M:SetAngles(a) local r = AngleRot(a) for i = 1, 3 do for j = 1, 3 do self[i][j] = r[i][j] end end end
function M:GetInverseTR()
	local o = Matrix()
	for i = 1, 3 do for j = 1, 3 do o[i][j] = self[j][i] end end
	local t = self:GetTranslation()
	for i = 1, 3 do o[i][4] = -(o[i][1] * t.x + o[i][2] * t.y + o[i][3] * t.z) end
	return o
end

-- stubs for everything else the client file touches at load time
local noop = setmetatable({}, { __index = function() return function() end end, __call = function() end })
hook, concommand, net, render, draw, surface, input, gameevent, chat, file = noop, noop, noop, noop, noop, noop, noop, noop, noop, noop
function CreateClientConVar() return { GetBool = function() return false end, GetFloat = function() return 1 end, GetString = function() return "" end } end
bit = require("bit")
function Color(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end
vector_origin = Vector()
COLLISION_GROUP_DEBRIS, COLLISION_GROUP_DEBRIS_TRIGGER, COLLISION_GROUP_WEAPON = 1, 2, 11
COLLISION_GROUP_IN_VEHICLE, COLLISION_GROUP_PASSABLE_DOOR, COLLISION_GROUP_WORLD = 10, 15, 20
function istable(x) return type(x) == "table" end
-- Vector:AngleEx(up): angle whose forward is self and whose up is closest to `up`
function V:AngleEx(up)
	local f = self:GetNormalized()
	local l = up:Cross(f):GetNormalized()
	local u = f:Cross(l)
	local m = Matrix({ { f.x, l.x, u.x, 0 }, { f.y, l.y, u.y, 0 }, { f.z, l.z, u.z, 0 }, { 0, 0, 0, 1 } })
	return m:GetAngles()
end
A.__add = A.__add or function(a, b) return Angle(a.p + b.p, a.y + b.y, a.r + b.r) end
math.NormalizeAngle = math.NormalizeAngle or function(a) a = a % 360 if a > 180 then a = a - 360 end return a end
function A:Right() local m = Matrix() m:SetAngles(self) return Vector(-m[1][2], -m[2][2], -m[3][2]) end
function A:Up() local m = Matrix() m:SetAngles(self) return Vector(m[1][3], m[2][3], m[3][3]) end
math.Clamp = function(v, a, b) return math.max(a, math.min(b, v)) end
math.Round = function(x) return math.floor(x + 0.5) end
-- VMatrix:Scale(v): scale the basis columns
do
	local mt = getmetatable(Matrix())
	local Mx = mt.__index
	function Mx:Scale(v)
		for r = 1, 3 do self[r][1] = self[r][1] * v.x self[r][2] = self[r][2] * v.y self[r][3] = self[r][3] * v.z end
	end
end
util = util or { PointContents = function() return 0 end, TraceLine = function(t) return { Hit = false } end, Effect = function() end, IsValidModel = function() return false end }
CONTENTS_WATER, MASK_WATER = CONTENTS_WATER or 32, MASK_WATER or 16432
util.AddNetworkString = util.AddNetworkString or function() end
MASK_SOLID, MASK_SOLID_BRUSHONLY = MASK_SOLID or 33570827, MASK_SOLID_BRUSHONLY or 16395
-- Vector:Angle(): pitch/yaw of a direction (Source: pitch positive looking down)
function V:Angle()
	local l = math.sqrt(self.x * self.x + self.y * self.y)
	return Angle(math.deg(math.atan2(-self.z, l)), math.deg(math.atan2(self.y, self.x)), 0)
end
RunConsoleCommand = RunConsoleCommand or function() end

-- server settings (shared ones too), which tests can flip
FCVAR_ARCHIVE = FCVAR_ARCHIVE or 128
FCVAR_NOTIFY = FCVAR_NOTIFY or 256
FCVAR_REPLICATED = FCVAR_REPLICATED or 8192
FCVAR_SERVER_CAN_EXECUTE = FCVAR_SERVER_CAN_EXECUTE or 268435456
MOCK_CVARS = MOCK_CVARS or {}
MOCK_CVAR_CALLBACKS = MOCK_CVAR_CALLBACKS or {}
CreateConVar = CreateConVar or function(name, default)
	if MOCK_CVARS[name] == nil then MOCK_CVARS[name] = tostring(default) end
	return { GetBool = function() return MOCK_CVARS[name] ~= "0" end, GetInt = function() return tonumber(MOCK_CVARS[name]) or 0 end,
		GetFloat = function() return tonumber(MOCK_CVARS[name]) or 0 end, GetString = function() return MOCK_CVARS[name] end }
end
cvars = cvars or { AddChangeCallback = function(name, f) MOCK_CVAR_CALLBACKS[name] = f end }
function MOCK_SET_CVAR(name, value)
	local old = MOCK_CVARS[name]
	MOCK_CVARS[name] = tostring(value)
	if MOCK_CVAR_CALLBACKS[name] then MOCK_CVAR_CALLBACKS[name](name, old, tostring(value)) end
end
include = include or function(path) return dofile("../../addon/skategm/lua/" .. path) end
AddCSLuaFile = AddCSLuaFile or function() end
math.Rand = math.Rand or function(a, b) return a + (b - a) * math.random() end
Lerp = Lerp or function(t, a, b) return a + (b - a) * t end
TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP, TEXT_ALIGN_BOTTOM = TEXT_ALIGN_LEFT or 0, TEXT_ALIGN_CENTER or 1, TEXT_ALIGN_RIGHT or 2, TEXT_ALIGN_TOP or 3, TEXT_ALIGN_BOTTOM or 4
do
	local Mx = getmetatable(Matrix()).__index
	function Mx:SetField(r, c, v) self[r][c] = v end
	function Mx:GetField(r, c) return self[r][c] end
	function Mx:GetForward() return Vector(self[1][1], self[2][1], self[3][1]) end
	function Mx:GetRight() return Vector(-self[1][2], -self[2][2], -self[3][2]) end
	function Mx:GetUp() return Vector(self[1][3], self[2][3], self[3][3]) end
	function Mx:GetInverse()
		local a = self
		local det = a[1][1] * (a[2][2] * a[3][3] - a[2][3] * a[3][2]) - a[1][2] * (a[2][1] * a[3][3] - a[2][3] * a[3][1]) + a[1][3] * (a[2][1] * a[3][2] - a[2][2] * a[3][1])
		if math.abs(det) < 1e-12 then return nil end
		local o = Matrix()
		o[1][1] = (a[2][2] * a[3][3] - a[2][3] * a[3][2]) / det
		o[1][2] = (a[1][3] * a[3][2] - a[1][2] * a[3][3]) / det
		o[1][3] = (a[1][2] * a[2][3] - a[1][3] * a[2][2]) / det
		o[2][1] = (a[2][3] * a[3][1] - a[2][1] * a[3][3]) / det
		o[2][2] = (a[1][1] * a[3][3] - a[1][3] * a[3][1]) / det
		o[2][3] = (a[1][3] * a[2][1] - a[1][1] * a[2][3]) / det
		o[3][1] = (a[2][1] * a[3][2] - a[2][2] * a[3][1]) / det
		o[3][2] = (a[1][2] * a[3][1] - a[1][1] * a[3][2]) / det
		o[3][3] = (a[1][1] * a[2][2] - a[1][2] * a[2][1]) / det
		local t = a:GetTranslation()
		for i = 1, 3 do o[i][4] = -(o[i][1] * t.x + o[i][2] * t.y + o[i][3] * t.z) end
		return o
	end
end
BONE_USED_BY_ANYTHING = BONE_USED_BY_ANYTHING or 0x7FF00
GetConVar = GetConVar or function(name)
	if MOCK_CVARS[name] == nil then return nil end
	return { GetBool = function() return MOCK_CVARS[name] ~= "0" end, GetInt = function() return tonumber(MOCK_CVARS[name]) or 0 end,
		GetFloat = function() return tonumber(MOCK_CVARS[name]) or 0 end, GetString = function() return MOCK_CVARS[name] end }
end
do local frame = 0 FrameNumber = FrameNumber or function() frame = frame + 1 return frame end end
LerpVector = LerpVector or function(t, a, b) return a + (b - a) * t end
LerpAngle = LerpAngle or function(t, a, b) return Angle(a.p + (b.p - a.p) * t, a.y + (b.y - a.y) * t, a.r + (b.r - a.r) * t) end
