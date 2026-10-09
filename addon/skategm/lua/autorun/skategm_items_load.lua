-- Items for minigames: the shared base (lua/skategm_items/) and every item
-- in lua/skategm_itemdefs/ (an add-on adds one by dropping a file there).
local function Defs()
	local list = file.Find("skategm_itemdefs/*.lua", "LUA") or {}
	table.sort(list)
	for i, f in ipairs(list) do list[i] = "skategm_itemdefs/" .. f end
	return list
end
if SERVER then
	AddCSLuaFile("skategm_items/sh_items.lua")
	AddCSLuaFile("skategm_items/cl_items.lua")
	include("skategm_items/sh_items.lua")
	include("skategm_items/sv_items.lua")
	for _, f in ipairs(Defs()) do AddCSLuaFile(f) include(f) end
else
	include("skategm_items/sh_items.lua")
	include("skategm_items/cl_items.lua")
	for _, f in ipairs(Defs()) do include(f) end
end
