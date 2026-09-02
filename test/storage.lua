dofile("src/services/storage.lua")

local function near(actual, expected, tolerance, label)
    assert(math.abs(actual - expected) <= tolerance,
        string.format("%s: expected %.3f, got %.3f", label, expected, actual))
end

local cfg = {
    storageTargetMin = 50, storageTargetMax = 85,
    storageReserveGain = 0.25, storageExclusions = { ignored = true },
}
local storage = StorageCoordinator.new()

local first = storage:update({
    sources = {
        { id="battery", stored=500, capacity=1000, valid=true },
        { id="ignored", stored=1000, capacity=1000, valid=true },
    },
    actualGeneration = 200, availableGeneration = 1000, topologyRevision = 1,
}, cfg)
assert(first.stored == 500 and first.capacity == 1000, "excluded storage was counted")
assert(first.delta == 0 and first.externalDemand == 200, "first sample did not establish a baseline")

local charging = storage:update({
    sources = { { id="battery", stored=550, capacity=1000, valid=true } },
    actualGeneration = 200, availableGeneration = 1000, topologyRevision = 1,
}, cfg)
near(charging.externalDemand, 150, 0.001, "demand subtracts positive storage delta")
near(charging.reserveFactor, 30 / 35, 0.001, "reserve factor tapers through target band")
near(charging.rechargeCorrection, 182.142857, 0.001, "bounded recharge correction")
near(charging.requiredGeneration, 332.142857, 0.001, "required generation")

local full = storage:update({
    sources = { { id="battery", stored=1000, capacity=1000, valid=true } },
    actualGeneration = 200, availableGeneration = 1000, topologyRevision = 1,
}, cfg)
assert(full.reserveFactor == 0 and full.rechargeCorrection == 0, "full storage requested surplus")

local changed = storage:update({
    sources = { { id="replacement", stored=100, capacity=5000, valid=true } },
    actualGeneration = 300, availableGeneration = 1000, topologyRevision = 2,
}, cfg)
assert(changed.delta == 0 and changed.externalDemand == 300, "topology change created false demand")

print("storage tests passed")
