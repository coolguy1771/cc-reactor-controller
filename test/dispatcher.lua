dofile("src/services/dispatcher.lua")

local result = Dispatcher.allocate({ requiredRF=300,
  passiveReactors={{id="small",capacity=100,weight=1,available=true},{id="large",capacity=300,weight=1,available=true}},
  turbines={}, activeReactors={}, steamGroups={} }, {sustainedOverspeedLimitRPM=2400})
assert(result.reactors.small.target == 75 and result.reactors.large.target == 225)
assert(result.availableRF == 400 and result.saturation == 0.75)
local stable = Dispatcher.allocate({requiredRF=304,previousTargets={reactors={small=75,large=225},turbines={}},
  passiveReactors={{id="small",capacity=100,weight=1,available=true},{id="large",capacity=300,weight=1,available=true}},turbines={},activeReactors={},steamGroups={}}, {dispatchRebalanceThreshold=0.02,sustainedOverspeedLimitRPM=2400})
assert(stable.reactors.small.target==75 and stable.reactors.large.target==225)
local defaults = Dispatcher.allocate({requiredRF=304,previousTargets={reactors={small=75,large=225},turbines={}},
  passiveReactors={{id="small",capacity=100,available=true},{id="large",capacity=300,available=true}},turbines={},activeReactors={},steamGroups={}})
assert(defaults.reactors.small.target==75 and defaults.reactors.large.target==225, "default rebalance threshold missing")
local steam = Dispatcher.allocate({requiredRF=100,passiveReactors={},
 turbines={{id="t1",capacity=100,maxFlow=2000,rfPerSteam=0.05,groupId="g",available=true}},
 activeReactors={{id="r1",capacity=600,groupId="g",available=true},{id="r2",capacity=400,groupId="g",available=true}},steamGroups={g={steamCorrection=0}}},{sustainedOverspeedLimitRPM=2400})
assert(steam.turbines.t1.rfTarget==100 and steam.turbines.t1.flowTarget==2000)
assert(steam.reactors.r1.target==600 and steam.reactors.r2.target==400)
local turbineStable = Dispatcher.allocate({requiredRF=99,previousTargets={reactors={},turbines={t1={rfTarget=100}}},
  passiveReactors={},turbines={{id="t1",capacity=100,maxFlow=2000,rfPerSteam=0.05,groupId="g",available=true}},activeReactors={},steamGroups={}}, {})
assert(turbineStable.turbines.t1.rfTarget==100 and turbineStable.turbines.t1.flowTarget==2000, "turbine deadband did not retain RF/flow")
assert(steam.turbines.t1.rpmLimit==2400, "default RPM limit missing")
local learned=Dispatcher.learnCapacity({value=80,known=true,misses=0},{actual=100,target=100,ceiling=200,steady=true,transient=false},{capacityLearningRate=0.05})
assert(math.abs(learned.value-81)<0.001)
local configured=Dispatcher.learnCapacity(nil,{configured=500,actual=10,target=10,steady=true},{capacityLearningRate=0.05})
assert(configured.value==500 and configured.known)
print("dispatcher tests passed")
