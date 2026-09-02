-- Optional non-blocking-ish periodic JSON telemetry export. Disabled by default.

local last, lastError = -math.huge, nil

local function configured(id, key)
    local value = getEntitySetting and getEntitySetting(id, key) or nil
    return type(value) == "number" and value > 0 and value == value and value < math.huge
end

local function deviceState(id, device, target, capacity, actual, capacityKey, degraded)
    local report = CapabilityValidator and CapabilityValidator.reports and CapabilityValidator.reports()[id]
    local mode = degraded[id] or (report and report.mode ~= "control" and report.mode) or false
    return {
        target=target or {}, capacity=capacity or 0,
        utilization=(capacity or 0) > 0 and (actual or 0) / capacity or 0,
        capacitySource=configured(id, capacityKey) and "configured"
            or (device.capacityKnown and "learned" or "observed"),
        controlStatus=device.controlStatus or "UNKNOWN", degraded=mode,
    }
end

local function snapshot()
    local s = _G.overallStats or {}
    local storage, dispatch = s.storage or {}, s.dispatch or {}
    local degraded = SafetyManager and SafetyManager.degradedDevices and SafetyManager.degradedDevices() or {}
    local payload = {
        timestamp = os.epoch("utc"), computerId = os.getComputerID and os.getComputerID() or 0,
        state = SafetyManager and SafetyManager.state() or "UNKNOWN",
        mode = CONTROL_CONFIG.operatingMode,
        alarms = AlarmManager and select(1, AlarmManager.summary()) or 0,
        grid = { stored = s.storedThisTick or 0, capacity = s.capacity or 0,
            generation = s.totalRFT or 0, drain = s.rfLost or 0 },
        steam = { production = s.steamProductionRate or 0, consumption = s.steamConsumedLastTick or 0,
            stored = s.storedSteam or 0, capacity = s.steamCapacity or 0 },
        storage = { stored=storage.stored or s.storedThisTick or 0, capacity=storage.capacity or s.capacity or 0,
            fillPct=storage.fillPct or 0, delta=storage.delta or 0, externalDemand=storage.externalDemand or 0,
            requiredGeneration=storage.requiredGeneration or 0, reserveFactor=storage.reserveFactor or 0,
            rechargeCorrection=storage.rechargeCorrection or 0, sourceIDs=storage.sourceIDs or {},
            trustworthy=storage.trustworthy ~= false },
        dispatch = { requiredRF=dispatch.requiredRF or storage.requiredGeneration or 0,
            availableRF=dispatch.availableRF or 0, saturation=dispatch.saturation or 0,
            topologyRevision=s.topologyRevision or 0 },
        reactors = {}, turbines = {},
    }
    for id, r in pairs(_G.reactors or {}) do
        local active = r.activelyCooled == true
        local actual = active and r.averageSteamProductionRate or r.averageLastRFT
        local capacity = active and r.capacitySteam or r.capacityRF
        local detail = deviceState(id, r, (s.reactorTargets or {})[id], capacity, actual,
            active and "maxSteamPerTick" or "maxRFPerTick", degraded)
        payload.reactors[id] = {
        active=r.active, rods=r.averageRodLevel, fuelTemperature=r.averageFuelTemp,
        casingTemperature=r.averageCaseTemp, output=r.averageLastRFT,
        steam=r.averageSteamProductionRate, fuelUsage=r.averageFuelUsage,
        target=detail.target, capacity=detail.capacity, utilization=detail.utilization,
        capacitySource=detail.capacitySource, controlStatus=detail.controlStatus, degraded=detail.degraded,
    } end
    for id, t in pairs(_G.turbines or {}) do
        local detail = deviceState(id, t, (s.turbineTargets or {})[id], t.capacityRF,
            t.averageEnergyProduced, "maxRFPerTick", degraded)
        payload.turbines[id] = {
        active=t.active, rpm=t.rpm, coils=t.coilsEngaged, output=t.averageEnergyProduced,
        steam=t.averageSteamFlow, bufferPct=t:bufferPct(),
        target=detail.target, capacity=detail.capacity, utilization=detail.utilization,
        capacitySource=detail.capacitySource, controlStatus=detail.controlStatus, degraded=detail.degraded,
    } end
    return payload
end

local function update()
    if not CONTROL_CONFIG.telemetryEnabled or CONTROL_CONFIG.telemetryUrl == "" or not http then return end
    local now = os.clock()
    if now - last < (CONTROL_CONFIG.telemetryIntervalSeconds or 5) then return end
    last = now
    local headers = { ["Content-Type"] = "application/json" }
    if CONTROL_CONFIG.telemetryAuthHeader ~= "" then headers.Authorization = CONTROL_CONFIG.telemetryAuthHeader end
    local response, err = http.post(CONTROL_CONFIG.telemetryUrl, textutils.serializeJSON(snapshot()), headers)
    if response then
        response.close(); lastError = nil
        if AlarmManager then AlarmManager.clear("telemetry", true) end
    elseif err ~= lastError then
        lastError = err
        if AlarmManager then AlarmManager.raise("telemetry", "advisory", "telemetry export failed: " .. tostring(err), "telemetry") end
    end
end

_G.TelemetryExporter = { update = update, snapshot = snapshot }
