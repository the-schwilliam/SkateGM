-- Imposter, client: follows the server's game, skates your one line, watches
-- everyone else's, runs the vote and draws the screens. Uses only SkateGM.API.
local C = { state = { phase = "idle" }, sel = 1, padPrev = 0 }
IMPOSTER.client = C

local API = SKATEGM_MODES.API
local function Send(t) IMPOSTER.mode:Send(t) end
C.Send = Send
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) IMPOSTER.mode:Say(text, bad) end
local Commas = SKATEGM_MODES.Commas
local Clock = SKATEGM_MODES.Clock

local PAD = { UP = 0x0001, DOWN = 0x0002, A = 0x1000 }
local ACTIVE = { prep = true, countdown = true, turn = true, finish = true, between = true }
local SKATING = { turn = true, finish = true }

function C.Me(st) return IMPOSTER.mode:Me(st) end
function C.IsHost(st) return IMPOSTER.mode:IsHost(st) end
function C.MyEnt() return LocalPlayer():EntIndex() end
function C.IsMine(st) return st.active ~= nil and st.active ~= 0 and st.active == C.MyEnt() end
function C.NameOf(st, ent)
	for _, p in ipairs(st.players or {}) do if p.ent == ent then return p.name end end
	return "?"
end

function C.Choices(st)
	local list = {}
	for _, p in ipairs(st.players or {}) do if p.ent ~= C.MyEnt() then list[#list + 1] = p end end
	return list
end

---------------------------------------------------------------------------
-- my role (sent to me alone: the others' screens never hold it)
---------------------------------------------------------------------------
function C.SetRole(imposter, target)
	C.role = { imposter = imposter, target = (not imposter) and target or nil }
	if imposter then
		Say("you're the IMPOSTER: you don't know the score. Watch the others and blend in.")
	else
		Say(string.format("the score is %s: land a line as close to it as you can", Commas(target)))
	end
end
if net and net.Receive then
	net.Receive(IMPOSTER.NET_ROLE, function()
		local imposter = net.ReadBool()
		C.SetRole(imposter, net.ReadUInt(32))
	end)
end

---------------------------------------------------------------------------
-- following the server
---------------------------------------------------------------------------
C.JustDone = SKATEGM_MODES.JustDone

function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	st.spotV = st.spot and Vector(st.spot[1], st.spot[2], st.spot[3]) or nil
	local me, a = C.Me(st), API()
	local mine, wasMine = C.IsMine(st), C.IsMine(prev)
	local playing = me ~= nil and (ACTIVE[st.phase] or st.phase == "vote")
	if (st.phase == "lobby" or st.phase == "idle") and prev.phase ~= st.phase then C.role, C.askedRole = nil, nil end
	if playing and not C.role and not C.askedRole then
		C.askedRole = true
		Send({ cmd = "role" })
	end
	if a and a.SetHidden then a.SetHidden("imposter", (ACTIVE[st.phase] and me ~= nil and not mine and not C.JustDone(st)) or false) end
	IMPOSTER.mode:KeepApart(ACTIVE[st.phase] and me ~= nil)
	if st.phase == "prep" and mine and not (prev.phase == "prep" and wasMine) then
		C.prep = { teleported = false, readySent = false }
		if a then a.StartSkating() end
		Say("your turn: one line, make it count")
	end
	if st.phase == "turn" and mine and not (prev.phase == "turn" and wasMine) then
		if a and st.spotV then a.TeleportTo(st.spotV, st.yaw) end
		local info = a and a.ScoreInfo and a.ScoreInfo()
		C.line = { base = info and info.total or 0, sent = false, started = false }
	end
	if not (SKATING[st.phase] and mine) then C.line = nil end
	IMPOSTER.mode:Spectate((ACTIVE[st.phase] and me ~= nil and not mine and not C.JustDone(st)) and SKATEGM_MODES.Others(st) or nil, { prefer = st.active })
	if st.phase ~= prev.phase or st.active ~= prev.active then C.cam = nil end
	if st.phase == "vote" and prev.phase ~= "vote" then C.sel, C.myVote = 1, nil end
	if a and a.BlockInput and me then
		local block = st.phase == "vote"
		if block ~= C.blocked then C.blocked = block a.BlockInput(block, "imposter") end
	end
	if a and a.Freeze and me then
		local hold = st.phase == "vote"
		if hold ~= C.held then C.held = hold a.Freeze(hold, "imposter") end
	end
	if st.phase == "results" and prev.phase ~= "results" and st.result then
		local r = st.result
		Say(string.format("%s was the impostor, and %s. The score was %s.", r.imposterName or "?", r.crewWin and "got caught" or "got away with it", Commas(r.target or 0)))
	end
end
IMPOSTER.mode:OnState(function(st, now) C.OnState(st, now) end)

-- my line: it ends when it lands (the points are banked) or when I bail
function C.TrackLine(st, a)
	local L = C.line
	if not L or L.sent then return end
	local info = a.ScoreInfo and a.ScoreInfo()
	if not info then return end
	local state = a.State and a.State() or ""
	if (info.line or 0) > 0 then L.started = true end
	local banked = (info.total or 0) - L.base
	if banked > 0.5 then
		L.sent = true
		return Send({ cmd = "landed", score = math.floor(banked), how = "land" })
	end
	if state:find("Wipeout", 1, true) then
		L.sent = true
		return Send({ cmd = "landed", score = 0, how = "bail" })
	end
	if st.phase == "finish" and (info.line or 0) <= 0 then
		L.sent = true
		return Send({ cmd = "landed", score = 0, how = "none" })
	end
end

function C.VoteInput(pressed)
	local choices = C.Choices(C.state)
	if #choices == 0 then return end
	C.sel = math.Clamp(C.sel or 1, 1, #choices)
	if bit.band(pressed, PAD.UP) ~= 0 then C.sel = (C.sel - 2) % #choices + 1 end
	if bit.band(pressed, PAD.DOWN) ~= 0 then C.sel = C.sel % #choices + 1 end
	if bit.band(pressed, PAD.A) ~= 0 then
		C.myVote = choices[C.sel].ent
		Send({ cmd = "vote", target = C.myVote })
	end
end

function C.Think(now)
	local st, a = C.state, API()
	if not a or st.phase == "idle" then return end
	local me = C.Me(st)
	if not IMPOSTER.mode:TurnPrep(C, st, a, now, st.spotV, st.yaw) and SKATING[st.phase] and C.IsMine(st) then
		C.TrackLine(st, a)
	end
	local pad = a.Pad and a.Pad()
	local buttons = pad and pad.buttons or 0
	local pressed = bit.band(buttons, bit.bnot(C.padPrev or 0))
	C.padPrev = buttons
	if st.phase == "vote" and me then C.VoteInput(pressed) end
end
hook.Add("Think", "skategm_imposter", function() C.Think(RealTime()) end)

---------------------------------------------------------------------------
-- watching: a chase camera on whoever's skating
---------------------------------------------------------------------------
function C.View(now, skating)
	local st = C.state
	if not ACTIVE[st.phase] or C.IsMine(st) or not C.Me(st) then return nil end
	local a = API()
	if a and a.IsSkating() and not skating then return nil end
	local active = st.active and Entity(st.active)
	local P = a and IsValid(active) and a.PoseOf(active) or nil
	if P and P.HIPS then
		local target = P.HIPS + Vector(0, 0, 10)
		local cam = C.cam or {}
		if cam.last then
			local moved = target - cam.last
			moved.z = 0
			if moved:LengthSqr() > 0.25 then cam.dir = LerpVector(0.08, cam.dir or moved:GetNormalized(), moved:GetNormalized()) end
		end
		cam.last = target
		local dir = cam.dir or Angle(0, st.yaw or 0, 0):Forward()
		local want = target - dir:GetNormalized() * 130 + Vector(0, 0, 55)
		cam.pos = cam.pos and LerpVector(0.12, cam.pos, want) or want
		C.cam = cam
		return { origin = cam.pos, angles = (target - cam.pos):Angle(), drawviewer = false }
	elseif st.spotV then
		local d = Angle(0, (st.yaw or 0) + 180, 0):Forward()
		local pos = st.spotV - d * -160 + Vector(0, 0, 90)
		return { origin = pos, angles = (st.spotV - pos):Angle(), drawviewer = false }
	end
end

---------------------------------------------------------------------------
-- display
---------------------------------------------------------------------------
local FONTS = {
	skategm_imposter_big = { "Coolvetica", 0.06, 500 },
	skategm_imposter_mid = { "Coolvetica", 0.03, 500 },
	skategm_imposter_small = { "Roboto", 0.018, 700 },
}
local RED, GOLD, GREY, BLUE = Color(235, 85, 95), Color(255, 210, 90), Color(190, 190, 190), Color(120, 220, 255)
local function Text(t, font, x, y, col, ax) SKATEGM_MODES.Text(t, font, x, y, col, ax or TEXT_ALIGN_CENTER, 1) end

function C.RoleLine()
	local r = C.role
	if not r then return nil end
	if r.imposter then return "YOU'RE THE IMPOSTOR: copy the others", RED end
	return "THE SCORE: " .. Commas(r.target or 0) .. " in one line", GOLD
end

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" then return end
	IMPOSTER.mode:Fonts(FONTS)
	local me = C.Me(st)
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
	local cx, line = w / 2, h * 0.035
	if st.phase == "lobby" then
		return
	end
	if not me then return end
	local role, roleCol = C.RoleLine()
	if role and st.phase ~= "results" then Text(role, "skategm_imposter_small", cx, h * 0.87, roleCol) end
	local activeName = C.NameOf(st, st.active)
	if st.phase == "prep" then
		Text(activeName .. " is getting to the spot...", "skategm_imposter_mid", cx, h * 0.08, GREY)
	elseif st.phase == "countdown" then
		Text(C.IsMine(st) and "YOUR LINE" or (string.upper(activeName) .. "'S LINE"), "skategm_imposter_mid", cx, h * 0.08, GOLD)
		Text(tostring(math.max(1, math.ceil(left))), "skategm_imposter_big", cx, h * 0.08 + line * 1.3, color_white)
	elseif st.phase == "turn" or st.phase == "finish" then
		local who = C.IsMine(st) and "YOU" or string.upper(activeName)
		local clock = st.phase == "finish" and "land it!" or Clock(left)
		Text(who .. "   " .. clock, "skategm_imposter_mid", cx, h * 0.08, (st.phase == "finish" or left <= 5) and RED or color_white)
		Text(string.format("line %d of %d", st.index or 0, st.turns or 0), "skategm_imposter_small", cx, h * 0.08 + line, GREY)
		if not C.IsMine(st) then Text("watch closely...", "skategm_imposter_small", cx, h * 0.08 + line * 1.8, GREY) end
	elseif st.phase == "between" and st.last then
		Text(st.last.name .. " is done", "skategm_imposter_mid", cx, h * 0.08, GOLD)
	elseif st.phase == "vote" then
		Text("WHO'S THE IMPOSTOR?", "skategm_imposter_big", cx, h * 0.12, RED)
		Text(string.format("%d s  -  D-pad up / down, A to vote", math.ceil(math.max(0, left))), "skategm_imposter_small", cx, h * 0.12 + line * 2, color_white)
		for i, p in ipairs(C.Choices(st)) do
			local picked = C.myVote == p.ent
			Text(string.format("%s%s", p.name, picked and "   <- your vote" or ""), "skategm_imposter_mid", cx, h * 0.3 + (i - 1) * line * 1.5,
				i == C.sel and GOLD or (picked and BLUE or color_white))
		end
	elseif st.phase == "results" and st.result then
		local r = st.result
		Text(string.upper(r.imposterName or "?") .. " WAS THE IMPOSTOR", "skategm_imposter_big", cx, h * 0.1, RED)
		Text(r.crewWin and "caught! everyone else wins" or (r.out and (C.NameOf(st, r.out) .. " was voted out instead: the impostor wins") or "nobody was voted out: the impostor wins"),
			"skategm_imposter_mid", cx, h * 0.1 + line * 2, r.crewWin and GOLD or RED)
		Text("the score was " .. Commas(r.target or 0), "skategm_imposter_mid", cx, h * 0.1 + line * 3.4, color_white)
		local y = h * 0.1 + line * 5
		for _, l in ipairs(r.lines or {}) do
			local tag = l.imposter and "  (impostor)" or (l.name == r.closest and "  closest!" or "")
			local how = l.how == "landed" and Commas(l.score) or l.how
			Text(string.format("%s   %s%s", l.name, how, tag), "skategm_imposter_small", cx, y, l.imposter and RED or (l.name == r.closest and GOLD or color_white))
			y = y + line * 0.9
		end
	end
	if st.phase == "vote" then
		local x, y = w * 0.98, h * 0.3
		for _, p in ipairs(st.players or {}) do
			Text(p.name .. (p.voted and "  voted" or "  ..."), "skategm_imposter_small", x, y, p.voted and color_white or GREY, TEXT_ALIGN_RIGHT)
			y = y + line * 0.8
		end
	end
end
hook.Add("HUDPaint", "skategm_imposter", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

hook.Add("PostDrawTranslucentRenderables", "skategm_imposter", function(depth, sky)
	local st = C.state
	if depth or sky or st.phase == "idle" or not st.spotV then return end
	local p = st.spotV + Vector(0, 0, 1)
	local pulse = 0.6 + 0.4 * math.sin(RealTime() * 3)
	render.SetColorMaterial()
	render.DrawBox(p, angle_zero, Vector(-1, -1, 0), Vector(1, 1, 80), Color(RED.r, RED.g, RED.b, 140 * pulse))
end)

---------------------------------------------------------------------------
-- commands, chat and the host menu
---------------------------------------------------------------------------
concommand.Add("skategm_imposter_create", function(_, _, args)
	Send({ cmd = "create", turn = tonumber(args[1]) or IMPOSTER.TURN_DEFAULT, difficulty = args[2] or IMPOSTER.DIFFICULTY_DEFAULT, canSkate = CanSkate() })
end, nil, "Impostor: open a game at your spot [turn seconds] [easy|medium|hard]")
concommand.Add("skategm_imposter_vote", function(_, _, args)
	local p = C.Choices(C.state)[tonumber(args[1]) or 0]
	if not p then return Say("vote with the number of the player in the list", true) end
	C.myVote = p.ent
	Send({ cmd = "vote", target = p.ent })
end)
C.Chat = IMPOSTER.mode:ChatCommands({ create = "skategm_imposter_create", vote = "skategm_imposter_vote" }, "create [seconds] [easy|medium|hard], join, leave, start, stop, vote N")

local choices = {}
for _, d in ipairs(IMPOSTER.DIFFICULTIES) do choices[#choices + 1] = { d[1], d[2] } end
IMPOSTER.mode:Host({
	description = "vote out the faker",
	about = "Everyone is secretly told a score to hit, except one player who has to fake it. Take turns skating one line each, then vote on who you think the impostor is.",
	options = {
		{ key = "turn", label = "Time for a line", type = "number", min = IMPOSTER.TURN_MIN, max = IMPOSTER.TURN_MAX, step = 10, default = IMPOSTER.TURN_DEFAULT, format = function(v) return v .. " s" end },
		{ key = "difficulty", label = "Score", type = "choice", choices = choices, default = IMPOSTER.DIFFICULTY_DEFAULT },
		{ key = "imposterFirst", label = "Impostor can go first", type = "bool", default = false },
	},
	start = function(v, mode)
		mode:Send({ cmd = "create", turn = v.turn, difficulty = v.difficulty, imposterFirst = v.imposterFirst, canSkate = CanSkate() })
	end,
})
