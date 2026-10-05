local virtualPad=CreateClientConVar("skategm_virtual_pad","0",true,false,"Keyboard as a virtual controller inside SkateGM",0,1)
local cvKeyboard=CreateClientConVar("skategm_keyboard","1",true,false,"Keyboard and mouse controls while skating (a controller always works too)",0,1)
local K={keys={},release=false}
function K.Enabled() return cvKeyboard:GetBool() end
K.LAYOUT={KEY_W,KEY_A,KEY_S,KEY_D,KEY_SPACE,KEY_LSHIFT,KEY_F,KEY_Z,KEY_C,KEY_I,KEY_K,KEY_U,KEY_O,KEY_ENTER,
	KEY_Q,KEY_E,KEY_LEFT,KEY_RIGHT,KEY_UP,KEY_DOWN,KEY_LALT,KEY_R,KEY_L,KEY_LCONTROL,KEY_BACKSPACE}
function K.Uses(code)
	if not code or not K.Enabled() then return false end
	for _,k in ipairs(K.LAYOUT) do if k==code then return true end end
	return false
end
function K.Blocked(S)
	if not (gui and vgui) then return true end
	return (S.InputBlockWanted and S.InputBlockWanted()) or gui.IsGameUIVisible() or vgui.CursorVisible() or (system.HasFocus and not system.HasFocus())
end
function K.Menu() return SKATEGM_UI~=nil and SKATEGM_UI.open~=nil end
function K.Read(state,blocked,menu)
	local function held(k) return not blocked and input.IsKeyDown(k) end
	local b=0
	for _,v in ipairs({{KEY_W,0x1000},{KEY_SPACE,0x1000},{KEY_LSHIFT,0x4000},{KEY_S,0x2000},{KEY_F,0x8000},{KEY_Z,0x100},{KEY_C,0x200},{KEY_I,1},{KEY_K,2},{KEY_U,4},{KEY_O,8},{KEY_ENTER,0x10},{KEY_LCONTROL,0x80}}) do
		if held(v[1]) then b=bit.bor(b,v[2]) end
	end
	local function axis(positive,negative) return (held(positive) and 1 or 0)-(held(negative) and 1 or 0) end
	local lx,ly,rx,ry=axis(KEY_D,KEY_A),0,axis(KEY_RIGHT,KEY_LEFT),axis(KEY_UP,KEY_DOWN)
	if held(KEY_LALT) then ry=ry*.5 end
	if menu or (state and (state:find("Biped",1,true) or state=="OffBoardPushing")) then
		ly=axis(KEY_W,KEY_S) b=bit.band(b,bit.bnot(0x3000))
		if held(KEY_SPACE) then b=bit.bor(b,0x1000) end
		if menu and held(KEY_BACKSPACE) then b=bit.bor(b,0x2000) end
	end
	local lt,rt=held(KEY_Q) and 1 or 0,held(KEY_E) and 1 or 0
	return {b,lt,rt,lx,ly,rx,ry},b~=0 or lx~=0 or ly~=0 or rx~=0 or ry~=0 or lt~=0 or rt~=0
end
function K.Step(S,p,dt)
	if not K.Enabled() then
		skategm.Step(dt,true,0,0,0,0,0,0,0)
		S.keyboardActive=false
		S.keyboardButtons=0
		S.flickitInput={x=p.padRX or 0,y=p.padRY or 0}
		return
	end
	local blocked=K.Blocked(S)
	local values,active=K.Read(p.state,blocked)
	local useKeyboard=(virtualPad:GetBool() and not K.hardware) or active or K.release
	if active then K.owner="keyboard" end
	K.release=active
	skategm.Step(dt,not useKeyboard,unpack(values))
	S.keyboardActive=active
	S.keyboardButtons=useKeyboard and values[1] or 0
	S.flickitInput={x=blocked and 0 or (useKeyboard and values[6] or p.padRX or 0),
		y=blocked and 0 or (useKeyboard and values[7] or p.padRY or 0)}
end
function K.Shortcuts(S)
	if not K.Enabled() then K.look=nil return end
	local blocked=K.Blocked(S)
	local function edge(key)
		local down=input.IsKeyDown(key) local changed=down and not K.keys[key]
		K.keys[key]=down return changed and not blocked
	end
	if edge(KEY_R) and S.phase=="on" then S.Respawn() end
	if edge(KEY_L) then K.look=nil end
	if S.phase~="on" then K.look=nil end
end
function K.Mouse(S,x,y)
	if not K.Enabled() or S.phase~="on" or K.Blocked(S) or S.viewOverride then return end
	if x==0 and y==0 then return end
	if not K.look then K.cameraWarningUntil=RealTime()+5 end
	local a=K.look or (S.view and S.view.angles) or LocalPlayer():EyeAngles()
	local sensitivity=GetConVar("sensitivity"):GetFloat()*.022
	K.look=Angle(math.Clamp(a.p+y*sensitivity,-55,70),math.NormalizeAngle(a.y-x*sensitivity),0)
end
function K.Camera(S,pos,ang)
	if not K.look or not S.renderP or not S.renderP.HIPS then return pos,ang end
	local target=S.renderP.HIPS+Vector(0,0,18)
	local distance=math.Clamp((pos-target):Length(),60,250)
	local desired=target-K.look:Forward()*distance
	local tr=util.TraceHull({start=target,endpos=desired,mins=Vector(-5,-5,-5),maxs=Vector(5,5,5),filter={LocalPlayer(),S.skater},mask=MASK_SOLID})
	return tr.Hit and (tr.HitPos+tr.HitNormal*2) or desired,K.look
end
function K.VirtualPad(S)
	if not K.Enabled() then return end
	if K.hardware and K.owner~="keyboard" then return end
	if not virtualPad:GetBool() and K.owner~="keyboard" then return end
	local blocked=gui.IsGameUIVisible() or (system.HasFocus and not system.HasFocus())
	local v,active=K.Read(S.pose and S.pose.state,blocked,K.Menu())
	if active then K.owner="keyboard" end
	return {buttons=v[1],lt=v[2],rt=v[3],lx=v[4],ly=v[5],rx=v[6],ry=v[7]}
end
function K.Decorate(S,p)
	if type(p)~="table" then return p end
	K.hardware=p.pad==true
	if K.hardware and ((p.padButtons or 0)~=0 or math.abs(p.padLX or 0)>.2 or math.abs(p.padLY or 0)>.2 or math.abs(p.padRX or 0)>.2 or math.abs(p.padRY or 0)>.2 or (p.padLT or 0)>.2 or (p.padRT or 0)>.2) then
		K.owner="hardware"
		K.look=nil
	end
	if K.hardware or not virtualPad:GetBool() then return p end
	local v=K.Read(p.state,K.Blocked(S))
	p.pad=true
	p.padButtons,p.padLT,p.padRT,p.padLX,p.padLY,p.padRX,p.padRY=unpack(v)
	return p
end

function K.IsKeyboard()
	return K.owner=="keyboard" or (K.owner~="hardware" and not K.hardware)
end

surface.CreateFont("skategm_camera_warning_title",{font="Bahnschrift",size=22,weight=600,extended=true})
surface.CreateFont("skategm_camera_warning_hint",{font="Bahnschrift",size=18,weight=400,extended=true})
hook.Add("HUDPaint","skategm_mouse_camera_warning",function()
	local S=SkateGM
	if not S or S.phase~="on" or not K.look or not S.renderP or not S.renderP.HIPS then return end
	local remaining=(K.cameraWarningUntil or 0)-RealTime()
	if remaining<=0 then return end
	local fade=math.Clamp(remaining,0,1)
	local alpha=math.floor(255*fade*fade*(3-2*fade))
	if S.viewOverride or K.Blocked(S) or (SKATEGM_UI and SKATEGM_UI.Busy()) then return end
	if S.replay and (S.replay.on or S.replay.hudHidden) then return end
	local hud=GetConVar("cl_drawhud")
	if hud and not hud:GetBool() then return end
	local title="Free mouse camera enabled"
	local hint="Press L or use your controller to return to the Skate 3 camera"
	local x,y=20,20
	draw.SimpleText(title,"skategm_camera_warning_title",x,y,Color(255,205,100,alpha))
	draw.SimpleText(hint,"skategm_camera_warning_hint",x,y+26,Color(235,235,235,alpha))
end)
return K
