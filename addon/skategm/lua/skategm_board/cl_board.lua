local C = BOARD.client or {}
BOARD.client = C

local cvDeck = CreateClientConVar("skategm_deck_color", BOARD.FormatColor(BOARD.DECK_DEFAULT), true, false, "Deck (grip) colour, \"r g b\"")
local cvWheel = CreateClientConVar("skategm_wheel_color", BOARD.FormatColor(BOARD.WHEEL_DEFAULT), true, false, "Wheel colour, \"r g b\"")
local cvImage = CreateClientConVar("skategm_board_image", "", true, false, "Image under your deck: a file in garrysmod/data/skategm/boards/")
local cvShow = CreateClientConVar("skategm_show_board_images", "1", true, false, "Show the images under other players' boards")
local cvRollSound = CreateClientConVar("skategm_roll_sound", "1", true, false, "Rolling sound (number in the list)", 1, #BOARD.ROLL_SOUNDS)
local cvRocketSound = CreateClientConVar("skategm_rocket_sound", "1", true, false, "Rocket sound (number in the list)", 1, #BOARD.ROCKET_SOUNDS)
local cvHover = CreateClientConVar("skategm_hoverboard", "0", true, false, "Hoverboard mode: the board and skater float and bob, and ride on water", 0, 1)
local cvType = CreateClientConVar("skategm_board_type", BOARD.DEFAULT_TYPE, true, false, "Your board type (classic, model, or one an add-on adds)")
local COMMON_CONVARS = { "skategm_hoverboard", "skategm_roll_sound", "skategm_rocket_sound", "skategm_board_type" }

C.DIR = "skategm/boards/"
C.CACHE = "skategm/cache/"
C.mats = C.mats or {}
C.asked = C.asked or {}
C.incoming = C.incoming or {}
C.looks = C.looks or {}

function C.AddType(def)
	for _, f in ipairs(def.fields) do
		if f.convar and not f.cv then
			local default = f.kind == "bool" and (f.default and "1" or "0") or tostring(f.default or "")
			f.cv = CreateClientConVar(f.convar, default, true, false, f.label or f.key, f.min, f.max)
			if cvars and cvars.AddChangeCallback then cvars.AddChangeCallback(f.convar, function() C.Schedule() end, "skategm_board") end
		end
	end
end

function C.FieldValue(f)
	if not f.cv then return f.default end
	if f.kind == "number" then return f.cv:GetFloat() end
	if f.kind == "bool" then return f.cv:GetBool() end
	if f.kind == "choice" then return f.cv:GetInt() end
	return f.cv:GetString()
end

function C.MyType()
	return BOARD.Type(cvType:GetString()) or BOARD.Type(BOARD.DEFAULT_TYPE)
end

function C.MyExtra()
	local def = C.MyType()
	local t = { rs = cvRollSound:GetInt(), ks = cvRocketSound:GetInt(), hv = cvHover:GetBool(), bt = def and def.id }
	for _, f in ipairs(def and def.fields or {}) do t["o_" .. f.key] = C.FieldValue(f) end
	for _, fx in ipairs(BOARD.EFFECTS) do
		for _, f in ipairs(fx.fields) do t["f_" .. fx.id .. "_" .. f.key] = C.FieldValue(f) end
	end
	return BOARD.CleanExtra(t)
end

C.retryAt = C.retryAt or {}
local function ToColor(c) return c and Color(c[1], c[2], c[3]) or nil end

if file and file.CreateDir then
	file.CreateDir("skategm")
	file.CreateDir("skategm/boards")
	file.CreateDir("skategm/cache")
end

local function Say(...)
	if chat and chat.AddText then chat.AddText(Color(120, 200, 255), "[SkateGM] ", Color(255, 255, 255), ...) end
end

function C.ValidFile(name)
	if type(name) ~= "string" or name == "" or name:find("..", 1, true) or name:find("[/\\:]") then return false end
	local ext = name:lower():match("%.(%a+)$")
	return ext == "png" or ext == "jpg" or ext == "jpeg"
end

function C.ImageFiles()
	local out = {}
	for _, pat in ipairs({ "*.png", "*.jpg", "*.jpeg" }) do
		for _, f in ipairs(file.Find(C.DIR .. pat, "DATA") or {}) do out[#out + 1] = f end
	end
	table.sort(out, function(a, b) return a:lower() < b:lower() end)
	return out
end

function C.ReadImage(name)
	if not C.ValidFile(name) then return nil, "not a PNG or JPG file name" end
	local data = file.Read(C.DIR .. name, "DATA")
	if not data then return nil, "can't read garrysmod/data/" .. C.DIR .. name end
	if #data > BOARD.MAX_BYTES then return nil, string.format("%s is %d KB; the limit is %d KB", name, math.ceil(#data / 1024), BOARD.MAX_BYTES / 1024) end
	local kind = BOARD.ImageType(data)
	if not kind then return nil, name .. " isn't a real PNG or JPG" end
	return data, kind
end

function C.CachePath(name)
	for _, kind in ipairs({ "png", "jpg" }) do
		local f = C.CACHE .. name .. "." .. kind
		if file.Exists(f, "DATA") then return f end
	end
end

function C.Store(name, kind, data)
	file.Write(C.CACHE .. name .. "." .. kind, data)
	C.mats[name] = nil
	C.retryAt[name] = nil
end

function C.MyLook()
	local deck = BOARD.ParseColor(cvDeck:GetString()) and cvDeck:GetString() or ""
	local wheels = BOARD.ParseColor(cvWheel:GetString()) and cvWheel:GetString() or ""
	return deck, wheels, cvImage:GetString()
end

-- my board as it's set right now (not as the server last heard it): for
-- previews, the same shape LookFor gives
C.SHRINK_SIDE = 1024
local SHRINK_STEPS = { { 1, 90 }, { 1, 75 }, { 0.75, 75 }, { 0.5, 75 }, { 0.35, 70 } }

function C.FreeName(stem, ext)
	for n = 1, 999 do
		local name = n == 1 and (stem .. "." .. ext) or string.format("%s (%d).%s", stem, n, ext)
		if not file.Exists(C.DIR .. name, "DATA") then return name end
	end
end

function C.ShrinkStep(job)
	local mat = Material("../data/" .. C.DIR .. job.name, "smooth")
	if not mat or mat:IsError() then return nil, "couldn't open the image" end
	local step = SHRINK_STEPS[job.step]
	local tw, th = mat:Width(), mat:Height()
	local k = math.min(1, C.SHRINK_SIDE / math.max(tw, th, 1)) * step[1]
	local w, h = math.max(16, math.floor(tw * k)), math.max(16, math.floor(th * k))
	local rt = GetRenderTargetEx("skategm_shrink_" .. w .. "x" .. h, w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGB888)
	render.PushRenderTarget(rt, 0, 0, w, h)
	render.Clear(0, 0, 0, 255)
	cam.Start2D()
	surface.SetDrawColor(255, 255, 255, 255)
	surface.SetMaterial(mat)
	surface.DrawTexturedRect(0, 0, w, h)
	cam.End2D()
	local data = render.Capture({ format = "jpeg", quality = step[2], x = 0, y = 0, w = w, h = h, alpha = false })
	render.PopRenderTarget()
	return data
end

function C.Shrink(name, done)
	C.shrinking = { name = name, done = done, step = 1 }
	hook.Add("PostRender", "skategm_board_shrink", function()
		local job = C.shrinking
		if not job then hook.Remove("PostRender", "skategm_board_shrink") return end
		local ok, data, err = pcall(C.ShrinkStep, job)
		if not ok then data, err = nil, tostring(data) end
		if data and #data <= BOARD.MAX_BYTES then
			local out = C.FreeName((job.name:gsub("%.%a+$", "")), "jpg")
			file.Write(C.DIR .. out, data)
			file.Delete(C.DIR .. job.name)
			C.shrinking = nil
			job.done(out)
		elseif err or job.step >= #SHRINK_STEPS then
			C.shrinking = nil
			job.done(nil, err or "the image is too big even shrunk")
		else
			job.step = job.step + 1
		end
	end)
end

function C.DeleteImage(name)
	if not C.ValidFile(name) then return false end
	file.Delete(C.DIR .. name)
	if cvImage:GetString() == name then RunConsoleCommand("skategm_board_image", "") end
	return true
end

function C.AddImage(name, done)
	if not C.ValidFile(name) then return done(nil, "not a PNG or JPG file name") end
	if (file.Size(C.DIR .. name, "DATA") or 0) <= BOARD.MAX_BYTES then return done(name) end
	C.Shrink(name, done)
end

function C.MyImageName(image)
	local stamp = file.Time and file.Time(C.DIR .. image, "DATA") or 0
	local m = C.myImage
	if m and m.file == image and m.stamp == stamp then return m.name end
	local data, kind = C.ReadImage(image)
	local name = data and BOARD.Hash(data) or nil
	if name and not C.CachePath(name) then C.Store(name, kind, data) end
	C.myImage = { file = image, stamp = stamp, name = name }
	return name
end

function C.MyLookNow()
	local deck, wheels, image = C.MyLook()
	local def = C.MyType()
	local x = C.MyExtra()
	local effects = {}
	for _, fx in ipairs(BOARD.EFFECTS) do effects[fx.id] = BOARD.EffectOptions(x, fx.id) end
	local cvRocket = GetConVar and GetConVar("skategm_rocket")
	return { type = def and def.id or BOARD.DEFAULT_TYPE, opts = BOARD.Options(x), effects = effects, deck = ToColor(BOARD.ParseColor(deck)), wheels = ToColor(BOARD.ParseColor(wheels)),
		mat = (def and def.image and image ~= "" and C.MyImageName(image)) and C.Material(C.MyImageName(image), RealTime()) or nil, rocket = cvRocket and cvRocket:GetBool() or false,
		rollSound = BOARD.ROLL_SOUNDS[x.rs or 1][2], rollChosen = (x.rs or 1) > 1, rocketSound = BOARD.ROCKET_SOUNDS[x.ks or 1][2], hover = x.hv == true }
end

function C.SendLook()
	local deck, wheels, image = C.MyLook()
	local def = C.MyType()
	if not (def and def.image) then image = "" end
	local data, kind
	if image ~= "" then
		data, kind = C.ReadImage(image)
		if not data then Say("Board image: ", kind) end
	end
	local bytes = 0
	if data then
		local name = BOARD.Hash(data)
		local mine = IsValid(LocalPlayer()) and BOARD.Decode(LocalPlayer():GetNW2String("skategm_look", ""))
		if not C.CachePath(name) then C.Store(name, kind, data) end
		bytes = (mine and mine.i == name) and BOARD.KEEP_IMAGE or #data
	end
	net.Start(BOARD.NET_LOOK)
	net.WriteString(deck)
	net.WriteString(wheels)
	net.WriteUInt(bytes, 20)
	local cvRocket = GetConVar and GetConVar("skategm_rocket")
	net.WriteBool(cvRocket and cvRocket:GetBool() or false)
	net.WriteString(util.TableToJSON(C.MyExtra()))
	net.SendToServer()
	if not data or bytes == BOARD.KEEP_IMAGE then return end
	local count = math.ceil(#data / BOARD.CHUNK)
	for k = 1, count do
		timer.Simple(k * 0.15, function()
			local part = data:sub((k - 1) * BOARD.CHUNK + 1, k * BOARD.CHUNK)
			net.Start(BOARD.NET_UP)
			net.WriteUInt(k, 8)
			net.WriteUInt(#part, 16)
			net.WriteData(part, #part)
			net.SendToServer()
		end)
	end
end

function C.Schedule() timer.Create("skategm_board_send", 0.6, 1, C.SendLook) end

function C.OnImage(name, kind, index, count, data, now)
	if not BOARD.ValidName(name) or (kind ~= "png" and kind ~= "jpg") or count < 1 or count * BOARD.CHUNK > BOARD.MAX_BYTES + BOARD.CHUNK then return end
	if index < 1 or index > count or type(data) ~= "string" then return end
	local inc = C.incoming[name]
	if not inc or inc.count ~= count or now - inc.at > 30 then
		inc = { count = count, parts = {}, got = 0, at = now }
		C.incoming[name] = inc
	end
	if inc.parts[index] then return end
	inc.parts[index] = data
	inc.got = inc.got + 1
	if inc.got < count then return end
	C.incoming[name] = nil
	local whole = table.concat(inc.parts)
	if #whole > BOARD.MAX_BYTES or BOARD.ImageType(whole) ~= kind or BOARD.Hash(whole) ~= name then return end
	C.Store(name, kind, whole)
	return true
end

function C.Request(name, now)
	if now - (C.asked[name] or -100) < 30 then return end
	C.asked[name] = now
	net.Start(BOARD.NET_REQ)
	net.WriteString(name)
	net.SendToServer()
end

function C.Material(name, now)
	local m = C.mats[name]
	if m ~= nil then return m or nil end
	if now < (C.retryAt[name] or 0) then return nil end
	local path = C.CachePath(name)
	if not path then
		C.retryAt[name] = now + 1
		C.Request(name, now)
		return nil
	end
	local ok, made = pcall(function()
		local img = Material("../data/" .. path, "smooth mips")
		if not img or img:IsError() then return false end
		local mat = CreateMaterial("skategm_under_" .. name, "UnlitGeneric", {
			["$basetexture"] = "color/white", ["$vertexcolor"] = "1", ["$nocull"] = "1",
		})
		mat:SetTexture("$basetexture", img:GetTexture("$basetexture"))
		return mat
	end)
	C.mats[name] = ok and made or false
	return C.mats[name] or nil
end


function C.LookFor(ply)
	local s = ply:GetNW2String("skategm_look", "")
	local look = C.looks[s]
	if look == nil then
		local t = BOARD.Decode(s)
		look = t and { deck = ToColor(t.d), wheels = ToColor(t.w), image = t.i, rocket = t.r, extra = t.x } or false
		C.looks[s] = look
	end
	if not look then return nil end
	local mat
	if look.image and (cvShow:GetBool() or ply == LocalPlayer()) then mat = C.Material(look.image, RealTime()) end
	local x = look.extra or {}
	if not look.effects then
		look.effects = {}
		for _, fx in ipairs(BOARD.EFFECTS) do look.effects[fx.id] = BOARD.EffectOptions(x, fx.id) end
	end
	return { type = x.bt or BOARD.DEFAULT_TYPE, opts = BOARD.Options(x), effects = look.effects, deck = look.deck, wheels = look.wheels, mat = mat, rocket = look.rocket,
		rollSound = BOARD.ROLL_SOUNDS[x.rs or 1][2], rollChosen = (x.rs or 1) > 1, rocketSound = BOARD.ROCKET_SOUNDS[x.ks or 1][2], hover = x.hv == true }
end

function C.Draw(ply, P, look, graphic, rocket, hover, drawBoard)
	local classic = BOARD.Type(BOARD.DEFAULT_TYPE)
	local def = (look and BOARD.Type(look.type)) or classic
	local ctx = { ply = ply, P = P, look = look, opts = look and look.opts or {}, graphic = graphic, rocket = rocket, hover = hover, DrawBoard = drawBoard }
	if def and def.draw then
		local ok, drawn = pcall(def.draw, ctx)
		if ok and drawn then return true end
		if not ok and not C.drawErr then C.drawErr = tostring(drawn) Say("board type ", def.id, ": ", C.drawErr) end
	end
	if classic and def ~= classic and classic.draw then
		ctx.opts = {}
		return classic.draw(ctx) and true or false
	end
	return false
end

C.fxState = C.fxState or {}
C.forced = C.forced or {}

function C.Force(ply, id, opts)
	local f = C.forced[ply] or {}
	f[id] = opts
	C.forced[ply] = next(f) and f or nil
end

function C.FxColour(mode, colour, ply, now, offset)
	if mode == 2 then
		local h = ((now or 0) * 90 + (offset or 0)) % 360
		if HSVToColor then return HSVToColor(h, 1, 1) end
		return Color(255, 255, 255)
	end
	if mode == 3 then
		local c = BOARD.ParseColor(colour)
		if c then return Color(c[1], c[2], c[3]) end
	end
	local pc = IsValid(ply) and ply.GetPlayerColor and ply:GetPlayerColor()
	if pc then return Color(math.Clamp(pc.x * 255, 0, 255), math.Clamp(pc.y * 255, 0, 255), math.Clamp(pc.z * 255, 0, 255)) end
	return Color(0, 200, 255)
end

function C.BoardFrame(P)
	local tf, tb = P.TRUCK_FRONT, P.TRUCK_BACK
	local rf, lf, rb, lb = P.RIGHT_WHEELFRONT, P.LEFT_WHEELFRONT, P.RIGHT_WHEELBACK, P.LEFT_WHEELBACK
	if not (tf and tb and rf and lf and rb and lb) then return nil end
	local fwd = (tf - tb):GetNormalized()
	local right = ((rf + rb) - (lf + lb)):GetNormalized()
	local up = right:Cross(fwd):GetNormalized()
	return { centre = (rf + lf + rb + lb) / 4, fwd = fwd, right = right, up = up, half = (tf - tb):Length() / 2,
		tf = tf, tb = tb, rf = rf, lf = lf, rb = rb, lb = lb }
end

function C.DrawEffects(ply, P, look, state, now, frame)
	if #BOARD.EFFECTS == 0 then return end
	local B = C.BoardFrame(P)
	if not B then return end
	local st = C.fxState[ply]
	if not st then st = { data = {} } C.fxState[ply] = st end
	local newFrame = frame == nil or st.frame ~= frame
	if newFrame then
		st.frame = frame
		local dt = st.at and now - st.at or 0
		if st.pos and dt > 0 then st.speed = (B.centre - st.pos):Length() / dt end
		if st.pos and (B.centre - st.pos):Length() > 400 then st.jumped = true else st.jumped = false end
		st.pos, st.at, st.dt = B.centre, now, dt
	end
	local mine = ply == LocalPlayer()
	for _, fx in ipairs(BOARD.EFFECTS) do
		local opts
		local forced = C.forced[ply] and C.forced[ply][fx.id]
		if forced then
			opts = {}
			for _, f in ipairs(fx.fields) do opts[f.key] = BOARD.CleanField(f, forced[f.key]) end
		elseif mine then
			opts = {}
			for _, f in ipairs(fx.fields) do opts[f.key] = BOARD.CleanField(f, C.FieldValue(f)) end
		else
			opts = look and look.effects and look.effects[fx.id] or {}
		end
		if fx.draw and (not fx.enabled or fx.enabled(opts)) then
			st.data[fx.id] = st.data[fx.id] or {}
			local ctx = { ply = ply, P = P, B = B, opts = opts, state = state, now = now, dt = st.dt or 0, speed = st.speed or 0,
				newFrame = newFrame, jumped = st.jumped, data = st.data[fx.id], C = C }
			local ok, err = pcall(fx.draw, ctx)
			if not ok and not fx.err then fx.err = tostring(err) Say("board effect ", fx.id, ": ", fx.err) end
		elseif fx.off and st.data[fx.id] then
			pcall(fx.off, st.data[fx.id])
			st.data[fx.id] = nil
		end
	end
end

function C.TestSound(path)
	if C.testSound then C.testSound:Stop() end
	local ok, snd = pcall(CreateSound, LocalPlayer(), path)
	if not ok or not snd then return end
	C.testSound = snd
	snd:Play()
	timer.Create("skategm_sound_test", 2, 1, function() if C.testSound == snd then snd:Stop() C.testSound = nil end end)
end

function C.Defaults()
	local list = {
		{ "skategm_deck_color", BOARD.FormatColor(BOARD.DECK_DEFAULT) },
		{ "skategm_wheel_color", BOARD.FormatColor(BOARD.WHEEL_DEFAULT) },
		{ "skategm_board_image", "" },
		{ "skategm_roll_sound", "1" },
		{ "skategm_rocket_sound", "1" },
		{ "skategm_hoverboard", "0" },
		{ "skategm_rocket", "0" },
		{ "skategm_rocket_fuel", "0" },
		{ "skategm_board_type", BOARD.DEFAULT_TYPE },
	}
	for _, group in ipairs({ BOARD.TYPES, BOARD.EFFECTS }) do
		for _, def in ipairs(group) do
			for _, f in ipairs(def.fields or {}) do
				if f.convar then list[#list + 1] = { f.convar, f.kind == "bool" and (f.default and "1" or "0") or tostring(f.default or "") } end
			end
		end
	end
	return list
end

function C.Reset()
	for _, d in ipairs(C.Defaults()) do RunConsoleCommand(d[1], d[2]) end
end

for _, name in ipairs({ "skategm_deck_color", "skategm_wheel_color", "skategm_board_image", "skategm_rocket" }) do
	cvars.AddChangeCallback(name, function() C.Schedule() end, "skategm_board")
end
for _, name in ipairs(COMMON_CONVARS) do
	cvars.AddChangeCallback(name, function() C.Schedule() end, "skategm_board")
end
for _, def in ipairs(BOARD.TYPES) do C.AddType(def) end
for _, def in ipairs(BOARD.EFFECTS) do C.AddType(def) end

hook.Add("Think", "skategm_board_fx", function()
	if RealTime() < (C.nextFxSweep or 0) then return end
	C.nextFxSweep = RealTime() + 2
	for ply, st in pairs(C.fxState) do
		if not IsValid(ply) or RealTime() - (st.at or 0) > 2 then
			for id, data in pairs(st.data) do
				local fx = BOARD.Effect(id)
				if fx and fx.off then pcall(fx.off, data) end
			end
			C.fxState[ply] = nil
		end
	end
end)

net.Receive(BOARD.NET_IMG, function()
	local name, kind = net.ReadString(), net.ReadString()
	local index, count = net.ReadUInt(8), net.ReadUInt(8)
	local n = net.ReadUInt(16)
	if n == 0 or n > BOARD.CHUNK then return end
	C.OnImage(name, kind, index, count, net.ReadData(n), RealTime())
end)

hook.Add("InitPostEntity", "skategm_board", function() timer.Simple(3, C.SendLook) end)
if IsValid(LocalPlayer()) then timer.Simple(1, C.SendLook) end
