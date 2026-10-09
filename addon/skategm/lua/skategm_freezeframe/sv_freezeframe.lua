-- Freeze Frame, server: the game. Uses only SkateGM.API from the skating add-on.

local FF = FREEZEFRAME
local S = { phase = "idle" }
FF.session = S
FF.mode:UseSessions(S)

local Allowed = SKATEGM_MODES.Allowed
local function Tell(ply, text) FF.mode:Tell(ply, text) end
local function Key(ply) return SKATEGM_MODES.Key(ply) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(S.players, ply) end
local function Ent(ply) return IsValid(ply) and ply:EntIndex() or 0 end
local SHOWING = { show = true, vote = true, out = true }

local function Alive()
	local out = {}
	for _, p in ipairs(S.players or {}) do if S.entries[Key(p)].alive then out[#out + 1] = p end end
	return out
end

local function Public(now)
	local t = { phase = S.phase }
	if S.phase == "idle" then return t end
	t.host, t.time, t.round = Ent(S.host), S.time, S.round
	t.timeLeft = S.deadline and math.max(0, S.deadline - now) or 0
	if SHOWING[S.phase] then
		t.photos = S.photos
		t.showIndex = S.showIndex
	end
	t.out, t.winner = S.out, S.winner
	t.players = {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)] or {}
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), alive = e.alive or nil, playing = e.playing or nil,
			locked = (S.shots and S.shots[p:EntIndex()] ~= nil) or nil, voted = (S.votes and S.votes[p:EntIndex()] ~= nil) or nil }
	end
	return t
end

local function Broadcast(now) FF.mode:Broadcast(Public(now or CurTime()), now) end
FF.Broadcast = Broadcast

local function Stop(reason, now)
	for k in pairs(S) do S[k] = nil end
	S.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
FF.Stop = Stop

local function ToLobby(now)
	S.phase, S.deadline, S.round, S.shots, S.photos, S.votes, S.out, S.winner, S.showIndex = "lobby", nil, 0, nil, nil, nil, nil, nil, nil
	for _, e in pairs(S.entries) do e.alive, e.playing = nil, nil end
	Broadcast(now)
end

local function Results(now, winner)
	S.winner = winner and { ent = winner:EntIndex(), name = winner:Nick() } or nil
	S.phase, S.deadline = "results", now + FF.RESULTS
	Broadcast(now)
	Tell(nil, winner and (winner:Nick() .. " wins Freeze Frame!") or "nobody's left")
end

local function NextRound(now)
	local alive = Alive()
	if #alive <= 1 then return Results(now, alive[1]) end
	S.round = (S.round or 0) + 1
	S.shots, S.photos, S.votes, S.out, S.showIndex = {}, nil, nil, nil, nil
	S.phase, S.deadline = "countdown", now + FF.COUNTDOWN
	Broadcast(now)
end

local function Shuffle(t)
	for i = #t, 2, -1 do
		local j = math.random(1, i)
		t[i], t[j] = t[j], t[i]
	end
	return t
end

local function EndShoot(now)
	S.photos = {}
	local missed = {}
	for _, p in ipairs(Alive()) do
		local shot = S.shots[p:EntIndex()]
		if shot then
			S.photos[#S.photos + 1] = { ent = p:EntIndex(), name = p:Nick(), pose = shot.pose, cam = shot.cam, filter = shot.filter }
		else
			missed[#missed + 1] = p
		end
	end
	if #missed > 0 and #S.photos > 0 then
		local names = {}
		for _, p in ipairs(missed) do
			S.entries[Key(p)].alive = nil
			names[#names + 1] = p:Nick()
		end
		Tell(nil, table.concat(names, " and ") .. (#names == 1 and " wasn't" or " weren't") .. " skating when time ran out: out")
	end
	if #S.photos <= 1 then
		S.photos = nil
		return NextRound(now)
	end
	Shuffle(S.photos)
	S.showIndex = 1
	S.phase, S.deadline = "show", now + FF.SHOW
	Broadcast(now)
end

local function EndVote(now)
	local candidates = {}
	for _, ph in ipairs(S.photos) do candidates[#candidates + 1] = ph.ent end
	local worst, votes = FF.Worst(S.votes, candidates)
	local name = "?"
	for _, p in ipairs(S.players) do
		if p:EntIndex() == worst then
			S.entries[Key(p)].alive = nil
			name = p:Nick()
		end
	end
	S.out = { ent = worst, name = name, votes = votes }
	S.phase, S.deadline = "out", now + FF.OUT
	Broadcast(now)
	Tell(nil, name .. "'s photo got the most votes (" .. votes .. "): out")
end

function FF.Tick(now)
	local ph = S.phase
	if ph == "idle" or ph == "lobby" then return end
	if ph == "countdown" and now > S.deadline then
		S.phase, S.deadline = "shoot", now + S.time
		Broadcast(now)
	elseif ph == "shoot" then
		local all = true
		for _, p in ipairs(Alive()) do if not S.shots[p:EntIndex()] then all = false end end
		if all or now > S.deadline then EndShoot(now) end
	elseif ph == "show" and now > S.deadline then
		if S.showIndex < #S.photos then
			S.showIndex = S.showIndex + 1
			S.deadline = now + FF.SHOW
		else
			S.phase, S.deadline, S.votes = "vote", now + FF.VOTE, {}
		end
		Broadcast(now)
	elseif ph == "vote" then
		local all = true
		for _, p in ipairs(S.players) do
			if S.entries[Key(p)].playing and not S.votes[p:EntIndex()] then all = false end
		end
		if all or now > S.deadline then EndVote(now) end
	elseif ph == "out" and now > S.deadline then
		NextRound(now)
	elseif ph == "results" and now > S.deadline then
		ToLobby(now)
	end
end
FF.mode:OnThink(function(now) FF.Tick(now) end)

function FF.Remove(ply, why, now)
	now = now or CurTime()
	local i = IndexOf(ply)
	if not i then return end
	local ent = ply:EntIndex()
	table.remove(S.players, i)
	S.entries[Key(ply)] = nil
	if #S.players == 0 then return Stop("everyone left: Freeze Frame is over", now) end
	if S.host == ply then
		S.host = S.players[1]
		Tell(nil, S.host:Nick() .. " is the host now")
	end
	Tell(nil, ply:Nick() .. " " .. why)
	if S.shots then S.shots[ent] = nil end
	if S.votes then
		S.votes[ent] = nil
		for voter, target in pairs(S.votes) do if target == ent then S.votes[voter] = nil end end
	end
	if S.photos then
		for k = #S.photos, 1, -1 do if S.photos[k].ent == ent then table.remove(S.photos, k) end end
		S.showIndex = S.showIndex and math.min(S.showIndex, math.max(1, #S.photos)) or nil
	end
	local inGame = S.phase ~= "lobby" and S.phase ~= "results"
	if inGame and #Alive() <= 1 then return Results(now, Alive()[1]) end
	if SHOWING[S.phase] and S.phase ~= "out" and #S.photos <= 1 then return NextRound(now) end
	Broadcast(now)
end
FF.mode:OnPlayerLeave(function(ply) FF.Remove(ply, "left the game") end)

local handlers = {}
local function Host(ply) return S.phase ~= "idle" and S.host == ply end

function handlers.create(ply, m, now)
	if S.phase ~= "idle" then return Tell(ply, "a game is already open") end
	if FF.mode:CantSkate(ply, m, "host") then return end
	S.phase, S.host = "lobby", ply
	S.time = FF.ClampTime(m.time)
	S.players, S.entries, S.round = { ply }, {}, 0
	S.entries[Key(ply)] = { name = ply:Nick() }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " is hosting Freeze Frame: join with LB + D-pad left")
end

function handlers.join(ply, m, now)
	if S.phase == "idle" then return Tell(ply, "no game is open") end
	if S.phase ~= "lobby" then return Tell(ply, "a game is on: wait for the next one") end
	if IndexOf(ply) then return end
	if FF.mode:CantSkate(ply, m, "play") then return end
	S.players[#S.players + 1] = ply
	S.entries[Key(ply)] = { name = ply:Nick() }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " joined")
end

function handlers.leave(ply, m, now) FF.Remove(ply, "left the game", now) end

function handlers.begin(ply, m, now)
	if not Host(ply) then return Tell(ply, "only the host can start") end
	if S.phase ~= "lobby" then return end
	if #S.players < 2 then return Tell(ply, "Freeze Frame needs at least 2 players") end
	for _, e in pairs(S.entries) do e.alive, e.playing = true, true end
	S.round = 0
	NextRound(now)
end

function handlers.stop(ply, m, now)
	if S.phase == "idle" then return end
	if not (Host(ply) or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
	if m.close or S.phase == "lobby" then return Stop("Freeze Frame was closed by " .. ply:Nick(), now) end
	ToLobby(now)
	Tell(nil, ply:Nick() .. " stopped the game")
end

function handlers.photo(ply, m, now)
	if S.phase ~= "shoot" then return end
	local e = IndexOf(ply) and S.entries[Key(ply)]
	if not (e and e.alive) or S.shots[ply:EntIndex()] then return end
	local shot = FF.CleanPhoto(m, ply.SkateGMHips)
	if not shot then return Tell(ply, "that photo didn't come through: try again") end
	S.shots[ply:EntIndex()] = shot
	Broadcast(now)
end

function handlers.vote(ply, m, now)
	if S.phase ~= "vote" then return end
	local e = IndexOf(ply) and S.entries[Key(ply)]
	local target = tonumber(m.target)
	if not (e and e.playing and target) or target == ply:EntIndex() then return end
	local ok = false
	for _, ph in ipairs(S.photos) do if ph.ent == target then ok = true end end
	if not ok then return end
	S.votes[ply:EntIndex()] = target
	Broadcast(now)
end

FF.Command = FF.mode:Serve(S, handlers, function(why) FF.Stop(why) end, function() Broadcast() end)
