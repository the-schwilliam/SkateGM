-- Little touches every minigame gets, from the states the framework already
-- follows (no mode does anything): countdown beeps and a "go", a cue when
-- it's your turn, ticks in a timed turn's last seconds, a fade over the jump
-- when you're moved to the start, a sound for the results, a blip when
-- someone joins the lobby, "+N" over whoever scored, who's up next, the
-- watched player's score, a beam over a placed start while the lobby's
-- open. skategm_game_cues 0 turns the sounds and the fade off.
local M = SKATEGM_MODES
local P = M.polish or {}
M.polish = P

P.cv = P.cv or (CreateClientConVar and CreateClientConVar("skategm_game_cues", "1", true, false, "Minigame cues: countdown beeps, your-turn flash, fades", 0, 1))
P.SOUNDS = {
	beep = "buttons/blip1.wav",
	go = "buttons/bell1.wav",
	turn = "garrysmod/content_downloaded.wav",
	tick = "buttons/lightswitch2.wav",
	results = "garrysmod/save_load1.wav",
	join = "garrysmod/ui_hover.wav",
}
P.TIMED = { turn = true, shot = true, playing = true, riding = true, running = true, attempt = true, copy = true, lead = true, shoot = true, racing = true }
P.ENDED = { results = true, final = true }
P.LAST_SECONDS = 5
P.FADE_TIME = 0.45
P.FLASH_TIME = 1.4
P.FLASH_Y = 0.44 -- (below every mode's countdown and turn lines)
P.POP_TIME = 1.8
P.SCORE_KEYS = { "total", "points", "score" }
P.QUEUED = { prep = true, countdown = true, turn = true, shot = true, between = true, riding = true }
P.pops = P.pops or {}

function P.On() return not P.cv or P.cv:GetBool() end

function P.Play(name)
	if not P.On() then return end
	local snd = P.SOUNDS[name]
	if snd and surface and surface.PlaySound then surface.PlaySound(snd) end
	P.played = P.played or {}
	P.played[#P.played + 1] = name
end

local function Mine(st)
	local me = LocalPlayer():EntIndex()
	return st.active ~= nil and st.active ~= 0 and st.active == me
end

local function Count(st) return #(st.players or {}) end

function P.ScoreOf(p)
	for _, k in ipairs(P.SCORE_KEYS) do
		if type(p[k]) == "number" then return p[k] end
	end
end

-- "+N" rising over a player who just scored
function P.Pop(ent, amount, now, color)
	P.pops[#P.pops + 1] = { ent = ent, text = "+" .. M.Commas(math.floor(amount)), at = now, color = color }
end

function P.Scored(mode, prev, st, now)
	if not (prev.players and st.players) or st.phase == "lobby" or prev.phase == "lobby" then return end
	local before = {}
	for _, p in ipairs(prev.players) do if p.ent then before[p.ent] = P.ScoreOf(p) end end
	for _, p in ipairs(st.players) do
		local was, is = p.ent and before[p.ent], P.ScoreOf(p)
		if was and is and is > was then P.Pop(p.ent, is - was, now, mode.color) end
	end
end

local function NameOf(st, ent)
	for _, p in ipairs(st.players or {}) do if p.ent == ent then return p.name end end
end

-- who's up after this turn (st.nextUp, from the server)
function P.QueueLine(mode, st)
	if mode.ownQueue or not P.QUEUED[st.phase] or not st.nextUp or st.nextUp == 0 then return nil end
	if Mine(st) then return nil end
	if st.nextUp == st.active then return nil end
	if st.nextUp == LocalPlayer():EntIndex() then return "YOU'RE UP NEXT", true end
	local name = NameOf(st, st.nextUp)
	return name and ("next up: " .. name) or nil, false
end

-- under "WATCHING ...": the watched player's score (this turn's, while it's theirs)
function P.ScoreLine(ent)
	local mode, st = M.MyGame()
	if not (st and ent) then return nil end
	if st.active == ent and st.live ~= nil then
		local live = type(st.live) == "table" and st.live.score or st.live
		if type(live) == "number" then return "this turn: " .. M.Commas(math.floor(live)) end
	end
	for _, p in ipairs(st.players or {}) do
		if p.ent == ent then
			local s = P.ScoreOf(p)
			return s and ("score: " .. M.Commas(math.floor(s))) or nil
		end
	end
end

-- every lobby with a placed start (any game, so people can find it)
function P.PlacedStarts(now)
	local out = {}
	for _, mode in pairs(M.modes or {}) do
		if mode.seen then
			for _, entry in pairs(mode.seen) do
				local st = entry.st
				if st and st.phase == "lobby" and st.placed and now - (entry.at or 0) < 3 then out[#out + 1] = { st.placed, mode.color } end
			end
		elseif mode.state and mode.state.phase == "lobby" and mode.state.placed then
			out[#out + 1] = { mode.state.placed, mode.color }
		end
	end
	return out
end

function P.DrawStarts(now)
	if not (render and render.SetColorMaterial) then return end
	for _, it in ipairs(P.PlacedStarts(now)) do
		local s, col = it[1], it[2] or M.START_COLOR
		local pos = Vector(s.pos[1], s.pos[2], s.pos[3])
		local pulse = 0.75 + 0.25 * math.sin(now * 2)
		render.SetColorMaterial()
		render.DrawBeam(pos, pos + Vector(0, 0, 900), 14, 0, 1, Color(col.r, col.g, col.b, 40 * pulse))
		render.DrawBeam(pos, pos + Vector(0, 0, 900), 4, 0, 1, Color(col.r, col.g, col.b, 90 * pulse))
		if M.DrawStartMarker then M.DrawStartMarker(pos, s.yaw, 0.6) end
	end
end

local function PopPos(ent)
	local a = M.API()
	local ply = Entity(ent)
	if not IsValid(ply) then return nil end
	local P2 = a and a.PoseOf and a.PoseOf(ply)
	if P2 and P2.HIPS then return P2.HIPS + Vector(0, 0, 40) end
	return ply:GetPos() + Vector(0, 0, 80)
end

function P.PaintPops(w, h, now)
	local keep = {}
	for _, pop in ipairs(P.pops) do
		local age = now - pop.at
		if age < P.POP_TIME then
			keep[#keep + 1] = pop
			local pos = PopPos(pop.ent)
			local sc = pos and (pos + Vector(0, 0, age * 24)):ToScreen()
			if sc and sc.visible then
				local a = math.Clamp(math.min(age / 0.12, (P.POP_TIME - age) / 0.5), 0, 1)
				local col = pop.color or Color(255, 210, 90)
				local PAD = SKATEGM_UI and SKATEGM_UI.pad
				M.Text(pop.text, PAD and "skategm_ui_title" or "DermaLarge", sc.x, sc.y, Color(col.r, col.g, col.b, 255 * a), TEXT_ALIGN_CENTER, 2)
			end
		end
	end
	P.pops = keep
end

-- a state of a game I'm in has arrived: what changed
function P.Observe(mode, prev, st, now)
	prev = prev or { phase = "idle" }
	local w = P.watch[mode.id] or {}
	P.watch[mode.id] = w
	w.st, w.at = st, now
	if st.phase ~= prev.phase then
		w.lastSecond = nil
		if prev.phase == "countdown" and st.phase ~= "idle" and st.phase ~= "lobby" then P.Play("go") end
		if P.ENDED[st.phase] then P.Play("results") end
	end
	if Mine(st) and not Mine(prev) then
		P.Play("turn")
		P.flash = { text = "YOUR TURN", at = now, color = mode.color }
	end
	if st.phase == "lobby" and prev.phase == "lobby" and Count(st) > Count(prev) then P.Play("join") end
	P.Scored(mode, prev, st, now)
	if st.phase == "idle" then P.watch[mode.id] = nil end
end
P.watch = P.watch or {}

-- every frame: the countdown's seconds and the last seconds of a timed turn
function P.Think(now)
	for _, w in pairs(P.watch) do
		local st = w.st
		local left = (st.timeLeft or 0) - (now - (w.at or now))
		local second = math.ceil(left)
		if st.phase == "countdown" and left > 0 and second ~= w.lastSecond then
			w.lastSecond = second
			P.Play("beep")
		elseif P.TIMED[st.phase] and left > 0 and second <= P.LAST_SECONDS and second ~= w.lastSecond and (st.active == nil or Mine(st)) then
			w.lastSecond = second
			P.Play("tick")
		end
	end
end

-- moved to the start (a teleport): the picture dips to black and back
function P.Fade(now)
	if not P.On() then return end
	P.fadeAt = now or RealTime()
end

-- on a results screen: how long until the lobby
function P.ResultsLine(now)
	for _, w in pairs(P.watch) do
		local st = w.st
		if P.ENDED[st.phase] then
			local left = math.ceil((st.timeLeft or 0) - (now - (w.at or now)))
			if left > 0 then return "back to the lobby in " .. left end
		end
	end
end

function P.Paint(w, h, now)
	if M.Text and not M.HudHidden() then
		P.PaintPops(w, h, now)
		local mode, st = M.MyGame()
		local q, mine = nil, false
		if mode then q, mine = P.QueueLine(mode, st) end
		if q then
			local PAD = SKATEGM_UI and SKATEGM_UI.pad
			if PAD and PAD.Fonts then PAD.Fonts() end
			local col = mine and (mode.color or Color(255, 210, 90)) or Color(200, 200, 200, 220)
			M.Text(q, PAD and "skategm_ui_row" or "DermaDefaultBold", w / 2, h * 0.74, col, TEXT_ALIGN_CENTER, 1)
		end
	end
	local line = P.On() and not M.HudHidden() and P.ResultsLine(now)
	if line and M.Text then
		local PAD = SKATEGM_UI and SKATEGM_UI.pad
		if PAD and PAD.Fonts then PAD.Fonts() end
		M.Text(line, PAD and "skategm_ui_row" or "DermaDefault", w / 2, h * 0.94, Color(200, 200, 200, 220), TEXT_ALIGN_CENTER, 1)
	end
	if P.fadeAt then
		local k = (now - P.fadeAt) / P.FADE_TIME
		if k >= 1 then
			P.fadeAt = nil
		else
			surface.SetDrawColor(0, 0, 0, 255 * (1 - k) ^ 2)
			surface.DrawRect(0, 0, w, h)
		end
	end
	local f = not M.HudHidden() and P.flash
	if f then
		local age = now - f.at
		if age > P.FLASH_TIME then
			P.flash = nil
		else
			local a = math.Clamp(math.min(age / 0.15, (P.FLASH_TIME - age) / 0.4), 0, 1)
			local col = f.color or Color(255, 255, 255)
			local rise = (1 - math.min(age / 0.25, 1)) * h * 0.02
			if M.Text then
				local PAD = SKATEGM_UI and SKATEGM_UI.pad
				if PAD and PAD.Fonts then PAD.Fonts() end
				M.Text(f.text, PAD and "skategm_ui_title" or "DermaLarge", w / 2, h * P.FLASH_Y + rise, Color(col.r, col.g, col.b, 255 * a), TEXT_ALIGN_CENTER, 2)
			end
		end
	end
end

if hook and hook.Add then
	hook.Add("Think", "skategm_modes_polish", function() P.Think(RealTime()) end)
	hook.Add("HUDPaint", "skategm_modes_polish", function() P.Paint(ScrW(), ScrH(), RealTime()) end)
	hook.Add("PostDrawTranslucentRenderables", "skategm_modes_polish", function(depth, sky)
		if not depth and not sky then P.DrawStarts(RealTime()) end
	end)
end
