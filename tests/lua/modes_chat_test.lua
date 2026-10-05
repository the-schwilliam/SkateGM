dofile("gmock.lua")
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local hooks, shown = {}, {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
concommand = { Add = function() end }
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
chat = { AddText = function(...) local t = { ... } shown[#shown + 1] = t[#t] end }
function ScrW() return 1600 end
function ScrH() return 900 end
CreateClientConVar = function() return { GetInt = function() return 0 end, GetBool = function() return false end, GetFloat = function() return 0 end, GetString = function() return "0" end } end
local padType, keys
SkateGM = { API = { PadType = function() return padType end, KeyboardHints = function() return keys end } }
dofile("../../addon/skategm/lua/skategm_ui/cl_pad.lua")
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
local M = SKATEGM_MODES
local onChat = hooks["ChatText/skategm_modes_buttons"]
local line = "[Snake] Bob is hosting Snake: join with LB + D-pad left"
check("an Xbox pad: the server's chat line shows as sent", onChat(0, "", line, "none") == nil and #shown == 0)
padType = "playstation"
check("a PlayStation pad: shown with its own buttons", onChat(0, "", line, "none") == true and shown[1] == "[Snake] Bob is hosting Snake: join with L1 + D-pad left")
padType, keys = nil, true
check("keyboard: the keys", onChat(0, "", line, "none") == true and shown[2] == "[Snake] Bob is hosting Snake: join with Z + U")
check("players' own chat is left alone", onChat(0, "Bob", "[me] LB + Y", "chat") == nil and M.ChatLine("LB + Y is the map", "none") == nil)
