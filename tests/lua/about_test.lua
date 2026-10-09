local root = "../../addon/skategm/lua/"
local function check(name, ok) print(name .. " " .. (ok and "OK" or "<-- WRONG")) end

local dirs = {}
local p = io.popen('ls -d ' .. root .. 'skategm_*/ 2>/dev/null || dir /b /ad "' .. root:gsub("/", "\\") .. 'skategm_*"')
for line in p:lines() do dirs[#dirs + 1] = line:match("(skategm_[%w_]+)") end
p:close()

local found = 0
for _, d in ipairs(dirs) do
	local id = d:match("^skategm_(.+)$")
	local f = io.open(root .. d .. "/cl_" .. id .. ".lua")
	if f then
		local s = f:read("*a")
		f:close()
		if s:find(":Host%(%{") or s:find("SpotClient%(") then
			found = found + 1
			local tag = s:match('\n\t+description = "([^"]*)",')
			local about = s:match('\n\t+about = "([^"]*)",')
			check(id .. " has a tagline", tag ~= nil and #tag > 0 and #tag <= 40 and not tag:find("%.$"))
			check(id .. " has a paragraph", about ~= nil and #about > 40 and about:find("%.$") ~= nil)
		end
	end
end
check("every minigame was found", found >= 22)
