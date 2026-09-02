local Storage = {}
Storage.__index = Storage

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

function Storage.new()
    return setmetatable({ previousStored = nil, topologyRevision = nil }, Storage)
end

function Storage:update(input, config)
    local excluded = config.storageExclusions or {}
    local stored, capacity, ids = 0, 0, {}
    for _, source in ipairs(input.sources or {}) do
        if source.valid ~= false and not excluded[source.id]
            and type(source.stored) == "number" and type(source.capacity) == "number"
            and source.stored >= 0 and source.capacity > 0 then
            stored = stored + source.stored
            capacity = capacity + source.capacity
            ids[#ids + 1] = source.id
        end
    end
    table.sort(ids)
    local topologyChanged = self.topologyRevision ~= input.topologyRevision
    local delta = (not topologyChanged and self.previousStored) and (stored - self.previousStored) or 0
    local actual = math.max(0, input.actualGeneration or 0)
    local demand = math.max(0, actual - delta)
    local fill = capacity > 0 and clamp(stored / capacity * 100, 0, 100) or 0
    local low, high = config.storageTargetMin or 50, config.storageTargetMax or 85
    local reserve = fill < low and 1 or (fill < high and (high - fill) / (high - low) or 0)
    local available = math.max(0, input.availableGeneration or actual)
    local correction = math.max(0, available - demand) * (config.storageReserveGain or 0.25) * reserve
    self.previousStored = stored
    self.topologyRevision = input.topologyRevision
    return { stored=stored, capacity=capacity, fillPct=fill, delta=delta,
        externalDemand=demand, reserveFactor=reserve, rechargeCorrection=correction,
        requiredGeneration=demand + correction, trustworthy=capacity > 0, sourceIDs=ids }
end

_G.StorageCoordinator = { new = Storage.new }
