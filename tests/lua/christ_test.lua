dofile("gmock.lua")
local ME = { EntIndex = function() return 3 end }
function RealTime() return 10 end
function LocalPlayer() return ME end
skategm = { SetFrozen = function() end, SetInputBlocked = function() end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S, A = SkateGM, SkateGM.API
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
S.phase = "on"
-- polls as the engine gives them (harness/christ.lua): the pose flag for either
-- hand, the trick named a moment later, tricksNamed counting each naming
local named = 4
local function poll(state, christ, trick)
	local p = { state = state, christAir = christ, score = { trick = trick or "", tricksNamed = named } }
	S.pose = p
	S.AirTrickThink(p, RealTime())
end
poll("PhysicsGround", false, "ID_TRICK_OLLIE")
poll("KnownAir", true, "ID_TRICK_OLLIE")
check("in the pose, not named yet: not a Christ Air (yet)", A.ChristPose() and not A.ChristAir())
named = 5
poll("KnownAir", true, "ID_TRICK_GRAB_CHRIST_AIR")
check("the engine names it Christ Air: it is one", A.ChristAir())
poll("KnownAir", false, "ID_TRICK_GRAB_CHRIST_AIR")
check("... out of the pose: not any more", not A.ChristAir())
poll("PhysicsGround", false, "ID_TRICK_GRAB_CHRIST_AIR")
poll("KnownAir", true, "ID_TRICK_GRAB_CHRIST_AIR")
check("the next air, before the engine names it: the last air's name doesn't count", not A.ChristAir())
named = 6
poll("KnownAir", true, "ID_TRICK_GRAB_CHRIST_AIR")
check("... a second Christ Air in a row, once named: counts", A.ChristAir())
poll("PhysicsGround", false, "ID_TRICK_GRAB_CHRIST_AIR")
poll("KnownAir", true, "ID_TRICK_GRAB_CHRIST_AIR")
named = 7
poll("KnownAir", true, "ID_TRICK_GRAB_NO_FOOT_AIR")
check("the other hand (a No Foot Air, the same pose): not a Christ Air", A.ChristPose() and not A.ChristAir())
named = 8
poll("KnownAir", true, "Christ Air")
check("the English name works too (Skate 3's text table)", A.ChristAir())
poll("KnownAir", false, "ID_TRICK_GRAB_SUPERMAN")
named = 9
poll("KnownAir", false, "ID_TRICK_GRAB_SUPERMAN")
check("a Superman: never", not A.ChristAir())
