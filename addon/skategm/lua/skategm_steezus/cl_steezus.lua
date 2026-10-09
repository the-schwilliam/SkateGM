-- Steezus Stint, client: a spot game (skategm_modes/cl_spotgame.lua) scored on
-- time in the Christ Air pose, doubled while flipping.
if not SKATEGM_MODES.SpotClient then include("skategm_modes/cl_spotgame.lua") end
SKATEGM_MODES.SpotClient(STEEZUS, {
	description = "hold the Christ Air the longest",
	about = "Take turns at the same spot. You score for every second you hold the Christ Air. Flipping while you hold it doubles your points. The most points wins.",
	crown = "IS STEEZUS",
	lobby = "Christ Air: grab + B (one hand; the other is a No Foot Air); flip for double",
	Score = function(C, a, now)
		local dt = math.Clamp(now - (C.lastT or now), 0, 0.1)
		C.lastT = now
		-- (the engine names the trick a moment into the pose: once it says Christ
		-- Air, the time held before that counts too)
		local pose = a.ChristPose and a.ChristPose() or false
		if pose then C.poseSince = C.poseSince or now else C.poseSince, C.credited = nil, nil end
		C.posing = a.ChristAir and a.ChristAir() or false
		C.flipping = C.posing and a.BodyFlip and a.BodyFlip() or false
		if C.posing and not C.credited then
			C.credited = true
			C.current = (C.current or 0) + STEEZUS.RATE * math.max(0, now - (C.poseSince or now) - dt)
		end
		if C.posing then C.current = (C.current or 0) + STEEZUS.RATE * (C.flipping and 2 or 1) * dt end
	end,
	PaintTurn = function(C, st, cx, cy, line, font)
		if C.IsMine(st) and C.posing then SKATEGM_MODES.Text(C.flipping and "STEEZUS x2!" or "STEEZUS", font, cx, cy + line * 3.4, C.flipping and Color(255, 120, 60) or Color(255, 210, 90), TEXT_ALIGN_CENTER, 1) end
	end,
})
