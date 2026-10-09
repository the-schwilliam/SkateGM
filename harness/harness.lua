-- The automatic skater: the real engine (the module DLL) on a real map, riding
-- test runs and recording every bail and runout.
--   luajit harness.lua <style> <runs> <seed> <cx> <cy> <cz> <out>
-- Settings (environment variables):
--   SK8_DLL   the module to test (default gmcl_skategm_win64.dll, next to this)
--   SK8_DATA  the converted Skate 3 data folder (the one holding private/)
--   SK8_MAP   the map .bsp
--   SK8_PAK   a folder holding the map's packed models/*.phy (extract_pak.py)
--   SK8_ONLY  "4,8,24": replay just these rides, with a tick-by-tick log
--   SK8_FORCE_SWAP=1: a collision swap mid-ride (an experiment)
-- Results are appended and resumed: rides already in <out> are skipped.
local style, runs, seed = arg[1] or "classic", tonumber(arg[2] or 20), tonumber(arg[3] or 1)
local cx, cy, cz = tonumber(arg[4] or -2600), tonumber(arg[5] or -700), tonumber(arg[6] or 420)
local outname = arg[7] or "harness_out.txt"
local DLL = os.getenv("SK8_DLL") or "gmcl_skategm_win64.dll"
local DATA = os.getenv("SK8_DATA") or (os.getenv("LOCALAPPDATA") or ".") .. "/SkateGM/data/assets"
local MAP = os.getenv("SK8_MAP") or "tl_skatepark.bsp"
local PAK = (os.getenv("SK8_PAK") or "pak") .. "/"
-- resumable: rides already in the results file are kept and skipped (the
-- machine running this restarts now and then)
local done = {}
do
	local old = io.open(outname, "r")
	if old then
		for line in old:lines() do
			local n = line:match("^run (%d+): ")
			if n then done[tonumber(n)] = true end
		end
		old:close()
	end
end
local out = assert(io.open(outname, "a"))
local function log(...) local s = string.format(...) out:write(s, "\n") out:flush() end
local open = assert(package.loadlib(DLL, "gmod13_open")) open()
local function wait(sec) local t = os.clock() + sec while os.clock() < t do end end

local TUNING = {
	classic = { SK8_CURVE_CAP = "16", SK8_TAPER = "linear", SK8_OFF = "crossings,bigterrain,shortsteps" },
	experimental = {},
	raw = { SK8_OFF = "weld,hidden,ledges,curves,cracks,crossings,wings" },
	classicold = { SK8_CURVE_CAP = "16", SK8_TAPER = "linear", SK8_OFF = "crossings,bigterrain,shortsteps,slopededges" },
	noledges = { SK8_CURVE_CAP = "16", SK8_TAPER = "linear", SK8_OFF = "crossings,bigterrain,shortsteps,ledges,cracks,wings" },
}
for _, n in ipairs({ "SK8_CURVE_CAP", "SK8_TAPER", "SK8_OFF" }) do skategm.SetTuning(n, (TUNING[style] or {})[n]) end
-- (SK8_OFF_ADD: more switches off on top of the style's, e.g. "entclean")
if os.getenv("SK8_OFF_ADD") then
	local base = (TUNING[style] or {}).SK8_OFF
	skategm.SetTuning("SK8_OFF", (base and base ~= "" and (base .. ",") or "") .. os.getenv("SK8_OFF_ADD"))
end
-- SK8_SPEED_LIMIT: the add-on's top speed setting (m/s, 0 = none)
if os.getenv("SK8_SPEED_LIMIT") and skategm.SetSpeedLimit then skategm.SetSpeedLimit(tonumber(os.getenv("SK8_SPEED_LIMIT")) or 0) end
-- SK8_OFF_EXTRA: more steps off on top of the style's (for finding which change does what)
if os.getenv("SK8_OFF_EXTRA") then
	local base = (TUNING[style] or {}).SK8_OFF
	skategm.SetTuning("SK8_OFF", (base and base ~= "" and (base .. ",") or "") .. os.getenv("SK8_OFF_EXTRA"))
end
-- (a fixed region covering every test spot: the collision is never rebuilt
-- mid-ride, which made identical setups come out differently)
skategm.SetTuning("SK8_REGION_HALF", os.getenv("SK8_HARNESS_MOVING") and nil or "4800")
local smooth, creases, steps = 1, 1, 8
if style == "raw" then smooth, creases, steps = 0, 0, 0 end

local f = assert(io.open(MAP, "rb")) local bytes = f:read("*a") f:close()
local t0 = os.time()
skategm.Load(DATA, cx, cy, cz, 0, bytes, 1, smooth, creases, steps)
bytes = nil collectgarbage()
local p
repeat wait(0.5) p = skategm.Poll() until p.status ~= "loading" or os.time() - t0 > 400
log("loaded: %s in %d s (%s)", tostring(p.status), os.time() - t0, tostring(p.error or p.world))
if p.status ~= "ready" and p.status ~= "active" then out:close() return end
skategm.Activate(cx, cy, cz, 0)
-- props: their physics shapes from the map's packed .phy files, as the add-on does in the game,
-- then from stock GMod / HL2 content (pak_gmod, filled by extract_props.py from the game's
-- VPKs: most workshop maps use stock models, which had no collision here before;
-- SK8_PROPS_GMOD=0 leaves it out, as older results were measured)
local PROP_DIRS = { PAK }
if os.getenv("SK8_PROPS_GMOD") ~= "0" then PROP_DIRS[#PROP_DIRS + 1] = (os.getenv("SK8_PAK_GMOD") or "pak_gmod") .. "/" end
local function open_phy(mdl)
	for _, dir in ipairs(PROP_DIRS) do
		local f = io.open(dir .. mdl:gsub("%.mdl$", ".phy"), "rb")
		if f then return f end
	end
end
local defined = {}
local function feed()
	local q = skategm.Poll()
	local n = 0
	for _, name in ipairs(q.needModels or {}) do
		if not defined[name] then
			defined[name] = true
			local mdl = string.lower((name:gsub("#bbox$", "")))
			local ph = open_phy(mdl)
			local hulls = {}
			if ph and not name:find("#bbox$") then
				local ok, h = pcall(skategm.PhyHulls, ph:read("*a"))
				if ok and h then hulls = h end
			end
			if ph then ph:close() end
			skategm.DefineModel(name, hulls)
			n = n + 1
		end
	end
	return n
end
local fed = 0
for i = 1, 60 do
	skategm.Step(1 / 60, false, 0, 0, 0, 0, 0, 0, 0)
	fed = fed + feed()
	wait(0.2)
end
-- give the props' pass time to finish (it runs in the background)
local t1 = os.time()
-- (until the props are in the collision and nothing is pending: under load the
-- props' pass can take minutes, and a fixed 45 s wait rode some runs without
-- any props at all; up to 10 minutes, then as it is)
local function ready(c)
	local props = tonumber(c:match("(%d+) static props") or "0")
	local pending = tonumber(c:match("(%d+) shapes pending") or "1")
	return pending == 0 and (fed == 0 or props > 0)
end
repeat skategm.Step(1 / 60, false, 0, 0, 0, 0, 0, 0, 0) wait(1) p = skategm.Poll() until ready(p.collision or "") or os.time() - t1 > (fed > 0 and 600 or 90)
log("props defined: %d; collision: %s", fed, tostring(p.collision))

-- spots: flat, rideable ground near the centre
local tris = skategm.CollisionNear(cx, cy, cz, 1100, 60000)
local flats = {}
for i = 1, #tris - 8, 9 do
	local ax, ay, az, bx, by, bz, qx, qy, qz = tris[i], tris[i+1], tris[i+2], tris[i+3], tris[i+4], tris[i+5], tris[i+6], tris[i+7], tris[i+8]
	local ux, uy, uz, vx, vy, vz = bx-ax, by-ay, bz-az, qx-ax, qy-ay, qz-az
	local nx, ny, nz = uy*vz-uz*vy, uz*vx-ux*vz, ux*vy-uy*vx
	local l = math.sqrt(nx*nx+ny*ny+nz*nz)
	if l > 800 and nz / l > 0.97 then flats[#flats + 1] = { ax, ay, az, bx, by, bz, qx, qy, qz } end
end
log("flat spots to start from: %d", #flats)
math.randomseed(seed)
local function seg_hits(t, i, px, py, pz, qx, qy, qz)
	local ax, ay, az = t[i], t[i+1], t[i+2]
	local e1x, e1y, e1z = t[i+3]-ax, t[i+4]-ay, t[i+5]-az
	local e2x, e2y, e2z = t[i+6]-ax, t[i+7]-ay, t[i+8]-az
	local dx, dy, dz = qx-px, qy-py, qz-pz
	local hx, hy, hz = dy*e2z-dz*e2y, dz*e2x-dx*e2z, dx*e2y-dy*e2x
	local a = e1x*hx + e1y*hy + e1z*hz
	if math.abs(a) < 1e-9 then return false end
	local sx, sy, sz = px-ax, py-ay, pz-az
	local u = (sx*hx + sy*hy + sz*hz) / a
	if u < 0 or u > 1 then return false end
	local qx2, qy2, qz2 = sy*e1z-sz*e1y, sz*e1x-sx*e1z, sx*e1y-sy*e1x
	local v = (dx*qx2 + dy*qy2 + dz*qz2) / a
	if v < 0 or u + v > 1 then return false end
	local k = (e2x*qx2 + e2y*qy2 + e2z*qz2) / a
	return k >= 0 and k <= 1
end
-- SK8_FEATURES=1: rides aimed straight at the transitions the pipeline built
-- (ledge ramps and curves), from 48 units back on the ground in front of them
local features = os.getenv("SK8_FEATURES")
local function feature_spots(n)
	local t, tags = skategm.CollisionNear(cx, cy, cz, 1100, 400000)
	local ground, steep = {}, {}
	for i = 1, #t - 8, 9 do
		local ux, uy, uz, vx, vy, vz = t[i+3]-t[i], t[i+4]-t[i+1], t[i+5]-t[i+2], t[i+6]-t[i], t[i+7]-t[i+1], t[i+8]-t[i+2]
		local nz = ux*vy-uy*vx
		local l = math.sqrt((uy*vz-uz*vy)^2 + (uz*vx-ux*vz)^2 + nz^2)
		if l > 1e-6 and math.abs(nz / l) < 0.5 then
			for gx = math.floor(math.min(t[i], t[i+3], t[i+6]) / 64), math.floor(math.max(t[i], t[i+3], t[i+6]) / 64) do
				for gy = math.floor(math.min(t[i+1], t[i+4], t[i+7]) / 64), math.floor(math.max(t[i+1], t[i+4], t[i+7]) / 64) do
					local k = gx * 100000 + gy
					steep[k] = steep[k] or {}
					table.insert(steep[k], i)
				end
			end
		end
		if l > 1e-6 and nz / l > 0.97 then
			for gx = math.floor(math.min(t[i], t[i+3], t[i+6]) / 64), math.floor(math.max(t[i], t[i+3], t[i+6]) / 64) do
				for gy = math.floor(math.min(t[i+1], t[i+4], t[i+7]) / 64), math.floor(math.max(t[i+1], t[i+4], t[i+7]) / 64) do
					local k = gx * 100000 + gy
					ground[k] = ground[k] or {}
					table.insert(ground[k], i)
				end
			end
		end
	end
	local function ground_at(x, y, below)
		local best
		for _, i in ipairs(ground[math.floor(x / 64) * 100000 + math.floor(y / 64)] or {}) do
			local ax, ay, bx, by, qx, qy = t[i], t[i+1], t[i+3], t[i+4], t[i+6], t[i+7]
			if x >= math.min(ax, bx, qx) and x <= math.max(ax, bx, qx) and y >= math.min(ay, by, qy) and y <= math.max(ay, by, qy) then
				local d = (bx-ax)*(qy-ay) - (qx-ax)*(by-ay)
				local u = ((x-ax)*(qy-ay) - (qx-ax)*(y-ay)) / d
				local v = ((bx-ax)*(y-ay) - (x-ax)*(by-ay)) / d
				if u >= 0 and v >= 0 and u + v <= 1 then
					local z = t[i+2] + u * (t[i+5]-t[i+2]) + v * (t[i+8]-t[i+2])
					if z <= below and z > below - 40 and (not best or z > best) then best = z end
				end
			end
		end
		return best
	end
	local cands = {}
	for i = 1, #t - 8, 9 do
		local g = tags[(i - 1) / 9 + 1]
		-- (SK8_FEATURES=ledges / ledgesdown: the gentle ledge ramps instead,
		-- 2 to 18 degrees, ridden up / down them)
		local ledges = features == "ledges" or features == "ledgesdown"
		if (ledges and g == 5) or (not ledges and (g == 5 or g == 6)) then
			local ux, uy, uz, vx, vy, vz = t[i+3]-t[i], t[i+4]-t[i+1], t[i+5]-t[i+2], t[i+6]-t[i], t[i+7]-t[i+1], t[i+8]-t[i+2]
			local nx, ny, nz = uy*vz-uz*vy, uz*vx-ux*vz, ux*vy-uy*vx
			local l = math.sqrt(nx*nx+ny*ny+nz*nz)
			local lo, hi = 0.5, 0.985
			if ledges then lo, hi = 0.95, 0.9995 end
			if l > 1e-6 and nz / l > lo and nz / l < hi then cands[#cands + 1] = { i, nx, ny } end
		end
	end
	local out, tries = {}, 0
	while #out < n and tries < n * 400 and #cands > 0 do
		tries = tries + 1
		local c = cands[math.random(#cands)]
		local i, nx, ny = c[1], c[2], c[3]
		local h = math.sqrt(nx*nx + ny*ny)
		nx, ny = nx / h, ny / h
		local mx, my = (t[i] + t[i+3] + t[i+6]) / 3, (t[i+1] + t[i+4] + t[i+7]) / 3
		local mz = math.min(t[i+2], t[i+5], t[i+8])
		local down = features == "ledgesdown"
		if down then
			-- start on the upper side, heading down the ramp
			nx, ny = -nx, -ny
			mz = math.max(t[i+2], t[i+5], t[i+8])
		end
		local sx, sy = mx + nx * 48, my + ny * 48
		local z = ground_at(sx, sy, mz + 1)
		local clear = true
		for _, lift in ipairs({ 1.5, 4, 8 }) do
			local seen = {}
			for f = 0, 48, 16 do
				for _, j in ipairs(steep[math.floor((mx + nx * f) / 64) * 100000 + math.floor((my + ny * f) / 64)] or {}) do
					if not seen[j] then
						seen[j] = true
						if z and seg_hits(t, j, sx, sy, z + lift, mx + nx * 4, my + ny * 4, z + lift) then clear = false end
					end
				end
			end
		end
		-- (one ride per feature: a curve is many small triangles, and without
		-- this a few big ones would take most of the rides)
		local distinct = true
		for _, o in ipairs(out) do
			if (o[1] - sx) ^ 2 + (o[2] - sy) ^ 2 < 96 * 96 then distinct = false end
		end
		if z and clear and distinct and ground_at(mx + nx * 24, my + ny * 24, mz + 1) then
			out[#out + 1] = { sx, sy, z, math.deg(math.atan2(-ny, -nx)) % 360 }
		end
	end
	return out
end
-- (SK8_SPOTS_SCREEN) whether a spot suits a test ride: ground within 1.5 of
-- the spot's height under the board's ends and sides, and no steep face in
-- the 48 units ahead between 4 and 30 above the ground
function Screener()
	local t = skategm.CollisionNear(cx, cy, cz, 1300, 400000)
	local grid = {}
	for i = 1, #t - 8, 9 do
		for gx = math.floor(math.min(t[i], t[i+3], t[i+6]) / 64), math.floor(math.max(t[i], t[i+3], t[i+6]) / 64) do
			for gy = math.floor(math.min(t[i+1], t[i+4], t[i+7]) / 64), math.floor(math.max(t[i+1], t[i+4], t[i+7]) / 64) do
				local k = gx * 100000 + gy
				grid[k] = grid[k] or {}
				table.insert(grid[k], i)
			end
		end
	end
	local function near(x, y) return grid[math.floor(x / 64) * 100000 + math.floor(y / 64)] or {} end
	local function ground(x, y, z)
		local best
		for _, i in ipairs(near(x, y)) do
			local ax, ay, bx, by, qx, qy = t[i], t[i+1], t[i+3], t[i+4], t[i+6], t[i+7]
			local d = (by - qy) * (ax - qx) + (qx - bx) * (ay - qy)
			if math.abs(d) > 1e-6 then
				local l1 = ((by - qy) * (x - qx) + (qx - bx) * (y - qy)) / d
				local l2 = ((qy - ay) * (x - qx) + (ax - qx) * (y - qy)) / d
				local l3 = 1 - l1 - l2
				if l1 >= 0 and l2 >= 0 and l3 >= 0 then
					local zz = l1 * t[i+2] + l2 * t[i+5] + l3 * t[i+8]
					if zz <= z + 8 and (not best or zz > best) then best = zz end
				end
			end
		end
		return best
	end
	return function(s)
		local x, y, z, yaw = s[1], s[2], s[3], s[4]
		local dx, dy = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
		for _, o in ipairs({ { 0, 0 }, { 24, 0 }, { -24, 0 }, { 0, 10 }, { 0, -10 } }) do
			local g = ground(x + dx * o[1] - dy * o[2], y + dy * o[1] + dx * o[2], z)
			if not g or math.abs(g - z) > 1.5 then return false end
		end
		for k = 1, 3 do
			local h = ({ 4, 12, 30 })[k]
			local px, py, pz = x, y, z + h
			local qx, qy = x + dx * 48, y + dy * 48
			for _, i in ipairs(near(x, y)) do if seg_hits(t, i, px, py, pz, qx, qy, pz) then return false end end
			for _, i in ipairs(near(qx, qy)) do if seg_hits(t, i, px, py, pz, qx, qy, pz) then return false end end
		end
		return true
	end
end

-- the same spots for every version (written by the first run, read by the rest)
-- (SK8_SPOTS_SCREEN=1: random spots only where the board can stand - level
-- ground under all of it - with room to roll - no wall within 48 ahead -
-- kept in their own file, so the old pairings stay as they are)
local screen = os.getenv("SK8_SPOTS_SCREEN") == "1" and not features
local spotfile = (os.getenv("SK8_SPOTS_DIR") or ".") .. "/spots_" .. (features == "ledges" and "ledge_" or features == "ledgesdown" and "ledgedown_" or features and "feat2_" or screen and "screened_" or "") .. seed .. ".txt"
local spots = {}
local sf = io.open(spotfile, "r")
if sf then
	for line in sf:lines() do
		local x, y, z, yaw = line:match("([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+)")
		if x then spots[#spots + 1] = { tonumber(x), tonumber(y), tonumber(z), tonumber(yaw) } end
	end
	sf:close()
end
if #spots == 0 and features then
	spots = feature_spots(runs)
	sf = io.open(spotfile, "w")
	for _, s in ipairs(spots) do sf:write(string.format("%.2f %.2f %.2f %.1f\n", s[1], s[2], s[3], s[4])) end
	sf:close()
elseif #spots < runs and not features then
	spots = {}
	local fits = screen and Screener() or function() return true end
	local tries = 0
	while #spots < runs and tries < runs * 200 do
		tries = tries + 1
		local t = flats[math.random(#flats)]
		local u, v = math.random(), math.random()
		if u + v > 1 then u, v = 1 - u, 1 - v end
		local s = { t[1] + (t[4] - t[1]) * u + (t[7] - t[1]) * v, t[2] + (t[5] - t[2]) * u + (t[8] - t[2]) * v, t[3] + (t[6] - t[3]) * u + (t[9] - t[3]) * v, math.random() * 360 }
		if fits(s) then spots[#spots + 1] = s end
	end
	if screen then log("screened spots: %d kept of %d tried", #spots, tries) end
	sf = io.open(spotfile, "w")
	for _, s in ipairs(spots) do sf:write(string.format("%.2f %.2f %.2f %.1f\n", s[1], s[2], s[3], s[4])) end
	sf:close()
end
local counts = { clean = 0, bail = 0, runout = 0, drop = 0, badspot = 0, fellthrough = 0, real = 0, lip = 0, unexplained = 0, landing = 0 }
-- what the board ran into: the steep faces its path (from 8 behind the event
-- to 36 ahead, along the direction it was moving) crosses at wheel, deck and
-- body height. "real": one the path still crosses 8 units above the ground
-- (taller than any curb, up to the skater's head: pf spot 17's guard rail
-- has bars 20 and 40 up, spots 43/97 a beam 52 up, 119 a 1.5-thick edge 13 up); "lip": only lower - the kind of edge the pipeline
-- is meant to smooth
-- an edge the board rolls off: within 48 ahead, the ground under the line
-- falls away steeper than ~56 degrees and by 32+ (gms spots 1 and 91 roll off
-- a deck into a bowl 140 below and bail; a 25 degree slope, tl feature 17,
-- is not one)
local function drop_off_ahead(px, py, pz, dx, dy)
	local t = skategm.CollisionNear(px + dx * 32, py + dy * 32, pz, 64, 8000)
	local ground = pz - 3.42
	for d = 8, 48, 8 do
		local qx, qy = px + dx * d, py + dy * d
		local top, above
		for i = 1, #t - 8, 9 do
			local ax, ay, bx, by, cx, cy = t[i], t[i+1], t[i+3], t[i+4], t[i+6], t[i+7]
			local d1 = (bx - ax) * (qy - ay) - (by - ay) * (qx - ax)
			local d2 = (cx - bx) * (qy - by) - (cy - by) * (qx - bx)
			local d3 = (ax - cx) * (qy - cy) - (ay - cy) * (qx - cx)
			local area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
			if area > 1e-6 and d1 >= 0 and d2 >= 0 and d3 >= 0 then
				local w1, w2 = d2 / area, d3 / area
				local z = w1 * t[i+2] + w2 * t[i+5] + (1 - w1 - w2) * t[i+8]
				if z <= ground + 8 and (not top or z > top) then top = z end
				if z > ground + 8 and z <= ground + 40 then above = true end
			end
		end
		if above and not top then return nil end
		if not top or top < ground - math.max(32, d * 1.5) then return "drop-off ahead" end
	end
end
DEBUG_NEAR = os.getenv("SK8_NEAR_COUNT")
LIFTS = { 0.4, 1.5, 4 }
for h = 8, 64 do LIFTS[#LIFTS + 1] = h end
local function obstacle_ahead(px, py, pz, dx, dy)
	local t = skategm.CollisionNear(px, py, pz + 32, 72, 100000)
	if DEBUG_NEAR then log("    obstacle test: %d triangles", #t / 9) end
	local ground = pz - 3.42
	local best
	for i = 1, #t - 8, 9 do
		local ux, uy, uz, vx, vy, vz = t[i+3]-t[i], t[i+4]-t[i+1], t[i+5]-t[i+2], t[i+6]-t[i], t[i+7]-t[i+1], t[i+8]-t[i+2]
		local nx, ny, nz = uy*vz-uz*vy, uz*vx-ux*vz, ux*vy-uy*vx
		local l = math.sqrt(nx*nx+ny*ny+nz*nz)
		if l > 1e-6 and math.abs(nz / l) < 0.5 then
			local top = math.max(t[i+2], t[i+5], t[i+8]) - ground
			for side = -8, 8, 4 do
				local ox, oy = -dy * side, dx * side
				for _, lift in ipairs(LIFTS) do
					local z = ground + lift
					if top > lift and seg_hits(t, i, px - dx * 8 + ox, py - dy * 8 + oy, z, px + dx * 36 + ox, py + dy * 36 + oy, z) then
						if lift >= 8 then return "real obstacle ahead" end
						best = "lip ahead"
					end
				end
			end
		end
	end
	return best or drop_off_ahead(px, py, pz, dx, dy) or "UNEXPLAINED"
end
local geo = io.open((outname:gsub("%.txt$", "_geometry.txt")), "w")
local only = {}
for n in (os.getenv("SK8_ONLY") or ""):gmatch("%d+") do only[tonumber(n)] = true end
local verbose = next(only) ~= nil
-- SK8_NEAR="x y r": only the spots within r of x, y (numbered as in the full
-- run, so the results stay paired with it): a change that touches one corner
-- of a map is measured on the rides that go there
local nx, ny, nr = (os.getenv("SK8_NEAR") or ""):match("([%-%d%.]+)%s+([%-%d%.]+)%s+([%d%.]+)")
nx, ny, nr = tonumber(nx), tonumber(ny), tonumber(nr)
local function wanted(s) return not nr or (s[1] - nx) ^ 2 + (s[2] - ny) ^ 2 <= nr * nr end
local bone = {}
local function board(q)
	if not bone.TRUCK_FRONT then
		for k, nm in ipairs(skategm.Poll(true).names or {}) do bone[nm] = k end
	end
	local b = q.bones or {}
	local f, r = b[bone.TRUCK_FRONT or -1], b[bone.TRUCK_BACK or -1]
	if f and r then return (f[1] + r[1]) / 2, (f[2] + r[2]) / 2, (f[3] + r[3]) / 2 end
	if q.pos then return q.pos[1], q.pos[2], q.pos[3] end
end
local WINDOW = 4
if os.getenv("SK8_SHAKE") and skategm.SetCameraShake then skategm.SetCameraShake(tonumber(os.getenv("SK8_SHAKE"))) end
if os.getenv("SK8_CAMTYPE") and skategm.SetCameraType then skategm.SetCameraType(tonumber(os.getenv("SK8_CAMTYPE"))) end
TIMING = os.getenv("SK8_TIMING") and { n = 0, sum = 0, max = 0, slow = 0, vslow = 0 } or nil
local function ride(r)
	local x, y, z, yaw = spots[r][1], spots[r][2], spots[r][3], spots[r][4]
	-- dropped from 18 units and left up to 3 s to come to rest. SK8_SETTLE=quick:
	-- put down at the spot itself (the module lifts a spawn 16 units: 15.5 taken
	-- off) and pushed after 12 ticks - measured worse (tl features 34 clean /
	-- 25 unexplained vs 46-48 / 9-11: pushed before the board has settled)
	local quick = os.getenv("SK8_SETTLE") == "quick"
	skategm.Activate(x, y, quick and (z - 15.5) or (z + 2), yaw)
	-- settle: riding, and standing still, for 20 ticks in a row (up to 3 s) -
	-- so how the last ride ended can't carry over into this one
	local calm, q0 = 0, nil
	for i = 1, quick and 12 or 180 do
		local before = (skategm.Poll().tick or 0)
		skategm.Step(1 / 60, false, 0, 0, 0, 0, 0, 0, 0)
		local w = os.clock() + 0.5
		repeat q0 = skategm.Poll() until (q0.tick or 0) > before or os.clock() > w
		local v = q0.vel and math.sqrt(q0.vel[1] ^ 2 + q0.vel[2] ^ 2 + q0.vel[3] ^ 2) * 0.0254 or 0
		if verbose and q0.pos then
			local bx, by, bz = board(q0)
			log("  settle %3d: tick %s, pos %.1f %.1f %.2f, board %.1f %.1f %.2f, state %s, held %s", i, tostring(q0.tick), q0.pos[1], q0.pos[2], q0.pos[3], bx or 0, by or 0, bz or 0, tostring(q0.state), tostring(q0.held))
		end
		if (q0.state or ""):find("PhysicsGround") and v < 0.2 then calm = calm + 1 else calm = 0 end
		if calm >= 20 then break end
	end
	-- a spot the skater can't even stand on (bailed or slid off while settling):
	-- a bad test spot, not a collision result
	if not (q0 and (q0.state or ""):find("PhysicsGround")) then
		counts.badspot = counts.badspot + 1
		log("run %d: badspot (%s) | start %.1f %.1f %.1f yaw %.0f | rode 0 units | %s | at -", r, "not riding after settling", x, y, z, yaw, tostring(q0 and q0.state))
		return
	end
	-- moved away while settling: rolled down a slope off the spot, or put
	-- elsewhere by the engine (a respawn to its checkpoint - tl feature spot 54
	-- went 480 units); then pushed at the spot's heading, often sideways to the
	-- board (gms spot 24 rolled 75 units off a ramp and skidded; spot 8 fell
	-- 94 off its platform, 20 sideways). 200 sideways or 40 down by default;
	-- SK8_SETTLE_MOVE=64 also drops gms 24's kind (but 50 of tl's 85 feature
	-- spots roll that far on their slopes): the ride
	-- wouldn't test this spot at all
	do
		local bx, by = board(q0)
		local bz = select(3, board(q0))
		local away = tonumber(os.getenv("SK8_SETTLE_MOVE") or "200")
		if bx and ((bx - x) ^ 2 + (by - y) ^ 2 > away * away or bz < z - 40) then
			counts.badspot = counts.badspot + 1
			log("run %d: badspot (%s) | start %.1f %.1f %.1f yaw %.0f | rode 0 units | %s | at -", r, "moved away while settling", x, y, z, yaw, tostring(q0.state))
			return
		end
	end
	-- (v4) a spot the skater left while settling (slid off a coping, rolled down
	-- a ramp) or turned on: pushing at the spot's heading then shoves the board
	-- sideways - a skid, not a collision result. Opt-in (SK8_SETTLE_CHECK=1):
	-- it drops ~45 of tl's 120 feature spots, which roll away on slopes.
	if os.getenv("SK8_SETTLE_CHECK") == "1" then
		local bx, by = board(q0)
		local b = q0.bones or {}
		local f, rr = b[bone.TRUCK_FRONT or -1], b[bone.TRUCK_BACK or -1]
		local moved = bx and math.sqrt((bx - x) ^ 2 + (by - y) ^ 2) or 0
		local turned = 0
		if f and rr then
			local h = math.deg(math.atan2(f[2] - rr[2], f[1] - rr[1]))
			turned = math.abs(((h - yaw + 180) % 360) - 180)
			turned = math.min(turned, 180 - turned) -- (riding switch is fine)
		end
		if moved > 32 or turned > 30 then
			counts.badspot = counts.badspot + 1
			log("run %d: badspot (%s) | start %.1f %.1f %.1f yaw %.0f | rode 0 units | %s | at -", r,
				string.format("moved %.0f / turned %.0f while settling", moved, turned), x, y, z, yaw, tostring(q0.state))
			return
		end
	end
	if os.getenv("SK8_FREEZE_TEST") then
		local q1 = skategm.Poll()
		skategm.Push(300, 0, 0)
		skategm.SetFrozen(1)
		for _ = 1, 20 do skategm.Step(1 / 60, false, 0, 0, 0, 0, 0, 0, 0) local w = os.clock() + 0.02 repeat until os.clock() > w end
		local q2 = skategm.Poll()
		skategm.SetFrozen(0)
		for _ = 1, 30 do skategm.Step(1 / 60, false, 0, 0, 0, 0, 0, 0, 0) local w = os.clock() + 0.02 repeat until os.clock() > w end
		local q3 = skategm.Poll()
		log("FREEZE run %d: frozen reported %s, ticks %s -> %s -> %s, moved while frozen %.2f, after %.2f", r, tostring(q2.frozen), tostring(q1.tick), tostring(q2.tick), tostring(q3.tick),
			math.sqrt((q2.pos[1] - q1.pos[1]) ^ 2 + (q2.pos[2] - q1.pos[2]) ^ 2), math.sqrt((q3.pos[1] - q2.pos[1]) ^ 2 + (q3.pos[2] - q2.pos[2]) ^ 2))
		return
	end
	if os.getenv("SK8_MARKER_TEST") then
		local function hold(buttons, n)
			for _ = 1, n do
				local before = skategm.Poll().tick or 0
				skategm.Step(1 / 60, false, buttons, 0, 0, 0, 0, 0, 0)
				local w = os.clock() + 0.5
				repeat local q2 = skategm.Poll() until (q2.tick or 0) > before or os.clock() > w or q2.held
			end
		end
		local function waitHeld()
			local t0 = os.clock()
			local q2 = skategm.Poll()
			while (q2.held or false) and os.clock() - t0 < 30 do hold(0, 1) q2 = skategm.Poll() end
			return os.clock() - t0
		end
		local mz = skategm.Poll().pos[3]
		hold(0x0100, 15)
		local m1 = skategm.Poll().marker or {}
		hold(0x0100 + 0x0002, 4)
		hold(0x0100, 15)
		local m2 = skategm.Poll().marker or {}
		hold(0, 20)
		log("MARKER set: before canPlace %s active %s | after active %s canReturn %s pos %s", tostring(m1.canPlace), tostring(m1.active), tostring(m2.active), tostring(m2.canReturn), m2.pos and string.format("%.0f %.0f %.0f", m2.pos[1], m2.pos[2], m2.pos[3]) or "-")
		local fx, fy, fz = os.getenv("SK8_MARKER_FAR"):match("(%S+) (%S+) (%S+)")
		skategm.Activate(tonumber(fx), tonumber(fy), tonumber(fz), 0)
		hold(0, 2)
		local waited1 = waitHeld()
		hold(0, 60)
		local farPos = skategm.Poll().pos
		local unc0 = skategm.Poll().uncovered or 0
		local m3 = skategm.Poll().marker or {}
		hold(0x0100, 10)
		local maxp = 0
		if os.getenv("SK8_MARKER_CHECKPOINT") then
			hold(0, 1)
			skategm.ReturnToCheckpoint()
		else
			for _ = 1, 240 do
				hold(0x0100 + 0x0001, 1)
				local mm = skategm.Poll().marker or {}
				maxp = math.max(maxp, mm.progress or 0)
			end
		end
		log("MARKER return: after the teleport active %s canReturn %s, most progress %.2f", tostring(m3.active), tostring(m3.canReturn), maxp)
		local sawHeld = false
		hold(0, 3)
		if skategm.Poll().held then sawHeld = true end
		local waited2 = waitHeld()
		log("  waited %.1f s for the collision after the return", waited2)
		for k = 1, 300 do
			hold(0, 1)
			local q2 = skategm.Poll()
			if q2.held then sawHeld = true end
			if k % 30 == 0 or k < 6 then log("  after return %d: tick %s state %s held %s pos %.0f %.0f %.1f", k, tostring(q2.tick), tostring(q2.state), tostring(q2.held), q2.pos[1], q2.pos[2], q2.pos[3]) end
		end
		local back = skategm.Poll()
		log("MARKER run %d: marker z %.1f, far %.0f %.0f %.0f (waited %.1f s), back at %.0f %.0f %.1f, state %s, held seen %s, uncovered ticks %d, %s", r, mz, farPos[1], farPos[2], farPos[3], waited1, back.pos[1], back.pos[2], back.pos[3], tostring(back.state), tostring(sawHeld), (back.uncovered or 0) - unc0, (math.abs(back.pos[1] - x) < 600 and math.abs(back.pos[2] - y) < 600) and ((back.pos[3] > mz - 60) and "ON THE FLOOR" or "FELL") or "DID NOT RETURN")
		return
	end
	local builds0 = skategm.Poll().builds10s or 0
	-- SK8_SETTLE=facing: pushed along the board as it stands after settling
	-- (nose or tail, whichever is nearer the spot's heading) - a board that
	-- turned on a slope or coping while settling was pushed sideways (a skid)
	if os.getenv("SK8_SETTLE") == "facing" then
		local b = q0.bones or {}
		local f, rr = b[bone.TRUCK_FRONT or -1], b[bone.TRUCK_BACK or -1]
		if f and rr and (f[1] - rr[1]) ^ 2 + (f[2] - rr[2]) ^ 2 > 1 then
			local h = math.deg(math.atan2(f[2] - rr[2], f[1] - rr[1]))
			if math.abs(((h - yaw + 180) % 360) - 180) > 90 then h = h + 180 end
			yaw = h % 360
		end
	end
	local rad = math.rad(yaw)
	local sp = tonumber(os.getenv("SK8_PUSH") or "6") / 0.0254
	skategm.Push(math.cos(rad) * sp, math.sin(rad) * sp, 0)
	local result, at, seq, lastState, dist = "clean", nil, {}, nil, 0
	local airRun, landedAt, afterLanding = 0, nil, false
	local q = skategm.Poll()
	local lx, ly = q.pos and q.pos[1] or x, q.pos and q.pos[2] or y
	-- the board's path: tick and position after every step; speed over a few
	-- ticks of it (the skater's root sways with the animation, the board doesn't)
	local path, speeds, heads, event = {}, {}, {}, nil
	local fell, last_board, crossed = false, nil, nil
	for i = 1, tonumber(os.getenv("SK8_TICKS") or "180") do
		local before = q.tick or 0
		-- (experiment: a collision swap mid-ride - the same geometry, rebuilt)
		if i == 45 and os.getenv("SK8_FORCE_SWAP") then skategm.SetEntities({}) end
		-- (experiment: one push at a given tick, to see what it does there)
		if i == tonumber(os.getenv("SK8_TEST_PUSH_AT") or "-1") then
			local ok = skategm.Push(0, 0, tonumber(os.getenv("SK8_TEST_PUSH_Z") or "1500"))
			if verbose then log("  test push at tick %d: accepted %s", i, tostring(ok)) end
		end
		-- SK8_WIPE_STICK="lx ly": the left stick held while bailing; logs how
		-- the body turned, seen from the camera (WIPE run lines)
		local wlx, wly = 0, 0
		if os.getenv("SK8_WIPE_STICK") and (lastState or ""):find("Wipeout") then
			wlx, wly = os.getenv("SK8_WIPE_STICK"):match("(%S+)%s+(%S+)")
			wlx, wly = tonumber(wlx) or 0, tonumber(wly) or 0
		end
		local t0 = os.clock()
		skategm.Step(1 / 60, false, 0, 0, 0, wlx, wly, 0, 0)
		local w = os.clock() + 0.5
		repeat q = skategm.Poll() until (q.tick or 0) > before or os.clock() > w
		if TIMING then
			local ms = (os.clock() - t0) * 1000
			TIMING.n, TIMING.sum, TIMING.max = TIMING.n + 1, TIMING.sum + ms, math.max(TIMING.max, ms)
			if ms > 8 then TIMING.slow = TIMING.slow + 1 end
			if ms > 16 then TIMING.vslow = TIMING.vslow + 1 end
			TIMING.rmax = math.max(TIMING.rmax or 0, ms)
			if ms > 50 then log("  slow step at tick %d: %.0f ms (held %s, collision %s)", i, ms, tostring(q.held), tostring(q.collision)) end
			if q.cam and q.cam.up then
				local u = q.cam.up
				if TIMING.lastUp then
					local l = TIMING.lastUp
					TIMING.wob = (TIMING.wob or 0) + math.sqrt((u[1] - l[1]) ^ 2 + (u[2] - l[2]) ^ 2 + (u[3] - l[3]) ^ 2)
					TIMING.wobn = (TIMING.wobn or 0) + 1
				end
				TIMING.lastUp = { u[1], u[2], u[3] }
				if os.getenv("SK8_CAMLOG") then log("cam %d %.6f %.6f %.6f %.3f %.3f %.3f", i, u[1], u[2], u[3], q.cam.pos[1], q.cam.pos[2], q.cam.pos[3]) end
				if os.getenv("SK8_CAMLOG") and q.pos then log("camrel %d %s %.2f %.2f", i, tostring(q.state), q.cam.pos[3] - q.pos[3], math.sqrt((q.cam.pos[1] - q.pos[1]) ^ 2 + (q.cam.pos[2] - q.pos[2]) ^ 2)) end
			end
		end
		local s = q.state or "?"
		if os.getenv("SK8_HOM_TRACK") and q.bones then
			if not HOM then
				Color = Color or function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
				SKATEGM_MODES = SKATEGM_MODES or { Register = function() return { Allowed = function() return true end } end,
					Clamper = function(lo, hi, d) return function(v) return math.max(lo, math.min(hi, math.floor(tonumber(v) or d))) end end,
					Commas = function(n) return tostring(math.floor(n or 0)) end }
				math.Clamp = math.Clamp or function(v, lo, hi) return math.max(lo, math.min(hi, v)) end
				dofile("../addon/skategm/lua/skategm_hom/sh_hom.lua")
				HOM.IMPACT_MIN = tonumber(os.getenv("SK8_HOM_MIN") or "") or HOM.IMPACT_MIN
				HOM.DAMAGE_PER_UNIT = tonumber(os.getenv("SK8_HOM_DPU") or "") or HOM.DAMAGE_PER_UNIT
			end
			HOMT = HOMT or {}
			if i == 1 then HOMT.tracker = HOM.NewTracker() end
			local P = {}
			for nm, k in pairs(bone) do local b = q.bones[k] if b then P[nm] = { x = b[1], y = b[2], z = b[3] } end end
			local now = (q.tick or 0) / 60
			for _, ev in ipairs(HOMT.tracker:Feed(P, q.tick, s, nil, now)) do
				if ev.kind == "injury" then log("  HOM injury %s %s", HOM.PART[ev.part].name, HOM.LEVELS[ev.level].name) end
				if ev.kind == "done" then
					local res = ev.result
					local parts = {}
					for _, inj in ipairs(res.injuries) do parts[#parts + 1] = HOM.LEVELS[inj.level].name .. " " .. HOM.PART[inj.part].name end
					log("HOM run %d: score %d, damage %d, air %.2f s, %s", r, res.score, res.damage, res.air, table.concat(parts, ", "))
				end
			end
		end
		if os.getenv("SK8_WIPE_STICK") and q.bones and q.cam and s:find("Wipeout") then
			if not WIPE or WIPE.run ~= r then WIPE = { run = r, flip = 0, roll = 0, yaw = 0, n = 0 } end
			local b = q.bones
			local hips, head, ls, rs = b[bone.HIPS], b[bone.HEAD], b[bone.LEFTSHOULDER], b[bone.RIGHTSHOULDER]
			local f = { q.cam.fwd[1], q.cam.fwd[2], 0 }
			local fl = math.sqrt(f[1] ^ 2 + f[2] ^ 2)
			if hips and head and ls and rs and fl > 0.1 then
				local function sub(a, c) return { a[1] - c[1], a[2] - c[2], a[3] - c[3] } end
				local function dot(a, c) return a[1] * c[1] + a[2] * c[2] + a[3] * c[3] end
				local function cross(a, c) return { a[2] * c[3] - a[3] * c[2], a[3] * c[1] - a[1] * c[3], a[1] * c[2] - a[2] * c[1] } end
				local function flat(a, ax) local d = dot(a, ax) return { a[1] - ax[1] * d, a[2] - ax[2] * d, a[3] - ax[3] * d } end
				local function turn(p0, p1, ax)
					local u, v = flat(p0, ax), flat(p1, ax)
					return math.deg(math.atan2(dot(cross(u, v), ax), dot(u, v)))
				end
				f = { f[1] / fl, f[2] / fl, 0 }
				local rt = cross(f, { 0, 0, 1 })
				local body, sh = sub(head, hips), sub(rs, ls)
				if WIPE.body and WIPE.n < tonumber(os.getenv("SK8_WIPE_TICKS") or "40") then
					-- flip > 0: the head goes away from the camera; roll > 0: to
					-- the camera's right; yaw > 0: turning left seen from above
					WIPE.flip = WIPE.flip + turn(WIPE.body, body, { -rt[1], -rt[2], 0 })
					WIPE.roll = WIPE.roll + turn(WIPE.body, body, f)
					WIPE.yaw = WIPE.yaw + turn(WIPE.sh, sh, { 0, 0, 1 })
					WIPE.n = WIPE.n + 1
				end
				WIPE.body, WIPE.sh = body, sh
			end
		end
		if os.getenv("SK8_HOM_PROBE") and q.bones then
			HOMP = HOMP or { max = {}, hits = {} }
			local tickNow = q.tick or 0
			if HOMP.prev and tickNow > HOMP.prevTick then
				local dt = (tickNow - HOMP.prevTick) / 60
				for nm, k in pairs(bone) do
					local b, pb = q.bones[k], HOMP.prev[k]
					if b and pb then
						local v = { (b[1] - pb[1]) / dt, (b[2] - pb[2]) / dt, (b[3] - pb[3]) / dt }
						local pv = HOMP.prevV and HOMP.prevV[k]
						if pv and s:find("Wipeout") then
							local dv = math.sqrt((v[1] - pv[1]) ^ 2 + (v[2] - pv[2]) ^ 2 + (v[3] - pv[3]) ^ 2)
							HOMP.max[nm] = math.max(HOMP.max[nm] or 0, dv)
							if dv > 250 then HOMP.hits[#HOMP.hits + 1] = dv end
						end
						HOMP.prevV = HOMP.prevV or {}
						HOMP.prevV[k] = v
					end
				end
			end
			HOMP.prev, HOMP.prevTick = q.bones, tickNow
		end
		if s ~= lastState then seq[#seq + 1] = s lastState = s end
		-- (a landing: back on the ground after 0.2 s or more in the air)
		if s:find("Air") then airRun = airRun + 1 else if airRun >= 12 then landedAt = i end airRun = 0 end
		if q.pos then dist = dist + math.sqrt((q.pos[1] - lx) ^ 2 + (q.pos[2] - ly) ^ 2) lx, ly = q.pos[1], q.pos[2] end
		local bx, by, bz = board(q)
		path[#path + 1] = { q.tick or before, bx, by, bz }
		local p0, p1 = path[math.max(#path - WINDOW, 1)], path[#path]
		local ticks = p1[1] - p0[1]
		if ticks > 0 then
			local ddx, ddy, ddz = p1[2] - p0[2], p1[3] - p0[3], p1[4] - p0[4]
			local d = math.sqrt(ddx * ddx + ddy * ddy)
			-- (the board's full speed, climbing included: rolling up a ramp
			-- isn't a loss, only the horizontal part of it shrinks)
			speeds[#speeds + 1] = math.sqrt(d * d + ddz * ddz) / ticks * 60 * 0.0254
			heads[#heads + 1] = d > 0.01 and { ddx / d, ddy / d } or heads[#heads]
		end
		if os.getenv("SK8_AUDIOLOG") then
			log("  audio %d %s: %s %s %s %s grind %s", i, tostring(q.state), tostring(q.audioWheel0), tostring(q.audioWheel1), tostring(q.audioWheel2), tostring(q.audioWheel3), tostring(q.audioGrind))
		end
		if verbose and q.pos then
			local b = q.bones or {}
			local wz = {}
			for _, name in ipairs({ "LEFT_WHEELFRONT", "RIGHT_WHEELFRONT", "LEFT_WHEELBACK", "RIGHT_WHEELBACK" }) do
				local v = bone[name] and b[bone[name]]
				wz[#wz + 1] = v and string.format("%.2f", v[3]) or "?"
			end
			local v = q.velocity or q.vel or {}
			if os.getenv("SK8_BONEDUMP") and q.bones then
				local names = skategm.Poll(true).names or {}
				local parts = {}
				for k, nm in ipairs(names) do local m = q.bones[k] if m and (k <= 6 or nm:find("BOARD") or nm:find("SPINE") or nm:find("HIP")) then parts[#parts + 1] = string.format("%s %.0f %.0f %.0f", nm, m[1], m[2], m[3]) end end
				log("    bones: %s", table.concat(parts, "; "))
			end
			log("  tick %3d: speed %5.2f m/s, pos %.1f %.1f %.2f, board %.1f %.1f %.2f, state %s, wheels z %s, deck v %.2f %.2f %.2f", i, speeds[#speeds] or 0, q.pos[1], q.pos[2], q.pos[3], bx or 0, by or 0, bz or 0, s, table.concat(wz, " "), v[1] or 0, v[2] or 0, v[3] or 0)
		end
		-- through the world: the board's path this tick crosses a floor from
		-- above (a pit or a drop off an edge doesn't: nothing is crossed)
		if bx and last_board and ((bx - last_board[1]) ^ 2 + (by - last_board[2]) ^ 2 + (bz - last_board[3]) ^ 2) > 200 * 200 then
			last_board, crossed = nil, nil
		end
		if bx and last_board and not fell and bz < last_board[3] then
			local lx2, ly2, lz2 = last_board[1], last_board[2], last_board[3]
			local len = math.sqrt((bx - lx2) ^ 2 + (by - ly2) ^ 2 + (bz - lz2) ^ 2)
			local t = skategm.CollisionNear((bx + lx2) / 2, (by + ly2) / 2, (bz + lz2) / 2, len / 2 + 4, 8000)
			for k = 1, #t - 8, 9 do
				local ux, uy, uz, vx, vy, vz = t[k+3]-t[k], t[k+4]-t[k+1], t[k+5]-t[k+2], t[k+6]-t[k], t[k+7]-t[k+1], t[k+8]-t[k+2]
				local nz = ux*vy-uy*vx
				local l = math.sqrt((uy*vz-uz*vy)^2 + (uz*vx-ux*vz)^2 + nz^2)
				if l > 1e-9 and nz / l > 0.3 and seg_hits(t, k, lx2, ly2, lz2, bx, by, bz) then
					-- (only a candidate: over a sharply curved ramp top the point
					-- between the trucks can dip under the surface for a tick)
					crossed = crossed or { i, (lz2 + bz) / 2, q.pos }
					if verbose then log("  crossed a floor between %.1f %.1f %.2f and %.1f %.1f %.2f", lx2, ly2, lz2, bx, by, bz) end
					break
				end
			end
		end
		if bx then last_board = { bx, by, bz } end
		-- a fall through: the board ends up well below the floor it crossed
		if crossed and bz and not fell and bz < crossed[2] - 20 then
			fell = true
			result, at = "fellthrough", crossed[3]
		end
		if crossed and i - crossed[1] > 60 and not fell then crossed = nil end
		if s:find("Wipeout") and result == "clean" then
			result, at = "bail", q.pos
			afterLanding = (landedAt ~= nil and i - landedAt <= 12) or airRun >= 12
		end
		if s:find("Biped") and result == "clean" then result, at = "runout", q.pos end
		-- a sudden drop: over 2 m/s lost within 0.1 s, from the first ticks on
		-- (a board stopped dead just after the push counts too)
		if result == "clean" and #speeds > 1 then
			local peak = 0
			for k = math.max(#speeds - 6, 1), #speeds - 1 do peak = math.max(peak, speeds[k]) end
			if peak > 3 and peak - speeds[#speeds] > 2 then
				result, at = "drop", q.pos
				afterLanding = (landedAt ~= nil and i - landedAt <= 12) or airRun >= 12
			end
		end
		if at and not event then event = heads[math.max(#heads - 8, 1)] end
	end
	counts[result] = counts[result] + 1
	local why = "-"
	if at then
		local hx, hy = math.cos(rad), math.sin(rad)
		if event then hx, hy = event[1], event[2] end
		why = obstacle_ahead(at[1], at[2], at[3], hx, hy)
		-- (a drop just after landing from real air, with nothing in the way:
		-- the landing itself - the engine loses speed landing flat)
		if why == "UNEXPLAINED" and afterLanding then why = "after a landing" end
		local k = why == "UNEXPLAINED" and "unexplained" or why == "lip ahead" and "lip" or why == "after a landing" and "landing" or "real"
		counts[k] = counts[k] + 1
		if why ~= "real obstacle ahead" then
			local t, tags = skategm.CollisionNear(at[1], at[2], at[3], 40, 4000)
			geo:write(string.format("--- run %d %s (%s) at %.2f %.2f %.2f heading %.3f %.3f\n", r, result, why, at[1], at[2], at[3], hx, hy))
			for i = 1, #t - 8, 9 do
				geo:write(string.format("%d | %.2f %.2f %.2f | %.2f %.2f %.2f | %.2f %.2f %.2f\n", tags[(i - 1) / 9 + 1] or -1, t[i], t[i+1], t[i+2], t[i+3], t[i+4], t[i+5], t[i+6], t[i+7], t[i+8]))
			end
			geo:flush()
		end
	end
	local builds1 = skategm.Poll().builds10s or 0
	if WIPE and WIPE.run == r then log("WIPE run %d: stick %s yaw %.0f | flip %.0f roll %.0f yaw %.0f degrees over %d ticks", r, os.getenv("SK8_WIPE_STICK"), yaw, WIPE.flip, WIPE.roll, WIPE.yaw, WIPE.n) end
	log("run %d: %s (%s) | start %.1f %.1f %.1f yaw %.0f | rode %.0f units | %s | at %s", r, result, why, x, y, z, yaw, dist, table.concat(seq, " > "),
		at and string.format("%.1f %.1f %.1f", at[1], at[2], at[3]) or "-")
	if builds1 > builds0 then log("  (collision rebuilt during run %d)", r) end
end
for r = 1, math.min(runs, #spots) do
	if (not verbose or only[r]) and not done[r] and wanted(spots[r]) then
		if TIMING then TIMING.rmax = 0 end
		local p0 = skategm.Poll()
		local rec0, unc0 = p0.recovered or 0, p0.uncovered or 0
		ride(r)
		local pr = skategm.Poll()
		if (pr.uncovered or 0) > unc0 then
			UNCOVERED = (UNCOVERED or 0) + 1
			log("UNCOVERED during run %d: %d ticks outside the installed collision", r, pr.uncovered - unc0)
		end
		if (pr.recovered or 0) > rec0 then
			RECOVERIES = (RECOVERIES or 0) + 1
			log("RECOVERED during run %d: %s", r, tostring(pr.warning):sub(1, 160) .. " ... " .. tostring(pr.warning):sub(-80))
		end
		if TIMING then log("timing %d: slowest step %.1f ms", r, TIMING.rmax) end
	end
end
if TIMING then log("CAMERA: mean change of the camera's up vector per tick %.5f", (TIMING.wob or 0) / math.max(1, TIMING.wobn or 0)) end
if TIMING then log("TIMING: %d steps, mean %.2f ms, max %.1f ms, over 8 ms %d, over 16 ms %d", TIMING.n, TIMING.sum / math.max(1, TIMING.n), TIMING.max, TIMING.slow, TIMING.vslow) end
if HOMP then
	local names = {}
	for nm, v in pairs(HOMP.max) do names[#names + 1] = string.format("%s %.0f", nm, v) end
	table.sort(names)
	table.sort(HOMP.hits)
	local function pct(f) return HOMP.hits[math.max(1, math.floor(#HOMP.hits * f))] or 0 end
	log("HOM PROBE max dv per bone (u/s): %s", table.concat(names, ", "))
	log("HOM PROBE impacts over 250 u/s: %d, median %.0f, p90 %.0f, p99 %.0f", #HOMP.hits, pct(0.5), pct(0.9), pct(0.99))
end
log("RECOVERIES: %d", RECOVERIES or 0)
log("UNCOVERED RIDES: %d", UNCOVERED or 0)
log("SUMMARY %s: %d runs: clean %d, bails %d, runouts %d, sudden drops %d, fell through %d, bad spots %d | at a real obstacle %d, at a low lip %d, after a landing %d, UNEXPLAINED %d", style, runs, counts.clean, counts.bail, counts.runout, counts.drop, counts.fellthrough, counts.badspot, counts.real, counts.lip, counts.landing, counts.unexplained)
geo:close()
skategm.Stop()
out:close()
