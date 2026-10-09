---------------------------------------------------------------------------
-- Settings > Style: Skate 3's Create-a-Skater style - stance (regular /
-- goofy), animation style (Standard, Loose, Aggressive, OG, Mike Carroll),
-- posture, and the four D-pad gestures (taunts). Convars, handed to the
-- engine with skategm.SetStyle (needs a gm_skategm with SetStyle).
---------------------------------------------------------------------------
local UI = SKATEGM_UI
local SET = UI and UI.settings
if not SET then return end
local List = UI.List

local STYLE = SKATEGM_STYLE or {}
SKATEGM_STYLE = STYLE

-- { shown name, engine style name }. OG is the engine's "Gonzo" set (the
-- third Create-a-Skater style, GetCACSettings 0=none, 1=Loose, 2=Gonzo, 3=Aggressive).
STYLE.STYLES = {
	{ "Standard", "" },
	{ "Loose", "Loose" },
	{ "Aggressive", "Aggressive" },
	{ "OG", "Gonzo" },
	{ "Mike Carroll", "MikeCarroll" },
}
STYLE.POSTURES = { "Default", "Stiff", "Slouch", "Buff" }
-- the engine's 37 gestures, in its table order (0-based in the engine)
STYLE.GESTURES = {
	"Air guitar", "Airplane", "Boxing", "Bruce Lee", "Check the time", "Devil horns", "Double guns",
	"Dunno", "Finger wag", "Fists", "Bicep flex", "Flip the table", "Fonz 'eh'", "Freedom", "Fist up",
	"Getaway", "Get outta here", "Handcuffs", "High pump", "Low pump", "Rewind", "Peace", "Point",
	"Raise the roof", "Shaka", "Shrug", "Point to the sky", "Snap", "Soul arch", "Spock", "Surf's up",
	"Swing high", "Swing low", "Throw arms", "Thumbs down", "Wings", "Yard sale",
}
STYLE.DIRS = { { "up", "D-pad up", 0 }, { "down", "D-pad down", 1 }, { "left", "D-pad left", 2 }, { "right", "D-pad right", 3 } }

local cvStance = CreateClientConVar("skategm_stance", "0", true, false, "0 = regular (left foot forward), 1 = goofy", 0, 1)
local cvStyle = CreateClientConVar("skategm_style", "1", true, false, "Skating style: 1 Standard, 2 Loose, 3 Aggressive, 4 OG, 5 Mike Carroll", 1, #STYLE.STYLES)
local cvPosture = CreateClientConVar("skategm_posture", "0", true, false, "Posture: 0 default, 1 stiff, 2 slouch, 3 buff", 0, 3)
local cvGesture = {}
for _, d in ipairs(STYLE.DIRS) do
	cvGesture[d[1]] = CreateClientConVar("skategm_gesture_" .. d[1], tostring(d[3]), true, false,
		"Gesture on " .. d[2] .. " (0-36)", 0, #STYLE.GESTURES - 1)
end

local sent
function STYLE.Apply(force)
	if not (skategm and skategm.SetStyle) then return false end
	local s = STYLE.STYLES[math.Clamp(cvStyle:GetInt(), 1, #STYLE.STYLES)]
	-- (the engine's natural-stance value: 0 rides regular, 1 goofy)
	local args = { cvStance:GetInt() == 1 and 1 or 0, s[2], cvPosture:GetInt(),
		cvGesture.up:GetInt(), cvGesture.down:GetInt(), cvGesture.left:GetInt(), cvGesture.right:GetInt() }
	local sig = table.concat(args, " ")
	if sig == sent and not force then return true end
	sent = sig
	skategm.SetStyle(unpack(args))
	return true
end

for _, name in ipairs({ "skategm_stance", "skategm_style", "skategm_posture", "skategm_gesture_up", "skategm_gesture_down", "skategm_gesture_left", "skategm_gesture_right" }) do
	cvars.AddChangeCallback(name, function() timer.Simple(0, STYLE.Apply) end, "skategm_style")
end
-- how long a landing must hold before its tricks score (a bail or run-out
-- within it loses them)
local cvSettle = CreateClientConVar("skategm_landing_settle", "0.25", true, false, "Seconds a landing must hold before the tricks score", 0, 3)
local settleSent
local function ApplySettle()
	if not (skategm and skategm.SetLandingSettle) then return end
	local v = cvSettle:GetFloat()
	if v == settleSent then return end
	settleSent = v
	skategm.SetLandingSettle(v)
end
cvars.AddChangeCallback("skategm_landing_settle", function() timer.Simple(0, ApplySettle) end, "skategm_style")

-- Skate 3's difficulty: the game's own physics_mode tables (board control,
-- auto-spin, grind lock, bails), switched while riding
STYLE.DIFFICULTIES = { "Easy", "Normal", "Hardcore" }
local cvDifficulty = CreateClientConVar("skategm_difficulty", "0", true, false, "Skate 3 difficulty: 0 easy, 1 normal, 2 hardcore", 0, 2)
local difficultySent
local function ApplyDifficulty()
	if not (skategm and skategm.SetDifficulty) then return end
	local v = cvDifficulty:GetInt()
	if v == difficultySent then return end
	difficultySent = v
	skategm.SetDifficulty(v)
end
cvars.AddChangeCallback("skategm_difficulty", function() timer.Simple(0, ApplyDifficulty) end, "skategm_style")

-- (the module loads later than this file: keep trying, sending only changes)
timer.Create("skategm_style_apply", 2, 0, function() STYLE.Apply() ApplySettle() ApplyDifficulty() end)

---------------------------------------------------------------------------
-- the page
---------------------------------------------------------------------------
function SET.GesturePage(d)
	local cv = cvGesture[d[1]]
	local page = { title = "Gesture on " .. d[2], rows = {} }
	for i, name in ipairs(STYLE.GESTURES) do
		page.rows[i] = { label = name, mark = function() return cv:GetInt() == i - 1 end,
			run = function() RunConsoleCommand(cv:GetName(), tostring(i - 1)) SET.stack[#SET.stack] = nil end }
		if cv:GetInt() == i - 1 then page.sel = i end
	end
	return page
end

function SET.StylePage()
	local rows = {
		SET.ChoiceRow("Difficulty", "skategm_difficulty", STYLE.DIFFICULTIES, nil, 0),
		SET.ChoiceRow("Stance", "skategm_stance", { "Regular", "Goofy" }, nil, 0),
		SET.ChoiceRow("Style", "skategm_style", (function()
			local n = {}
			for i, s in ipairs(STYLE.STYLES) do n[i] = s[1] end
			return n
		end)()),
		SET.ChoiceRow("Posture", "skategm_posture", STYLE.POSTURES, nil, 0),
		List.Heading("Gestures"),
	}
	for _, d in ipairs(STYLE.DIRS) do
		local row = SET.ChoiceRow(d[2], "skategm_gesture_" .. d[1], STYLE.GESTURES, nil, 0)
		row.page = function() return SET.GesturePage(d) end
		row.aText = "Pick from the list"
		rows[#rows + 1] = row
	end
	if not (skategm and skategm.SetStyle) then
		rows[#rows + 1] = { label = "This gm_skategm can't set the style", sub = "needs the rebuilt module with skategm.SetStyle" }
	end
	return { title = "Style", rows = rows }
end
