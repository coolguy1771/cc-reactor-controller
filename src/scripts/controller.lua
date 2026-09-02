-- Controller orchestration: peripheral registry, tick loop, aggregate stats, and the
-- per-tick control passes for reactors (rods) and turbines (steam PID + coils + safety).
--
-- Per game tick (20/s), runLoop():
--   1. update every EnergyBuffer, Reactor, Turbine (read peripherals, refresh averages)
--   2. updateOverallStats()  - aggregate grid energy, steam production/consumption, shares
--   3. if autoMode: reactor rod PIDs + turbine control laws
--   4. every TICKS_TO_REDRAW ticks: redraw all monitors
--
-- Concurrently, eventListener() reacts to monitor touches/resizes and peripheral
-- attach/detach, so devices can be (un)plugged live without restarting.

---@type table<string, Monitor>
_G.monitors = {}
---@type table<string, Reactor>
_G.reactors = {}
---@type table<string, Turbine>
_G.turbines = {}
---@type table<string, EnergyBuffer>
_G.energyBuffers = {}

-- StorageCoordinator resets its delta baseline whenever this revision changes.  The revision
-- covers every power/storage source, rather than treating a hot-plugged battery as a real load.
local storageCoordinator = StorageCoordinator and StorageCoordinator.new() or nil
local topologyRevision = 0
local unavailableDevices = {}
local turbineProbeCursor = 0

-- Master on/off states (mapped to the monitor's control buttons).
_G.btnOn = true        -- reactors
_G.turbinesOn = true   -- turbines

-- Aggregate stats, recomputed every tick. Smoothed values are used where available.
---@class OverallStats
_G.overallStats = {
    storedLastTick = 0,
    storedThisTick = 0,
    capacity = 1,

    lastRFT = 0,          -- passive reactor RF generation (drives rfLost feedback)
    turbineRFT = 0,       -- turbine RF generation
    totalRFT = 0,         -- lastRFT + turbineRFT (display)
    rfLost = 0,           -- grid drain (display)
    rfLostPerReactor = 0, -- per passive-reactor control target

    fuelUsage = 0,
    waste = 0,

    steamProductionRate = 0,
    storedSteam = 0,
    steamCapacity = 0,
    steamConsumedLastTick = 0,     -- total turbine steam draw (display)
    steamConsumedPerReactor = 0,   -- per active-reactor control target

    passiveReactorCount = 0,
    activeReactorCount = 0,
    turbineCount = 0,

    steamGroups = {},        -- groupId -> per-group steam cascade stats (see updateSteamGroups)
    hasSteamGroups = false,  -- true when >1 group is configured (UI shows group badges)
    dispatchTargets = nil,   -- efficiency mode: reactorID -> assigned generation target (merit order)
    storage = nil,
    dispatch = nil,
    reactorTargets = {},
    turbineTargets = {},
    topologyRevision = topologyRevision,

    efficiency = function()
        if _G.overallStats.fuelUsage <= 0 then return 0 end
        return _G.overallStats.totalRFT / _G.overallStats.fuelUsage
    end,
}

local function sortedIDs(devices)
    local ids = {}
    for id in pairs(devices) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

local function configuredCapacity(id, key, fallback)
    local value = getEntitySetting and getEntitySetting(id, key) or nil
    if type(value) == "number" and value > 0 then return value end
    return math.max(1, fallback or 1)
end

-- The device wrappers cache their own batteries during sampling.  Keep those snapshots in the
-- storage model, but do not wrap them again as EnergyBuffer peripherals (which double-counts).
local function buildStorageSources()
    local sources = {}
    for id, reactor in pairs(_G.reactors) do
        sources[#sources + 1] = { id=id, stored=reactor.energyStored, capacity=reactor.energyCapacity,
            valid=not unavailableDevices[id] }
    end
    for id, turbine in pairs(_G.turbines) do
        sources[#sources + 1] = { id=id, stored=turbine.energyStored, capacity=turbine.energyCapacity,
            valid=not unavailableDevices[id] }
    end
    for id, buffer in pairs(_G.energyBuffers) do
        sources[#sources + 1] = { id=id, stored=buffer.energyStoredThisTick, capacity=buffer.capacity,
            valid=not unavailableDevices[id] }
    end
    return sources
end

local function buildDispatchInput(storage)
    local previousReactors, previousTurbines = {}, {}
    for id, target in pairs(_G.overallStats.reactorTargets or {}) do
        -- Dispatcher deadband consumes scalar reactor RF/steam targets.  Published targets are
        -- richer tables so actuator callers can retain the unit alongside the number.
        previousReactors[id] = type(target) == "table" and target.target or target
    end
    for id, target in pairs(_G.overallStats.turbineTargets or {}) do
        previousTurbines[id] = type(target) == "table" and target.rfTarget or target
    end
    local input = { requiredRF=storage.requiredGeneration or 0, previousTargets={
        reactors=previousReactors, turbines=previousTurbines,
    }, passiveReactors={}, activeReactors={}, turbines={}, steamGroups=_G.overallStats.steamGroups or {} }
    for id, reactor in pairs(_G.reactors) do
        local descriptor = { id=id, groupId=reactor.groupId or "default", available=not unavailableDevices[id] }
        if reactor.activelyCooled then
            descriptor.capacity = configuredCapacity(id, "maxSteamPerTick", math.max(reactor.capacitySteam or 1,
                reactor.averageSteamProductionRate or 0, reactor.steamProductionRate or 0))
            input.activeReactors[#input.activeReactors + 1] = descriptor
        else
            descriptor.capacity = configuredCapacity(id, "maxRFPerTick", math.max(reactor.capacityRF or 1,
                reactor.averageLastRFT or 0, reactor.lastRFT or 0))
            input.passiveReactors[#input.passiveReactors + 1] = descriptor
        end
    end
    for id, turbine in pairs(_G.turbines) do
        local ratio = turbine.rfPerSteam
        if type(ratio) ~= "number" or ratio <= 0 then ratio = 1 end
        input.turbines[#input.turbines + 1] = {
            id=id, groupId=turbine.groupId or "default", available=not unavailableDevices[id],
            capacity=configuredCapacity(id, "maxRFPerTick", math.max(turbine.capacityRF or 1,
                turbine.averageEnergyProduced or 0, turbine.energyProduced or 0, (turbine.flowMaxMax or 0) * ratio)),
            maxFlow=turbine.flowMaxMax or 0, rfPerSteam=ratio,
        }
    end
    -- Until active-reactor capacity learning has a settled observation, do not let a low
    -- startup sample throttle a whole steam group below the turbines' requested flow.
    local groupFlowCeilings = {}
    for _, turbine in ipairs(input.turbines) do
        local gid = turbine.groupId
        groupFlowCeilings[gid] = (groupFlowCeilings[gid] or 0) + (turbine.maxFlow or 0)
    end
    for _, reactor in ipairs(input.activeReactors) do
        if not _G.reactors[reactor.id].capacityKnown then
            reactor.capacity = math.max(reactor.capacity or 1, groupFlowCeilings[reactor.groupId] or 1)
        end
    end
    return input
end

local function publishDispatch(storage)
    if not storageCoordinator or not Dispatcher then return nil end
    local input = buildDispatchInput(storage)
    local dispatch = Dispatcher.allocate(input, CONTROL_CONFIG)
    if CONTROL_CONFIG.optimizeMode == "efficiency" then
        computeDispatch(_G.overallStats)
        for id, target in pairs(_G.overallStats.dispatchTargets or {}) do
            local reactor = _G.reactors[id]
            if reactor then
                local sweet = reactor.curve and reactor.bestEffLevel and reactor.curve[reactor.bestEffLevel]
                if sweet and type(sweet.out) == "number" then target = math.min(target, sweet.out) end
                dispatch.reactors[id] = { unit=reactor.activelyCooled and "steam" or "rf", target=target }
            end
        end
        -- A calibrated device remains bounded at its own sweet spot even when another
        -- uncalibrated peer prevents the all-or-nothing merit preview from being published.
        for id, reactor in pairs(_G.reactors) do
            local sweet = reactor.curve and reactor.bestEffLevel and reactor.curve[reactor.bestEffLevel]
            local target = dispatch.reactors[id]
            if sweet and target and type(sweet.out) == "number" then
                target.target = math.min(target.target or 0, sweet.out)
            end
        end
    end
    -- Turbine RPM governor owns actual steam flow.  Cascade active-reactor targets to the
    -- measured flow in each isolated group, so a transient turbine throttle cannot make an
    -- active reactor manufacture steam merely because its RF allocation is larger.
    local groupDemand, groupCapacity = {}, {}
    for groupId, group in pairs(_G.overallStats.steamGroups or {}) do
        groupDemand[groupId] = math.max(0, group.consumption or 0)
    end
    local groupBootstrap = {}
    for _, turbine in ipairs(input.turbines) do
        local target = dispatch.turbines[turbine.id]
        groupBootstrap[turbine.groupId] = (groupBootstrap[turbine.groupId] or 0) + (target and target.flowTarget or 0)
    end
    for groupId, demand in pairs(groupDemand) do
        if demand <= 0 then groupDemand[groupId] = groupBootstrap[groupId] or 0 end
        if CONTROL_CONFIG.flywheelMode then
            groupDemand[groupId] = math.max(groupDemand[groupId], groupBootstrap[groupId] or 0)
        end
        local group = (_G.overallStats.steamGroups or {})[groupId]
        local pct = group and group.steamCapacity > 0 and group.storedSteam / group.steamCapacity * 100 or 0
        local high = CONTROL_CONFIG.bufferMax or 70
        if pct > high and high < 100 then
            -- Storage-aware dispatch must also unwind an already-full steam tank.  This is
            -- deliberately per-group: pressure in group A never throttles group B.
            groupDemand[groupId] = groupDemand[groupId] * math.max(0, 1 - (pct - high) / (100 - high))
        end
    end
    for _, reactor in ipairs(input.activeReactors) do
        groupCapacity[reactor.groupId] = (groupCapacity[reactor.groupId] or 0) + (reactor.capacity or 0)
    end
    for _, reactor in ipairs(input.activeReactors) do
        local capacity = groupCapacity[reactor.groupId] or 0
        local demand = groupDemand[reactor.groupId] or 0
        dispatch.reactors[reactor.id] = { unit="steam", target=(storage.requiredGeneration or 0) > 0
            and capacity > 0 and demand * reactor.capacity / capacity or 0 }
    end
    local s = _G.overallStats
    s.storage, s.dispatch = storage, dispatch
    s.reactorTargets, s.turbineTargets = dispatch.reactors, dispatch.turbines
    return dispatch
end

_G.selectedReactor = nil

local function updateOverallStats()
    local s = _G.overallStats
    s.topologyRevision = topologyRevision

    -- Aggregate energy buffer = every internal RF buffer on the net (passive reactors + turbines).
    s.storedLastTick = 0
    s.storedThisTick = 0
    s.capacity = 0
    for _, buffer in pairs(_G.energyBuffers) do
        s.storedLastTick = s.storedLastTick + buffer.averageEnergyStoredLastTick
        s.storedThisTick = s.storedThisTick + buffer.averageEnergyStoredThisTick
        s.capacity = s.capacity + buffer.capacity
    end
    if s.capacity <= 0 then s.capacity = 1 end

    s.fuelUsage = 0
    s.waste = 0
    s.lastRFT = 0
    s.steamProductionRate = 0
    s.storedSteam = 0
    s.steamCapacity = 0
    s.passiveReactorCount = 0
    s.activeReactorCount = 0

    for _, reactor in pairs(_G.reactors) do
        if reactor.activelyCooled then
            s.activeReactorCount = s.activeReactorCount + 1
            s.steamProductionRate = s.steamProductionRate + reactor.averageSteamProductionRate
            s.storedSteam = s.storedSteam + reactor.averageStoredSteam
            s.steamCapacity = s.steamCapacity + reactor.steamCapacity
        else
            s.passiveReactorCount = s.passiveReactorCount + 1
            s.lastRFT = s.lastRFT + reactor.averageLastRFT
        end
        s.fuelUsage = s.fuelUsage + reactor.averageFuelUsage
        s.waste = s.waste + reactor.waste
    end

    -- Turbines: RF generation (display) and actual steam consumption (cascade to steam reactors).
    s.turbineRFT = 0
    s.steamConsumedLastTick = 0
    s.turbineCount = 0
    for _, turbine in pairs(_G.turbines) do
        s.turbineCount = s.turbineCount + 1
        s.turbineRFT = s.turbineRFT + turbine.averageEnergyProduced
        s.steamConsumedLastTick = s.steamConsumedLastTick + turbine.averageSteamFlow
    end

    s.totalRFT = s.lastRFT + s.turbineRFT

    updateSteamGroups(s)

    if storageCoordinator then
        local availableRF = 0
        for _, reactor in pairs(_G.reactors) do
            if not reactor.activelyCooled then
                availableRF = availableRF + configuredCapacity(reactor.id, "maxRFPerTick", math.max(reactor.capacityRF or 1,
                    reactor.averageLastRFT or 0, reactor.lastRFT or 0))
            end
        end
        for _, turbine in pairs(_G.turbines) do
            local ratio = turbine.rfPerSteam
            if type(ratio) ~= "number" or ratio <= 0 then ratio = 1 end
            availableRF = availableRF + configuredCapacity(turbine.id, "maxRFPerTick",
                math.max(turbine.capacityRF or 1, turbine.averageEnergyProduced or 0,
                    turbine.energyProduced or 0, (turbine.flowMaxMax or 0) * ratio))
        end
        local storage = storageCoordinator:update({
            sources=buildStorageSources(), actualGeneration=s.totalRFT,
            availableGeneration=availableRF, topologyRevision=topologyRevision,
        }, CONTROL_CONFIG)
        -- At/above the storage ceiling, the observable storage discharge is the reliable
        -- external draw.  Generation can be clipped by full internal batteries, so using the
        -- raw generator total here would perpetuate surplus output forever.
        if storage.fillPct >= (CONTROL_CONFIG.storageTargetMax or 85) then
            storage.externalDemand = math.max(0, -storage.delta)
            storage.rechargeCorrection = 0
            storage.requiredGeneration = storage.externalDemand
        elseif storage.fillPct <= (CONTROL_CONFIG.storageTargetMin or 50) and storage.delta == 0 then
            -- An empty grid cannot reveal an unmet load through a storage delta.  Ask every
            -- currently known source for capacity so the controller recovers instead of
            -- self-limiting to its last small output sample.
            storage.requiredGeneration = availableRF
        end
        s.storedLastTick = storage.stored - storage.delta
        s.storedThisTick = storage.stored
        s.capacity = math.max(1, storage.capacity)
        s.rfLost = math.floor(storage.externalDemand + 0.5)
        publishDispatch(storage)
        -- Retain the calibration/efficiency UI's legacy merit-order preview.  Actuators use
        -- the storage-aware targets above in every automatic mode.
        computeDispatch(s)
    else
        -- Keep the pre-dispatch fallback usable for partial test harnesses and old installs.
        s.rfLost = math.floor(s.lastRFT + s.storedLastTick - s.storedThisTick + 0.5)
        computeDispatch(s)
    end
    s.rfLostPerReactor = s.rfLost / math.max(1, s.passiveReactorCount)
    s.steamConsumedPerReactor = s.steamConsumedLastTick / math.max(1, s.activeReactorCount)
end

-- Resolve the configured steam groups into a membership lookup. Every reactor/turbine id not
-- named in any group maps to the shared "default" group, so an empty steamGroups list keeps
-- the original single-network behavior.
---@return table reactorGroup id->groupId, table turbineGroup id->groupId
local function resolveGroupMembership()
    local reactorGroup, turbineGroup = {}, {}
    local groups = CONTROL_CONFIG.steamGroups or {}
    for i, group in ipairs(groups) do
        for _, rid in ipairs(group.reactors or {}) do reactorGroup[rid] = i end
        for _, tid in ipairs(group.turbines or {}) do turbineGroup[tid] = i end
    end
    return reactorGroup, turbineGroup
end

-- Per-group steam cascade. For each group, active reactors chase ONLY that group's turbine
-- steam draw and band-seek on that group's own steam tanks. Results are stashed on
-- overallStats so reactor:updateRods can read its group's numbers; each reactor/turbine also
-- gets a .groupId for the UI. With no groups configured, everything lands in "default" and
-- this reproduces the aggregate cascade exactly.
---@param s OverallStats
function updateSteamGroups(s)
    local reactorGroup, turbineGroup = resolveGroupMembership()
    local groups = {}

    local function groupFor(id)
        if not groups[id] then
            groups[id] = { consumption = 0, storedSteam = 0, steamCapacity = 0, reactorCount = 0, turbineCount = 0 }
        end
        return groups[id]
    end

    for id, turbine in pairs(_G.turbines) do
        local gid = turbineGroup[id] or "default"
        turbine.groupId = gid
        local g = groupFor(gid)
        g.consumption = g.consumption + turbine.averageSteamFlow
        g.turbineCount = g.turbineCount + 1
    end

    for id, reactor in pairs(_G.reactors) do
        if reactor.activelyCooled then
            local gid = reactorGroup[id] or "default"
            reactor.groupId = gid
            local g = groupFor(gid)
            g.storedSteam = g.storedSteam + reactor.averageStoredSteam
            g.steamCapacity = g.steamCapacity + reactor.steamCapacity
            g.reactorCount = g.reactorCount + 1
        else
            reactor.groupId = nil
        end
    end

    for _, g in pairs(groups) do
        g.consumedPerReactor = g.consumption / math.max(1, g.reactorCount)
    end

    s.steamGroups = groups
    updateSteamCoordination(s)
    -- More than one non-empty group means the UI should surface group ids on the cards.
    local count = 0
    for _ in pairs(groups) do count = count + 1 end
    s.hasSteamGroups = (CONTROL_CONFIG.steamGroups ~= nil and #CONTROL_CONFIG.steamGroups > 0 and count > 1)
end

local function clamp01(value)
    if value <= 0 then return 0 end
    if value >= 1 then return 1 end
    return value
end

-- Steam-tank relief only: when the tank exceeds bufferMax, insert rods (no casing coupling).
---@param s OverallStats
function updateSteamCoordination(s)
    local groups = s.steamGroups or {}
    if CONTROL_CONFIG.steamCoordination == false then
        for _, g in pairs(groups) do g.pressureRelief = 0 end
        return
    end

    local bufferMax = CONTROL_CONFIG.bufferMax or 70
    for _, g in pairs(groups) do
        local steamPct = (g.steamCapacity > 0) and (g.storedSteam / g.steamCapacity * 100) or 0
        g.steamBufferPct = steamPct
        if steamPct > bufferMax and bufferMax < 100 then
            g.pressureRelief = clamp01((steamPct - bufferMax) / (100 - bufferMax))
        else
            g.pressureRelief = 0
        end
    end
end

-- Efficiency merit-order dispatch (feature: "crank the efficient reactors first").
-- Max output a reactor can make (curve peak, ~rod 0) and its output at the best-efficiency point.
local function reactorMaxOut(reactor)
    local m = 0
    for _, point in pairs(reactor.curve) do
        if point.out and point.out > m then m = point.out end
    end
    return m
end
local function reactorSweetOut(reactor)
    local point = reactor.curve[reactor.bestEffLevel]
    return point and point.out or 0
end

-- Allocate `demand` across a pool of same-mode reactors, most fuel-efficient first, writing each
-- reactor's assigned generation target into `targets[id]`. Two passes: (1) load reactors at their
-- best-efficiency output in merit order until demand is met (extras stay idle); (2) if demand
-- still isn't met, ramp the already-loaded reactors past their sweet spot toward max output, again
-- most-efficient first. Does nothing (falls back to the even split) unless EVERY reactor in the
-- pool is calibrated, so behavior is predictable.
local function assignMeritOrder(pool, demand, targets)
    if #pool == 0 then return end
    for _, r in ipairs(pool) do
        if not r.curve or r.bestEff == nil or r.bestEffLevel == nil or not r.curve[r.bestEffLevel] then
            return
        end
    end
    table.sort(pool, function(a, b) return (a.bestEff or 0) > (b.bestEff or 0) end)

    local remaining = math.max(0, demand or 0)
    for _, r in ipairs(pool) do
        local give = math.min(remaining, reactorSweetOut(r))
        r._dispatch = give
        remaining = remaining - give
    end
    if remaining > 0 then
        for _, r in ipairs(pool) do
            local headroom = math.max(0, reactorMaxOut(r) - r._dispatch)
            local extra = math.min(remaining, headroom)
            r._dispatch = r._dispatch + extra
            remaining = remaining - extra
            if remaining <= 0 then break end
        end
    end
    for _, r in ipairs(pool) do
        targets[r.id] = r._dispatch
        r._dispatch = nil
    end
end

-- Build per-reactor dispatch targets for efficiency mode: the passive reactors share the grid
-- drain, and each steam group's active reactors share that group's steam draw. Left nil in output
-- mode (reactors fall back to the even per-reactor split in reactor:updateRods).
---@param s OverallStats
function computeDispatch(s)
    s.dispatchTargets = nil
    if CONTROL_CONFIG.optimizeMode ~= "efficiency" then return end

    local targets = {}

    local passives = {}
    local groups = {}
    for _, reactor in pairs(_G.reactors) do
        if reactor.activelyCooled then
            local gid = reactor.groupId or "default"
            groups[gid] = groups[gid] or {}
            table.insert(groups[gid], reactor)
        else
            passives[#passives + 1] = reactor
        end
    end

    assignMeritOrder(passives, s.rfLost, targets)
    for gid, pool in pairs(groups) do
        local gstats = s.steamGroups[gid]
        local demand = gstats and gstats.consumption or s.steamConsumedLastTick
        assignMeritOrder(pool, demand, targets)
    end

    if next(targets) then s.dispatchTargets = targets end
end

-- Keep the legacy globals the monitor/PID code reads in sync with the config band.
local function syncConfigGlobals()
    _G.SECONDS_TO_AVERAGE = CONTROL_CONFIG.secondsToAverage or 0.5
    _G.minb = CONTROL_CONFIG.bufferMin
    _G.maxb = CONTROL_CONFIG.bufferMax
end

-- Effective setting for one entity: per-entity override if present, else the global value.
-- See entityOverrides in projectConfigs.lua for which keys each entity kind honors.
---@param entityID string peripheral id
---@param key string CONTROL_CONFIG key
function _G.getEntitySetting(entityID, key)
    local overrides = CONTROL_CONFIG.entityOverrides
    local entity = overrides and overrides[entityID]
    if entity and entity[key] ~= nil then
        return entity[key]
    end
    return CONTROL_CONFIG[key]
end

-- rpmMin must stay below rpmMax so the band controller has room to steer.
local IDLE_RPM_MARGIN = 100
local IDLE_RPM_FLOOR = 100
function _G.clampIdleRPM(rpm)
    local rpmMax = CONTROL_CONFIG.rpmMax or CONTROL_CONFIG.ceilingRPM or 2000
    return math.max(IDLE_RPM_FLOOR, math.min(rpm, rpmMax - IDLE_RPM_MARGIN))
end

function _G.toggleFlywheel()
    CONTROL_CONFIG.flywheelMode = not CONTROL_CONFIG.flywheelMode
    ConfigUtil.writeConfig("control")
end

-- UI adjusters (monitor settings row). Each validates, persists, and re-syncs globals.

function _G.adjustIdleRPM(delta)
    local newMin = _G.clampIdleRPM((CONTROL_CONFIG.rpmMin or CONTROL_CONFIG.idleRPM) + delta)
    CONTROL_CONFIG.rpmMin = newMin
    CONTROL_CONFIG.idleRPM = newMin
    ConfigUtil.writeConfig("control")
end

-- Widen (+delta) or narrow (-delta) a [min,max] band symmetrically, keeping it sane.
local function adjustBand(minKey, maxKey, delta)
    local newMin = math.max(0, math.min(CONTROL_CONFIG[minKey] - delta, 100))
    local newMax = math.max(0, math.min(CONTROL_CONFIG[maxKey] + delta, 100))
    if newMax - newMin < 10 then -- too tight -> control law flaps; refuse
        return
    end
    CONTROL_CONFIG[minKey] = newMin
    CONTROL_CONFIG[maxKey] = newMax
    syncConfigGlobals()
    ConfigUtil.writeConfig("control")
end

function _G.adjustBufferBand(delta) adjustBand("bufferMin", "bufferMax", delta) end
function _G.adjustCoilBand(delta) adjustBand("coilsOnBelowPct", "coilsOffAbovePct", delta) end

-- Steering interval (server-lag throttle), 1..20 ticks. Governor is unaffected.
function _G.adjustControlInterval(delta)
    local current = CONTROL_CONFIG.controlIntervalTicks or 1
    CONTROL_CONFIG.controlIntervalTicks = math.max(1, math.min(20, current + delta))
    ConfigUtil.writeConfig("control")
end

---@param monitorID string
local function connectMonitor(monitorID, suppliedPeripheral)
    print("Monitor " .. monitorID .. " connected!")
    _G.monitors[monitorID] = Monitor.new(monitorID, suppliedPeripheral)
end

---@param reactorID string
local function connectExtremeReactor(reactorID)
    local ok, missing = CapabilityValidator.validate(reactorID, "reactor")
    if not ok then
        print("Rejected reactor " .. reactorID .. ": " .. table.concat(missing, ", "))
        return
    end
    print("Extreme Reactor " .. reactorID .. " connected!")
    _G.reactors[reactorID] = Reactor.newExtremeReactor(reactorID)
    pcall(_G.reactors[reactorID].setRodLevels, 100)
    pcall(_G.reactors[reactorID].setActive, false)
    _G.reactors[reactorID].active = false
    _G.selectedReactor = _G.reactors[reactorID]
    unavailableDevices[reactorID] = nil
    topologyRevision = topologyRevision + 1
end

---@param turbineID string
local function connectExtremeTurbine(turbineID)
    local ok, missing = CapabilityValidator.validate(turbineID, "turbine")
    if not ok then
        print("Rejected turbine " .. turbineID .. ": " .. table.concat(missing, ", "))
        return
    end
    print("Extreme Turbine " .. turbineID .. " connected!")
    _G.turbines[turbineID] = Turbine.newExtremeTurbine(turbineID)
    unavailableDevices[turbineID] = nil
    topologyRevision = topologyRevision + 1
end

---@param energyBufferID string
local function connectForgeEnergyBuffer(energyBufferID)
    print("Energy Buffer " .. energyBufferID .. " connected!")
    _G.energyBuffers[energyBufferID] = EnergyBuffer.newForgeEnergyBuffer(energyBufferID)
    unavailableDevices[energyBufferID] = nil
    topologyRevision = topologyRevision + 1
end

local function firePeripheralAttachEventForAllPeripherals()
    for _, id in pairs(peripheral.getNames()) do
        os.queueEvent("peripheral", id)
    end
end

---@param currentTickNumber number
local function updateEnergyBuffers(currentTickNumber)
    for _, energyBuffer in pairs(_G.energyBuffers) do
        energyBuffer:update(currentTickNumber)
    end
end

---@param currentTickNumber number
local function updateReactors(currentTickNumber)
    for _, reactor in pairs(_G.reactors) do
        reactor:update(currentTickNumber)
    end
end

---@param currentTickNumber number
local function updateTurbines(currentTickNumber)
    for _, turbine in pairs(_G.turbines) do
        turbine:update(currentTickNumber)
    end
end

function _G.setReactors(active)
    if active then
        return SafetyManager.requestMode(CONTROL_CONFIG.optimizeMode == "efficiency"
            and "AUTO_EFFICIENCY" or "AUTO_OUTPUT", "operator")
    end
    return SafetyManager.requestMode("OFF", "operator")
end

function _G.setTurbines(active)
    if active and not SafetyManager.isRunning() then return false, "controller is not running" end
    if not active and SafetyManager.isRunning() then
        return SafetyManager.requestMode("OFF", "operator-turbine-stop")
    end
    _G.turbinesOn = active
    for _, turbine in pairs(_G.turbines) do
        turbine:setActive(active)
    end
end

function _G.toggleAutoMode()
    if SafetyManager.isRunning() then return SafetyManager.requestMode("OFF", "operator") end
    return SafetyManager.requestMode(CONTROL_CONFIG.optimizeMode == "efficiency"
        and "AUTO_EFFICIENCY" or "AUTO_OUTPUT", "operator")
end

local function markUnavailable(id, err)
    if unavailableDevices[id] then return end
    unavailableDevices[id] = true
    topologyRevision = topologyRevision + 1
    if AlarmManager then
        AlarmManager.raise("device_write_" .. id, "warning", "device write failed: " .. tostring(err), id)
    end
end

local function protectedCall(id, callback)
    local ok, result, err = xpcall(callback, function(message) return tostring(message) end)
    if not ok then markUnavailable(id, result); return false end
    if result == false then markUnavailable(id, err); return false end
    return true
end

local function controlContext()
    local storage = _G.overallStats.storage or {}
    return {
        steady=true, topologyChanged=storage.delta == 0 and storageCoordinator and storageCoordinator.topologyRevision == topologyRevision,
        storageFull=(storage.fillPct or 0) >= 99.9,
        transient=false, scram=SafetyManager and SafetyManager.state() == "SCRAM",
    }
end

local function updateReactorRods(dispatch, context)
    for _, id in ipairs(sortedIDs(_G.reactors)) do
        local reactor = _G.reactors[id]
        -- A reactor mid-calibration owns its own rods (stepCalibration); skip normal steering.
        if not reactor.calibration and not unavailableDevices[id] then
            local target = dispatch and dispatch.reactors[id]
            local healthy = protectedCall(id, function() return reactor:updateRods(target) end)
            if healthy and reactor.observeCapacity and target then
                reactor:observeCapacity(target.target, context, CONTROL_CONFIG)
            end
        end
    end
end

-- Advance any in-progress efficiency calibrations. Runs every tick (independent of the steering
-- interval) so each rod step is held for a real, consistent number of ticks.
local function stepCalibrations()
    for _, reactor in pairs(_G.reactors) do
        if reactor.calibration then
            reactor:stepCalibration()
        end
    end
end

-- Toggle output vs. efficiency optimize mode (feature 6).
function _G.toggleOptimizeMode()
    CONTROL_CONFIG.optimizeMode = (CONTROL_CONFIG.optimizeMode == "efficiency") and "output" or "efficiency"
    if SafetyManager.isRunning() then
        CONTROL_CONFIG.operatingMode = CONTROL_CONFIG.optimizeMode == "efficiency"
            and "AUTO_EFFICIENCY" or "AUTO_OUTPUT"
    end
    ConfigUtil.writeConfig("control")
end

-- Start calibration on the first eligible reactor (one at a time, so the sweep never blacks out
-- the whole grid). Returns ok, reason.
function _G.startCalibration()
    if not SafetyManager.isRunning() then return false, "controller must be running" end
    for _, reactor in pairs(_G.reactors) do
        if reactor.calibration then
            return false, "a reactor is already calibrating"
        end
    end
    for _, reactor in pairs(_G.reactors) do
        local ok = reactor:startCalibration()
        if ok then return true end
    end
    return false, "no reactor eligible (grid busy?)"
end

-- True while any reactor is mid-sweep (for the UI button state).
function _G.isCalibrating()
    for _, reactor in pairs(_G.reactors) do
        if reactor.calibration then return true end
    end
    return false
end

---@param steer boolean false = safety-governor-only pass (between steering intervals)
local function controlTurbines(steer, dispatch, context, probeID)
    for _, id in ipairs(sortedIDs(_G.turbines)) do
        local turbine = _G.turbines[id]
        if not unavailableDevices[id] then
            local target = dispatch and dispatch.turbines[id]
            -- Flywheel mode owns the throttle while it intentionally stores rotor energy.
            -- It must not be converted into a zero-target idle command before its overspeed
            -- governor and SCRAM path can run.
            local actuatorTarget = CONTROL_CONFIG.flywheelMode and nil or target
            local deviceContext = {}
            for key, value in pairs(context) do deviceContext[key] = value end
            -- Only one rotating turbine can perform overspeed capacity learning in a tick.
            deviceContext.probeAllowed = id == probeID
            -- Do not let a cold rotor mistake its spin-up RPM for a sustainable operating bin.
            -- Once the selected turbine has reached its normal configured band it may learn;
            -- all other turbines remain observationally inert this tick.
            local rpmMin = getEntitySetting(id, "rpmMin") or getEntitySetting(id, "idleRPM")
                or CONTROL_CONFIG.rpmMin or CONTROL_CONFIG.idleRPM or 1800
            if (turbine.bestSustainedRPM or 0) > 0 and turbine.bestSustainedRPM < rpmMin then
                turbine.bestSustainedRPM = 0
            end
            deviceContext.steady = deviceContext.probeAllowed and turbine.averageRPM >= rpmMin - 25
            local healthy = protectedCall(id, function()
                return turbine:updateControl(CONTROL_CONFIG, false, nil, deviceContext)
            end)
            -- The RPM/safety governor runs every tick. Only a scheduled steering pass may
            -- consume a dispatch target, so no later nil-target governor pass can overwrite it.
            if healthy and steer then
                healthy = protectedCall(id, function()
                    return turbine:updateControl(CONTROL_CONFIG, true, actuatorTarget, deviceContext)
                end)
            end
            if healthy and turbine.observeCapacity and actuatorTarget then
                turbine:observeCapacity(target.rfTarget, deviceContext, CONTROL_CONFIG)
            end
        end
    end
end

local function applyDispatch(steer)
    local s = _G.overallStats
    local dispatch, context = s.dispatch, controlContext()
    local ids = sortedIDs(_G.turbines)
    local probeID = nil
    if #ids > 0 then
        turbineProbeCursor = turbineProbeCursor % #ids + 1
        probeID = ids[turbineProbeCursor]
    end
    local unavailableBefore = 0
    for _ in pairs(unavailableDevices) do unavailableBefore = unavailableBefore + 1 end
    if steer then updateReactorRods(dispatch, context) end
    controlTurbines(steer, dispatch, context, probeID)

    -- A failed target must not starve healthy peers for a full tick.  Reallocate once with
    -- failed IDs excluded; do not retry the failed peripheral in this control pass.
    local unavailableAfter = 0
    for _ in pairs(unavailableDevices) do unavailableAfter = unavailableAfter + 1 end
    if s.dispatch and unavailableAfter > unavailableBefore then
        if storageCoordinator then
            s.storage = storageCoordinator:update({ sources=buildStorageSources(), actualGeneration=s.totalRFT,
                availableGeneration=s.dispatch.availableRF or 0, topologyRevision=topologyRevision }, CONTROL_CONFIG)
        end
        dispatch = publishDispatch(s.storage)
        context = controlContext()
        if steer then updateReactorRods(dispatch, context) end
        controlTurbines(steer, dispatch, context, probeID)
    end
end

---@param peripheralID string
local function handlePeripheralDetach(peripheralID)
    if _G.monitors[peripheralID] ~= nil then
        print("Monitor " .. peripheralID .. " disconnected!")
        _G.monitors[peripheralID] = nil
    end
    if _G.energyBuffers[peripheralID] ~= nil then
        _G.energyBuffers[peripheralID] = nil
        topologyRevision = topologyRevision + 1
    end
    if _G.reactors[peripheralID] ~= nil then
        print("Reactor " .. peripheralID .. " disconnected!")
        _G.reactors[peripheralID] = nil
        unavailableDevices[peripheralID] = nil
        topologyRevision = topologyRevision + 1
        if _G.selectedReactor and _G.selectedReactor.id == peripheralID then
            _G.selectedReactor = next(_G.reactors) and _G.reactors[next(_G.reactors)] or nil
        end
    end
    if _G.turbines[peripheralID] ~= nil then
        print("Turbine " .. peripheralID .. " disconnected!")
        _G.turbines[peripheralID] = nil
        unavailableDevices[peripheralID] = nil
        topologyRevision = topologyRevision + 1
        if SafetyManager and SafetyManager.isRunning() then
            SafetyManager.evaluate()
        end
    end
end

-- Extreme Reactors 2 (MC 1.20.1) reports these CC peripheral types.
local REACTOR_TYPES = {
    ["BigReactors-Reactor"] = true,
    ["extremereactor-reactorComputerPort"] = true,
}
local TURBINE_TYPES = {
    ["BigReactors-Turbine"] = true,
    ["extremereactor-turbineComputerPort"] = true,
}

---@param peripheralID string
---@param peripheralType string
local function handlePeripheralAttach(peripheralID, peripheralType)
    if peripheralType == "monitor" then
        connectMonitor(peripheralID)
    elseif REACTOR_TYPES[peripheralType] then
        connectExtremeReactor(peripheralID)
    elseif TURBINE_TYPES[peripheralType] then
        connectExtremeTurbine(peripheralID)
    elseif peripheralType == "energy_storage" then
        connectForgeEnergyBuffer(peripheralID)
    else
        print("Ignoring peripheral", peripheralID, "of type", peripheralType)
    end
end

local function redrawMonitors()
    for _, monitor in pairs(_G.monitors) do
        monitor:draw()
    end
end

_G.TICKS_TO_REDRAW = 2
local function runLoop(currentTickNumber)
    if RemoteDisplayServer then
        RemoteDisplayServer.update()
    end
    updateEnergyBuffers(currentTickNumber)
    updateReactors(currentTickNumber)
    updateTurbines(currentTickNumber)
    updateOverallStats()

    if not SafetyManager.evaluate() then
        if WatchdogHeartbeat then WatchdogHeartbeat.update() end
        if HistoryManager then HistoryManager.sample() end
        if TelemetryExporter then TelemetryExporter.update() end
        if currentTickNumber % _G.TICKS_TO_REDRAW == 0 then redrawMonitors() end
        return
    end

    if CONTROL_CONFIG.autoMode and SafetyManager.isRunning() then
        -- Calibration sweeps step every tick (own timing), independent of the steering throttle.
        stepCalibrations()

        -- Responsiveness throttle: steering runs every controlIntervalTicks; the turbine
        -- safety governor still runs every tick (inside updateControl, before steering).
        local interval = math.max(1, math.floor(CONTROL_CONFIG.controlIntervalTicks or 1))
        local steer = (currentTickNumber % interval == 0)
        applyDispatch(steer)
    end

    if HistoryManager then HistoryManager.sample() end
    if WatchdogHeartbeat then WatchdogHeartbeat.update() end
    if TelemetryExporter then TelemetryExporter.update() end

    if currentTickNumber % _G.TICKS_TO_REDRAW == 0 then
        redrawMonitors()
    end
end

local function eventListener()
    while true do
        local event = { os.pullEvent() }

        if event[1] == "monitor_touch" or event[1] == "monitor_resize" then
            local monitor = _G.monitors[event[2]]
            if monitor ~= nil then
                monitor:handleEvents(event)
            end
        elseif event[1] == "peripheral" then
            handlePeripheralAttach(event[2], peripheral.getType(event[2]))
        elseif event[1] == "peripheral_detach" then
            handlePeripheralDetach(event[2])
        elseif event[1] == "rednet_message" and RemoteDisplayServer then
            RemoteDisplayServer.handleMessage(event[2], event[3], event[4])
        end
    end
end

-- Game-tick-synchronized driver (inherited from upstream, subtle but effective):
-- os.clock() advances in 0.05s steps, so floor(os.clock()*20) is the current game tick.
-- queueEvent+pullEvent of a dummy event is a zero-sleep yield - it spins the coroutine
-- without losing the rest of the current tick (os.sleep would always round up to a tick).
--   * same tick as last run  -> yield and re-check
--   * exactly one tick later -> busy-yield ~2ms into the fresh tick (so peripherals have
--     settled), then run the control pass
--   * more than one tick     -> we lagged; run immediately and note the miss
local function loop()
    local loopEventName = "yield"
    local curTime = math.floor(os.clock() * 20)
    local lastTime = curTime

    os.sleep(0)
    while true do
        curTime = math.floor(os.clock() * 20)

        local hasDevices = next(_G.reactors) ~= nil or next(_G.turbines) ~= nil
        if not hasDevices then
            print("No reactor or turbine detected! Waiting for a connection...")
            sleep(1)
        elseif curTime < lastTime + 1 then
            os.queueEvent(loopEventName)
            os.pullEvent(loopEventName)
        elseif curTime > lastTime + 1 then
            print("Missed last", curTime - lastTime - 1, "tick(s)!", curTime)
            local ok, err = xpcall(function() runLoop(curTime) end, debug.traceback)
            if not ok then SafetyManager.scram("control loop exception: " .. tostring(err), "runtime") end
        else
            local t = os.epoch("utc")
            while os.epoch("utc") - t < 2 do
                os.queueEvent(loopEventName)
                os.pullEvent(loopEventName)
            end
            local ok, err = xpcall(function() runLoop(curTime) end, debug.traceback)
            if not ok then SafetyManager.scram("control loop exception: " .. tostring(err), "runtime") end
            os.sleep(0)
        end
        lastTime = curTime
    end
end

-- Exposed for the headless simulator in test/ (harmless in-game).
_G.__test = {
    runLoop = runLoop,
    updateOverallStats = updateOverallStats,
    applyDispatch = applyDispatch,
    handlePeripheralAttach = handlePeripheralAttach,
    handlePeripheralDetach = handlePeripheralDetach,
    syncConfigGlobals = syncConfigGlobals,
    assignMeritOrder = assignMeritOrder,
    computeDispatch = computeDispatch,
}

--Entry point
function _G.main()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)

    syncConfigGlobals()

    _G.monitors = {}
    _G.reactors = {}
    _G.turbines = {}
    _G.energyBuffers = {}
    _G.btnOn = false
    _G.turbinesOn = false
    unavailableDevices = {}
    topologyRevision = 0
    turbineProbeCursor = 0
    storageCoordinator = StorageCoordinator and StorageCoordinator.new() or nil
    _G.overallStats.topologyRevision = topologyRevision

    if RemoteDisplayServer then
        RemoteDisplayServer.start({
            attach = function(id, remotePeripheral)
                connectMonitor(id, remotePeripheral)
            end,
            resize = function(id)
                local monitor = _G.monitors[id]
                if monitor then monitor:handleResize() end
            end,
            detach = function(id)
                if _G.monitors[id] then
                    print("Remote monitor " .. id .. " disconnected!")
                    _G.monitors[id] = nil
                end
            end,
            touch = function(id, x, y)
                local monitor = _G.monitors[id]
                if monitor then
                    monitor:handleEvents({ "monitor_touch", id, x, y })
                end
            end,
        })
    end

    -- Manually fire "peripheral" for everything already connected so registries populate.
    firePeripheralAttachEventForAllPeripherals()

    -- Let queued attach events populate before the first guarded control pass. SafetyManager
    -- remains fail-closed and will transition to READY only after capability/count checks pass.
    if HistoryManager then HistoryManager.restore() end

    parallel.waitForAll(loop, eventListener)
end
