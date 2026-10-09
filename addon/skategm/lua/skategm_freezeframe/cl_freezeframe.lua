-- Freeze Frame, client: left stick in freezes me and opens the photo camera
-- (move, FOV, filter, A takes it); every photo drawn again here from its
-- camera and skeleton; the vote for the worst one.
if not (SKATEGM_UI and SKATEGM_UI.pad) then include("skategm_ui/cl_pad.lua") end
local UI = SKATEGM_UI
local PAD = UI.pad
local B = PAD.B
local FF = FREEZEFRAME
local C = { state = { phase = "idle" }, padPrev = 0, sel = 1 }
FF.client = C

local API = SKATEGM_MODES.API
local function Send(t) FF.mode:Send(t) end
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) FF.mode:Say(text, bad) end
local PINK, GOLD, GREY, RED = Color(255, 120, 170), Color(255, 210, 90), Color(190, 190, 190), Color(235, 85, 95)
local SHOWING = { show = true, vote = true, out = true }
C.CAM_SPEED, C.FOV_STEP = 160, 5

function C.Me(st) return FF.mode:Me(st) end
function C.MyEnt() return LocalPlayer():EntIndex() end
function C.Alive(st) local me = C.Me(st) return me ~= nil and me.alive == true end
function C.Photo(st, i) return st.photos and st.photos[i] end
function C.Choices(st)
	local out = {}
	for _, ph in ipairs(st.photos or {}) do if ph.ent ~= C.MyEnt() then out[#out + 1] = ph end end
	return out
end
function C.FilterName(id)
	local R = SkateGM and SkateGM.replay
	for _, f in ipairs(R and R.FILTERS or {}) do if f.id == id then return f.name end end
	return id
end

---------------------------------------------------------------------------
-- taking my photo
---------------------------------------------------------------------------
local function V(t) return Vector(t[1], t[2], t[3]) end
local function Plain(P)
	local out = {}
	for k, v in pairs(P) do out[k] = { v.x, v.y, v.z } end
	return out
end

function C.Snap()
	local a = API()
	local P = a and a.PoseOf and a.PoseOf(LocalPlayer())
	if not (P and P.HIPS) then return nil end
	local view = SkateGM and SkateGM.view
	local eye = view and view.origin and Vector(view.origin.x, view.origin.y, view.origin.z) or P.HIPS + Vector(-120, 0, 60)
	if eye:Distance(P.HIPS) > FF.CAM_RANGE then eye = P.HIPS + Vector(-120, 0, 60) end
	local ang = view and view.angles and eye:Distance(view.origin) < 1 and view.angles or (P.HIPS - eye):Angle()
	return { pose = Plain(P), hips = Vector(P.HIPS.x, P.HIPS.y, P.HIPS.z), cam = { pos = eye, ang = Angle(ang.p, ang.y, 0) }, fov = FF.FOV_DEFAULT, filter = 1 }
end

function C.Freeze(now)
	local a = API()
	local shot = C.Snap()
	if not shot then return end
	shot.at = now
	C.shot = shot
	if a.Freeze then a.Freeze(true, "freezeframe_shot") end
	UI.Take("freezeframe", C.Screen(), function(_, _, fov) return C.ComposeView(fov) end)
	if a.SetHidden then a.SetHidden("view", false) end
	if surface and surface.PlaySound then surface.PlaySound("npc/scanner/scanner_photo1.wav") end
end

function C.ComposeView()
	local s = C.shot
	if not s then return nil end
	local R = SkateGM and SkateGM.replay
	local id = FF.FILTERS[s.filter]
	return { origin = s.cam.pos, angles = s.cam.ang, fov = R and R.FilterFov and R.FilterFov(id, s.fov) or s.fov }
end

function C.Lock()
	local s = C.shot
	if not s or s.locked then return end
	s.locked = true
	Send({ cmd = "photo", pose = s.pose, cam = { pos = { s.cam.pos.x, s.cam.pos.y, s.cam.pos.z }, ang = { s.cam.ang.p, s.cam.ang.y, s.cam.ang.r }, fov = s.fov },
		filter = FF.FILTERS[s.filter] })
	if surface and surface.PlaySound then surface.PlaySound("npc/scanner/scanner_photo1.wav") end
end

function C.Screen()
	local screen = {}
	function screen.think(pad, now, dt)
		local s = C.shot
		if not s or s.locked then return end
		UI.Fly(s.cam, pad, dt, C.CAM_SPEED, 110, 2.5)
		local off = s.cam.pos - s.hips
		if off:Length() > FF.CAM_RANGE then s.cam.pos = s.hips + off:GetNormalized() * FF.CAM_RANGE end
	end
	function screen.press(btn)
		local s = C.shot
		if not s or s.locked then return end
		if btn == B.UP then s.fov = math.max(FF.FOV_MIN, s.fov - C.FOV_STEP)
		elseif btn == B.DOWN then s.fov = math.min(FF.FOV_MAX, s.fov + C.FOV_STEP)
		elseif btn == B.RIGHT then s.filter = s.filter % #FF.FILTERS + 1
		elseif btn == B.LEFT then s.filter = (s.filter - 2) % #FF.FILTERS + 1
		elseif btn == B.A then C.Lock()
		elseif btn == B.B then C.Unfreeze() end
	end
	function screen.close() end
	return screen
end

-- B: back to skating, to try again (the camera's work is dropped)
function C.Unfreeze()
	if not C.shot or C.shot.locked then return end
	if UI.IsOpen("freezeframe") then UI.Give("freezeframe") end
	C.shot = nil
	C.Thaw()
end

-- my skater, held still while I compose the photo
function C.Thaw()
	local a = API()
	if a and a.Freeze then a.Freeze(false, "freezeframe_shot") end
end

-- time's up without a photo: what the chase camera sees right now
function C.ChaseShot()
	local shot = C.Snap()
	if not shot then return end
	C.shot = shot
	C.Lock()
end

function C.EndShot()
	if UI.IsOpen("freezeframe") then UI.Give("freezeframe") end
	C.shot = nil
	C.Thaw()
end

---------------------------------------------------------------------------
-- showing a photo: its camera, its filter, its skater frozen as they were
---------------------------------------------------------------------------
function C.ShowPhoto(ph)
	local a = API()
	if not a then return end
	if a.StopClip then a.StopClip("freezeframe") end
	C.showing = ph
	if not ph then
		SKATEGM_MODES.GiveViewBack("freezeframe_photo")
		return
	end
	local ply = ph.ent == C.MyEnt() and LocalPlayer() or Entity(ph.ent)
	local P = {}
	for k, v in pairs(ph.pose or {}) do P[k] = V(v) end
	if a.PlayClip and IsValid(ply) then a.PlayClip("freezeframe", ply, C.StillClip(P, FF.VOTE + FF.SHOW * 2)) end
	local R = SkateGM and SkateGM.replay
	local view = { origin = V(ph.cam.pos), angles = Angle(ph.cam.ang[1], ph.cam.ang[2], ph.cam.ang[3]),
		fov = R and R.FilterFov and R.FilterFov(ph.filter, ph.cam.fov) or ph.cam.fov }
	if a.SetView then a.SetView(function() return view end, "freezeframe_photo") end
end

-- a still: the same pose again and again (a ghost fed nothing new fades out)
function C.StillClip(P, seconds)
	local clip = {}
	for i = 0, math.ceil(seconds * 10) do clip[#clip + 1] = { t = i / 10, P = P } end
	return clip
end

function C.WantedPhoto(st)
	if st.phase == "show" then return C.Photo(st, st.showIndex) end
	if st.phase == "vote" then
		local choices = C.Choices(st)
		if C.Alive(st) or C.Me(st) then
			C.sel = math.Clamp(C.sel or 1, 1, math.max(1, #choices))
			return choices[C.sel]
		end
	end
	if st.phase == "out" and st.out then
		for _, ph in ipairs(st.photos or {}) do if ph.ent == st.out.ent then return ph end end
	end
end

---------------------------------------------------------------------------
-- following the server
---------------------------------------------------------------------------
function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state, C.stateAt = st, now
	FF.mode:NoCollide(FF.mode:Me(st) ~= nil and st.phase == "shoot")
	local me, a = C.Me(st), API()
	if me and st.phase ~= "idle" and a and not a.IsSkating() and not a.IsLoading() and CanSkate() and not C.asked then
		C.asked = true
		a.StartSkating()
	end
	if not me then C.asked = nil end
	if (st.phase ~= "shoot" or st.round ~= prev.round) and C.shot then C.EndShot() end
	if st.phase == "vote" and prev.phase ~= "vote" then C.sel, C.myVote = 1, nil end
	local shooting = st.phase == "shoot" and C.Alive(st)
	if a and a.SetButtonMask and shooting ~= (C.masking or false) then
		C.masking = shooting
		a.SetButtonMask(shooting and FF.BUTTON or 0)
	end
	FF.mode:Spectate((st.phase == "shoot" and me and me.playing and not me.alive) and SKATEGM_MODES.Others(st, function(p) return p.alive end) or nil)
	local hold = (me ~= nil and SHOWING[st.phase]) or false
	if a and hold ~= (C.held or false) then
		C.held = hold
		if a.Freeze then a.Freeze(hold, "freezeframe") end
		if a.BlockInput then a.BlockInput(hold, "freezeframe") end
		if a.SetHidden then a.SetHidden("freezeframe", hold) end
		if a.HideOthers then a.HideOthers(hold, "freezeframe_show") end
	end
	local want = hold and C.WantedPhoto(st) or nil
	if want ~= C.showing and not (want and C.showing and want.ent == C.showing.ent and prev.phase == st.phase) then C.ShowPhoto(want) end
	if st.phase == "out" and prev.phase ~= "out" and st.out and surface and surface.PlaySound then surface.PlaySound("buttons/button10.wav") end
end
FF.mode:OnState(function(st, now) C.OnState(st, now) end)

function C.VoteInput(pressed)
	local st = C.state
	local choices = C.Choices(st)
	if #choices == 0 then return end
	local before = C.sel
	if bit.band(pressed, B.RIGHT) ~= 0 then C.sel = C.sel % #choices + 1 end
	if bit.band(pressed, B.LEFT) ~= 0 then C.sel = (C.sel - 2) % #choices + 1 end
	if C.sel ~= before then C.ShowPhoto(choices[C.sel]) end
	if bit.band(pressed, B.A) ~= 0 then
		C.myVote = choices[C.sel].ent
		Send({ cmd = "vote", target = C.myVote })
	end
end

function C.Think(now)
	local st, a = C.state, API()
	if not a or st.phase == "idle" then return end
	local pad = a.Pad and a.Pad()
	local buttons = pad and pad.buttons or 0
	local pressed = bit.band(buttons, bit.bnot(C.padPrev or 0))
	C.padPrev = buttons
	if st.phase == "shoot" and C.Alive(st) then
		local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
		if not C.shot and bit.band(pressed, FF.BUTTON) ~= 0 and a.IsSkating() then C.Freeze(now) end
		if left < 0.6 and not (C.shot and C.shot.locked) then
			if C.shot then C.Lock() elseif a.IsSkating() then C.ChaseShot() end
		end
	elseif st.phase == "vote" and C.Me(st) then
		C.VoteInput(pressed)
	end
end
hook.Add("Think", "skategm_freezeframe", function() C.Think(RealTime()) end)

hook.Add("RenderScreenspaceEffects", "skategm_freezeframe", function()
	local R = SkateGM and SkateGM.replay
	if not (R and R.DrawFilter) then return end
	local id = (C.shot and FF.FILTERS[C.shot.filter]) or (C.showing and C.showing.filter)
	if id and id ~= "none" then R.DrawFilter(id, RealTime(), ScrW(), ScrH(), { date = os and os.date and os.date("%b %d %Y") or "" }) end
end)

---------------------------------------------------------------------------
-- on screen
---------------------------------------------------------------------------
local FONTS = {
	skategm_ff_big = { "Coolvetica", 0.06, 500 },
	skategm_ff_mid = { "Coolvetica", 0.03, 500 },
	skategm_ff_small = { "Roboto", 0.018, 700 },
}
local function Text(t, font, x, y, col, ax) SKATEGM_MODES.Text(t, font, x, y, col, ax or TEXT_ALIGN_CENTER, 1) end

function C.Viewfinder(w, h)
	surface.SetDrawColor(255, 255, 255, 60)
	for k = 1, 2 do
		surface.DrawRect(w * k / 3, 0, 1, h)
		surface.DrawRect(0, h * k / 3, w, 1)
	end
	surface.SetDrawColor(255, 255, 255, 200)
	local m, l = h * 0.06, h * 0.08
	for _, c in ipairs({ { m, m, 1, 1 }, { w - m, m, -1, 1 }, { m, h - m, 1, -1 }, { w - m, h - m, -1, -1 } }) do
		surface.DrawRect(c[3] > 0 and c[1] or c[1] - l, c[2], l, 2)
		surface.DrawRect(c[1], c[4] > 0 and c[2] or c[2] - l, 2, l)
	end
end

function C.Caption(w, h, text, sub, col)
	surface.SetDrawColor(0, 0, 0, 190)
	surface.DrawRect(0, h * 0.86, w, h * 0.14)
	Text(text, "skategm_ff_mid", w / 2, h * 0.9, col or color_white)
	if sub then Text(sub, "skategm_ff_small", w / 2, h * 0.95, GREY) end
end

function C.Paint(w, h, now)
	if SKATEGM_MODES.HudHidden() then return end
	local st = C.state
	if st.phase == "idle" or st.phase == "lobby" then return end
	local me = C.Me(st)
	if not me then return end
	FF.mode:Fonts(FONTS)
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))
	local cx, line = w / 2, h * 0.035
	if st.phase == "countdown" then
		Text(string.format("ROUND %d", st.round or 1), "skategm_ff_mid", cx, h * 0.22, PINK)
		Text(tostring(math.max(1, math.ceil(left))), "skategm_ff_big", cx, h * 0.22 + line * 1.2, color_white)
		Text("skate, then left stick in to freeze and take your photo", "skategm_ff_small", cx, h * 0.22 + line * 3, GREY)
	elseif st.phase == "shoot" then
		local s = C.shot
		if s then
			if not s.locked then C.Viewfinder(w, h) end
			Text(s.locked and "PHOTO TAKEN: waiting for the others" or string.format("LINE UP YOUR PHOTO   %d", math.ceil(math.max(0, left))), "skategm_ff_mid", cx, h * 0.04, s.locked and GOLD or PINK)
			if not s.locked then
				PAD.Legend({
					{ keys = { "LS" }, text = "Move" }, { keys = { "RS" }, text = "Look" }, { keys = { "LT", "RT" }, text = "Down / up" },
					{ keys = { "UP", "DOWN" }, text = string.format("Zoom (FOV %d)", s.fov) },
					{ keys = { "LEFT", "RIGHT" }, text = "Filter: " .. C.FilterName(FF.FILTERS[s.filter]) },
					{ keys = { "A" }, text = "Take the photo" }, { keys = { "B" }, text = "Unfreeze" },
				}, w, h, "bottom")
			end
		elseif me.alive then
			Text(string.format("FREEZE FRAME   %d", math.ceil(math.max(0, left))), "skategm_ff_mid", cx, h * 0.04, PINK)
			local hint = "left stick in: freeze right here and take your photo (no photo by the end: the camera's view is it)"
			Text(PAD.T and PAD.T(hint) or hint, "skategm_ff_small", cx, h * 0.04 + line, GREY)
		else
			Text("you're out: watching", "skategm_ff_mid", cx, h * 0.04, GREY)
		end
	elseif st.phase == "show" then
		local ph = C.Photo(st, st.showIndex)
		if ph then C.Caption(w, h, ph.name, string.format("photo %d / %d", st.showIndex or 1, #(st.photos or {})), PINK) end
	elseif st.phase == "vote" then
		local choices = C.Choices(st)
		local ph = choices[C.sel or 1]
		Text(string.format("VOTE FOR THE WORST PHOTO   %d", math.ceil(math.max(0, left))), "skategm_ff_mid", cx, h * 0.04, RED)
		if ph then
			local voted = C.myVote == ph.ent
			C.Caption(w, h, "<   " .. ph.name .. (voted and "   (your vote)" or "") .. "   >", string.format("%d / %d", C.sel, #choices), voted and RED or color_white)
			PAD.Legend({ { keys = { "LEFT", "RIGHT" }, text = "Browse" }, { keys = { "A" }, text = "Vote this the worst" } }, w, h, { w * 0.02, h * 0.8 })
		end
	elseif st.phase == "out" and st.out then
		C.Caption(w, h, string.upper(st.out.name) .. " IS OUT", string.format("%d vote%s for the worst photo", st.out.votes or 0, st.out.votes == 1 and "" or "s"), RED)
	elseif st.phase == "results" then
		Text(st.winner and (string.upper(st.winner.name) .. " WINS") or "NOBODY WON", "skategm_ff_big", cx, h * 0.14, GOLD)
	end
	local x, y = w * 0.98, h * 0.3
	for _, p in ipairs(st.players or {}) do
		if p.playing then
			local mark = st.phase == "shoot" and (p.locked and "  photo taken" or "") or (st.phase == "vote" and (p.voted and "  voted" or "") or "")
			Text(p.name .. mark, "skategm_ff_small", x, y, p.alive and color_white or Color(140, 140, 140), TEXT_ALIGN_RIGHT)
			y = y + line * 0.8
		end
	end
end
hook.Add("HUDPaint", "skategm_freezeframe", function() C.Paint(ScrW(), ScrH(), RealTime()) end)

---------------------------------------------------------------------------
-- host menu
---------------------------------------------------------------------------
FF.mode:LobbyLines(function(st)
	return { string.format("%d s to get your photo", st.time or FF.TIME_DEFAULT), "left stick in to freeze, A takes it; worst photo is out" }
end)
FF.mode:Host({
	useStart = false,
	description = "take the best photo",
	about = "Everyone skates at once. Freeze yourself mid-trick with the left stick, line up the camera and take a photo. Everyone votes, and the worst photo each round is out.",
	options = {
		{ key = "time", label = "Time a round", type = "number", min = FF.TIME_MIN, max = FF.TIME_MAX, step = 10, default = FF.TIME_DEFAULT, format = function(v) return v .. " s" end },
	},
	start = function(v, mode) mode:Send({ cmd = "create", time = v.time, canSkate = CanSkate() }) end,
})
