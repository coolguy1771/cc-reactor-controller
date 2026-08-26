-- Alarm lifecycle: raise, acknowledge, clear, and retain bounded history.

local active, history = {}, {}

local function now() return os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000) end

local function addHistory(item)
    history[#history + 1] = item
    local limit = CONTROL_CONFIG.alarmHistoryLimit or 200
    while #history > limit do table.remove(history, 1) end
end

local function raise(code, severity, message, source, latched)
    local alarm = active[code]
    if alarm then
        alarm.lastSeen = now()
        alarm.message = message or alarm.message
        return alarm, false
    end
    alarm = {
        code = code, severity = severity or "warning", message = message or code,
        source = source or "controller", raisedAt = now(), lastSeen = now(),
        acknowledged = false, latched = latched == true,
    }
    active[code] = alarm
    addHistory({ action = "raised", at = alarm.raisedAt, code = code, severity = alarm.severity,
        message = alarm.message, source = alarm.source })
    if EventJournal then EventJournal.record(alarm.severity:upper(), code, alarm.message, { source = alarm.source }) end
    return alarm, true
end

local function clear(code, force)
    local alarm = active[code]
    if not alarm or (alarm.latched and not force) then return false end
    active[code] = nil
    addHistory({ action = "cleared", at = now(), code = code })
    if EventJournal then EventJournal.record("INFO", code, "alarm cleared") end
    return true
end

local function acknowledge(code)
    local alarm = active[code]
    if not alarm then return false end
    alarm.acknowledged = true
    addHistory({ action = "acknowledged", at = now(), code = code })
    if EventJournal then EventJournal.record("INFO", code, "alarm acknowledged") end
    return true
end

local rank = { advisory = 1, warning = 2, critical = 3 }
local function summary()
    local count, worst = 0, nil
    for _, alarm in pairs(active) do
        count = count + 1
        if not worst or (rank[alarm.severity] or 0) > (rank[worst] or 0) then worst = alarm.severity end
    end
    return count, worst
end

_G.AlarmManager = {
    raise = raise, clear = clear, acknowledge = acknowledge, summary = summary,
    active = function() return active end, history = function() return history end,
}
