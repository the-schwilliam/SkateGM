-- Copycat: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_copycat/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_copycat/sh_copycat.lua")
	AddCSLuaFile("skategm_copycat/cl_copycat.lua")
	include("skategm_copycat/sh_copycat.lua")
	include("skategm_copycat/sv_copycat.lua")
else
	include("skategm_copycat/sh_copycat.lua")
	include("skategm_copycat/cl_copycat.lua")
end
