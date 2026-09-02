-- Validate the ATM10/Extreme Reactors peripheral API before constructing a controller object.

local requirements = {
    reactor = {
        "getActive", "setActive", "isActivelyCooled", "getNumberOfControlRods",
        "getControlRodsLevels", "setControlRodsLevels", "getEnergyStats", "getFuelStats",
        "getFuelTemperature", "getCasingTemperature", "getWasteAmount",
        "getHotFluidProducedLastTick", "getHotFluidAmount", "getHotFluidAmountMax",
    },
    turbine = {
        "getActive", "setActive", "getRotorSpeed", "getEnergyProducedLastTick",
        "getEnergyStored", "getEnergyCapacity", "getFluidFlowRate", "getFluidFlowRateMaxMax",
        "setFluidFlowRateMax", "getInductorEngaged", "setInductorEngaged",
    },
}

local reports = {}

local function validate(id, kind)
    local wrapped = peripheral.wrap(id)
    local missing = {}
    if not wrapped then missing[1] = "peripheral.wrap" else
        for _, method in ipairs(requirements[kind] or {}) do
            if type(wrapped[method]) ~= "function" then missing[#missing + 1] = method end
        end
    end
    local ok = #missing == 0
    reports[id] = { id = id, kind = kind, ok = ok, missing = missing }
    if not ok and AlarmManager then
        AlarmManager.raise("capability:" .. id, "critical",
            kind .. " missing methods: " .. table.concat(missing, ", "), id, true)
    end
    return ok, missing
end

_G.CapabilityValidator = { validate = validate, reports = function() return reports end }
