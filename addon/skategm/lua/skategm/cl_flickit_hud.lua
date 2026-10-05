local enabled=CreateClientConVar("skategm_flickit_hud","0",true,false,"Show the Flick-it stick display",0,1)
local F={trail={}}
function F.Input(S)
	local input=S.flickitInput or {}
	return math.Clamp(input.x or 0,-1,1),math.Clamp(input.y or 0,-1,1)
end
function F.Visible(S)
	local hud=GetConVar("cl_drawhud")
	local master=GetConVar("skategm_hud")
	return enabled:GetBool() and (not master or master:GetBool()) and S and S.phase=="on" and not S.inputBlocked
		and not (hud and not hud:GetBool()) and not (S.replay and (S.replay.on or S.replay.hudHidden))
		and not (SKATEGM_UI and SKATEGM_UI.Busy())
end
hook.Add("HUDPaint","skategm_flickit_hud",function()
	local S=SkateGM
	if not F.Visible(S) then F.trail={} return end
	local now=RealTime()
	local x,y=F.Input(S)
	local radius=math.Clamp(ScrH()*.043,30,64)
	local cx,cy=ScrW()-radius-32,ScrH()-radius-54
	local px,py=cx+x*(radius-7),cy-y*(radius-7)
	local last=F.trail[#F.trail]
	if not last or ((last.x-x)^2+(last.y-y)^2)>.0004 then F.trail[#F.trail+1]={x=x,y=y,t=now} end
	while #F.trail>32 or (#F.trail>0 and now-F.trail[1].t>.4) do table.remove(F.trail,1) end
	draw.RoundedBox(radius,cx-radius,cy-radius,radius*2,radius*2,Color(12,18,24,175))
	surface.DrawCircle(cx,cy,radius,Color(110,210,245,220))
	surface.SetDrawColor(160,185,195,65)
	surface.DrawLine(cx-radius+5,cy,cx+radius-5,cy)
	surface.DrawLine(cx,cy-radius+5,cx,cy+radius-5)
	for i=2,#F.trail do
		local a,b=F.trail[i-1],F.trail[i]
		surface.SetDrawColor(110,210,245,math.Clamp(1-(now-b.t)/.4,0,1)*150)
		surface.DrawLine(cx+a.x*(radius-7),cy-a.y*(radius-7),cx+b.x*(radius-7),cy-b.y*(radius-7))
	end
	draw.RoundedBox(5,px-5,py-5,10,10,Color(245,245,245))
	draw.SimpleText("FLICK-IT","DermaDefaultBold",cx,cy+radius+10,color_white,TEXT_ALIGN_CENTER,TEXT_ALIGN_TOP)
end)
return F
