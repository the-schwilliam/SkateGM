-- Skull Runners: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_skullrunners/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_skullrunners/sh_skullrunners.lua")
	AddCSLuaFile("skategm_skullrunners/cl_skullrunners.lua")
	include("skategm_skullrunners/sh_skullrunners.lua")
	include("skategm_skullrunners/sv_skullrunners.lua")
else
	include("skategm_skullrunners/sh_skullrunners.lua")
	include("skategm_skullrunners/cl_skullrunners.lua")
end
