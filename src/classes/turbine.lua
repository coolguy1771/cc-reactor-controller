-- Turbine class (Extreme Reactors 2 "BigReactors-Turbine" peripheral, MC 1.20.1 Modernized API).
--
-- Control model (see README):
--   * Steam throttle (setFluidFlowRateMax) is a PI controller holding RPM inside [rpmMin, rpmMax].
--   * Coils (setInductorEngaged) are the power tap: engaged = generate + brake, disengaged = freewheel.
--     Driven by this turbine's OWN internal RF buffer % with hysteresis.
--   * A safety governor overrides both above safeRPM/ceilingRPM so RPM can never cross rpmMax.

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function entityRpmMin(config, turbineId)
    local o = config.entityOverrides and config.entityOverrides[turbineId]
    if o and o.rpmMin ~= nil then return o.rpmMin end
    if o and o.idleRPM ~= nil then return o.idleRPM end
    return config.rpmMin or config.idleRPM or 1800
end

local function entityRpmMax(config, turbineId)
    local o = config.entityOverrides and config.entityOverrides[turbineId]
    if o and o.rpmMax ~= nil then return o.rpmMax end
    return config.rpmMax or config.ceilingRPM or 2000
end

local function rpmLimits(config, turbineId)
    local rpmMin = entityRpmMin(config, turbineId)
    local rpmMax = entityRpmMax(config, turbineId)
    if rpmMax < rpmMin then rpmMax = rpmMin end
    return rpmMin, rpmMax
end
local DEFAULT_SUSTAINED_LIMIT = 2400

local function finiteLimit(value, fallback)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then value = fallback end
    return value
end

-- PI error: below band -> push up to rpmMin; above band -> pull down; inside -> hold midpoint.
local function rpmBandError(avgRpm, rpmMin, rpmMax)
    if avgRpm < rpmMin then
        return rpmMin - avgRpm
    end
    if avgRpm > rpmMax then
        return rpmMax - avgRpm
    end
    return (rpmMin + rpmMax) / 2 - avgRpm
end

---@class Turbine
---@field id string
---@field active boolean
---@field rpm number
---@field averageRPM number
---@field energyProduced number       RF/t produced last tick
---@field averageEnergyProduced number
---@field energyStored number
---@field energyCapacity number
---@field steamFlow number            actual mB/t steam consumed last tick
---@field averageSteamFlow number
---@field steamCap number             current setFluidFlowRateMax setting
---@field flowMaxMax number           hard per-turbine cap ceiling
---@field coilsEngaged boolean
---@field desiredCoils boolean
---@field bladeEfficiency number
---@field lastUpdatedTick number
local Turbine = {

    lastUpdatedTick = 0,

    ---@param self Turbine
    bufferPct = function(self)
        if self.energyCapacity <= 0 then
            return 100
        end
        return self.energyStored / self.energyCapacity * 100
    end,

    ---@param self Turbine
    updateAverages = function(self)
        self.rpmValues:pushleft(self.rpm)
        self.energyProducedValues:pushleft(self.energyProduced)
        self.steamFlowValues:pushleft(self.steamFlow)

        local ticksToAverage = 20 * _G.SECONDS_TO_AVERAGE
        while self.rpmValues.size > ticksToAverage do
            self.rpmValues:popright()
            self.energyProducedValues:popright()
            self.steamFlowValues:popright()
        end

        self.averageRPM = self.rpmValues:average()
        self.averageEnergyProduced = self.energyProducedValues:average()
        self.averageSteamFlow = self.steamFlowValues:average()
        return true
    end,

    ---@param self Turbine
    ---@param currentTickNumber number
    update = function(self, currentTickNumber)
        if self.lastUpdatedTick >= currentTickNumber then
            return
        end

        self.active = self.getActive()
        self.rpm = self.getRotorSpeed()
        self.energyProduced = self.getEnergyProduced()
        self.energyStored = self.getEnergyStored()
        self.energyCapacity = self.getEnergyCapacity()
        self.steamFlow = self.getFluidFlowRate()
        self.coilsEngaged = self.getInductorEngaged()
        self.bladeEfficiency = self.getBladeEfficiency()

        self:updateAverages()
        self.lastUpdatedTick = currentTickNumber
    end,

    observeCapacity = function(self, target, context, config)
        local o = getEntitySetting(self.id, "maxRFPerTick")
        if o then self.capacityRF, self.capacityKnown = o, true; return {value=o, known=true} end
        if getEntitySetting(self.id, "capacityLearning") == false then return {value=self.capacityRF, known=self.capacityKnown} end
        context = context or {}
        local blocked = context.topologyChanged or context.calibration or context.scram or context.governorBraking or context.startupGrace or context.storageFull or context.flywheelDeceleration
        local result = Dispatcher.learnCapacity({value=self.capacityRF or 1, known=self.capacityKnown == true, misses=self.capacityMisses or 0}, {actual=self.energyProduced, target=target, steady=self.coilsEngaged and context.steady == true and not blocked, transient=context.transient}, config)
        self.capacityRF, self.capacityKnown = math.max(1, result.value), result.known
        self.capacityMisses = result.misses
        if self.coilsEngaged and self.steamFlow > 0 and context.steady and not blocked and not context.transient then self.rfPerSteam = self.energyProduced / self.steamFlow end
        return result
    end,

    -- Peripheral-write helpers: only hit the peripheral when the value actually changes,
    -- to keep 20Hz control from spamming the server with method calls.

    ---@param self Turbine
    ---@param amount number desired steam-flow cap (mB/t)
    writeSteam = function(self, amount)
        amount = math.floor(clamp(amount, 0, self.flowMaxMax) + 0.5)
        local forceEdge = (amount == 0 or amount == self.flowMaxMax)
        if forceEdge or math.abs(amount - self.lastWrittenSteamCap) >= self.steamWriteThreshold then
            local ok, err = pcall(self.setFluidFlowRateMax, amount)
            if not ok then self.controlStatus = "WRITE_FAILED"; return false, err end
            self.lastWrittenSteamCap = amount
            self.steamCap = amount
        end
        return true
    end,

    ---@param self Turbine
    ---@param engaged boolean
    writeCoils = function(self, engaged)
        if engaged ~= self.lastWrittenCoils then
            local ok, err = pcall(self.setInductorEngaged, engaged)
            if not ok then self.controlStatus = "WRITE_FAILED"; return false, err end
            self.lastWrittenCoils = engaged
            self.coilsEngaged = engaged
        end
        return true
    end,

    ---@param self Turbine
    setActive = function(self, state)
        self.setActivePeripheral(state)
        self.active = state
    end,

    -- The three-step control law. Called once per tick in auto mode.
    -- steer == false runs ONLY the safety governor (used between controlIntervalTicks
    -- steering passes, so the responsiveness throttle can never slow the governor down).
    ---@param self Turbine
    ---@param config table CONTROL_CONFIG
    ---@param steer boolean|nil nil/true = full pass, false = governor only
    updateControl = function(self, config, steer, target, context)
        if not self.active then
            return
        end

        self.steamWriteThreshold = config.steamWriteThreshold or 5

        local hasDispatchTarget = target ~= nil
        target, context = target or {}, context or {}
        local rpm = self.rpm                 -- instantaneous for safety
        local avgRpm = self.averageRPM       -- smoothed for the PI

        -- Flywheel mode (feature 5): while armed AND this turbine is idle (coils not demanded),
        -- the governor ceiling is raised so the rotor can store energy at high RPM. With
        -- flywheelCeilingRPM == 0 (default) the ceiling is lifted ENTIRELY - the rotor spins as
        -- high as it physically can. The instant power is needed (coils demanded) the normal
        -- 2000 ceiling snaps back and the governor brakes the overspeed off into the grid.
        -- self.desiredCoils is the persisted demand decision (valid on governor-only ticks too).
        -- DANGER: high/uncapped RPM can explode turbines in-game.
        local flywheelArmedIdle = (config.flywheelMode == true) and (self.desiredCoils == false)
        local rpmMin, rpmMax = rpmLimits(config, self.id)
        local override = config.entityOverrides and config.entityOverrides[self.id]
        local absoluteLimit = finiteLimit(override and override.sustainedOverspeedLimitRPM,
            finiteLimit(target.rpmLimit, finiteLimit(config.sustainedOverspeedLimitRPM, DEFAULT_SUSTAINED_LIMIT)))
        if absoluteLimit < rpmMin then absoluteLimit = rpmMin end
        local ceiling = config.rpmMax or config.ceilingRPM or rpmMax
        local safe = config.safeRPM or math.max(rpmMin, ceiling - 10)
        if flywheelArmedIdle then
            local cap = config.flywheelCeilingRPM or 0
            if cap > 0 then
                ceiling = cap
                safe = cap - (config.ceilingRPM - config.safeRPM)
            else
                ceiling = math.huge      -- uncapped: no governor limit while armed+idle
                safe = math.huge
            end
        end

        if rpm >= absoluteLimit then
            local ok, err = self:writeSteam(0); if not ok then return false, err end
            ok, err = self:writeCoils(true); if not ok then return false, err end
            self.pid.integral = 0
            self.controlStatus = "governor"
            return
        end

        -- 1) SAFETY GOVERNOR -- highest priority, ignores the PI. Runs on every tick.
        if rpm >= ceiling then
            local ok, err = self:writeSteam(0); if not ok then return false, err end
            ok, err = self:writeCoils(true); if not ok then return false, err end
            self.pid.integral = 0            -- so we don't slam back to full steam
            return
        elseif rpm >= safe then
            local ok, err = self:writeCoils(true); if not ok then return false, err end
            local capped = math.min(self.steamCap, self.flowMaxMax * 0.25)
            ok, err = self:writeSteam(capped); if not ok then return false, err end
            self.pid.integral = math.min(self.pid.integral, capped)
            return
        end

        if steer == false then
            return
        end

        if hasDispatchTarget then
        self.dispatchTarget = target
        if (target.rfTarget or 0) <= 0 then
            self.desiredCoils = false
            local ok, err = self:writeCoils(false); if not ok then return false, err end
            self.pid.integral = 0
            ok, err = self:writeSteam(0); if not ok then return false, err end
            self.controlStatus = context.storageFull and "storage-full" or "idle"
            return
        end
        self.desiredCoils = true
        local ok, err = self:writeCoils(true); if not ok then return false, err end
        local maxDispatchFlow = clamp(finiteLimit(target.maxFlow, self.flowMaxMax), 0, self.flowMaxMax)
        local desiredFlow = clamp(target.flowTarget or 0, 0, maxDispatchFlow)
        local storageBelowTarget = self.energyCapacity <= 0 or self.energyStored < self.energyCapacity * 0.9
        local probeEligible = context.probeAllowed and not self.probeStopped and storageBelowTarget and desiredFlow >= self.flowMaxMax and config.sustainedOverspeedEnabled ~= false and context.steady and not context.transient and not context.governorBraking and not context.flywheelDeceleration and not context.storageFull
        if probeEligible and not self.probeBin then
            self.probeBin = math.min((self.bestSustainedRPM > 0 and self.bestSustainedRPM or rpmMin) + 100, absoluteLimit - 10)
        end
        local targetRPM = math.min(self.probeBin or (self.bestSustainedRPM > 0 and self.bestSustainedRPM or rpmMin), absoluteLimit - 10)
        local dispatchErr = rpmBandError(avgRpm, targetRPM, targetRPM)
        self.pid.integral = clamp(self.pid.integral + (config.turbineKi or 0) * dispatchErr, 0, maxDispatchFlow)
        ok, err = self:writeSteam(clamp(desiredFlow + (config.turbineKp or 0) * dispatchErr, 0, maxDispatchFlow)); if not ok then return false, err end
        self.controlStatus = "dispatch"
        local saturated = desiredFlow >= maxDispatchFlow
        if probeEligible then
            self.probeBin = self.probeBin or math.min((self.bestSustainedRPM > 0 and self.bestSustainedRPM or rpmMin) + 100, absoluteLimit - 10)
            self.probeSettledBins = self.probeSettledBins or {}
            self.probeSettledFailures = self.probeSettledFailures or 0
            if self.probeBin >= absoluteLimit then self.controlStatus = "probe-limit" end
        end
        if context.steady and (not self.probeBin or math.abs((avgRpm or 0) - self.probeBin) <= 25) and not context.transient and not context.governorBraking and
            not context.flywheelDeceleration and not context.storageFull and self.coilsEngaged then
            local bin = math.floor((avgRpm or 0) / 100) * 100
            self.rpmBinObservations = self.rpmBinObservations or {}
            local b = self.rpmBinObservations[bin] or {samples=0, rf=0}
            b.samples = math.min((b.samples or 0) + 1, 20)
            b.rf = ((b.rf or 0) * (b.samples - 1) + (self.energyProduced or 0)) / b.samples
            self.rpmBinObservations[bin] = b
            if (self.bestSustainedRPM or 0) == 0 or b.rf > (self.bestContinuousRF or 0) then
                self.bestContinuousRF, self.bestSustainedRPM = b.rf, bin
                self.probeSettledFailures = 0
            elseif (self.probeBin or 0) > 0 and not self.probeSettledBins[bin] then
                self.probeSettledBins[bin] = true
                self.probeSettledFailures = (self.probeSettledFailures or 0) + 1
                if self.probeSettledFailures >= 2 then self.probeStopped = true; self.probeBin = nil else self.probeBin = math.min(self.probeBin + 100, absoluteLimit) end
            end
        end
        return
        end

        -- Per-turbine overrides (entityOverrides).
        local coilsOnBelow = getEntitySetting(self.id, "coilsOnBelowPct")
        local coilsOffAbove = getEntitySetting(self.id, "coilsOffAbovePct")

        -- 2) COIL DEMAND -- buffer hysteresis, but keep coils on in the upper RPM band so a
        --     full buffer does not freewheel while RPM still has room below rpmMax.
        local bufPct = self:bufferPct()
        local wiggle = getEntitySetting(self.id, "coilsRpmHeadroom")
            or config.coilsRpmHeadroom or 100
        local upperBand = avgRpm > rpmMin + wiggle

        if bufPct <= coilsOnBelow then
            self.desiredCoils = true
        elseif upperBand then
            self.desiredCoils = true
        elseif bufPct >= coilsOffAbove then
            self.desiredCoils = false
        end
        local ok, err = self:writeCoils(self.desiredCoils); if not ok then return false, err end

        -- 3a) FLYWHEEL SPIN-UP -- armed + idle: open the throttle fully and let the rotor climb
        --     as high as it can (up to flywheelCeilingRPM if a cap is set; the governor above
        --     enforces it). Priming the integral to full steam makes the hand-back to the normal
        --     PI (when coils engage) start from the right place.
        if config.flywheelMode == true and self.desiredCoils == false then
            self.pid.integral = self.flowMaxMax
            ok, err = self:writeSteam(self.flowMaxMax); if not ok then return false, err end
            return
        end

        -- 3b) STEAM PI -- modulate flow cap to hold RPM inside [rpmMin, rpmMax].
        local err = rpmBandError(avgRpm, rpmMin, rpmMax)
        if math.abs(err) < (config.rpmDeadband or 0) then
            err = 0
        end
        self.pid.integral = clamp(self.pid.integral + config.turbineKi * err, 0, self.flowMaxMax)
        local output = clamp(self.pid.integral + config.turbineKp * err, 0, self.flowMaxMax)
        ok, err = self:writeSteam(output); if not ok then return false, err end
        return true
    end,
}

---@param id string
---@return Turbine
local function newExtremeTurbine(id)
    local p = peripheral.wrap(id)

    -- Feature-detect the two diagnostics the mod historically misspelled
    -- (getBladeEffiency / getBladeEfficiency). Load-bearing methods are stable-named.
    local bladeEff = p.getBladeEfficiency or p.getBladeEffiency or function() return 0 end

    local instance = {
        id = id,

        rpm = 0, averageRPM = 0,
        energyProduced = 0, averageEnergyProduced = 0,
        energyStored = 0, energyCapacity = 0,
        steamFlow = 0, averageSteamFlow = 0,
        steamCap = 0,
        coilsEngaged = false,
        desiredCoils = false,
        bladeEfficiency = 0,
        capacityRF = 1, capacityKnown = false, rfPerSteam = 0,
        bestSustainedRPM = 0, dispatchTarget = nil,

        lastWrittenSteamCap = -1,
        lastWrittenCoils = nil,
        steamWriteThreshold = 5,

        rpmValues = Deque.new(),
        energyProducedValues = Deque.new(),
        steamFlowValues = Deque.new(),

        pid = { integral = 0 },

        -- peripheral bindings
        getActive = p.getActive,
        getRotorSpeed = p.getRotorSpeed,
        getEnergyProduced = p.getEnergyProducedLastTick,
        getEnergyStored = p.getEnergyStored,
        getEnergyCapacity = p.getEnergyCapacity,
        getFluidFlowRate = p.getFluidFlowRate,
        getInductorEngaged = p.getInductorEngaged,
        getBladeEfficiency = bladeEff,
        setFluidFlowRateMax = p.setFluidFlowRateMax,
        setInductorEngaged = p.setInductorEngaged,
        setActivePeripheral = p.setActive,
    }

    -- Hard per-turbine steam ceiling, read from the peripheral (do NOT assume 2000).
    instance.flowMaxMax = p.getFluidFlowRateMaxMax()
    if not instance.flowMaxMax or instance.flowMaxMax <= 0 then
        instance.flowMaxMax = 2000
    end

    setmetatable(instance, { __index = Turbine })

    -- Fail closed. SafetyManager starts the turbine only after the full controller self-test.
    local initOk, initErr = pcall(instance.setFluidFlowRateMax, 0)
    if not initOk then instance.controlStatus, instance.controlError = "WRITE_FAILED", initErr end
    initOk, initErr = pcall(instance.setInductorEngaged, true)
    if not initOk then instance.controlStatus, instance.controlError = "WRITE_FAILED", initErr end
    initOk, initErr = pcall(instance.setActivePeripheral, false)
    if not initOk then instance.controlStatus, instance.controlError = "WRITE_FAILED", initErr end
    instance.active = false
    instance.lastWrittenSteamCap = 0
    instance.lastWrittenCoils = true

    instance.lastUpdatedTick = -1
    local currentTickNumber = math.floor(os.clock() * 20)
    instance:update(currentTickNumber)
    return instance
end

_G.Turbine = {
    newExtremeTurbine = newExtremeTurbine,
}
