# Writing a Skate 3 game mode (minigame)

Game modes are ordinary Garry's Mod add-ons that sit on top of the Skate 3 add-on
(`skategm`). The built-in modes (Race, Own the Spot,
Hot Potato and the rest) use exactly the same framework described here, so they are the
best larger examples. A minimal complete mode is in
[`docs/example_mode/`](example_mode/) ("High Speed": fastest skater in 60 seconds
wins) - copy that folder into `garrysmod/addons/` to try it.

## What the framework does for you

`lua/skategm_modes/sh_modes.lua` (global `SKATEGM_MODES`) gives every mode:

- two network messages (state: server to clients, commands: clients to server),
  with JSON encoding, a size limit and a rate limit (30 commands a second per
  player) on commands;
- an "allowed on this server" switch, `skategm_<id>_allowed` (replicated, archived;
  host and admins change it from the mode's menu);
- a line in the controller's Settings > Advanced (host and admins) to allow or forbid it on the server;
- `!<id> ...` chat commands;
- hooks for think, players joining and leaving, and the mode being turned off.

## Loading

Your add-on's autorun file should check that the Skate 3 add-on is installed,
then load the framework if it isn't loaded yet (load order between add-ons is
not guaranteed):

```lua
-- lua/autorun/mymode_load.lua
if not file.Exists("skategm_modes/sh_modes.lua", "LUA") then return end
if SERVER then
	AddCSLuaFile("skategm_modes/sh_modes.lua")
	AddCSLuaFile("mymode/sh.lua")
	AddCSLuaFile("mymode/cl.lua")
end
if not SKATEGM_MODES or not SKATEGM_MODES.Register then include("skategm_modes/sh_modes.lua") end
include("mymode/sh.lua")
if SERVER then include("mymode/sv.lua") else include("mymode/cl.lua") end
```

## Registering (shared)

```lua
MYMODE = MYMODE or {}
MYMODE.mode = SKATEGM_MODES.Register({
	id = "mymode",            -- letters, digits, _ ; used in names below
	title = "My Mode",        -- shown in the Game modes list
	order = 50,               -- position in that list (built-ins use 1-4)
	-- optional:
	category = "Party",       -- the Host list's group: "Tricks", "Sports", "Arena",
	                          -- "Chaos", "Party", or a new name of your own
	                          -- (listed after those); none = "Other"
	chat = "!mm",             -- chat prefix (default "!" .. id)
	allowed = false,          -- no "allowed on this server" switch
	allowedDefault = false,   -- the switch starts off
	allowedConVar = "name",   -- a different convar name
	netState = "name",        -- different network message names
	netCommand = "name",
	maxCommandBytes = 60000,  -- bigger commands than the default 4 KB
})
```

Registering the same id again (e.g. after a Lua refresh) returns the same mode
object and keeps its handlers. `SKATEGM_MODES.Get(id)` finds a registered mode.
Hooks: `Sk8ModesReady(SKATEGM_MODES)` when the framework first loads,
`Sk8ModeRegistered(mode)` after each registration.

`mode.NET_STATE`, `mode.NET_CMD`, `mode.cvAllowed` and `mode:Allowed()` are
available on both sides.

## Server

```lua
local mode = MYMODE.mode
mode:OnCommand(function(ply, msg) end)  -- msg: the table a client sent
mode:OnThink(function(now) end)         -- every server tick
mode:OnPlayerJoin(function(ply) end)    -- PlayerInitialSpawn
mode:OnPlayerLeave(function(ply) end)   -- PlayerDisconnected
mode:OnDisallowed(function() end)       -- the allowed switch was turned off
mode:Broadcast(stateTable, now)         -- to everyone (also stored as mode.lastState)
mode:SendState(ply, stateTable)         -- to one player (default: the last state)
```

Check `mode:Allowed()` in your command handler before starting anything. The
server has no physics of its own for skaters: the skating happens on each
client. `SKATEGM_MODES.API()` on the server is `SkateGM.API`:

| | |
|---|---|
| `IsSkating(ply)` | the player is in Skater mode |
| `Allowed(ply)` | the player may use Skater mode on this server (`skategm_allow`) |

## Client

```lua
local mode = MYMODE.mode
mode:Send(commandTable)                 -- to the server
mode:OnState(function(state, now) end)  -- the server's state arrived (also mode.state)
mode:OnFrameShift(function(delta) end)  -- infinite maps: your frame moved (a chunk over);
                                        -- move any positions you keep yourself by -delta
                                        -- (messages and states are converted for you)
mode:OnChat(function(words) return true end)  -- "!mymode a b" -> { "a", "b" }; return false to let it through
-- (hosting and joining are on the controller: mode:Host above, LB + D-pad left;
-- the "allowed on this server" switch is in Settings > Advanced for admins)
```

Shared helpers (client): `mode:Say(text, bad)` (a chat line titled with the
mode, in `color` from Register), `mode:Me(state)` (your entry in
`state.players`, matched by `ent`), `mode:IsHost(state)` (`state.host` is you),
`mode:Fonts({ name = { font, fraction of screen height, weight, min size } })`,
`SKATEGM_MODES.Here()` (your skater, or you), `SKATEGM_MODES.CanSkate()`,
`SKATEGM_MODES.Text(text, font, x, y, col, align, shadowOffset)`,
`SKATEGM_MODES.Ring(centre, radius, col, segments)`. Server: `mode:Tell(ply, text)`
(nil ply = everyone), `SKATEGM_MODES.Allowed(ply)`, `SKATEGM_MODES.Skating(ply)`.

### The controller menu (LB + D-pad left / right)

Skaters host and join minigames from the pad: LB + D-pad left opens
Minigames (Host / Join; Join lists each hosted game, "Hosted by <name>");
LB + D-pad right opens Players (spectate, teleport to, or join someone). While the menu is open the skater gets no
input. Make a mode hostable there:

```lua
mode:Host({
	description = "be first to the finish",  -- a short tagline, shown under the mode's name
	about = "Everyone starts together. The first one to the finish line wins.",
	                          -- a few plain sentences: beside the Host list,
	                          -- on the options screen and in the lobby
	options = {
		{ key = "time", label = "Time", type = "number", min = 30, max = 300, step = 15, default = 120, format = function(v) return v .. " s" end },
		{ key = "mode", label = "Rules", type = "choice", choices = { { "a", "Classic" }, { "b", "Chaos" } }, default = "a" },
		{ key = "teams", label = "Teams", type = "bool", default = false },
		{ key = "area", label = "Play area", type = "region", min = 256, max = 4096, step = 64, default = 1024 },
		{ key = "finish", label = "Finish", type = "point" },
	},
	start = function(values, mode) mode:SendSequence({ ... }) end,
})
```

- `region`: a radius slider around where the host is standing (a ring shows it);
  `values.area` arrives as `{ centre = Vector, radius = n }`.
- `point`: the host flies a free camera there (left stick fly, right stick look,
  triggers down/up) and presses A; arrives as `{ pos = Vector, yaw = degrees }`.
  `required = false` makes it optional.
- `object`: like `point`, but the host sees the thing itself while placing it:
  your `draw(obj, alpha)` is called with `obj = { pos, yaw, scale, lift }`
  wherever they look. D-pad left/right turns it (`rotate = false` to stop
  that, `turnStep` degrees, 15 by default), D-pad up/down sizes it, X/Y
  lower and raise it, A puts it down. Give `scale` and/or `lift` as
  `{ label, min, max, step, default, format }` to offer them. Arrives as
  that same `obj` table. Placed objects stay drawn (faded) while the host
  sets the rest up. Basketboard (the hoop), Race (start and finish),
  Bullseye (the target) and Board Golf (the cup) use it.
- `mode:SendSequence({ cmd, cmd, ... })` sends commands spaced out (the
  framework rate-limits commands).
- While the host's game exists, Host Minigame offers `mode:Actions()` (default:
  Start = `{ cmd = "begin" }`, Close = `{ cmd = "stop" }`; override with
  `mode:HostActions(function(state) return { { label, run } } end)`).
- Join Minigame lists modes whose `mode:Info()` is non-nil. Default: from the
  last state, `phase ~= "idle"` and `host` (entity index); joinable in "lobby";
  joining sends `{ cmd = "join", canSkate = ... }` (override `mode:JoinInfo(fn)`,
  `mode:OnJoin(fn)`).
- `mode:HoldAtStart(holding, pos, yaw, now)` for countdowns: teleports your
  skater to the start once and freezes it (no simulation) until `holding` is
  false. The engine API has `Freeze(on)`, `BlockInput(on)`, `Pad()` (buttons,
  triggers, sticks), `SetView(fn)` and `View()`.
- `SKATEGM_MODES.Beacon(pos, col, height)` draws a beam into the sky.

`SKATEGM_MODES.API()` on the client is `SkateGM.API`:

| | |
|---|---|
| `IsSkating()`, `IsLoading()`, `CanSkate()` | Skater mode is on / loading / installed |
| `StartSkating()`, `StopSkating()` | switch Skater mode on (asynchronous) / off |
| `TeleportTo(pos, yaw)` | put your skater there (while skating); it waits for the collision there before it can fall |
| `SkaterPos()` | your skater's hips, or nil |
| `PoseOf(ply)` | a skater's bone positions (yours or another player's) |
| `State()` | the engine state: "PhysicsGround", "PhysicsAir", "GrindFiftyFifty", "WipeoutGround"... |
| `Velocity()`, `Speed()` | your skater's velocity (units/s) and speed (m/s) |
| `Score()` | Skate 3 points so far: banked lines plus the current line |
| `Launch(vel)` | add a velocity (m/s) to your skater |
| `SetPlayerCollision(on)` | false: other skaters aren't solid for now; nil: the player's own setting |
| `Say(text, bad)` | a chat line in the add-on's style |

Everything else (drawing, sounds, HUD) is plain Garry's Mod: add your own
`HUDPaint`, `PostDrawTranslucentRenderables` and `Think` hooks.

## Testing offline

The add-on's tests run under plain LuaJIT with `tests/lua/gmock.lua` mocking
the GMod API; `tests/lua/modes_test.lua` loads the framework and the example
mode. Follow the built-in modes' `*_server_test.lua` / `*_client_test.lua` for
fuller examples: they drive `MYMODE.Command(ply, msg, now)` and
`C.OnState(state, now)` directly.

### Shared by every mode

- **Lobby screen**: while your game is in its `lobby` phase the framework
  draws who's in, who hosts and what to press. Add your settings with
  `mode:LobbyLines(function(state) return { "60 s turns" } end)`; set
  `minPlayers` in `Register` for the "waiting for players (2 / 3)" hint.
- **Spectating**: `mode:Spectate(ents, { prefer = ent })` (client) watches
  one of `ents` (entity indexes; `SKATEGM_MODES.Others(state, filter)` lists
  the others in your game): a chase camera the right stick turns, D-pad
  left / right for the next one, Y for a free camera. Your own skater is
  held, hidden and gets no input meanwhile. `prefer` follows that player
  whenever it changes (the active player in turn-based modes).
  `mode:Spectate(nil)` hands everything back.
- **Rocket board / hoverboard**: every `mode:Host` gets "Rocket board" and
  "Hoverboard" switches (on by default); the framework enforces them for the
  players of that game while it's being played. `rocket = "force"` in the
  host definition turns every rocket on, full thrust (Rocket Royale);
  `boardRules = false` leaves the switches out.
- **Invites**: a game's menu offers "Invite players"; the invitee gets a
  toast and joins with LB + RT while the game is still in its lobby.

### Items

Crates, items and hits for your game: see [ITEMS.md](ITEMS.md)
(`ITEMS.server.Sync` from your think).

## Respawn (LB + X)

LB + X sends the skater back to the map's spawn (the server asks the
gamemode's `PlayerSelectSpawn`). A mode that doesn't want that during its
game can refuse it on the server:

```lua
hook.Add("SkateGMCanRespawn", "mymode", function(ply)
	if MYMODE.InGame(ply) then return false end
end)
```

`SkateGM.API.Respawn()` does the same from client code.

Punches (RB, off unless the server sets `skategm_punch_allow 1`) never
land on anyone in a minigame. Any other punch can be refused the same way:

```lua
hook.Add("SkateGMCanPunch", "myaddon", function(attacker, target)
	if target:IsPlayer() and NoPvP(target) then return false end
end)
```
