SNAKE = SNAKE or {}

SNAKE.mode = SKATEGM_MODES.Register({ music = "arena", id = "snake", category = "Arena", title = "Snake", order = 5, color = Color(120, 255, 120), maxCommandBytes = 8000 })
SNAKE.NET_STATE, SNAKE.NET_CMD = SNAKE.mode.NET_STATE, SNAKE.mode.NET_CMD
SNAKE.NET_TRAIL = "skategm_mode_snake_trail"
SNAKE.cvAllowed = SNAKE.mode.cvAllowed
function SNAKE.Allowed() return SNAKE.mode:Allowed() end

SNAKE.RADIUS_MIN, SNAKE.RADIUS_MAX, SNAKE.RADIUS_DEFAULT = 512, 6000, 1536
SNAKE.TIME_MIN, SNAKE.TIME_MAX, SNAKE.TIME_DEFAULT = 30, 600, 180
SNAKE.LENGTH_MIN, SNAKE.LENGTH_MAX, SNAKE.LENGTH_DEFAULT = 200, 3000, 600
SNAKE.PELLETS_MIN, SNAKE.PELLETS_MAX, SNAKE.PELLETS_DEFAULT = 0, 30, 8
SNAKE.GROWTH = 250
SNAKE.SPACING = 16
SNAKE.HIT_RADIUS = 14
SNAKE.HIT_HEIGHT = 40
SNAKE.WALL_HEIGHT = 36
SNAKE.NECK = 120
SNAKE.EAT_RADIUS = 48
SNAKE.COUNTDOWN = 3
SNAKE.RESULTS = 12
SNAKE.MAX_PLAYERS = 12
SNAKE.MAX_POINTS = 30
SNAKE.COLORS = {
	{ 120, 255, 120 }, { 80, 200, 255 }, { 255, 110, 90 }, { 255, 220, 70 }, { 210, 120, 255 }, { 255, 150, 220 },
	{ 90, 255, 220 }, { 255, 160, 60 }, { 180, 255, 60 }, { 120, 140, 255 }, { 255, 255, 255 }, { 255, 80, 160 },
}

SNAKE.ClampRadius = SKATEGM_MODES.Clamper(SNAKE.RADIUS_MIN, SNAKE.RADIUS_MAX, SNAKE.RADIUS_DEFAULT)
SNAKE.ClampTime = SKATEGM_MODES.Clamper(SNAKE.TIME_MIN, SNAKE.TIME_MAX, SNAKE.TIME_DEFAULT)
SNAKE.ClampLength = SKATEGM_MODES.Clamper(SNAKE.LENGTH_MIN, SNAKE.LENGTH_MAX, SNAKE.LENGTH_DEFAULT)
SNAKE.ClampPellets = SKATEGM_MODES.Clamper(SNAKE.PELLETS_MIN, SNAKE.PELLETS_MAX, SNAKE.PELLETS_DEFAULT)

SNAKE.Clock = SKATEGM_MODES.Clock

function SNAKE.Trim(pts, len)
	local total = 0
	for i = #pts, 2, -1 do
		local a, b = pts[i], pts[i - 1]
		total = total + math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
		if total > len then
			for _ = 1, i - 1 do table.remove(pts, 1) end
			return pts
		end
	end
	return pts
end

local function SegmentDistance2D(px, py, ax, ay, bx, by)
	local dx, dy = bx - ax, by - ay
	local l2 = dx * dx + dy * dy
	local t = l2 > 0 and math.Clamp(((px - ax) * dx + (py - ay) * dy) / l2, 0, 1) or 0
	local cx, cy = ax + dx * t, ay + dy * t
	return math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2), t
end
SNAKE.SegmentDistance2D = SegmentDistance2D

function SNAKE.HitsTrail(head, pts, skipFromEnd)
	local skip = skipFromEnd or 0
	local last = #pts
	if skip > 0 then
		local total = 0
		while last > 1 and total < skip do
			local a, b = pts[last], pts[last - 1]
			total = total + math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2)
			last = last - 1
		end
	end
	for i = 1, last - 1 do
		local a, b = pts[i], pts[i + 1]
		local d, t = SegmentDistance2D(head[1], head[2], a[1], a[2], b[1], b[2])
		if d < SNAKE.HIT_RADIUS then
			local z = a[3] + (b[3] - a[3]) * t
			if math.abs(head[3] - z) < SNAKE.HIT_HEIGHT then return true end
		end
	end
	return false
end

function SNAKE.Outside(area, x, y)
	return area ~= nil and ((x - area[1]) ^ 2 + (y - area[2]) ^ 2) > area[4] ^ 2
end
