-- Optional non-blocking-ish periodic JSON telemetry export. Disabled by default.

local last, lastError = -math.huge, nil

local function snapshot()
    local s = _G.overallStats or {}
    local payload = {
        timestamp = os.epoch("utc"), computerId = os.getComputerID and os.getComputerID() or 0,
        state = SafetyManager and SafetyManager.state() or "UNKNOWN",
        mode = CONTROL_CONFIG.operatingMode,
        alarms = AlarmManager and select(1, AlarmManager.summary()) or 0,
        grid = { stored = s.storedThisTick or 0, capacity = s.capacity or 0,
            generation = s.totalRFT or 0, drain = s.rfLost or 0 },
        steam = { production = s.steamProductionRate or 0, consumption = s.steamConsumedLastTick or 0,
            stored = s.storedSteam or 0, capacity = s.steamCapacity or 0 },
        reactors = {}, turbines = {},
    }
    for id, r in pairs(_G.reactors or {}) do payload.reactors[id] = {
        active=r.active, rods=r.averageRodLevel, fuelTemperature=r.averageFuelTemp,
        casingTemperature=r.averageCaseTemp, output=r.averageLastRFT,
        steam=r.averageSteamProductionRate, fuelUsage=r.averageFuelUsage,
    } end
    for id, t in pairs(_G.turbines or {}) do payload.turbines[id] = {
        active=t.active, rpm=t.rpm, coils=t.coilsEngaged, output=t.averageEnergyProduced,
        steam=t.averageSteamFlow, bufferPct=t:bufferPct(),
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
