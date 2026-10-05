local M={}
function M.New() return {frames={}} end
function M.Reset(b) b.frames={} b.tick=nil end
function M.Push(b,p,P,now)
	if not p.cam or not P or not P.HIPS then return end
	if p.tick~=nil and p.tick==b.tick then return end
	local frames=b.frames
	local last=frames[#frames]
	if last and ((P.HIPS-last.P.HIPS):LengthSqr()>256*256 or now-last.time>0.25) then M.Reset(b) frames=b.frames end
	local copy={}
	for name,v in pairs(P) do copy[name]=Vector(v.x,v.y,v.z) end
	local c=p.cam
	frames[#frames+1]={time=now,P=copy,state=p.state,cam={pos=Vector(unpack(c.pos)),ang=Vector(unpack(c.fwd)):AngleEx(Vector(unpack(c.up))),fov=c.fov or 90}}
	b.tick=p.tick
	while #frames>12 do table.remove(frames,1) end
end
function M.Sample(b,now)
	local frames=b.frames
	if #frames==0 then return end
	local at=now-1/30
	local a,z=frames[1],frames[#frames]
	for i=2,#frames do
		if frames[i].time>=at then z=frames[i] break end
		a=frames[i]
	end
	local t=math.Clamp((at-a.time)/math.max(z.time-a.time,0.0001),0,1)
	local P={}
	for name,v in pairs(z.P) do P[name]=LerpVector(t,a.P[name] or v,v) end
	local angle=LerpAngle(t,a.cam.ang,z.cam.ang)
	local pos=LerpVector(t,a.cam.pos,z.cam.pos)
	local f,u=angle:Forward(),angle:Up()
	return P,{pos={pos.x,pos.y,pos.z},fwd={f.x,f.y,f.z},up={u.x,u.y,u.z},fov=Lerp(t,a.cam.fov,z.cam.fov)},t<1 and a.state or z.state
end
return M
