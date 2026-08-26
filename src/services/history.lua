-- Bounded aggregate trend history with periodic persistence.

local samples, lastSample, lastPersist = {}, -math.huge, -math.huge
local PATH = "/state/history.state.conf"

local function sample()
    local now = os.clock()
    if now - lastSample < (CONTROL_CONFIG.historySampleSeconds or 1) then return end
    lastSample = now
    local s = _G.overallStats or {}
    samples[#samples + 1] = {
        t = os.epoch and os.epoch("utc") or math.floor(now * 1000),
        mode = CONTROL_CONFIG.operatingMode,
        grid = (s.capacity or 0) > 0 and (s.storedThisTick or 0) / s.capacity * 100 or 0,
        generation = s.totalRFT or 0, drain = s.rfLost or 0,
        steamProduction = s.steamProductionRate or 0,
        steamConsumption = s.steamConsumedLastTick or 0,
        fuel = s.fuelUsage or 0,
    }
    local limit = math.max(60, math.floor((CONTROL_CONFIG.historySeconds or 3600)
        / math.max(0.05, CONTROL_CONFIG.historySampleSeconds or 1)))
    while #samples > limit do table.remove(samples, 1) end

    if ConfigUtil and now - lastPersist >= (CONTROL_CONFIG.historyPersistSeconds or 60) then
        ConfigUtil.writeState("history", { samples = samples })
        lastPersist = now
    end
end

local function restore()
    if not ConfigUtil then return end
    local saved = ConfigUtil.readState("history")
    if saved and type(saved.samples) == "table" then samples = saved.samples end
end

_G.HistoryManager = { sample = sample, restore = restore, samples = function() return samples end, path = PATH }
