-- Ball Battle, shared: the rules, limits and message names.
--
-- How a game runs (the server decides, every client follows its state):
--   lobby     the host picked the play area around them; players join
--   countdown everyone side by side where the host stood, 3, 2, 1
--   playing   everyone has bouncy balls circling them. An item's hit, or a
--             bail of your own, pops one; lose them all and you're out (you
--             watch the rest). Items if the host left them on
--   results   the last one with balls wins (or the most balls at the time
--             limit); then the lobby
BALLBATTLE = BALLBATTLE or {}

BALLBATTLE.mode = SKATEGM_MODES.Register({ music = "arena", id = "ballbattle", category = "Arena", title = "Ball Battle", order = 16, color = Color(255, 120, 200), minPlayers = 2 })

BALLBATTLE.TIME_MIN, BALLBATTLE.TIME_MAX, BALLBATTLE.TIME_DEFAULT = 60, 600, 180
BALLBATTLE.BALLS_MIN, BALLBATTLE.BALLS_MAX, BALLBATTLE.BALLS_DEFAULT = 1, 5, 3
BALLBATTLE.AREA_MIN, BALLBATTLE.AREA_MAX, BALLBATTLE.AREA_DEFAULT = 768, 6000, 2400
BALLBATTLE.COUNTDOWN = 3
BALLBATTLE.RESULTS = 15
BALLBATTLE.GRACE = 2.5 -- after a pop, the bail it causes doesn't pop another
BALLBATTLE.SPACING = 96

BALLBATTLE.ClampTime = SKATEGM_MODES.Clamper(BALLBATTLE.TIME_MIN, BALLBATTLE.TIME_MAX, BALLBATTLE.TIME_DEFAULT)
BALLBATTLE.ClampBalls = SKATEGM_MODES.Clamper(BALLBATTLE.BALLS_MIN, BALLBATTLE.BALLS_MAX, BALLBATTLE.BALLS_DEFAULT)
BALLBATTLE.ClampArea = SKATEGM_MODES.Clamper(BALLBATTLE.AREA_MIN, BALLBATTLE.AREA_MAX, BALLBATTLE.AREA_DEFAULT)

function BALLBATTLE.SlotOffset(i, n, yaw)
	local r = math.rad((yaw or 0) - 90)
	local d = ((i or 1) - ((n or 1) + 1) / 2) * BALLBATTLE.SPACING
	return math.cos(r) * d, math.sin(r) * d
end

-- a player's own ball colour (as GMod's bouncy balls: a bright random hue, here fixed per player)
function BALLBATTLE.Colour(ent)
	local h = ((ent or 0) * 67) % 360
	return HSVToColor and HSVToColor(h, 0.85, 1) or Color(255, 120, 200)
end

BALLBATTLE.cvAllowed = BALLBATTLE.mode.cvAllowed
function BALLBATTLE.Allowed() return BALLBATTLE.mode:Allowed() end
