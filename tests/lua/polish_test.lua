dofile("gmock.lua")
local ME = { EntIndex = function() return 2 end }
function LocalPlayer() return ME end
surface = setmetatable({ PlaySound = function() end }, { __index = surface })
local cues = true
function CreateClientConVar() return { GetBool = function() return cues end } end
SERVER, CLIENT = nil, true
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
if not SKATEGM_MODES.polish then dofile("../../addon/skategm/lua/skategm_modes/cl_polish.lua") end
local M = SKATEGM_MODES
local P = M.polish
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local mode = M.Register({ id = "polishtest", title = "Polish test" })
local function count(name) local n = 0 for _, p in ipairs(P.played or {}) do if p == name then n = n + 1 end end return n end
P.played = {}
P.Observe(mode, { phase = "lobby" }, { phase = "countdown", timeLeft = 3 }, 0)
for t = 0.01, 2.99, 0.05 do P.Think(t) end
check("a countdown: a beep for each of 3, 2, 1", count("beep") == 3)
P.Observe(mode, { phase = "countdown" }, { phase = "turn", timeLeft = 8, active = 5 }, 3)
check("... and a go when it starts", count("go") == 1)
for t = 3, 10.9, 0.05 do P.Think(t) end
check("someone else's timed turn: no ticks for me", count("tick") == 0)
P.Observe(mode, { phase = "between" }, { phase = "turn", timeLeft = 8, active = 2 }, 20)
check("my turn: a cue and a YOUR TURN flash", count("turn") == 1 and P.flash and P.flash.text == "YOUR TURN")
for t = 20, 27.95, 0.05 do P.Think(t) end
check("its last five seconds tick, once each", count("tick") == 5)
P.Observe(mode, { phase = "turn" }, { phase = "results" }, 30)
check("the results: a sound", count("results") == 1)
P.Observe(mode, { phase = "lobby", players = { {} } }, { phase = "lobby", players = { {}, {} } }, 40)
check("someone joins the lobby: a blip", count("join") == 1)
P.Fade(50)
check("moved to the start: a fade", P.fadeAt == 50)
cues = false
P.played = {}
P.Observe(mode, { phase = "lobby" }, { phase = "countdown", timeLeft = 3 }, 60)
P.Think(60.1)
check("cues switched off: nothing", #P.played == 0)
cues = true
P.watch = {}
P.Observe(mode, { phase = "turn" }, { phase = "results", timeLeft = 15 }, 100)
check("a results screen says when the lobby's back", P.ResultsLine(103.2) == "back to the lobby in 12")
P.pops = {}
P.Observe(mode, { phase = "turn", players = { { ent = 5, name = "Bob", total = 100 }, { ent = 2, name = "Me", total = 0 } } },
	{ phase = "between", players = { { ent = 5, name = "Bob", total = 1350 }, { ent = 2, name = "Me", total = 0 } } }, 110)
check("someone scores: a +N pops over them (only them)", #P.pops == 1 and P.pops[1].ent == 5 and P.pops[1].text == "+1,250")
P.pops = {}
P.Observe(mode, { phase = "lobby", players = { { ent = 5, total = 0 } } }, { phase = "countdown", players = { { ent = 5, total = 0 } } }, 111)
check("no pop when nothing was scored", #P.pops == 0)
local st = { phase = "turn", active = 5, nextUp = 2, players = { { ent = 5, name = "Bob" }, { ent = 2, name = "Me" }, { ent = 7, name = "Cat" } } }
local q, mine = P.QueueLine(mode, st)
check("I'm next: YOU'RE UP NEXT", q == "YOU'RE UP NEXT" and mine == true)
st.nextUp = 7
check("someone else is next: their name", P.QueueLine(mode, st) == "next up: Cat")
st.phase = "lobby"
check("no queue line in the lobby", P.QueueLine(mode, st) == nil)
mode.state = { phase = "turn", active = 5, live = 420, players = { { ent = 5, name = "Bob", total = 1000 }, { ent = 2, name = "Me", total = 0 } } }
check("watching the active player: this turn's score", P.ScoreLine(5) == "this turn: 420")
mode.state.active = 7
check("watching someone else: their score", P.ScoreLine(5) == "score: 1,000")
mode.state = { phase = "lobby", placed = { pos = { 1, 2, 3 }, yaw = 90 } }
check("a lobby with a placed start: its beam is drawn", #P.PlacedStarts(200) == 1)
mode.state = { phase = "countdown", placed = { pos = { 1, 2, 3 }, yaw = 90 } }
check("... until the game begins", #P.PlacedStarts(200) == 0)
mode.state = { phase = "idle" }
