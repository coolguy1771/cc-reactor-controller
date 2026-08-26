-- Independent fail-safe watchdog. Install on a separate ComputerCraft computer whose configured
-- redstone side drives an Extreme Reactors redstone port/relay set to shut down the reactor.

local PATH = "/watchdog.conf"
local defaults = {
    protocol = "my-reactor-controller.watchdog.v1", secret = "", outputSide = "back",
    activeHigh = true, timeoutSeconds = 3, healthyHeartbeatsToReset = 3,
}

local function save(value)
    local f = fs.open(PATH, "w"); f.write(textutils.serialize(value)); f.close()
end
local function load()
    if not fs.exists(PATH) then save(defaults); print("Created " .. PATH .. "; configure secret/outputSide"); return nil end
    local f = fs.open(PATH, "r"); local c = textutils.unserialise(f.readAll()); f.close()
    if type(c) ~= "table" then error("invalid " .. PATH) end
    for k, v in pairs(defaults) do if c[k] == nil then c[k] = v end end
    if c.secret == "" then print("Set secret in " .. PATH); return nil end
    return c
end
local function modem()
    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        if p and p.isWireless and p.isWireless() then return name end
    end
end

local config = load(); if not config then return end
local modemName = modem(); if not modemName then error("No Ender Modem attached") end
rednet.open(modemName)

local tripped, lastHealthy, consecutive = true, -math.huge, 0
local function setTrip(value)
    tripped = value
    local signal
    if config.activeHigh then signal = value else signal = not value end
    redstone.setOutput(config.outputSide, signal)
end
setTrip(true) -- fail safe from the first instruction
print("WATCHDOG TRIPPED - waiting for healthy controller")
local timer = os.startTimer(0.5)

while true do
    local event = { os.pullEvent() }
    if event[1] == "rednet_message" then
        local msg, protocol = event[3], event[4]
        if protocol == config.protocol and type(msg) == "table" and msg.kind == "heartbeat"
            and msg.secret == config.secret then
            if msg.healthy and msg.state ~= "SCRAM" and msg.state ~= "DEGRADED" then
                lastHealthy = os.clock(); consecutive = consecutive + 1
                if tripped and consecutive >= config.healthyHeartbeatsToReset then
                    setTrip(false); print("Watchdog healthy - SCRAM output cleared")
                end
            else
                consecutive = 0; setTrip(true); print("Controller reported unsafe state: " .. tostring(msg.state))
            end
        end
    elseif event[1] == "timer" and event[2] == timer then
        if os.clock() - lastHealthy > config.timeoutSeconds then
            if not tripped then print("Heartbeat timeout - SCRAM") end
            consecutive = 0; setTrip(true)
        end
        timer = os.startTimer(0.5)
    end
end
