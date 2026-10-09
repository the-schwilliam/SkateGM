-- A spot game, client: follows the server's session state, runs your turn,
-- spectates everyone else's, and draws the display. spec: description,
-- crown (the winner line), lobby (an extra lobby line), Score(C, a, now)
-- (the turn's scoring; default the game's points), PaintTurn.
function SKATEGM_MODES.SpotClient(T, spec)
	spec = spec or {}
	local ID = "skategm_" .. T.mode.id
	local C = { state = { phase = "idle" }, cam = nil }
	T.client = C

	local API = SKATEGM_MODES.API
	local function Send(t) T.mode:Send(t) end
	local CanSkate = SKATEGM_MODES.CanSkate
	local function Say(text, bad) T.mode:Say(text, bad) end

	local Commas = SKATEGM_MODES.Commas
	local Clock = SKATEGM_MODES.Clock

	local ACTIVE = { prep = true, countdown = true, turn = true, between = true }

	function C.IsMine(st) return st.active and st.active ~= 0 and st.active == LocalPlayer():EntIndex() end
	function C.Taking(st)
		local me = LocalPlayer():EntIndex()
		for _, p in ipairs(st.players or {}) do if p.ent == me then return true end end
		return false
	end

	---------------------------------------------------------------------------
	-- following the server
	---------------------------------------------------------------------------
	C.BAIL_HOLD, C.BAIL_GRACE = 0.25, 1

	C.JustDone = SKATEGM_MODES.JustDone

	function C.OnState(st, now)
		local prev = C.state or { phase = "idle" }
		C.state = st
		C.stateAt = now
		local mine, wasMine = C.IsMine(st), C.IsMine(prev)
		local a = API()
		-- someone else's turn: waiting, out of sight and out of the way
		if a and a.SetHidden then a.SetHidden(T.mode.id, (ACTIVE[st.phase] and C.Taking(st) and not mine and not C.JustDone(st)) or false) end
		T.mode:KeepApart(ACTIVE[st.phase] and C.Taking(st))
		st.spotV = st.spot and Vector(st.spot[1], st.spot[2], st.spot[3]) or nil
		-- my turn begins: into Skater mode, then to the spot (see Think)
		if st.phase == "prep" and mine and not (prev.phase == "prep" and wasMine) then
			C.prep = { t = now, teleported = false, readySent = false }
			if a then a.StartSkating() end
			Say("your turn: get ready")
		end
		-- the clock starts: a fresh start from the spot, score counted from here
		if st.phase == "turn" and mine and not (prev.phase == "turn" and wasMine) then
			if a then
				if st.spotV then a.TeleportTo(st.spotV, st.yaw) end
				C.baseline = a.Score()
				C.baseBanked = C.Banked(a)
			end
			C.current, C.nextLive, C.bailSent, C.lastT, C.turnAt, C.wipeSince = 0, 0, nil, nil, now, nil
		end
		-- my turn ended: send the final score
		if prev.phase == "turn" and wasMine and not (st.phase == "turn" and mine) then
			Send({ cmd = "final", score = C.current or 0 })
		end
		-- someone else's turn: watch instead of skating
		T.mode:Spectate((ACTIVE[st.phase] and C.Taking(st) and not mine and not C.JustDone(st)) and SKATEGM_MODES.Others(st) or nil, { prefer = st.active })
		if st.phase ~= prev.phase or st.active ~= prev.active then C.cam = nil end
		if st.phase == "idle" and prev.phase ~= "idle" then C.baseline, C.current, C.prep = nil, nil, nil end
	end

	T.mode:OnState(function(st, now) C.OnState(st, now) end)

	-- the points already banked (a line still going isn't: a bail loses it)
	function C.Banked(a)
		local info = a.ScoreInfo and a.ScoreInfo()
		return info and info.total or (a.Score and a.Score() or 0)
	end

	function C.Think(now)
		local st = C.state
		local a = API()
		if not a then return end
		if not T.mode:TurnPrep(C, st, a, now, st.spotV, st.yaw) and st.phase == "turn" and C.IsMine(st) and C.baseline then
			local state = a.State and a.State() or ""
			if spec.Score then
				spec.Score(C, a, now)
			elseif state:find("Wipeout", 1, true) then
				C.current = math.max(0, C.Banked(a) - (C.baseBanked or 0))
			else
				C.current = math.max(0, a.Score() - C.baseline)
			end
			-- (a real bail: a quarter second in the wipeout, not in the turn's first
			-- second, when the start teleport can read as one for a moment)
			if state:find("Wipeout", 1, true) then C.wipeSince = C.wipeSince or now else C.wipeSince = nil end
			if st.bailEnds and not C.bailSent and C.wipeSince and now - C.wipeSince >= C.BAIL_HOLD and now - (C.turnAt or now) >= C.BAIL_GRACE then
				C.bailSent = true
				Send({ cmd = "bailed", score = C.current })
			end
			if now > (C.nextLive or 0) then
				C.nextLive = now + 0.25
				Send({ cmd = "live", score = C.current })
			end
		end
	end
	hook.Add("Think", ID, function() C.Think(RealTime()) end)

	---------------------------------------------------------------------------
	-- spectating: a chase camera on the active skater
	---------------------------------------------------------------------------
	function C.View(now, skating)
		local st = C.state
		if not ACTIVE[st.phase] or C.IsMine(st) then return nil end
		if not (C.Taking(st) or C.watch) then return nil end
		local a = API()
		if a and a.IsSkating() and not skating then return nil end
		local target, dir
		local active = st.active and Entity(st.active)
		local P = a and IsValid(active) and a.PoseOf(active) or nil
		if P and P.HIPS then
			target = P.HIPS + Vector(0, 0, 10)
			local cam = C.cam or {}
			if cam.last then
				local moved = target - cam.last
				moved.z = 0
				if moved:LengthSqr() > 0.25 then cam.dir = LerpVector(0.08, cam.dir or moved:GetNormalized(), moved:GetNormalized()) end
			end
			cam.last = target
			dir = cam.dir or Angle(0, st.yaw or 0, 0):Forward()
			local want = target - dir:GetNormalized() * 130 + Vector(0, 0, 55)
			cam.pos = cam.pos and LerpVector(0.12, cam.pos, want) or want
			C.cam = cam
			return { origin = cam.pos, angles = (target - cam.pos):Angle(), drawviewer = false }
		elseif st.spotV then
			-- nobody to follow yet: look at the spot
			local d = Angle(0, (st.yaw or 0) + 180, 0):Forward()
			local pos = st.spotV - d * -160 + Vector(0, 0, 90)
			return { origin = pos, angles = (st.spotV - pos):Angle(), drawviewer = false }
		end
	end

	---------------------------------------------------------------------------
	-- display
	---------------------------------------------------------------------------
	local BIG, MID, SMALL = ID .. "_big", ID .. "_mid", ID .. "_small"
	local FONTS = {
		[BIG] = { "Coolvetica", 0.05, 500 },
		[MID] = { "Coolvetica", 0.026, 500 },
		[SMALL] = { "Roboto", 0.017, 700 },
	}
	local function Fonts() T.mode:Fonts(FONTS) end
	local function Text(t, font, x, y, col, ax) SKATEGM_MODES.Text(t, font, x, y, col, ax or TEXT_ALIGN_LEFT, 1) end

	local function Standings(st)
		local rows = {}
		for _, p in ipairs(st.players or {}) do rows[#rows + 1] = { name = p.name, best = p.best or 0, turns = p.turns or 0 } end
		for _, g in ipairs(st.gone or {}) do rows[#rows + 1] = { name = g.name .. " (left)", best = g.best or 0, turns = 1 } end
		table.sort(rows, function(x, y) return x.best > y.best end)
		return rows
	end
	C.Standings = Standings

	function C.Paint(w, h, now)
		if SKATEGM_MODES.HudHidden() then return end
		local st = C.state
		if st.phase == "idle" then return end
		Fonts()
		local gold, grey = Color(255, 210, 90), Color(200, 200, 200)
		local x, y, line = w * 0.02, h * 0.2, h * 0.024
		local hostName = "?"
		for _, p in ipairs(st.players or {}) do if p.ent == st.host then hostName = p.name end end
		local activeName
		for _, p in ipairs(st.players or {}) do if p.ent == st.active then activeName = p.name end end
		local left = (st.timeLeft or 0) - (now - (C.stateAt or now))

		if st.phase == "lobby" then return end
		Text(string.upper(T.mode.title), MID, x, y, gold)
		y = y + line * 1.3
		Text(string.format("round %d / %d", math.min(st.round or 1, st.rounds or 1), st.rounds or 1), SMALL, x, y, grey)
		y = y + line
		local standings = Standings(st)
		for i, r in ipairs(standings) do
			if i > 8 then
				Text("+" .. (#standings - 8) .. " more", SMALL, x, y, grey)
				break
			end
			Text(string.format("%d. %s  %s", i, r.name, r.turns > 0 and Commas(r.best) or "-"), SMALL, x, y, i == 1 and r.best > 0 and gold or color_white)
			y = y + line * 0.85
		end
		-- the middle of the screen: whose turn, countdown, clock, result
		local cx, cy = w / 2, h * 0.1
		if st.phase == "prep" then
			Text((activeName or "?") .. " is getting to the spot...", MID, cx, cy, grey, TEXT_ALIGN_CENTER)
		elseif st.phase == "countdown" then
			Text(C.IsMine(st) and "YOUR TURN" or ((activeName or "?") .. "'S TURN"), MID, cx, cy, gold, TEXT_ALIGN_CENTER)
			Text(tostring(math.max(1, math.ceil(left))), BIG, cx, cy + line * 1.4, color_white, TEXT_ALIGN_CENTER)
		elseif st.phase == "turn" then
			local score = C.IsMine(st) and (C.current or 0) or (st.live or 0)
			Text(string.format("%s   %s", C.IsMine(st) and "YOU" or (activeName or "?"), Clock(left)), MID, cx, cy, left <= 5 and Color(255, 110, 90) or color_white, TEXT_ALIGN_CENTER)
			Text(Commas(math.floor(score)), BIG, cx, cy + line * 1.4, gold, TEXT_ALIGN_CENTER)
			if spec.PaintTurn then spec.PaintTurn(C, st, cx, cy, line, MID) end
		elseif st.phase == "between" and st.last then
			local r = st.last
			Text(r.skipped and (r.name .. ": skipped (" .. (r.reason or "") .. ")") or string.format("%s scored %s", r.name, Commas(r.score)),
				MID, cx, cy, gold, TEXT_ALIGN_CENTER)
		elseif st.phase == "final" then
			if st.winner then
				Text(string.upper(st.winner.name) .. " " .. (spec.crown or "WINS"), BIG, cx, cy, gold, TEXT_ALIGN_CENTER)
				Text(Commas(st.winner.score) .. " points", MID, cx, cy + line * 2.2, color_white, TEXT_ALIGN_CENTER)
			else
				Text("nobody set a score", MID, cx, cy, grey, TEXT_ALIGN_CENTER)
			end
		end
	end

	local panel
	local function EnsurePanel()
		if IsValid(panel) then return end
		panel = vgui.Create("DPanel")
		panel:SetPos(0, 0)
		panel:SetSize(ScrW(), ScrH())
		panel:SetMouseInputEnabled(false)
		panel:SetKeyboardInputEnabled(false)
		panel.Paint = function(self, w, h)
			if self:GetWide() ~= ScrW() then self:SetSize(ScrW(), ScrH()) end
			local ok, err = pcall(C.Paint, w, h, RealTime())
			if not ok and not C.paintErr then C.paintErr = tostring(err) Say("display error: " .. C.paintErr, true) end
		end
	end
	hook.Add("Think", ID .. "_panel", function()
		if C.state.phase ~= "idle" and vgui and vgui.Create then EnsurePanel() end
	end)

	-- the spot: a ring on the ground and a post
	hook.Add("PostDrawTranslucentRenderables", ID, function(depth, sky)
		local st = C.state
		if depth or sky or st.phase == "idle" or not st.spotV then return end
		local p = st.spotV + Vector(0, 0, 1)
		local pulse = 0.6 + 0.4 * math.sin(RealTime() * 3)
		local col = Color(255, 210, 90, 255 * pulse)
		for i = 0, 31 do
			local a0, a1 = i / 32 * math.pi * 2, (i + 1) / 32 * math.pi * 2
			render.DrawLine(p + Vector(math.cos(a0), math.sin(a0), 0) * 40, p + Vector(math.cos(a1), math.sin(a1), 0) * 40, col, true)
		end
		render.SetColorMaterial()
		render.DrawBox(p, angle_zero, Vector(-1, -1, 0), Vector(1, 1, 80), Color(255, 210, 90, 120 * pulse))
	end)

	---------------------------------------------------------------------------
	-- commands, chat and the host menu
	---------------------------------------------------------------------------
	concommand.Add(ID .. "_create", function(_, _, args)
		Send({ cmd = "create", turn = tonumber(args[1]) or T.TURN_DEFAULT, rounds = tonumber(args[2]) or T.ROUNDS_DEFAULT, canSkate = CanSkate() })
	end, nil, T.mode.title .. ": open a challenge at your spot [turn seconds] [rounds]")
	concommand.Add(ID .. "_join", function() Send({ cmd = "join", canSkate = CanSkate() }) end)
	concommand.Add(ID .. "_leave", function() Send({ cmd = "leave" }) end)
	concommand.Add(ID .. "_start", function() Send({ cmd = "begin" }) end)
	concommand.Add(ID .. "_stop", function() Send({ cmd = "stop" }) end)
	concommand.Add(ID .. "_spot", function() Send({ cmd = "spot" }) end)
	concommand.Add(ID .. "_time", function(_, _, args) Send({ cmd = "settings", turn = tonumber(args[1]) }) end)
	concommand.Add(ID .. "_rounds", function(_, _, args) Send({ cmd = "settings", rounds = tonumber(args[1]) }) end)
	concommand.Add(ID .. "_watch", function() C.watch = not C.watch Say(C.watch and "watching the challenge" or "stopped watching") end)

	-- !<id> create [seconds] [rounds] | join | leave | start | stop | spot | time N | rounds N | menu | watch
	local CHAT = {}
	for _, k in ipairs({ "create", "join", "leave", "stop", "spot", "time", "rounds", "watch" }) do CHAT[k] = ID .. "_" .. k end
	CHAT.start = ID .. "_start"
	C.Chat = T.mode:ChatCommands(CHAT, "create [seconds] [rounds], join, leave, start, stop, spot, time N, rounds N, watch")

	T.mode:LobbyLines(function(st) local t = { string.format("%d s turns, %d round%s", st.turn or 0, st.rounds or 0, st.rounds == 1 and "" or "s") } if spec.lobby then t[#t + 1] = spec.lobby end return t end)

	T.mode:Host({
		description = spec.description,
		about = spec.about,
		options = {
			{ key = "turn", label = "Turn length", type = "number", min = T.TURN_MIN, max = T.TURN_MAX, step = 5, default = T.TURN_DEFAULT, format = function(v) return v .. " s" end },
			{ key = "rounds", label = "Rounds", type = "number", min = T.ROUNDS_MIN, max = T.ROUNDS_MAX, step = 1, default = T.ROUNDS_DEFAULT },
			{ key = "bailEnds", label = "A bail ends your turn", type = "bool", default = true },
		},
		start = function(v, mode)
			mode:Send({ cmd = "create", turn = v.turn, rounds = v.rounds, bailEnds = v.bailEnds, canSkate = CanSkate() })
		end,
	})
	return T
end
