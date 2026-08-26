-- First-run configuration and API report wizard.

local function ask(prompt, default)
    write(prompt .. (default ~= nil and (" [" .. tostring(default) .. "]") or "") .. ": ")
    local value = read()
    if value == "" then return default end
    return value
end
local function yes(prompt, default)
    local value = string.lower(tostring(ask(prompt .. " (y/n)", default and "y" or "n")))
    return value == "y" or value == "yes"
end

print("Reactor Controller v2 setup")
print("Computer ID: " .. os.getComputerID())
print("")
local reactors, turbines, monitors = {}, {}, {}
for _, id in ipairs(peripheral.getNames()) do
    local kind = peripheral.getType(id)
    print(id .. "  " .. tostring(kind))
    if kind == "BigReactors-Reactor" or kind == "extremereactor-reactorComputerPort" then reactors[#reactors + 1] = id end
    if kind == "BigReactors-Turbine" or kind == "extremereactor-turbineComputerPort" then turbines[#turbines + 1] = id end
    if kind == "monitor" then monitors[#monitors + 1] = id end
end

local secret = ask("Remote/watchdog shared secret (leave empty to disable)", "")
local overrides = {
    minimumReactors = tonumber(ask("Minimum expected reactors", #reactors)) or #reactors,
    minimumTurbines = tonumber(ask("Minimum expected turbines", #turbines)) or #turbines,
    expectedPeripherals = {}, remoteSecret = secret,
    watchdogEnabled = yes("Enable independent watchdog heartbeats", false),
}
for _, id in ipairs(reactors) do overrides.expectedPeripherals[#overrides.expectedPeripherals + 1] = id end
for _, id in ipairs(turbines) do overrides.expectedPeripherals[#overrides.expectedPeripherals + 1] = id end

if secret ~= "" then
    print("Enter remote display computer IDs, comma-separated, or leave blank for read-only discovery:")
    local ids = read(); overrides.remoteClients = {}
    for id in string.gmatch(ids, "%d+") do overrides.remoteClients[tonumber(id)] = "control" end
end

if not fs.exists("/overrides") then fs.makeDir("/overrides") end
local f = fs.open("/overrides/control.override.conf", "w")
f.write(textutils.serialize(overrides)); f.close()
print("Configuration written. Reactors will remain OFF after reboot until you press Auto/Reactors On.")
print("Run 'reboot' when ready.")
