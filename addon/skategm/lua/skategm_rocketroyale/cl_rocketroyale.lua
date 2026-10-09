-- Rocket Royale, client: lines everyone up, lets the forced rocket do the
-- rest (the board rules: SKATEGM_MODES.RocketForced), tells the server when I
-- bail, and watches the others once I'm out.
local RR = ROCKETROYALE
local C = { state = { phase = "idle" } }
RR.client = C

local API = SKATEGM_MODES.API
local function Send(t) RR.mode:Send(t) end
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) RR.mode:Say(text, bad) end
local Clock = SKATEGM_MODES.Clock

function C.Me(st) return RR.mode:Me(st) end

function C.SlotPos(st, me)
	if not (st.startV and me and me.slot) then return st.startV end
	local dx, dy = RR.SlotOffset(me.slot, st.slots or 1, st.yaw)
	local p = st.startV + Vector(dx, dy, 0)
	local ground = SKATEGM_MODES.Ground and SKATEGM_MODES.Ground(p.x, p.y, st.startV.z)
	return ground and Vector(p.x, p.y, ground + 6) or p
end

function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	st.startV = st.start and Vector(st.start[1], st.start[2], st.start[3]) or nil
	local me, a = C.Me(st), API()
	local out = (me and me.playing and me.out and st.phase == "playing") or false
	if a and a.SetHidden then a.SetHidden("rocketroyale", out) end
	RR.mode:Spectate(out and SKATEGM_MODES.Others(st, function(p) return p.playing and not p.out end) or nil)
	if me and st.phase ~= "idle" and a and not a.IsSkating() and not a.IsLoading() and CanSkate() and not C.asked then
		C.asked = true
		a.StartSkating()
	end
	if not me then C.asked = nil end
	if st.phase == "countdown" and prev.phase ~= "countdown" then C.launched, C.bailSent, C.slot = nil, nil, C.SlotPos(st, me) end
	if st.phase == "results" and prev.phase ~= "results" and st.winners then
		Say(#st.winners == 1 and (st.winners[1] .. " wins!") or (#st.winners > 1 and (table.concat(st.winners, ", ") .. " rode it out") or "nobody's left"))
	end
end
RR.mode:OnState(function(st, now) C.OnState(st, now) end)

function C.Think(now)
	local st, a = C.state, API()
	local me = C.Me(st)
	local riding = me ~= nil and me.playing and not me.out
	RR.mode:HoldAtStart(riding and st.phase == "countdown", C.slot or st.startV, st.yaw, now)
	if not (a and riding) then return end
	if st.phase == "playing" and not C.launched and (C.slot or st.startV) then
		C.launched = true
		a.TeleportTo(C.slot or st.startV, st.yaw)
	end
	if st.phase == "playing" and C.launched and not C.bailSent then
		local state = a.State and a.State() or ""
		if state:find("Wipeout", 1, true) then
			C.bailSent = true
			Send({ cmd = "bailed" })
		end
	end
end
hook.Add("Think", "skategm_rocketroyale", function() C.Think(RealTime()) end)

local FONTS = {
	skategm_rr_big = { "Coolvetica", 0.06, 500 },
	skategm_rr_mid = { "Coolvetica", 0.03, 500 },
	skategm_rr_small = { "Roboto", 0.018, 700 },
}
local ORANGE, GREY = Color(255, 140, 50), Color(190, 190, 190)
local function Text(t, font, x, y, col, ax) SKATEGM_MODES.Text(t, font, x, y, col, ax or TEXT_ALIGN_CENTER, 1) end

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" or st.phase == "lobby" then return end
	local me = C.Me(st)
	if not me then return end
	RR.mode:Fonts(FONTS)
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
	local line = h * 0.035
	local riding = 0
	for _, p in ipairs(st.players or {}) do if p.playing and not p.out then riding = riding + 1 end end
	if st.phase == "countdown" then
		Text("ROCKETS ON IN", "skategm_rr_mid", w / 2, h * 0.22, ORANGE)
		Text(tostring(math.max(1, math.ceil(left))), "skategm_rr_big", w / 2, h * 0.22 + line * 1.2, color_white)
	elseif st.phase == "playing" then
		Text(string.format("ROCKET ROYALE   %s   %d riding", Clock(left), riding), "skategm_rr_mid", w / 2, h * 0.04, ORANGE)
	elseif st.phase == "results" then
		local wn = st.winners or {}
		Text(#wn == 1 and (string.upper(wn[1]) .. " WINS") or (#wn > 1 and "RODE IT OUT: " .. string.upper(table.concat(wn, ", ")) or "NOBODY WON"), "skategm_rr_big", w / 2, h * 0.12, ORANGE)
	end
	local x, y = w * 0.98, h * 0.3
	for _, p in ipairs(st.players or {}) do
		if p.playing then
			Text(p.name .. (p.out and string.format("  out (%.1f s)", p.lasted or 0) or ""), "skategm_rr_small", x, y, p.out and GREY or color_white, TEXT_ALIGN_RIGHT)
			y = y + line * 0.8
		end
	end
end
hook.Add("HUDPaint", "skategm_rocketroyale", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

concommand.Add("skategm_rocketroyale_create", function(_, _, args)
	Send({ cmd = "create", time = tonumber(args[1]) or RR.TIME_DEFAULT, canSkate = CanSkate() })
end, nil, "Rocket Royale: open a game, the start line where you stand [time limit seconds]")
C.Chat = RR.mode:ChatCommands({ create = "skategm_rocketroyale_create" }, "create [seconds], join, leave, start, stop")

RR.mode:LobbyLines(function(st) return { "time limit " .. Clock(st.time or RR.TIME_DEFAULT) } end)
RR.mode:Host({
	description = "last one riding a rocket wins",
	about = "Everyone is equipped with a rocket board, and you can't turn it off. The last one not to bail wins.",
	rocket = "force",
	options = {
		{ key = "time", label = "Time limit", type = "number", min = RR.TIME_MIN, max = RR.TIME_MAX, step = 30, default = RR.TIME_DEFAULT, format = function(v) return v .. " s" end },
	},
	start = function(v, mode)
		mode:Send({ cmd = "create", time = v.time, canSkate = CanSkate() })
	end,
})
