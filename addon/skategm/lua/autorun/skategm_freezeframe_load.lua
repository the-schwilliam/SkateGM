-- Freeze Frame: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_freezeframe/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_freezeframe/sh_freezeframe.lua")
	AddCSLuaFile("skategm_freezeframe/cl_freezeframe.lua")
	include("skategm_freezeframe/sh_freezeframe.lua")
	include("skategm_freezeframe/sv_freezeframe.lua")
else
	include("skategm_freezeframe/sh_freezeframe.lua")
	include("skategm_freezeframe/cl_freezeframe.lua")
end
