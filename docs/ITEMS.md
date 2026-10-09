# Minigame items

Some minigames have items: see-through wooden crates float around the play
area, and skating through one breaks it and gives you a random item (if your
hands are free). Press the **left stick in** to use it. The item you hold is
shown top right and floats behind your skater for everyone to see.

Built in: **Rocket** (aimed: a red box marks the skater nearest the middle of
your view; a homing missile knocks them off), **Grenade** (thrown ahead; goes
off near a skater or after a few seconds, knocking off everyone close),
**Traffic Cone** (dropped behind you; whoever touches it bails), **Crowbar**
(three swings in front of you), **Physics Gun** (aimed: freezes the target for
two seconds with a blue beam).

Skull Runners and Ball Battle have items on by default; Hot Potato and Melon
King have an Items switch for the host.

## Adding an item

Drop a file into your add-on's `lua/skategm_itemdefs/`. Every file there is
loaded on both server and client (SkateGM sends it to clients).

```lua
-- lua/skategm_itemdefs/banana.lua
local BANANA = ITEMS.Register({
	id = "banana", title = "Banana", model = "models/props/cs_italy/bananna.mdl",
	scale = 2,        -- the preview / floating model's size
	uses = 1,         -- how many times it can be used before it's gone
	weight = 1,       -- how often crates give it (the built-ins are 1)
	color = Color(255, 230, 60),  -- its glow, floating behind the holder's board
	-- target = { range = 3000, color = Color(255, 40, 40) },  -- aim at a player first
})

-- server: it's used. Return false to keep it (nothing happened).
function BANANA.use(arena, ply, msg)
	-- msg.targetEnt: the aimed-at player (aimed items only, checked for you)
	local spot = arena:Pos(ply) - arena:Forward(ply) * 50
	arena.objects.bananas = arena.objects.bananas or {}
	table.insert(arena.objects.bananas, { pos = spot, owner = ply })
	arena:Fx({ item = "banana", p = { spot.x, spot.y, spot.z } })
end

-- server: every tick, for each arena that's open
function BANANA.think(arena, now)
	for i, b in ipairs(arena.objects.bananas or {}) do
		for _, p in ipairs(arena:Players()) do
			if p ~= b.owner and arena:Pos(p):Distance(b.pos) < 40 then
				arena:Hit(p, b.owner, "banana")
				table.remove(arena.objects.bananas, i)
				arena:Fx({ item = "banana", gone = i })
				return
			end
		end
	end
end

-- client: an event your item sent with arena:Fx (everyone gets them)
function BANANA.fx(ev, now) end

-- client: draw your item's things in the world, every frame
function BANANA.draw(now) end
```

The arena (server side) gives you:

| | |
|---|---|
| `arena:Players()` | the players of that game |
| `arena:Has(ply)` | a player of the game who can be hit right now |
| `arena:Pos(ply)`, `arena:Forward(ply)` | where a skater is, which way they're going (flat) |
| `arena:Hit(victim, attacker, id)` | knock them off the board (a real bail); the game is told (e.g. Ball Battle pops a ball). Once per 1.5 s per victim |
| `arena:Freeze(ply, seconds)` | hold their skater still |
| `arena:Fx(table)` | send an event to every client's `fx` (put `item = "<your id>"` in it) |
| `arena:Later(seconds, fn)` | run `fn` later (it should check `arena.closed`) |
| `arena.objects` | a table for your item's things in that arena |

On the client, `ITEMS.client.Model(path, scale, alpha)` makes a client-side
model (remove it yourself when done).

## Items in your own minigame

From your mode's think (on the server), one call keeps items on while your
game is being played and off otherwise:

```lua
ITEMS.server.Sync(MYMODE.mode, G, {
	on = G.items,                    -- your host option
	centre = Vector(...), radius = 2000,
	onHit = function(victim, attacker, id) end,   -- runs as this game (G is right)
	canPlay = function(ply, game) return true end, -- game: this game's own table
})
```

`G` is your game's table (the one you pass to `mode:UseSessions`); its
`players` list is who can pick up crates and be hit.
