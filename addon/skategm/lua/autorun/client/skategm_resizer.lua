---------------------------------------------------------------------------
-- Advanced Resizer (workshop 217376234) support (gm_sk8 addition).
-- The resizer gives a prop scaled physics (PhysicsInitMultiConvex) and a
-- "sizehandler" child that networks the scale; SkateGM sends props to the
-- engine by model name, one shape per model, so a resized prop stayed its
-- old size to the skater. Here such a prop goes to the engine as
-- "<model>#scale<x>,<y>,<z>", whose shape is the model's own, scaled.
---------------------------------------------------------------------------
local SUFFIX = "#scale"
local RESET = Vector(1, 1, 1)

-- the prop's physical scale, as the resizer's sizehandler networks it
-- (nil: not resized, or its client physics disabled - then it reports 1 1 1)
local handlers = {}
local function Scale(e)
	local h = handlers[e]
	if not (IsValid(h) and h:GetParent() == e) then
		handlers[e] = nil
		return nil
	end
	if not h.GetActualPhysicsScale then return nil end
	local s = Vector(h:GetActualPhysicsScale() or "")
	if s == RESET or s.x <= 0 or s.y <= 0 or s.z <= 0 then return nil end
	return s
end

local function NameFor(mdl, s)
	return string.format("%s%s%.3f,%.3f,%.3f", mdl, SUFFIX, s.x, s.y, s.z)
end

local function Install()
	local S = SkateGM
	if not (S and S.Hulls and S.HullProviders) then return false end
	if S.ResizerInstalled then return true end
	S.ResizerInstalled = true

	-- a resized model's shape: the model's own, scaled about its origin
	-- (the resizer scales the physics mesh the same way)
	table.insert(S.HullProviders, function(name)
		local at = string.find(name, SUFFIX, 1, true)
		if not at then return nil end
		local base = string.sub(name, 1, at - 1)
		local x, y, z = string.match(string.sub(name, at + #SUFFIX), "^([%d%.]+),([%d%.]+),([%d%.]+)$")
		x, y, z = tonumber(x), tonumber(y), tonumber(z)
		if not (x and y and z) then return nil end
		local hulls, isMesh = S.Hulls(base)
		if not istable(hulls) then return nil end
		local out = {}
		for i, flat in ipairs(hulls) do
			local scaled = {}
			for k = 1, #flat - 2, 3 do
				scaled[k], scaled[k + 1], scaled[k + 2] = flat[k] * x, flat[k + 1] * y, flat[k + 2] * z
			end
			out[i] = scaled
		end
		return out, isMesh, string.format("%s, resized %.2f x %.2f x %.2f (Advanced Resizer)", base, x, y, z)
	end)

	-- the resized ones are left out of SkateGM's own list...
	S.EntitySkippers = S.EntitySkippers or {}
	table.insert(S.EntitySkippers, function(e)
		return handlers[e] ~= nil and Scale(e) ~= nil
	end)

	-- ...and fed here under their scaled name
	S.ExtraFeeds = S.ExtraFeeds or {}
	table.insert(S.ExtraFeeds, function(centre, list, sig)
		for e in pairs(handlers) do
			local s = IsValid(e) and Scale(e)
			if s and e:GetSolid() == SOLID_VPHYSICS and e:GetPos():DistToSqr(centre) < 2500 * 2500 then
				local mdl = e:GetModel()
				if mdl and string.EndsWith(string.lower(mdl), ".mdl") then
					local name = NameFor(mdl, s)
					local p, a = e:GetPos(), e:GetAngles()
					list[#list + 1] = { name, p.x, p.y, p.z, a.p, a.y, a.r }
					sig[#sig + 1] = string.format("%s%d,%d,%d,%d,%d,%d", name, p.x / 2, p.y / 2, p.z / 2, a.p / 2, a.y / 2, a.r / 2)
				end
			end
		end
	end)
	return true
end

-- the sizehandlers, by the prop each belongs to
local function Track()
	for k in pairs(handlers) do if not IsValid(k) then handlers[k] = nil end end
	for _, h in ipairs(ents.FindByClass("sizehandler")) do
		local p = h:GetParent()
		if IsValid(p) then handlers[p] = h end
	end
end

timer.Create("skategm_resizer", 1, 0, function()
	if not Install() then return end
	Track()
end)
hook.Add("NetworkEntityCreated", "skategm_resizer", function(e)
	if IsValid(e) and e:GetClass() == "sizehandler" then timer.Simple(0, Track) end
end)
