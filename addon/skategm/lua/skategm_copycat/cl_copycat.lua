-- Copycat, client: the setter watched live, the copies skated out of each
-- other's sight (every client records every run: poses reach every player),
-- each copy played back beside the setter (a name tag over them).
local CC = COPYCAT
local C = { state = { phase = "idle" }, clips = {} }
CC.client = C

local API = SKATEGM_MODES.API
local function Send(t) CC.mode:Send(t) end
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) CC.mode:Say(text, bad) end
local SHOWING = { replay = true, score = true }
local RUNNING = { leadcount = true, lead = true, copycount = true, copy = true }
local TEAL, GOLD, GREY, GHOST = Color(120, 220, 200), Color(255, 210, 90), Color(190, 190, 190), Color(255, 255, 255)

function C.Me(st) return CC.mode:Me(st) end
function C.MyEnt() return LocalPlayer():EntIndex() end
function C.IsLeader(st) return st.leader ~= nil and st.leader == C.MyEnt() end
function C.IsCopier(st)
	for _, e in ipairs(st.copiers or {}) do if e == C.MyEnt() then return true end end
	return false
end
function C.NameOf(st, ent)
	for _, p in ipairs(st.players or {}) do if p.ent == ent then return p.name end end
	return "?"
end
function C.PlayerFor(ent) return ent == C.MyEnt() and LocalPlayer() or Entity(ent) end

---------------------------------------------------------------------------
-- recording, and the replay camera behind the copy
---------------------------------------------------------------------------
function C.StartRecording(ents, now) SKATEGM_MODES.StartRecording(C, ents, now, true) end
function C.Record(now) SKATEGM_MODES.RecordPoses(C, CC.RECORD_RATE, now) end

function C.Watch(target) SKATEGM_MODES.ChaseWatch(C, target, "copycat_replay", 170, 70, true) end
function C.View(fov) return SKATEGM_MODES.ChaseView(C, fov, 170, 70, true) end

function C.StopClips()
	local a = API()
	if a and a.StopClip then
		a.StopClip("copycat_lead")
		a.StopClip("copycat_copy")
	end
	C.Watch(nil)
end

function C.PlayReplay(st)
	local a = API()
	if not (a and a.PlayClip and st.replay) then return end
	C.StopClips()
	local lead, copy = C.clips[st.leader], C.clips[st.replay.ent]
	local lp, cp = C.PlayerFor(st.leader), C.PlayerFor(st.replay.ent)
	local ghost = IsValid(lp) and lead and #lead > 1 and a.PlayClip("copycat_lead", lp, lead, { nametag = lp:Nick() }) or nil
	local key = IsValid(cp) and copy and #copy > 1 and a.PlayClip("copycat_copy", cp, copy) or nil
	C.missing = key == nil
	C.Watch(key or ghost)
end

---------------------------------------------------------------------------
-- following the server
---------------------------------------------------------------------------
function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	st.startV = st.start and Vector(st.start[1], st.start[2], st.start[3]) or nil
	local me, a = C.Me(st), API()
	local playing = me ~= nil and me.playing
	if me and st.phase ~= "idle" and a and not a.IsSkating() and not a.IsLoading() and CanSkate() and not C.asked then
		C.asked = true
		a.StartSkating()
	end
	if not me then C.asked = nil end
	local leader, copier = C.IsLeader(st), C.IsCopier(st)
	-- (nobody touches anybody in Copycat; and only who I watch is drawn, so
	-- the others don't show for a moment while their hidden flag arrives)
	CC.mode:KeepApart(RUNNING[st.phase] and playing)
	if st.phase == "lead" and prev.phase ~= "lead" then C.StartRecording({ st.leader }, now) C.launched = nil end
	if st.phase == "copy" and prev.phase ~= "copy" then C.StartRecording(st.copiers or {}, now) C.launched = nil end
	if (prev.phase == "lead" and st.phase ~= "lead") or (prev.phase == "copy" and st.phase ~= "copy") then C.recStart = nil end
	local watchLive
	if playing and (st.phase == "leadcount" or st.phase == "lead") and not leader then watchLive = { st.leader } end
	if playing and (st.phase == "copycount" or st.phase == "copy") and leader then watchLive = SKATEGM_MODES.Others(st, function(p) return p.playing end) end
	-- (the replays end before the live watching starts: ending them hands the
	-- camera back, which mustn't take it from the spectator)
	local rp, prevRp = st.replay, prev.replay
	if not SHOWING[st.phase] and SHOWING[prev.phase] then C.StopClips() end
	CC.mode:Spectate(watchLive)
	if st.phase == "replay" and rp and (prev.phase ~= "replay" or not prevRp or prevRp.index ~= rp.index or prev.leader ~= st.leader) then C.PlayReplay(st) end
	local hold = (playing and SHOWING[st.phase]) or false
	if a and hold ~= (C.held or false) then
		C.held = hold
		if a.Freeze then a.Freeze(hold, "copycat") end
		if a.BlockInput then a.BlockInput(hold, "copycat") end
		if a.SetHidden then a.SetHidden("copycat", hold) end
	end
	if st.phase == "score" and prev.phase ~= "score" and st.last and surface and surface.PlaySound then
		surface.PlaySound(st.last.points >= 70 and "garrysmod/save_load4.wav" or "buttons/button14.wav")
	end
end
CC.mode:OnState(function(st, now) C.OnState(st, now) end)

function C.Think(now)
	local st, a = C.state, API()
	if st.phase == "lead" or st.phase == "copy" then C.Record(now) end
	local me = C.Me(st)
	if not (a and me and me.playing) then return end
	local mine = (C.IsLeader(st) and (st.phase == "leadcount" or st.phase == "lead")) or (C.IsCopier(st) and (st.phase == "copycount" or st.phase == "copy"))
	CC.mode:HoldAtStart(mine and (st.phase == "leadcount" or st.phase == "copycount"), st.startV, st.yaw, now)
	if mine and (st.phase == "lead" or st.phase == "copy") and st.startV and not C.launched then
		C.launched, C.goAt, C.wipeSince, C.bailSent = true, now, nil, nil
		a.TeleportTo(st.startV, st.yaw)
	end
	-- the setter bails: their line ends there (a quarter second in the
	-- wipeout, not in the first second, when the start teleport can read as one)
	if C.IsLeader(st) and st.phase == "lead" and not C.bailSent then
		local state = a.State and a.State() or ""
		if state:find("Wipeout", 1, true) then C.wipeSince = C.wipeSince or now else C.wipeSince = nil end
		if C.wipeSince and now - C.wipeSince >= CC.BAIL_HOLD and now - (C.goAt or now) >= CC.BAIL_GRACE then
			C.bailSent = true
			Send({ cmd = "bailed" })
		end
	end
end
hook.Add("Think", "skategm_copycat", function() C.Think(RealTime()) end)

---------------------------------------------------------------------------
-- the two lines on the ground during the replay
---------------------------------------------------------------------------
function C.DrawPath(path, col)
	for i = 1, #path - 1 do
		local a, b = path[i], path[i + 1]
		render.DrawBeam(Vector(a[1], a[2], a[3] - 30), Vector(b[1], b[2], b[3] - 30), 2, 0, 1, col)
	end
end

hook.Add("PostDrawTranslucentRenderables", "skategm_copycat", function(depth, sky)
	if depth or sky then return end
	local st = C.state
	if SHOWING[st.phase] and st.paths and C.Me(st) then
		render.SetColorMaterial()
		C.DrawPath(st.paths.lead or {}, Color(GHOST.r, GHOST.g, GHOST.b, 200))
		C.DrawPath(st.paths.copy or {}, Color(TEAL.r, TEAL.g, TEAL.b, 255))
	elseif st.startV and (st.phase == "lobby" or st.phase == "leadcount" or st.phase == "copycount") then
		render.SetColorMaterial()
		render.DrawBox(st.startV, angle_zero, Vector(-2, -2, 0), Vector(2, 2, 64), Color(TEAL.r, TEAL.g, TEAL.b, 160))
	end
end)

---------------------------------------------------------------------------
-- on screen
---------------------------------------------------------------------------
local FONTS = {
	skategm_cc_big = { "Coolvetica", 0.06, 500 },
	skategm_cc_mid = { "Coolvetica", 0.03, 500 },
	skategm_cc_small = { "Roboto", 0.018, 700 },
}
local function Text(t, font, x, y, col, ax) SKATEGM_MODES.Text(t, font, x, y, col, ax or TEXT_ALIGN_CENTER, 1) end

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" or st.phase == "lobby" then return end
	local me = C.Me(st)
	if not (me and me.playing) then return end
	CC.mode:Fonts(FONTS)
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
	local cx, line = w / 2, h * 0.035
	local setter = C.NameOf(st, st.leader)
	local round = st.round and string.format("line %d / %d", st.round.index, st.round.total) or ""
	if st.phase == "leadcount" then
		Text(C.IsLeader(st) and "SET THE LINE" or (string.upper(setter) .. " SETS THE LINE"), "skategm_cc_mid", cx, h * 0.22, TEAL)
		Text(tostring(math.max(1, math.ceil(left))), "skategm_cc_big", cx, h * 0.22 + line * 1.2, color_white)
		Text(round, "skategm_cc_small", cx, h * 0.22 + line * 3, GREY)
	elseif st.phase == "lead" then
		Text(string.format("%s   %.1f", C.IsLeader(st) and "SET THE LINE" or ("WATCH " .. string.upper(setter)), math.max(0, left)), "skategm_cc_mid", cx, h * 0.04, TEAL)
		Text(C.IsLeader(st) and "everyone's watching: make it hard to copy" or "you'll have to skate the same line", "skategm_cc_small", cx, h * 0.04 + line, GREY)
	elseif st.phase == "copycount" then
		Text(C.IsLeader(st) and "THEY'RE COPYING YOU" or "COPY " .. string.upper(setter) .. "'S LINE", "skategm_cc_mid", cx, h * 0.22, TEAL)
		Text(tostring(math.max(1, math.ceil(left))), "skategm_cc_big", cx, h * 0.22 + line * 1.2, color_white)
	elseif st.phase == "copy" then
		Text(string.format("%s   %.1f", C.IsLeader(st) and "THEY'RE COPYING YOU" or "COPY IT", math.max(0, left)), "skategm_cc_mid", cx, h * 0.04, TEAL)
		if not C.IsLeader(st) then Text("everyone's skating at once, out of sight", "skategm_cc_small", cx, h * 0.04 + line, GREY) end
	elseif st.phase == "replay" and st.replay then
		Text(string.format("%s COPYING %s   (%d / %d)", string.upper(C.NameOf(st, st.replay.ent)), string.upper(setter), st.replay.index, st.replay.total), "skategm_cc_mid", cx, h * 0.04, TEAL)
		Text("the one with the name tag is the setter, " .. setter, "skategm_cc_small", cx, h * 0.04 + line, GREY)
		if C.missing then Text("(this run wasn't recorded here)", "skategm_cc_small", cx, h * 0.5, GREY) end
	elseif st.phase == "score" and st.last then
		Text(string.format("%s: %d%% MATCH", string.upper(st.last.name), st.last.points), "skategm_cc_big", cx, h * 0.12, st.last.points >= 70 and GOLD or color_white)
		Text("+" .. st.last.points .. " points", "skategm_cc_mid", cx, h * 0.12 + line * 2, GREY)
	elseif st.phase == "results" and st.winners then
		local wn = st.winners.names or {}
		Text(#wn > 0 and (string.upper(table.concat(wn, " & ")) .. " WIN" .. (#wn == 1 and "S" or "")) or "NOBODY SCORED", "skategm_cc_big", cx, h * 0.12, GOLD)
		Text((st.winners.points or 0) .. " points", "skategm_cc_mid", cx, h * 0.12 + line * 2, color_white)
	end
	local rows = {}
	for _, p in ipairs(st.players or {}) do if p.playing then rows[#rows + 1] = p end end
	table.sort(rows, function(x, y) return (x.points or 0) > (y.points or 0) end)
	local x, y = w * 0.98, h * 0.3
	for _, p in ipairs(rows) do
		Text(string.format("%s  %d", p.name, p.points or 0), "skategm_cc_small", x, y, p.ent == st.leader and TEAL or color_white, TEXT_ALIGN_RIGHT)
		y = y + line * 0.8
	end
end
hook.Add("HUDPaint", "skategm_copycat", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

---------------------------------------------------------------------------
-- host menu
---------------------------------------------------------------------------
local judging = {}
for _, j in ipairs(CC.JUDGING) do judging[#judging + 1] = { j[1], j[2] } end
local function JudgingName(v) for _, j in ipairs(CC.JUDGING) do if j[1] == v then return j[2] end end return "Normal" end
CC.mode:LobbyLines(function(st)
	return { string.format("%d s lines, %s judging", st.runTime or CC.RUN_DEFAULT, string.lower(JudgingName(st.judging or CC.JUDGING_DEFAULT))),
		"everyone sets a line once; the others copy it unseen" }
end)
CC.mode:Host({
	description = "copy another player's line",
	about = "One player skates a line while everyone watches. Then everyone else tries to copy it, all at the same time. The replays show how close each copy was, and the closest copy gets the most points.",
	options = {
		{ key = "run", label = "Line length", type = "number", min = CC.RUN_MIN, max = CC.RUN_MAX, step = 5, default = CC.RUN_DEFAULT, format = function(v) return v .. " s" end },
		{ key = "judging", label = "Judging", type = "choice", choices = judging, default = CC.JUDGING_DEFAULT },
	},
	start = function(v, mode) mode:Send({ cmd = "create", runTime = v.run, judging = v.judging, canSkate = CanSkate() }) end,
})
