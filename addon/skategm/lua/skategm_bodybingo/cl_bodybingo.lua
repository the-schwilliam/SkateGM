-- Body Bingo, client: Hall of Meat's injury tracker on my own skater (a new
-- one for every bail), each injury told to the server, the card.
local BB = BODYBINGO
local C = { state = { phase = "idle" }, popups = {} }
BB.client = C

local API = SKATEGM_MODES.API
local function Send(t) BB.mode:Send(t) end
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) BB.mode:Say(text, bad) end
local Clock = SKATEGM_MODES.Clock
local RED, GREY, GOLD, GREEN = Color(255, 90, 90), Color(190, 190, 190), Color(255, 210, 90), Color(110, 230, 120)

function C.Me(st) return BB.mode:Me(st) end

local function GroundBelow(p)
	if not (util and util.TraceLine) then return nil end
	local tr = util.TraceLine({ start = p, endpos = p - Vector(0, 0, 400), mask = MASK_SOLID_BRUSHONLY })
	return tr.Hit and (p.z - tr.HitPos.z) or 400
end

function C.MyMarks(st)
	local me = C.Me(st)
	local marks = {}
	for _, i in ipairs(me and me.marks or {}) do marks[i] = true end
	return marks
end

function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	local me, a = C.Me(st), API()
	if me and st.phase ~= "idle" and a and not a.IsSkating() and not a.IsLoading() and CanSkate() and not C.asked then
		C.asked = true
		a.StartSkating()
	end
	if not me then C.asked = nil end
	if st.phase == "playing" and prev.phase ~= "playing" then C.tracker = HOM and HOM.NewTracker(st.pain) or nil end
	if st.phase ~= "playing" then C.tracker = nil end
	local before = C.MyMarks(prev)
	for i in pairs(C.MyMarks(st)) do
		if not before[i] and st.card and st.card[i] then
			local sq = st.card[i]
			table.insert(C.popups, 1, { text = "TICKED: " .. C.Label(sq), t = now, good = true })
			if surface and surface.PlaySound then surface.PlaySound("garrysmod/save_load2.wav") end
		end
	end
	if st.phase == "results" and prev.phase ~= "results" and st.winner then Say(st.winner.name .. " wins!") end
end
BB.mode:OnState(function(st, now) C.OnState(st, now) end)

function C.Label(sq)
	local part = HOM and HOM.PART and HOM.PART[sq.part]
	local lv = HOM and HOM.LEVELS and HOM.LEVELS[sq.level]
	return (part and part.name or sq.part) .. ": " .. (lv and lv.name or "")
end

-- a bail over: back to my place at the start
function C.MySlot(st)
	local i, n = 1, #(st.players or {})
	for k, p in ipairs(st.players or {}) do if p.ent == LocalPlayer():EntIndex() then i = k end end
	local s = BB.Slot(st.start, st.yaw, i, n)
	return Vector(s[1], s[2], s[3])
end

function C.BackToStart(st, a, now)
	if not (st.start and a.TeleportTo) then return end
	if a.TeleportTo(C.MySlot(st), st.yaw) and SKATEGM_MODES.polish then SKATEGM_MODES.polish.Fade(now) end
end

function C.Think(now)
	local st, a = C.state, API()
	local me = C.Me(st)
	if a and st.start and me then
		BB.mode:HoldAtStart(st.phase == "countdown" and a.IsSkating(), C.MySlot(st), st.yaw, now)
	end
	if st.phase ~= "playing" or not (a and C.Me(st) and C.tracker) then return end
	local P = a.PoseOf and a.PoseOf(LocalPlayer())
	local events = C.tracker:Feed(P, a.Tick and a.Tick(), a.State and a.State(), P and P.HIPS and GroundBelow(P.HIPS), now)
	for _, ev in ipairs(events) do
		if ev.kind == "injury" then
			Send({ cmd = "hurt", part = ev.part, level = ev.level })
			table.insert(C.popups, 1, { text = string.upper(HOM.LEVELS[ev.level].name) .. "  " .. HOM.PART[ev.part].name, level = ev.level, t = now })
		elseif ev.kind == "done" then
			C.tracker = HOM.NewTracker(st.pain)
			C.BackToStart(st, a, now)
		end
	end
	while #C.popups > 5 do table.remove(C.popups) end
end
hook.Add("Think", "skategm_bodybingo", function() C.Think(RealTime()) end)

local FONTS = {
	skategm_bodyb_big = { "Coolvetica", 0.06, 500 },
	skategm_bodyb_mid = { "Coolvetica", 0.03, 500 },
	skategm_bodyb_small = { "Roboto", 0.018, 700 },
	skategm_bodyb_cell = { "Roboto", 0.0145, 800 },
}
local function Text(t, font, x, y, col, ax) SKATEGM_MODES.Text(t, font, x, y, col, ax or TEXT_ALIGN_CENTER, 1) end
local CELL_BG, CELL_DONE = Color(0, 0, 0, 170), Color(70, 170, 80, 220)

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" or st.phase == "lobby" then return end
	local me = C.Me(st)
	if not me then return end
	BB.mode:Fonts(FONTS)
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
	if st.phase == "countdown" then
		Text(tostring(math.max(1, math.ceil(left))), "skategm_bodyb_big", w / 2, h * 0.3, RED)
	elseif st.phase == "playing" then
		Text("BODY BINGO  " .. Clock(left), "skategm_bodyb_mid", w / 2, h * 0.04, RED)
	elseif st.phase == "results" then
		Text(st.winner and (string.upper(st.winner.name) .. ": BINGO!") or "NOBODY WON", "skategm_bodyb_big", w / 2, h * 0.2, GOLD)
	end
	local card = st.card
	if card then
		local marks = C.MyMarks(st)
		local size = math.floor(h * 0.085)
		local n = BB.SIZE
		local x0, y0 = w - size * n - w * 0.02, h * 0.2
		for i, sq in ipairs(card) do
			local r, c = math.floor((i - 1) / n), (i - 1) % n
			local x, y = x0 + c * size, y0 + r * size
			draw.RoundedBox(4, x + 2, y + 2, size - 4, size - 4, marks[i] and CELL_DONE or CELL_BG)
			local part = HOM and HOM.PART and HOM.PART[sq.part]
			local lv = HOM and HOM.LEVELS and HOM.LEVELS[sq.level]
			local name = part and part.name or sq.part
			local words, lines, cur = {}, {}, ""
			for wd in name:gmatch("%S+") do words[#words + 1] = wd end
			for _, wd in ipairs(words) do
				if #cur + #wd > 9 and cur ~= "" then lines[#lines + 1] = cur cur = wd else cur = cur == "" and wd or (cur .. " " .. wd) end
			end
			lines[#lines + 1] = cur
			local lc = lv and Color(lv.color[1], lv.color[2], lv.color[3]) or color_white
			for k, ln in ipairs(lines) do
				Text(ln, "skategm_bodyb_cell", x + size / 2, y + size * 0.22 + (k - 1) * size * 0.2, color_white, TEXT_ALIGN_CENTER)
			end
			Text(lv and string.upper(lv.name) or "", "skategm_bodyb_cell", x + size / 2, y + size * 0.68, lc, TEXT_ALIGN_CENTER)
		end
		Text(st.full and "fill the whole card" or "get three in a row", "skategm_bodyb_small", x0 + size * n / 2, y0 + size * n + h * 0.005, GREY)
		local y = y0 + size * n + h * 0.04
		for _, p in ipairs(st.players or {}) do
			Text(string.format("%s  %d/%d", p.name, p.count or 0, #card), "skategm_bodyb_small", x0 + size * n, y, p.ent == LocalPlayer():EntIndex() and GREEN or color_white, TEXT_ALIGN_RIGHT)
			y = y + h * 0.026
		end
	end
	local py = h * 0.62
	for _, p in ipairs(C.popups) do
		local age = now - p.t
		if age < 3 then
			local col = p.good and GREEN or (p.level and HOM and HOM.LEVELS[p.level] and Color(HOM.LEVELS[p.level].color[1], HOM.LEVELS[p.level].color[2], HOM.LEVELS[p.level].color[3])) or color_white
			Text(p.text, "skategm_bodyb_mid", w / 2, py, Color(col.r, col.g, col.b, 255 * math.min(1, 3 - age)))
			py = py - h * 0.04
		end
	end
end
hook.Add("HUDPaint", "skategm_bodybingo", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

local pains = {}
for _, p in ipairs(HOM and HOM.PAINS or { { 1, "normal" } }) do pains[#pains + 1] = { p[1], p[2] } end
BB.mode:LobbyLines(function(st) return { Clock(st.time or BB.TIME_DEFAULT) .. (st.full and ", whole card" or ", three in a row"), "bail to injure the parts on the card" } end)
BB.mode:Host({
	description = "hurt the right body parts",
	about = "Everyone gets a card of body parts. Bail and hurt those parts to tick them off. The first to get three in a row wins.",
	options = {
		{ key = "time", label = "Time limit", type = "number", min = BB.TIME_MIN, max = BB.TIME_MAX, step = 30, default = BB.TIME_DEFAULT, format = Clock },
		{ key = "full", label = "To win", type = "choice", choices = { { false, "three in a row" }, { true, "the whole card" } }, default = false },
		{ key = "pain", label = "Pain", type = "choice", choices = pains, default = 1 },
	},
	start = function(v, mode) mode:Send({ cmd = "create", time = v.time, full = v.full, pain = v.pain, canSkate = CanSkate() }) end,
})
