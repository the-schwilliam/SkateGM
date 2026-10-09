BOARD = BOARD or {}

BOARD.NET_LOOK = "skategm_board_look"
BOARD.NET_UP = "skategm_board_up"
BOARD.NET_REQ = "skategm_board_req"
BOARD.NET_IMG = "skategm_board_img"

BOARD.MAX_BYTES = 192 * 1024
BOARD.CHUNK = 30000
BOARD.KEEP_IMAGE = 0xFFFFF
BOARD.DECK_DEFAULT = { 40, 40, 43 }
BOARD.WHEEL_DEFAULT = { 238, 236, 222 }

function BOARD.ParseColor(s)
	if type(s) ~= "string" then return nil end
	local r, g, b = s:match("^%s*(%d+)%s+(%d+)%s+(%d+)%s*$")
	r, g, b = tonumber(r), tonumber(g), tonumber(b)
	if not (r and g and b) or r > 255 or g > 255 or b > 255 then return nil end
	return { r, g, b }
end
function BOARD.FormatColor(c) return string.format("%d %d %d", c[1], c[2], c[3]) end

function BOARD.ImageType(data)
	if type(data) ~= "string" or #data < 8 then return nil end
	if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
	if data:sub(1, 3) == "\255\216\255" then return "jpg" end
	return nil
end

function BOARD.Hash(data)
	if util and util.SHA256 then return util.SHA256(data):sub(1, 32) end
	return tostring(util.CRC(data)) .. "_" .. #data
end
function BOARD.ValidName(h) return type(h) == "string" and #h >= 4 and #h <= 64 and h:match("^[%w_]+$") ~= nil end

BOARD.ROLL_SOUNDS = {
	{ "Standard (follows Sound set)", "physics/plastic/plastic_barrel_scrape_smooth_loop1.wav" },
	{ "Hard plastic", "physics/plastic/plastic_box_scrape_smooth_loop1.wav" },
	{ "Metal", "physics/metal/metal_box_scrape_smooth_loop1.wav" },
	{ "Gritty", "physics/concrete/concrete_scrape_smooth_loop1.wav" },
	{ "Wood", "physics/wood/wood_box_scrape_smooth_loop1.wav" },
	{ "Cardboard", "physics/cardboard/cardboard_box_scrape_smooth_loop1.wav" },
	{ "Engine", "vehicles/v8/v8_idle_loop1.wav" },
	{ "Fan", "vehicles/airboat/fan_motor_idle_loop1.wav" },
	{ "Hoverboard", "weapons/physcannon/hold_loop.wav" },
	{ "Hoverboard, charged", "weapons/physcannon/superphys_hold_loop.wav" },
	{ "Energy hum", "weapons/physcannon/energy_sing_loop4.wav" },
	{ "Force field", "ambient/energy/force_field_loop1.wav" },
	{ "Electric crackle", "ambient/energy/electric_loop.wav" },
	{ "Zapper", "ambient/levels/citadel/zapper_loop1.wav" },
	{ "Combine shield", "ambient/machines/combine_shield_loop3.wav" },
	{ "Teleporter", "ambient/levels/labs/teleport_active_loop1.wav" },
	{ "Portal beam", "ambient/levels/citadel/portal_beam_loop1.wav" },
	{ "Resonator", "ambient/levels/labs/machine_ring_resonance_loop1.wav" },
	{ "Scanner drone", "npc/scanner/cbot_fly_loop.wav" },
	{ "Manhack", "npc/manhack/mh_engine_loop1.wav" },
	{ "Gunship whine", "npc/combine_gunship/engine_whine_loop1.wav" },
	{ "Spinning machine", "ambient/machines/spin_loop.wav" },
	{ "Train wheels", "ambient/machines/train_wheels_loop1.wav" },
	{ "Beeping gadget", "ambient/levels/labs/equipment_beep_loop1.wav" },
	{ "Siren", "ambient/alarms/city_siren_loop2.wav" },
	{ "Crossing bell", "ambient/alarms/train_crossing_bell_loop1.wav" },
}
BOARD.ROCKET_SOUNDS = {
	{ "Rocket", "weapons/rpg/rocket1.wav" },
	{ "Jet", "thrusters/jet01.wav" },
	{ "Jet, deep", "thrusters/jet02.wav" },
	{ "Thruster", "thrusters/rocket00.wav" },
	{ "Thruster, loud", "thrusters/rocket04.wav" },
	{ "Fire", "ambient/fire/fire_med_loop1.wav" },
	{ "Fan", "vehicles/airboat/fan_motor_fullthrottle_loop1.wav" },
	{ "Dropship", "npc/combine_gunship/dropship_engine_near_loop1.wav" },
	{ "Hover engine", "weapons/physcannon/superphys_hold_loop.wav" },
}
BOARD.MAX_MODEL_PATH = 160
BOARD.DEFAULT_TYPE = "classic"
BOARD.TYPES = BOARD.TYPES or {}
BOARD.EFFECTS = BOARD.EFFECTS or {}

function BOARD.ValidModel(path)
	return type(path) == "string" and #path <= BOARD.MAX_MODEL_PATH and path:lower():match("^models/[%w_/%-%.]+%.mdl$") ~= nil and not path:find("..", 1, true)
end

BOARD.COLOUR_MODES = { "My player colour", "Rainbow", "Custom colour" }

local function Num(v, lo, hi, default)
	v = tonumber(v)
	if not v or v ~= v then return default end
	return math.Clamp(v, lo, hi)
end

local function Bool(v, default)
	if v == nil then return default == true end
	return v == true or v == 1 or v == "1"
end

local function Ordered(list, def)
	for i = #list, 1, -1 do if list[i].id == def.id then table.remove(list, i) end end
	list[#list + 1] = def
	table.sort(list, function(a, b)
		if (a.order or 99) ~= (b.order or 99) then return (a.order or 99) < (b.order or 99) end
		return a.id < b.id
	end)
end

function BOARD.RegisterType(def)
	assert(type(def) == "table" and type(def.id) == "string" and def.id:match("^[%w_]+$"), "board type needs an id of letters, digits or _")
	def.title = def.title or def.id
	def.fields = def.fields or {}
	Ordered(BOARD.TYPES, def)
	if BOARD.client and BOARD.client.AddType then BOARD.client.AddType(def) end
	return def
end

function BOARD.RegisterEffect(def)
	assert(type(def) == "table" and type(def.id) == "string" and def.id:match("^[%w]+$"), "board effect needs an id of letters or digits")
	def.title = def.title or def.id
	def.fields = def.fields or {}
	Ordered(BOARD.EFFECTS, def)
	if BOARD.client and BOARD.client.AddType then BOARD.client.AddType(def) end
	return def
end

function BOARD.Effect(id)
	for _, def in ipairs(BOARD.EFFECTS) do if def.id == id then return def end end
	return nil
end

function BOARD.EffectOptions(x, id)
	local opts, prefix = {}, "f_" .. id .. "_"
	for k, v in pairs(x or {}) do
		if type(k) == "string" and k:sub(1, #prefix) == prefix then opts[k:sub(#prefix + 1)] = v end
	end
	return opts
end

function BOARD.Type(id)
	for _, def in ipairs(BOARD.TYPES) do if def.id == id then return def end end
	return nil
end

function BOARD.CleanField(f, v)
	if f.kind == "number" then return Num(v, f.min, f.max, f.default) end
	if f.kind == "bool" then return Bool(v, f.default) end
	if f.kind == "choice" then return math.floor(Num(v, 1, #f.choices, f.default or 1)) end
	if f.kind == "model" then return BOARD.ValidModel(v) and v or f.default end
	if f.kind == "color" then return BOARD.ParseColor(v) and v or f.default end
	if f.kind == "string" then return type(v) == "string" and #v <= (f.max or 64) and v or f.default end
	return nil
end

function BOARD.CleanExtra(t)
	t = type(t) == "table" and t or {}
	local def = BOARD.Type(t.bt) or BOARD.Type(BOARD.DEFAULT_TYPE)
	local out = {
		rs = math.floor(Num(t.rs, 1, #BOARD.ROLL_SOUNDS, 1)),
		ks = math.floor(Num(t.ks, 1, #BOARD.ROCKET_SOUNDS, 1)),
		hv = Bool(t.hv, false),
		bt = def and def.id or BOARD.DEFAULT_TYPE,
	}
	for _, f in ipairs(def and def.fields or {}) do out["o_" .. f.key] = BOARD.CleanField(f, t["o_" .. f.key]) end
	for _, fx in ipairs(BOARD.EFFECTS) do
		for _, f in ipairs(fx.fields) do
			local k = "f_" .. fx.id .. "_" .. f.key
			out[k] = BOARD.CleanField(f, t[k])
		end
	end
	return out
end

function BOARD.Options(x)
	local opts = {}
	for k, v in pairs(x or {}) do
		local key = type(k) == "string" and k:match("^o_(.+)$")
		if key then opts[key] = v end
	end
	return opts
end

-- (only what differs from the defaults: the look goes out as a networked
-- string, which is cut off past BOARD.MAX_LOOK; Decode fills the defaults in)
BOARD.MAX_LOOK = 511
function BOARD.Encode(look)
	local t = { d = look.d or "", w = look.w or "", i = look.i or "", r = look.r and "1" or "" }
	local x = BOARD.CleanExtra(look.x)
	local base = BOARD.CleanExtra({ bt = x.bt })
	for k, v in pairs(x) do
		if k == "bt" or base[k] ~= v then t[k] = v end
	end
	local s = util.TableToJSON(t)
	if #s > BOARD.MAX_LOOK then ErrorNoHalt(string.format("[SkateGM] board look is %d characters, over %d: it will be cut off\n", #s, BOARD.MAX_LOOK)) end
	return s
end

function BOARD.Decode(s)
	if type(s) ~= "string" or s == "" then return nil end
	local ok, t = pcall(util.JSONToTable, s)
	if not ok or type(t) ~= "table" then return nil end
	return { d = BOARD.ParseColor(t.d), w = BOARD.ParseColor(t.w), i = BOARD.ValidName(t.i) and t.i or nil, r = t.r == "1", x = BOARD.CleanExtra(t) }
end
