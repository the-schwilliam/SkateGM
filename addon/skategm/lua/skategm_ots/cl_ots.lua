-- Own the Spot, client: a spot game (skategm_modes/cl_spotgame.lua).
if not SKATEGM_MODES.SpotClient then include("skategm_modes/cl_spotgame.lua") end
SKATEGM_MODES.SpotClient(OTS, {
	description = "score the most at one spot",
	about = "Everyone skates the same spot, one at a time. You get one line to score as many points as you can. A bail scores nothing. The highest score wins.",
	crown = "OWNS THE SPOT",
})
