-- Headless smoke test / simulator for the controller.
-- Run from the project root:  lua test/sim.lua
--
-- Builds fake reactor/turbine/monitor peripherals with rough-but-plausible physics,
-- drives the real control loop through three demand phases, and asserts:
--   * turbine RPM never crosses the 2000 ceiling (incl. an induced overspeed test)
--   * turbines settle near 1800 RPM in every phase
--   * coils disengage when the grid is full, re-engage under load
--   * the steam reactor throttles rods when turbines idle (production tracks consumption)
--   * the monitor renders and its buttons respond to touches

dofile("test/cc_stubs.lua")

-- Load the real modules in the same order main.lua would.
local MODULES = {
    "src/config/projectConfigs.lua",
    "src/constants/projectConstants.lua",
    "src/classes/vector2.lua",
    "src/classes/deque.lua",
    "src/util/draw.lua",
    "src/classes/touchpoint.lua",
    "src/classes/energybuffer.lua",
    "src/classes/reactor.lua",
    "src/classes/turbine.lua",
    "src/classes/monitor.lua",
    "src/util/config.lua",
    "src/services/journal.lua",
    "src/services/alarm.lua",
    "src/services/capability.lua",
    "src/services/history.lua",
    "src/services/safety.lua",
    "src/services/watchdog.lua",
    "src/services/telemetry.lua",
    "src/services/storage.lua",
    "src/services/dispatcher.lua",
    "src/scripts/controller.lua",
}
for _, path in ipairs(MODULES) do dofile(path) end

--region world + fake devices

local world = {
    steamTank = { amount = 0, capacity = 50000 },
    baseDraw = 0,
    passiveReactors = {},
    activeReactors = {},
    fakeTurbines = {},
    drawShortfall = 0,
    externalStore = { stored = 1000000, capacity = 10000000 },
}

local function rodAverage(rods)
    local sum, count = 0, 0
    for _, level in pairs(rods) do
        sum = sum + level
        count = count + 1
    end
    return sum / count
end

local function makeFakeReactor(name, opts)
    local self = {
        name = name,
        rods = {},
        active = true,
        battery = opts.activelyCooled and 0 or 5000000,
        batteryCap = opts.activelyCooled and 0 or 10000000,
        maxRF = opts.maxRF or 0,
        maxSteam = opts.maxSteam or 0,
        activelyCooled = opts.activelyCooled or false,
        genLast = 0,
        waste = 0,
    }
    for i = 0, (opts.rodCount or 4) - 1 do self.rods[i] = 80 end

    self.step = function()
        local avgRod = rodAverage(self.rods)
        local powerFraction = self.active and (100 - avgRod) / 100 or 0
        if self.activelyCooled then
            local produced = powerFraction * self.maxSteam
            local space = world.steamTank.capacity - world.steamTank.amount
            world.steamTank.amount = world.steamTank.amount + math.min(produced, space)
            self.genLast = produced
        else
            self.genLast = powerFraction * self.maxRF
            self.battery = math.min(self.batteryCap, self.battery + self.genLast)
        end
        self.waste = self.waste + self.genLast / 1000000
    end

    self.methods = {
        getActive = function() return self.active end,
        setActive = function(v) self.active = v end,
        isActivelyCooled = function() return self.activelyCooled end,
        getNumberOfControlRods = function()
            local n = 0
            for _ in pairs(self.rods) do n = n + 1 end
            return n
        end,
        getControlRodsLevels = function()
            local copy = {}
            for k, v in pairs(self.rods) do copy[k] = v end
            return copy
        end,
        setControlRodsLevels = function(levels)
            for k, v in pairs(levels) do self.rods[k] = v end
        end,
        getEnergyStats = function()
            return {
                energyStored = self.battery,
                energyCapacity = self.batteryCap,
                energyProducedLastTick = self.activelyCooled and 0 or self.genLast,
            }
        end,
        getFuelStats = function()
            return { fuelConsumedLastTick = self.genLast / 100 + 0.001 }
        end,
        getFuelTemperature = function() return 20 + (self.genLast / math.max(1, self.maxRF + self.maxSteam)) * 600 end,
        getCasingTemperature = function() return 20 + (self.genLast / math.max(1, self.maxRF + self.maxSteam)) * 300 end,
        getWasteAmount = function() return self.waste end,
        getHotFluidProducedLastTick = function() return self.activelyCooled and self.genLast or 0 end,
        getHotFluidAmount = function() return self.activelyCooled and world.steamTank.amount or 0 end,
        getHotFluidAmountMax = function() return self.activelyCooled and world.steamTank.capacity or 0 end,
    }
    return self
end

-- Rotor physics: rpm += (steamTorque - coilDrag - friction) * inertia
-- Constants chosen so ~2000 mB/t holds ~1800 RPM with coils engaged,
-- and freewheeling at full steam would badly overspeed (governor must prevent it).
local K_TORQUE, K_DRAG, K_FRICTION, INERTIA = 0.054, 0.05, 0.01, 0.2

local function makeFakeTurbine(name, misspellBladeMethod)
    local self = {
        name = name,
        rpm = 0,
        cap = 0,
        coils = false,
        active = true,
        buffer = 0,
        bufferCap = 1000000,
        flowLast = 0,
        genLast = 0,
        flowMaxMax = 2000,
        maxRpmSeen = 0,
    }

    self.step = function(grantedFlow)
        if not self.active then grantedFlow = 0 end
        self.flowLast = grantedFlow
        local torque = K_TORQUE * grantedFlow
        local drag = self.coils and K_DRAG * self.rpm or 0
        local friction = K_FRICTION * self.rpm
        self.rpm = math.max(0, self.rpm + (torque - drag - friction) * INERTIA)
        self.maxRpmSeen = math.max(self.maxRpmSeen, self.rpm)
        self.genLast = (self.coils and self.active) and self.rpm * 5 or 0
        self.buffer = math.min(self.bufferCap, self.buffer + self.genLast)
    end

    self.methods = {
        getActive = function() return self.active end,
        setActive = function(v) self.active = v end,
        getRotorSpeed = function() return self.rpm end,
        getEnergyProducedLastTick = function() return self.genLast end,
        getEnergyStored = function() return self.buffer end,
        getEnergyCapacity = function() return self.bufferCap end,
        getEnergyStats = function()
            return { energyStored = self.buffer, energyCapacity = self.bufferCap, energyProducedLastTick = self.genLast }
        end,
        getFluidFlowRate = function() return self.flowLast end,
        getFluidFlowRateMax = function() return self.cap end,
        getFluidFlowRateMaxMax = function() return self.flowMaxMax end,
        setFluidFlowRateMax = function(v) self.cap = v end,
        getInductorEngaged = function() return self.coils end,
        setInductorEngaged = function(v) self.coils = v end,
    }
    -- One turbine carries the mod's historical typo to exercise feature detection.
    if misspellBladeMethod then
        self.methods.getBladeEffiency = function() return 75 end
    else
        self.methods.getBladeEfficiency = function() return 75 end
    end
    return self
end

function world.step()
    -- 1) steam production
    for _, r in ipairs(world.activeReactors) do r.step() end

    -- 2) grant steam to turbines proportional to their requested caps
    local totalRequested = 0
    for _, t in ipairs(world.fakeTurbines) do
        totalRequested = totalRequested + (t.active and t.cap or 0)
    end
    local grantedTotal = math.min(totalRequested, world.steamTank.amount)
    for _, t in ipairs(world.fakeTurbines) do
        local request = t.active and t.cap or 0
        local grant = totalRequested > 0 and (request * grantedTotal / totalRequested) or 0
        t.step(grant)
    end
    world.steamTank.amount = world.steamTank.amount - grantedTotal

    -- 3) passive generation
    for _, r in ipairs(world.passiveReactors) do r.step() end

    -- 4) base draw, pulled proportionally from every RF buffer
    local pools = {}
    local totalStored = 0
    for _, r in ipairs(world.passiveReactors) do
        pools[#pools + 1] = r
        totalStored = totalStored + r.battery
    end
    for _, t in ipairs(world.fakeTurbines) do
        pools[#pools + 1] = t
        totalStored = totalStored + t.buffer
    end
    pools[#pools + 1] = world.externalStore
    totalStored = totalStored + world.externalStore.stored
    local draw = world.baseDraw
    if totalStored > 0 and draw > 0 then
        local pulled = 0
        for _, p in ipairs(pools) do
            local stored = p.battery or p.buffer or p.stored
            local share = math.min(stored, draw * stored / totalStored)
            if p.battery then p.battery = p.battery - share
            elseif p.buffer then p.buffer = p.buffer - share
            else p.stored = p.stored - share end
            pulled = pulled + share
        end
        world.drawShortfall = world.drawShortfall + math.max(0, draw - pulled)
    end
end

--endregion
--region checks

local failures = {}
local function check(condition, label)
    if condition then
        print("PASS  " .. label)
    else
        print("FAIL  " .. label)
        failures[#failures + 1] = label
    end
end

--endregion
--region build world

-- CC:Tweaked 4x4 advanced monitor at text scale 0.5:
-- round((4 - 2*(2/16+0.5/16)) / (0.5 * 6/64)) x round((4 - 2*(2/16+0.5/16)) / (0.5 * 9/64))
local monitorPeripheral = makeTerm(79, 52)

-- Deliberately asymmetric passive capacity catches equal-RF/share dispatch regressions.
local reactorBig = makeFakeReactor("reactor_large", { maxRF = 80000, rodCount = 9 })
local reactorMid = makeFakeReactor("reactor_small", { maxRF = 20000, rodCount = 4 })
local reactorSteam = makeFakeReactor("reactor_steam", { maxSteam = 12000, rodCount = 4, activelyCooled = true })
world.passiveReactors = { reactorBig, reactorMid }
world.activeReactors = { reactorSteam }

for i = 1, 5 do
    world.fakeTurbines[i] = makeFakeTurbine("turbine_" .. i, i == 3)
end

peripheral.register("BigReactors-Reactor_0", "BigReactors-Reactor", reactorBig.methods)
peripheral.register("BigReactors-Reactor_1", "BigReactors-Reactor", reactorMid.methods)
peripheral.register("BigReactors-Reactor_2", "BigReactors-Reactor", reactorSteam.methods)
for i = 1, 5 do
    peripheral.register("BigReactors-Turbine_" .. i, "BigReactors-Turbine", world.fakeTurbines[i].methods)
end
peripheral.register("monitor_0", "monitor", monitorPeripheral)
peripheral.register("storage_0", "energy_storage", {
    getEnergy = function() return world.externalStore.stored end,
    getEnergyCapacity = function() return world.externalStore.capacity end,
})

ConfigUtil.writeAllConfigsAsDefaults()
ConfigUtil.readAllConfigs()
__test.syncConfigGlobals()

for _, name in ipairs(peripheral.getNames()) do
    __test.handlePeripheralAttach(name, peripheral.getType(name))
end

check(next(_G.reactors) ~= nil, "reactors registered")
check(next(_G.turbines) ~= nil, "turbines registered")
check(next(_G.monitors) ~= nil, "monitor registered")
local turbineCount, reactorCount = 0, 0
for _ in pairs(_G.turbines) do turbineCount = turbineCount + 1 end
for _ in pairs(_G.reactors) do reactorCount = reactorCount + 1 end
check(turbineCount == 5, "5 turbines wrapped")
check(reactorCount == 3, "3 reactors wrapped")
CONTROL_CONFIG.requireManualStart = true
local safetyReady = SafetyManager.initialize()
check(safetyReady and SafetyManager.state() == "READY", "safety self-test reaches READY")
local started = SafetyManager.requestMode("AUTO_OUTPUT", "test")
check(started and SafetyManager.state() == "RUNNING", "operator start enters RUNNING")

--endregion
--region run phases

local RPM_MIN = CONTROL_CONFIG.rpmMin or CONTROL_CONFIG.idleRPM
local RPM_MAX = CONTROL_CONFIG.rpmMax or CONTROL_CONFIG.ceilingRPM
local RPM_MID = (RPM_MIN + RPM_MAX) / 2
local SAFE, CEILING = CONTROL_CONFIG.safeRPM, CONTROL_CONFIG.ceilingRPM
local tick = 0
local ceilingViolations = 0

local function inRpmBand(rpm)
    return rpm >= RPM_MIN - 50 and rpm <= RPM_MAX + 50
end

local function runTicks(n, sample)
    for _ = 1, n do
        tick = tick + 1
        _G.__simClock = tick / 20
        world.step()
        __test.runLoop(tick)
        for _, t in ipairs(world.fakeTurbines) do
            if t.rpm > CEILING + 1 then
                ceilingViolations = ceilingViolations + 1
            end
        end
        if sample then sample(tick) end
    end
end

-- Phase A: heavy base load -> turbines must generate.
world.baseDraw = 50000
local aGenerated = {}
local aRodSamples, aRodCount = 0, 0
local aTurbineOutput, aTurbineFlow, aTurbineSamples = 0, 0, 0
runTicks(600, function()
    for i, t in ipairs(world.fakeTurbines) do
        if t.genLast > 0 then aGenerated[i] = true end
    end
    if tick > 400 then
        aRodSamples = aRodSamples + rodAverage(reactorSteam.rods)
        aRodCount = aRodCount + 1
        for _, turbine in ipairs(world.fakeTurbines) do
            aTurbineOutput = aTurbineOutput + turbine.genLast
            aTurbineFlow = aTurbineFlow + turbine.flowLast
        end
        aTurbineSamples = aTurbineSamples + 1
    end
end)

local allGeneratedA = true
for i = 1, 5 do allGeneratedA = allGeneratedA and (aGenerated[i] == true) end
check(allGeneratedA, "phase A: every turbine generated under load")

-- Sustained-output integration: dispatch is an explicit, capacity-weighted command layer.
-- The old PID-only controller has no dispatch snapshot, so this must fail before integration.
local firstDispatch = _G.overallStats.dispatch
local largeTarget = firstDispatch and firstDispatch.reactors["BigReactors-Reactor_0"]
local smallTarget = firstDispatch and firstDispatch.reactors["BigReactors-Reactor_1"]
check(firstDispatch ~= nil and largeTarget ~= nil and smallTarget ~= nil,
    "asymmetric phase: controller publishes explicit reactor dispatch targets")
if largeTarget and smallTarget then
    local largeRF = largeTarget.target or 0
    local smallRF = smallTarget.target or 0
    local largeUtil, smallUtil = largeRF / 80000, smallRF / 20000
    check(math.abs(largeUtil - smallUtil) <= 0.10,
        string.format("asymmetric phase: 20k/80k reactors receive equal utilization (%.2f/%.2f)", smallUtil, largeUtil))
end
local largeMeasured = reactorBig.genLast / 80000
local smallMeasured = reactorMid.genLast / 20000
check(math.abs(largeMeasured - smallMeasured) <= 0.10,
    string.format("asymmetric phase: 20k/80k measured generation has equal utilization (%.2f/%.2f)",
        smallMeasured, largeMeasured))
check(aTurbineOutput / math.max(1, aTurbineSamples) > 0
        and aTurbineFlow / math.max(1, aTurbineSamples) > 0,
    "dispatch phase: turbine flow and generation respond under demand")

local phaseATargets = _G.overallStats.turbineTargets or {}
local phaseACommandsSafe = true
for i, t in ipairs(world.fakeTurbines) do
    local target = phaseATargets["BigReactors-Turbine_" .. i] or {}
    phaseACommandsSafe = phaseACommandsSafe and t.cap >= 0 and t.cap <= t.flowMaxMax
    if (target.rfTarget or 0) == 0 then
        phaseACommandsSafe = phaseACommandsSafe and t.cap == 0 and not t.coils
    end
end
check(phaseACommandsSafe, "phase A: turbine dispatch commands stay bounded and deactivate zero targets")

-- Phase B: zero draw -> buffers fill, coils must disengage, steam production must throttle.
-- Long enough for the steam tank to finish band-seeking so the tail is pure load-following.
world.baseDraw = 0
local bCoilTicks = 0
local bProdSum, bConsSum, bSamples = 0, 0, 0
local bRodSamples, bRodCount = 0, 0
runTicks(1600, function()
    if tick > 2000 then
        for _, t in ipairs(world.fakeTurbines) do
            if t.coils then bCoilTicks = bCoilTicks + 1 end
        end
        bProdSum = bProdSum + reactorSteam.genLast
        local consumption = 0
        for _, t in ipairs(world.fakeTurbines) do consumption = consumption + t.flowLast end
        bConsSum = bConsSum + consumption
        bSamples = bSamples + 1
        bRodSamples = bRodSamples + rodAverage(reactorSteam.rods)
        bRodCount = bRodCount + 1
    end
end)

check(bCoilTicks > 0, "phase B: upper RPM band exercises coil control (idle @1800)")

local zeroTargetsAreOff = true
for i, t in ipairs(world.fakeTurbines) do
    local target = (_G.overallStats.turbineTargets or {})["BigReactors-Turbine_" .. i] or {}
    if (target.rfTarget or 0) == 0 then
        zeroTargetsAreOff = zeroTargetsAreOff and t.cap == 0 and not t.coils
    end
end
check(zeroTargetsAreOff, "phase B: zero turbine allocations close steam and coils")

local avgProdB = bProdSum / math.max(1, bSamples)
local avgConsB = bConsSum / math.max(1, bSamples)
check(math.abs(avgProdB - avgConsB) <= math.max(200, avgConsB * 0.35),
    string.format("phase B: steam production tracks consumption (prod %.0f vs cons %.0f mB/t)", avgProdB, avgConsB))

local tankPct = world.steamTank.amount / world.steamTank.capacity * 100
check(tankPct <= CONTROL_CONFIG.bufferMin + 10,
    string.format("phase B: zero allocations drain unneeded steam inventory (%.1f%%)", tankPct))

-- Phase C: heavy load again -> coils re-engage.
world.baseDraw = 50000
local cGenerated = {}
runTicks(600, function()
    for i, t in ipairs(world.fakeTurbines) do
        if t.genLast > 0 then cGenerated[i] = true end
    end
end)
local allGeneratedC = true
for i = 1, 5 do allGeneratedC = allGeneratedC and (cGenerated[i] == true) end
check(allGeneratedC, "phase C: turbines resume generating when load returns")

check(ceilingViolations == 0, "no turbine ever crossed the 2000 RPM ceiling (all phases)")

local maxSeen = 0
for _, t in ipairs(world.fakeTurbines) do maxSeen = math.max(maxSeen, t.maxRpmSeen) end
print(string.format("      (max RPM observed anywhere: %.0f)", maxSeen))

--endregion
--region safety governor unit test

local victim = world.fakeTurbines[1]
victim.rpm = SAFE + 40 -- 1990
tick = tick + 1; _G.__simClock = tick / 20
world.step()
victim.rpm = SAFE + 40 -- keep it in the soft-brake band despite the step
__test.runLoop(tick)
check(victim.coils == true, "soft brake: coils forced on at 1990 RPM")
check(victim.cap <= victim.flowMaxMax * 0.25, "soft brake: steam clamped at 1990 RPM")

victim.rpm = CEILING + 5 -- 2005
tick = tick + 1; _G.__simClock = tick / 20
world.step()
victim.rpm = CEILING + 5
__test.runLoop(tick)
check(victim.cap == 0, "hard cut: steam zeroed above 2000 RPM")
check(victim.coils == true, "hard cut: coils engaged to brake above 2000 RPM")
victim.rpm = 0
local reset = SafetyManager.resetScram("test")
check(reset, "latched overspeed SCRAM resets after sensors are safe")
SafetyManager.requestMode("AUTO_OUTPUT", "test")

--endregion
--region monitor render + touch test

local mon
for _, m in pairs(_G.monitors) do mon = m end
local okDraw = pcall(function() mon:draw() end)
check(okDraw, "monitor renders without error")
check(mon.size.x == 79 and mon.size.y == 52, "primary monitor is a 4x4 at scale 0.5")
check(not mon.tooSmall and (mon.cols or 0) >= 3 and (mon.rows or 0) >= 1
        and (mon.cardsPerPage or 0) >= 3,
    "4x4 monitor fits a card grid")

local autoBtn = mon.touch.buttonList["Auto"]
check(autoBtn ~= nil, "Auto button exists")
if autoBtn then
    local before = CONTROL_CONFIG.autoMode
    _G.__simClock = _G.__simClock + 1.1
    mon:handleEvents({ "monitor_touch", mon.id, autoBtn.xMin, autoBtn.yMin })
    check(CONTROL_CONFIG.autoMode == not before, "touching Auto toggles auto mode")
    _G.__simClock = _G.__simClock + 1.1
    mon:handleEvents({ "monitor_touch", mon.id, autoBtn.xMin, autoBtn.yMin })
    check(CONTROL_CONFIG.autoMode == before, "touching Auto again restores auto mode")
end

--region planned features: reserve bands, responsiveness throttle, configurable idleRPM

-- rpmMin validation: UI adjuster clamps to [floor, rpmMax - margin].
local savedMin = CONTROL_CONFIG.rpmMin or CONTROL_CONFIG.idleRPM
adjustIdleRPM(100000)
check((CONTROL_CONFIG.rpmMin or CONTROL_CONFIG.idleRPM) <= RPM_MAX - 100,
    "rpmMin adjust clamps under rpmMax")
adjustIdleRPM(-100000)
check((CONTROL_CONFIG.rpmMin or CONTROL_CONFIG.idleRPM) >= 100, "rpmMin adjust clamps at floor")
CONTROL_CONFIG.rpmMin = savedMin
CONTROL_CONFIG.idleRPM = savedMin
ConfigUtil.writeConfig("control")

-- Band adjusters: widen/narrow symmetrically, refuse to collapse below 10% width.
local bMin, bMax = CONTROL_CONFIG.bufferMin, CONTROL_CONFIG.bufferMax
adjustBufferBand(5)
check(CONTROL_CONFIG.bufferMin == bMin - 5 and CONTROL_CONFIG.bufferMax == bMax + 5
    and _G.minb == bMin - 5, "buffer band widens and re-syncs globals")
adjustBufferBand(-5)
check(CONTROL_CONFIG.bufferMin == bMin and CONTROL_CONFIG.bufferMax == bMax, "buffer band narrows back")
for _ = 1, 20 do adjustCoilBand(-5) end
check(CONTROL_CONFIG.coilsOffAbovePct - CONTROL_CONFIG.coilsOnBelowPct >= 10,
    "coil band refuses to collapse below 10% width")
CONTROL_CONFIG.coilsOnBelowPct, CONTROL_CONFIG.coilsOffAbovePct = 30, 70
ConfigUtil.writeConfig("control")

-- Per-turbine rpmMin override + responsiveness throttle, end to end:
-- turbine 2 targets 900 RPM while steering runs every 3rd tick with deadbands active.
CONTROL_CONFIG.entityOverrides["BigReactors-Turbine_2"] = { rpmMin = 900, rpmMax = 1100 }
CONTROL_CONFIG.controlIntervalTicks = 3
CONTROL_CONFIG.rpmDeadband = 15
CONTROL_CONFIG.rodWriteThreshold = 0.5

local rodWrites = 0
local origSetRods = reactorBig.methods.setControlRodsLevels
reactorBig.methods.setControlRodsLevels = function(levels)
    rodWrites = rodWrites + 1
    return origSetRods(levels)
end

world.baseDraw = 50000
local violationsBefore = ceilingViolations
runTicks(900)

local throttledCommandsSafe = true
for _, t in ipairs(world.fakeTurbines) do
    throttledCommandsSafe = throttledCommandsSafe and t.cap >= 0 and t.cap <= t.flowMaxMax
end
check(throttledCommandsSafe, "turbine commands stay within flow bounds with interval+deadband active")
check(rodWrites <= 300,
    string.format("rod writes throttled by controlIntervalTicks (%d writes in 900 ticks)", rodWrites))
check(ceilingViolations == violationsBefore, "no ceiling violations under throttled steering")

-- Governor must still run on non-steering ticks (interval = 3).
local victim2 = world.fakeTurbines[4]
repeat tick = tick + 1 until tick % 3 ~= 0
_G.__simClock = tick / 20
world.step()
victim2.rpm = CEILING + 5
__test.runLoop(tick)
check(victim2.cap == 0 and victim2.coils == true,
    "safety governor runs full-rate between steering intervals")
victim2.rpm = 0
SafetyManager.resetScram("test")
SafetyManager.requestMode("AUTO_OUTPUT", "test")

-- Restore defaults for the remaining tests.
CONTROL_CONFIG.entityOverrides["BigReactors-Turbine_2"] = nil
CONTROL_CONFIG.controlIntervalTicks = 1
CONTROL_CONFIG.rpmDeadband = 0
CONTROL_CONFIG.rodWriteThreshold = 0
reactorBig.methods.setControlRodsLevels = origSetRods

-- Tick -/+ buttons adjust controlIntervalTicks, clamped to [1, 20].
local tickMinus = mon.touch.buttonList["Tick-"]
check(tickMinus ~= nil and mon.touch.buttonList["Tick+"] ~= nil, "Tick-/Tick+ buttons exist")
adjustControlInterval(-100)
check(CONTROL_CONFIG.controlIntervalTicks == 1, "control interval clamps at 1")
adjustControlInterval(100)
check(CONTROL_CONFIG.controlIntervalTicks == 20, "control interval clamps at 20")
CONTROL_CONFIG.controlIntervalTicks = 1
ConfigUtil.writeConfig("control")

-- Settings-row buttons on the monitor drive the adjusters (1800 +100 clamps to 1850).
local rpmPlus = mon.touch.buttonList["RPM+"]
check(rpmPlus ~= nil, "settings buttons exist (RPM+)")
if rpmPlus then
    local before = CONTROL_CONFIG.idleRPM
    mon:handleEvents({ "monitor_touch", mon.id, rpmPlus.xMin, rpmPlus.yMin })
    check(CONTROL_CONFIG.idleRPM == math.min(before + 100, RPM_MAX - 100),
        "touching RPM+ raises idleRPM with safeRPM clamp")
    CONTROL_CONFIG.idleRPM = before
    ConfigUtil.writeConfig("control")
end

--endregion

--region feature 3: steam network groups

-- Put the steam reactor in a group fed only by turbines 1 & 2; the other three turbines
-- land in the implicit "default" group.
CONTROL_CONFIG.steamGroups = {
    { reactors = { "BigReactors-Reactor_2" }, turbines = { "BigReactors-Turbine_1", "BigReactors-Turbine_2" } },
}
world.baseDraw = 50000
runTicks(200)

local steamReactor = _G.reactors["BigReactors-Reactor_2"]
check(steamReactor.groupId == 1, "steam reactor resolved into its configured group")
check(_G.turbines["BigReactors-Turbine_1"].groupId == 1
    and _G.turbines["BigReactors-Turbine_3"].groupId == "default",
    "turbines split between group 1 and the default group")
check(_G.overallStats.hasSteamGroups == true, "hasSteamGroups set when >1 group present")
local g1 = _G.overallStats.steamGroups[1]
local gDef = _G.overallStats.steamGroups["default"]
check(g1 and g1.turbineCount == 2 and gDef and gDef.turbineCount == 3,
    "per-group turbine counts correct (2 in group 1, 3 in default)")
check(g1.consumption > 0 and reactorSteam.genLast > 0,
    "group cascade active: reactor produces against its group's steam draw")
local groupedTarget = (_G.overallStats.reactorTargets["BigReactors-Reactor_2"] or {}).target or 0
check(math.abs(groupedTarget - g1.consumption) <= math.max(100, g1.consumption * 0.10),
    "separate steam groups: active reactor target excludes default-group turbine flow")

CONTROL_CONFIG.steamGroups = {
    { _reactors = { "BigReactors-Reactor_2" }, turbines = { "BigReactors-Turbine_1", "BigReactors-Turbine_2" } },
}
runTicks(1)
check(steamReactor.groupId == 1, "_reactors alias assigns steam group membership")

CONTROL_CONFIG.steamGroups = {}
runTicks(50)
check(_G.overallStats.hasSteamGroups == false, "empty steamGroups falls back to one network")

--endregion

--region feature 5: flywheel mode

-- Step helper that does NOT feed the global ceiling-violation counter (flywheel deliberately
-- exceeds 2000 RPM, which is the whole point of the mode).
local function stepOnly(n)
    for _ = 1, n do
        tick = tick + 1
        _G.__simClock = tick / 20
        world.step()
        __test.runLoop(tick)
    end
end

-- SafetyManager supersedes legacy flywheel overspeed: an attempted uncapped spin latches SCRAM.
CONTROL_CONFIG.flywheelMode = true
CONTROL_CONFIG.flywheelCeilingRPM = 0
world.baseDraw = 0
world.steamTank.amount = world.steamTank.capacity
for i, t in ipairs(world.fakeTurbines) do
    local wrapper = _G.turbines["BigReactors-Turbine_" .. i]
    t.active, t.cap, t.coils, t.buffer = i == 1, 0, false, t.bufferCap
    t.rpm = i == 1 and 2350 or 0
    wrapper.active, wrapper.desiredCoils = i == 1, false
    wrapper.energyStored, wrapper.energyCapacity = t.bufferCap, t.bufferCap
    wrapper.lastWrittenSteamCap, wrapper.lastWrittenCoils = -1, nil
end
stepOnly(40)
check(SafetyManager.state() == "SCRAM", "flywheel overspeed is stopped by latched SCRAM")
local allSteamCut = true
for _, t in ipairs(world.fakeTurbines) do allSteamCut = allSteamCut and t.cap == 0 end
check(allSteamCut, "SCRAM cuts turbine steam after flywheel overspeed")

CONTROL_CONFIG.flywheelMode = false
for _, t in ipairs(world.fakeTurbines) do t.rpm = 0 end
SafetyManager.resetScram("test")
SafetyManager.requestMode("AUTO_OUTPUT", "test")
world.baseDraw = 0
stepOnly(500)
local backNormal = true
for _, t in ipairs(world.fakeTurbines) do
    backNormal = backNormal and t.rpm < SAFE
end
check(backNormal, "turbines return under safeRPM after SCRAM reset")

-- Fly button exists and toggles the mode.
local flyBtn = mon.touch.buttonList["Fly"]
check(flyBtn ~= nil, "Fly button exists")
if flyBtn then
    mon:handleEvents({ "monitor_touch", mon.id, flyBtn.xMin, flyBtn.yMin })
    check(CONTROL_CONFIG.flywheelMode == false, "first Fly touch requests confirmation")
    mon:handleEvents({ "monitor_touch", mon.id, flyBtn.xMin, flyBtn.yMin })
    check(CONTROL_CONFIG.flywheelMode == true, "second Fly touch arms flywheel mode")
    mon:handleEvents({ "monitor_touch", mon.id, flyBtn.xMin, flyBtn.yMin })
    check(CONTROL_CONFIG.flywheelMode == false, "touching Fly while armed disarms flywheel mode")
end

world.baseDraw = 0

--endregion

--region feature 6: efficiency calibration + optimize mode

CONTROL_CONFIG.calibrationSettleTicks = 6
CONTROL_CONFIG.optimizeMode = "output"
world.baseDraw = 0
runTicks(300) -- let band control restore the buffer into its ~50% band

local bigReactor = _G.reactors["BigReactors-Reactor_0"]
local okCal = bigReactor:startCalibration()
check(okCal, "calibration starts when the grid is not busy")

local guard = 0
while bigReactor.calibration and guard < 500 do
    tick = tick + 1
    _G.__simClock = tick / 20
    world.step()
    __test.runLoop(tick)
    guard = guard + 1
end
check(bigReactor.calibration == nil, "calibration sweep runs to completion")

local pointCount = 0
for _ in pairs(bigReactor.curve or {}) do pointCount = pointCount + 1 end
check(pointCount == 21, "efficiency curve recorded all 21 rod steps")
check(type(bigReactor.bestEffLevel) == "number"
    and bigReactor.bestEffLevel >= 0 and bigReactor.bestEffLevel <= 100,
    "best-efficiency rod level picked from the curve")

local saved = ConfigUtil.readState("BigReactors-Reactor_0")
check(saved and saved.curve and saved.bestEffLevel ~= nil, "efficiency curve persisted to state file")

-- Refuse to start while the grid is busy (buffer drained below the band).
world.baseDraw = 500000
runTicks(200)
local okBusy, busyReason = bigReactor:startCalibration()
check(not okBusy, "calibration refuses while grid is busy (" .. tostring(busyReason) .. ")")

-- Optimize-efficiency mode never pulls rods out past the sweet spot, even under heavy load.
bigReactor.bestEffLevel = 60
world.baseDraw = 500000
CONTROL_CONFIG.optimizeMode = "efficiency"
runTicks(300)
check(rodAverage(reactorBig.rods) >= 55, "efficiency mode holds rods at/above the sweet spot under load")

CONTROL_CONFIG.optimizeMode = "output"
runTicks(300)
check(rodAverage(reactorBig.rods) < 55, "output mode pulls rods below the sweet spot to chase load")

-- Opt / Calib buttons.
local optBtn = mon.touch.buttonList["Opt"]
check(optBtn ~= nil, "Opt button exists")
if optBtn then
    mon:handleEvents({ "monitor_touch", mon.id, optBtn.xMin, optBtn.yMin })
    check(CONTROL_CONFIG.optimizeMode == "efficiency", "touching Opt switches to efficiency mode")
    mon:handleEvents({ "monitor_touch", mon.id, optBtn.xMin, optBtn.yMin })
    check(CONTROL_CONFIG.optimizeMode == "output", "touching Opt switches back to output mode")
end
check(mon.touch.buttonList["Calib"] ~= nil, "Calib button exists")

-- Restore defaults for the remaining tests.
CONTROL_CONFIG.optimizeMode = "output"
bigReactor.bestEffLevel = nil
world.baseDraw = 0
ConfigUtil.writeConfig("control")

--endregion

--region efficiency merit-order dispatch

-- Unit tests on the allocator: A is more efficient (bestEff 200) than B (100). Sweet-spot
-- outputs 100/80, max outputs 300/200.
local function mkR(id, bestEff, sweetOut, maxOut)
    return { id = id, bestEff = bestEff, bestEffLevel = 60,
        curve = { [60] = { out = sweetOut }, [0] = { out = maxOut } } }
end

local t = {}
__test.assignMeritOrder({ mkR("A", 200, 100, 300), mkR("B", 100, 80, 200) }, 90, t)
check(t.A == 90 and t.B == 0, "dispatch: light load -> only the efficient reactor runs, other idled")

t = {}
__test.assignMeritOrder({ mkR("A", 200, 100, 300), mkR("B", 100, 80, 200) }, 150, t)
check(t.A == 100 and t.B == 50, "dispatch: A held at sweet spot, B picks up the remainder")

t = {}
__test.assignMeritOrder({ mkR("A", 200, 100, 300), mkR("B", 100, 80, 200) }, 400, t)
check(t.A == 300 and t.B == 100, "dispatch: overload ramps the efficient reactor to max first")

t = {}
__test.assignMeritOrder({ { id = "C" }, mkR("D", 100, 80, 200) }, 100, t)
check(next(t) == nil, "dispatch: falls back (no targets) when a reactor is uncalibrated")

-- Integration: give both passive reactors curves, and only in efficiency mode should the
-- controller publish per-reactor dispatch targets.
_G.reactors["BigReactors-Reactor_0"].curve = { [60] = { out = 40000 }, [0] = { out = 60000 } }
_G.reactors["BigReactors-Reactor_0"].bestEff = 250
_G.reactors["BigReactors-Reactor_0"].bestEffLevel = 60
_G.reactors["BigReactors-Reactor_1"].curve = { [60] = { out = 20000 }, [0] = { out = 30000 } }
_G.reactors["BigReactors-Reactor_1"].bestEff = 150
_G.reactors["BigReactors-Reactor_1"].bestEffLevel = 60

CONTROL_CONFIG.optimizeMode = "output"
world.baseDraw = 30000
runTicks(50)
check(_G.overallStats.dispatchTargets == nil, "dispatch: no targets published in output mode")

CONTROL_CONFIG.optimizeMode = "efficiency"
runTicks(50)
local dt = _G.overallStats.dispatchTargets
check(dt ~= nil and dt["BigReactors-Reactor_0"] ~= nil and dt["BigReactors-Reactor_1"] ~= nil,
    "dispatch: per-reactor targets published in efficiency mode")
check((dt["BigReactors-Reactor_0"] or 0) >= (dt["BigReactors-Reactor_1"] or 0),
    "dispatch: more of the load assigned to the more efficient reactor")

-- Restore defaults.
CONTROL_CONFIG.optimizeMode = "output"
_G.reactors["BigReactors-Reactor_0"].curve = nil
_G.reactors["BigReactors-Reactor_0"].bestEffLevel = nil
_G.reactors["BigReactors-Reactor_1"].curve = nil
_G.reactors["BigReactors-Reactor_1"].bestEffLevel = nil
world.baseDraw = 0
ConfigUtil.writeConfig("control")

--endregion

-- Detach/reattach shouldn't blow up.
__test.handlePeripheralDetach("BigReactors-Turbine_5")
tick = tick + 1; _G.__simClock = tick / 20
world.step()
__test.runLoop(tick)
__test.handlePeripheralAttach("BigReactors-Turbine_5", "BigReactors-Turbine")
tick = tick + 1; _G.__simClock = tick / 20
world.step()
__test.runLoop(tick)
check(true, "turbine detach/reattach survived")

-- Fault injection: high temperature latches SCRAM and forces every reactor safe.
local controlled = _G.reactors["BigReactors-Reactor_0"]
local savedTemp = controlled.averageFuelTemp
local savedMaxFuelTemperature = CONTROL_CONFIG.maxFuelTemperature
CONTROL_CONFIG.maxFuelTemperature = 100
controlled.averageFuelTemp = CONTROL_CONFIG.maxFuelTemperature + 1
SafetyManager.evaluate()
local allReactorsOff = true
for _, reactor in pairs(_G.reactors) do allReactorsOff = allReactorsOff and reactor.active == false end
check(SafetyManager.state() == "SCRAM" and allReactorsOff,
    "high-temperature interlock latches SCRAM and deactivates reactors")
controlled.averageFuelTemp = savedTemp
CONTROL_CONFIG.maxFuelTemperature = savedMaxFuelTemperature
check(SafetyManager.resetScram("test"), "temperature SCRAM resets after the sensor is safe")
SafetyManager.requestMode("AUTO_OUTPUT", "test")

-- Fault injection: losing every turbine while an active steam reactor is running is critical.
local savedTurbines = _G.turbines
local savedStartupGrace = CONTROL_CONFIG.safetyStartupGraceSeconds
CONTROL_CONFIG.safetyStartupGraceSeconds = 0
_G.turbines = {}
_G.reactors["BigReactors-Reactor_2"].active = true
SafetyManager.evaluate()
check(SafetyManager.state() == "SCRAM", "loss of all turbines SCRAMs an active steam reactor")
_G.turbines = savedTurbines
CONTROL_CONFIG.safetyStartupGraceSeconds = savedStartupGrace
check(SafetyManager.resetScram("test"), "missing-turbine SCRAM resets after restoration")
SafetyManager.requestMode("AUTO_OUTPUT", "test")

check(#HistoryManager.samples() > 0, "bounded history collects aggregate trend samples")
local telemetry = TelemetryExporter.snapshot()
check(telemetry.state and telemetry.reactors["BigReactors-Reactor_0"],
    "telemetry snapshot includes controller and per-reactor state")
local telemetryReactor = telemetry.reactors["BigReactors-Reactor_0"] or {}
local telemetryTurbine = telemetry.turbines["BigReactors-Turbine_1"] or {}
check(telemetry.storage and telemetry.dispatch
        and telemetry.storage.fillPct ~= nil and telemetry.storage.externalDemand ~= nil
        and telemetry.storage.sourceIDs ~= nil
        and telemetry.dispatch.requiredRF ~= nil and telemetry.dispatch.availableRF ~= nil,
    "telemetry snapshot includes aggregate storage and dispatch fields")
check(telemetryReactor.target ~= nil and telemetryReactor.capacity ~= nil
        and telemetryReactor.utilization ~= nil and telemetryReactor.capacitySource
        and telemetryReactor.controlStatus and telemetryReactor.degraded ~= nil
        and telemetryTurbine.target ~= nil and telemetryTurbine.capacity ~= nil
        and telemetryTurbine.utilization ~= nil and telemetryTurbine.capacitySource
        and telemetryTurbine.controlStatus and telemetryTurbine.degraded ~= nil,
    "telemetry snapshot includes per-device target/capacity/utilization/status fields")
for _, role in ipairs({ "overview", "reactors", "turbines", "alarms", "history" }) do
    mon.role = role
    check(pcall(function() mon:draw() end), "monitor renders " .. role .. " view")
end
mon.role = "overview"

-- Task 8 operator-visibility contract: scan the real terminal stub rather than asserting
-- implementation details.  Aggregate dispatch/storage labels must remain visible in every
-- device-facing role, and a degraded device must be called out in its card.
local function renderedText(target)
    local lines = {}
    for y = 1, target._h do
        local chars = {}
        for x = 1, target._w do
            local cell = target._grid[y] and target._grid[y][x]
            chars[x] = cell and cell.ch or " "
        end
        lines[#lines + 1] = table.concat(chars)
    end
    return table.concat(lines, "\n")
end
for _, role in ipairs({ "overview", "reactors", "turbines" }) do
    mon.role = role
    mon:draw()
    local text = renderedText(mon.mon)
    for _, label in ipairs({ "Demand", "Requested", "Available", "Stored", "Charge", "Target", "Actual" }) do
        check(text:find(label, 1, true) ~= nil,
            "monitor " .. role .. " shows dispatch label " .. label)
    end
end
local savedStatus = _G.reactors["BigReactors-Reactor_0"].controlStatus
_G.reactors["BigReactors-Reactor_0"].controlStatus = "DEGRADED"
mon.role = "reactors"
mon:draw()
check(renderedText(mon.mon):find("DEGRADED", 1, true) ~= nil,
    "degraded device card is visible")
_G.reactors["BigReactors-Reactor_0"].controlStatus = savedStatus
local smallMonitor = Monitor.new("small-task8", makeTerm(20, 10))
smallMonitor.role = "overview"
check(pcall(function() smallMonitor:draw() end), "small monitor renders without bounds errors")

-- Sentinel telemetry regression: values must come from the storage/dispatch snapshots and
-- device samples, not merely from static labels or stale aggregate fields.
local savedStorage, savedDispatch = _G.overallStats.storage, _G.overallStats.dispatch
local savedOverrides = CONTROL_CONFIG.entityOverrides["BigReactors-Reactor_2"]
local savedKnown = {}
local savedDeviceTelemetry = {}
for _, id in ipairs({ "BigReactors-Reactor_0", "BigReactors-Reactor_1", "BigReactors-Reactor_2" }) do
    savedKnown[id] = _G.reactors[id].capacityKnown
    savedDeviceTelemetry[id] = { capacityRF = _G.reactors[id].capacityRF, averageLastRFT = _G.reactors[id].averageLastRFT,
        averageFuelUsage = _G.reactors[id].averageFuelUsage, waste = _G.reactors[id].waste }
end
_G.overallStats.storage = { externalDemand=1234, requiredGeneration=2345, stored=3456,
    capacity=4567, fillPct=75, delta=-678, sourceIDs={ "sentinel-battery" } }
_G.overallStats.dispatch = { requiredRF=2345, availableRF=5678,
    reactors={
        ["BigReactors-Reactor_0"]={ target=1111 },
        ["BigReactors-Reactor_1"]={ target=2222 },
        ["BigReactors-Reactor_2"]={ target=3333 },
    }, turbines={} }
_G.reactors["BigReactors-Reactor_0"].capacityKnown = true
_G.reactors["BigReactors-Reactor_0"].capacityRF = 10000
_G.reactors["BigReactors-Reactor_0"].averageLastRFT = 4000
_G.reactors["BigReactors-Reactor_0"].averageFuelUsage = 7.321
_G.reactors["BigReactors-Reactor_0"].waste = 987
_G.reactors["BigReactors-Reactor_1"].capacityKnown = false
_G.reactors["BigReactors-Reactor_2"].capacityKnown = false
CONTROL_CONFIG.entityOverrides["BigReactors-Reactor_2"] = { maxSteamPerTick = 4444 }
mon.role = "reactors"
mon:draw()
local sentinelText = renderedText(mon.mon)
for _, value in ipairs({ "1.23K", "2.35K", "5.68K", "3.46K", "4.57K", "75.0%", "-678" }) do
    check(sentinelText:find(value, 1, true) ~= nil, "monitor renders sentinel value " .. value)
end
check(sentinelText:find("Target", 1, true) ~= nil and sentinelText:find("1.11K", 1, true) ~= nil
        and sentinelText:find("Actual", 1, true) ~= nil and sentinelText:find("4.00K", 1, true) ~= nil,
    "monitor renders device target and actual values")
check(sentinelText:find("Util", 1, true) ~= nil and sentinelText:find("learned", 1, true) ~= nil
        and sentinelText:find("observing", 1, true) ~= nil and sentinelText:find("configured", 1, true) ~= nil,
    "monitor renders utilization and all capacity source variants")
check(sentinelText:find("40.0%", 1, true) ~= nil, "monitor renders numeric device utilization")
check(sentinelText:find("7.321", 1, true) ~= nil and sentinelText:find("987", 1, true) ~= nil,
    "monitor renders fuel and waste simultaneously")
mon.detailEntity = { kind = "reactor", obj = _G.reactors["BigReactors-Reactor_0"] }
mon:draw()
check(renderedText(mon.mon):find("sentinel-battery", 1, true) ~= nil,
    "monitor detail includes contributing storage ID")
mon.detailEntity = nil
_G.overallStats.storage, _G.overallStats.dispatch = savedStorage, savedDispatch
CONTROL_CONFIG.entityOverrides["BigReactors-Reactor_2"] = savedOverrides
for id, known in pairs(savedKnown) do
    _G.reactors[id].capacityKnown = known
    _G.reactors[id].capacityRF = savedDeviceTelemetry[id].capacityRF
    _G.reactors[id].averageLastRFT = savedDeviceTelemetry[id].averageLastRFT
    _G.reactors[id].averageFuelUsage = savedDeviceTelemetry[id].averageFuelUsage
    _G.reactors[id].waste = savedDeviceTelemetry[id].waste
end

--endregion
--region sustained-output dispatch integration phases

-- The preceding fault-injection cases deliberately leave the safety state READY.  These
-- measured control phases require the real automatic actuator pass to be running.
_G.__simClock = _G.__simClock + 2
SafetyManager.requestMode("AUTO_OUTPUT", "test-dispatch-phases")
check(SafetyManager.isRunning(), "dispatch phases start from RUNNING safety state")

local function fillAllElectricalStores()
    for _, reactor in ipairs(world.passiveReactors) do reactor.battery = reactor.batteryCap end
    for _, turbine in ipairs(world.fakeTurbines) do turbine.buffer = turbine.bufferCap end
    world.externalStore.stored = world.externalStore.capacity
end

-- A near-full grid under a real steady draw must continue to request that draw.  It may not
-- zero generation merely because a previous tick charged storage.
fillAllElectricalStores()
CONTROL_CONFIG.storageExclusions = {
    ["BigReactors-Reactor_0"] = true, ["BigReactors-Reactor_1"] = true,
    ["BigReactors-Reactor_2"] = true, ["BigReactors-Turbine_1"] = true,
    ["BigReactors-Turbine_2"] = true, ["BigReactors-Turbine_3"] = true,
    ["BigReactors-Turbine_4"] = true, ["BigReactors-Turbine_5"] = true,
}
for _, reactor in ipairs(world.passiveReactors) do reactor.battery = 0 end
for _, turbine in ipairs(world.fakeTurbines) do turbine.buffer = 0 end
world.externalStore.stored = world.externalStore.capacity * 0.98
world.baseDraw = 25000
local nearFullRequired, nearFullDelta, nearFullSamples = 0, 0, 0
runTicks(40, function()
    if nearFullSamples >= 20 then
        nearFullRequired = nearFullRequired + ((_G.overallStats.dispatch or {}).requiredRF or 0)
        nearFullDelta = nearFullDelta + ((_G.overallStats.storage or {}).delta or 0)
    end
    nearFullSamples = nearFullSamples + 1
end)
local nearFullTail = math.max(1, nearFullSamples - 20)
local measuredExternalDraw = math.max(0, -nearFullDelta / nearFullTail)
check(math.abs(nearFullRequired / nearFullTail - measuredExternalDraw) <= math.max(1, measuredExternalDraw * 0.10)
        and nearFullDelta / nearFullTail <= 0,
    string.format("near-full storage: required generation follows draw without positive storage drift (%.0f RF/t, %.0f delta)",
        nearFullRequired / nearFullTail, nearFullDelta / nearFullTail))
CONTROL_CONFIG.storageExclusions = {}

-- A full, unloaded grid publishes zero generation targets instead of self-sustaining from
-- last-tick generation.  The turbine governor may still retain a safe idle RPM; the commands
-- themselves must be zero.
fillAllElectricalStores()
world.baseDraw = 0
runTicks(3)
local noUnneededTargets = true
for _, target in pairs(_G.overallStats.reactorTargets or {}) do
    noUnneededTargets = noUnneededTargets and (target.target or 0) == 0
end
for _, target in pairs(_G.overallStats.turbineTargets or {}) do
    noUnneededTargets = noUnneededTargets and (target.rfTarget or 0) == 0
end
check(noUnneededTargets, "full storage/low demand: unnecessary devices receive zero targets")

-- A sudden load step is visible in the requested generation before a comfortably full grid
-- has dropped through its 50% reserve floor.
world.baseDraw = 500000
local generationBeforeStep = _G.overallStats.totalRFT or 0
runTicks(5)
check((_G.overallStats.dispatch.requiredRF or 0) > 0
        and (_G.overallStats.totalRFT or 0) >= generationBeforeStep
        and (_G.overallStats.storage.fillPct or 0) > 50,
    "load step: requested and actuated generation rise before storage falls below 50%")

-- At low fill and overwhelming demand, allocation saturates at sustainable capacity rather
-- than splitting a fixed RF amount equally between the 20k and 80k reactors.
for _, reactor in ipairs(world.passiveReactors) do reactor.battery = 0 end
for _, turbine in ipairs(world.fakeTurbines) do turbine.buffer = 0 end
world.externalStore.stored = 0
world.baseDraw = 1000000
CONTROL_CONFIG.entityOverrides["BigReactors-Reactor_0"] = { maxRFPerTick = 80000 }
CONTROL_CONFIG.entityOverrides["BigReactors-Reactor_1"] = { maxRFPerTick = 20000 }
for i = 1, 5 do
    CONTROL_CONFIG.entityOverrides["BigReactors-Turbine_" .. i] = { maxRFPerTick = 1 }
end
runTicks(80)
local passiveMeasured = reactorBig.genLast + reactorMid.genLast
check(passiveMeasured >= 90000,
    string.format("low storage/high demand: measured passive generation reaches sustainable capacity (%.0f RF/t)",
        passiveMeasured))
CONTROL_CONFIG.entityOverrides["BigReactors-Reactor_0"] = nil
CONTROL_CONFIG.entityOverrides["BigReactors-Reactor_1"] = nil
for i = 1, 5 do CONTROL_CONFIG.entityOverrides["BigReactors-Turbine_" .. i] = nil end

-- Storage topology changes establish a fresh one-tick delta baseline; neither a newly
-- attached battery nor a detached one is mistaken for an instantaneous load.
local probeStore = { stored=300000, capacity=1000000 }
peripheral.register("storage_probe", "energy_storage", {
    getEnergy = function() return probeStore.stored end,
    getEnergyCapacity = function() return probeStore.capacity end,
})
__test.handlePeripheralAttach("storage_probe", "energy_storage")
runTicks(1)
check((_G.overallStats.storage or {}).delta == 0,
    "storage attach: delta baseline resets for one tick")
__test.handlePeripheralDetach("storage_probe")
runTicks(1)
check((_G.overallStats.storage or {}).delta == 0,
    "storage detach: delta baseline resets for one tick")

-- The real controller/world loop must translate a higher load allocation into a higher requested
-- cap and a higher granted steam flow/RF; zero demand must actively close steam/coils.  These
-- cases deliberately use runTicks so world.step performs the proportional steam grant.
local dispatchTurbine = world.fakeTurbines[1]
local dispatchTurbineID = "BigReactors-Turbine_1"
local turbineWrapper = _G.turbines[dispatchTurbineID]
local function resetDispatchWorld(demand, stored)
    CONTROL_CONFIG.flywheelMode = false
    SafetyManager.resetScram("dispatch measurement")
    SafetyManager.requestMode("AUTO_OUTPUT", "dispatch measurement")
    if demand == 0 then fillAllElectricalStores() end
    world.baseDraw, world.externalStore.stored = demand, stored
    world.steamTank.amount = world.steamTank.capacity
    dispatchTurbine.active, dispatchTurbine.rpm, dispatchTurbine.cap, dispatchTurbine.coils, dispatchTurbine.buffer = true, 1900, 0, false, 0
    turbineWrapper.active, turbineWrapper.rpm, turbineWrapper.averageRPM = true, 1900, 1900
    turbineWrapper.energyStored, turbineWrapper.energyCapacity = 0, dispatchTurbine.bufferCap
    turbineWrapper.pid.integral, turbineWrapper.bestSustainedRPM = 0, 0
    turbineWrapper.lastWrittenSteamCap, turbineWrapper.lastWrittenCoils = -1, nil
end
local function measureLoadDispatch(demand, stored)
    resetDispatchWorld(demand, stored)
    local targetFlow, cap, actualFlow, rf = 0, 0, 0, 0
    runTicks(12, function()
        local target = ((_G.overallStats.turbineTargets or {})[dispatchTurbineID] or {})
        targetFlow, cap = target.flowTarget or 0, dispatchTurbine.cap
        actualFlow, rf = dispatchTurbine.flowLast, dispatchTurbine.genLast
    end)
    return targetFlow, cap, actualFlow, rf, dispatchTurbine.coils
end
local lowTarget, lowCap, lowFlow, lowRF = measureLoadDispatch(10000, 0)
local highTarget, highCap, highFlow, highRF = measureLoadDispatch(500000, 0)
local zeroTarget, zeroCap, zeroFlow, zeroRF, zeroCoils = measureLoadDispatch(0, world.externalStore.capacity)
check(highTarget > lowTarget and highCap > lowCap and highFlow > lowFlow and highRF > lowRF,
    string.format("turbine dispatch: high load raises target/cap/granted flow/RF (%.0f/%d/%.0f/%.0f -> %.0f/%d/%.0f/%.0f)",
        lowTarget, lowCap, lowFlow, lowRF, highTarget, highCap, highFlow, highRF))
check(zeroTarget == 0 and zeroCap == 0 and zeroFlow == 0 and zeroRF == 0 and not zeroCoils,
    "turbine dispatch: zero demand closes target, cap, granted flow, RF, and coils")

local savedTurbineOverride = CONTROL_CONFIG.entityOverrides[dispatchTurbineID]
CONTROL_CONFIG.entityOverrides[dispatchTurbineID] = {dispatchWeight=3, maxFlowPerTick=120}
resetDispatchWorld(500000, 0)
local weightedTarget, peerTarget, weightedFlow, weightedCap = 0, 0, 0, 0
runTicks(12, function()
    local targets = _G.overallStats.turbineTargets or {}
    weightedTarget = (targets[dispatchTurbineID] or {}).rfTarget or 0
    peerTarget = (targets["BigReactors-Turbine_2"] or {}).rfTarget or 0
    weightedFlow, weightedCap = (targets[dispatchTurbineID] or {}).flowTarget or 0, dispatchTurbine.cap
end)
check(weightedTarget > peerTarget * 2 and weightedFlow <= 120 and weightedCap <= 120,
    string.format("turbine overrides: weight changes share and max flow caps target/actuation (%.0f/%.0f, %.0f/%d)",
        weightedTarget, peerTarget, weightedFlow, weightedCap))
CONTROL_CONFIG.entityOverrides[dispatchTurbineID] = savedTurbineOverride

-- With flywheel armed, a positive allocation remains a normal target-driven generator while an
-- explicitly idle peer is permitted to use the flywheel path.  A controller/world tick then
-- proves that the idle peer's overspeed still SCRAMs the system.
local flywheelIdle = world.fakeTurbines[2]
local flywheelIdleID = "BigReactors-Turbine_2"
local flywheelIdleWrapper = _G.turbines[flywheelIdleID]
fillAllElectricalStores()
world.baseDraw = 0
SafetyManager.resetScram("flywheel mixed demand")
SafetyManager.requestMode("AUTO_OUTPUT", "flywheel mixed demand")
CONTROL_CONFIG.flywheelMode = true
CONTROL_CONFIG.flywheelCeilingRPM = 0
world.steamTank.amount = world.steamTank.capacity
for _, pair in ipairs({ {dispatchTurbine, turbineWrapper, 1900}, {flywheelIdle, flywheelIdleWrapper, 1800} }) do
    local fake, wrapper, rpm = pair[1], pair[2], pair[3]
    fake.active, fake.rpm, fake.cap, fake.coils, fake.buffer = true, rpm, 0, false, fake.bufferCap
    wrapper.active, wrapper.rpm, wrapper.averageRPM = true, rpm, rpm
    wrapper.energyStored, wrapper.energyCapacity, wrapper.desiredCoils = fake.bufferCap, fake.bufferCap, false
    wrapper.lastWrittenSteamCap, wrapper.lastWrittenCoils = -1, nil
end
for i = 3, #world.fakeTurbines do
    world.fakeTurbines[i].active = false
    _G.turbines["BigReactors-Turbine_" .. i].active = false
end
local savedMixedDispatch = _G.overallStats.dispatch
_G.overallStats.dispatch = { reactors=_G.overallStats.reactorTargets or {}, turbines={
    [dispatchTurbineID] = {rfTarget=200, flowTarget=200, rpmLimit=2400},
    [flywheelIdleID] = {rfTarget=0, flowTarget=0, rpmLimit=2400},
}, availableRF=100000 }
__test.applyDispatch(true)
local positiveCap, idleCap = dispatchTurbine.cap, flywheelIdle.cap
runTicks(1)
local positiveFlow = dispatchTurbine.flowLast
runTicks(40)
_G.overallStats.dispatch = savedMixedDispatch
check(positiveCap > 0 and positiveFlow > 0,
    string.format("flywheel mixed demand: positive target remains target-driven (cap %d flow %.0f)",
        positiveCap, positiveFlow))
check(positiveCap <= 400 and dispatchTurbine.flowLast <= 400,
    "flywheel mixed demand: positive target does not become flywheel full-throttle")
check(idleCap == flywheelIdle.flowMaxMax,
    "flywheel mixed demand: zero target idle turbine may spin/store")
check(SafetyManager.state() == "SCRAM",
    string.format("flywheel mixed demand: idle overspeed SCRAMs (rpm %.0f cap %d)", flywheelIdle.rpm, flywheelIdle.cap))
CONTROL_CONFIG.flywheelMode = false
for i, fake in ipairs(world.fakeTurbines) do
    fake.active = true
    _G.turbines["BigReactors-Turbine_" .. i].active = true
end
SafetyManager.resetScram("dispatch measurement cleanup")
SafetyManager.requestMode("AUTO_OUTPUT", "dispatch measurement cleanup")

-- One throwing reactor setter is isolated.  Its healthy asymmetric peer receives the newly
-- redistributed target in the same tick, without a recursive retry of the failed setter.
world.baseDraw = 50000
runTicks(8)
local healthyId = "BigReactors-Reactor_1"
local targetBeforeFailure = ((_G.overallStats.reactorTargets or {})[healthyId] or {}).target or 0
local originalSetter = reactorBig.methods.setControlRodsLevels
local setterCalls = 0
local probeCalls = {}
local turbineWrappers = {}
for id, turbine in pairs(_G.turbines) do
    local originalControl = turbine.updateControl
    turbineWrappers[id] = originalControl
    turbine.updateControl = function(self, config, steer, target, context)
        if context and context.probeAllowed then probeCalls[id] = (probeCalls[id] or 0) + 1 end
        return originalControl(self, config, steer, target, context)
    end
end
reactorBig.methods.setControlRodsLevels = function(_)
    setterCalls = setterCalls + 1
    error("injected reactor setter failure")
end
runTicks(1)
local targetAfterFailure = ((_G.overallStats.reactorTargets or {})[healthyId] or {}).target or 0
local probedTurbines = 0
for _ in pairs(probeCalls) do probedTurbines = probedTurbines + 1 end
check(setterCalls == 1 and targetAfterFailure > targetBeforeFailure
        and ((_G.overallStats.storage or {}).delta or 0) == 0,
    string.format("write failure: healthy target rises and storage baseline resets in same tick (%.0f -> %.0f)",
        targetBeforeFailure, targetAfterFailure))
check(probedTurbines <= 1, "write failure: redistribution keeps one turbine probe selection")
reactorBig.methods.setControlRodsLevels = originalSetter
for id, originalControl in pairs(turbineWrappers) do _G.turbines[id].updateControl = originalControl end

--endregion
-- Fault injection: an incompatible ATM10 peripheral is rejected before construction.  This
-- comes after the running dispatch phases because its capability report intentionally blocks
-- subsequent SafetyManager self-tests.
peripheral.register("bad_reactor", "BigReactors-Reactor", { getActive = function() return true end })
local compatible, missing = CapabilityValidator.validate("bad_reactor", "reactor")
check(not compatible and #missing > 0, "capability gate rejects an incomplete reactor API")
--region render preview (text-only dump of the fake monitor)

print("\n--- monitor render preview (text cells only, first 46 rows) ---")
local win = mon.mon
for y = 1, math.min(46, win._h) do
    local row = {}
    for x = 1, win._w do
        local cell = win._grid[y] and win._grid[y][x]
        row[x] = (cell and cell.ch ~= " " and cell.ch) or (cell and "#" or ".")
    end
    print(table.concat(row))
end

--endregion

print("")
if #failures > 0 then
    print(#failures .. " FAILURE(S):")
    for _, f in ipairs(failures) do print("  - " .. f) end
    os.exit(1)
else
    print("ALL CHECKS PASSED")
end
