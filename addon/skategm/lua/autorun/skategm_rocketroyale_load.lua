-- Rocket Royale: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_rocketroyale/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_rocketroyale/sh_rocketroyale.lua")
	AddCSLuaFile("skategm_rocketroyale/cl_rocketroyale.lua")
	include("skategm_rocketroyale/sh_rocketroyale.lua")
	include("skategm_rocketroyale/sv_rocketroyale.lua")
else
	include("skategm_rocketroyale/sh_rocketroyale.lua")
	include("skategm_rocketroyale/cl_rocketroyale.lua")
end
