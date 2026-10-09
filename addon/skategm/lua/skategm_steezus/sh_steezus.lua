-- Steezus Stint, shared: settings limits and message names.
--
-- How a session runs (the server decides, every client follows its state):
--   lobby     the host created it at their spot; players join; the host sets
--             turn length and rounds, and starts it when ready
--   prep      the active player switches to Skater mode and goes to the spot
--   countdown 3, 2, 1
--   turn      the active player skates; their turn score is the game's
--             points they earn during it; everyone else spectates
--   between   that turn's result, then the next player (or the next round)
--   final     standings: the best single turn is Steezus
STEEZUS = STEEZUS or {}

STEEZUS.mode = SKATEGM_MODES.Register({ id = "steezus", category = "Tricks", title = "Steezus Stint", order = 12, color = Color(255, 235, 160), netState = "skategm_steezus_state", netCommand = "skategm_steezus_cmd" })
STEEZUS.NET_STATE = STEEZUS.mode.NET_STATE
STEEZUS.NET_CMD = STEEZUS.mode.NET_CMD

STEEZUS.TURN_MIN, STEEZUS.TURN_MAX, STEEZUS.TURN_DEFAULT = 10, 300, 45
STEEZUS.ROUNDS_MIN, STEEZUS.ROUNDS_MAX, STEEZUS.ROUNDS_DEFAULT = 1, 10, 2
STEEZUS.PREP_TIMEOUT = 40  -- seconds for a player to get into Skater mode at the spot
STEEZUS.COUNTDOWN = 3
STEEZUS.BETWEEN = 4
STEEZUS.FINAL = 12
STEEZUS.MAX_SCORE = 50000000
STEEZUS.RATE = 100 -- points a second in the Christ Air pose (doubled during a back / front flip)

STEEZUS.ClampTurn = SKATEGM_MODES.Clamper(STEEZUS.TURN_MIN, STEEZUS.TURN_MAX, STEEZUS.TURN_DEFAULT)
STEEZUS.ClampRounds = SKATEGM_MODES.Clamper(STEEZUS.ROUNDS_MIN, STEEZUS.ROUNDS_MAX, STEEZUS.ROUNDS_DEFAULT)

STEEZUS.cvAllowed = STEEZUS.mode.cvAllowed
function STEEZUS.Allowed() return STEEZUS.mode:Allowed() end
