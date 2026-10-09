-- punches on RB (skategm_punch/)
AddCSLuaFile("skategm_punch/sh_punch.lua")
AddCSLuaFile("skategm_punch/cl_punch.lua")
include("skategm_punch/sh_punch.lua")
if SERVER then include("skategm_punch/sv_punch.lua") else include("skategm_punch/cl_punch.lua") end
