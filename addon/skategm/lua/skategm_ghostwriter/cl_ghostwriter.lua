-- Ghost Writer, client: everyone's run recorded here (poses reach every
-- player), played back with everyone looking the same, the guessing.
local GW = GHOSTWRITER
local C = { state = { phase = "idle" }, clips = {}, sel = 1, padPrev = 0 }
GW.client = C

local API = SKATEGM_MODES.API
local function Send(t) GW.mode:Send(t) end
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) GW.mode:Say(text, bad) end
local PAD = { UP = 0x0001, DOWN = 0x0002, A = 0x1000 }
local HELD = { replay = true, guess = true, reveal = true }

function C.Me(st) return GW.mode:Me(st) end
function C.MyEnt() return LocalPlayer():EntIndex() end
function C.Runners(st)
	local out = {}
	for _, p in ipairs(st.players or {}) do if p.inRun then out[#out + 1] = p end end
	return out
end
function C.Choices(st)
	local out = {}
	for _, p in ipairs(C.Runners(st)) do if p.ent ~= C.MyEnt() then out[#out + 1] = p end end
	return out
end
function C.MyRun(st) return st.replay ~= nil and st.replay.ent == C.MyEnt() end

---------------------------------------------------------------------------
-- recording every run, and the replay camera
---------------------------------------------------------------------------
function C.StartRecording(st, now)
	local ents = {}
	for _, p in ipairs(C.Runners(st)) do ents[#ents + 1] = p.ent end
	SKATEGM_MODES.StartRecording(C, ents, now)
end
function C.Record(now) SKATEGM_MODES.RecordPoses(C, GW.RECORD_RATE, now) end

function C.Watch(target) SKATEGM_MODES.ChaseWatch(C, target, "ghostwriter_replay", 160, 64, true) end
function C.View(fov) return SKATEGM_MODES.ChaseView(C, fov, 160, 64, true) end

---------------------------------------------------------------------------
-- following the server
---------------------------------------------------------------------------
function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	st.startV = st.start and Vector(st.start[1], st.start[2], st.start[3]) or nil
	local me, a = C.Me(st), API()
	local inRun = me ~= nil and me.inRun
	if me and st.phase ~= "idle" and a and not a.IsSkating() and not a.IsLoading() and CanSkate() and not C.asked then
		C.asked = true
		a.StartSkating()
	end
	if not me then C.asked = nil end
	local running = st.phase == "countdown" or st.phase == "running"
	GW.mode:KeepApart(inRun and running)
	if st.phase == "running" and prev.phase ~= "running" then C.StartRecording(st, now) C.launched = nil end
	if prev.phase == "running" and st.phase ~= "running" then C.recStart = nil end
	local rp, prevRp = st.replay, prev.replay
	if st.phase == "replay" and rp and (prev.phase ~= "replay" or not prevRp or prevRp.index ~= rp.index) then
		local ply = rp.ent == C.MyEnt() and LocalPlayer() or Entity(rp.ent)
		local clip = C.clips[rp.ent]
		local key = a and a.PlayClip and IsValid(ply) and clip and #clip > 1 and a.PlayClip("ghostwriter", ply, clip, { plain = true }) or nil
		C.missing = key == nil
		C.Watch(key)
	end
	if not HELD[st.phase] and HELD[prev.phase] then
		if a and a.StopClip then a.StopClip("ghostwriter") end
		C.Watch(nil)
	end
	if st.phase == "guess" and prev.phase ~= "guess" then C.sel, C.myGuess = 1, nil end
	local hold = (inRun and HELD[st.phase]) or false
	if a and hold ~= (C.held or false) then
		C.held = hold
		if a.Freeze then a.Freeze(hold, "ghostwriter") end
		if a.BlockInput then a.BlockInput(hold, "ghostwriter") end
		if a.SetHidden then a.SetHidden("ghostwriter", hold) end
	end
	if st.phase == "reveal" and prev.phase ~= "reveal" and st.reveal then
		Say(string.format("that was %s! %s", st.reveal.name, #st.reveal.right > 0 and (table.concat(st.reveal.right, ", ") .. " got it") or "nobody got it"))
	end
end
GW.mode:OnState(function(st, now) C.OnState(st, now) end)

function C.GuessInput(pressed)
	local choices = C.Choices(C.state)
	if #choices == 0 or C.MyRun(C.state) then return end
	C.sel = math.Clamp(C.sel or 1, 1, #choices)
	if bit.band(pressed, PAD.UP) ~= 0 then C.sel = (C.sel - 2) % #choices + 1 end
	if bit.band(pressed, PAD.DOWN) ~= 0 then C.sel = C.sel % #choices + 1 end
	if bit.band(pressed, PAD.A) ~= 0 then
		C.myGuess = choices[C.sel].ent
		Send({ cmd = "guess", target = C.myGuess })
	end
end

function C.Think(now)
	local st, a = C.state, API()
	if st.phase == "running" then C.Record(now) end
	local me = C.Me(st)
	local inRun = me ~= nil and me.inRun
	GW.mode:HoldAtStart(inRun and st.phase == "countdown", st.startV, st.yaw, now)
	if not (a and inRun) then return end
	if st.phase == "running" and st.startV and not C.launched then
		C.launched = true
		a.TeleportTo(st.startV, st.yaw)
	end
	local pad = a.Pad and a.Pad()
	local buttons = pad and pad.buttons or 0
	local pressed = bit.band(buttons, bit.bnot(C.padPrev or 0))
	C.padPrev = buttons
	if st.phase == "guess" then C.GuessInput(pressed) end
end
hook.Add("Think", "skategm_ghostwriter", function() C.Think(RealTime()) end)

---------------------------------------------------------------------------
-- on screen
---------------------------------------------------------------------------
local FONTS = {
	skategm_gw_big = { "Coolvetica", 0.06, 500 },
	skategm_gw_mid = { "Coolvetica", 0.03, 500 },
	skategm_gw_small = { "Roboto", 0.018, 700 },
}
local BLUE, GOLD, GREY = Color(170, 200, 255), Color(255, 210, 90), Color(190, 190, 190)
local function Text(t, font, x, y, col, ax) SKATEGM_MODES.Text(t, font, x, y, col, ax or TEXT_ALIGN_CENTER, 1) end

function C.MyPick(st)
	local me = C.MyEnt()
	for _, pk in ipairs(st.reveal and st.reveal.picks or {}) do if pk.by == me then return pk end end
end

function C.NameOf(st, ent)
	for _, p in ipairs(st.players or {}) do if p.ent == ent then return p.name end end
end

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" or st.phase == "lobby" then return end
	local me = C.Me(st)
	if not (me and me.inRun) then return end
	GW.mode:Fonts(FONTS)
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
	local cx, line = w / 2, h * 0.035
	if st.phase == "countdown" then
		Text("SKATE YOUR RUN", "skategm_gw_mid", cx, h * 0.22, BLUE)
		Text(tostring(math.max(1, math.ceil(left))), "skategm_gw_big", cx, h * 0.22 + line * 1.2, color_white)
	elseif st.phase == "running" then
		Text(string.format("YOUR RUN   %.1f", math.max(0, left)), "skategm_gw_mid", cx, h * 0.04, BLUE)
		Text("nobody sees you now: they'll see the replay, with everyone looking the same", "skategm_gw_small", cx, h * 0.04 + line, GREY)
	elseif st.phase == "replay" and st.replay then
		Text(string.format("RUN %d / %d: WHO SKATED THIS?", st.replay.index, st.replay.total), "skategm_gw_mid", cx, h * 0.04, BLUE)
		if C.MyRun(st) then Text("(this one's yours: keep a straight face)", "skategm_gw_small", cx, h * 0.04 + line, GREY) end
		if C.missing then Text("(this run wasn't recorded here)", "skategm_gw_small", cx, h * 0.5, GREY) end
	elseif st.phase == "guess" then
		Text("WHOSE RUN WAS THAT?", "skategm_gw_big", cx, h * 0.12, BLUE)
		if C.MyRun(st) then
			Text("it was yours: wait for the others to guess", "skategm_gw_mid", cx, h * 0.12 + line * 2, GREY)
		else
			Text(string.format("%d s  -  D-pad up / down, A to guess (answers at the end)", math.ceil(math.max(0, left))), "skategm_gw_small", cx, h * 0.12 + line * 2, color_white)
			for i, p in ipairs(C.Choices(st)) do
				local picked = C.myGuess == p.ent
				Text(p.name .. (picked and "   <- your guess" or ""), "skategm_gw_mid", cx, h * 0.3 + (i - 1) * line * 1.5, i == C.sel and GOLD or (picked and BLUE or color_white))
			end
		end
	elseif st.phase == "reveal" and st.reveal then
		local r = st.reveal
		if r.index and r.total then Text(string.format("RUN %d / %d", r.index, r.total), "skategm_gw_small", cx, h * 0.12 - line, GREY) end
		Text("IT WAS " .. string.upper(r.name), "skategm_gw_big", cx, h * 0.12, GOLD)
		local mine = C.MyPick(st)
		if mine then
			Text(mine.target == r.ent and "you got it" or ("you said " .. (C.NameOf(st, mine.target) or "nobody")), "skategm_gw_mid", cx, h * 0.12 + line * 4.4, mine.target == r.ent and GOLD or Color(255, 120, 100))
		end
		Text(#r.right > 0 and ("got it: " .. table.concat(r.right, ", ")) or "nobody got it", "skategm_gw_mid", cx, h * 0.12 + line * 2, color_white)
		if (r.fooled or 0) > 0 then Text(string.format("%s fooled %d: +%d", r.name, r.fooled, r.fooled), "skategm_gw_small", cx, h * 0.12 + line * 3.2, GREY) end
	elseif st.phase == "results" and st.winners then
		local wn = st.winners.names or {}
		Text(#wn > 0 and (string.upper(table.concat(wn, " & ")) .. " WIN" .. (#wn == 1 and "S" or "")) or "NOBODY SCORED", "skategm_gw_big", cx, h * 0.12, GOLD)
	end
	local x, y = w * 0.98, h * 0.3
	for _, p in ipairs(C.Runners(st)) do
		Text(p.name .. (p.points and ("  " .. p.points) or "") .. (st.phase == "guess" and p.guessed and "  guessed" or ""), "skategm_gw_small", x, y, color_white, TEXT_ALIGN_RIGHT)
		y = y + line * 0.8
	end
end
hook.Add("HUDPaint", "skategm_ghostwriter", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

hook.Add("PostDrawTranslucentRenderables", "skategm_ghostwriter", function(depth, sky)
	local st = C.state
	if depth or sky or not st.startV or not (st.phase == "lobby" or st.phase == "countdown") then return end
	render.SetColorMaterial()
	render.DrawBox(st.startV, angle_zero, Vector(-2, -2, 0), Vector(2, 2, 64), Color(BLUE.r, BLUE.g, BLUE.b, 160))
end)

concommand.Add("skategm_ghostwriter_create", function(_, _, args)
	Send({ cmd = "create", runTime = tonumber(args[1]) or GW.RUN_DEFAULT, canSkate = CanSkate() })
end, nil, "Ghost Writer: open a game, the start where you stand [run seconds]")
C.Chat = GW.mode:ChatCommands({ create = "skategm_ghostwriter_create" }, "create [seconds], join, leave, start, stop")

GW.mode:LobbyLines(function(st) return { string.format("%d s runs; everyone looks the same in the replays", st.runTime or GW.RUN_DEFAULT) } end)
GW.mode:Host({
	description = "guess who did each line",
	about = "Everyone skates a line without anyone watching. Then the lines play back as ghosts with the names hidden. Guess who skated each one. You find out who was right at the end.",
	options = {
		{ key = "run", label = "Run time", type = "number", min = GW.RUN_MIN, max = GW.RUN_MAX, step = 5, default = GW.RUN_DEFAULT, format = function(v) return v .. " s" end },
	},
	start = function(v, mode) mode:Send({ cmd = "create", runTime = v.run, canSkate = CanSkate() }) end,
})
