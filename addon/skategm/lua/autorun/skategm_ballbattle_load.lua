-- Ball Battle: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_ballbattle/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_ballbattle/sh_ballbattle.lua")
	AddCSLuaFile("skategm_ballbattle/cl_ballbattle.lua")
	include("skategm_ballbattle/sh_ballbattle.lua")
	include("skategm_ballbattle/sv_ballbattle.lua")
else
	include("skategm_ballbattle/sh_ballbattle.lua")
	include("skategm_ballbattle/cl_ballbattle.lua")
end
