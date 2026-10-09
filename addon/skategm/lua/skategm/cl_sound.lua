local S = SkateGM
local L = S.L

---------------------------------------------------------------------------
-- Sound: stock Source/HL2 sounds driven by the engine's own states. The same
-- code runs for every skater you can see (yours, other players', the ghost),
-- positioned on their model so it fades with distance.
---------------------------------------------------------------------------
local cvSounds = CreateClientConVar("skategm_sounds", "1", true, false, "Skateboard sounds", 0, 1)
local cvVolume = CreateClientConVar("skategm_sound_volume", "1", true, false, "Skateboard sound volume", 0, 2)

local function Numbered(fmt, n) local t = {} for i = 1, n do t[i] = string.format(fmt, i) end return t end
local SND = {
	roll       = "physics/plastic/plastic_barrel_scrape_smooth_loop1.wav", -- urethane wheels
	slide      = "physics/plastic/plastic_barrel_scrape_rough_loop1.wav",  -- powerslide
	grindMetal = "physics/metal/metal_box_scrape_smooth_loop1.wav",        -- trucks on a rail/ledge
	grindWood  = "physics/wood/wood_box_scrape_rough_loop1.wav",           -- deck on an edge
	drag       = "physics/concrete/concrete_scrape_smooth_loop1.wav",      -- foot braking
	pop        = Numbered("physics/wood/wood_plank_impact_hard%d.wav", 5),
	land       = Numbered("physics/wood/wood_box_impact_hard%d.wav", 3),
	landHard   = Numbered("physics/wood/wood_crate_impact_hard%d.wav", 5),
	grindOn    = Numbered("physics/metal/metal_solid_impact_hard%d.wav", 5),
	bail       = Numbered("physics/body/body_medium_impact_hard%d.wav", 6),
	clatter    = Numbered("physics/wood/wood_box_impact_soft%d.wav", 3),
	step       = Numbered("player/footsteps/concrete%d.wav", 4),
	-- ragdoll (bails)
	bodyHard   = Numbered("physics/body/body_medium_impact_hard%d.wav", 6),
	bodySoft   = Numbered("physics/body/body_medium_impact_soft%d.wav", 7),
	bodySlide  = "physics/body/body_medium_scrape_smooth_loop1.wav",
	boardHard  = Numbered("physics/wood/wood_box_impact_hard%d.wav", 3),
	boardSoft  = Numbered("physics/wood/wood_box_impact_soft%d.wav", 3),
}

-- Skate 3's own board sounds, when the installer made them from the player's
-- game (addons/skategm_s3sounds + data/skategm/skate3_sounds.json; exporter
-- asset_pipeline/skate3_sounds.py): each event plays what retail plays for it,
-- the Splice patch layered as the game does (a member per group, its gain,
-- pitch, delay and chance), rolling from the surface's grain at the speed's
-- band. The surface is the engine's audio tag under the wheels (yours only:
-- other skaters use the default)
local cvSet = CreateClientConVar("skategm_sound_set", "0", true, false, "0 = Skate 3's own board sounds (when installed), 1 = the stock Garry's Mod ones", 0, 1)
S.S3 = { M = nil, picks = {} }
local S3 = S.S3
S3.DEFAULT_TAG = 1
S3.MPS = 52.49
S3.FLIP_RATE = 600
S3.SQUEAK_CHANCE = 0.35

function S3.At(t, k)
	if not t then return nil end
	local v = t[k]
	if v == nil then v = t[tostring(k)] end
	if v == nil and tonumber(k) then v = t[tonumber(k)] end
	return v
end

function S3.Load()
	S3.M = nil
	if not (file and file.Read) then return false end
	local text = file.Read("skategm/skate3_sounds.json", "DATA")
	local m = text and util.JSONToTable(text)
	if not (m and m.banks and m.surfaces) then return false end
	if file.Exists and not file.Exists("sound/skate3/grains", "GAME") then return false end
	S3.M = m
	return true
end

function S3.On()
	return S3.M ~= nil and not cvSet:GetBool()
end

function S3.Surface(key)
	local tag
	local p = S.pose
	if p and IsValid(key) and key == LocalPlayer() then
		for i = 0, 3 do
			local t = p["audioWheel" .. i]
			if t and t > 0 then tag = t break end
		end
	end
	tag = math.min(tag or S3.DEFAULT_TAG, 95)
	return S3.At(S3.M.surfaces, tag) or S3.At(S3.M.surfaces, S3.DEFAULT_TAG) or {}, tag
end

function S3.GrindSurface(key)
	local p = S.pose
	local tag = p and IsValid(key) and key == LocalPlayer() and p.audioGrind or 0
	local s = tag > 0 and S3.At(S3.M.surfaces, math.min(tag, 95))
	return (s and s.grind or 4) + 1
end

-- an index of `count` with the group's pick mode: 0 random, 2 shuffled (no
-- repeat until each was played), else in turn
function S3.Pick(state, count, mode)
	if count <= 1 then return 1 end
	if mode == 0 then return math.random(count) end
	if mode == 2 then
		if not state.left or #state.left == 0 then
			state.left = {}
			for i = 1, count do state.left[i] = i end
		end
		return table.remove(state.left, math.random(#state.left))
	end
	state.n = (state.n or 0) % count + 1
	return state.n
end

local function Spread(v, spread)
	if not spread or spread <= 1 then return v end
	return v * math.Rand(1 / spread, 1)
end

-- a sound id of a Splice bank, as retail plays it
function S3.Play(ent, bank, id, vol, depth)
	local B = S3.M and S3.M.banks[bank]
	if not (B and id and IsValid(ent)) or (depth or 0) > 4 then return end
	local c = S3.At(B.containers, id)
	if c then
		local state = S3.picks[bank .. ":c" .. id] or {}
		S3.picks[bank .. ":c" .. id] = state
		return S3.Play(ent, bank, c.ids[S3.Pick(state, #c.ids, c.mode)], vol, (depth or 0) + 1)
	end
	local rec = S3.At(B.records, id)
	if not rec then return end
	local base = vol * (rec.gain or 1) * cvVolume:GetFloat()
	local rp = (rec.pitch or 1) * (1 + (rec.pitchRand or 0) * math.Rand(-1, 1))
	for g, group in ipairs(rec.groups) do
		local state = S3.picks[bank .. ":" .. id .. ":" .. g] or {}
		S3.picks[bank .. ":" .. id .. ":" .. g] = state
		local m = group.members[S3.Pick(state, #group.members, group.mode)]
		if m and math.random() <= (m.prob or 1) then
			local v = math.min(1, Spread(base * (m.gain or 1), m.gainSpread))
			local pitch = math.Clamp(math.Round(100 * rp * (m.pitch or 1) * (1 + (m.pitchRand or 0) * math.Rand(-1, 1))), 20, 255)
			local path = "skate3/" .. bank .. "/" .. m.s .. ".wav"
			local delay = (m.delay or 0) + (m.delayRand or 0) * math.random()
			if v > 0.01 then
				if delay > 0.005 then
					timer.Simple(delay, function() if IsValid(ent) then ent:EmitSound(path, 75, pitch, v) end end)
				else
					ent:EmitSound(path, 75, pitch, v)
				end
			end
		end
	end
end

function S3.Abk(bank, list)
	local picks = S3.M and S3.M.abk[bank]
	if not picks or #picks == 0 then return nil end
	local t = {}
	for i, n in ipairs(list or picks) do t[i] = "skate3/" .. bank .. "/" .. n .. ".wav" end
	return t
end

-- the rolling loop: the surface's grain, the band for this speed
function S3.RollPath(key, speed)
	local surface = S3.Surface(key)
	local name = S3.At(S3.M.grainNames, surface.grain or 1) or "asphalt_rough"
	local stem = name .. "_hard"
	local curve = S3.M.grains[stem]
	if not curve then stem, curve = "asphalt_rough_hard", S3.M.grains.asphalt_rough_hard end
	local kmh = speed / S3.MPS * 3.6
	local t = math.Clamp(kmh / ((curve and curve.max_kmh) or 60), 0, 1)
	local b = curve and curve.bezier or { 0, 0.33, 0.66, 1 }
	local u = 1 - t
	local pos = u * u * u * b[1] + 3 * u * u * t * b[2] + 3 * u * t * t * b[3] + t * t * t * b[4]
	local band = math.Clamp(math.floor(pos * 6), 0, 5)
	return "skate3/grains/" .. stem .. "/" .. band .. ".wav"
end

-- a collision material's id for this hit: [tier 2, tier 0 x class 0..2, tier 1 x class 0..2]
function S3.Hit(ent, material, strength, hollow)
	if not material then return end
	local class = strength > 0.66 and 3 or strength > 0.33 and 2 or 1
	local id = material.ids[(hollow and 4 or 1) + class]
	if not id or id == 0 then id = material.ids[1] end
	S3.Play(ent, "Skate_Collisions", id, (material.gain or 1) * math.Clamp(0.4 + strength, 0.4, 1))
end

S3.Load()

-- bones whose tumbling makes the body sounds during a bail
local RAGDOLL_BONES = { "HEAD", "SPINE2", "HIPS", "RIGHTHAND", "LEFTHAND", "RIGHTFOOT", "LEFTFOOT" }
S.SND = SND

local function Category(state)
	if not state then return "ground" end
	if state == "SlideGround" then return "slide" end
	if string.sub(state, 1, 5) == "Grind" then
		if state == "GrindBoardslide" or state == "GrindTipslide" or state == "GrindDarkslide" then return "woodgrind" end
		return "metalgrind"
	end
	if state == "WipeoutGround" then return "wipeout" end
	if state == "BipedAir" then return "walkair" end
	if string.sub(state, 1, 5) == "Biped" or state == "OffBoardPushing" then return "walk" end
	if string.find(state, "Air", 1, true) then return "air" end
	return "ground" -- PhysicsGround, RevertGround, landings, plants...
end
local ROLLING = { ground = true, slide = true, metalgrind = true, woodgrind = true }

local audio = {} -- skater key -> sound state

local function OneShot(ent, list, vol, pitch)
	if not IsValid(ent) then return end
	local v = vol * cvVolume:GetFloat()
	if v <= 0.01 then return end
	ent:EmitSound(list[math.random(#list)], 75, pitch or math.random(95, 105), math.min(v, 1))
end

local function Loop(A, ent, name, path, on, vol, pitch)
	local L = A.loops[name]
	A.paths = A.paths or {}
	if L and A.paths[name] ~= path then
		L:Stop()
		L, A.loops[name] = nil, nil
	end
	A.paths[name] = path
	if on and cvSounds:GetBool() then
		if not L then
			local ok, snd = pcall(CreateSound, ent, path)
			if not ok or not snd then return end
			L = snd
			A.loops[name] = L
			L:PlayEx(0, pitch)
		elseif not L:IsPlaying() then
			L:PlayEx(0, pitch)
		end
		L:ChangeVolume(math.Clamp(vol * cvVolume:GetFloat(), 0, 1), 0.1)
		L:ChangePitch(math.Clamp(pitch, 30, 250), 0.1)
	elseif L then
		L:FadeOut(0.15)
		A.loops[name] = nil
	end
end

function S.RollSoundFor(key, own)
	local look = BOARD and BOARD.client and IsValid(key) and key.GetNW2String and BOARD.client.LookFor(key)
	if own and look and look.rollChosen == false then return nil end
	return look and look.rollSound
end

function S.StopSounds(key)
	local A = audio[key]
	if not A then return end
	for _, L in pairs(A.loops) do L:Stop() end
	audio[key] = nil
end


-- Ragdoll sound during a bail: a bone that was falling (or flying) and
-- suddenly stops has hit something. Velocities are smoothed so the steps
-- between other players' network snapshots don't read as hits.
local function RagdollSound(A, ent, P, centre, dt, now)
	A.rag = A.rag or { bones = {}, budget = { body = 3, board = 2 } }
	local R = A.rag
	-- at most ~10 body hits and ~5 board hits a second (the board is its own object)
	R.budget.body = math.min(8, R.budget.body + dt * 10)
	R.budget.board = math.min(4, R.budget.board + dt * 5)
	local function track(key, pos, pool)
		local b = R.bones[key]
		if not b then
			b = { pos = pos, v = Vector(0, 0, 0), fall = 0, peak = 0, next = 0 }
			R.bones[key] = b
			return nil
		end
		local raw = (pos - b.pos) / dt
		b.pos = pos
		if raw:LengthSqr() > 3000 * 3000 then return nil end -- teleport
		b.v = LerpVector(math.min(1, dt * 30), b.v, raw)
		-- remembered peaks fade steadily, so gradual slowing never counts as a hit
		b.fall = math.min(0, b.fall + dt * 800, b.v.z) -- fastest recent fall, fading back towards 0
		local speed = b.v:Length()
		b.peak = math.max(speed, b.peak - dt * 600)
		local hit
		if b.fall < -150 and b.v.z > b.fall * 0.3 then hit = -b.fall end   -- was falling, stopped
		if b.peak > 300 and speed < b.peak * 0.4 then hit = math.max(hit or 0, b.peak) end -- slammed into something
		if hit then
			b.fall, b.peak = b.v.z < 0 and b.v.z or 0, speed
			if now > b.next and R.budget[pool] >= 1 then
				b.next = now + 0.18
				R.budget[pool] = R.budget[pool] - 1
				return hit
			end
		end
		return nil
	end
	for _, name in ipairs(RAGDOLL_BONES) do
		local pos = P[name]
		if pos then
			local hit = track(name, pos, "body")
			if hit and cvSounds:GetBool() then
				if S3.On() then
					local part = name == "HEAD" and "head" or (name == "SPINE2" or name == "HIPS") and "torso" or string.find(name, "HAND", 1, true) and "arms" or "legs"
					S3.Hit(ent, S3.M.collision.parts[part], math.Clamp(hit / 900, 0, 1))
				else
					OneShot(ent, hit > 500 and SND.bodyHard or SND.bodySoft, math.Clamp(hit / 700, 0.25, 1), math.random(90, 110))
				end
			end
		end
	end
	-- the board bounces on its own
	local hit = track("board", centre, "board")
	if hit and cvSounds:GetBool() then
		if S3.On() then
			S3.Hit(ent, S3.M.collision.board, math.Clamp(hit / 800, 0, 1))
		else
			OneShot(ent, hit > 400 and SND.boardHard or SND.boardSoft, math.Clamp(hit / 600, 0.25, 0.9), math.random(95, 115))
		end
	end
	-- sliding along the ground: hips moving fast sideways but hardly up or down
	local hips = R.bones.HIPS
	local flat = hips and Vector(hips.v.x, hips.v.y, 0):Length() or 0
	local sliding = hips and flat > 90 and math.abs(hips.v.z) < 70
	Loop(A, ent, "bodySlide", S3.On() and "skate3/Bodyslide/" .. S3.BODY_SLIDE .. ".wav" or SND.bodySlide, sliding, math.Clamp(flat / 600, 0.1, 0.6), 90 + math.min(flat, 800) * 0.03)
end

-- per frame, per visible skater
function S.UpdateSound(key, ent, P, state, now, stale)
	if not (IsValid(ent) and P and P.HIPS) then return end
	local A = audio[key]
	if not A then
		A = { loops = {}, feet = {}, speed = 0, vz = 0, accel = 0, minVz = 0 }
		audio[key] = A
	end
	local w = P.RIGHT_WHEELFRONT and P.LEFT_WHEELFRONT and P.RIGHT_WHEELBACK and P.LEFT_WHEELBACK
	local centre = w and (P.RIGHT_WHEELFRONT + P.LEFT_WHEELFRONT + P.RIGHT_WHEELBACK + P.LEFT_WHEELBACK) / 4 or P.HIPS
	-- Only react to a pose that actually changed. The engine ticks at 60 Hz, so
	-- at higher frame rates (and on the second update in a frame) the pose is
	-- the same as last time; measuring those frames would read speed as zero.
	-- Unchanged for longer than an engine tick (~17 ms) means it really stopped
	-- (e.g. a ragdoll hitting the ground), so that is processed.
	if A.t and A.hips and (P.HIPS - A.hips):LengthSqr() < 1e-8 and (centre - A.centre):LengthSqr() < 1e-8
		and state == A.state and now - A.t < 0.03 then
		return
	end
	local dt = A.t and now - A.t or 0
	A.t, A.state = now, state
	if A.centre and dt > 1e-4 then
		local speed = (centre - A.centre):Length() / dt
		local hips = P.HIPS - A.hips
		local vz = hips.z / dt
		local hipsFlat = Vector(hips.x, hips.y, 0):Length() / dt
		if speed < 3000 and hipsFlat < 3000 then -- ignore teleports / respawns
			local k = math.min(1, dt * 8)
			local before = A.speed
			A.speed = Lerp(k, A.speed, speed)
			A.walkSpeed = Lerp(k, A.walkSpeed or 0, hipsFlat)
			A.vz = Lerp(math.min(1, dt * 12), A.vz, vz)
			A.accel = Lerp(k, A.accel, (A.speed - before) / dt)
		end
	end
	A.centre, A.hips, A.hipsZ = centre, Vector(P.HIPS.x, P.HIPS.y, P.HIPS.z), P.HIPS.z

	local cat = Category(state)
	local prev = A.cat
	local s3 = S3.On()
	if prev and prev ~= cat and cvSounds:GetBool() and s3 then
		S3.Events(A, key, ent, prev, cat, now)
	elseif prev and prev ~= cat and cvSounds:GetBool() then
		if ROLLING[prev] and cat == "air" and A.vz > 40 then
			OneShot(ent, SND.pop, 0.8)                                   -- ollie / pop out
		end
		if prev == "air" and ROLLING[cat] then
			local impact = -A.minVz
			if cat == "metalgrind" or cat == "woodgrind" then
				OneShot(ent, SND.grindOn, 0.6)                           -- locking into a grind
			elseif impact > 80 then
				OneShot(ent, impact > 450 and SND.landHard or SND.land, math.Clamp(impact / 500, 0.35, 1))
			end
		end
		if cat == "wipeout" then
			OneShot(ent, SND.bail, 0.9)
			OneShot(ent, SND.clatter, 0.7)
		end
	end
	if cat == "air" then
		if prev ~= "air" then A.minVz, A.airAt = 0, now end
		A.minVz = math.min(A.minVz, A.vz)
	end
	A.cat = cat

	if cat == "wipeout" and dt > 1e-4 then
		-- a late network snapshot freezes a remote skater, which looks like a
		-- sudden stop; don't read hits from those frames
		if not stale then RagdollSound(A, ent, P, centre, dt, now) end
	elseif A.rag then
		A.rag = nil
		Loop(A, ent, "bodySlide", SND.bodySlide, false, 0, 100)
	end

	local sp = A.speed
	if s3 then
		S3.Loops(A, key, ent, cat, sp, dt, now, P, w)
	else
		Loop(A, ent, "roll", S.RollSoundFor(key) or SND.roll, cat == "ground" and sp > 20, math.Clamp(0.1 + sp / 900, 0.15, 0.65), 60 + math.min(sp, 1400) * 0.05)
		Loop(A, ent, "slide", SND.slide, cat == "slide" and sp > 20, math.Clamp(sp / 500, 0.15, 0.6), 80 + math.min(sp, 1500) * 0.03)
		Loop(A, ent, "grindMetal", SND.grindMetal, cat == "metalgrind", math.Clamp(0.25 + sp / 800, 0.25, 0.7), 85 + math.min(sp, 1800) * 0.03)
		Loop(A, ent, "grindWood", SND.grindWood, cat == "woodgrind", math.Clamp(0.25 + sp / 800, 0.25, 0.7), 80 + math.min(sp, 1800) * 0.03)
	end

	-- Feet. A step is a foot that was swinging coming to rest near the ground;
	-- a planted foot is nearly still in the world (when pushing, the board rolls
	-- away from it), however little it lifted. On the board, only feet off to
	-- the side of it count (pushing, braking), not the ones standing on it.
	local ground
	if ROLLING[cat] and w then
		ground = (P.RIGHT_WHEELFRONT.z + P.LEFT_WHEELFRONT.z + P.RIGHT_WHEELBACK.z + P.LEFT_WHEELBACK.z) / 4 - 1.1
	elseif cat == "walk" or cat == "walkair" then
		local low = math.min((P.RIGHTTOEBASE or P.HIPS).z, (P.LEFTTOEBASE or P.HIPS).z)
		A.walkGround = math.min((A.walkGround or low) + dt * 40, low)
		ground = A.walkGround
	end
	local dragging = false
	for _, name in ipairs({ "RIGHTTOEBASE", "LEFTTOEBASE" }) do
		local f = P[name]
		local F = A.feet[name]
		if type(F) ~= "table" then F = {} A.feet[name] = F end
		if f and F.pos and dt > 1e-4 then
			local v = (f - F.pos) / dt
			if v:LengthSqr() < 3000 * 3000 then F.v = LerpVector(math.min(1, dt * 20), F.v or v, v) end
		end
		F.pos = Vector(f and f.x or 0, f and f.y or 0, f and f.z or 0)
		local speed = F.v and F.v:Length() or 0
		local off = cat == "walk" or (f and Vector(f.x - centre.x, f.y - centre.y, 0):Length() > 9)
		local near = f and ground and off and f.z - ground < 6
		local planted = near and speed < 45
		if speed > 70 or (f and ground and f.z - ground > 6) then F.swung = true end
		if planted and not F.planted and F.swung and cvSounds:GetBool() and (cat == "walk" or ROLLING[cat]) then
			if s3 then S3.Step(A, key, ent, cat) else OneShot(ent, SND.step, cat == "walk" and 0.9 or 1.0) end
			F.swung = false
		end
		F.planted = planted
		-- braking: a foot beside the board, near the ground, sliding along with it
		if near and ROLLING[cat] and speed > 60 then dragging = true end
	end
	-- landing from an off-board jump: both feet
	if prev == "walkair" and cat == "walk" and cvSounds:GetBool() then
		if s3 then
			S3.Step(A, key, ent, cat)
			S3.Step(A, key, ent, cat)
		else
			OneShot(ent, SND.step, 1.0)
			OneShot(ent, SND.step, 0.8)
		end
	end
	Loop(A, ent, "drag", s3 and S3.DragPath(key) or SND.drag, dragging and sp > 60 and A.accel < -60, math.Clamp(sp / 500, 0.2, 0.7), 90 + math.min(sp, 1000) * 0.02)
end

L.cvSounds, L.cvVolume = cvSounds, cvVolume

-- the Skate 3 set's one-shots on a change of state
function S3.Events(A, key, ent, prev, cat, now)
	local M = S3.M
	local surface = S3.Surface(key)
	local hollow = surface.hollow == 1
	local grind = { metalgrind = true, woodgrind = true }
	if ROLLING[prev] and cat == "air" and A.vz > 40 then
		local jump = math.abs(A.vz) / S3.MPS / 2.65
		local i = jump > 0.42 and 3 or jump > 0.25 and 2 or 1
		local gains = hollow and { 0.58, 0.76, 0.99 } or { 0.5, 0.75, 1.0 }
		S3.Play(ent, "Skate_Collisions", (hollow and M.popHollow or M.pop)[i], gains[i])
		if A.speed / S3.MPS > 4 then S3.Play(ent, "Skate_Collisions", M.popRoll, 0.6) end
	end
	if grind[cat] and not grind[prev] then
		local g = M.grinds[S3.GrindSurface(key)]
		if g then S3.Play(ent, g.metal and "Skate_Metal" or "Skate_Collisions", g.on[1], g.onGain[1] or 0.8) end
	elseif prev == "air" and ROLLING[cat] and -A.minVz > 80 then
		local air = now - (A.airAt or now)
		local tier = (hollow and 2 or 0) + 1
		local variant = air >= 1 and 2 or air >= 0.62 and 1 or 0
		local v = math.Clamp(-A.minVz / 500, 0.35, 1)
		S3.Play(ent, "Skate_Collisions", M.landing, v)
		S3.Play(ent, "Skate_Collisions", M.touchdown[tier][1 + variant], v)
		local sq = math.random() < S3.SQUEAK_CHANCE and S3.Abk("Brd_Squeaks")
		if sq then OneShot(ent, sq, 0.4) end
	end
	if grind[prev] and not grind[cat] then
		local g = M.grinds[S3.GrindSurface(key)]
		if g then S3.Play(ent, g.metal and "Skate_Metal" or "Skate_Collisions", g.off[1], g.offGain[1] or 0.8) end
	end
	if cat == "wipeout" then
		S3.Hit(ent, M.collision.body, 0.9)
		S3.Hit(ent, M.collision.board, 0.7)
	end
end

S3.STEP_IDS = { 84, 88, 92, 80, 76 }
function S3.Step(A, key, ent, cat)
	local surface = S3.Surface(key)
	local kind = math.Clamp((surface.drag or 0) + 1, 1, #S3.STEP_IDS)
	S3.Play(ent, "sk8_foley", S3.STEP_IDS[kind], cat == "walk" and 0.8 or 0.9)
end

S3.DRAG = { 36, 44, 60 }
function S3.DragPath(key)
	local surface = S3.Surface(key)
	if (S3.M.dragLoops or 0) > 0 then return "skate3/loops/drag_" .. math.Clamp(surface.drag or 0, 0, 4) .. ".wav" end
	return "skate3/FOOT_DRAG/" .. S3.DRAG[math.Clamp((surface.drag or 0) + 1, 1, #S3.DRAG)] .. ".wav"
end

S3.GRINDS = { 13, 14, 20, 21 }
S3.SKID = { 0, 1, 2, 3, 4 }
S3.BODY_SLIDE = 5
function S3.Loops(A, key, ent, cat, sp, dt, now, P, w)
	local surface = S3.Surface(key)
	local grinding = cat == "metalgrind" or cat == "woodgrind"
	if grinding and not A.grindLoop then A.grindLoop = S3.GRINDS[math.random(#S3.GRINDS)] end
	if not grinding then A.grindLoop = nil end
	local grind = "skate3/GRINDS/" .. (A.grindLoop or S3.GRINDS[1]) .. ".wav"
	Loop(A, ent, "roll", S.RollSoundFor(key, true) or S3.RollPath(key, sp), cat == "ground" and sp > 20, math.Clamp(0.15 + sp / 900, 0.2, 0.8), 100)
	local skid = S3.SKID[math.Clamp(surface.skid or 0, 0, #S3.SKID - 1) + 1]
	Loop(A, ent, "slide", "skate3/loops/skid_" .. skid .. ".wav", cat == "slide" and sp > 20, math.Clamp(sp / 500, 0.2, 0.75), 95 + math.min(sp, 1500) * 0.01)
	Loop(A, ent, "grindMetal", grind, cat == "metalgrind", math.Clamp(0.3 + sp / 800, 0.3, 0.8), 95 + math.min(sp, 1800) * 0.01)
	Loop(A, ent, "grindWood", grind, cat == "woodgrind", math.Clamp(0.3 + sp / 800, 0.3, 0.8), 95 + math.min(sp, 1800) * 0.01)
	if cat == "air" and P and w then S3.Flip(A, ent, P, dt, now) else A.deckUp = nil end
end

-- a flip trick: in the air, the deck's up turning fast; once per flip
function S3.Flip(A, ent, P, dt, now)
	local fwd = (P.RIGHT_WHEELFRONT + P.LEFT_WHEELFRONT) - (P.RIGHT_WHEELBACK + P.LEFT_WHEELBACK)
	local side = (P.RIGHT_WHEELFRONT + P.RIGHT_WHEELBACK) - (P.LEFT_WHEELFRONT + P.LEFT_WHEELBACK)
	local up = fwd:Cross(side)
	if up:LengthSqr() < 1e-6 then return end
	up:Normalize()
	local last = A.deckUp
	A.deckUp = up
	if not last or dt <= 1e-4 then return end
	local rate = math.deg(math.acos(math.Clamp(up:Dot(last), -1, 1))) / dt
	if rate > S3.FLIP_RATE and now >= (A.nextFlip or 0) and cvSounds:GetBool() then
		A.nextFlip = now + 0.45
		local flips = S3.Abk("Sk8_Air_Flip_Tricks")
		if flips then OneShot(ent, flips, 0.6) end
	end
end

if concommand and concommand.Add then
	concommand.Add("skategm_skate3_sounds_reload", function()
		print("[SkateGM] Skate 3 board sounds: " .. (S3.Load() and "loaded" or "not installed (run the SkateGM installer)"))
	end, nil, "Load Skate 3's board sounds again (after installing)")
end
