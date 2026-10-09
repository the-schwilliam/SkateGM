local C = { state = { phase = "idle" }, marks = {}, pending = {}, sent = {} }
BINGO.client = C

local API = SKATEGM_MODES.API
local CanSkate = SKATEGM_MODES.CanSkate
local Text = SKATEGM_MODES.Text
local function Send(t) BINGO.mode:Send(t) end
local function Say(text, bad) BINGO.mode:Say(text, bad) end

function C.Me(st) return BINGO.mode:Me(st) end
function C.IsHost(st) return BINGO.mode:IsHost(st) end

function C.Reset()
	C.marks, C.pending, C.sent = {}, {}, {}
	C.lastLine, C.lastTrickT, C.lineMult, C.airStart, C.grindStart, C.wasClean, C.primed = nil, nil, 1, nil, nil, nil, nil
end

function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	local me = C.Me(st)
	local a = API()
	if me and st.phase ~= "idle" and a and not a.IsSkating() and not a.IsLoading() and CanSkate() and not C.asked then
		C.asked = true
		a.StartSkating()
	end
	if not me then C.asked = nil end
	if st.phase == "countdown" and prev.phase ~= "countdown" then C.Reset() end
	if me then
		for _, i in ipairs(me.marks or {}) do C.marks[i] = true end
	end
end

function C.Complete(i)
	if C.marks[i] or C.sent[i] then return end
	C.sent[i] = true
	C.marks[i] = true
	Send({ cmd = "done", cell = i })
	if surface and surface.PlaySound then surface.PlaySound("buttons/button14.wav") end
end

local function CellsOfKind(card, fn)
	local out = {}
	for i, id in ipairs(card) do
		local t = BINGO.BY_ID[id]
		if t and not C.marks[i] and fn(t) then out[#out + 1] = { i, t } end
	end
	return out
end

function C.Track(now)
	local st = C.state
	local card = st.card
	local a = API()
	if st.phase ~= "playing" or not card or not a or not C.Me(st) then return end
	local state = a.State and a.State() or ""
	local info = a.ScoreInfo and a.ScoreInfo()
	local speed = a.Speed and a.Speed() or 0
	if not info then return end
	if not C.primed then
		C.primed, C.wasClean = true, info.clean
		C.lastLine = info.line
	end
	if state:find("Wipeout", 1, true) then
		C.pending, C.lineMult, C.airStart, C.grindStart = {}, 1, nil, nil
		C.lastLine = info.line
		return
	end
	local riding = a.OnBoard and a.OnBoard() or (state ~= "" and not state:find("Biped", 1, true))
	for _, c in ipairs(riding and CellsOfKind(card, function(t) return t.kind == "speed" end) or {}) do
		if speed >= c[2].value then C.Complete(c[1]) end
	end
	if info.clean and not C.wasClean then
		for _, c in ipairs(CellsOfKind(card, function(t) return t.kind == "clean" end)) do C.Complete(c[1]) end
	end
	C.wasClean = info.clean
	C.lineMult = math.max(C.lineMult or 1, info.multiplier or 1)
	if info.trickT and info.trickT ~= C.lastTrickT then
		C.lastTrickT = info.trickT
		local name = string.lower(info.trick or "")
		for _, c in ipairs(CellsOfKind(card, function(t) return t.kind == "trick" end)) do
			for _, m in ipairs(c[2].match) do if name:find(m, 1, true) then C.pending[c[1]] = true end end
		end
	end
	for _, c in ipairs(CellsOfKind(card, function(t) return t.kind == "state" end)) do
		if state == c[2].state then C.pending[c[1]] = true end
	end
	local inAir = state:find("Air", 1, true) ~= nil
	if inAir and not C.airStart then C.airStart = now end
	if not inAir and C.airStart then
		local dur = now - C.airStart
		C.airStart = nil
		for _, c in ipairs(CellsOfKind(card, function(t) return t.kind == "air" end)) do
			if dur >= c[2].seconds then C.pending[c[1]] = true end
		end
	end
	local grinding = state:sub(1, 5) == "Grind"
	if grinding and not C.grindStart then C.grindStart = now end
	if not grinding and C.grindStart then
		local dur = now - C.grindStart
		C.grindStart = nil
		for _, c in ipairs(CellsOfKind(card, function(t) return t.kind == "grindtime" end)) do
			if dur >= c[2].seconds then C.pending[c[1]] = true end
		end
	end
	local line = info.line or 0
	if C.lastLine and line > C.lastLine + 0.5 then
		for i in pairs(C.pending) do C.Complete(i) end
		C.pending = {}
		for _, c in ipairs(CellsOfKind(card, function(t) return t.kind == "mult" end)) do
			if C.lineMult >= c[2].value then C.Complete(c[1]) end
		end
	end
	if line < (C.lastLine or 0) then C.lineMult = 1 end
	for _, c in ipairs(CellsOfKind(card, function(t) return t.kind == "line" end)) do
		if line >= c[2].points then C.Complete(c[1]) end
	end
	C.lastLine = line
end

BINGO.mode:OnState(function(st, now) C.OnState(st, now) end)
hook.Add("Think", "skategm_bingo", function() C.Track(RealTime()) end)

local FONTS = {
	skategm_bingo_big = { "Roboto", 0.07, 900, 24 },
	skategm_bingo_mid = { "Roboto", 0.026, 700, 16 },
	skategm_bingo_cell = { "Roboto", 0.016, 700, 11 },
	skategm_bingo_small = { "Roboto", 0.019, 600, 12 },
}
local GOLD, GREY, GREEN = Color(255, 200, 90), Color(170, 170, 170), Color(110, 230, 120)
local CELL_BG, CELL_DONE, CELL_PEND, CELL_FREE = Color(0, 0, 0, 170), Color(60, 170, 80, 220), Color(200, 160, 60, 200), Color(90, 90, 90, 200)

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" then return end
	BINGO.mode:Fonts(FONTS)
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
	if st.phase == "lobby" then
		return
	elseif st.phase == "countdown" then
		Text(tostring(math.max(1, math.ceil(left))), "skategm_bingo_big", w / 2, h * 0.3, GOLD)
	elseif st.phase == "playing" then
		Text("TRICK BINGO  " .. BINGO.Clock(left), "skategm_bingo_mid", w / 2, h * 0.04, GOLD)
	elseif st.phase == "results" then
		Text(st.winner and (st.winner.name .. ": BINGO!") or "nobody won", "skategm_bingo_big", w / 2, h * 0.25, GOLD)
	end
	local card = st.card
	if card and C.Me(st) then
		local size = math.floor(h * 0.075)
		local x0, y0 = w - size * BINGO.SIZE - w * 0.02, h * 0.2
		for i, id in ipairs(card) do
			local r, c = math.floor((i - 1) / BINGO.SIZE), (i - 1) % BINGO.SIZE
			local x, y = x0 + c * size, y0 + r * size
			local bg = id == "free" and CELL_FREE or (C.marks[i] and CELL_DONE) or (C.pending[i] and CELL_PEND) or CELL_BG
			draw.RoundedBox(4, x + 2, y + 2, size - 4, size - 4, bg)
			local task = BINGO.BY_ID[id]
			local label = id == "free" and "FREE" or (task and task.label or id)
			local words, lines, cur = {}, {}, ""
			for wd in label:gmatch("%S+") do words[#words + 1] = wd end
			for _, wd in ipairs(words) do
				if #cur + #wd > 10 and cur ~= "" then lines[#lines + 1] = cur cur = wd else cur = cur == "" and wd or (cur .. " " .. wd) end
			end
			lines[#lines + 1] = cur
			for k, ln in ipairs(lines) do
				Text(ln, "skategm_bingo_cell", x + size / 2, y + size / 2 - #lines * size * 0.11 + (k - 1) * size * 0.22, color_white, TEXT_ALIGN_CENTER, 1)
			end
		end
		Text(st.full and "fill the whole card" or "get three in a row", "skategm_bingo_small", x0 + size * BINGO.SIZE / 2, y0 + size * BINGO.SIZE + h * 0.005, GREY)
		local y = y0 + size * BINGO.SIZE + h * 0.04
		for _, p in ipairs(st.players or {}) do
			Text(string.format("%s  %d/%d", p.name, p.count or 0, #card), "skategm_bingo_small", x0 + size * BINGO.SIZE, y, p.ent == LocalPlayer():EntIndex() and GREEN or color_white, TEXT_ALIGN_RIGHT)
			y = y + h * 0.026
		end
	end
end
hook.Add("HUDPaint", "skategm_bingo", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

BINGO.mode:ChatCommands({})
BINGO.mode:JoinInfo(function(st)
	if not st.phase or st.phase == "idle" then return nil end
	local host = st.host and st.host ~= 0 and Entity(st.host)
	local me = C.Me(st)
	return { host = (host and IsValid(host)) and host:Nick() or "someone", phase = st.phase, joinable = me == nil and st.phase ~= "results", mine = C.IsHost(st), playing = me ~= nil }
end)
BINGO.mode:Host({
	useStart = false,
	description = "land tricks to get three in a row",
	about = "Everyone gets the same 3x3 card of tricks. Land a trick in a line to tick its square. The first to get three in a row wins.",
	options = {
		{ key = "time", label = "Time limit", type = "number", min = BINGO.TIME_MIN, max = BINGO.TIME_MAX, step = 30, default = BINGO.TIME_DEFAULT, format = BINGO.Clock },
		{ key = "full", label = "To win", type = "choice", choices = { { false, "three in a row" }, { true, "the whole card" } }, default = false },
		{ key = "free", label = "Free middle square", type = "bool", default = true },
	},
	start = function(v, mode)
		mode:Send({ cmd = "create", time = v.time, full = v.full, free = v.free, canSkate = CanSkate() })
	end,
})

