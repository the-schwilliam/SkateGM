-- Christ Air and body flips as the module reports them (Poll christAir / bodyFlip).
--   luajit christ.lua [lt | rt | both | none] [lift] [ry: right stick y while in the air]
local btn = tonumber(os.getenv("SK8_BTN") or "0")
local ly = tonumber(os.getenv("SK8_LY") or "0")
local grab, lift, ry, rx, run = arg[1] or "both", tonumber(arg[2]) or 1600, tonumber(arg[3]) or 0, tonumber(arg[4]) or 0, tonumber(arg[5]) or 400
local DLL, DATA, MAP = os.getenv("SK8_DLL"), os.getenv("SK8_DATA"), os.getenv("SK8_MAP")
local function wait(sec) local t = os.clock() + sec while os.clock() < t do end end
local open = assert(package.loadlib(DLL, "gmod13_open")) open()
local f = assert(io.open(MAP, "rb")) local bytes = f:read("*a") f:close()
skategm.Load(DATA, 0, 0, 8, 0, bytes, 1, 1, 1, 8)
bytes = nil collectgarbage()
local t0 = os.time()
repeat wait(0.5) until skategm.Poll().status ~= "loading" or os.time() - t0 > 400
skategm.Activate(0, 0, 8, 0)
local function step(lt, rt, sy, sx)
	local before = skategm.Poll().tick or 0
	skategm.Step(1 / 60, false, (lt > 0 or rt > 0) and btn or 0, lt, rt, 0, (sx ~= nil and sx ~= 0 or sy ~= nil) and ly or 0, sx or 0, sy or 0)
	local w = os.clock() + 0.5
	local q
	repeat q = skategm.Poll() until (q.tick or 0) > before or os.clock() > w
	return q
end
for _ = 1, 120 do step(0, 0) end
skategm.Push(run, 0, 0)
for _ = 1, 20 do step(0, 0) end
skategm.Push(0, 0, lift)
local christ, flip, air, states = 0, 0, 0, {}
local tricks, seen, named, lastNamed = {}, {}, {}, nil
for i = 1, 240 do
	local q = skategm.Poll()
	local inAir = (q.state or ""):find("Air") ~= nil
	local lt = (grab == "lt" or grab == "both") and inAir and 255 or 0
	local rt = (grab == "rt" or grab == "both") and inAir and 255 or 0
	q = inAir and step(lt, rt, ry, rx) or step(lt, rt, nil, nil)
	if inAir then air = air + 1 end
	if q.christAir then christ = christ + 1 end
	local tn = q.score and q.score.trick or ""
	if q.score and q.score.tricksNamed ~= lastNamed then lastNamed = q.score.tricksNamed named[#named + 1] = tn .. "@" .. i end
	if tn ~= "" then tricks[tn] = (tricks[tn] or 0) + (q.christAir and 1 or 0) seen[tn] = true end
	if q.bodyFlip then flip = flip + 1 end
	if q.state ~= states[#states] then states[#states + 1] = q.state end
	if not inAir and air > 10 then break end
end
print(string.format("GRAB %s ry %s rx %s: air %d ticks, christAir %d, bodyFlip %d, %s", grab, ry, rx, air, christ, flip, table.concat(states, " > ")))
local tl = {}
for k in pairs(seen) do tl[#tl + 1] = k .. " (christAir " .. tricks[k] .. ")" end
print("  tricks: " .. table.concat(tl, ", ") .. "  named: " .. table.concat(named, ", "))
