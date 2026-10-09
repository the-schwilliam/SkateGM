-- Imposter: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_imposter/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_imposter/sh_imposter.lua")
	AddCSLuaFile("skategm_imposter/cl_imposter.lua")
	include("skategm_imposter/sh_imposter.lua")
	include("skategm_imposter/sv_imposter.lua")
else
	include("skategm_imposter/sh_imposter.lua")
	include("skategm_imposter/cl_imposter.lua")
end
