local M = SKATEGM_MODES
local MU = M.music or {}
M.music = MU
MU.FADE = 1.5
MU.TRACKS = MU.TRACKS or {}

function M.RegisterMusic(id, def)
	assert(type(id) == "string" and type(def) == "table" and type(def.path) == "string", "SKATEGM_MODES.RegisterMusic: needs an id and a path")
	MU.TRACKS[id] = { path = def.path }
end

M.RegisterMusic("arena", { path = "sound/skategm/music/arena.ogg" })

local cvOn = CreateClientConVar("skategm_game_music", "1", true, false, "1 = music plays during minigames that have it")
local cvVolume = CreateClientConVar("skategm_music_volume", "0.6", true, false, "Minigame music volume, 0-1", 0, 1)

function MU.Volume()
	if not cvOn:GetBool() then return 0 end
	return math.Clamp(cvVolume:GetFloat(), 0, 1)
end

function MU.Wanted()
	local mode, st = M.MyGame()
	if not (mode and mode.music and M.InPlay(st)) then return nil end
	if MU.Volume() <= 0 then return nil end
	return MU.TRACKS[mode.music] and mode.music or nil
end

function MU.Stop(now)
	local cur = MU.current
	MU.current = nil
	if not (cur and IsValid(cur.ch)) then return end
	MU.fading = MU.fading or {}
	MU.fading[#MU.fading + 1] = { ch = cur.ch, from = now, vol = cur.vol or MU.Volume() }
end

function MU.Start(id)
	local track = MU.TRACKS[id]
	local cur = { id = id, track = track, vol = MU.Volume() }
	MU.current = cur
	sound.PlayFile(track.path, "noblock", function(ch)
		if not IsValid(ch) then return end
		if MU.current ~= cur then ch:Stop() return end
		ch:EnableLooping(true)
		ch:SetVolume(cur.vol)
		ch:Play()
		cur.ch = ch
	end)
end

function MU.Think(now)
	local want = MU.Wanted()
	local cur = MU.current
	if cur and cur.id ~= want then MU.Stop(now) cur = nil end
	if want and not cur then MU.Start(want) cur = MU.current end
	if cur and IsValid(cur.ch) then
		cur.vol = MU.Volume()
		cur.ch:SetVolume(cur.vol)
		if cur.ch:GetState() == GMOD_CHANNEL_STOPPED then cur.ch:Play() end
	end
	if MU.fading then
		for i = #MU.fading, 1, -1 do
			local f = MU.fading[i]
			local k = 1 - (now - f.from) / MU.FADE
			if not IsValid(f.ch) or k <= 0 then
				if IsValid(f.ch) then f.ch:Stop() end
				table.remove(MU.fading, i)
			else
				f.ch:SetVolume(f.vol * k)
			end
		end
		if #MU.fading == 0 then MU.fading = nil end
	end
end

if hook and hook.Add then hook.Add("Think", "skategm_modes_music", function() MU.Think(RealTime()) end) end
