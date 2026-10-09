-- Hot Potato, shared: limits and message names.
--
-- How a game runs (the server decides, every client follows its state):
--   lobby     the host created it where they stood (the start); players join
--             (joining switches you into Skater mode, so you're loaded in time)
--   countdown the host starts it: everyone in Skater mode is put on the start,
--             3, 2, 1
--   playing   one skater carries a ticking bomb; skating into someone passes
--             it on. Nobody knows when it goes off - the ticking only gets
--             faster. When it blows, whoever holds it is launched sky-high and
--             loses a life; out of lives, they're out. A fresh bomb goes to
--             someone still in, and the last one left wins.
--   results   the winner, then back to the lobby for a rematch
-- Skaters don't collide with each other while playing: a bump is just being
-- close enough.
POTATO = POTATO or {}

POTATO.mode = SKATEGM_MODES.Register({ music = "arena", id = "potato", category = "Chaos", title = "Hot Potato", order = 4, color = Color(255, 90, 60), netState = "skategm_potato_state", netCommand = "skategm_potato_cmd" })
POTATO.NET_STATE = POTATO.mode.NET_STATE
POTATO.NET_CMD = POTATO.mode.NET_CMD

POTATO.FUSE_MIN, POTATO.FUSE_MAX, POTATO.FUSE_DEFAULT = 10, 90, 25
POTATO.LIVES_MIN, POTATO.LIVES_MAX, POTATO.LIVES_DEFAULT = 1, 5, 1
POTATO.COUNTDOWN = 3
POTATO.SCATTER = 3     -- after GO (and after each blast): run before the bomb can move
POTATO.BETWEEN = 3     -- after a blast, before the next bomb
POTATO.RESULTS = 12
POTATO.MAX_PLAYERS = 16
POTATO.PASS_RADIUS = 48 -- how close (units, skater to skater) passes the bomb
POTATO.HOLD_GRACE = 1   -- seconds a new holder keeps it before they can pass it on
POTATO.NO_TAGBACK = 3   -- seconds before it can go straight back to who passed it
POTATO.FUSE_SPREAD = 0.4 -- each bomb's fuse is FUSE x (1 +- this), at random

POTATO.ClampFuse = SKATEGM_MODES.Clamper(POTATO.FUSE_MIN, POTATO.FUSE_MAX, POTATO.FUSE_DEFAULT)
POTATO.ClampLives = SKATEGM_MODES.Clamper(POTATO.LIVES_MIN, POTATO.LIVES_MAX, POTATO.LIVES_DEFAULT)

-- the ticking: seconds between beeps, given how much of the fuse is left
-- (0..1) - from one a second down to eight a second near the end
function POTATO.BeepGap(left) return 0.12 + 0.88 * math.Clamp(left or 1, 0, 1) end

POTATO.cvAllowed = POTATO.mode.cvAllowed
function POTATO.Allowed() return POTATO.mode:Allowed() end
