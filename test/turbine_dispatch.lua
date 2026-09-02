-- Task 5 RED/GREEN: target-driven turbine dispatch and sustained-limit behavior.
dofile("test/cc_stubs.lua")
dofile("src/classes/deque.lua")
dofile("src/classes/turbine.lua")
SECONDS_TO_AVERAGE = 1
getEntitySetting = function(_, key) if key == "coilsOnBelowPct" then return 10 elseif key == "coilsOffAbovePct" then return 90 end return nil end
local fake = { coils = false, flowCap = 0 }
local p = { getFluidFlowRateMaxMax=function() return 2000 end, getActive=function() return true end,
 getRotorSpeed=function() return 1800 end, getEnergyProducedLastTick=function() return 100 end,
 getEnergyStored=function() return 0 end, getEnergyCapacity=function() return 10000 end,
 getFluidFlowRate=function() return 100 end, getInductorEngaged=function() return fake.coils end,
 getBladeEfficiency=function() return 1 end, setFluidFlowRateMax=function(v) fake.flowCap=v end,
 setInductorEngaged=function(v) fake.coils=v end, setActive=function() end }
peripheral = {wrap=function() return p end}
local t = Turbine.newExtremeTurbine("t")
t.active, t.rpm, t.averageRPM = true, 1800, 1800
local cfg = {entityOverrides={}, rpmMin=1800, rpmMax=2000, safeRPM=1990, ceilingRPM=2000,
 turbineKp=1, turbineKi=0.1, coilsOnBelowPct=10, coilsOffAbovePct=90, sustainedOverspeedEnabled=true,
 sustainedOverspeedLimitRPM=2400, steamWriteThreshold=5}
t:updateControl(cfg,true,{rfTarget=5000,flowTarget=1500,rpmLimit=2400},{})
assert(fake.coils and fake.flowCap > 0,"positive RF target did not engage generation")
t:updateControl(cfg,true,{rfTarget=0,flowTarget=0,rpmLimit=2400},{storageFull=true})
assert(not fake.coils and fake.flowCap == 0,"full storage did not stop intentional generation")
t.rpm,t.averageRPM=2401,2401
t:updateControl(cfg,false,{rfTarget=5000,flowTarget=2000,rpmLimit=2400},{})
assert(fake.coils and fake.flowCap == 0,"absolute sustained RPM limit did not govern")
print("turbine dispatch ok")

-- Regression coverage: transient samples are excluded, steady samples populate bins.
t.rpmBinObservations = nil; t.energyProduced = 123; t.rpm = 1800; t.averageRPM = 1800; t.coilsEngaged = true
t:updateControl(cfg, true, {rfTarget=5000,flowTarget=2000,rpmLimit=2400}, {steady=true, transient=true})
assert(not t.rpmBinObservations, "transient braking sample updated observation bin")
t:updateControl(cfg, true, {rfTarget=5000,flowTarget=2000,rpmLimit=2400}, {steady=true})
assert(t.rpmBinObservations and t.rpmBinObservations[1800], "steady sample did not update observation bin")

-- Probe advances one bin per settled evaluation and stops after two distinct misses.
t.bestSustainedRPM=1800; t.bestContinuousRF=999; t.energyProduced=100; t.probeBin=nil; t.probeStopped=false; t.probeSettledFailures=0; t.probeSettledBins={}
t.rpm,t.averageRPM=1800,1800
t:updateControl(cfg,true,{rfTarget=5000,flowTarget=2000,rpmLimit=2400},{probeAllowed=true,steady=true})
assert(t.probeBin == 1900 and t.probeSettledFailures==0)
t.averageRPM=1850; t:updateControl(cfg,true,{rfTarget=5000,flowTarget=2000,rpmLimit=2400},{probeAllowed=true,steady=true}); assert(t.probeBin==1900 and t.probeSettledFailures==0 and not t.probeSettledBins[1900])
t.averageRPM=1900; t:updateControl(cfg,true,{rfTarget=5000,flowTarget=2000,rpmLimit=2400},{probeAllowed=true,steady=true}); assert(t.probeSettledBins[1900] and t.probeSettledFailures==1 and t.probeBin==2000)
t:updateControl(cfg,true,{rfTarget=5000,flowTarget=2000,rpmLimit=2400},{probeAllowed=true,steady=true}); assert(t.probeSettledFailures==1 and t.probeBin==2000)
t.averageRPM=2000; t:updateControl(cfg,true,{rfTarget=5000,flowTarget=2000,rpmLimit=2400},{probeAllowed=true,steady=true}); assert(t.probeSettledBins[2000] and t.probeSettledFailures==2 and t.probeStopped==true and t.probeBin==nil)
t:updateControl(cfg,true,{rfTarget=5000,flowTarget=2000,rpmLimit=2400},{probeAllowed=true,steady=true}); assert(t.probeStopped==true and t.probeSettledFailures==2 and t.probeBin==nil)

-- Protected writes return failures; constructor failures remain discoverable.
local oldSteam, oldCoil = t.setFluidFlowRateMax, t.setInductorEngaged
t.setFluidFlowRateMax=function() error("steam boom") end
local ok, err=t:writeSteam(100); assert(not ok and err and t.controlStatus=="WRITE_FAILED", "steam write failure not returned")
t.setFluidFlowRateMax=oldSteam; t.setInductorEngaged=function() error("coil boom") end
ok, err=t:writeCoils(false); assert(not ok and err and t.controlStatus=="WRITE_FAILED", "coil write failure not returned")
t.setInductorEngaged=oldCoil
print("turbine dispatch regressions ok")

-- Chunk A: finite limit inputs must never produce an unbounded governor target.
for _, lim in ipairs({nil, 0/0, math.huge, -math.huge}) do
  t.rpm, t.averageRPM = 1800, 1800
  local ok = pcall(function() t:updateControl(cfg, false, {rfTarget=1, flowTarget=1, rpmLimit=lim}, {}) end)
  assert(ok, "non-finite sustained limit escaped safely")
end
cfg.entityOverrides.t = {sustainedOverspeedLimitRPM=2300}
 t:updateControl(cfg, true, {rfTarget=1,flowTarget=1,rpmLimit=2200},{})
assert(t.dispatchTarget.rpmLimit == 2200, "valid target limit not accepted")
cfg.entityOverrides.t.sustainedOverspeedLimitRPM=2100
 t:updateControl(cfg, true, {rfTarget=1,flowTarget=1,rpmLimit=2200},{})
assert(t.controlStatus == "governor" or t.dispatchTarget.rpmLimit == 2200, "entity precedence path failed")
cfg.entityOverrides = {}

-- Constructor peripheral writes are protected and discovery-visible.
for _, field in ipairs({"setFluidFlowRateMax", "setInductorEngaged"}) do
  local broken = {}
  for k,v in pairs(p) do broken[k]=v end
  broken[field] = function() error(field .. " failure") end
  peripheral.wrap = function() return broken end
  local ok, made = pcall(Turbine.newExtremeTurbine, "broken")
  assert(ok and made.controlStatus == "WRITE_FAILED" and made.controlError, "constructor write failure escaped")
end
peripheral.wrap = function() return p end
print("turbine finite/failure chunk ok")

-- Chunk B: branch-level protected-write matrix (each branch must return its write error).
local branchCases = {
  {name="ceiling", rpm=2500, steer=false, target={rfTarget=1,flowTarget=1,rpmLimit=2400}, steam=true},
  {name="safe", rpm=1995, steer=false, target={rfTarget=1,flowTarget=1,rpmLimit=2400}, coil=true},
  {name="idle", rpm=1800, steer=true, target=nil, steam=true},
  {name="flywheel", rpm=1800, steer=true, target=nil, steam=true, fly=true},
  {name="legacy-pi", rpm=1800, steer=true, target=nil, steam=true},
  {name="positive", rpm=1800, steer=true, target={rfTarget=1,flowTarget=100,rpmLimit=2400}, steam=true},
  {name="zero", rpm=1800, steer=true, target={rfTarget=0,flowTarget=0,rpmLimit=2400}, coil=true},
}
for _, c in ipairs(branchCases) do
  t.rpm,t.averageRPM=c.rpm,c.rpm; t.active=true; t.lastWrittenSteamCap=-1; t.lastWrittenCoils=nil
  local oldS,oldC=t.setFluidFlowRateMax,t.setInductorEngaged
  if c.steam then t.setFluidFlowRateMax=function() error(c.name.." steam") end end
  if c.coil then t.setInductorEngaged=function() error(c.name.." coil") end end
  local ccfg=cfg; ccfg.flywheelMode=c.fly
  local ok,err=t:updateControl(ccfg,c.steer,c.target,{})
  assert(ok==false and err and t.controlStatus=="WRITE_FAILED", c.name.." failure not propagated")
  t.setFluidFlowRateMax,t.setInductorEngaged=oldS,oldC
end
print("turbine branch failure matrix ok")

local function at(rpm, lim, configLim, entityLimit)
 t.rpm,t.averageRPM=rpm,rpm; t.lastWrittenSteamCap=-1; t.lastWrittenCoils=nil; t.controlStatus=nil
 local c={entityOverrides=entityLimit and {t={sustainedOverspeedLimitRPM=entityLimit}} or {},rpmMin=1800,rpmMax=math.huge,safeRPM=math.huge,ceilingRPM=math.huge,turbineKp=1,turbineKi=0,sustainedOverspeedLimitRPM=configLim or 2400,steamWriteThreshold=5}
 local ok,err=t:updateControl(c,true,{rfTarget=1,flowTarget=1,rpmLimit=lim},{})
 return ok,err,t.controlStatus,t.steamCap
end
local function checkInvalid(lim) local _,_,s=at(2399,lim,math.huge); assert(s=="dispatch"); local _,_,s2=at(2400,lim,math.huge); assert(s2=="governor") end
checkInvalid(nil); checkInvalid(0/0); checkInvalid(math.huge); checkInvalid(-math.huge)
local _,_,s=at(2299,nil,2300); assert(s=="dispatch"); local _,_,s0=at(2300,nil,2300); assert(s0=="governor")
local _,_,s2=at(2199,2200,2300); assert(s2=="dispatch"); local _,_,s20=at(2200,2200,2300); assert(s20=="governor")
t.rpm,t.averageRPM=2100,2100; cfg.entityOverrides={t={sustainedOverspeedLimitRPM=2100}}
local _,_,s3=at(2099,2200,2300,2100); assert(s3=="dispatch"); local _,_,s30=at(2100,2200,2300,2100); assert(s30=="governor")
cfg.entityOverrides={}
print("finite limit behavior ok")
