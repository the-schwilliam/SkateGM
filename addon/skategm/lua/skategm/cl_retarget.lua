local M={}
local mapping={
	{"Pelvis","HIPS","Spine"},{"Spine","SPINE","Spine1"},
	{"Spine1","SPINE1","Spine2"},{"Spine2","SPINE3","Neck1"},
	{"Neck1","NECK"},{"Head1","HEAD"},
	{"L_Clavicle","LEFTSHOULDER","L_UpperArm"},{"L_UpperArm","LEFTARM","L_Forearm"},
	{"L_Forearm","LEFTFOREARM","L_Hand"},{"L_Hand","LEFTHAND"},
	{"R_Clavicle","RIGHTSHOULDER","R_UpperArm"},{"R_UpperArm","RIGHTARM","R_Forearm"},
	{"R_Forearm","RIGHTFOREARM","R_Hand"},{"R_Hand","RIGHTHAND"},
	{"L_Thigh","LEFTUPLEG","L_Calf"},{"L_Calf","LEFTLEG","L_Foot"},
	{"L_Foot","LEFTFOOT","L_Toe0"},{"L_Toe0","LEFTTOEBASE"},
	{"R_Thigh","RIGHTUPLEG","R_Calf"},{"R_Calf","RIGHTLEG","R_Foot"},
	{"R_Foot","RIGHTFOOT","R_Toe0"},{"R_Toe0","RIGHTTOEBASE"},
}
local R=include("skategm/cl_retarget_math.lua")
function M.HeadYaw(ent,P,now)
	local previous=ent.Sk8GazeSample
	local dt=previous and now-previous.time or 0
	local target=0
	if P.HIPS and P.SPINE and P.RIGHTUPLEG and P.LEFTUPLEG then
		local right=P.RIGHTUPLEG-P.LEFTUPLEG
		local up=P.SPINE-P.HIPS
		local forward=up:Cross(right)
		local velocity
		if previous and dt>0.0001 and dt<0.2 then
			local delta=P.HIPS-previous.pos
			if delta:LengthSqr()<128*128 then velocity=delta/dt end
		end
		if velocity and velocity.x^2+velocity.y^2>30^2 then ent.Sk8GazeTravel=velocity end
		local travel=ent.Sk8GazeTravel
		if travel and forward.x^2+forward.y^2>0.001 then
			local difference=math.deg(math.atan2(travel.y,travel.x)-math.atan2(forward.y,forward.x))
			difference=(difference+180)%360-180
			target=math.Clamp(difference*0.8,-60,60)
		end
	end
	local state=ent.Sk8State or ""
	if state:find("Wipeout",1,true) or state:find("Biped",1,true) then target=0 end
	if dt>=0.2 then ent.Sk8GazeTravel=nil target=0 end
	if not previous or dt>0.0001 then
		ent.Sk8GazeSample={pos=Vector(P.HIPS.x,P.HIPS.y,P.HIPS.z),time=now}
		ent.Sk8GazeYaw=(ent.Sk8GazeYaw or 0)+(target-(ent.Sk8GazeYaw or 0))*(1-math.exp(-8*math.Clamp(dt,0,0.1)))
	end
	return ent.Sk8GazeYaw or 0
end
M.ON_BOARD,M.OFF_BOARD=30,60
function M.ScaleOrigin(P)
	local board,hips=P.SKATEBOARD_ROOT,P.HIPS
	if not board or not hips then return board or hips end
	local feet=(P.LEFTFOOT and P.RIGHTFOOT) and (P.LEFTFOOT+P.RIGHTFOOT)/2 or hips
	local w=math.Clamp((M.OFF_BOARD-feet:Distance(board))/(M.OFF_BOARD-M.ON_BOARD),0,1)
	return hips+(board-hips)*w
end
M.MIN_LINK=0.5
function M.LinkFor(id,links,base)
	local child,seen=links[id],0
	while child and base[child] and base[id] and seen<8 and (base[child]:GetTranslation()-base[id]:GetTranslation()):Length()<M.MIN_LINK do
		child,seen=links[child],seen+1
	end
	if child and base[child] and base[id] and (base[child]:GetTranslation()-base[id]:GetTranslation()):Length()<M.MIN_LINK then return nil end
	return child
end
function M.Apply(ent,P)
	local count=ent:GetBoneCount()
	local names,points={},{}
	for name,point in pairs(P or {}) do names[#names+1]=name points[#points+1]=point end
	local pose={boneNames=names,bones=points,board=M.ScaleOrigin(P)}
	local bind=ent.Sk8Bind
	if not pose or not pose.boneNames or not bind then return end
	local joints={}
	for i,name in ipairs(pose.boneNames) do joints[name]=pose.bones[i] end
	local world=Matrix() world:SetAngles(ent:GetAngles()) world:SetTranslation(ent:GetPos())
	local modelScale=ent:GetModelScale() world:Scale(Vector(modelScale,modelScale,modelScale))
	local base,targets,links={},{},{}
	for id,matrix in pairs(bind) do base[id]=world*matrix end
	local function bone(name) return ent:LookupBone("ValveBiped.Bip01_"..name) end
	local pelvis,spine,left,right=bone("Pelvis"),bone("Spine"),bone("L_Thigh"),bone("R_Thigh")
	if not pelvis or not base[pelvis] or not joints.HIPS then return end
	local scale=1
	local calf,foot=bone("L_Calf"),bone("L_Foot")
	if left and calf and foot and base[left] and base[calf] and base[foot] and joints.LEFTUPLEG and joints.LEFTLEG and joints.LEFTFOOT then
		local nativeLength=joints.LEFTUPLEG:Distance(joints.LEFTLEG)+joints.LEFTLEG:Distance(joints.LEFTFOOT)
		local modelLength=base[left]:GetTranslation():Distance(base[calf]:GetTranslation())+base[calf]:GetTranslation():Distance(base[foot]:GetTranslation())
		if nativeLength>1 then scale=math.Clamp(modelLength/nativeLength,0.1,10) end
	end
	for _,entry in ipairs(mapping) do
		local id=bone(entry[1])
		if id and base[id] and joints[entry[2]] then
			targets[id]=pose.board+(joints[entry[2]]-pose.board)*scale
			links[id]=entry[3] and bone(entry[3]) or nil
		end
	end
	local rootTurn=Matrix()
	if spine and left and right and base[spine] and base[left] and base[right] and joints.SPINE and joints.RIGHTUPLEG and joints.LEFTUPLEG then
		local rest=R.Body(base[spine]:GetTranslation()-base[pelvis]:GetTranslation(),base[right]:GetTranslation()-base[left]:GetTranslation())
		local target=R.Body(joints.SPINE-joints.HIPS,joints.RIGHTUPLEG-joints.LEFTUPLEG)
		if rest and target then rootTurn=target*rest:GetInverse() end
	end
	local head=bone("Head1")
	local headYaw=RealTime and M.HeadYaw(ent,joints,RealTime()) or 0
	local finished,engineMatrices={},{}
	local function engine(id)
		if engineMatrices[id]==nil then engineMatrices[id]=ent:GetBoneMatrix(id) or false end
		return engineMatrices[id] or nil
	end
	local function solve(id,depth)
		if finished[id] then return finished[id] end
		if depth>count then return end
		local parent=ent:GetBoneParent(id)
		if not base[id] then
			local own=engine(id)
			if not own then return end
			local parentMatrix=parent>=0 and solve(parent,depth+1) or nil
			local parentOwn=parent>=0 and engine(parent) or nil
			local inverse=parentOwn and parentOwn:GetInverse()
			local matrix=(parentMatrix and inverse) and parentMatrix*inverse*own or Matrix(own)
			finished[id]=matrix return matrix
		end
		local matrix=Matrix(base[id])
		local parentMatrix=parent>=0 and solve(parent,depth+1) or nil
		local inverse=base[parent] and base[parent]:GetInverse()
		if parentMatrix and inverse then matrix=parentMatrix*inverse*base[id] end
		if id==pelvis then
			matrix=Matrix(base[id]) matrix:SetTranslation(vector_origin)
			matrix=rootTurn*matrix matrix:SetTranslation(targets[id])
		else
			local child=M.LinkFor(id,links,base)
			if child and targets[id] and targets[child] and base[child] then
				local inverseBone=base[id]:GetInverse()
				if inverseBone then
					local inheritedChild=matrix*inverseBone*base[child]
					local from=inheritedChild:GetTranslation()-matrix:GetTranslation()
					local to=targets[child]-targets[id]
					local position=matrix:GetTranslation()
					local turn=R.Swing(from,to,matrix:GetUp())
					matrix:SetTranslation(vector_origin)
					matrix=turn*matrix matrix:SetTranslation(position)
				end
			end
		end
		if id==head and math.abs(headYaw)>0.001 then
			local position=matrix:GetTranslation()
			local turn=Matrix() turn:SetAngles(Angle(0,headYaw,0))
			matrix:SetTranslation(vector_origin)
			matrix=turn*matrix matrix:SetTranslation(position)
		end
		finished[id]=matrix return matrix
	end
	for i=0,count-1 do solve(i,0) end
	local offset=Vector(0,0,0) local feet=0
	for _,name in ipairs({"L_Foot","R_Foot"}) do
		local id=bone(name)
		if id and targets[id] and finished[id] then offset=offset+targets[id]-finished[id]:GetTranslation() feet=feet+1 end
	end
	if feet>0 then offset=offset/feet end
	for id,matrix in pairs(finished) do
		matrix:SetTranslation(matrix:GetTranslation()+offset)
		local name=ent:GetBoneName(id)
		if name and name~="__INVALIDBONE__" and ent:BoneHasFlag(id,BONE_USED_BY_ANYTHING) then
			ent:SetBoneMatrix(id,matrix)
		end
	end
end
function M.Bind(ent)
	local ok,_,poses=pcall(util.GetModelMeshes,ent:GetModel())
	local bind={}
	if ok and poses then
		for id,p in pairs(poses) do if p.matrix then bind[id]=p.matrix:GetInverse() end end
	end
	local world=Matrix() world:SetAngles(ent:GetAngles()) world:SetTranslation(ent:GetPos())
	local inv=world:GetInverse()
	for id=0,ent:GetBoneCount()-1 do
		if not bind[id] then local m=ent:GetBoneMatrix(id) if m then bind[id]=inv*m end end
	end
	if next(bind) then ent.Sk8Bind=bind end
end
return M
