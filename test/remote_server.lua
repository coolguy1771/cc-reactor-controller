-- Headless checks for the Ender Modem remote-display transport.

dofile("test/cc_stubs.lua")
dofile("src/config/projectConfigs.lua")

local sent = {}
rednet = {
    open = function(name) rednet.opened = name end,
    host = function(protocol, host) rednet.hosted = { protocol, host } end,
    send = function(target, message, protocol)
        sent[#sent + 1] = { target = target, message = message, protocol = protocol }
        return true
    end,
    close = function() end,
}
os.getComputerID = function() return 7 end

peripheral.register("ender_modem_0", "modem", {
    isWireless = function() return true end,
})

CONTROL_CONFIG.remoteSecret = "test-secret"
CONTROL_CONFIG.remoteClients[42] = "control"
dofile("src/remote/server.lua")

local attached, touched
local detached = {}
local callbacks = {
    attach = function(id, terminal) attached = { id = id, terminal = terminal } end,
    resize = function() end,
    detach = function(id) detached[id] = true end,
    touch = function(id, x, y) touched = { id = id, x = x, y = y } end,
}

assert(RemoteDisplayServer.start(callbacks), "server did not start")
assert(rednet.opened == "ender_modem_0", "Ender Modem was not opened")

RemoteDisplayServer.handleMessage(42, {
    kind = "hello",
    secret = "test-secret",
    monitors = { { name = "monitor_0", width = 20, height = 5 } },
}, CONTROL_CONFIG.remoteProtocol)

assert(attached and attached.id == "remote:42:monitor_0", "remote monitor was not attached")
assert(type(attached.terminal.getPaletteColour) == "function",
    "remote terminal missing palette API required by window.create")
attached.terminal.setCursorPos(1, 1)
attached.terminal.blit("HELLO", "00000", "fffff")
attached.terminal.flush(true)

local frame
for _, packet in ipairs(sent) do
    if packet.message.kind == "frame" then frame = packet.message end
end
assert(frame, "no remote frame was sent")
assert(frame.rows[1][1]:sub(1, 5) == "HELLO", "frame text was corrupted")
assert(frame.full == true and frame.seq == 1 and frame.session, "frame metadata missing")

attached.terminal.setCursorPos(1, 2)
attached.terminal.blit("DELTA", "00000", "fffff")
attached.terminal.flush(true)
local delta = sent[#sent].message
assert(delta.full == false and delta.seq == 2 and delta.rows[2] and not delta.rows[1],
    "changed-row delta frame was not produced")

RemoteDisplayServer.handleMessage(42, {
    kind = "touch", secret = "test-secret", monitor = "monitor_0", x = 3, y = 4,
    session = frame.session, commandSeq = 1,
}, CONTROL_CONFIG.remoteProtocol)
assert(touched and touched.id == attached.id and touched.x == 3 and touched.y == 4,
    "touch was not forwarded")

RemoteDisplayServer.handleMessage(42, {
    kind = "touch", secret = "wrong-secret", monitor = "monitor_0", x = 9, y = 9,
    session = frame.session, commandSeq = 2,
}, CONTROL_CONFIG.remoteProtocol)
assert(touched.x == 3 and touched.y == 4, "unauthorized touch was accepted")

RemoteDisplayServer.handleMessage(42, {
    kind = "touch", secret = "test-secret", monitor = "monitor_0", x = 8, y = 8,
    session = frame.session, commandSeq = 1,
}, CONTROL_CONFIG.remoteProtocol)
assert(touched.x == 3 and touched.y == 4, "replayed touch was accepted")

RemoteDisplayServer.handleMessage(43, {
    kind = "hello", secret = "test-secret",
    monitors = { { name = "monitor_ro", width = 10, height = 3 } },
}, CONTROL_CONFIG.remoteProtocol)
RemoteDisplayServer.handleMessage(43, {
    kind = "touch", secret = "test-secret", monitor = "monitor_ro", x = 7, y = 2,
    session = frame.session, commandSeq = 1,
}, CONTROL_CONFIG.remoteProtocol)
assert(touched.x == 3 and touched.y == 4, "read-only client was allowed to control")
assert(pcall(RemoteDisplayServer.handleMessage, 44, "malformed", CONTROL_CONFIG.remoteProtocol),
    "malformed remote packet crashed the server")

_G.__simClock = CONTROL_CONFIG.remoteClientTimeoutSeconds + 1
RemoteDisplayServer.update()
assert(detached["remote:42:monitor_0"] and detached["remote:43:monitor_ro"],
    "expired clients were not detached")

print("REMOTE DISPLAY CHECKS PASSED")
