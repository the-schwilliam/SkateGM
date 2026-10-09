dofile("gmock.lua")
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local convars = {}
function CreateClientConVar(name, default)
	convars[name] = default
	return { GetBool = function() return convars[name] ~= "0" end, GetInt = function() return tonumber(convars[name]) or 0 end,
		GetFloat = function() return tonumber(convars[name]) or 0 end }
end
local manifest
local installed = true
file = {
	Read = function(path, where) return where == "DATA" and path == "skategm/skate3_sounds.json" and manifest or nil end,
	Exists = function(path, where) return installed and where == "GAME" and path == "sound/skate3/grains" end,
}
util = util or {}
local function NumberKeys(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[tonumber(k) or k] = NumberKeys(v) end
	return out
end
util.JSONToTable = NumberKeys
local delayed = {}
timer = { Simple = function(d, fn) delayed[#delayed + 1] = { d = d, fn = fn } end }
hook = { Add = function() end }
function IsValid(x) return x ~= nil end
SkateGM = { L = {} }
local me = {}
function LocalPlayer() return me end

local function Member(s, gain, pitch, delay) return { s = s, gain = gain or 1, pitch = pitch or 1, delay = delay or 0, gainSpread = 1, pitchRand = 0, delayRand = 0, prob = 1 } end
manifest = {
	banks = {
		Skate_Collisions = {
			count = 10,
			records = {
				["3"] = { gain = 0.5, pitch = 1, pitchRand = 0, groups = {
					{ mode = 1, members = { Member(40) } },
					{ mode = 1, members = { Member(41, 2, 1.1225, 0.05) } },
				} },
				["4"] = { gain = 1, pitch = 1, pitchRand = 0, groups = { { mode = 1, members = { Member(50), Member(51) } } } },
			},
			containers = { ["12"] = { mode = 1, ids = { 4, 3 } } },
		},
	},
	abk = { Brd_Squeaks = { 0, 1 } },
	surfaces = {
		["1"] = { grain = 3, hollow = 0, skid = 0, grind = 1, drag = 0 },
		["6"] = { grain = 5, hollow = 1, skid = 1, grind = 8, drag = 2 },
	},
	grainNames = { ["3"] = "asphalt_smooth", ["5"] = "wood_ramp" },
	grains = {
		asphalt_smooth_hard = { max_kmh = 65, bezier = { 0, 0.33, 0.66, 1 } },
		asphalt_rough_hard = { max_kmh = 60, bezier = { 0, 0.33, 0.66, 1 } },
	},
	collision = {},
}
dofile("../../addon/skategm/lua/skategm/cl_sound.lua")
local S = SkateGM
local S3 = S.S3

check("installed: the Skate 3 set is on", S3.M ~= nil and S3.On())
convars.skategm_sound_set = "1"
check("the setting on Garry's Mod: off", not S3.On())
convars.skategm_sound_set = "0"

local played = {}
local ent = { EmitSound = function(_, path, level, pitch, vol) played[#played + 1] = { path = path, pitch = pitch, vol = vol } end }
S3.Play(ent, "Skate_Collisions", 3, 1)
check("a record: every group plays one member (the delayed one later)", #played == 1 and played[1].path == "skate3/Skate_Collisions/40.wav" and #delayed == 1 and delayed[1].d == 0.05)
check("... the record's gain times the member's", math.abs(played[1].vol - 0.5) < 1e-6)
delayed[1].fn()
check("... the member's pitch ratio as Source pitch", played[2].path == "skate3/Skate_Collisions/41.wav" and played[2].pitch == 112 and played[2].vol == 1)

played, delayed = {}, {}
S3.Play(ent, "Skate_Collisions", 12, 1)
S3.Play(ent, "Skate_Collisions", 12, 1)
check("a container: one of its records, in turn (mode 1)", played[1].path:find("/5%d%.wav") ~= nil and played[2].path == "skate3/Skate_Collisions/40.wav")
played = {}
S3.Play(ent, "Skate_Collisions", 4, 1)
S3.Play(ent, "Skate_Collisions", 4, 1)
check("a group in turn: each member once before repeating", played[1].path ~= played[2].path)

check("rolling, no surface reported: the default surface's grain", S3.RollPath(me, 0) == "skate3/grains/asphalt_smooth_hard/0.wav")
check("... faster: a higher band", S3.RollPath(me, 52.49 * 12) ~= "skate3/grains/asphalt_smooth_hard/0.wav")
check("... flat out: the top band", S3.RollPath(me, 52.49 * 40) == "skate3/grains/asphalt_smooth_hard/5.wav")
S.pose = { audioWheel0 = 0, audioWheel1 = 6 }
check("on wood (tag 6, no hard grain made): falls back to asphalt", S3.RollPath(me, 0) == "skate3/grains/asphalt_rough_hard/0.wav")
check("... and it's hollow", S3.Surface(me).hollow == 1)
check("another skater: the default surface, whatever my wheels report", S3.Surface({}).hollow == 0)

local looks = {}
BOARD = { client = { LookFor = function(k) return looks[k] end } }
local rider = { GetNW2String = function() return "" end }
looks[rider] = { rollSound = "urethane.wav", rollChosen = false }
check("standard rolling sound: the Skate 3 set rolls on its own", S.RollSoundFor(rider, true) == nil and S.RollSoundFor(rider) == "urethane.wav")
looks[rider] = { rollSound = "metal.wav", rollChosen = true }
check("a rolling sound chosen: it's used with either set", S.RollSoundFor(rider, true) == "metal.wav")
BOARD = nil

installed = false
check("addon missing: not loaded", not S3.Load() and not S3.On())
