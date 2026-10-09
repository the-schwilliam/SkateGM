HOM = HOM or {}

HOM.mode = SKATEGM_MODES.Register({ id = "hom", category = "Chaos", title = "Hall of Meat", order = 7, color = Color(255, 70, 60) })
HOM.NET_STATE, HOM.NET_CMD = HOM.mode.NET_STATE, HOM.mode.NET_CMD
HOM.cvAllowed = HOM.mode.cvAllowed
function HOM.Allowed() return HOM.mode:Allowed() end

-- (as in Skate: a turn is the time you have to START your bail; once you're
-- bailing the clock stops, and the bail goes on - taking damage hit after
-- hit - until the engine is done with the wipeout and puts you back up)
HOM.TURN_MIN, HOM.TURN_MAX, HOM.TURN_DEFAULT = 5, 60, 15
HOM.ROUNDS_MIN, HOM.ROUNDS_MAX, HOM.ROUNDS_DEFAULT = 1, 5, 2
HOM.PREP_TIMEOUT = 40
HOM.COUNTDOWN = 3
HOM.BETWEEN = 7
HOM.FINAL = 14
HOM.MAX_PLAYERS = 12
HOM.MAX_SCORE = 10000000

HOM.IMPACT_MIN = 450
HOM.DAMAGE_PER_UNIT = 1 / 15
HOM.BONE_COOLDOWN = 0.15
HOM.AIR_HEIGHT = 30
HOM.TELEPORT_JUMP = 60 -- units in one tick (~90 m/s): past that a bone was moved, not thrown
HOM.BAIL_CAP = 90
-- the host's Pain setting: every impact multiplied by this
HOM.PAINS = { { 1, "normal" }, { 1.6, "high" }, { 2.5, "brutal" } }
function HOM.PainScale(p) for _, e in ipairs(HOM.PAINS) do if e[1] == tonumber(p) then return e[1] end end return 1 end -- (only a safety net: the wipeout ending ends the bail)
HOM.WIPEOUT_GAP = 0.4 -- out of Wipeout this long: the bail is over
HOM.SLOWMO_SCALE, HOM.SLOWMO_TIME = 0.25, 1.1
HOM.POINTS_PER_DAMAGE = 25
HOM.POINTS_PER_AIR_SECOND = 1000

HOM.LEVELS = {
	{ name = "Bruised", damage = 10, bonus = 100, color = { 255, 230, 90 } },
	{ name = "Fractured", damage = 25, bonus = 500, color = { 255, 150, 50 } },
	{ name = "Broken", damage = 45, bonus = 1500, color = { 255, 50, 40 } },
	{ name = "Shattered", damage = 80, bonus = 3000, color = { 230, 60, 255 } },
}
HOM.BREAK_LEVEL = 3

-- pain: how sensitive each part is. Measured in the engine (launch-and-fall
-- bails): the head's impacts peak lower than the legs' - it lands after the
-- body, cushioned by the spine - so with one threshold for every bone a
-- head-first landing only bruised while ankles shattered on every landing
HOM.PARTS = {
	{ id = "skull", pain = 1.9, name = "Skull", bones = { "HEAD", "NECK1" } },
	{ id = "neck", pain = 1.7, name = "Neck", bones = { "NECK" } },
	{ id = "ribs", pain = 1.4, name = "Ribs", bones = { "SPINE2", "SPINE3" } },
	{ id = "spine", pain = 1.4, name = "Spine", bones = { "SPINE", "SPINE1" } },
	{ id = "pelvis", pain = 1.1, name = "Pelvis", bones = { "HIPS" } },
	{ id = "lcollar", pain = 1.3, name = "Left Collarbone", bones = { "LEFTSHOULDER" } },
	{ id = "rcollar", pain = 1.3, name = "Right Collarbone", bones = { "RIGHTSHOULDER" } },
	{ id = "lhumerus", pain = 1.25, name = "Left Humerus", bones = { "LEFTARM" } },
	{ id = "rhumerus", pain = 1.25, name = "Right Humerus", bones = { "RIGHTARM" } },
	{ id = "lforearm", pain = 1.2, name = "Left Forearm", bones = { "LEFTFOREARM" } },
	{ id = "rforearm", pain = 1.2, name = "Right Forearm", bones = { "RIGHTFOREARM" } },
	{ id = "lwrist", pain = 1.1, name = "Left Wrist", bones = { "LEFTHAND" } },
	{ id = "rwrist", pain = 1.1, name = "Right Wrist", bones = { "RIGHTHAND" } },
	{ id = "lfemur", pain = 1.0, name = "Left Femur", bones = { "LEFTUPLEG" } },
	{ id = "rfemur", pain = 1.0, name = "Right Femur", bones = { "RIGHTUPLEG" } },
	{ id = "ltibia", pain = 1.0, name = "Left Tibia", bones = { "LEFTLEG" } },
	{ id = "rtibia", pain = 1.0, name = "Right Tibia", bones = { "RIGHTLEG" } },
	{ id = "lankle", pain = 0.75, name = "Left Ankle", bones = { "LEFTFOOT", "LEFTTOEBASE" } },
	{ id = "rankle", pain = 0.75, name = "Right Ankle", bones = { "RIGHTFOOT", "RIGHTTOEBASE" } },
}
HOM.PART = {}
HOM.PART_OF_BONE = {}
for _, p in ipairs(HOM.PARTS) do
	HOM.PART[p.id] = p
	for _, b in ipairs(p.bones) do HOM.PART_OF_BONE[b] = p.id end
end

HOM.SKELETON = {
	{ "HIPS", "SPINE" }, { "SPINE", "SPINE1" }, { "SPINE1", "SPINE2" }, { "SPINE2", "SPINE3" }, { "SPINE3", "NECK" }, { "NECK", "NECK1" }, { "NECK1", "HEAD" },
	{ "SPINE3", "LEFTSHOULDER" }, { "LEFTSHOULDER", "LEFTARM" }, { "LEFTARM", "LEFTFOREARM" }, { "LEFTFOREARM", "LEFTHAND" },
	{ "SPINE3", "RIGHTSHOULDER" }, { "RIGHTSHOULDER", "RIGHTARM" }, { "RIGHTARM", "RIGHTFOREARM" }, { "RIGHTFOREARM", "RIGHTHAND" },
	{ "HIPS", "LEFTUPLEG" }, { "LEFTUPLEG", "LEFTLEG" }, { "LEFTLEG", "LEFTFOOT" }, { "LEFTFOOT", "LEFTTOEBASE" },
	{ "HIPS", "RIGHTUPLEG" }, { "RIGHTUPLEG", "RIGHTLEG" }, { "RIGHTLEG", "RIGHTFOOT" }, { "RIGHTFOOT", "RIGHTTOEBASE" },
}

HOM.ClampTurn = SKATEGM_MODES.Clamper(HOM.TURN_MIN, HOM.TURN_MAX, HOM.TURN_DEFAULT)
HOM.ClampRounds = SKATEGM_MODES.Clamper(HOM.ROUNDS_MIN, HOM.ROUNDS_MAX, HOM.ROUNDS_DEFAULT)

function HOM.LevelFor(damage)
	local level = 0
	for i, l in ipairs(HOM.LEVELS) do if damage >= l.damage then level = i end end
	return level
end

HOM.Commas = SKATEGM_MODES.Commas

function HOM.Score(damage, levels, air)
	local bonus = 0
	for _, lv in pairs(levels) do
		if lv > 0 then bonus = bonus + HOM.LEVELS[lv].bonus end
	end
	local total = math.floor(damage * HOM.POINTS_PER_DAMAGE) + bonus + math.floor(air * HOM.POINTS_PER_AIR_SECOND)
	return math.min(total, HOM.MAX_SCORE), bonus
end

local Tracker = {}
Tracker.__index = Tracker

function HOM.NewTracker(pain)
	return setmetatable({ pain = HOM.PainScale(pain), phase = "riding", damage = {}, levels = {}, prev = nil, prevV = {}, cool = {}, air = 0, total = 0 }, Tracker)
end

-- the bones this frame, copied: the skater's pose is one table updated in
-- place each frame, so keeping it as "last frame" compared every bone with
-- itself - no movement, so never any damage
local function Snapshot(P)
	if not P then return nil end
	local out = {}
	for bone in pairs(HOM.PART_OF_BONE) do
		local v = P[bone]
		if v then out[bone] = { x = v.x, y = v.y, z = v.z } end
	end
	return out
end
HOM.Snapshot = Snapshot


function Tracker:Feed(P, tick, state, ground, now)
	local events = {}
	state = state or ""
	local wiping = state:find("Wipeout", 1, true) ~= nil
	local airborne = state:find("Air", 1, true) ~= nil
	if self.phase == "riding" then
		if airborne then
			self.airSince = self.airSince or now
		elseif not wiping then
			self.airSince = nil
		end
		if wiping then
			self.phase, self.start = "bail", now
			self.air = self.airSince and (now - self.airSince) or 0
			self.airSince = nil
			events[#events + 1] = { kind = "start" }
		end
	end
	if self.phase ~= "bail" or not P or not tick then
		self.prev, self.prevTick = Snapshot(P), tick
		return events
	end
	-- (only the wipeout itself hurts; and a jump no body makes in a tick is
	-- the engine putting the skater back up - a teleport - not a hit: it used
	-- to break every bone at the end of the round)
	local jumped = false
	if self.prev and self.prevTick and tick > self.prevTick then
		local reach = HOM.TELEPORT_JUMP * (tick - self.prevTick)
		for bone in pairs(HOM.PART_OF_BONE) do
			local b, pb = P[bone], self.prev[bone]
			if b and pb and (b.x - pb.x) ^ 2 + (b.y - pb.y) ^ 2 + (b.z - pb.z) ^ 2 > reach * reach then jumped = true break end
		end
	end
	if not wiping or jumped then self.prevV = {} end
	if wiping and not jumped and self.prev and self.prevTick and tick > self.prevTick then
		local dt = (tick - self.prevTick) / 60
		for bone, part in pairs(HOM.PART_OF_BONE) do
			local b, pb = P[bone], self.prev[bone]
			if b and pb then
				local v = { (b.x - pb.x) / dt, (b.y - pb.y) / dt, (b.z - pb.z) / dt }
				local pv = self.prevV[bone]
				if pv then
					local dv = math.sqrt((v[1] - pv[1]) ^ 2 + (v[2] - pv[2]) ^ 2 + (v[3] - pv[3]) ^ 2) * HOM.PART[part].pain * self.pain
					if dv > HOM.IMPACT_MIN and now >= (self.cool[bone] or 0) then
						self.cool[bone] = now + HOM.BONE_COOLDOWN
						local dmg = (dv - HOM.IMPACT_MIN) * HOM.DAMAGE_PER_UNIT
						self.damage[part] = (self.damage[part] or 0) + dmg
						self.total = self.total + dmg
						local level = HOM.LevelFor(self.damage[part])
						if level > (self.levels[part] or 0) then
							self.levels[part] = level
							events[#events + 1] = { kind = "injury", part = part, level = level }
							if level >= HOM.BREAK_LEVEL then events[#events + 1] = { kind = "break", part = part, level = level } end
						end
					end
				end
				self.prevV[bone] = v
			end
		end
		if ground and ground > HOM.AIR_HEIGHT then self.air = self.air + dt end
	end
	-- lying still doesn't end it: the engine does, leaving the wipeout
	if not wiping then self.offSince = self.offSince or now else self.offSince = nil end
	local done = (self.offSince and now - self.offSince > HOM.WIPEOUT_GAP) or (now - self.start >= HOM.BAIL_CAP)
	self.prev, self.prevTick = Snapshot(P), tick
	if done then
		self.phase = "done"
		events[#events + 1] = { kind = "done", result = self:Result() }
	end
	return events
end

function Tracker:Result()
	local score, bonus = HOM.Score(self.total, self.levels, self.air)
	local injuries = {}
	for _, p in ipairs(HOM.PARTS) do
		local lv = self.levels[p.id]
		if lv and lv > 0 then injuries[#injuries + 1] = { part = p.id, level = lv } end
	end
	table.sort(injuries, function(a, b) return a.level > b.level end)
	return { score = score, damage = math.floor(self.total), air = math.floor(self.air * 100) / 100, bonus = bonus, injuries = injuries }
end
