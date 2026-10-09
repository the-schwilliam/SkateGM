-- Freeze Frame, shared: the rules, limits and message names.
--
-- How a game runs (the server decides, every client follows its state):
--   lobby     players join
--   countdown 3, 2, 1
--   shoot     everyone skates at once; left stick in freezes you where you
--             are and gives you a free camera: move it, FOV,
--             a filter, A takes the photo, B unfreezes to try again; no photo
--             when time's up: the chase camera's view is taken
--   show      every photo in turn, with whose it is
--   vote      everyone (the ones out too) votes for the worst photo
--   out       the worst photo's skater is out; then the next round
--   results   one skater left: they win; then the lobby
-- A photo is the camera, the filter and the frozen skeleton, not an image:
-- every client draws it again, so it's small to send and sharp everywhere.
FREEZEFRAME = FREEZEFRAME or {}

FREEZEFRAME.mode = SKATEGM_MODES.Register({ id = "freezeframe", category = "Party", title = "Freeze Frame", order = 21, color = Color(255, 120, 170), minPlayers = 2, maxCommandBytes = 16384 })

FREEZEFRAME.TIME_MIN, FREEZEFRAME.TIME_MAX, FREEZEFRAME.TIME_DEFAULT = 20, 180, 60
FREEZEFRAME.COUNTDOWN = 3
FREEZEFRAME.SHOW = 5
FREEZEFRAME.VOTE = 25
FREEZEFRAME.OUT = 5
FREEZEFRAME.RESULTS = 15
FREEZEFRAME.CAM_RANGE = 480
FREEZEFRAME.FOV_MIN, FREEZEFRAME.FOV_MAX, FREEZEFRAME.FOV_DEFAULT = 15, 110, 75
FREEZEFRAME.BONES_MAX = 80
FREEZEFRAME.BUTTON = 0x0040
FREEZEFRAME.FILTERS = { "none", "bw", "sepia", "film", "vhs", "contrast", "fisheye", "camcorder" }

FREEZEFRAME.ClampTime = SKATEGM_MODES.Clamper(FREEZEFRAME.TIME_MIN, FREEZEFRAME.TIME_MAX, FREEZEFRAME.TIME_DEFAULT)

local function Finite(v) return type(v) == "number" and v == v and v > -1e7 and v < 1e7 end

-- a photo as sent: cleaned, or nil (a skeleton of named points, a camera near it)
function FREEZEFRAME.CleanPhoto(m, near)
	if type(m) ~= "table" or type(m.pose) ~= "table" or type(m.cam) ~= "table" then return nil end
	local pose, count = {}, 0
	for name, p in pairs(m.pose) do
		count = count + 1
		if count > FREEZEFRAME.BONES_MAX or type(name) ~= "string" or #name > 32 or type(p) ~= "table" then return nil end
		if not (Finite(p[1]) and Finite(p[2]) and Finite(p[3])) then return nil end
		pose[name] = { math.floor(p[1] * 10 + 0.5) / 10, math.floor(p[2] * 10 + 0.5) / 10, math.floor(p[3] * 10 + 0.5) / 10 }
	end
	local hips = pose.HIPS
	if not hips then return nil end
	local c = m.cam
	if not (type(c.pos) == "table" and type(c.ang) == "table" and Finite(c.pos[1]) and Finite(c.pos[2]) and Finite(c.pos[3])
		and Finite(c.ang[1]) and Finite(c.ang[2]) and Finite(c.ang[3]) and Finite(c.fov)) then return nil end
	local d = math.sqrt((c.pos[1] - hips[1]) ^ 2 + (c.pos[2] - hips[2]) ^ 2 + (c.pos[3] - hips[3]) ^ 2)
	if d > FREEZEFRAME.CAM_RANGE + 32 then return nil end
	if near and math.sqrt((near.x - hips[1]) ^ 2 + (near.y - hips[2]) ^ 2 + (near.z - hips[3]) ^ 2) > 400 then return nil end
	local filter = "none"
	for _, f in ipairs(FREEZEFRAME.FILTERS) do if f == m.filter then filter = f end end
	return {
		pose = pose,
		cam = { pos = { c.pos[1], c.pos[2], c.pos[3] }, ang = { c.ang[1], c.ang[2], c.ang[3] },
			fov = math.max(FREEZEFRAME.FOV_MIN, math.min(FREEZEFRAME.FOV_MAX, c.fov)) },
		filter = filter,
	}
end

-- who's out: the most votes; a tie (or no votes at all) picked by roll(n)
function FREEZEFRAME.Worst(votes, candidates, roll)
	local count = {}
	for _, target in pairs(votes) do count[target] = (count[target] or 0) + 1 end
	local best, tied = 0, {}
	for _, ent in ipairs(candidates) do
		local n = count[ent] or 0
		if n > best then best, tied = n, { ent } elseif n == best then tied[#tied + 1] = ent end
	end
	if #tied == 0 then return nil, 0 end
	return tied[(roll or math.random)(#tied)], best
end

FREEZEFRAME.cvAllowed = FREEZEFRAME.mode.cvAllowed
function FREEZEFRAME.Allowed() return FREEZEFRAME.mode:Allowed() end
