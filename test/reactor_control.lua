-- Focused real-actuator checks for explicit reactor dispatch targets.
dofile("test/cc_stubs.lua")
dofile("src/config/projectConfigs.lua")
dofile("src/constants/projectConstants.lua")
dofile("src/classes/deque.lua")
dofile("src/util/config.lua")
dofile("src/classes/reactor.lua")

local function makePeripheral(active, output)
    local rods = {[0]=80,[1]=80,[2]=80,[3]=80}
    local writes = 0
    local p = {
        isActivelyCooled=function() return active end, getActive=function() return true end,
        getEnergyStats=function() return {energyProducedLastTick=active and 0 or output, energyStored=500, energyCapacity=1000} end,
        getControlRodsLevels=function() return rods end, getNumberOfControlRods=function() return 4 end,
        setActive=function() end,
        getFuelStats=function() return {fuelConsumedLastTick=1000} end, getFuelTemperature=function() return 100 end,
        getCasingTemperature=function() return 100 end, getWasteAmount=function() return 0 end,
        getHotFluidProducedLastTick=function() return active and output or 0 end,
        getHotFluidAmount=function() return 0 end, getHotFluidAmountMax=function() return 100000 end,
        setControlRodsLevels=function(levels) writes=writes+1; for k,v in pairs(levels) do rods[k]=v end end,
    }
    return p, rods, function() return writes end
end

local function average(rods) local n,s=0,0; for _,v in pairs(rods) do n=n+1;s=s+v end; return s/n end
local pp, prods, passiveWrites = makePeripheral(false, 0)
local sp, srods = makePeripheral(true, 0)
peripheral.register("passive", "BigReactors-Reactor", pp)
peripheral.register("steam", "BigReactors-Reactor", sp)
_G.overallStats = {storedThisTick=500, capacity=1000, storedSteam=0, steamCapacity=100000, rfLost=0, steamConsumedLastTick=0}
function getEntitySetting() return nil end
_G.minb, _G.maxb, _G.SECONDS_TO_AVERAGE = 30, 70, 1
CONTROL_CONFIG.rodWriteThreshold = 0
local passive = Reactor.newExtremeReactor("passive")
local steam = Reactor.newExtremeReactor("steam")
assert(passive:updateRods({unit="rf", target=60000}) == true)
assert(average(prods) < 80, "positive RF target did not withdraw rods")
assert(steam:updateRods({unit="steam", target=12000}) == true)
assert(average(srods) < 80, "positive steam target did not withdraw rods")
local before = average(prods)
assert(passive:updateRods(nil) == false and average(prods) == before, "missing target changed output")
assert(passive.controlStatus == "NO_TARGET")
local incompatibleBefore = average(prods)
local badOK, badErr = passive:updateRods({unit="steam", target=1})
assert(badOK == false and badErr and passive.controlStatus == "NO_TARGET" and average(prods) == incompatibleBefore)
for _=1,10 do assert(passive:updateRods({unit="rf", target=0})) end
assert(average(prods) > before, "zero target did not insert rods")
CONTROL_CONFIG.rodWriteThreshold = 100
local writesBefore = average(prods)
local writesCount = passiveWrites()
CONTROL_CONFIG.rodWriteThreshold = 1000
passive.pid.integral = 0
passive.pid.lastError = 0
passive.pid.Kp = -0.000001
passive.pid.Ki = 0
passive.pid.Kd = 0
passive.lastWrittenRodLevel = 0.1
passive.averageLastRFT = 200
local thresholdOK = passive:updateRods({unit="rf", target=100})
print("threshold", thresholdOK, passive.controlStatus, passiveWrites(), writesCount)
assert(thresholdOK == true and passive.controlStatus == "TRACKING" and passiveWrites() == writesCount, "rod write threshold did not suppress small change")
passive.bestEffLevel = 100
CONTROL_CONFIG.optimizeMode = "efficiency"
CONTROL_CONFIG.rodWriteThreshold = 0
local prior = average(prods)
passive:updateRods({unit="rf", target=60000})
assert(average(prods) < prior, "explicit dispatch target was capped at efficiency sweet spot")
local throwing = Reactor.newExtremeReactor("passive")
throwing.setRodLevels = function() error("actuator unavailable") end
local writeOK, writeErr = throwing:updateRods({unit="rf", target=60000})
assert(writeOK == false and writeErr and throwing.controlStatus == "WRITE_FAILED")
print("reactor control: ok")
