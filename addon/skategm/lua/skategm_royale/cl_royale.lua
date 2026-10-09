-- Run Royale, client: follows the server's game, records every run as it
-- happens (everyone's poses already reach every player), replays them with a
-- chase camera, and runs the vote. Uses only SkateGM.API.
local C = { state = { phase = "idle" }, clips = {}, sel = 1, padPrev = 0 }
ROYALE.client = C

local API = SKATEGM_MODES.API
local function Send(t) ROYALE.mode:Send(t) end
C.Send = Send
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) ROYALE.mode:Say(text, bad) end
local Here = SKATEGM_MODES.Here

local PAD = { UP = 0x0001, DOWN = 0x0002, LEFT = 0x0004, RIGHT = 0x0008, A = 0x1000 }
C.PAD = PAD

function C.Me(st) return ROYALE.mode:Me(st) end
function C.IsHost(st) return ROYALE.mode:IsHost(st) end
function C.MyEnt() return LocalPlayer():EntIndex() end

function C.Runners(st)
	local list = {}
	for _, p in ipairs(st.players or {}) do if p.inMatch and not p.out then list[#list + 1] = p end end
	return list
end

-- who I can vote for: everyone still in but me
function C.Choices(st)
	local list = {}
	for _, p in ipairs(C.Runners(st)) do if p.ent ~= C.MyEnt() then list[#list + 1] = p end end
	return list
end

local HELD = { replays = true, voting = true, out = true }

---------------------------------------------------------------------------
-- recording every runner's poses while the round runs, and the camera
-- behind whoever we're watching
---------------------------------------------------------------------------
function C.StartRecording(st, now)
	local ents = {}
	for _, p in ipairs(C.Runners(st)) do ents[#ents + 1] = p.ent end
	SKATEGM_MODES.StartRecording(C, ents, now)
end

function C.Record(st, now)
	local done = {}
	for _, p in ipairs(st and st.players or {}) do if p.done then done[p.ent] = true end end
	local a = API()
	SKATEGM_MODES.RecordPoses(C, ROYALE.RECORD_RATE, now, function(ent) return done[ent] end,
		function(ent) return ent == C.MyEnt() and a and a.State and a.State() or nil end)
end

function C.Watch(target) SKATEGM_MODES.ChaseWatch(C, target, "royale_replay", 160, 64) end
function C.View(fov) return SKATEGM_MODES.ChaseView(C, fov, 160, 64) end

---------------------------------------------------------------------------
-- following the server
---------------------------------------------------------------------------
function C.Hold(on)
	local a = API()
	if not a then return end
	if on ~= C.held then
		C.held = on
		if a.Freeze then a.Freeze(on, "royale") end
	end
end

function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	st.startV = st.start and Vector(st.start[1], st.start[2], st.start[3]) or nil
	local me, a = C.Me(st), API()
	local running = st.phase == "countdown" or st.phase == "running"
	ROYALE.mode:NoCollide(me and running)
	if st.phase == "running" and prev.phase ~= "running" then
		C.StartRecording(st, now)
		C.goAt = now
		C.scoreStart = a and a.Score and a.Score() or 0
	end
	if prev.phase == "running" and st.phase ~= "running" then
		C.recStart = nil
		if me and me.inMatch and not me.out and a and a.Score then Send({ cmd = "score", score = a.Score() - (C.scoreStart or 0) }) end
	end
	local inMatch = me and me.inMatch
	-- watching: replays, and runs while I'm out
	local rp, prevRp = st.replay, prev.replay
	if st.phase == "replays" and rp and (not prevRp or prevRp.index ~= rp.index or prev.phase ~= "replays") then
		local ply = rp.ent == C.MyEnt() and LocalPlayer() or Entity(rp.ent)
		local clip = C.clips[rp.ent]
		local key = a and a.PlayClip and clip and #clip > 1 and a.PlayClip("royale", ply, clip) or nil
		C.replayMissing = key == nil
		C.Watch(key)
	elseif st.phase ~= "replays" and prev.phase == "replays" then
		if a and a.StopClip then a.StopClip("royale") end
		C.Watch(nil)
	end
	if st.phase == "voting" and prev.phase ~= "voting" then C.sel, C.myVote = 1, nil end
	if a and a.BlockInput and inMatch then
		local block = st.phase == "voting"
		if block ~= C.blocked then C.blocked = block a.BlockInput(block, "royale") end
	end
	if inMatch then C.Hold(HELD[st.phase] or (st.phase == "running" and (me.out or me.done)) or false) end
	-- while the runs are replayed (everyone's ghost moves, their real skater
	-- stands frozen) and while I'm out watching: my skater out of sight
	if a and a.SetHidden then a.SetHidden("royale", (inMatch and (st.phase == "replays" or (st.phase == "running" and me.out))) or false) end
	if st.phase == "running" and me and (me.out or me.done) and not C.watch then C.SpectateNext(0) end
	if st.phase ~= "running" then C.bailSent = nil end
	if st.phase ~= "running" and st.phase ~= "replays" and C.watch and not (st.phase == "replays") then C.Watch(nil) end
	if not me then C.switchedOn = nil return end
	if not C.switchedOn and a and not a.IsSkating() then
		C.switchedOn = true
		a.StartSkating()
	end
	if st.phase == "countdown" and prev.phase ~= "countdown" and not me.inMatch then
		Say("you weren't in Skater mode in time: this one's without you", true)
	end
end
-- (an infinite map: my frame moved a chunk over - the runs recorded here move
-- with it, so their replays play where they were skated)
function C.OnFrameShift(delta)
	for _, clip in pairs(C.clips) do
		for _, f in ipairs(clip) do
			for name, v in pairs(f.P or {}) do
				if SKATEGM_MODES.IsVec(v) then f.P[name] = v - delta end
			end
		end
	end
end

ROYALE.mode:OnState(function(st, now) C.OnState(st, now) end)
ROYALE.mode:OnFrameShift(function(delta) C.OnFrameShift(delta) end)

-- knocked out: watch the runners, D-pad left / right to switch
function C.SpectateNext(dir)
	local runners = {}
	for _, p in ipairs(C.Runners(C.state)) do if not p.done and p.ent ~= C.MyEnt() then runners[#runners + 1] = p end end
	if #runners == 0 then runners = C.Runners(C.state) end
	if #runners == 0 then return C.Watch(nil) end
	C.specIndex = ((C.specIndex or 1) - 1 + dir) % #runners + 1
	local ent = Entity(runners[C.specIndex].ent)
	if IsValid(ent) then C.Watch(ent) end
end

---------------------------------------------------------------------------
-- the vote
---------------------------------------------------------------------------
function C.Vote(target)
	C.myVote = target
	Send({ cmd = "vote", target = target })
end

function C.VoteInput(pressed)
	local choices = C.Choices(C.state)
	if #choices == 0 then return end
	C.sel = math.Clamp(C.sel or 1, 1, #choices)
	if bit.band(pressed, PAD.UP) ~= 0 then C.sel = (C.sel - 2) % #choices + 1 end
	if bit.band(pressed, PAD.DOWN) ~= 0 then C.sel = C.sel % #choices + 1 end
	if bit.band(pressed, PAD.A) ~= 0 then C.Vote(choices[C.sel].ent) end
end

function C.Think(now)
	local st, a = C.state, API()
	local me = C.Me(st)
	if st.phase == "running" then C.Record(st, now) end
	local runner = me ~= nil and me.inMatch and not me.out
	ROYALE.mode:HoldAtStart(runner and st.phase == "countdown", st.startV, st.yaw, now)
	if not me or not a or not me.inMatch then return end
	if st.phase == "running" and runner and st.startV and not C.launched then
		C.launched = true
		a.TeleportTo(st.startV, st.yaw)
	end
	if st.phase ~= "running" then C.launched = nil end
	if st.phase == "running" and runner and st.bailEnds and not me.done and not C.bailSent and C.launched then
		local state = a.State and a.State() or ""
		if state:find("Wipeout", 1, true) then
			C.bailSent = true
			Send({ cmd = "bailed", score = (a.Score and a.Score() or 0) - (C.scoreStart or 0) })
		end
	end
	local pad = a.Pad and a.Pad()
	local buttons = pad and pad.buttons or 0
	local pressed = bit.band(buttons, bit.bnot(C.padPrev or 0))
	C.padPrev = buttons
	if st.phase == "voting" then C.VoteInput(pressed)
	elseif st.phase == "running" and (me.out or me.done) then
		if bit.band(pressed, PAD.LEFT) ~= 0 then C.SpectateNext(-1) end
		if bit.band(pressed, PAD.RIGHT) ~= 0 then C.SpectateNext(1) end
	end
end
hook.Add("Think", "skategm_royale", function() C.Think(RealTime()) end)

---------------------------------------------------------------------------
-- in the world: the start (no play area: skate anywhere)
---------------------------------------------------------------------------
local GOLD = Color(255, 200, 70)
function C.DrawWorld()
	local st = C.state
	if st.phase == "idle" then return end
	render.SetColorMaterial()
	if st.startV and (st.phase == "lobby" or st.phase == "countdown") then
		render.DrawBox(st.startV, angle_zero, Vector(-2, -2, 0), Vector(2, 2, 64), Color(GOLD.r, GOLD.g, GOLD.b, 180))
	end
end
hook.Add("PostDrawTranslucentRenderables", "skategm_royale", function(depth, sky) if not (depth or sky) then C.DrawWorld() end end)

---------------------------------------------------------------------------
-- on screen
---------------------------------------------------------------------------
local FONTS = {
	skategm_royale_big = { "Roboto", 0.07, 900, 24 },
	skategm_royale_mid = { "Roboto", 0.03, 700, 16 },
	skategm_royale_small = { "Roboto", 0.02, 600, 12 },
}
local function Fonts() ROYALE.mode:Fonts(FONTS) end
local Text = SKATEGM_MODES.Text
local GREY, RED = Color(170, 170, 170), Color(255, 90, 70)

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" then return end
	Fonts()
	local me = C.Me(st)
	local since = now - (C.stateAt or now)
	local left = math.max(0, (st.timeLeft or 0) - since)
	if st.phase == "lobby" then
		return
	elseif st.phase == "countdown" then
		Text("ROUND " .. (st.round or 1), "skategm_royale_mid", w / 2, h * 0.22, GOLD)
		Text(tostring(math.max(1, math.ceil(left))), "skategm_royale_big", w / 2, h * 0.3, color_white)
	elseif st.phase == "running" then
		if C.goAt and now - C.goAt < 1.2 and me and not me.out then Text("SHOW US WHAT YOU'VE GOT!", "skategm_royale_big", w / 2, h * 0.3, GOLD) end
		Text(string.format("%.1f", left), "skategm_royale_mid", w / 2, h * 0.04, left <= 5 and RED or color_white)
		if me and (me.out or me.done) then
			local name = C.watch and C.watch.target and C.watch.target.Nick and C.watch.target:Nick() or "-"
			Text((me.out and "you're out" or "you bailed: run over") .. ": watching " .. name .. " (D-pad left / right)", "skategm_royale_small", w / 2, h * 0.9, GREY)
		end
	elseif st.phase == "replays" and st.replay then
		local rp = st.replay
		Text(string.format("REPLAY %d / %d", rp.index, rp.total), "skategm_royale_small", w / 2, h * 0.04, GREY)
		Text(string.upper(rp.name or "?"), "skategm_royale_big", w / 2, h * 0.07, GOLD)
		if rp.score then Text(string.format("%d points", rp.score), "skategm_royale_mid", w / 2, h * 0.07 + h * 0.08, color_white) end
		if C.replayMissing then Text("(this run wasn't recorded here)", "skategm_royale_small", w / 2, h * 0.5, GREY) end
	elseif st.phase == "voting" then
		Text("VOTE FOR THE WORST RUN", "skategm_royale_big", w / 2, h * 0.12, GOLD)
		Text(string.format("%d s  -  D-pad up / down, A to vote", math.ceil(left)), "skategm_royale_small", w / 2, h * 0.12 + h * 0.08, color_white)
		local choices = me and me.inMatch and C.Choices(st) or {}
		for i, p in ipairs(choices) do
			local picked = C.myVote == p.ent
			local label = string.format("%d. %s%s", i, p.name, picked and "   <- your vote" or "")
			Text(label, "skategm_royale_mid", w / 2, h * 0.3 + (i - 1) * h * 0.05, i == C.sel and GOLD or (picked and Color(120, 220, 255) or color_white))
		end
	elseif st.phase == "out" and st.knocked then
		Text(string.upper(st.knocked.name) .. " IS OUT", "skategm_royale_big", w / 2, h * 0.25, RED)
	elseif st.phase == "results" then
		Text(st.winner and (string.upper(st.winner.name) .. " WINS RUN ROYALE") or "NOBODY WON", "skategm_royale_big", w / 2, h * 0.12, GOLD)
	end
	local x, y = w - w * 0.02, h * 0.3
	for _, p in ipairs(st.players or {}) do
		if p.inMatch then
			local tag = p.out and "  out" or (st.phase == "voting" and (p.voted and "  voted" or "  ...") or "")
			Text(p.name .. tag, "skategm_royale_small", x, y, p.out and GREY or color_white, TEXT_ALIGN_RIGHT)
			y = y + h * 0.028
		end
	end
end
hook.Add("HUDPaint", "skategm_royale", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

---------------------------------------------------------------------------
-- console, chat and the spawn menu (Utilities > SkateGM > Game modes > Run Royale)
---------------------------------------------------------------------------
local cvRun = CreateClientConVar("skategm_royale_pref_run", tostring(ROYALE.RUN_DEFAULT), true, false, "Run Royale: seconds per run, in games you host", ROYALE.RUN_MIN, ROYALE.RUN_MAX)
local function Num(cv, default) local v = cv.GetInt and cv:GetInt() or tonumber(cv:GetString()) return v or default end

function C.Create(runTime, bailEnds)
	local p = Here()
	Send({ cmd = "create", pos = { p.x, p.y, p.z }, yaw = LocalPlayer():EyeAngles().y,
		runTime = runTime or Num(cvRun, ROYALE.RUN_DEFAULT), bailEnds = bailEnds ~= false, canSkate = CanSkate() })
end
function C.Settings(runTime) Send({ cmd = "settings", runTime = runTime or Num(cvRun, ROYALE.RUN_DEFAULT) }) end
function C.VoteNumber(n)
	local choices = C.Choices(C.state)
	local p = choices[tonumber(n) or 0]
	if not p then return Say("vote with the number next to their name", true) end
	C.sel = tonumber(n)
	C.Vote(p.ent)
end

concommand.Add("skategm_royale_create", function() C.Create() end, nil, "Run Royale: set up a game here (runs start here)")
concommand.Add("skategm_royale_join", function() Send({ cmd = "join", canSkate = CanSkate() }) end)
concommand.Add("skategm_royale_leave", function() Send({ cmd = "leave" }) end)
concommand.Add("skategm_royale_start", function() Send({ cmd = "begin" }) end)
concommand.Add("skategm_royale_stop", function() Send({ cmd = "stop" }) end)
concommand.Add("skategm_royale_run", function(_, _, args) C.Settings(tonumber(args[1])) end)
concommand.Add("skategm_royale_vote", function(_, _, args) C.VoteNumber(args[1]) end)

local CHAT = { create = "skategm_royale_create", join = "skategm_royale_join", leave = "skategm_royale_leave", start = "skategm_royale_start",
	stop = "skategm_royale_stop", run = "skategm_royale_run", vote = "skategm_royale_vote" }
C.Chat = ROYALE.mode:ChatCommands(CHAT, "create, join, leave, start, stop, run N, vote N")

ROYALE.mode:Host({
	description = "don't skate the worst run",
	about = "Everyone skates a run at the same time, then watches the replays. Everyone votes on the worst run, and that player is out. The last skater left wins.",
	options = {
		{ key = "run", label = "Run time", type = "number", min = ROYALE.RUN_MIN, max = ROYALE.RUN_MAX, step = 5, default = ROYALE.RUN_DEFAULT, format = function(v) return v .. " s" end },
		{ key = "bailEnds", label = "A bail ends your run", type = "bool", default = true },
	},
	start = function(v) C.Create(v.run, v.bailEnds) end,
})
