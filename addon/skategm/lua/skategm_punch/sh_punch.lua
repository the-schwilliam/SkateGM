SKATEGM_PUNCH = SKATEGM_PUNCH or {}
local P = SKATEGM_PUNCH
P.NET = "skategm_punch"         -- skater -> server: I punched from here, facing this way
P.NET_HIT = "skategm_punch_hit" -- server -> a skater who was hit: bail with this velocity
P.SWING = 0.35    -- seconds the engine holds the shove
P.LAND = 0.15     -- when the fist lands
P.COOLDOWN = 0.45 -- between punches
P.REACH = 60      -- from the chest, along the facing (units)
P.RADIUS = 40     -- how far from that point a target counts
-- swung with the board (on foot, board in hand): longer, later, harder
P.LAND_BOARD = 0.25
P.REACH_BOARD = 80
P.BOARD_DAMAGE = 1.8 -- times the punch's damage
P.BOARD_FORCE = 1.5  -- times the punch's throw

-- whether the skater holds the board (a hand at the deck)
function P.HoldingBoard(pose)
	local board = pose and (pose.SKATEBOARD_ROOT or pose.TRUCK_FRONT)
	if not board then return false end
	for _, hand in ipairs({ "LEFTHAND", "RIGHTHAND" }) do
		if pose[hand] and pose[hand]:DistToSqr(board) < 30 * 30 then return true end
	end
	return false
end
