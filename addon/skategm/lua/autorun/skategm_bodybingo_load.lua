-- Body Bingo: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_bodybingo/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
-- (the injuries are Hall of Meat's: its shared part first, whatever the load order)
if not (HOM and HOM.PARTS) then
	if SERVER then AddCSLuaFile("skategm_hom/sh_hom.lua") end
	include("skategm_hom/sh_hom.lua")
end
if SERVER then
	AddCSLuaFile("skategm_bodybingo/sh_bodybingo.lua")
	AddCSLuaFile("skategm_bodybingo/cl_bodybingo.lua")
	include("skategm_bodybingo/sh_bodybingo.lua")
	include("skategm_bodybingo/sv_bodybingo.lua")
else
	include("skategm_bodybingo/sh_bodybingo.lua")
	include("skategm_bodybingo/cl_bodybingo.lua")
end
