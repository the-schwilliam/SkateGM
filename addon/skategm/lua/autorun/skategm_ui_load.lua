-- controller screens: the map (LB + Y) and settings (LB + A)
local FILES = { "skategm_ui/cl_pad.lua", "skategm_ui/cl_map.lua", "skategm_ui/cl_settings.lua", "skategm_ui/cl_style.lua" }
for _, f in ipairs(FILES) do
	if file.Exists(f, "LUA") then
		if SERVER then AddCSLuaFile(f) else include(f) end
	end
end
