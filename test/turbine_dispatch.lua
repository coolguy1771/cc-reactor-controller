-- Task 5 RED/GREEN: target-driven turbine dispatch and sustained-limit behavior.
dofile("test/cc_stubs.lua")
dofile("src/classes/deque.lua")
dofile("src/classes/turbine.lua")
SECONDS_TO_AVERAGE = 1
getEntitySetting = function() return nil end
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
t.bestSustainedRPM=1800; t.bestContinuousRF=999; t.probeBin=nil; t.probeSettledFailures=0; t.probeSettledBins=nil
t:updateControl(cfg,true,{rfTarget=5000,flowTarget=2000,rpmLimit=2400},{probeAllowed=true,steady=true})
assert(t.probeBin == 1900, "probe did not start at one bounded bin")
t.averageRPM=1900; t:updateControl(cfg,true,{rfTarget=5000,flowTarget=2000,rpmLimit=2400},{probeAllowed=true,steady=true})
assert(t.probeBin == 2000, "probe did not advance exactly 100 RPM")
t.averageRPM=1900; t:updateControl(cfg,true,{rfTarget=5000,flowTarget=2000,rpmLimit=2400},{probeAllowed=true,steady=true})
t.averageRPM=2000; t:updateControl(cfg,true,{rfTarget=5000,flowTarget=2000,rpmLimit=2400},{probeAllowed=true,steady=true})
assert(t.probeBin == 2400, "probe did not stop after two distinct settled non-improvements")

-- Protected writes return failures; constructor failures remain discoverable.
local oldSteam, oldCoil = t.setFluidFlowRateMax, t.setInductorEngaged
t.setFluidFlowRateMax=function() error("steam boom") end
local ok, err=t:writeSteam(100); assert(not ok and err and t.controlStatus=="WRITE_FAILED", "steam write failure not returned")
t.setFluidFlowRateMax=oldSteam; t.setInductorEngaged=function() error("coil boom") end
ok, err=t:writeCoils(false); assert(not ok and err and t.controlStatus=="WRITE_FAILED", "coil write failure not returned")
t.setInductorEngaged=oldCoil
print("turbine dispatch regressions ok")
