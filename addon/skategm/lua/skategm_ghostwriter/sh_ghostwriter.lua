-- Ghost Writer, shared: the rules, limits and message names.
--
-- How a game runs (the server decides, every client follows its state):
--   lobby     the host stood at the start; players join
--   countdown everyone on the start, 3, 2, 1
--   running   everyone skates a run at once, the others out of sight; every
--             client records every run
--   replay    one run played back with everyone looking the same (one
--             playermodel, the default board): whose was it?
--   guess     everyone but its skater picks a name (kept unseen); then the
--             next run's replay
--   reveal    once every run's been guessed: each run in turn, who it was
--             and who got it right (points only show from here)
--   results   points: one for each right guess, one to the skater for each
--             wrong one; then the lobby
GHOSTWRITER = GHOSTWRITER or {}

GHOSTWRITER.mode = SKATEGM_MODES.Register({ id = "ghostwriter", category = "Party", title = "Ghost Writer", order = 13, color = Color(170, 200, 255), minPlayers = 3 })

GHOSTWRITER.RUN_MIN, GHOSTWRITER.RUN_MAX, GHOSTWRITER.RUN_DEFAULT = 10, 60, 20
GHOSTWRITER.COUNTDOWN = 3
GHOSTWRITER.REPLAY_GAP = 1.5
GHOSTWRITER.GUESS_TIME = 15
GHOSTWRITER.REVEAL = 5
GHOSTWRITER.RESULTS = 15
GHOSTWRITER.RECORD_RATE = 20

GHOSTWRITER.ClampRun = SKATEGM_MODES.Clamper(GHOSTWRITER.RUN_MIN, GHOSTWRITER.RUN_MAX, GHOSTWRITER.RUN_DEFAULT)

GHOSTWRITER.cvAllowed = GHOSTWRITER.mode.cvAllowed
function GHOSTWRITER.Allowed() return GHOSTWRITER.mode:Allowed() end
