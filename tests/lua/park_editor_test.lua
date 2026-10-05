dofile("gmock.lua")
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
scripted_ents = { Register = function() end }
local partFiles = {}
for _, f in ipairs({ "bank", "deck", "flat_bar", "funbox", "half_pipe", "kicker", "launch_ramp", "ledge", "manual_pad", "quarter_pipe", "spine", "stairs" }) do partFiles[#partFiles + 1] = f .. ".lua" end
-- the parts folder, and two GMod saves (one of this map, one of another)
local saveMaps = { ["saves/mine.gms"] = "sgm_warehouse", ["saves/other.gms"] = "gm_flatgrass" }
file = {
	Find = function(pattern) if pattern:find("^saves/") then return { "mine.gms", "other.gms" } end return partFiles end,
	Open = function(path) local map = saveMaps[path] if not map then return nil end
		return { Seek = function() end, ReadLine = function() return map .. "\n" end, Close = function() end } end,
}
game = { SinglePlayer = function() return true end, GetMap = function() return "sgm_warehouse" end }
steamworks = {
	GetList = function(sort, tags, _, _, _, _, cb) steamworks.asked = { sort = sort, tags = tags } cb({ results = { "111", "222" }, totalresults = 2 }) end,
	FileInfo = function(id, cb) cb({ title = "Park " .. id, ownername = "someone" }) end,
	DownloadUGC = function(id, cb) cb("cache/" .. id .. ".gma") end,
}
function include(f) dofile("../../addon/skategm/lua/" .. f) end
function AddCSLuaFile() end
function IsValid(x) return x ~= nil and (type(x) ~= "table" or not x.IsValid or x:IsValid()) end
LerpVector = function(t, a, b) return a + (b - a) * t end
LerpAngle = function(t, a, b) return Angle(a.p + (b.p - a.p) * t, a.y + (b.y - a.y) * t, 0) end
local clock = 0
RealTime = function() return clock end

-- what the editor sends the server
local sent = {}
local current
net = {
	Start = function(name) current = { name = name } end,
	WriteBool = function(v) current[#current + 1] = v end,
	WriteString = function(v) current[#current + 1] = v end,
	WriteVector = function(v) current[#current + 1] = v end,
	WriteFloat = function(v) current[#current + 1] = v end,
	WriteAngle = function(v) current[#current + 1] = v end,
	WriteEntity = function(v) current[#current + 1] = v end,
	SendToServer = function() sent[#sent + 1] = current end,
	Receive = function() end,
}
local function lastSent(name) for i = #sent, 1, -1 do if sent[i].name == name then return sent[i] end end end
local commands = {}
RunConsoleCommand = function(...) commands[#commands + 1] = { ... } end

-- the world: a floor at z 0 and the parts on it (a trace hits a part's box first)
local world = {}
local P
local function Part(id, pos, yaw)
	local e = { SkateGMPart = true, PartId = id, pos = pos, ang = Angle(0, yaw, 0) }
	function e:IsValid() return true end
	function e:GetPos() return self.pos end
	function e:GetAngles() return self.ang end
	function e:SetNoDraw(v) self.hidden = v end
	world[#world + 1] = e
	return e
end
ents = { FindInSphere = function() return world end, GetAll = function() return world end }
util.TraceLine = function(t)
	local d = t.endpos - t.start
	local filtered = {}
	for _, f in ipairs(t.filter or {}) do filtered[f] = true end
	for step = 0, 400 do
		local p = t.start + d * (step / 400)
		for _, e in ipairs(world) do
			if not filtered[e] then
				local sh = P.Shape(P.Get(e.PartId))
				local l = P.Turn(p - e.pos, -e.ang.y)
				if l.x >= sh.mins.x and l.x <= sh.maxs.x and l.y >= sh.mins.y and l.y <= sh.maxs.y and l.z >= 0 and l.z <= sh.maxs.z then
					return { Hit = true, HitPos = Vector(p.x, p.y, p.z), HitNormal = Vector(0, 0, 1), Entity = e }
				end
			end
		end
		if p.z <= 0 then return { Hit = true, HitPos = Vector(p.x, p.y, 0), HitNormal = Vector(0, 0, 1) } end
	end
	return { Hit = false }
end

-- the add-on's API, and a controller
local pad = { buttons = 0, lx = 0, ly = 0, rx = 0, ry = 0, lt = 0, rt = 0 }
local calls = {}
SkateGM = { API = {
	View = function() return { origin = Vector(0, 0, 100), angles = Angle(10, 0, 0) } end,
	Freeze = function(on) calls.freeze = on end,
	BlockInput = function(on) calls.block = on end,
	SetView = function(fn) calls.view = fn end,
	TeleportTo = function(pos, yaw) calls.teleport = { pos, yaw } end,
	Pad = function() return pad end,
} }
SKATEGM_MODES = { menu = { open = false } }
local me = { EyePos = function() return Vector() end, EyeAngles = function() return Angle() end }
function LocalPlayer() return me end

CLIENT, SERVER = true, false
dofile("../../addon/skategm/lua/autorun/skategm_parts_load.lua")
P = SKATEGM_PARTS
local ED = P.editor
local B = ED.BUTTONS

local now = 0
local function frame(buttons)
	pad.buttons = buttons or 0
	now = now + 0.05
	clock = now
	SKATEGM_UI.Think(now, 0.05)
end
local function press(...)
	local mask = 0
	for _, b in ipairs({ ... }) do mask = bit.bor(mask, b) end
	frame(mask)
	frame(0)
end

-- LB + B: in
frame(B.LB)
frame(bit.bor(B.LB, B.B))
frame(0)
check("LB + B puts me in the park editor", ED.active == true)
check("... my skater waits (frozen, no input, the editor's camera)", calls.freeze == true and calls.block == true and type(calls.view) == "function")
check("... and the server hears I'm editing", lastSent("skategm_editor_state") and lastSent("skategm_editor_state")[1] == true)
check("... the controller is the editor's meanwhile (no other screen opens)", SKATEGM_UI.IsOpen("editor"))

local function legend()
	local t = {}
	for _, r in ipairs(ED.Legend()) do if r.text then t[#t + 1] = (r.lit and "" or "~") .. table.concat(r.keys, "+") .. " " .. r.text end end
	return table.concat(t, "|")
end
check("legend with nothing selected: X chooses a part, LB + B goes back", legend():find("X Choose a part", 1, true) and legend():find("LB+B Back to skating", 1, true) and not legend():find("A Place", 1, true))

-- X: the parts menu, by spawn menu group, and the park page
press(B.X)
local labels = {}
local function Rows() local m = ED.menu return SKATEGM_UI.List.Rows(m[#m]), m[#m] end
for _, r in ipairs(Rows()) do labels[#labels + 1] = r.label end
local joined = table.concat(labels, ",")
check("X opens the parts menu, by group, with a Park page", ED.menu ~= nil and joined:find("Ramps", 1, true) and joined:find("Platforms", 1, true) and joined:find("Bowls & pipes", 1, true) and labels[#labels] == "Park")

-- choose Platforms > the 96 high deck
local function choose(label)
	for _ = 1, 40 do
		local rows, page = Rows()
		local row = rows[page.sel]
		if row and (row.label == label or (row.def and row.def.id == label)) then return press(B.A) end
		press(B.DOWN)
	end
end
choose("Platforms")
check("A opens a group", ED.menu and ED.menu[#ED.menu].title == "Platforms")
choose("deck_96x128")
do
	local def = P.Get("quarter_pipe_128x256")
	local o1, a1, fov, s1 = ED.PreviewCamera(def, 0, 1.6)
	local _, _, _, s2 = ED.PreviewCamera(def, 1, 1.6)
	local sh = P.Shape(def)
	local r = (sh.maxs - sh.mins):Length() / 2
	check("the preview camera sees the whole part and it turns slowly", o1:Length() > r * 1.5 and a1.p > 0 and (s2.y - s1.y) == ED.PREVIEW_SPIN)
end
check("A on a part picks it and closes the menu", ED.menu == nil and ED.selected and ED.selected.id == "deck_96x128")

-- a quarter pipe already there; aim at the floor a little off its deck edge
local qp = Part("quarter_pipe", Vector(0, 0, 0), 0)
local back = P.Shape(P.Get("quarter_pipe")).maxs.x
ED.cam.pos, ED.cam.ang = Vector(back + 64 + 50, 12, 400), Angle(90, 0, 0)
ED.yaw = 10
frame(0)
local g = ED.ghost
local dmin = P.Shape(P.Get("deck_96x128")).mins.x
check("the ghost snaps to the quarter pipe's deck edge from further than the physgun's 40", g and g.joined ~= nil and math.abs(g.pos.x + P.Turn(Vector(dmin, 0, 0), g.yaw).x - back) < 0.05 and math.abs(g.pos.y) < 0.05)
check("legend while placing: A names the part, turning shown", legend():find("A Place Deck", 1, true) and legend():find("LEFT+RIGHT Turn it", 1, true))
press(B.A)
local placed = lastSent("skategm_editor_place")
check("A places it where the ghost is", placed and placed[1] == "deck_96x128" and (placed[2] - g.pos):Length() < 0.01 and math.abs(placed[3] - g.yaw) < 0.01)

-- snapping off: the ghost stays where I aim, turned in my steps
press(B.UP)
frame(0)
check("D-pad up turns snapping off: the ghost sits where I aim", ED.snap == false and ED.ghost and not ED.ghost.joined and (ED.ghost.pos - ED.aim.pos):Length() < 0.01)
local yaw0 = ED.ghost.yaw
press(B.LEFT)
frame(0)
check("D-pad left turns it a step", math.abs(((ED.ghost.yaw - yaw0) % 360) - ED.TURN_STEP) < 0.01)
press(B.UP)

-- B drops the selection; Y picks up the part I aim at, A puts it down
press(B.B)
check("B lets go of the selected part", ED.selected == nil)
ED.cam.pos, ED.cam.ang = Vector(0, 0, 400), Angle(90, 0, 0)
frame(0)
check("aiming at a part finds it", ED.aim and ED.aim.ent == qp)
check("legend aiming at a part: pick up and remove lit", legend():find("|Y Pick up", 1, true) and legend():find("|DOWN Remove", 1, true))
press(B.Y)
check("legend while moving: A puts it down, B puts it back", legend():find("A Put it down", 1, true) and legend():find("B Put it back", 1, true))
check("Y picks it up (hidden where it was, a ghost follows the aim)", ED.carry and ED.carry.ent == qp and qp.hidden == true)
ED.cam.pos = Vector(-500, 300, 400)
frame(0)
local aimed = ED.aim.pos
press(B.A)
local moved = lastSent("skategm_editor_move")
check("A moves it there", moved and moved[1] == qp and (moved[2] - aimed):Length() < 0.01 and math.abs(aimed.x + 500) < 10 and not ED.carry and qp.hidden == false)

-- D-pad down removes the part I aim at
ED.cam.pos = Vector(0, 0, 400)
frame(0)
press(B.DOWN)
check("D-pad down removes the part I aim at", lastSent("skategm_editor_remove") and lastSent("skategm_editor_remove")[1] == qp)

-- the park page: Garry's Mod's own saves
press(B.X)
choose("Park")
check("the Park page opens", ED.menu and ED.menu[#ED.menu].title == "Park")
local function goRow(label)
	for _ = 1, 20 do
		local rows, page = Rows()
		if rows[page.sel].label == label then return end
		press(B.DOWN)
	end
end
goRow("Save the park")
press(B.A)
local c = commands[#commands]
check("Save the park makes a Garry's Mod save", c and c[1] == "gm_save")
goRow("Load one of my saves")
press(B.A)
local rows = Rows()
check("my saves: only this map's", #rows == 1 and rows[1].label == "mine")
press(B.A)
c = commands[#commands]
check("A loads it", c and c[1] == "gm_load" and c[2] == "saves/mine.gms")
press(B.B)
check("B goes back to the Park page", ED.menu[#ED.menu].title == "Park")
goRow("Workshop saves for this map")
press(B.A)
rows = Rows()
check("the Workshop's saves of this map, by title", steamworks.asked.tags[2] == "sgm_warehouse" and rows[2] and rows[2].label == "Park 111" and rows[3].label == "Park 222")
press(B.A)
Rows()
check("the first row switches to the newest", steamworks.asked.sort == "latest")
press(B.DOWN)
press(B.A)
c = commands[#commands]
check("A downloads one and loads it", c and c[1] == "gm_load" and c[2] == "cache/111.gma")
press(B.X)

-- LB + B: back on the board, under the camera, facing its way
ED.cam.pos, ED.cam.ang = Vector(300, -200, 500), Angle(20, 135, 0)
frame(B.LB)
frame(bit.bor(B.LB, B.B))
frame(0)
check("LB + B again: back to skating", not ED.active and calls.freeze == false and calls.block == false and calls.view == nil)
check("... set down on the ground under the camera, facing its way", calls.teleport and math.abs(calls.teleport[1].x - 300) < 0.01 and math.abs(calls.teleport[1].y + 200) < 0.01 and calls.teleport[2] == 135)
check("... the server hears it, and the controller is free again", lastSent("skategm_editor_state")[1] == false and not SKATEGM_UI.Busy())

-- not with a minigame menu open
SKATEGM_UI.Take("minigames", {})
frame(B.LB)
frame(bit.bor(B.LB, B.B))
frame(0)
check("LB + B does nothing while the minigame menu is open", not ED.active)
SKATEGM_UI.Give("minigames")

-- stopping skating while editing leaves the editor where it is
frame(B.LB)
frame(bit.bor(B.LB, B.B))
frame(0)
calls.teleport = nil
SkateGM.API.Pad = function() return nil end
frame(0)
check("stopping skating closes the editor (without moving the skater)", not ED.active and calls.teleport == nil)

local playing = true
SKATEGM_MODES.Playing = function() return playing end
check("no park editor while my minigame is on", ED.Allowed() == false)
playing = false
check("... allowed again after it", ED.Allowed() == true)
