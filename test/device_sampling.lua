-- Task 3 RED test: each device getter is sampled once per update tick.
dofile("test/cc_stubs.lua")
dofile("src/classes/deque.lua")
dofile("src/classes/reactor.lua")
dofile("src/classes/turbine.lua")
dofile("src/classes/energybuffer.lua")

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
calls.reactorEnergyStats, calls.turbineEnergyProduced, calls.turbineEnergyStored, calls.turbineEnergyCapacity = 0, 0, 0, 0
r:update(1); t:update(1)
assert(calls.reactorEnergyStats == 1, "reactor getEnergyStats must provide output, stored RF, and capacity in one call")
assert(calls.turbineEnergyProduced == 1 and calls.turbineEnergyStored == 1 and calls.turbineEnergyCapacity == 1, "turbine getters were repeated in one tick")
assert(r.lastUpdatedTick == 0 or r.energyStored == 20, "constructor must sample tick zero")
print("device sampling ok")
