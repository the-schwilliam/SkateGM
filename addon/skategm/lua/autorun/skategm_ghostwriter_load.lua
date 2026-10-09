-- Ghost Writer: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_ghostwriter/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_ghostwriter/sh_ghostwriter.lua")
	AddCSLuaFile("skategm_ghostwriter/cl_ghostwriter.lua")
	include("skategm_ghostwriter/sh_ghostwriter.lua")
	include("skategm_ghostwriter/sv_ghostwriter.lua")
else
	include("skategm_ghostwriter/sh_ghostwriter.lua")
	include("skategm_ghostwriter/cl_ghostwriter.lua")
end
