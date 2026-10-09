-- Own the Spot, shared: settings limits and message names.
--
-- How a session runs (the server decides, every client follows its state):
--   lobby     the host created it at their spot; players join; the host sets
--             turn length and rounds, and starts it when ready
--   prep      the active player switches to Skater mode and goes to the spot
--   countdown 3, 2, 1
--   turn      the active player skates; their turn score is the game's
--             points they earn during it; everyone else spectates
--   between   that turn's result, then the next player (or the next round)
--   final     standings: the best single turn owns the spot
OTS = OTS or {}

OTS.mode = SKATEGM_MODES.Register({ id = "ots", category = "Tricks", title = "Own the Spot", order = 2, color = Color(255, 200, 80), netState = "skategm_ots_state", netCommand = "skategm_ots_cmd" })
OTS.NET_STATE = OTS.mode.NET_STATE
OTS.NET_CMD = OTS.mode.NET_CMD

OTS.TURN_MIN, OTS.TURN_MAX, OTS.TURN_DEFAULT = 10, 300, 45
OTS.ROUNDS_MIN, OTS.ROUNDS_MAX, OTS.ROUNDS_DEFAULT = 1, 10, 2
OTS.PREP_TIMEOUT = 40  -- seconds for a player to get into Skater mode at the spot
OTS.COUNTDOWN = 3
OTS.BETWEEN = 4
OTS.FINAL = 12
OTS.MAX_SCORE = 50000000

OTS.ClampTurn = SKATEGM_MODES.Clamper(OTS.TURN_MIN, OTS.TURN_MAX, OTS.TURN_DEFAULT)
OTS.ClampRounds = SKATEGM_MODES.Clamper(OTS.ROUNDS_MIN, OTS.ROUNDS_MAX, OTS.ROUNDS_DEFAULT)

OTS.cvAllowed = OTS.mode.cvAllowed
function OTS.Allowed() return OTS.mode:Allowed() end
