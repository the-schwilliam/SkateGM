-- Steezus Stint: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_steezus/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_steezus/sh_steezus.lua")
	AddCSLuaFile("skategm_steezus/cl_steezus.lua")
	include("skategm_steezus/sh_steezus.lua")
	include("skategm_steezus/sv_steezus.lua")
else
	include("skategm_steezus/sh_steezus.lua")
	include("skategm_steezus/cl_steezus.lua")
end
