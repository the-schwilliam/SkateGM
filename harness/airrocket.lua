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
skategm.Push(run, 0, 0)
for _ = 1, 20 do step() end
local start = skategm.Poll().pos
skategm.Push(0, 0, lift)
local airTicks, accepted, states, top = 0, 0, {}, nil
for i = 1, 240 do
	local q = skategm.Poll()
	local air = (q.state or ""):find("Air") ~= nil
	if air then
		airTicks = airTicks + 1
		local px, py, pz = axis == "x" and per or 0, axis == "y" and per or 0, axis == "z" and per or 0
		if axis == "xz" then px, pz = per * 0.7, per * 0.7 end
		if per ~= 0 and skategm.Push(px, py, pz) then accepted = accepted + 1 end
		top = math.max(top or -1e9, q.pos[3])
	end
	if q.state ~= states[#states] then states[#states + 1] = q.state end
	q = step()
	if os.getenv("SK8_VERBOSE") and i % 6 == 0 then
		local v = q.vel or { 0, 0, 0 }
		print(string.format("tick %3d %-20s pos %.0f %.0f %.0f vel %.0f %.0f %.0f", i, tostring(q.state), q.pos[1], q.pos[2], q.pos[3], v[1], v[2], v[3]))
	end
	if not air and airTicks > 10 then break end
end
local q = skategm.Poll()
print(string.format("PUSH %s %s per tick: air %d ticks, pushes accepted %d, sideways %.0f forward %.0f units, top %.0f above the start, recoveries %s, states %s", per, axis, airTicks, accepted, q.pos[2] - start[2], q.pos[1] - start[1], (top or start[3]) - start[3], tostring(q.recoveries), table.concat(states, " > ")))
