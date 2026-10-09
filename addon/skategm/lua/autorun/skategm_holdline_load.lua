-- Hold the Line: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_holdline/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_holdline/sh_holdline.lua")
	AddCSLuaFile("skategm_holdline/cl_holdline.lua")
	include("skategm_holdline/sh_holdline.lua")
	include("skategm_holdline/sv_holdline.lua")
else
	include("skategm_holdline/sh_holdline.lua")
	include("skategm_holdline/cl_holdline.lua")
end
