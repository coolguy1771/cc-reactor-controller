-- Scripted headless smoke test for remote-display.lua discovery and full-frame rendering.

dofile("test/cc_stubs.lua")
local protocol, secret, session = "my-reactor-controller.remote.v1", "client-test", "7:1000"
local cfg = fs.open("/remote-display.conf", "w")
cfg.write(textutils.serialize({ protocol=protocol, host="reactor-controller", secret=secret,
    textScale=0.5, discoverySeconds=3, heartbeatSeconds=5, offlineSeconds=12 }))
cfg.close()

local monitor = makeTerm(20, 5)
peripheral.register("ender_0", "modem", { isWireless=function() return true end })
peripheral.register("monitor_0", "monitor", monitor)

rednet = {
    open=function() end,
    broadcast=function(message, usedProtocol)
        assert(message.kind == "hello" and usedProtocol == protocol)
        os.queueEvent("rednet_message", 99, {
            kind="hello_ack", secret=secret, session=session, role="control", server=99,
        }, protocol)
        os.queueEvent("rednet_message", 99, {
            kind="frame", secret=secret, session=session, seq=1, full=true,
            monitor="monitor_0", width=20, height=5,
            rows={ [1]={ "HELLO               ", "00000000000000000000", "ffffffffffffffffffff" } },
        }, protocol)
    end,
    send=function() return true end,
}

local ok, err = pcall(dofile, "remote-display.lua")
-- The stub intentionally raises once its finite scripted event queue is exhausted.
assert(not ok and tostring(err):find("empty queue"), "client did not consume scripted events")
local text = {}
for x = 1, 5 do text[x] = monitor._grid[1][x] and monitor._grid[1][x].ch or " " end
assert(table.concat(text) == "HELLO", "remote client did not render the frame")
print("REMOTE CLIENT CHECKS PASSED")
