local S = SkateGM

---------------------------------------------------------------------------
-- Replays: the last 15 s of your skating, always recorded (S.Record). LB +
-- RB opens the list (the last 15 s, then saved clips of this map); the
-- editor plays it back as a ghost of you while your skater waits.
--   A play / pause   D-pad left / right scrub   D-pad up / down FOV
--   X camera (chase, tripod, free)   RB shake   Y set keyframe
--   LB + left / right stick trim   LB + D-pad previous / next keyframe
--   LB + Y delete the nearest keyframe   Start menu   B back
-- Keyframes: a camera mode, its position and FOV at a time; the same mode
-- glides from one keyframe to the next, a new mode cuts (cl_replay_cam).
-- Filters: cl_replay_fx. Video export: cl_replay_export.
-- Saved clips: garrysmod/data/skategm/replays/*.txt
---------------------------------------------------------------------------
local R = { speeds = { 0.25, 0.5, 1 }, SPEED_NAMES = { "Quarter speed", "Half speed", "Full speed" } }
S.replay = R
R.DIR = "skategm/replays/"
R.MAX_LIST = 20
R.SCRUB, R.SCRUB_PAUSED, R.FOV_STEP = 1, 0.1, 5

-- (the shared controller UI: skategm_ui/cl_pad.lua)
if not (SKATEGM_UI and SKATEGM_UI.pad) then include("skategm_ui/cl_pad.lua") end
local UI = SKATEGM_UI
local PAD = UI.pad.B
R.PAD = PAD
local Dead = UI.pad.Dead

if file and file.CreateDir then
	file.CreateDir("skategm")
	file.CreateDir("skategm/replays")
end

---------------------------------------------------------------------------
-- a clip: { { t, P, state, trick, rocket }, ... }, t from 0
---------------------------------------------------------------------------
function R.Duration(clip) return clip and #clip > 0 and clip[#clip].t or 0 end

-- the pose at time t, blended between the two frames around it
function R.PoseAt(clip, t)
	local n = #clip
	if n == 0 then return nil end
	if t <= clip[1].t then return clip[1].P, clip[1] end
	if t >= clip[n].t then return clip[n].P, clip[n] end
	local lo, hi = 1, n
	while hi - lo > 1 do
		local mid = math.floor((lo + hi) / 2)
		if clip[mid].t <= t then lo = mid else hi = mid end
	end
	local a, b = clip[lo], clip[hi]
	local f = (t - a.t) / math.max(b.t - a.t, 1e-6)
	local P = {}
	for name, v in pairs(a.P) do
		local w = b.P[name]
		P[name] = w and (v + (w - v) * f) or v
	end
	return P, f < 0.5 and a or b
end

-- saved as text: a header, then one line a frame: t|state|trick|x,y,z,...
-- in S.BONES order, to a tenth of a unit
function R.Encode(clip, meta, edit)
	local lines = { "skategm replay 1", "map " .. (meta and meta.map or "?"), "date " .. (meta and meta.date or "?") }
	if edit then
		lines[#lines + 1] = "filter " .. (edit.filter or "none")
		if edit.trim then lines[#lines + 1] = string.format("trim %.3f %.3f", edit.trim[1], edit.trim[2]) end
		for _, k in ipairs(edit.keys or {}) do lines[#lines + 1] = R.EncodeKey(k) end
	end
	local from
	for i, f in ipairs(clip) do
		if f.rocket and not from then from = f.t end
		local nxt = clip[i + 1]
		if from and not (nxt and nxt.rocket) then
			lines[#lines + 1] = string.format("rocket %.3f %.3f", from, f.t)
			from = nil
		end
	end
	for _, f in ipairs(clip) do
		local nums = {}
		for _, name in ipairs(S.BONES) do
			local v = f.P[name]
			if v then nums[#nums + 1] = string.format("%.1f,%.1f,%.1f", v.x, v.y, v.z) else nums[#nums + 1] = "" end
		end
		lines[#lines + 1] = string.format("%.3f|%s|%s|%s", f.t, f.state or "", (f.trick or ""):gsub("[|\n]", " "), table.concat(nums, ";"))
	end
	return table.concat(lines, "\n")
end

function R.Decode(text)
	if type(text) ~= "string" or text:sub(1, 16) ~= "skategm replay 1" then return nil end
	local clip, meta = {}, {}
	local edit = { filter = "none", keys = {} }
	local rockets = {}
	for line in text:gmatch("[^\n]+") do
		local k, v = line:match("^(%a+) (.*)$")
		if k == "map" or k == "date" then
			meta[k] = v
		elseif k == "filter" then
			edit.filter = R.FILTERS[R.FilterIndex(v)].id
		elseif k == "trim" then
			local a, b = v:match("^([%d%.%-]+) ([%d%.%-]+)$")
			if a then edit.trim = { tonumber(a), tonumber(b) } end
		elseif k == "rocket" then
			local a, b = v:match("^([%d%.%-]+) ([%d%.%-]+)$")
			if a then rockets[#rockets + 1] = { tonumber(a) - 0.0005, tonumber(b) + 0.0005 } end
		elseif k == "key" then
			local key = R.DecodeKey(line)
			if key then edit.keys[#edit.keys + 1] = key end
		else
			local t, state, trick, rest = line:match("^([%d%.%-]+)|([^|]*)|([^|]*)|(.*)$")
			if t then
				local P, i = {}, 0
				for part in (rest .. ";"):gmatch("([^;]*);") do
					i = i + 1
					local x, y, z = part:match("^([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)$")
					local name = S.BONES[i]
					if x and name then P[name] = Vector(tonumber(x), tonumber(y), tonumber(z)) end
				end
				if P.HIPS then clip[#clip + 1] = { t = tonumber(t), P = P, state = state ~= "" and state or nil, trick = trick ~= "" and trick or nil } end
			end
		end
	end
	if #clip < 2 then return nil end
	for _, f in ipairs(clip) do
		for _, s in ipairs(rockets) do
			if f.t >= s[1] and f.t <= s[2] then f.rocket = true break end
		end
	end
	table.sort(edit.keys, function(a, b) return a.t < b.t end)
	if edit.trim then
		local dur = clip[#clip].t
		local a = math.Clamp(edit.trim[1], 0, dur)
		edit.trim = { a, math.Clamp(edit.trim[2], a, dur) }
	end
	meta.edit = edit
	return clip, meta
end

function R.MapName() return (game and game.GetMap and game.GetMap()) or "map" end

function R.SafeName(name)
	return type(name) == "string" and not name:find("..", 1, true) and not name:find("[/\\]") and name:find("%.txt$") ~= nil
end

function R.Save(clip, edit, name, meta)
	if not (clip and #clip > 1 and file and file.Write) then return nil end
	if not R.SafeName(name) then
		name = (R.MapName():gsub("[^%w_%-]", "_")) .. "_" .. os.date("%Y-%m-%d_%H-%M-%S") .. ".txt"
		meta = nil
	end
	meta = meta or { map = R.MapName(), date = os.date("%Y-%m-%d %H:%M") }
	file.Write(R.DIR .. name, R.Encode(clip, meta, edit))
	return name
end

-- where saved clips are, as the player would find it on their PC
function R.FolderText()
	local full = util and util.RelativePathToFull and util.RelativePathToFull("data/" .. R.DIR)
	if full and full ~= "" then return (full:gsub("\\", "/")) end
	return "garrysmod/data/" .. R.DIR
end

function R.MapOf(name)
	local text = file.Read(R.DIR .. name, "DATA")
	return type(text) == "string" and text:match("\nmap ([^\n]*)") or nil
end

function R.Saved()
	local files = file and file.Find and file.Find(R.DIR .. "*.txt", "DATA") or {}
	table.sort(files, function(a, b) return a > b end)
	local here, out = R.MapName(), {}
	for _, f in ipairs(files) do
		if #out >= R.MAX_LIST then break end
		if R.MapOf(f) == here then out[#out + 1] = f end
	end
	return out
end

function R.Load(name)
	if not R.SafeName(name) then return nil end
	return R.Decode(file.Read(R.DIR .. name, "DATA"))
end


include("skategm/cl_replay_cam.lua")
include("skategm/cl_replay_fx.lua")
include("skategm/cl_replay_export.lua")

---------------------------------------------------------------------------
-- the editor
---------------------------------------------------------------------------
local function API() return S.API end

function R.Open(clip, title, meta, fileName)
	if not (clip and #clip > 1) then
		S.API.Say("nothing to replay yet: skate for a few seconds first", true)
		return false
	end
	if meta and meta.map and meta.map ~= R.MapName() then
		S.API.Say("that replay was recorded on " .. meta.map .. ": load that map to watch it", true)
		return false
	end
	if R.on then R.Close() end
	local edit = meta and meta.edit or { filter = "none", keys = {} }
	R.on = { clip = clip, meta = meta or { map = R.MapName(), date = os.date("%Y-%m-%d %H:%M") }, file = fileName,
		title = title or "Last 15 seconds", t = 0, playing = true, speed = 3, edit = edit,
		key = S.ClipProxy(LocalPlayer()) }
	local v = R.on
	edit.trim = edit.trim or { 0, R.Duration(clip) }
	v.t = edit.trim[1]
	if #edit.keys == 0 then v.manual = R.NewCam("chase", clip, v.t) end
	S.hideSelf = true
	if S.SetHidden then S.SetHidden("replay", true) end
	UI.Take("replay", { press = R.Press, think = R.Think, close = R.Close }, function(_, _, fov) return R.View(fov) end)
	return true
end

function R.Close()
	local v = R.on
	if not v then return end
	if R.exporting then R.ExportFinish(false) end
	R.CloseDone()
	R.on = nil
	S.ForgetSkater(v.key)
	S.hideSelf = nil
	if S.SetHidden then S.SetHidden("replay", false) end
	UI.Give("replay")
end

function R.Feed(now)
	local v = R.on
	local P, frame = R.PoseAt(v.clip, v.t)
	if not P then return end
	S.remote[v.key] = { snaps = { { t = now - 1, P = P }, { t = now + 1, P = P } }, last = now, state = frame and frame.state }
	v.P, v.frame = P, frame
	if frame and frame.rocket and S.RocketFlames then pcall(S.RocketFlames, P, now, v.key, true) end
end

function R.Current()
	local v = R.on
	return v.manual or R.KeyedCam(v.edit.keys, v.t) or R.NewCam("chase", v.clip, v.t)
end

function R.Editable()
	local v = R.on
	if not v.manual then v.manual = R.CopyCam(R.Current()) end
	return v.manual
end

function R.ComputeView()
	local v = R.on
	local origin, angles, fov = R.EvalCam(R.Current(), v.clip, v.t)
	v.view = { origin = origin, angles = angles, fov = R.FilterFov(v.edit.filter, fov) }
end

function R.View()
	local v = R.on
	if not (v and v.view) then return nil end
	return { origin = v.view.origin, angles = v.view.angles, fov = v.view.fov }
end

function R.Trim()
	local v = R.on
	return v.edit.trim[1], v.edit.trim[2]
end

function R.Scrub(dt)
	local v = R.on
	local a, b = R.Trim()
	v.t = math.Clamp(v.t + dt, a, b)
end

R.TRIM_RATE, R.TRIM_MIN = 3, 0.5

function R.TrimSteer(pad, dt)
	local v = R.on
	local Dead = UI.pad.Dead
	local lx, rx = Dead(pad.lx), Dead(pad.rx)
	if lx == 0 and rx == 0 then return end
	local dur = R.Duration(v.clip)
	local a, b = R.Trim()
	a = math.Clamp(a + lx * R.TRIM_RATE * dt, 0, math.max(0, b - R.TRIM_MIN))
	b = math.Clamp(b + rx * R.TRIM_RATE * dt, math.min(dur, a + R.TRIM_MIN), dur)
	v.edit.trim = { a, b }
	v.t = math.Clamp(v.t, a, b)
	if lx ~= 0 then v.t = a end
	if rx ~= 0 then v.t = b end
	v.dirty = true
end

function R.NearestKey()
	local v = R.on
	local best, bi
	for i, k in ipairs(v.edit.keys) do
		if not best or math.abs(k.t - v.t) < math.abs(best.t - v.t) then best, bi = k, i end
	end
	return bi, best
end

function R.DeleteNearest()
	local v = R.on
	local i, k = R.NearestKey()
	if not i then return R.Note("no keyframes to delete") end
	table.remove(v.edit.keys, i)
	v.dirty = true
	if #v.edit.keys == 0 then v.manual = R.CopyCam(k) else v.manual = nil end
	R.Note(string.format("keyframe at %.1f s deleted", k.t))
end

function R.CycleShake()
	local cam = R.Editable()
	cam.shake = (math.floor((cam.shake or 0) + 0.5) + 1) % (#R.SHAKE_AMOUNTS + 1)
	R.Note("shake: " .. R.SHAKE_NAMES[cam.shake])
end

function R.JumpKey(dir)
	local v = R.on
	local keys = v.edit.keys
	local pick
	if dir > 0 then
		for _, k in ipairs(keys) do if k.t > v.t + R.KEY_SNAP then pick = k break end end
	else
		for i = #keys, 1, -1 do if keys[i].t < v.t - R.KEY_SNAP then pick = keys[i] break end end
	end
	if not pick then return false end
	v.t, v.manual, v.playing = pick.t, nil, false
	return true
end

function R.NextMode()
	local v = R.on
	local cur = R.Current()
	local i = 1
	for n, m in ipairs(R.MODES) do if m == cur.mode then i = n end end
	local mode = R.MODES[i % #R.MODES + 1]
	v.manual = R.NewCam(mode, v.clip, v.t, cur.fov, v.view, cur.shake)
end

function R.SetKeyHere()
	local v = R.on
	R.SetKey(v.edit.keys, R.Current(), v.t)
	v.manual = nil
	v.dirty = true
	R.Note("keyframe set at " .. string.format("%.1f", v.t) .. " s")
end

function R.Note(text) R.on.note = { text = text, t = RealTime and RealTime() or 0 } end

R.LEAVE_WINDOW = 3

function R.Press(btn, buttons)
	local v = R.on
	if R.ExportPress(btn) then return end
	if v.menu then
		if UI.List.Input(v.menu, btn) == "empty" then v.menu = nil end
		return
	end
	local now = RealTime and RealTime() or 0
	if btn ~= PAD.B then v.leaveAt = nil end
	if bit.band(buttons or 0, PAD.LB) ~= 0 then
		if btn == PAD.LEFT then R.JumpKey(-1)
		elseif btn == PAD.RIGHT then R.JumpKey(1)
		elseif btn == PAD.Y then R.DeleteNearest()
		end
		return
	end
	local a, b = R.Trim()
	if btn == PAD.A then
		if not v.playing and v.t >= b then v.t = a end
		v.playing = not v.playing
	elseif btn == PAD.B then
		if v.dirty and not (v.leaveAt and now - v.leaveAt < R.LEAVE_WINDOW) then
			v.leaveAt = now
			return R.Note("unsaved changes: B again to leave without saving (Start > Save keeps them)")
		end
		R.Close()
	elseif btn == PAD.LEFT then R.Scrub(-(v.playing and R.SCRUB or R.SCRUB_PAUSED))
	elseif btn == PAD.RIGHT then R.Scrub(v.playing and R.SCRUB or R.SCRUB_PAUSED)
	elseif btn == PAD.UP or btn == PAD.DOWN then
		local cam = R.Editable()
		cam.fov = math.Clamp(cam.fov + (btn == PAD.UP and -R.FOV_STEP or R.FOV_STEP), R.FOV_MIN, R.FOV_MAX)
	elseif btn == PAD.X then R.NextMode()
	elseif btn == PAD.Y then R.SetKeyHere()
	elseif btn == PAD.RB then R.CycleShake()
	elseif btn == PAD.START then R.OpenMenu()
	end
end

function R.Think(pad, now, dt)
	local v = R.on
	if not v then return end
	if R.exporting then
		R.ExportThink(dt)
	elseif not R.done then
		local a, b = R.Trim()
		if v.playing then
			v.t = math.max(v.t, a) + dt * R.speeds[v.speed]
			if v.t >= b then v.t = b v.playing = false end
		end
		v.lbHeld = pad ~= nil and bit.band(pad.buttons or 0, PAD.LB) ~= 0
		if not v.menu and pad then
			if v.lbHeld then
				R.TrimSteer(pad, dt)
			else
				local cam = v.manual and v.manual or R.CopyCam(R.Current())
				if R.Steer(cam, pad, dt, v.clip, v.t) then v.manual = cam end
			end
		end
	end
	R.Feed(now)
	R.ComputeView()
end

---------------------------------------------------------------------------
-- the menu (Start)
---------------------------------------------------------------------------
function R.MenuPage()
	local v = R.on
	local List = UI.List
	local filters = {}
	for i, f in ipairs(R.FILTERS) do filters[i] = f.name end
	return { title = "Replay", rows = function()
		local _, nearest = R.NearestKey()
		local rows = {
			List.Choice("Playback speed", R.SPEED_NAMES, function() return v.speed end, function(i) v.speed = i end),
			List.Choice("Filter", filters, function() return R.FilterIndex(v.edit.filter) end, function(i) v.edit.filter = R.FILTERS[i].id v.dirty = true end),
			{ label = nearest and string.format("Delete the nearest keyframe (%.1f s)", nearest.t) or "Delete the nearest keyframe",
				disabled = nearest == nil, run = function() R.DeleteNearest() end },
			{ label = "Reset the trim", sub = string.format("now %.1f - %.1f s", R.Trim()), run = function()
				v.edit.trim = { 0, R.Duration(v.clip) }
				v.dirty = true
			end },
			{ label = v.clearArmed and "Press A again to clear them all" or "Clear all keyframes", disabled = #v.edit.keys == 0, run = function()
				if not v.clearArmed then v.clearArmed = true return end
				v.clearArmed = nil
				v.manual = R.CopyCam(R.Current())
				v.edit.keys = {}
				v.dirty = true
				R.Note("all keyframes cleared")
			end },
			{ label = v.file and "Save" or "Save to my replays", sub = "keeps the keyframes and filter", run = function() R.SaveEdit() end },
			{ label = "Export video", sub = R.CanExport() and "renders it to a .webm file" or "not available in this copy of Garry's Mod",
				disabled = not R.CanExport(), page = R.ExportPage },
		}
		return rows
	end }
end

function R.ExportPage()
	local v = R.on
	local List = UI.List
	v.exportFps, v.exportQuality, v.exportSound = v.exportFps or 1, v.exportQuality or 2, v.exportSound or 1
	local fps, qualities = {}, {}
	for i, f in ipairs(R.EXPORT_FPS) do fps[i] = f .. " fps" end
	for i, q in ipairs(R.EXPORT_QUALITY) do qualities[i] = q[1] end
	return { title = "Export video", rows = {
		List.Choice("Frame rate", fps, function() return v.exportFps end, function(i) v.exportFps = i end),
		List.Choice("Quality", qualities, function() return v.exportQuality end, function(i) v.exportQuality = i end),
		List.Choice("Sound", R.EXPORT_SOUND, function() return v.exportSound end, function(i) v.exportSound = i end),
		{ label = "Start export", sub = v.exportSound == 2 and "the picture first, then the sound in real time (takes about twice as long)"
			or string.format("%.1f s of replay (the trimmed part)", select(2, R.Trim()) - R.Trim()), run = function()
			R.Export(R.EXPORT_FPS[v.exportFps], v.exportQuality, v.exportSound == 2)
		end },
	} }
end

function R.OpenMenu()
	local v = R.on
	v.playing = false
	v.clearArmed = nil
	v.menu = {}
	UI.List.Push(v.menu, R.MenuPage())
end

function R.SaveEdit()
	local v = R.on
	local name = R.Save(v.clip, v.edit, v.file, v.file and v.meta or nil)
	if not name then return end
	v.file = name
	v.dirty = nil
	v.saved, v.savedAt = name, RealTime and RealTime() or 0
	S.API.Say("replay saved: " .. R.FolderText() .. name)
end

---------------------------------------------------------------------------
-- on screen
---------------------------------------------------------------------------
function R.Fonts(h)
	if R.fontsAt == h then return end
	R.fontsAt = h
	surface.CreateFont("skategm_replay_big", { font = "Roboto", size = math.max(22, math.floor(h * 0.045)), weight = 800, antialias = true })
	surface.CreateFont("skategm_replay_mid", { font = "Roboto", size = math.max(16, math.floor(h * 0.03)), weight = 700, antialias = true })
	surface.CreateFont("skategm_replay_small", { font = "Roboto", size = math.max(12, math.floor(h * 0.02)), weight = 600, antialias = true })
end

function R.PaintTimeline(w, h, x0, x1, y)
	local v = R.on
	local dur = R.Duration(v.clip)
	local a, b = R.Trim()
	local function X(t) return x0 + (x1 - x0) * (dur > 0 and t / dur or 0) end
	surface.SetDrawColor(0, 0, 0, 110)
	surface.DrawRect(x0, y, x1 - x0, 8)
	surface.SetDrawColor(0, 0, 0, 200)
	surface.DrawRect(X(a), y, X(b) - X(a), 8)
	surface.SetDrawColor(255, 255, 255, 70)
	surface.DrawRect(X(a), y, X(v.t) - X(a), 8)
	surface.SetDrawColor(255, 200, 70, 255)
	surface.DrawRect(X(a) - 2, y - 8, 4, 24)
	surface.DrawRect(X(b) - 2, y - 8, 4, 24)
	for _, k in ipairs(v.edit.keys) do
		local c = R.MODE_COLOURS[k.mode] or color_white
		local alpha = (k.t < a or k.t > b) and 90 or 255
		surface.SetDrawColor(c.r, c.g, c.b, alpha)
		surface.DrawRect(X(k.t) - 3, y - 6, 6, 20)
	end
	surface.SetDrawColor(255, 255, 255, 255)
	surface.DrawRect(X(v.t) - 1, y - 10, 2, 28)
end

function R.Hints()
	local v = R.on
	if v.lbHeld then
		return {
			{ keys = { "LB", "LS" }, join = "+", text = "Trim start" },
			{ keys = { "LB", "RS" }, join = "+", text = "Trim end" },
			{ keys = { "LB", "LEFT" }, join = "+", text = "Previous keyframe" },
			{ keys = { "LB", "RIGHT" }, join = "+", text = "Next keyframe" },
			{ keys = { "LB", "Y" }, join = "+", text = "Delete nearest keyframe" },
		}
	end
	local cam = R.Current()
	local rows = {
		{ keys = { "A" }, text = v.playing and "Pause" or "Play" },
		{ keys = { "LEFT", "RIGHT" }, text = "Scrub" },
		{ keys = { "UP", "DOWN" }, text = "FOV" },
	}
	if cam.mode == "free" then
		rows[#rows + 1] = { keys = { "LS" }, text = "Move" }
		rows[#rows + 1] = { keys = { "RS" }, text = "Look" }
		rows[#rows + 1] = { keys = { "LT", "RT" }, text = "Down / up" }
	elseif cam.mode == "tripod" then
		rows[#rows + 1] = { keys = { "LS" }, text = "Move" }
		rows[#rows + 1] = { keys = { "RS" }, text = "Circle" }
		rows[#rows + 1] = { keys = { "LT", "RT" }, text = "Zoom" }
	else
		rows[#rows + 1] = { keys = { "RS" }, text = "Turn around" }
		rows[#rows + 1] = { keys = { "LT", "RT" }, text = "Zoom" }
	end
	rows[#rows + 1] = { keys = { "X" }, text = "Camera" }
	rows[#rows + 1] = { keys = { "RB" }, text = "Shake" }
	rows[#rows + 1] = { keys = { "Y" }, text = "Set keyframe" }
	rows[#rows + 1] = { keys = { "LB" }, text = "Trim, keyframes" }
	rows[#rows + 1] = { keys = { "START" }, text = "Save/Export" }
	rows[#rows + 1] = { keys = { "B" }, text = "Back" }
	return rows
end

function R.Paint(w, h)
	local v = R.on
	if not v then return end
	R.Fonts(h)
	if R.PaintExport(w, h) then return end
	local a, b = R.Trim()
	local x0, x1, y = w * 0.2, w * 0.8, h * 0.78
	R.PaintTimeline(w, h, x0, x1, y)
	local cam = R.Current()
	local filter = R.FILTERS[R.FilterIndex(v.edit.filter)].name
	draw.SimpleText(string.format("%s%s   %.1f s   (%.1f - %.1f)   %sx%s", v.title, v.dirty and " *" or "", v.t - a, a, b, tostring(R.speeds[v.speed]), v.playing and "" or "   (paused)"),
		"skategm_replay_mid", w / 2, y - h * 0.075, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	local c = R.MODE_COLOURS[cam.mode] or color_white
	draw.SimpleText(string.format("Camera: %s   FOV %d   Shake: %s   Filter: %s   Keyframes: %d", R.MODE_NAMES[cam.mode], math.floor(cam.fov + 0.5),
		R.SHAKE_NAMES[math.floor((cam.shake or 0) + 0.5)] or "Off", filter, #v.edit.keys),
		"skategm_replay_small", w / 2, y - h * 0.035, c, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	if v.manual and #v.edit.keys > 0 then
		draw.SimpleText("camera changed: Y sets it as a keyframe here", "skategm_replay_small", w / 2, y + h * 0.03, Color(255, 200, 70), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	end
	UI.pad.Legend(R.Hints(), w, h, "bottom")
	local now = RealTime and RealTime() or 0
	if v.note and now - v.note.t < 2.5 then
		draw.SimpleText(v.note.text, "skategm_replay_mid", w / 2, h * 0.16, Color(120, 220, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	end
	if v.savedAt and now - v.savedAt < 6 then
		draw.SimpleText("Saved: " .. v.saved, "skategm_replay_mid", w / 2, h * 0.2, Color(120, 220, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
		local again = "watch it again from LB + RB > Replays"
		draw.SimpleText("in " .. R.FolderText() .. "  -  " .. UI.pad.T(again), "skategm_replay_small", w / 2, h * 0.2 + h * 0.035, Color(220, 220, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	end
	local trick = v.frame and v.frame.trick
	if trick then draw.SimpleText(trick, "skategm_replay_mid", w / 2, h * 0.08, Color(255, 200, 70), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP) end
	if v.menu then UI.List.Paint(v.menu, w, h, { note = v.note }) end
end

hook.Add("HUDPaint", "skategm_replay", function() R.Paint(ScrW(), ScrH()) end)

---------------------------------------------------------------------------
-- the list (LB + RB), and the console
---------------------------------------------------------------------------
function R.Screen()
	return { title = "Replays", rows = function()
		local rows = { { label = "Last 15 seconds", sub = "watch and edit what you just did", run = function() R.Open(S.RecentClip(), "Last 15 seconds") end } }
		for _, name in ipairs(R.Saved()) do
			rows[#rows + 1] = { label = name:gsub("%.txt$", ""), sub = "saved in " .. R.FolderText(), run = function()
				local clip, meta = R.Load(name)
				if not clip then return S.API.Say("that replay couldn't be read", true) end
				R.Open(clip, name:gsub("%.txt$", ""), meta, name)
			end }
		end
		return rows
	end }
end

local function Register()
	local menu = SKATEGM_MODES and SKATEGM_MODES.menu
	if not menu then return false end
	menu.SCREENS = menu.SCREENS or {}
	menu.SCREENS.replays = R.Screen
	return true
end
if not Register() and hook then hook.Add("Sk8ModesReady", "skategm_replay", Register) end

concommand.Add("skategm_replay", function(_, _, args)
	if args[1] and args[1] ~= "" then
		local name = args[1]:find("%.txt$") and args[1] or (args[1] .. ".txt")
		local clip, meta = R.Load(name)
		if not clip then return S.API.Say("no saved replay called " .. args[1], true) end
		return R.Open(clip, args[1], meta, name)
	end
	if R.on then R.Close() else R.Open(S.RecentClip(), "Last 15 seconds") end
end, nil, "Replay your last 15 seconds (or a saved replay: skategm_replay <name>)")
