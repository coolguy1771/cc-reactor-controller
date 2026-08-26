-- Persistent, size-bounded operator/event journal.

local PATH = "/logs/events.log"

local function timestamp()
    if os.date then return os.date("!%Y-%m-%dT%H:%M:%SZ") end
    return tostring(os.epoch and os.epoch("utc") or 0)
end

local function rotateIfNeeded()
    if not fs.exists(PATH) or not fs.getSize then return end
    if fs.getSize(PATH) <= (CONTROL_CONFIG.eventLogMaxBytes or 131072) then return end
    local old = PATH .. ".1"
    if fs.exists(old) then fs.delete(old) end
    fs.move(PATH, old)
end

local function record(level, code, message, data)
    rotateIfNeeded()
    local dir = fs.getDir(PATH)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local line = table.concat({
        timestamp(), tostring(level or "INFO"), tostring(code or "event"),
        tostring(message or ""), data and textutils.serialize(data, { compact = true }) or "",
    }, "\t") .. "\n"
    local file = fs.open(PATH, "a")
    if file then file.write(line); file.close() end
end

_G.EventJournal = { record = record, path = PATH }
