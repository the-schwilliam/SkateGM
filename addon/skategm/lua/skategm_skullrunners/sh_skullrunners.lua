-- Skull Runners, shared: the rules, limits and message names.
--
-- How a game runs (the server decides, every client follows its state):
--   lobby     the host picked the play area around them; players join
--   countdown everyone side by side where the host stood, 3, 2, 1
--   playing   skulls float all over the area: skate through one to take it.
--             A bail (an item's hit, or your own) drops some of yours
--             around you for anyone to grab. Items if the host turned them on
--   results   the most skulls wins; then the lobby
SKULLRUNNERS = SKULLRUNNERS or {}

SKULLRUNNERS.mode = SKATEGM_MODES.Register({ music = "arena", id = "skullrunners", category = "Arena", title = "Skull Runners", order = 15, color = Color(180, 255, 140), minPlayers = 1 })

SKULLRUNNERS.TIME_MIN, SKULLRUNNERS.TIME_MAX, SKULLRUNNERS.TIME_DEFAULT = 30, 600, 120
SKULLRUNNERS.SKULLS_MIN, SKULLRUNNERS.SKULLS_MAX, SKULLRUNNERS.SKULLS_DEFAULT = 10, 120, 40
SKULLRUNNERS.AREA_MIN, SKULLRUNNERS.AREA_MAX, SKULLRUNNERS.AREA_DEFAULT = 768, 6000, 2400
SKULLRUNNERS.COUNTDOWN = 3
SKULLRUNNERS.RESULTS = 15
SKULLRUNNERS.DROP = 3
SKULLRUNNERS.DROP_SPREAD = 140
SKULLRUNNERS.FLOAT = 30
SKULLRUNNERS.TOUCH = 56
SKULLRUNNERS.TOUCH_CHECK = 120
SKULLRUNNERS.SPACING = 72

SKULLRUNNERS.ClampTime = SKATEGM_MODES.Clamper(SKULLRUNNERS.TIME_MIN, SKULLRUNNERS.TIME_MAX, SKULLRUNNERS.TIME_DEFAULT)
SKULLRUNNERS.ClampSkulls = SKATEGM_MODES.Clamper(SKULLRUNNERS.SKULLS_MIN, SKULLRUNNERS.SKULLS_MAX, SKULLRUNNERS.SKULLS_DEFAULT)
SKULLRUNNERS.ClampArea = SKATEGM_MODES.Clamper(SKULLRUNNERS.AREA_MIN, SKULLRUNNERS.AREA_MAX, SKULLRUNNERS.AREA_DEFAULT)

function SKULLRUNNERS.SlotOffset(i, n, yaw)
	local r = math.rad((yaw or 0) - 90)
	local d = ((i or 1) - ((n or 1) + 1) / 2) * SKULLRUNNERS.SPACING
	return math.cos(r) * d, math.sin(r) * d
end

SKULLRUNNERS.cvAllowed = SKULLRUNNERS.mode.cvAllowed
function SKULLRUNNERS.Allowed() return SKULLRUNNERS.mode:Allowed() end
