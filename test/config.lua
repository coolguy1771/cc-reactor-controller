-- Config load must survive empty or unreadable override/default files.
dofile("test/cc_stubs.lua")
CONTROL_CONFIG = { steamGroups = {}, operatingMode = "OFF", remoteSecret = "" }
dofile("src/util/config.lua")

local function writePath(path, contents)
    local file = fs.open(path, "w")
    file.write(contents)
    file.close()
end

local function readPath(path)
    local file = fs.open(path, "r")
    if file == nil then
        return nil
    end
    local contents = file.readAll()
    file.close()
    return contents
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

-- Boot auto-start calls writeConfig. An unreadable override must not be treated as
-- "no overrides" and deleted or replaced with just operatingMode.
CONTROL_CONFIG.steamGroups = {}
CONTROL_CONFIG.operatingMode = "OFF"
CONTROL_CONFIG.remoteSecret = ""
ConfigUtil.writeAllConfigsAsDefaults()
local unreadable = "{ steamGroups = { { _reactors = { \"Reactor_0\" }, }"
writePath("/overrides/control.override.conf", unreadable)
ConfigUtil.readConfig("control")
CONTROL_CONFIG.operatingMode = "AUTO_OUTPUT"
ConfigUtil.writeConfig("control")
assert(readPath("/overrides/control.override.conf") == unreadable,
    "unreadable override must not be rewritten on writeConfig")

writePath("/overrides/control.override.conf", "")
CONTROL_CONFIG.operatingMode = "OFF"
ConfigUtil.readConfig("control")
ConfigUtil.writeConfig("control")
assert(fs.exists("/overrides/control.override.conf"),
    "empty unreadable override must not be deleted on writeConfig")
assert(readPath("/overrides/control.override.conf") == "",
    "empty unreadable override contents must be preserved")

CONTROL_CONFIG.steamGroups = {}
CONTROL_CONFIG.operatingMode = "OFF"
CONTROL_CONFIG.remoteSecret = ""
ConfigUtil.writeAllConfigsAsDefaults()
writePath("/overrides/control.override.conf", textutils.serialize({
    steamGroups = {
        { reactors = { "Reactor_0" }, turbines = { "Turbine_0" } },
    },
    remoteSecret = "password",
}))
ConfigUtil.readConfig("control")
CONTROL_CONFIG.operatingMode = "AUTO_OUTPUT"
ConfigUtil.writeConfig("control")
local saved = textutils.unserialise(readPath("/overrides/control.override.conf"))
assert(saved.steamGroups[1].reactors[1] == "Reactor_0", "valid steamGroups must persist")
assert(saved.remoteSecret == "password", "valid secret must persist")

CONTROL_CONFIG.steamGroups = {}
writePath("/overrides/control.override.conf", textutils.serialize({
    steamGroups = {
        { _reactors = { "Reactor_0" }, turbines = { "Turbine_0" } },
    },
}))
ConfigUtil.readConfig("control")
assert(CONTROL_CONFIG.steamGroups[1].reactors[1] == "Reactor_0",
    "_reactors alias must populate reactors")

print("config tests passed")
