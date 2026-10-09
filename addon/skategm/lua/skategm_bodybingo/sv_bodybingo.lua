-- Body Bingo, server: the game. Uses only SkateGM.API from the skating add-on.

local BB = BODYBINGO
local S = { phase = "idle" }
BB.session = S
BB.mode:UseSessions(S)

local Allowed = SKATEGM_MODES.Allowed
local function Tell(ply, text) BB.mode:Tell(ply, text) end
local function Key(ply) return SKATEGM_MODES.Key(ply) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(S.players, ply) end
local function Ent(ply) return IsValid(ply) and ply:EntIndex() or 0 end

local function Public(now)
	local t = { phase = S.phase }
	if S.phase == "idle" then return t end
	t.host = Ent(S.host)
	t.card, t.full, t.time, t.pain = S.card, S.full, S.time, S.pain
	t.start, t.yaw = S.start, S.yaw
	t.timeLeft = S.deadline and math.max(0, S.deadline - now) or 0
	t.winner = S.winner
	t.players = {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)] or {}
		local marks = {}
		for i in pairs(e.marks or {}) do marks[#marks + 1] = i end
		table.sort(marks)
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), playing = e.playing or nil, marks = marks, count = S.card and BB.Count(e.marks or {}, S.card) or 0 }
	end
	return t
end

local function Broadcast(now)
	BB.mode:Broadcast(Public(now or CurTime()), now)
	S.lastBroadcast = now or CurTime()
end
BB.Broadcast = Broadcast

local function Stop(reason, now)
	for k in pairs(S) do S[k] = nil end
	S.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
BB.Stop = Stop

local function ToLobby(now)
	S.phase, S.deadline, S.winner, S.card = "lobby", nil, nil, nil
	for _, e in pairs(S.entries) do e.playing, e.marks = nil, {} end
	Broadcast(now)
end

local function Results(now, winner, why)
	if not winner then
		local best, bestN
		for _, p in ipairs(S.players) do
			local e = S.entries[Key(p)]
			if e.playing then
				local n = BB.Count(e.marks, S.card)
				if not bestN or n > bestN then best, bestN = p, n end
			end
		end
		winner = best
	end
	S.winner = winner and { name = winner:Nick(), ent = winner:EntIndex() } or nil
	S.phase, S.deadline = "results", now + BB.RESULTS
	Broadcast(now)
	Tell(nil, winner and (winner:Nick() .. " wins Body Bingo" .. (why and (" (" .. why .. ")") or "")) or "nobody played")
end

function BB.Tick(now)
	local ph = S.phase
	if ph == "countdown" and now > S.deadline then
		S.phase, S.deadline = "playing", now + S.time
		Broadcast(now)
	elseif ph == "playing" then
		if now > S.deadline then return Results(now, nil, "time's up: most squares") end
		if now - (S.lastBroadcast or 0) > 1 then Broadcast(now) end
	elseif ph == "results" and now > S.deadline then
		ToLobby(now)
	end
end
BB.mode:OnThink(function(now) BB.Tick(now) end)

function BB.Remove(ply, why, now)
	now = now or CurTime()
	local i = IndexOf(ply)
	if not i then return end
	table.remove(S.players, i)
	S.entries[Key(ply)] = nil
	if #S.players == 0 then return Stop("everyone left: Body Bingo is over", now) end
	if S.host == ply then
		S.host = S.players[1]
		Tell(nil, S.host:Nick() .. " is the host now")
	end
	Tell(nil, ply:Nick() .. " " .. why)
	Broadcast(now)
end
BB.mode:OnPlayerLeave(function(ply) BB.Remove(ply, "left the game") end)

local handlers = {}
local function Host(ply) return S.phase ~= "idle" and S.host == ply end

function handlers.create(ply, m, now)
	if S.phase ~= "idle" then return Tell(ply, "a game is already open") end
	if BB.mode:CantSkate(ply, m, "host") then return end
	S.phase, S.host = "lobby", ply
	local p, yaw = SKATEGM_MODES.HostStart(ply, m)
	S.start, S.yaw = { p.x, p.y, p.z }, yaw
	S.time, S.full = BB.ClampTime(m.time), m.full == true
	S.pain = HOM and HOM.PainScale and HOM.PainScale(m.pain) or 1
	S.players, S.entries = { ply }, {}
	S.entries[Key(ply)] = { name = ply:Nick(), marks = {} }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " is hosting Body Bingo: join with LB + D-pad left")
end

function handlers.join(ply, m, now)
	if S.phase == "idle" then return Tell(ply, "no game is open") end
	if S.phase ~= "lobby" then return Tell(ply, "a game is on: wait for the next one") end
	if IndexOf(ply) then return end
	if BB.mode:CantSkate(ply, m, "play") then return end
	S.players[#S.players + 1] = ply
	S.entries[Key(ply)] = { name = ply:Nick(), marks = {} }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " joined")
end

function handlers.leave(ply, m, now) BB.Remove(ply, "left the game", now) end

-- LB + X while playing: back to the start
BB.mode:RespawnAt(function(ply)
	if not S.start then return nil end
	local i = IndexOf(ply) or 1
	local s = BB.Slot(S.start, S.yaw, i, #S.players)
	return Vector(s[1], s[2], s[3]), S.yaw
end)

function handlers.begin(ply, m, now)
	if not Host(ply) then return Tell(ply, "only the host can start") end
	if S.phase ~= "lobby" then return end
	if not (HOM and HOM.PARTS) then return Tell(ply, "Body Bingo needs Hall of Meat's injuries (skategm_hom)") end
	S.card = BB.Deal(HOM.PARTS)
	for _, e in pairs(S.entries) do e.playing, e.marks = true, {} end
	S.phase, S.deadline, S.winner = "countdown", now + BB.COUNTDOWN, nil
	Broadcast(now)
end

function handlers.stop(ply, m, now)
	if S.phase == "idle" then return end
	if not (Host(ply) or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
	if m.close or S.phase == "lobby" then return Stop("Body Bingo was closed by " .. ply:Nick(), now) end
	ToLobby(now)
	Tell(nil, ply:Nick() .. " stopped the game")
end

function handlers.hurt(ply, m, now)
	if S.phase ~= "playing" then return end
	local e = IndexOf(ply) and S.entries[Key(ply)]
	local level = tonumber(m.level)
	if not (e and e.playing and type(m.part) == "string" and level) then return end
	local ticked = BB.Ticks(S.card, e.marks, m.part, math.floor(level))
	if #ticked == 0 then return end
	for _, i in ipairs(ticked) do e.marks[i] = true end
	local sq = S.card[ticked[1]]
	local part = HOM and HOM.PART and HOM.PART[sq.part]
	local lv = HOM and HOM.LEVELS and HOM.LEVELS[sq.level]
	Tell(nil, string.format("%s: %s %s (%d/%d)", ply:Nick(), part and part.name or sq.part, lv and lv.name or "", BB.Count(e.marks, S.card), #S.card))
	if BB.Won(e.marks, S.card, S.full) then return Results(now, ply, S.full and "full card" or "BINGO") end
	Broadcast(now)
end

BB.Command = BB.mode:Serve(S, handlers, function(why) BB.Stop(why) end, function() Broadcast() end)
