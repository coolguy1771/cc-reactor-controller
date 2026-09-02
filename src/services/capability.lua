-- Validate the ATM10/Extreme Reactors Modernized peripheral API before constructing
-- a controller object. Sampling is necessary to observe a device; every actuator is
-- necessary to make it safe. A partially controllable device is never dispatched.

local requirements = {
    reactor = {
        sampling = {
            "getActive", "isActivelyCooled", "getNumberOfControlRods", "getControlRodsLevels",
            "getEnergyStats", "getFuelStats", "getFuelTemperature", "getCasingTemperature",
            "getWasteAmount", "getHotFluidProducedLastTick", "getHotFluidAmount", "getHotFluidAmountMax",
        },
        actuation = { "setActive", "setControlRodsLevels" }, optional = {},
    },
    turbine = {
        sampling = {
            "getActive", "getRotorSpeed", "getEnergyProducedLastTick", "getEnergyStored",
            "getEnergyCapacity", "getFluidFlowRate", "getFluidFlowRateMaxMax", "getInductorEngaged",
        },
        actuation = { "setActive", "setFluidFlowRateMax", "setInductorEngaged" },
        -- ATM10 has shipped both spellings. They are one telemetry capability, not two.
        optional = { { "getBladeEfficiency", "getBladeEffiency" } },
    },
}

local reports = {}

local function appendAll(target, source)
    for _, method in ipairs(source or {}) do target[#target + 1] = method end
end

local function missingMethods(wrapped, methods)
    local missing = {}
    for _, method in ipairs(methods or {}) do
        if type(wrapped[method]) ~= "function" then missing[#missing + 1] = method end
    end
    return missing
end

local function optionalTelemetry(wrapped, alternatives)
    local supported, missing = {}, {}
    for _, spellings in ipairs(alternatives or {}) do
        local found = nil
        for _, method in ipairs(spellings) do
            if type(wrapped[method]) == "function" then found = method; break end
        end
        if found then supported[#supported + 1] = found else appendAll(missing, spellings) end
    end
    return supported, missing
end

local function validate(id, kind)
    local definition = requirements[kind]
    local peripheralType = peripheral.getType and peripheral.getType(id) or nil
    local wrapped = peripheral.wrap(id)
    local required, missingRequired, optional, missingOptional = {}, {}, {}, {}
    local mode = "rejected"

    if definition then
        appendAll(required, definition.sampling)
        appendAll(required, definition.actuation)
    end
    if not wrapped then
        missingRequired[1] = "peripheral.wrap"
    elseif not definition then
        missingRequired[1] = "unsupported kind"
    else
        local missingSampling = missingMethods(wrapped, definition.sampling)
        local missingActuation = missingMethods(wrapped, definition.actuation)
        appendAll(missingRequired, missingSampling)
        appendAll(missingRequired, missingActuation)
        optional, missingOptional = optionalTelemetry(wrapped, definition.optional)
        if #missingSampling == 0 then
            mode = #missingActuation == 0 and "control" or "monitor-only"
        end
    end

    local report = {
        id = id, peripheralType = peripheralType, kind = kind, mode = mode,
        required = required, optional = optional,
        missingRequired = missingRequired, missingOptional = missingOptional,
    }
    reports[id] = report
    if mode ~= "control" and AlarmManager then
        local severity = mode == "monitor-only" and "warning" or "critical"
        AlarmManager.raise("capability:" .. id, severity,
            kind .. " " .. mode .. ": " .. table.concat(missingRequired, ", "), id, mode == "rejected")
    end
    -- Preserve the legacy first result, but only a fully controllable device returns true.
    return mode == "control", missingRequired, report
end

_G.CapabilityValidator = { validate = validate, reports = function() return reports end }
