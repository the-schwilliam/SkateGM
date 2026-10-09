-- S.K.A.T.E.: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_skate/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_skate/sh_skate.lua")
	AddCSLuaFile("skategm_skate/cl_skate.lua")
	include("skategm_skate/sh_skate.lua")
	include("skategm_skate/sv_skate.lua")
else
	include("skategm_skate/sh_skate.lua")
	include("skategm_skate/cl_skate.lua")
end
