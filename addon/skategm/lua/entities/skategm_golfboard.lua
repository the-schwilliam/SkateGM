-- Board Golf's ball: a board-shaped physics prop let go with the skater's
-- board's place, angle and speed. Drawn as that skater's board; skaters ride
-- through it (it's only the ball).
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Golf board"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_OPAQUE

-- the deck (half-length, half-width) and from the wheels' bottom to its top
ENT.HALF, ENT.WIDTH, ENT.BOTTOM, ENT.TOP = 16, 4.5, -3.5, 0.8
ENT.MASS = 5
ENT.WHEELBASE = 7

function ENT:SetupDataTables()
	self:NetworkVar("Entity", 0, "Skater")
end

if SERVER then
	function ENT:Initialize()
		self:SetModel("models/hunter/plates/plate025x05.mdl")
		self:DrawShadow(false)
		self:PhysicsInitBox(Vector(-self.HALF, -self.WIDTH, self.BOTTOM), Vector(self.HALF, self.WIDTH, self.TOP))
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetCollisionGroup(COLLISION_GROUP_WEAPON)
		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:SetMass(self.MASS)
			phys:SetMaterial("gmod_ice")
			phys:Wake()
		end
	end

	-- let go: velocity (units/s), rolling friction (units/s per second, on
	-- the ground only: in the air it flies freely)
	function ENT:Launch(velocity, friction)
		local phys = self:GetPhysicsObject()
		if not IsValid(phys) then return end
		self.friction = friction or 0
		phys:SetDamping(0, 1.5)
		phys:SetVelocity(velocity)
		phys:Wake()
	end

	-- the ground under the wheels (a trace from the deck down its own up
	-- axis): its normal, or nil while it's in the air
	function ENT:Ground()
		local pos, up = self:GetPos(), self:GetUp()
		local tr = util.TraceLine({ start = pos, endpos = pos - up * (-self.BOTTOM + 4), filter = self, mask = MASK_SOLID })
		if tr.Hit then return tr.HitNormal, true end
		tr = util.TraceLine({ start = pos, endpos = pos - Vector(0, 0, 8), filter = self, mask = MASK_SOLID })
		if tr.Hit then return tr.HitNormal, false end
	end

	-- every server tick, on the ground: it rolls like a skateboard. Wheels
	-- down, it rolls along its length (slowed by the host's grip; gravity
	-- still pulls it down slopes) and hardly at all sideways, and stops spinning; on its
	-- side or upside down it scrapes to a stop. In the air it flies freely.
	ENT.SIDE_GRIP, ENT.SPIN_GRIP, ENT.SCRAPE = 14, 10, 3
	ENT.cvDebug = CreateConVar("skategm_golf_debug", "0", FCVAR_NONE, "Board Golf: print the ball's speed and grip twice a second", 0, 1)
	function ENT:Think()
		local now = CurTime()
		local dt = math.Clamp(now - (self.lastGrip or now), 0, 0.1)
		self.lastGrip = now
		local phys = self:GetPhysicsObject()
		if dt > 0 and IsValid(phys) and phys:IsMotionEnabled() then
			local normal, wheels = self:Ground()
			if normal then
				local v = phys:GetVelocity()
				local up = self:GetUp()
				if wheels and up:Dot(normal) > 0.6 then
					local fwd = self:GetForward()
					fwd = fwd - normal * fwd:Dot(normal)
					if fwd:LengthSqr() > 1e-4 then
						fwd:Normalize()
						local side = normal:Cross(fwd)
						local along, across, into = v:Dot(fwd), v:Dot(side), v:Dot(normal)
						local roll = (self.friction or 0) * dt
						along = along > 0 and math.max(0, along - roll) or math.min(0, along + roll)
						across = across * math.exp(-self.SIDE_GRIP * dt)
						phys:SetVelocity(fwd * along + side * across + normal * into)
					end
					local spin = phys:GetAngleVelocity()
					phys:AddAngleVelocity(-spin * math.min(1, self.SPIN_GRIP * dt))
				else
					local flat = v - normal * v:Dot(normal)
					local speed = flat:Length()
					if speed > 0.01 then
						local slow = math.min(speed, ((self.friction or 0) * self.SCRAPE + 200) * dt)
						phys:SetVelocity(v - flat / speed * slow)
					end
				end
			end
		end
		if self.cvDebug:GetBool() and now >= (self.nextDebug or 0) then
			self.nextDebug = now + 0.5
			local normal, wheels = self:Ground()
			print(string.format("[SkateGM golf] speed %.0f, ground %s, wheels down %s, grip %s", IsValid(phys) and phys:GetVelocity():Length() or -1,
				tostring(normal ~= nil), tostring(wheels == true), tostring(self.friction)))
		end
		self:NextThink(now)
		return true
	end

	-- over the cup slowly enough: it drops in (held, drawn sinking into it)
	function ENT:Sink(cup)
		local phys = self:GetPhysicsObject()
		if IsValid(phys) then phys:EnableMotion(false) end
		self:SetNW2Vector("SkateGMSinkTo", cup)
		self:SetNW2Float("SkateGMSinkAt", CurTime())
	end

	function ENT:Speed()
		local phys = self:GetPhysicsObject()
		return IsValid(phys) and phys:GetVelocity():Length() or 0
	end
end

if CLIENT then
	-- the pose SkateGM's board drawing wants, from this prop's place
	function ENT:BoardPose()
		local pos, fwd, right, up = self:GetPos(), self:GetForward(), self:GetRight(), self:GetUp()
		local at = self:GetNW2Float("SkateGMSinkAt", 0)
		if at > 0 then
			local k = math.Clamp((CurTime() - at) / 0.6, 0, 1)
			local cup = self:GetNW2Vector("SkateGMSinkTo", pos)
			local over = Vector(cup.x, cup.y, pos.z)
			pos = LerpVector(math.min(1, k * 2), pos, over) - Vector(0, 0, 34 * k * k)
		end
		local wb = self.WHEELBASE
		local axle = up * (self.BOTTOM + 1.15)
		local tf, tb = pos + fwd * wb + axle, pos - fwd * wb + axle
		return {
			TRUCK_FRONT = tf, TRUCK_BACK = tb, SKATEBOARD_ROOT = pos,
			RIGHT_WHEELFRONT = tf + right * 3.4, LEFT_WHEELFRONT = tf - right * 3.4,
			RIGHT_WHEELBACK = tb + right * 3.4, LEFT_WHEELBACK = tb - right * 3.4,
		}
	end

	function ENT:Draw()
		local S = SkateGM
		local P = self:BoardPose()
		local ply = self:GetSkater()
		local draw = S and S.DrawBoard
		if not draw then return end
		local look = BOARD and BOARD.client and IsValid(ply) and BOARD.client.LookFor(ply)
		local pc = IsValid(ply) and ply.GetPlayerColor and ply:GetPlayerColor()
		local graphic = pc and Color(math.Clamp(pc.x * 255, 30, 255), math.Clamp(pc.y * 255, 30, 255), math.Clamp(pc.z * 255, 30, 255)) or nil
		if not (BOARD and BOARD.client and BOARD.client.Draw and BOARD.client.Draw(ply, P, look, graphic, false, false, draw)) then
			draw(P, { graphic = graphic })
		end
	end
end
