local SPARKS = BOARD.RegisterEffect({
	id = "sparks", title = "Grind sparks", order = 3,
	fields = {
		{ key = "on", kind = "bool", convar = "skategm_sparks", default = false, label = "Grind sparks" },
		{ key = "mode", kind = "choice", convar = "skategm_sparks_mode", choices = { "Hot metal", "My player colour", "Rainbow", "Custom colour" }, default = 1, label = "Spark colour" },
		{ key = "color", kind = "color", convar = "skategm_sparks_color", default = "120 200 255", label = "Sparks: custom colour", showWhen = { "mode", 4 } },
		{ key = "amount", kind = "number", convar = "skategm_sparks_amount", min = 1, max = 10, default = 5, decimals = 0, label = "Spark amount" },
	},
})

if not CLIENT then return end

SPARKS.WOOD = { GrindBoardslide = true, GrindTipslide = true, GrindDarkslide = true }

function SPARKS.enabled(o) return o.on == true end

function SPARKS.Points(B, state)
	if SPARKS.WOOD[state] then return { B.centre + B.up * 1.5 } end
	return { (B.rf + B.lf) / 2, (B.rb + B.lb) / 2 }
end

function SPARKS.Colour(ctx)
	local o = ctx.opts
	if (o.mode or 1) == 1 then return Color(255, math.random(150, 230), math.random(40, 110)) end
	return ctx.C.FxColour(o.mode - 1, o.color, ctx.ply, ctx.now, math.random(0, 60))
end

function SPARKS.Count(ctx)
	local amount = ctx.opts.amount or 5
	local n = amount * math.Clamp(ctx.speed / 250, 0.2, 2) * (ctx.dt * 60)
	if SPARKS.WOOD[ctx.state] then n = n * 0.35 end
	local whole = math.floor(n)
	if math.random() < n - whole then whole = whole + 1 end
	return whole
end

function SPARKS.draw(ctx)
	if not ctx.newFrame or type(ctx.state) ~= "string" or ctx.state:sub(1, 5) ~= "Grind" or not ParticleEmitter then return end
	local B = ctx.B
	local data = ctx.data
	local points = SPARKS.Points(B, ctx.state)
	if not data.em then data.em = ParticleEmitter(points[1]) end
	local em = data.em
	if not em then return end
	local back = -B.fwd * math.max(ctx.speed, 80)
	for _, at in ipairs(points) do
		em:SetPos(at)
		for _ = 1, SPARKS.Count(ctx) do
			local pt = em:Add("effects/spark", at - B.up * 1.5)
			if pt then
				local col = SPARKS.Colour(ctx)
				pt:SetVelocity(back * math.Rand(0.4, 0.9) + B.up * math.Rand(30, 110) + B.right * math.Rand(-60, 60))
				pt:SetGravity(Vector(0, 0, -600))
				pt:SetDieTime(math.Rand(0.25, 0.6))
				pt:SetStartAlpha(255) pt:SetEndAlpha(0)
				pt:SetStartSize(math.Rand(1, 2)) pt:SetEndSize(0)
				pt:SetStartLength(math.Rand(4, 9)) pt:SetEndLength(1)
				pt:SetColor(col.r, col.g, col.b)
				pt:SetCollide(true)
				pt:SetBounce(0.3)
			end
		end
	end
end

function SPARKS.off(data)
	if data.em then data.em:Finish() data.em = nil end
end
