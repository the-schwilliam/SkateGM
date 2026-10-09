-- Steezus Stint, server: a spot game (skategm_modes/sv_spotgame.lua).
if not SKATEGM_MODES.SpotServer then include("skategm_modes/sv_spotgame.lua") end
SKATEGM_MODES.SpotServer(STEEZUS, { winner = "%s is Steezus! (%s)" })
