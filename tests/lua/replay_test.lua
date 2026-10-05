dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
local files = {}
file = {
	CreateDir = function() end,
	Write = function(p, d) files[p] = d end,
	Read = function(p) return files[p] end,
	Find = function(pat)
		local out = {}
		for p in pairs(files) do local name = p:match("^skategm/replays/(.+%.txt)$") if name then out[#out + 1] = name end end
		return out
	end,
}
local hooks, cmds = {}, {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
concommand = { Add = function(n, f) cmds[n] = f end }
game = { GetMap = function() return "tl_skatepark" end }
function LerpVector(f, a, b) return a + (b - a) * f end
function IsValid(x) return x ~= nil end
local ME = {}
function LocalPlayer() return ME end
local said = {}
local api = { frozen = false, blocked = false, pad = { buttons = 0 } }
SKATEGM_MODES = { menu = { open = false, Close = function(self) end } }
SkateGM = {
	phase = "on", remote = {}, BONES = { "TRAJECTORY", "HIPS", "SPINE", "HEAD" },
	ClipProxy = function(ply) return { ghost = true, of = ply } end,
	ForgetSkater = function(key) SkateGM.remote[key] = nil SkateGM.forgot = key end,
	API = {
		Freeze = function(on) api.frozen = on end,
		BlockInput = function(on) api.blocked = on end,
		SetView = function(fn) api.view = fn end,
		Pad = function() return api.pad end,
		Say = function(t) said[#said + 1] = t end,
	},
}
local S = SkateGM
local clock = 0
RealTime = function() return clock end
function ScrW() return 1600 end
function ScrH() return 900 end
dofile("../../addon/skategm/lua/skategm/cl_replay.lua")
local UI = SKATEGM_UI
local function Think(t, dt) clock = t UI.Think(t, dt) end
local R = S.replay

local clip = {}
for i = 0, 30 do clip[#clip + 1] = { t = i * 0.05, P = { HIPS = Vector(i * 10, 0, 40), HEAD = Vector(i * 10, 0, 70) }, state = i < 20 and "PhysicsGround" or "PhysicsAir", trick = i == 25 and "Kickflip" or nil } end
local P = R.PoseAt(clip, 0.125)
check("the pose between two frames is blended", math.abs(P.HIPS.x - 25) < 1e-6)
check("before the start / after the end: the first / last frame", R.PoseAt(clip, -1).HIPS.x == 0 and R.PoseAt(clip, 99).HIPS.x == 300)

check("nothing recorded yet: says so", R.Open(nil) == false and said[#said]:find("nothing to replay"))
check("open: the clip plays back", R.Open(clip, "Last 15 seconds") and R.on and R.on.playing)
check("... my skater waits, the pad drives the viewer, my live skater is hidden", api.frozen and api.blocked and S.hideSelf and UI.IsOpen("replay"))
local think = hooks["Think/skategm_replay"]
Think(1, 0.5)
check("playing: time runs at full speed, a ghost of me in the pose", math.abs(R.on.t - 0.5) < 1e-6 and S.remote[R.on.key] ~= nil and math.abs(R.on.P.HIPS.x - 100) < 1e-6)
check("... and a camera on it (chase, before any keyframe)", api.view and api.view(nil, nil, 90) and api.view(nil, nil, 90).origin ~= nil and R.Current().mode == "chase")
local function press(b) api.pad = { buttons = b } Think(2, 0) api.pad = { buttons = 0 } Think(2.01, 0) end
local function lbPress(b) api.pad = { buttons = R.PAD.LB } Think(2, 0) api.pad = { buttons = R.PAD.LB + b } Think(2.01, 0) api.pad = { buttons = 0 } Think(2.02, 0) end
press(R.PAD.A)
check("A pauses", not R.on.playing)
Think(3, 1)
check("paused: time stands still", math.abs(R.on.t - 0.5) < 1e-6)
press(R.PAD.RIGHT)
check("paused, D-pad right steps forward a tenth of a second", math.abs(R.on.t - 0.6) < 1e-6)
press(R.PAD.LEFT)
check("... D-pad left back", math.abs(R.on.t - 0.5) < 1e-6)
local fov = R.Current().fov
press(R.PAD.UP)
check("D-pad up narrows the FOV, down widens it", R.Current().fov == fov - R.FOV_STEP)
press(R.PAD.DOWN) press(R.PAD.DOWN)
check("... and back past where it was", R.Current().fov == fov + R.FOV_STEP)
for _, mode in ipairs({ "tripod", "free", "chase" }) do
	press(R.PAD.X)
	check("X: camera " .. mode, R.Current().mode == mode and api.view(nil, nil, 90).origin ~= nil)
end

R.on.t = 0.2
press(R.PAD.Y)
check("Y sets a keyframe here, with this camera", #R.on.edit.keys == 1 and R.on.edit.keys[1].mode == "chase" and math.abs(R.on.edit.keys[1].t - 0.2) < 1e-6 and R.on.manual == nil)
R.on.t = 1.0
local chaseFar = R.CopyCam(R.Current())
chaseFar.dist, chaseFar.fov = 400, 100
R.on.manual = chaseFar
press(R.PAD.Y)
R.on.t = 1.3
R.on.manual = R.NewCam("tripod", clip, 1.3, 60)
press(R.PAD.Y)
local keys = R.on.edit.keys
check("three keyframes, in time order", #keys == 3 and keys[1].t < keys[2].t and keys[2].t < keys[3].t)
local mid = R.KeyedCam(keys, 0.6)
check("between two chase keyframes the camera glides: zoom and FOV in between", mid.mode == "chase" and mid.dist > keys[1].dist and mid.dist < 400 and mid.fov > keys[1].fov and mid.fov < 100)
check("... eased: slow at the ends", math.abs(R.KeyedCam(keys, 0.25).dist - keys[1].dist) < 0.1 * (400 - keys[1].dist))
check("a new mode is a hard cut: chase right up to the tripod keyframe", R.KeyedCam(keys, 1.29).mode == "chase" and R.KeyedCam(keys, 1.29).dist == 400 and R.KeyedCam(keys, 1.3).mode == "tripod")
check("before the first keyframe: the first keyframe's camera", R.KeyedCam(keys, 0).t == keys[1].t)
R.on.t = 1.0 press(R.PAD.Y)
check("Y again at a keyframe replaces it", #R.on.edit.keys == 3)
R.on.t = 0.6 R.on.manual = nil R.on.playing = true
lbPress(R.PAD.RIGHT)
check("LB + D-pad right jumps to the next keyframe, and pauses there", math.abs(R.on.t - 1.0) < 1e-6 and not R.on.playing)
lbPress(R.PAD.LEFT)
check("LB + D-pad left to the previous one", math.abs(R.on.t - 0.2) < 1e-6)
press(R.PAD.RB)
check("RB: shake for this camera, any mode (light, then strong, then off)", R.Current().shake == 1 and R.Current().mode == "chase")
press(R.PAD.RB)
check("... strong", R.Current().shake == 2)
press(R.PAD.Y)
check("... kept in the keyframe", R.edit_shake == nil and R.on.edit.keys[1].shake == 2)
local still = R.CopyCam(R.on.edit.keys[1])
still.shake = 0
local o1, a1 = R.EvalCam(still, clip, 0.3)
local o2, a2 = R.EvalCam(R.on.edit.keys[1], clip, 0.3)
check("... and it shakes the view (same place, turned a little)", (o1 - o2):Length() < 1e-6 and (math.abs(a1.p - a2.p) + math.abs(a1.y - a2.y)) > 0.01)
check("... fading to the next keyframe's shake when the mode is the same", math.abs(R.KeyedCam(R.on.edit.keys, 0.6).shake - 1) < 0.99 and R.KeyedCam(R.on.edit.keys, 0.6).shake > 0)
R.on.t = 0.95
lbPress(R.PAD.Y)
check("LB + Y deletes the nearest keyframe", #R.on.edit.keys == 2 and math.abs(R.on.edit.keys[2].t - 1.3) < 1e-6)
R.SetKey(R.on.edit.keys, chaseFar, 1.0)
R.on.t = 0.6
R.on.manual = R.CopyCam(chaseFar)
press(R.PAD.LEFT)
check("scrubbing keeps the camera I'm setting up (it isn't reset to the keyframes)", R.on.manual ~= nil and R.on.manual.dist == chaseFar.dist)
R.on.manual = nil
press(R.PAD.LEFT)
check("... and with no change of mine, scrubbing shows the keyed camera", R.on.manual == nil)
api.pad = { buttons = 0, rx = 1 } Think(2.5, 0.1) api.pad = { buttons = 0 } Think(2.51, 0)
check("a stick turns the camera here: changed, not keyed until Y", R.on.manual ~= nil and #R.on.edit.keys == 3)

R.on.t = 1.26
Think(6, 0)
check("the trick name shows at its moment", R.on.frame and R.on.frame.trick == "Kickflip")
api.pad = { buttons = R.PAD.LB, lx = 1 } Think(6.1, 0.1) api.pad = { buttons = R.PAD.LB } Think(6.2, 0.1) api.pad = { buttons = 0 } Think(6.21, 0)
local ta, tb = R.Trim()
check("LB + left stick moves the start in (and shows that frame)", ta > 0.25 and tb == R.Duration(clip) and math.abs(R.on.t - ta) < 1e-6)
api.pad = { buttons = R.PAD.LB, rx = -1 } Think(6.3, 0.1) api.pad = { buttons = 0 } Think(6.31, 0)
ta, tb = R.Trim()
check("LB + right stick moves the end in", tb < R.Duration(clip) and math.abs(R.on.t - tb) < 1e-6 and #R.on.edit.keys == 3)
check("... and the sticks don't turn the camera meanwhile", R.on.manual == nil or R.on.manual.mode ~= nil)
R.on.t = ta
press(R.PAD.LEFT)
check("scrubbing stays inside the trim", math.abs(R.on.t - ta) < 1e-6)
press(R.PAD.A)
Think(6.5, 5)
check("playing stops at the trimmed end", math.abs(R.on.t - tb) < 1e-6 and not R.on.playing)
press(R.PAD.START)
check("Start opens the menu (and pauses)", R.on.menu ~= nil and not R.on.playing)
local menuRows = UI.List.Rows(R.on.menu[#R.on.menu])
local function row(label) for i, r in ipairs(menuRows) do if r.label == label then return r, i end end end
check("... speed, filter, delete / clear keyframes, save, export", row("Playback speed") and row("Filter") and row("Clear all keyframes") and row("Save to my replays") and row("Export video"))
row("Playback speed").change(-2)
check("speed: down to a quarter", R.speeds[R.on.speed] == 0.25)
row("Filter").change(1)
check("filter: black and white", R.on.edit.filter == "bw")
row("Save to my replays").run()
local saved = R.Saved()
check("save: to data/skategm/replays, says where", #saved == 1 and saved[1]:find("^tl_skatepark_") and said[#said]:find("garrysmod/data/skategm/replays/", 1, true))
local loaded, meta = R.Load(saved[1])
check("... loads back the same clip", loaded and #loaded == #clip and math.abs(loaded[11].P.HIPS.x - 100) < 0.06 and loaded[26].trick == "Kickflip" and meta.map == "tl_skatepark")
check("... with its keyframes, filter, trim and shake", #meta.edit.keys == 3 and meta.edit.keys[3].mode == "tripod" and meta.edit.filter == "bw" and math.abs(meta.edit.keys[2].dist - 400) < 0.01
	and math.abs(meta.edit.trim[1] - ta) < 0.001 and math.abs(meta.edit.trim[2] - tb) < 0.001 and meta.edit.keys[1].shake == 2)
R.on.edit.filter = "vhs"
menuRows = UI.List.Rows(R.on.menu[#R.on.menu])
row("Save").run()
check("saving again overwrites the same file", #R.Saved() == 1 and select(2, R.Load(saved[1])).edit.filter == "vhs")
check("saved files can't be read from outside the folder", R.Load("../../cfg/config.cfg") == nil)
press(R.PAD.B)
check("B closes the menu first", R.on and R.on.menu == nil)

video = { Record = function(cfg)
	local w = { cfg = cfg, frames = 0 }
	function w:AddFrame(dt) self.frames = self.frames + 1 self.dt = dt end
	function w:Finish() self.done = true end
	function w:SetRecordSound(on) self.sound = on end
	video.last = w
	return w
end }
vgui = nil
local frames = math.ceil((tb - ta) * 30) + 1
check("export: starts a .webm recording of the trimmed part", R.Export(30, 1) and video.last.cfg.container == "webm" and video.last.cfg.fps == 30 and R.exporting.frames == frames)
local capture = hooks["PreDrawHUD/skategm_replay_export"]
local steps = 0
while R.exporting and steps < 200 do Think(10 + steps * 0.01, 0.01) capture() steps = steps + 1 end
check("... a frame per step, each 1/30 s, from the trim start to its end, then finished", video.last.done and video.last.frames == frames and math.abs(video.last.dt - 1 / 30) < 1e-9 and not video.last.sound)
check("... and the done popup shows", R.done ~= nil and R.done.name:find("^skategm_tl_skatepark_"))
local opened
skategm = { OpenFolder = function(n) opened = n return true end }
press(R.PAD.X)
check("... X opens the videos folder", opened == "videos" and R.done ~= nil)
press(R.PAD.A)
check("... A closes it", R.done == nil and R.on ~= nil)

local muxed
local keepSkategm = skategm
skategm = { MuxWebm = function(a, b, c, off) muxed = { a, b, c, off } return true end, OpenFolder = function() return true end }
local writers = {}
local record = video.Record
video.Record = function(cfg) local w = record(cfg) writers[#writers + 1] = w return w end
check("export with sound: first the picture, smooth (locked frame rate, no sound)", R.Export(30, 1, true) and writers[1].cfg.lockfps == true and not writers[1].sound and writers[1].cfg.name:find("_picture$"))
steps = 0
while R.exporting and steps < 4000 do Think(20 + steps * 0.02, 0.02) capture() steps = steps + 1 end
local base = writers[1].cfg.name:gsub("_picture$", "")
check("... then the sound in real time (small picture, audio on)", writers[2] and writers[2].cfg.lockfps == false and writers[2].sound == true and writers[2].cfg.width == 320 and writers[2].cfg.name == base .. "_sound")
check("... the sound pass carries real frame times and ends at the trim end", writers[2].done and math.abs(writers[2].dt - 0.02) < 1e-9 and math.abs(writers[2].frames - (math.ceil((tb - ta) / 0.02) + 1)) <= 2)
check("... then they're merged into one file under the plain name", muxed and muxed[1] == base .. "_picture" and muxed[2] == base .. "_sound" and muxed[3] == base and muxed[4] >= 0 and R.done and R.done.name == base)
video.Record = record
skategm = keepSkategm
press(R.PAD.A)

local function hintTexts() local t = {} for _, h in ipairs(R.Hints()) do t[#t + 1] = h.text end return table.concat(t, "|") end
check("the stick controls are in the hint bar", hintTexts():find("Zoom", 1, true) ~= nil and hintTexts():find("Shake", 1, true) ~= nil)
R.on.lbHeld = true
check("holding LB: the hint bar shows the LB controls (trim, keyframes, delete)", hintTexts():find("Trim start", 1, true) and hintTexts():find("Delete nearest keyframe", 1, true) and not hintTexts():find("Zoom", 1, true))
R.on.lbHeld = false
R.on.edit.filter = "film"
R.on.dirty = true
press(R.PAD.B)
check("unsaved changes: B only warns", R.on ~= nil and R.on.note.text:find("unsaved", 1, true))
press(R.PAD.A) press(R.PAD.A)
press(R.PAD.B)
check("... another button in between: B warns again", R.on ~= nil)
local key = R.on.key
press(R.PAD.B)
check("B: back to skating, everything as it was", R.on == nil and not api.frozen and not api.blocked and not S.hideSelf and api.view == nil and S.forgot == key and not UI.Busy())
local screen = SKATEGM_MODES.menu.SCREENS.replays()
local rows = screen.rows()
check("the Replays list: the last 15 seconds, then saved ones", rows[1].label == "Last 15 seconds" and #rows == 2)
check("... each saying which folder it's in", rows[2].sub:find("skategm/replays", 1, true) ~= nil)
S.RecentClip = function() return clip end
rows[2].run()
check("picking a saved one opens it with its keyframes", R.on and #R.on.clip == #clip and #R.on.edit.keys == 3 and R.on.file == saved[1])
R.Close()
files["skategm/replays/gm_construct_2026.txt"] = R.Encode(clip, { map = "gm_construct", date = "x" })
check("replays from other maps aren't listed", #SKATEGM_MODES.menu.SCREENS.replays().rows() == 2)
check("... and won't open", R.Open(clip, "x", { map = "gm_construct" }) == false and said[#said]:find("gm_construct", 1, true))
R.Open(clip, "again")
S.phase = "off"
api.pad = nil
Think(7, 0)
check("leaving Skater mode closes the viewer", R.on == nil)

local floorZ = 0
util = util or {}
util.TraceLine = function(t)
	if t.endpos.z < floorZ and t.start.z >= floorZ then
		local f = (t.start.z - floorZ) / (t.start.z - t.endpos.z)
		return { Hit = true, HitPos = t.start + (t.endpos - t.start) * f, HitNormal = Vector(0, 0, 1) }
	end
	return { Hit = false }
end
local tri = R.NewCam("tripod", clip, 0.5)
local startZ = tri.pos.z
for _ = 1, 50 do R.Steer(tri, { ry = -1, buttons = 0 }, 0.1, clip, 0.5) end
check("tripod: right stick down raises it (looks down on the skater)", tri.pos.z > startZ)
for _ = 1, 100 do R.Steer(tri, { ry = 1, buttons = 0 }, 0.1, clip, 0.5) end
local target = R.Target(clip, 0.5)
local below = math.deg(math.asin(math.Clamp((target.z - tri.pos.z) / (tri.pos - target):Length(), -1, 1)))
check("... stick up lowers it to look up, but never more than " .. R.TRIPOD_BELOW .. " degrees under the skater", below <= R.TRIPOD_BELOW + 0.5 and tri.pos.z >= floorZ)
floorZ = 45
local o = R.EvalCam(tri, clip, 0.5)
check("... and never inside the ground: the camera stays above it", o.z >= floorZ)
floorZ = 0
local VA = getmetatable(Vector(0, 0, 0)).Angle
getmetatable(Vector(0, 0, 0)).Angle = function(v) local ang = VA(v) ang.p = ang.p % 360 return ang end
local up = R.NewCam("tripod", clip, 0.5)
up.pos = R.Target(clip, 0.5) + Vector(-100, 0, 30)
for _ = 1, 40 do R.Steer(up, { ry = -1, buttons = 0 }, 0.1, clip, 0.5) end
local t5 = R.Target(clip, 0.5)
check("tripod climbs well above the skater (Garry's Mod's 0-360 pitch, no kick back down)", up.pos.z - t5.z > 100)
local fr = R.NewCam("free", clip, 0.5, 75, { origin = t5 + Vector(-100, 0, -40), angles = Angle(340, 0, 0) })
R.Steer(fr, { rx = 0.5, buttons = 0 }, 0.1, clip, 0.5)
check("free camera started looking up keeps looking up (not flipped to straight down)", fr.ang.p < 0 and fr.ang.p > -30)
getmetatable(Vector(0, 0, 0)).Angle = VA
local ch = R.NewCam("chase", clip, 0.5)
for _ = 1, 100 do R.Steer(ch, { ry = 1, buttons = 0 }, 0.1, clip, 0.5) end
check("chase: stick up looks up, stopping just under the skater", ch.pitch == R.CHASE_PITCH_MIN)
floorZ = 49
local co = R.EvalCam(ch, clip, 0.5)
check("... and it's kept out of the ground too", co.z >= floorZ)
floorZ = -1e9
local drawn, colourMods = 0, 0
local mods = {}
DrawColorModify = function(t) colourMods = colourMods + 1 mods[#mods + 1] = t end
DrawMaterialOverlay = function() drawn = drawn + 1 end
Material = function(p) return { IsError = function() return false end } end
cam = cam or {}
cam.Start2D, cam.End2D = function() end, function() end
surface.CreateFont = function() end
draw.SimpleText = draw.SimpleText or function() end
local okAll = true
for _, f in ipairs(R.FILTERS) do
	local ok = pcall(R.DrawFilter, f.id, 1.3, 1600, 900, { date = "2026-10-04 12:00" })
	okAll = okAll and ok
end
check("every filter draws (" .. #R.FILTERS .. ": none, b&w, sepia, old film, VHS, contrast, fisheye)", okAll and colourMods == 7 and drawn == 1)
mods = {}
R.DrawFilter("sepia", 0, 1600, 900, {})
check("sepia: grey first, then tinted warm (not greyed again: unlike black & white)", #mods == 2 and mods[1]["$pp_colour_colour"] == 0
	and mods[2]["$pp_colour_colour"] == 1 and mods[2]["$pp_colour_addr"] > mods[2]["$pp_colour_addb"])
check("fisheye widens the view", R.FilterFov("fisheye", 75) > 75 and R.FilterFov("bw", 75) == 75)
check("handheld shake is the same at the same moment (so exports match)", R.Shake(2.5, 1).p == R.Shake(2.5, 1).p and R.Shake(2.5, 1).p ~= R.Shake(2.7, 1).p)

local rclip = {}
for i = 0, 20 do rclip[#rclip + 1] = { t = i * 0.05, P = { HIPS = Vector(i, 0, 40) }, rocket = (i >= 5 and i <= 9) or i == 15 or nil } end
local text = R.Encode(rclip, { map = "m", date = "d" })
local back = R.Decode(text)
local same = #back == #rclip
for i, f in ipairs(back) do same = same and (f.rocket == rclip[i].rocket) end
check("rocket boosts are saved (as spans) and come back on the same frames", same and select(2, text:gsub("\nrocket ", "")) == 2)
local flames = {}
S.RocketFlames = function(P, now, key, quiet) flames[#flames + 1] = { P = P, key = key, quiet = quiet } end
S.RecentClip = function() return rclip end
if R.on then R.Close() end
R.Open(rclip, "rocket")
api.pad = { buttons = 0 }
if R.on then
	R.on.t = 0.3 R.on.playing = false
	Think(20, 0.016)
	check("the replay shows the rocket's fire on boosted frames (no sound)", #flames > 0 and flames[#flames].quiet == true)
	local n = #flames
	R.on.t = 0.6
	Think(20.1, 0.016)
	check("... and not on the others", #flames == n)
	R.Close()
else
	check("replay opens for the rocket test", false)
end

local function free(t, x, yaw) return { t = t, mode = "free", fov = 75, shake = 0, pos = Vector(x, 0, 100), ang = Angle(0, yaw, 0) } end
local path = { free(0, 0, 0), free(1, 100, 10), free(2, 200, 20), free(3, 300, 30) }
local function at(t) return R.KeyedCam(path, t) end
local speedAt1 = (at(1.05).pos.x - at(0.95).pos.x) / 0.1
check("free camera through 3+ keyframes flows through the middle ones (no stop)", speedAt1 > 90 and speedAt1 < 110)
check("... and passes exactly through each keyframe", math.abs(at(1).pos.x - 100) < 1e-6 and math.abs(at(2).pos.x - 200) < 1e-6)
check("... turning smoothly too (yaw keeps going at a middle key)", (at(2.05).ang.y - at(1.95).ang.y) / 0.1 > 9)
check("... still easing in at the first and out at the last keyframe", (at(0.05).pos.x - at(0).pos.x) / 0.05 < 20 and (at(3).pos.x - at(2.95).pos.x) / 0.05 < 20)
local two = { free(0, 0, 0), free(1, 100, 0) }
local f = 0.25
check("two keyframes: the same ease in / out as before", math.abs(R.KeyedCam(two, f).pos.x - 100 * f * f * (3 - 2 * f)) < 1e-6)
local wrap = { free(0, 0, 170), free(1, 100, -170), free(2, 200, -150) }
local y = R.KeyedCam(wrap, 0.5).ang.y
check("yaw across 180 takes the short way", math.abs(math.NormalizeAngle(y - 180)) < 15)
