dofile("gmock.lua")
local cv = { skategm_game_music = "1", skategm_music_volume = "0.6" }
function CreateClientConVar(n, d)
	return { GetBool = function() return (cv[n] or d) ~= "0" end, GetFloat = function() return tonumber(cv[n] or d) end, GetInt = function() return tonumber(cv[n] or d) end }
end
GMOD_CHANNEL_STOPPED, GMOD_CHANNEL_PLAYING = 0, 1
local channels = {}
local function Channel(path)
	local ch = { path = path, t = 0, vol = 1, state = 0, seeks = {} }
	function ch:IsValid() return not self.gone end
	function ch:SetVolume(v) self.vol = v end
	function ch:Play() self.state = 1 end
	function ch:Stop() self.state = 0 self.gone = true end
	function ch:GetTime() return self.t end
	function ch:SetTime(t) self.t = t self.seeks[#self.seeks + 1] = t end
	function ch:GetState() return self.state end
	function ch:EnableLooping(on) self.looping = on end
	function ch:GetLength() return self.path:find("loop") and 43.8907 or 5.743 end
	return ch
end
sound = { PlayFile = function(path, flags, cb) local ch = Channel(path) ch.flags = flags channels[#channels + 1] = ch cb(ch) end }
function IsValid(x) return x ~= nil and (type(x) ~= "table" or not x.IsValid or x:IsValid()) end
function LocalPlayer() return { EntIndex = function() return 1 end, GetPos = function() return Vector(0, 0, 0) end } end
local hooks = {}
hook = { Add = function(n, id, f) hooks[id] = f end, Run = function() end }
net = { Start = function() end, WriteString = function() end, SendToServer = function() end, Receive = function() end }
concommand = { Add = function() end }
SkateGM = { API = {} }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
local M = SKATEGM_MODES
if not M.music then dofile("../../addon/skategm/lua/skategm_modes/cl_music.lua") end
local MU = M.music
local function check(label, ok) print(string.format("%-66s %s", label, ok and "OK" or "<-- WRONG")) end

local arena = M.Register({ id = "mtest", title = "Music test", music = "arena" })
local quiet = M.Register({ id = "mquiet", title = "Quiet test" })
local me = { { ent = 1, name = "Me" } }
check("Register keeps the mode's music", arena.music == "arena" and quiet.music == nil)
check("the arena track: one file, played on a loop", MU.TRACKS.arena and MU.TRACKS.arena.path == "sound/skategm/music/arena.ogg")

arena.state = { phase = "lobby", host = 2, players = me }
MU.Think(0)
check("lobby: no music", #channels == 0)
arena.state.phase = "playing"
MU.Think(1)
local ch = channels[1]
check("playing: one file, set to loop, at the music volume", #channels == 1 and ch.path == "sound/skategm/music/arena.ogg" and ch.flags == "noblock" and ch.looping == true and ch.state == 1 and math.abs(ch.vol - 0.6) < 1e-6)
ch.t = 300
MU.Think(2)
check("never seeked", #ch.seeks == 0)
ch.state = 0
MU.Think(3)
check("stopped by itself: played again", ch.state == 1 and #ch.seeks == 0)
cv.skategm_music_volume = "0.3"
MU.Think(5)
check("volume follows the setting live", math.abs(ch.vol - 0.3) < 1e-6 and #channels == 1)
arena.state.phase = "results"
MU.Think(10)
MU.Think(10.5)
check("results: fades out", ch.state == 1 and ch.vol < 0.3)
MU.Think(10 + MU.FADE + 0.1)
check("... then stops", ch.gone == true and MU.fading == nil)

arena.state = { phase = "idle" }
quiet.state = { phase = "playing", host = 2, players = me }
MU.Think(20)
check("a mode without music plays none", #channels == 1)
quiet.state = { phase = "idle" }
arena.state = { phase = "playing", host = 2, players = me }
cv.skategm_game_music = "0"
MU.Think(21)
check("Music off: none", #channels == 1)
cv.skategm_game_music = "1"
MU.Think(22)
check("Music on again mid-game: starts", #channels == 2 and channels[2].state == 1)
arena.state = { phase = "playing", host = 2, players = { { ent = 3, name = "Bob" } } }
MU.Think(23)
MU.Think(23.5)
check("not my game: stops", channels[2].vol < 0.3 or channels[2].gone)
check("the Think hook is installed", hooks.skategm_modes_music ~= nil)

for _, id in ipairs({ "snake", "melon", "skullrunners", "ballbattle", "potato", "rocketroyale", "race" }) do
	local f = io.open("../../addon/skategm/lua/skategm_" .. id .. "/sh_" .. id .. ".lua")
	local s = f and f:read("*a") or ""
	if f then f:close() end
	check(id .. " plays the arena music", s:find('Register({ music = "arena", id = "' .. id .. '"', 1, true) ~= nil)
end
local f = io.open("../../addon/skategm/sound/skategm/music/arena.ogg", "rb")
check("the track ships in the add-on", f ~= nil and f:read(4) == "OggS")
if f then f:close() end
