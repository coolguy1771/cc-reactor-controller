-- Resilient remote monitor client for my-reactor-controller v2.

local CONFIG_PATH = "/remote-display.conf"
local DEFAULT_CONFIG = {
    protocol = "my-reactor-controller.remote.v1", host = "reactor-controller", secret = "",
    textScale = 0.5, discoverySeconds = 3, heartbeatSeconds = 5, offlineSeconds = 12,
}

local function writeConfig(config)
    local file = fs.open(CONFIG_PATH, "w"); file.write(textutils.serialize(config)); file.close()
end

local function loadConfig()
    if not fs.exists(CONFIG_PATH) then
        writeConfig(DEFAULT_CONFIG)
        print("Created " .. CONFIG_PATH .. "; set secret, then run again.")
        return nil
    end
    local file = fs.open(CONFIG_PATH, "r")
    local config = textutils.unserialise(file.readAll()); file.close()
    if type(config) ~= "table" then error("Invalid " .. CONFIG_PATH) end
    for key, value in pairs(DEFAULT_CONFIG) do if config[key] == nil then config[key] = value end end
    if type(config.secret) ~= "string" or config.secret == "" then
        print("Set secret in " .. CONFIG_PATH); return nil
    end
    return config
end

local function findWirelessModem()
    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        if p and type(p.isWireless) == "function" and p.isWireless() then return name end
    end
end

local config = loadConfig()
if not config then return end
local modemName = findWirelessModem()
if not modemName then error("No wireless/Ender Modem attached") end
rednet.open(modemName)

local monitors, frameBuffers = {}, {}
local serverId, serverSession, permission = nil, nil, "read-only"
local lastServerMessage, commandSequence = -math.huge, 0

local function discoverMonitors()
    monitors = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            local monitor = peripheral.wrap(name)
            monitor.setTextScale(config.textScale)
            monitors[name] = monitor
        end
    end
end

local function status(text, color)
    for _, monitor in pairs(monitors) do
        monitor.setBackgroundColor(colors.black); monitor.setTextColor(color or colors.yellow)
        monitor.clear(); monitor.setCursorPos(2, 2); monitor.write(text)
    end
end

local function monitorList()
    local list = {}
    for name, monitor in pairs(monitors) do
        local width, height = monitor.getSize()
        list[#list + 1] = { name = name, width = width, height = height }
    end
    return list
end

local function message(kind, extra)
    local msg = extra or {}; msg.kind = kind; msg.secret = config.secret
    return msg
end

local function sendHello()
    local msg = message("hello", { monitors = monitorList(), requestedHost = config.host })
    if serverId then rednet.send(serverId, msg, config.protocol) else rednet.broadcast(msg, config.protocol) end
end

local function drawFrame(msg)
    local monitor = monitors[msg.monitor]
    if not monitor or msg.session ~= serverSession or type(msg.rows) ~= "table" then return end
    local buffer = frameBuffers[msg.monitor]
    if not buffer or buffer.session ~= msg.session or msg.full then
        buffer = { session = msg.session, seq = 0, rows = {} }
        frameBuffers[msg.monitor] = buffer
    end
    if (tonumber(msg.seq) or 0) <= buffer.seq then return end
    buffer.seq = msg.seq
    for y, row in pairs(msg.rows) do buffer.rows[tonumber(y) or y] = row end
    local width, height = monitor.getSize()
    monitor.setCursorBlink(false)
    for y = 1, math.min(height, msg.height or height) do
        local row = buffer.rows[y]
        if type(row) == "table" and type(row[1]) == "string"
            and type(row[2]) == "string" and type(row[3]) == "string" then
            local n = math.min(width, #row[1], #row[2], #row[3])
            monitor.setCursorPos(1, y)
            monitor.blit(row[1]:sub(1, n), row[2]:sub(1, n), row[3]:sub(1, n))
        end
    end
end

discoverMonitors()
if next(monitors) == nil then error("No monitor attached to display computer") end
status("Searching for reactor controller...", colors.yellow)
sendHello()
local timer = os.startTimer(config.discoverySeconds)

while true do
    local event = { os.pullEvent() }
    if event[1] == "rednet_message" then
        local sender, msg, protocol = event[2], event[3], event[4]
        if protocol == config.protocol and type(msg) == "table" and msg.secret == config.secret then
            if msg.kind == "hello_ack" and (not serverId or sender == serverId) then
                local changedSession = serverSession ~= msg.session
                serverId, serverSession = sender, msg.session
                permission = msg.role or "read-only"
                lastServerMessage = os.clock()
                if changedSession then frameBuffers = {}; commandSequence = 0 end
                print(("Connected to controller %d (%s)"):format(serverId, permission))
            elseif sender == serverId and msg.kind == "frame" then
                lastServerMessage = os.clock(); drawFrame(msg)
            end
        end
    elseif event[1] == "monitor_touch" then
        local name, x, y = event[2], event[3], event[4]
        if monitors[name] and serverId and permission == "control" then
            commandSequence = commandSequence + 1
            rednet.send(serverId, message("touch", {
                monitor = name, x = x, y = y, session = serverSession, commandSeq = commandSequence,
            }), config.protocol)
        end
    elseif event[1] == "monitor_resize" or event[1] == "peripheral"
        or event[1] == "peripheral_detach" then
        discoverMonitors(); frameBuffers = {}; sendHello()
    elseif event[1] == "timer" and event[2] == timer then
        if serverId and os.clock() - lastServerMessage <= config.offlineSeconds then
            rednet.send(serverId, message("heartbeat", { session = serverSession }), config.protocol)
            sendHello()
            timer = os.startTimer(config.heartbeatSeconds)
        else
            if serverId then status("Controller link lost - reconnecting", colors.red) end
            serverId, serverSession, permission = nil, nil, "read-only"
            frameBuffers = {}
            sendHello()
            timer = os.startTimer(config.discoverySeconds)
        end
    end
end
