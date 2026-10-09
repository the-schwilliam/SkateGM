-- Does a push in the air (the rocket board) change the flight?
--   luajit airrocket.lua [push per tick, units/s] [lift units/s]
local per, lift = tonumber(arg[1]) or 12, tonumber(arg[2]) or 1400
local axis, run = arg[3] or "y", tonumber(arg[4]) or 200
local DLL = os.getenv("SK8_DLL") or "gmcl_skategm_win64.dll"
local DATA = os.getenv("SK8_DATA")
local MAP = os.getenv("SK8_MAP")
local function wait(sec) local t = os.clock() + sec while os.clock() < t do end end
local open = assert(package.loadlib(DLL, "gmod13_open")) open()
local f = assert(io.open(MAP, "rb")) local bytes = f:read("*a") f:close()
skategm.Load(DATA, 0, 0, 8, 0, bytes, 1, 1, 1, 8)
bytes = nil collectgarbage()
local p, t0 = nil, os.time()
repeat wait(0.5) p = skategm.Poll() until p.status ~= "loading" or os.time() - t0 > 400
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
local limit = tonumber(arg[1])
if limit and skategm.SetAirReset then skategm.SetAirReset(limit) end
local start = skategm.Poll().pos
skategm.Push(0, 0, 200)
local states, jumps, airTicks, last = {}, 0, 0, start
for i = 1, 900 do
	local q = skategm.Poll()
	local air = (q.state or ""):find("Air") ~= nil
	if air then airTicks = airTicks + 1 if i < 600 and (q.vel and q.vel[3] or 0) < 0 then skategm.Push(0, 0, 12) end end
	if q.state ~= states[#states] then states[#states + 1] = q.state end
	q = step()
	local d = math.sqrt((q.pos[1] - last[1]) ^ 2 + (q.pos[2] - last[2]) ^ 2 + (q.pos[3] - last[3]) ^ 2)
	if d > 150 then jumps = jumps + 1 print(string.format("JUMP at tick %d: %.0f units (state %s)", i, d, tostring(q.state))) end
	last = q.pos
	if not air and airTicks > 60 and not (q.state or ""):find("Air") then break end
end
print(string.format("AIRLONG limit %s: %d ticks in the air (%.1f s), sudden jumps %d, states %s", tostring(limit), airTicks, airTicks / 60, jumps, table.concat(states, " > ")))
