-- Rocket Royale, shared: the rules, limits and message names.
--
-- How a game runs (the server decides, every client follows its state):
--   lobby     the host opened it where they stood (the start line)
--   countdown everyone side by side on the start line, 3, 2, 1
--   playing   every rocket board fires flat out, all the time; a bail puts
--             you out (you watch the rest). Last one riding wins
--   results   the winner (or everyone still riding when time ran out)
ROCKETROYALE = ROCKETROYALE or {}

ROCKETROYALE.mode = SKATEGM_MODES.Register({ music = "arena", id = "rocketroyale", category = "Chaos", title = "Rocket Royale", order = 10, color = Color(255, 140, 50), minPlayers = 2 })

ROCKETROYALE.TIME_MIN, ROCKETROYALE.TIME_MAX, ROCKETROYALE.TIME_DEFAULT = 30, 600, 180
ROCKETROYALE.COUNTDOWN = 3
ROCKETROYALE.RESULTS = 12
ROCKETROYALE.SPACING = 64
ROCKETROYALE.OFF_GRACE = 1.5

ROCKETROYALE.ClampTime = SKATEGM_MODES.Clamper(ROCKETROYALE.TIME_MIN, ROCKETROYALE.TIME_MAX, ROCKETROYALE.TIME_DEFAULT)

-- where slot i of n stands: side by side across the start line
function ROCKETROYALE.SlotOffset(i, n, yaw)
	local r = math.rad((yaw or 0) - 90)
	local d = ((i or 1) - ((n or 1) + 1) / 2) * ROCKETROYALE.SPACING
	return math.cos(r) * d, math.sin(r) * d
end

ROCKETROYALE.cvAllowed = ROCKETROYALE.mode.cvAllowed
function ROCKETROYALE.Allowed() return ROCKETROYALE.mode:Allowed() end
