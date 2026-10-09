---------------------------------------------------------------------------
-- A soft shadow under each skater (gm_sk8 addition): a dark round blob laid
-- on the surface below, fainter and wider the higher they are. Source's own
-- shadows don't fall on the converted Skate 3 maps (they're models, not
-- brushes), so this is drawn by hand, after each skater (SkateGMDrawSkater).
---------------------------------------------------------------------------
local cvOn = CreateClientConVar("skategm_shadow", "1", true, false, "Soft shadow under skaters", 0, 1)
local cvSize = CreateClientConVar("skategm_shadow_size", "1", true, false, "Size of the skater shadow", 0.2, 3)
local cvDark = CreateClientConVar("skategm_shadow_darkness", "0.6", true, false, "Darkness of the skater shadow", 0, 1)

local MAT = CreateMaterial("skategm_blobshadow", "UnlitGeneric", {
	["$basetexture"] = "particle/particle_glow_04",
	["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$translucent"] = 1,
})
local REACH = 400 -- how far below it still shows (units)
local RADIUS = 22

hook.Add("SkateGMDrawSkater", "skategm_blobshadow", function(e, ply)
	if not cvOn:GetBool() or not IsValid(e) then return end
	local P = e.Sk8P
	if not (P and P.HIPS) then return end
	local centre = P.HIPS
	if P.TRUCK_FRONT and P.TRUCK_BACK then centre = (P.TRUCK_FRONT + P.TRUCK_BACK) * 0.5 end
	local tr = util.TraceLine({
		start = centre + Vector(0, 0, 8), endpos = centre - Vector(0, 0, REACH),
		mask = MASK_SOLID, filter = function(x) return x ~= e and not x:IsPlayer() end,
	})
	if not tr.Hit or tr.StartSolid then return end
	local height = math.max(centre.z - tr.HitPos.z, 0)
	local fade = 1 - math.Clamp(height / REACH, 0, 1)
	if fade <= 0 then return end
	local size = RADIUS * cvSize:GetFloat() * (1 + height / 150)
	-- a little longer along the board
	local along = (P.TRUCK_FRONT and P.TRUCK_BACK) and (P.TRUCK_FRONT - P.TRUCK_BACK) or e:GetForward()
	local rot = math.deg(math.atan2(along.y, along.x))
	render.SetMaterial(MAT)
	render.DrawQuadEasy(tr.HitPos + tr.HitNormal * 0.6, tr.HitNormal, size * 2.2, size * 1.5,
		Color(0, 0, 0, 255 * cvDark:GetFloat() * fade * fade), rot)
end)
