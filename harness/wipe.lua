-- skategm.Wipeout(): does it knock the skater off, on the ground and in the air?
--   luajit wipe.lua [ground | air]
local where = arg[1] or "ground"
local DLL, DATA, MAP = os.getenv("SK8_DLL"), os.getenv("SK8_DATA"), os.getenv("SK8_MAP")
local function wait(sec) local t = os.clock() + sec while os.clock() < t do end end
local open = assert(package.loadlib(DLL, "gmod13_open")) open()
local f = assert(io.open(MAP, "rb")) local bytes = f:read("*a") f:close()
skategm.Load(DATA, 0, 0, 8, 0, bytes, 1, 1, 1, 8)
bytes = nil collectgarbage()
local t0 = os.time()
repeat wait(0.5) until skategm.Poll().status ~= "loading" or os.time() - t0 > 400
skategm.Activate(0, 0, 8, 0)
local function step()
	local before = skategm.Poll().tick or 0
	skategm.Step(1 / 60, false, 0, 0, 0, 0, 0, 0, 0)
	local w = os.clock() + 0.5
	local q
	repeat q = skategm.Poll() until (q.tick or 0) > before or os.clock() > w
	return q
end
for _ = 1, 120 do step() end
skategm.Push(300, 0, 0)
for _ = 1, 30 do step() end
if where == "air" then
	skategm.Push(0, 0, 700)
	for _ = 1, 12 do step() end
end
local before = skategm.Poll().state
local kx, ky, kz = tonumber(arg[2] or ""), tonumber(arg[3] or ""), tonumber(arg[4] or "")
if kz then skategm.Push(kx, ky, kz) else skategm.Wipeout() end
local states = { before }
for _ = 1, 300 do
	local q = step()
	if q.state ~= states[#states] then states[#states + 1] = q.state end
end
local q = skategm.Poll()
print(string.format("WIPE %s: %s | recovered %s error %s", where, table.concat(states, " > "), tostring(q.recovered), tostring(q.error)))
