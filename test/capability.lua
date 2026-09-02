-- ATM10 Modernized API capability classification.  Control is allowed only when
-- all sampling and fail-safe actuation bindings are present.
dofile("test/cc_stubs.lua")

local function assertList(actual, expected, label)
    assert(#actual == #expected, label .. " length")
    for i, name in ipairs(expected) do
        assert(actual[i] == name, label .. " item " .. i)
    end
end

local function functions(names, writes)
    local object = {}
    for _, name in ipairs(names) do
        object[name] = function(...)
            writes[name] = (writes[name] or 0) + 1
            return 0
        end
    end
    return object
end

local reactorRequired = {
    -- The report contract is grouped deterministically: all sampling, then all actuation.
    "getActive", "isActivelyCooled", "getNumberOfControlRods", "getControlRodsLevels",
    "getEnergyStats", "getFuelStats",
    "getFuelTemperature", "getCasingTemperature", "getWasteAmount",
    "getHotFluidProducedLastTick", "getHotFluidAmount", "getHotFluidAmountMax",
    "setActive", "setControlRodsLevels",
}
local turbineRequired = {
    "getActive", "getRotorSpeed", "getEnergyProducedLastTick",
    "getEnergyStored", "getEnergyCapacity", "getFluidFlowRate", "getFluidFlowRateMaxMax",
    "getInductorEngaged", "setActive", "setFluidFlowRateMax", "setInductorEngaged",
}

dofile("src/services/capability.lua")

local reactorWrites, turbineWrites, historicWrites = {}, {}, {}
peripheral.register("reactor_complete", "BigReactors-Reactor", functions(reactorRequired, reactorWrites))
local turbine = functions(turbineRequired, turbineWrites)
turbine.getBladeEfficiency = function() return 75 end
peripheral.register("turbine_complete", "BigReactors-Turbine", turbine)
local historic = functions(turbineRequired, historicWrites)
historic.getBladeEffiency = function() return 75 end
peripheral.register("turbine_historic", "BigReactors-Turbine", historic)

local ok, missing, reactorReport = CapabilityValidator.validate("reactor_complete", "reactor")
assert(ok == true and #missing == 0, "complete Modernized reactor must be control-capable")
assert(reactorReport.id == "reactor_complete" and reactorReport.peripheralType == "BigReactors-Reactor")
assert(reactorReport.kind == "reactor" and reactorReport.mode == "control")
assertList(reactorReport.required, reactorRequired, "reactor required")
assertList(reactorReport.optional, {}, "reactor optional")
assertList(reactorReport.missingRequired, {}, "reactor missing required")
assertList(reactorReport.missingOptional, {}, "reactor missing optional")

local turbineOK, turbineMissing, turbineReport = CapabilityValidator.validate("turbine_complete", "turbine")
assert(turbineOK == true and #turbineMissing == 0 and turbineReport.mode == "control")
assertList(turbineReport.required, turbineRequired, "turbine required")
assertList(turbineReport.optional, { "getBladeEfficiency" }, "canonical blade telemetry")
assertList(turbineReport.missingOptional, {}, "canonical blade telemetry missing")

local historicOK, historicMissing, historicReport = CapabilityValidator.validate("turbine_historic", "turbine")
assert(historicOK == true and #historicMissing == 0 and historicReport.mode == "control")
assertList(historicReport.optional, { "getBladeEffiency" }, "historical blade telemetry")
assertList(historicReport.missingOptional, {}, "historical blade telemetry missing")

local missingActuatorWrites = {}
local monitorOnlyNames = {}
for _, name in ipairs(turbineRequired) do
    if name ~= "setFluidFlowRateMax" then monitorOnlyNames[#monitorOnlyNames + 1] = name end
end
local monitorOnly = functions(monitorOnlyNames, missingActuatorWrites)
monitorOnly.getBladeEfficiency = function() return 75 end
peripheral.register("turbine_observe", "BigReactors-Turbine", monitorOnly)
local controlOK, actuatorMissing, monitorReport = CapabilityValidator.validate("turbine_observe", "turbine")
assert(controlOK == false and monitorReport.mode == "monitor-only", "missing actuator must never be control-capable")
assertList(actuatorMissing, { "setFluidFlowRateMax" }, "missing actuator return")
assertList(monitorReport.missingRequired, { "setFluidFlowRateMax" }, "missing actuator report")
assert(next(missingActuatorWrites) == nil, "capability validation must not write a monitor-only device")

local incomplete = functions(reactorRequired, {})
incomplete.getFuelTemperature = nil
peripheral.register("reactor_incomplete", "BigReactors-Reactor", incomplete)
local samplingOK, samplingMissing, rejectedReport = CapabilityValidator.validate("reactor_incomplete", "reactor")
assert(samplingOK == false and rejectedReport.mode == "rejected", "missing sampling must reject device")
assertList(samplingMissing, { "getFuelTemperature" }, "missing sampling return")

local reports = CapabilityValidator.reports()
assert(reports.reactor_complete == reactorReport and reports.turbine_observe == monitorReport,
    "reports must retain each validation")
assert(reports.turbine_historic.peripheralType == "BigReactors-Turbine", "report retains peripheral type")
assertList(reports.reactor_incomplete.missingRequired, { "getFuelTemperature" }, "retained missing list")

-- Degraded capability reports remain visible to safety, but an unconstructed monitor-only
-- peripheral must not block a healthy controlled topology. Storage distrust is advisory and
-- cannot clear an existing SCRAM.
CONTROL_CONFIG = { minimumReactors = 1, minimumTurbines = 0, expectedPeripherals = {} }
peripheral.isPresent = function() return true end
local alarms = {}
AlarmManager = {
    raise = function(code, severity) alarms[code] = severity end,
    clear = function(code) alarms[code] = nil end,
}
_G.reactors = { reactor_complete = {
    averageFuelTemp = 100, averageCaseTemp = 100, activelyCooled = false, active = false,
    setRodLevels = function() end, setActive = function() end,
} }
_G.turbines = {}
_G.overallStats = { storage = {
    trustworthy = false, externalDemand = 321, rechargeCorrection = 99, reserveFactor = 1,
} }
dofile("src/services/safety.lua")
assert(SafetyManager.initialize() == true, "monitor-only capability must not fail safety self-test")
assert(SafetyManager.degradedDevices().turbine_observe == "monitor-only", "safety retains degraded mode")
assert(SafetyManager.evaluate() == true, "advisory storage loss must not SCRAM")
assert(_G.overallStats.storage.rechargeCorrection == 0 and _G.overallStats.storage.reserveFactor == 0)
assert(_G.overallStats.storage.requiredGeneration == 321 and alarms.storage_untrusted == "advisory")
SafetyManager.scram("test latch", "test")
assert(SafetyManager.evaluate() == false and SafetyManager.state() == "SCRAM", "advisory must not clear SCRAM")

print("capability tests passed")
