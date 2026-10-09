local S = SkateGM

---------------------------------------------------------------------------
-- Name tags over other skaters (skategm_nametags, Settings > Display). Not
-- while watching a minigame (the spectator names who you watch), except
-- tags asked for: a replay's clip played with opts.nametag (Copycat's setter)
---------------------------------------------------------------------------
S.cvNametags = S.cvNametags or CreateClientConVar("skategm_nametags", "1", true, false, "Name tags over other skaters", 0, 1)
S.NAMETAG_FULL, S.NAMETAG_FAR, S.NAMETAG_LIFT = 1200, 2500, 16

function S.NametagFor(key)
	if type(key) == "table" and key.ghost then return key.nametag, true end
	if not (IsValid(key) and key.Nick) then return nil end
	if not S.cvNametags:GetBool() then return nil end
	local SP = SKATEGM_MODES and SKATEGM_MODES.spectate
	if SP and SP.on then return nil end
	if S.IsHidden(key) then return nil end
	return key:Nick(), false
end

-- every tag to draw now: { text, pos (over the head), asked }
function S.Nametags(now)
	local out = {}
	for key, r in pairs(S.remote) do
		local text, asked = S.NametagFor(key)
		if text and text ~= "" then
			local P = (S.API and S.API.PoseOf and S.API.PoseOf(key)) or S.RemotePose(r, now)
			local head = P and (P.HEAD or P.NECK or P.HIPS)
			if head then out[#out + 1] = { text = text, pos = head + Vector(0, 0, S.NAMETAG_LIFT), asked = asked, sub = not asked and S.InMenu(key) and "(in a menu)" or nil } end
		end
	end
	return out
end

local fontMade
function S.PaintNametags(now)
	local tags = S.Nametags(now)
	if #tags == 0 then return end
	if not fontMade then
		surface.CreateFont("skategm_nametag", { font = "Roboto", size = math.max(16, math.floor(ScrH() * 0.022)), weight = 800 })
		surface.CreateFont("skategm_nametag_sub", { font = "Roboto", size = math.max(13, math.floor(ScrH() * 0.016)), weight = 600 })
		fontMade = true
	end
	local eye = (S.phase == "on" and S.view and S.view.origin) or EyePos()
	for _, t in ipairs(tags) do
		local d = eye:Distance(t.pos)
		local fade = t.asked and 1 or math.Clamp((S.NAMETAG_FAR - d) / (S.NAMETAG_FAR - S.NAMETAG_FULL), 0, 1)
		if fade > 0 then
			local tr = not t.asked and util.TraceLine({ start = eye, endpos = t.pos, mask = MASK_SOLID_BRUSHONLY })
			if not (tr and tr.Hit) then
				local s = t.pos:ToScreen()
				if s.visible then
					draw.SimpleTextOutlined(t.text, "skategm_nametag", s.x, s.y, Color(255, 255, 255, 235 * fade), TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, Color(0, 0, 0, 200 * fade))
					if t.sub then draw.SimpleTextOutlined(t.sub, "skategm_nametag_sub", s.x, s.y + 2, Color(200, 200, 200, 220 * fade), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, Color(0, 0, 0, 180 * fade)) end
				end
			end
		end
	end
end

hook.Add("HUDPaint", "skategm_nametags", function() pcall(S.PaintNametags, RealTime()) end)
