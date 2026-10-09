-- S.K.A.T.E., client: follows the server's game, skates your go (the tricks
-- of the line you land are sent), watches everyone else's, draws the letters.
local C = { state = { phase = "idle" } }
SKATE.client = C

local API = SKATEGM_MODES.API
local function Send(t) SKATE.mode:Send(t) end
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) SKATE.mode:Say(text, bad) end
local Clock = SKATEGM_MODES.Clock

local ACTIVE = { prep = true, countdown = true, attempt = true, finish = true, between = true }
local SKATING = { attempt = true, finish = true }

function C.Me(st) return SKATE.mode:Me(st) end
function C.MyEnt() return LocalPlayer():EntIndex() end
function C.IsMine(st) return st.active ~= nil and st.active ~= 0 and st.active == C.MyEnt() end
function C.NameOf(st, ent)
	for _, p in ipairs(st.players or {}) do if p.ent == ent then return p.name end end
	return "?"
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
	if a and a.SetHidden then a.SetHidden("skate", (ACTIVE[st.phase] and me ~= nil and not mine and not C.JustDone(st)) or false) end
	SKATE.mode:KeepApart(ACTIVE[st.phase] and me ~= nil)
	if st.phase == "prep" and mine and not (prev.phase == "prep" and wasMine) then
		C.prep = { teleported = false, readySent = false }
		if a then a.StartSkating() end
		Say(st.set and ("your go: match " .. table.concat(st.set, " + ")) or "your go: set a trick")
	end
	if st.phase == "attempt" and mine and not (prev.phase == "attempt" and wasMine) then
		if a and st.spotV then a.TeleportTo(st.spotV, st.yaw) end
		local info = a and a.ScoreInfo and a.ScoreInfo()
		C.go = { base = info and info.total or 0, trickT = info and info.trickT, tricks = {}, sent = false }
	end
	if not (SKATING[st.phase] and mine) then C.go = nil end
	SKATE.mode:Spectate((ACTIVE[st.phase] and me ~= nil and not mine and not C.JustDone(st)) and SKATEGM_MODES.Others(st, function(p) return not p.out end) or nil, { prefer = st.active })
	if st.phase == "results" and prev.phase ~= "results" and st.winner then Say(st.winner.name .. " wins!") end
end
SKATE.mode:OnState(function(st, now) C.OnState(st, now) end)

-- my go: collect the tricks of the line; it ends when it lands or I bail
function C.Track(st, a)
	local G = C.go
	if not G or G.sent then return end
	local info = a.ScoreInfo and a.ScoreInfo()
	if not info then return end
	if info.trickT and info.trickT ~= G.trickT then
		G.trickT = info.trickT
		if info.trick and info.trick ~= "" then G.tricks[#G.tricks + 1] = info.trick end
	end
	local state = a.State and a.State() or ""
	if (info.total or 0) - G.base > 0.5 then
		G.sent = true
		return Send({ cmd = "attempt", landed = true, tricks = SKATE.Clean(G.tricks) })
	end
	if state:find("Wipeout", 1, true) or (st.phase == "finish" and (info.line or 0) <= 0) then
		G.sent = true
		return Send({ cmd = "attempt", landed = false, tricks = {} })
	end
end

function C.Think(now)
	local st, a = C.state, API()
	if not a or st.phase == "idle" then return end
	if not SKATE.mode:TurnPrep(C, st, a, now, st.spotV, st.yaw) and SKATING[st.phase] and C.IsMine(st) then
		C.Track(st, a)
	end
end
hook.Add("Think", "skategm_skate", function() C.Think(RealTime()) end)

---------------------------------------------------------------------------
-- display
---------------------------------------------------------------------------
local FONTS = {
	skategm_skate_big = { "Coolvetica", 0.06, 500 },
	skategm_skate_mid = { "Coolvetica", 0.03, 500 },
	skategm_skate_small = { "Roboto", 0.018, 700 },
}
local BLUE, GOLD, GREY, RED = Color(120, 200, 255), Color(255, 210, 90), Color(190, 190, 190), Color(235, 85, 95)
local function Text(t, font, x, y, col, ax) SKATEGM_MODES.Text(t, font, x, y, col, ax or TEXT_ALIGN_CENTER, 1) end

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" or st.phase == "lobby" then return end
	local me = C.Me(st)
	if not me then return end
	SKATE.mode:Fonts(FONTS)
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
	local cx, line = w / 2, h * 0.035
	local who = C.IsMine(st) and "YOU" or string.upper(C.NameOf(st, st.active))
	local job = st.set and ("MATCH: " .. table.concat(st.set, " + ")) or "SET A TRICK"
	if st.phase == "prep" then
		Text(C.NameOf(st, st.active) .. " is getting to the spot...", "skategm_skate_mid", cx, h * 0.08, GREY)
	elseif st.phase == "countdown" then
		Text(who .. ": " .. job, "skategm_skate_mid", cx, h * 0.08, GOLD)
		Text(tostring(math.max(1, math.ceil(left))), "skategm_skate_big", cx, h * 0.08 + line * 1.3, color_white)
	elseif SKATING[st.phase] then
		Text(who .. ": " .. job, "skategm_skate_mid", cx, h * 0.08, GOLD)
		Text(st.phase == "finish" and "land it!" or Clock(left), "skategm_skate_small", cx, h * 0.08 + line, (st.phase == "finish" or left <= 5) and RED or color_white)
	elseif st.phase == "between" and st.last then
		local l = st.last
		local text = l.how == "set" and (l.name .. " set " .. table.concat(l.set or {}, " + "))
			or l.how == "matched" and (l.name .. " matched it")
			or l.how == "missed" and (l.name .. " missed: " .. (l.letters or "") .. (l.out and " - out!" or ""))
			or l.how == "missed the set" and (l.name .. " didn't land a set: the next one sets")
			or (l.name .. " " .. (l.how or ""))
		Text(text, "skategm_skate_mid", cx, h * 0.08, l.how == "missed" and RED or GOLD)
	elseif st.phase == "results" then
		Text(st.winner and (string.upper(st.winner.name) .. " WINS S.K.A.T.E.") or "NOBODY WON", "skategm_skate_big", cx, h * 0.12, BLUE)
	end
	local x, y = w * 0.98, h * 0.3
	for _, p in ipairs(st.players or {}) do
		local letters = SKATE.Letters(p.letters)
		Text(string.format("%s  %s", p.name, p.out and "OUT" or (letters ~= "" and letters or "-")), "skategm_skate_small", x, y,
			p.out and GREY or (p.ent == st.setter and GOLD or color_white), TEXT_ALIGN_RIGHT)
		y = y + line * 0.8
	end
end
hook.Add("HUDPaint", "skategm_skate", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

hook.Add("PostDrawTranslucentRenderables", "skategm_skate", function(depth, sky)
	local st = C.state
	if depth or sky or st.phase == "idle" or not st.spotV then return end
	local pulse = 0.6 + 0.4 * math.sin(RealTime() * 3)
	render.SetColorMaterial()
	render.DrawBox(st.spotV + Vector(0, 0, 1), angle_zero, Vector(-1, -1, 0), Vector(1, 1, 80), Color(BLUE.r, BLUE.g, BLUE.b, 140 * pulse))
end)

---------------------------------------------------------------------------
-- commands, chat and the host menu
---------------------------------------------------------------------------
concommand.Add("skategm_skate_create", function(_, _, args)
	Send({ cmd = "create", time = tonumber(args[1]) or SKATE.TIME_DEFAULT, canSkate = CanSkate() })
end, nil, "S.K.A.T.E.: open a game at your spot [seconds for a go]")
C.Chat = SKATE.mode:ChatCommands({ create = "skategm_skate_create" }, "create [seconds], join, leave, start, stop")

SKATE.mode:LobbyLines(function(st) return { string.format("%d s a go", st.time or SKATE.TIME_DEFAULT) } end)
SKATE.mode:Host({
	description = "land the tricks the others set",
	about = "One player lands a line of tricks, and everyone else has to land a line with all of the same tricks in it. Miss and you get a letter. Spell S.K.A.T.E. and you're out. The last player left wins.",
	options = {
		{ key = "time", label = "Time for a go", type = "number", min = SKATE.TIME_MIN, max = SKATE.TIME_MAX, step = 5, default = SKATE.TIME_DEFAULT, format = function(v) return v .. " s" end },
	},
	start = function(v, mode)
		mode:Send({ cmd = "create", time = v.time, canSkate = CanSkate() })
	end,
})
