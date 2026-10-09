-- Items for minigames, shared: the registry every item (built in, or from an
-- add-on's lua/skategm_itemdefs/*.lua) registers with.
--
-- A mode opens an "arena" for one of its games (ITEMS.server.Open): crates
-- float around its play area; skating through one breaks it and gives the
-- skater a random item if their hands are free. Left stick in uses it.
--
-- ITEMS.Register({
--   id = "rocket", title = "Rocket", model = "...", scale = 1,
--   uses = 1,                    -- how many times it can be used
--   weight = 1,                  -- how often crates give it
--   color = Color(...),          -- the glow around it, floating behind its holder's board
--   target = { range = 3000, color = Color(255, 40, 40) },  -- aimed at a player (optional)
--   use = function(arena, ply, msg) end,      -- server: used (msg.target: an entity index)
--   think = function(arena, now) end,         -- server: every tick an arena is open
--   fx = function(ev, now) end,               -- client: an event this item broadcast
--   draw = function(now) end,                 -- client: in the world, every frame
-- })
-- (a mode's canPlay(ply, game) gets that game's own table: games share one table)
-- arena (server): arena:Hit(victim, attacker, id), arena:Freeze(ply, seconds),
-- arena:Fx(ev), arena:Players(), arena:Pos(ply), arena:Forward(ply), arena.objects
ITEMS = ITEMS or { defs = {}, order = {} }
ITEMS.NET = "skategm_items"
ITEMS.BUTTON = 0x0040 -- left stick in
ITEMS.CRATE_MODEL = "models/props_junk/wood_crate001a.mdl"
ITEMS.CRATE_SCALE = 0.72
ITEMS.CRATE_FLOAT = 30
ITEMS.CRATE_OUTLINE = Color(255, 200, 80)
ITEMS.CRATE_RESPAWN = 8
ITEMS.TOUCH = 52
ITEMS.TOUCH_CHECK = 110

function ITEMS.Register(def)
	assert(type(def) == "table" and type(def.id) == "string" and def.id:match("^[%w_]+$"), "ITEMS.Register: needs an id (letters, digits, _)")
	def.title = def.title or def.id
	def.uses = math.max(1, def.uses or 1)
	def.weight = def.weight or 1
	def.scale = def.scale or 1
	if not ITEMS.defs[def.id] then ITEMS.order[#ITEMS.order + 1] = def.id end
	ITEMS.defs[def.id] = def
	return def
end

function ITEMS.Get(id) return ITEMS.defs[id] end

-- a weighted pick among the registered items (random(n) -> 1..n, a number in [0, 1) without)
function ITEMS.Pick(random)
	local total = 0
	for _, id in ipairs(ITEMS.order) do total = total + math.max(0, ITEMS.defs[id].weight) end
	if total <= 0 then return nil end
	local r = (random or math.random)() * total
	for _, id in ipairs(ITEMS.order) do
		r = r - math.max(0, ITEMS.defs[id].weight)
		if r < 0 then return id end
	end
	return ITEMS.order[#ITEMS.order]
end

-- one spot anywhere in a circle, on the ground
function ITEMS.RandomSpot(centre, radius, random)
	random = random or math.random
	local r, a = radius * 0.92 * math.sqrt(random()), random() * math.pi * 2
	local x, y = centre[1] + math.cos(a) * r, centre[2] + math.sin(a) * r
	local z = SKATEGM_MODES and SKATEGM_MODES.Ground and SKATEGM_MODES.Ground(x, y, centre[3]) or centre[3]
	return { x, y, z }
end

-- spots spread over a circle (sunflower spiral: even, no clumps), on the ground
function ITEMS.Spread(centre, radius, n, random)
	local out = {}
	random = random or math.random
	local golden = math.pi * (3 - math.sqrt(5))
	local turn = random() * math.pi * 2
	for i = 1, n do
		local r = radius * 0.92 * math.sqrt((i - 0.5) / n)
		local a = turn + i * golden
		local x, y = centre[1] + math.cos(a) * r, centre[2] + math.sin(a) * r
		local z = SKATEGM_MODES and SKATEGM_MODES.Ground and SKATEGM_MODES.Ground(x, y, centre[3]) or centre[3]
		out[i] = { x, y, z }
	end
	return out
end
