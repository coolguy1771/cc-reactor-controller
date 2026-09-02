-- Task 3 RED test: each device getter is sampled once per update tick.
dofile("test/cc_stubs.lua")
dofile("src/classes/deque.lua")
dofile("src/classes/reactor.lua")
dofile("src/classes/turbine.lua")
dofile("src/classes/energybuffer.lua")
dofile("src/services/dispatcher.lua")

SECONDS_TO_AVERAGE = 1
CONTROL_CONFIG = { entityOverrides = {} }
getEntitySetting = function() return nil end

local calls = { reactorEnergyStats = 0, turbineEnergyProduced = 0,
    turbineEnergyStored = 0, turbineEnergyCapacity = 0 }
local reactor = {
    getEnergyStats = function() calls.reactorEnergyStats = calls.reactorEnergyStats + 1; return { energyProducedLastTick = 10, energyStored = 20, energyCapacity = 100 } end,
    getFuelStats = function() return { fuelConsumedLastTick = 1 } end,
    isActivelyCooled = function() return false end, getActive = function() return true end,
    getFuelTemperature = function() return 1 end, getCasingTemperature = function() return 1 end,
    getControlRodsLevels = function() return {[0] = 0} end, getWasteAmount = function() return 0 end,
    getHotFluidProducedLastTick = function() return 0 end, getHotFluidAmountMax = function() return 0 end,
    getHotFluidAmount = function() return 0 end,
}
local turbine = {
    getFluidFlowRateMaxMax = function() return 100 end,
    getActive = function() return false end, getRotorSpeed = function() return 0 end,
    getEnergyProducedLastTick = function() calls.turbineEnergyProduced = calls.turbineEnergyProduced + 1; return 1 end,
    getEnergyStored = function() calls.turbineEnergyStored = calls.turbineEnergyStored + 1; return 2 end,
    getEnergyCapacity = function() calls.turbineEnergyCapacity = calls.turbineEnergyCapacity + 1; return 3 end,
    getFluidFlowRate = function() return 0 end, getInductorEngaged = function() return true end,
    getBladeEfficiency = function() return 1 end, setFluidFlowRateMax = function() end,
    setInductorEngaged = function() end, setActive = function() end,
}
peripheral = { wrap = function(id) return id == "r" and reactor or turbine end }
local r = Reactor.newExtremeReactor("r")
local t = Turbine.newExtremeTurbine("t")
assert(r.energyStored == 20 and r.energyCapacity == 100 and r.lastUpdatedTick >= 0,
    "reactor constructor must populate tick-zero sample")
assert(t.energyStored == 2 and t.energyCapacity == 3 and t.lastUpdatedTick >= 0,
    "turbine constructor must populate tick-zero sample")
local constructorReactorCalls = calls.reactorEnergyStats
assert(constructorReactorCalls == 1, "reactor constructor must sample once")
assert(calls.turbineEnergyProduced == 1 and calls.turbineEnergyStored == 1 and calls.turbineEnergyCapacity == 1,
    "turbine constructor must sample each getter once")
calls.reactorEnergyStats, calls.turbineEnergyProduced, calls.turbineEnergyStored, calls.turbineEnergyCapacity = 0, 0, 0, 0
r:update(1); t:update(1)
assert(calls.reactorEnergyStats == 1, "reactor getEnergyStats must provide output, stored RF, and capacity in one call")
assert(calls.turbineEnergyProduced == 1 and calls.turbineEnergyStored == 1 and calls.turbineEnergyCapacity == 1, "turbine getters were repeated in one tick")
calls.reactorEnergyStats, calls.turbineEnergyProduced, calls.turbineEnergyStored, calls.turbineEnergyCapacity = 0, 0, 0, 0
r:update(2); t:update(2)
assert(calls.reactorEnergyStats == 1 and calls.turbineEnergyProduced == 1 and calls.turbineEnergyStored == 1 and calls.turbineEnergyCapacity == 1,
    "each device getter must be called once on every tick")
assert(r.lastUpdatedTick == 0 or r.energyStored == 20, "constructor must sample tick zero")
assert(r.energyStored == 20 and r.energyCapacity == 100, "reactor energy sample fields missing")
assert(r.observeCapacity and t.observeCapacity, "capacity observation interface missing")
assert(t.capacityRF and t.rfPerSteam ~= nil, "turbine capacity fields missing")
local before = t.rfPerSteam
t.coilsEngaged = false; t.steamFlow = 10; t.energyProduced = 100
t:observeCapacity(100, {steady = true, topologyChanged = false}, {})
assert(t.rfPerSteam == before, "rfPerSteam learned while coils disengaged")
local blocked = {"flywheelDeceleration", "scram", "governorBraking", "startupGrace", "topologyChanged", "calibration", "storageFull"}
for _, name in ipairs(blocked) do
    t.coilsEngaged=true; t.steamFlow=10; t.energyProduced=100; t.rfPerSteam=1; t.capacityRF=1; t.capacityKnown=false
    local context = {steady=true}; context[name] = true
    t:observeCapacity(100, context, {})
    assert(t.rfPerSteam == 1 and t.capacityRF == 1 and not t.capacityKnown, "learning occurred during " .. name)
end
t.capacityRF=100; t.capacityKnown=true; t.capacityMisses=2; t.coilsEngaged=true; t.steamFlow=10; t.energyProduced=1
t:observeCapacity(200, {steady=true}, {})
assert(t.capacityRF == 1 and t.capacityMisses == 0, "turbine persisted misses did not lower stale capacity")
r.capacityRF=100; r.capacityKnown=true; r.capacityMisses=2; r.lastRFT=1; r.activelyCooled=false
r:observeCapacity(200, {steady=true}, {})
assert(r.capacityRF == 1 and r.capacityMisses == 0, "reactor persisted misses did not lower stale capacity")
print("device sampling ok")
