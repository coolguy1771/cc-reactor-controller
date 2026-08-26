-- Scripted watchdog test: fail-safe output starts asserted, then clears after healthy heartbeats.

dofile("test/cc_stubs.lua")
local cfg = fs.open("/watchdog.conf", "w")
cfg.write(textutils.serialize({ protocol="watchdog-test", secret="watch-secret", outputSide="back",
    activeHigh=true, timeoutSeconds=3, healthyHeartbeatsToReset=3 }))
cfg.close()
peripheral.register("ender_0", "modem", { isWireless=function() return true end })

local outputs = {}
redstone = { setOutput=function(side, value) outputs[#outputs + 1] = { side, value } end }
rednet = { open=function() end }
for _ = 1, 3 do
    os.queueEvent("rednet_message", 7, {
        kind="heartbeat", secret="watch-secret", state="RUNNING", healthy=true,
    }, "watchdog-test")
end
local ok, err = pcall(dofile, "watchdog.lua")
assert(not ok and tostring(err):find("empty queue"), "watchdog did not consume scripted events")
assert(outputs[1][2] == true, "watchdog did not start fail-safe asserted")
local cleared = false
for _, output in ipairs(outputs) do if output[2] == false then cleared = true end end
assert(cleared, "watchdog did not clear after consecutive healthy heartbeats")
print("WATCHDOG CHECKS PASSED")
