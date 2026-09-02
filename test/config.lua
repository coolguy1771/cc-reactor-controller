-- Config load must survive empty or unreadable override/default files.
dofile("test/cc_stubs.lua")
CONTROL_CONFIG = { steamGroups = {}, operatingMode = "OFF", remoteSecret = "" }
dofile("src/util/config.lua")

local function writePath(path, contents)
    local file = fs.open(path, "w")
    file.write(contents)
    file.close()
end

CONTROL_CONFIG.operatingMode = "OFF"
writePath("/overrides/control.override.conf", "")
ConfigUtil.readConfig("control")
assert(CONTROL_CONFIG.operatingMode == "OFF", "empty override must not crash or wipe live config")

writePath("/overrides/control.override.conf", "{ this is not valid lua")
ConfigUtil.readConfig("control")
assert(CONTROL_CONFIG.operatingMode == "OFF", "invalid override must not crash")

writePath("/defaults/control.default.conf", "")
ConfigUtil.readConfig("control")
assert(CONTROL_CONFIG.operatingMode == "OFF", "empty defaults must not crash")

writePath("/overrides/control.override.conf", textutils.serialize({
    operatingMode = "AUTO_OUTPUT",
    remoteSecret = "password",
}))
ConfigUtil.readConfig("control")
assert(CONTROL_CONFIG.operatingMode == "AUTO_OUTPUT", "valid override did not apply")
assert(CONTROL_CONFIG.remoteSecret == "password", "valid override secret did not apply")

print("config tests passed")
