dofile("gmock.lua")
local sent = {}
util = setmetatable({ TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
net = { Start = function() end, WriteString = function(t) sent[#sent + 1] = t end, SendToServer = function() end, Receive = function() end }
hook = { Add = function() end }
concommand = { Add = function() end }
function IsValid(x) return x ~= nil end
local ME = { EntIndex = function() return 2 end }
local OTHER = { EntIndex = function() return 5 end }
function LocalPlayer() return ME end
SkateGM = { API = { Say = function() end, CanSkate = function() return true end } }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
local M = SKATEGM_MODES
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local mode = M.Register({ id = "rulestest", title = "Rules test" })
local got
mode:Host({ useStart = false, options = { { key = "time", type = "number", default = 60 } }, start = function(v, m) got = v m:Send({ cmd = "create", time = v.time }) end })
check("hosting offers the rocket board and hoverboard switches", #mode.hostDef.options == 3 and mode.hostDef.options[2].key == "_rocket")
mode.hostDef.start({ time = 60, _rocket = false, _hover = true }, mode)
check("... and the create command carries them (on = everyone has it)", sent[#sent].cmd == "create" and sent[#sent].rules.rocket == false and sent[#sent].rules.hover == "on")
check("the rocket choices: off, metered 1 / 3 / 5 s, infinite", #M.ROCKET_CHOICES == 5 and M.ROCKET_CHOICES[1][2] == "off" and M.ROCKET_CHOICES[3][2] == "metered (3s)" and M.ROCKET_CHOICES[5][2] == "infinite")
mode.hostDef.start({ time = 60, _rocket = 3, _hover = false }, mode)
check("metered (3s): everyone has it, with 3 s of fuel", sent[#sent].rules.rocket == "on" and sent[#sent].rules.fuel == 3)
mode.hostDef.start({ time = 60, _rocket = -1, _hover = false }, mode)
check("infinite: everyone has it, no fuel limit", sent[#sent].rules.rocket == "on" and sent[#sent].rules.fuel == nil)
mode.hostDef.start({ time = 60, _rocket = true, _hover = false }, mode)
check("an old preset's switch (on): infinite", sent[#sent].rules.rocket == "on" and sent[#sent].rules.fuel == nil)
mode:Send({ cmd = "join" })
check("... only the create command", sent[#sent].rules == nil)
local forced = M.Register({ id = "rockettest", title = "Rocket test" })
forced:Host({ useStart = false, rocket = "force", options = {}, start = function(v, m) m:Send({ cmd = "create" }) end })
check("a mode that forces the rocket: no rocket switch, rocket forced", #forced.hostDef.options == 1 and (forced.hostDef.start({}, forced) or true) and sent[#sent].rules.rocket == "force")
mode.state = { phase = "playing", rules = { rocket = false, hover = false }, players = { { ent = 2 } } }
check("in a game with the rocket off: no rocket, no hoverboard for me", not M.RocketAllowed(ME) and not M.HoverAllowed(ME))
check("... someone not in it is unaffected", M.RocketAllowed(OTHER) and M.HoverAllowed(OTHER))
mode.state.rules = { rocket = "on", fuel = 3, hover = false }
check("in a game with metered rockets: that game's fuel", M.RocketFuel(ME) == 3)
mode.state.rules = { rocket = "on", hover = false }
check("... infinite rockets: no limit", M.RocketFuel(ME) == nil)
check("... someone not in it: their own setting decides", M.RocketFuel(OTHER) == false)
mode.state.rules = { rocket = false, hover = false }
mode.state.phase = "lobby"
check("... and in the lobby the rules don't apply yet", M.RocketAllowed(ME))
mode.state = { phase = "playing", rules = { rocket = "force", hover = true }, players = { { ent = 2 } } }
check("Rocket Royale style: the rocket is forced on", M.RocketForced(ME) and M.RocketAllowed(ME))
mode.state = { phase = "playing", rules = { rocket = "on", hover = "on" }, players = { { ent = 2 } } }
check("switched on: everyone in the game has the rocket and the hoverboard", M.RocketOn(ME) and M.HoverOn(ME) and not M.RocketForced(ME))
check("... not someone outside the game", not M.RocketOn(OTHER) and not M.HoverOn(OTHER))
local lob = M.Register({ id = "lobbytest", title = "Lobby test", minPlayers = 3 })
lob:LobbyLines(function(st) return { "60 s turns" } end)
local rows = M.LobbyRows(lob, { phase = "lobby", host = 2, players = { { ent = 2, name = "Me" }, { ent = 4, name = "Bob" } }, rules = { rocket = false, hover = true } })
check("every mode's lobby lists who's in, marks the host, adds the mode's settings and rules", #rows.players == 2 and rows.players[1].host and rows.players[1].me
	and rows.lines[1] == "60 s turns" and rows.lines[2] == "no rocket board")
check("... the host waits for enough players", rows.hint == "waiting for 1 more player (2 / 3)")
rows = M.LobbyRows(lob, { phase = "lobby", host = 4, players = { { ent = 2, name = "Me" }, { ent = 4, name = "Bob" }, { ent = 5, name = "Cat" } } })
check("... a player waits for the host", rows.hint == "ready: waiting for Bob to start" and rows.ready)
local inv = M.Register({ id = "invitetest", title = "Invite test" })
inv.seen = { [7] = { st = { phase = "lobby", session = 7, host = 4, players = { { ent = 4 } } }, at = 0 } }
mode.state = nil lob.state = nil forced.state = nil
M.ReceiveInvite("invitetest", "7", "Bob", 0)
check("an invite arrives: active while that game is in its lobby", M.InviteActive() and M.invite.session == 7)
M.AcceptInvite()
check("LB + RT accepts: joins that very game", sent[#sent].cmd == "join" and sent[#sent].session == 7 and M.invite == nil)
M.ReceiveInvite("invitetest", "7", "Bob", 0)
inv.seen[7].st.phase = "playing"
check("the game starts: the invite is gone (and LB + RT with it)", not M.InviteActive() and M.invite == nil)
surface = setmetatable({ SetFont = function() end, GetTextSize = function(t) return #t * 10, 20 end }, { __index = surface })
local long = "board through the hoop: 1 point. You through it too: none"
local wrapped = M.Wrap(long, "f", 300)
local fits = true
for _, l in ipairs(wrapped) do if #l * 10 > 300 then fits = false end end
check("a long lobby line wraps to fit the box, every word kept", #wrapped > 1 and fits and table.concat(wrapped, " ") == long)
check("a short one stays one line", #M.Wrap("2 rounds", "f", 300) == 1)
mode.state = { phase = "countdown", rules = { rocket = "force" }, players = { { ent = 2 } } }
check("a countdown: no rocket (forced or not), nobody builds up speed on the line", not M.RocketAllowed(ME) and not M.RocketForced(ME))
mode.state = { phase = "playing", rules = { rocket = "force" }, players = { { ent = 2 } } }
check("... and it's back at the go", M.RocketAllowed(ME) and M.RocketForced(ME))
mode.state = nil
