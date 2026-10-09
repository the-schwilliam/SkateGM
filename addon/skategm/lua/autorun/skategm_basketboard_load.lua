-- Basketboard: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_basketboard/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_basketboard/sh_basketboard.lua")
	AddCSLuaFile("skategm_basketboard/cl_basketboard.lua")
	include("skategm_basketboard/sh_basketboard.lua")
	include("skategm_basketboard/sv_basketboard.lua")
else
	include("skategm_basketboard/sh_basketboard.lua")
	include("skategm_basketboard/cl_basketboard.lua")
end
