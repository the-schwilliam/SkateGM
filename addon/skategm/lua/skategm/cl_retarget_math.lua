local R={}
function R.Swing(from,to,hint)
	local m=Matrix()
	if from:LengthSqr()<1e-8 or to:LengthSqr()<1e-8 then return m end
	local a,b=from:GetNormalized(),to:GetNormalized()
	local cosine=math.Clamp(a:Dot(b),-1,1)
	if cosine>0.999999 then return m end
	local axis=a:Cross(b)
	local sine=axis:Length()
	if sine<1e-6 then
		axis=hint-a*a:Dot(hint)
		if axis:LengthSqr()<1e-8 then
			local fallback=math.abs(a.x)<0.8 and Vector(1,0,0) or Vector(0,1,0)
			axis=fallback-a*a:Dot(fallback)
		end
		axis=axis:GetNormalized() sine=0 cosine=-1
	else axis=axis/sine end
	local x,y,z=axis.x,axis.y,axis.z
	local t=1-cosine
	local rows={
		{t*x*x+cosine,t*x*y-sine*z,t*x*z+sine*y},
		{t*x*y+sine*z,t*y*y+cosine,t*y*z-sine*x},
		{t*x*z-sine*y,t*y*z+sine*x,t*z*z+cosine},
	}
	for row=1,3 do for col=1,3 do m:SetField(row,col,rows[row][col]) end end
	return m
end
function R.Body(up,right)
	if up:LengthSqr()<1e-8 or right:LengthSqr()<1e-8 then return nil end
	local z=up:GetNormalized()
	local y=right-z*z:Dot(right)
	if y:LengthSqr()<1e-8 then return nil end
	y=y:GetNormalized()
	local x=y:Cross(z):GetNormalized()
	local m=Matrix()
	for col,v in ipairs({x,y,z}) do m:SetField(1,col,v.x) m:SetField(2,col,v.y) m:SetField(3,col,v.z) end
	return m
end
return R
