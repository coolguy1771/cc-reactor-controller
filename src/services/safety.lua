-- Fail-closed operating state machine and latched SCRAM interlocks.

local state = "BOOTING"
local scramReason = nil
local initialized = false
local autoStartAttempted = false
local lastOperatorModeAt = -math.huge

local function journal(level, code, message, data)
    if EventJournal then EventJournal.record(level, code, message, data) end
end

local function forceSafe()
    for _, reactor in pairs(_G.reactors or {}) do
        pcall(reactor.setRodLevels, 100)
        pcall(reactor.setActive, false)
        reactor.active = false
    end
    for _, turbine in pairs(_G.turbines or {}) do
        pcall(function() turbine:writeSteam(CONTROL_CONFIG.scramTurbineSteam or 0) end)
        pcall(function() turbine:writeCoils(true) end)
    end
    _G.btnOn = false
end

local function selfTest()
    local failures = {}
    local reactorCount, turbineCount = 0, 0
    for _ in pairs(_G.reactors or {}) do reactorCount = reactorCount + 1 end
    for _ in pairs(_G.turbines or {}) do turbineCount = turbineCount + 1 end
    if reactorCount < (CONTROL_CONFIG.minimumReactors or 1) then failures[#failures + 1] = "not enough reactors" end
    if turbineCount < (CONTROL_CONFIG.minimumTurbines or 0) then failures[#failures + 1] = "not enough turbines" end
    for _, id in ipairs(CONTROL_CONFIG.expectedPeripherals or {}) do
        if not peripheral.isPresent or not peripheral.isPresent(id) then failures[#failures + 1] = "missing " .. id end
    end
    for id, report in pairs(CapabilityValidator and CapabilityValidator.reports() or {}) do
        if not report.ok then failures[#failures + 1] = "incompatible " .. id end
    end
    return #failures == 0, failures
end

local function desiredRunningMode()
    if CONTROL_CONFIG.optimizeMode == "efficiency" then
        return "AUTO_EFFICIENCY"
    end
    return "AUTO_OUTPUT"
end

local function requestMode(mode, source)
    local valid = { OFF=true, AUTO_OUTPUT=true, AUTO_EFFICIENCY=true, MANUAL=true, MAINTENANCE=true }
    if not valid[mode] then return false, "invalid mode" end
    if state == "SCRAM" then return false, "SCRAM must be reset" end
    local now = os.clock()
    local cooldown = CONTROL_CONFIG.remoteTouchCooldownSeconds or 1.0
    if source ~= "auto-start" and now - lastOperatorModeAt < cooldown then
        return false, "operator cooldown"
    end
    if mode ~= "OFF" then
        local ok, failures = selfTest()
        if not ok then return false, table.concat(failures, "; ") end
    end
    CONTROL_CONFIG.operatingMode = mode
    CONTROL_CONFIG.autoMode = mode == "AUTO_OUTPUT" or mode == "AUTO_EFFICIENCY"
    CONTROL_CONFIG.optimizeMode = mode == "AUTO_EFFICIENCY" and "efficiency" or "output"
    if mode == "OFF" then
        state = "READY"; forceSafe()
    elseif mode == "MAINTENANCE" then
        state = "MAINTENANCE"; forceSafe()
    else
        state = "RUNNING"
        _G.btnOn = true
        _G.turbinesOn = true
        for _, reactor in pairs(_G.reactors) do pcall(reactor.setActive, true); reactor.active = true end
        for _, turbine in pairs(_G.turbines) do pcall(function() turbine:setActive(true) end) end
    end
    if ConfigUtil then ConfigUtil.writeConfig("control") end
    journal("INFO", "mode", "mode changed to " .. mode, { source = source or "local" })
    return true
end

local function tryAutoStart()
    if autoStartAttempted or CONTROL_CONFIG.requireManualStart or state ~= "READY" then return end
    if CONTROL_CONFIG.autoMode == false then return end
    autoStartAttempted = true
    requestMode(desiredRunningMode(), "auto-start")
end

local function scram(reason, source)
    if state ~= "SCRAM" then
        scramReason = tostring(reason or "unspecified")
        state = "SCRAM"
        CONTROL_CONFIG.operatingMode = "SCRAM"
        if AlarmManager then AlarmManager.raise("scram", "critical", scramReason, source or "safety", true) end
        journal("CRITICAL", "scram", scramReason, { source = source })
    end
    forceSafe()
    return false, scramReason
end

local function initialize()
    state = "SELF_TEST"
    forceSafe()
    local ok, failures = selfTest()
    if ok then
        state = "READY"
        CONTROL_CONFIG.operatingMode = "OFF"
        journal("INFO", "self_test", "controller ready")
    else
        state = "DEGRADED"
        CONTROL_CONFIG.operatingMode = "OFF"
        local message = table.concat(failures, "; ")
        if AlarmManager then AlarmManager.raise("self_test", "critical", message, "safety", true) end
        journal("ERROR", "self_test", message)
    end
    initialized = true
    if ok then tryAutoStart() end
    return ok, failures
end

local function resetScram(source)
    if state ~= "SCRAM" then return false, "not in SCRAM" end
    local ok, failures = selfTest()
    if not ok then return false, table.concat(failures, "; ") end
    scramReason = nil
    if AlarmManager then AlarmManager.clear("scram", true) end
    state = "READY"; CONTROL_CONFIG.operatingMode = "OFF"; forceSafe()
    journal("INFO", "scram_reset", "SCRAM reset", { source = source })
    if not CONTROL_CONFIG.requireManualStart and CONTROL_CONFIG.autoMode ~= false then
        requestMode(desiredRunningMode(), "auto-start")
    end
    return true
end

local function finite(value) return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge end
local function evaluate()
    if not initialized then return initialize() end
    if state == "SCRAM" then forceSafe(); return false end

    local activeSteamReactors = 0
    for id, reactor in pairs(_G.reactors) do
        if not finite(reactor.averageFuelTemp) or not finite(reactor.averageCaseTemp) then
            return scram("invalid reactor sensor reading: " .. id, id)
        end
        if (CONTROL_CONFIG.maxFuelTemperature or 0) > 0 and reactor.averageFuelTemp >= CONTROL_CONFIG.maxFuelTemperature then
            return scram("fuel temperature high: " .. id, id)
        end
        if (CONTROL_CONFIG.maxCasingTemperature or 0) > 0 and reactor.averageCaseTemp >= CONTROL_CONFIG.maxCasingTemperature then
            return scram("casing temperature high: " .. id, id)
        end
        if reactor.activelyCooled and reactor.active then
            activeSteamReactors = activeSteamReactors + 1
            local pct = reactor.steamCapacity > 0 and reactor.averageStoredSteam / reactor.steamCapacity * 100 or 0
            if (CONTROL_CONFIG.maxSteamBufferPct or 0) > 0 and pct > CONTROL_CONFIG.maxSteamBufferPct then
                return scram("steam buffer critically high: " .. id, id)
            end
        end
    end
    local turbineCount, activeTurbineCount = 0, 0
    for id, turbine in pairs(_G.turbines) do
        turbineCount = turbineCount + 1
        if turbine.active then activeTurbineCount = activeTurbineCount + 1 end
        if not finite(turbine.rpm) then return scram("invalid turbine RPM: " .. id, id) end
        if turbine.rpm >= (CONTROL_CONFIG.overspeedScramRPM or 2000) then
            return scram("turbine overspeed: " .. id, id)
        end
    end
    if state == "RUNNING" and activeSteamReactors > 0 and activeTurbineCount == 0 then
        return scram("all turbines unavailable while steam reactor active", "peripheral")
    end
    return true
end

local function isRunning() return state == "RUNNING" end
_G.SafetyManager = {
    initialize=initialize, evaluate=evaluate, scram=scram, resetScram=resetScram,
    requestMode=requestMode, isRunning=isRunning,
    state=function() return state end, reason=function() return scramReason end,
    selfTest=selfTest, forceSafe=forceSafe,
}
