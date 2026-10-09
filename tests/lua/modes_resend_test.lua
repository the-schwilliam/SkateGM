dofile("gmock.lua")
local sent = {}
util = { AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }
net = { Start = function() end, WriteString = function(t) sent[#sent + 1] = t end, Broadcast = function() end, Receive = function() end, Send = function() end }
hook = { Add = function() end }
timer = { Simple = function() end }
function IsValid(x) return x ~= nil end
SkateGM = { API = { Allowed = function() return true end } }
SERVER = true
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local mode = SKATEGM_MODES.Register({ id = "resendtest", title = "Resend test" })
mode:Broadcast({ phase = "countdown", timeLeft = 3 }, 100)
local first = sent[#sent]
mode:RunThink(101.2)
local again = sent[#sent]
check("a game's state is sent again a second later (so lobbies stay listed)", again ~= first)
local decoded = type(again) == "string" and util.JSONToTable(again) or again
check("... with its clock counted on: 3 s left then, 1.8 s now (not 3 again)", math.abs((decoded.timeLeft or 0) - 1.8) < 1e-6)
check("... and the state kept as it was for the next resend", first.timeLeft == 3 or (type(first) == "table" and first.timeLeft == 3))
mode:RunThink(102.4)
decoded = sent[#sent]
check("next resend: 0.6 s left", math.abs((decoded.timeLeft or 0) - 0.6) < 1e-6)
mode:RunThink(105)
check("never below zero", sent[#sent].timeLeft == 0)
