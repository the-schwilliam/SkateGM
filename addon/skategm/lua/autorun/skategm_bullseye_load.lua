-- Bullseye: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_bullseye/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_bullseye/sh_bullseye.lua")
	AddCSLuaFile("skategm_bullseye/cl_bullseye.lua")
	include("skategm_bullseye/sh_bullseye.lua")
	include("skategm_bullseye/sv_bullseye.lua")
else
	include("skategm_bullseye/sh_bullseye.lua")
	include("skategm_bullseye/cl_bullseye.lua")
end
