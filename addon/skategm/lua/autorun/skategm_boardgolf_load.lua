-- Board Golf: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_boardgolf/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_boardgolf/sh_boardgolf.lua")
	AddCSLuaFile("skategm_boardgolf/cl_boardgolf.lua")
	include("skategm_boardgolf/sh_boardgolf.lua")
	include("skategm_boardgolf/sv_boardgolf.lua")
else
	include("skategm_boardgolf/sh_boardgolf.lua")
	include("skategm_boardgolf/cl_boardgolf.lua")
end
