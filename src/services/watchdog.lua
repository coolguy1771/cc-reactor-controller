-- Broadcast controller health for an independent redstone watchdog computer.

local last = -math.huge
local session = nil
local opened = false

local function ensureOpen()
    if opened then return true end
    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        if p and p.isWireless and p.isWireless() then rednet.open(name); opened = true; return true end
    end
    if AlarmManager then AlarmManager.raise("watchdog_modem", "critical", "watchdog enabled without Ender Modem", "watchdog") end
    return false
end

local function update()
    if not CONTROL_CONFIG.watchdogEnabled or not rednet then return end
    if type(CONTROL_CONFIG.remoteSecret) ~= "string" or CONTROL_CONFIG.remoteSecret == "" then
        if AlarmManager then AlarmManager.raise("watchdog_secret", "critical", "watchdog enabled without a shared secret", "watchdog") end
        return
    end
    if not ensureOpen() then return end
    local now = os.clock()
    if now - last < (CONTROL_CONFIG.watchdogHeartbeatSeconds or 1) then return end
    session = session or ((os.getComputerID and os.getComputerID() or 0) .. ":" ..
        tostring(os.epoch and os.epoch("utc") or now))
    rednet.broadcast({
        kind = "heartbeat", secret = CONTROL_CONFIG.remoteSecret, session = session,
        state = SafetyManager and SafetyManager.state() or "UNKNOWN",
        healthy = SafetyManager and SafetyManager.state() ~= "SCRAM" and SafetyManager.state() ~= "DEGRADED",
    }, CONTROL_CONFIG.watchdogProtocol)
    last = now
end

_G.WatchdogHeartbeat = { update = update }
