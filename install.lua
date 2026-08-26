-- Transactional installer/updater for reactor controller components.
-- Usage:
--   wget run <raw install.lua URL> controller [owner] [repo] [branch]
--   wget run <raw install.lua URL> display [owner] [repo] [branch]
--   wget run <raw install.lua URL> watchdog [owner] [repo] [branch]
--
-- Roles: controller, display, watchdog.
-- Defaults: coolguy1771 / cc-reactor-controller / main

local args = { ... }
local ROLE = args[1] or "controller"
local OWNER = args[2] or "coolguy1771"
local REPO = args[3] or "cc-reactor-controller"
local BRANCH = args[4] or "main"
local STAGE = "/.reactor-update-staging"
local BACKUP = "/.reactor-update-backup"
local RAW_BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(OWNER, REPO, BRANCH)

local MANIFEST = {
    controller = {
        { source = "startup.lua", target = "startup.lua" },
        { source = "setup.lua", target = "setup.lua" },
        { source = "rollback.lua", target = "rollback.lua" },
        { source = "install.lua", target = "install.lua" },
        { source = "src/config/projectConfigs.lua", target = "src/config/projectConfigs.lua" },
        { source = "src/constants/projectConstants.lua", target = "src/constants/projectConstants.lua" },
        { source = "src/scripts/main.lua", target = "src/scripts/main.lua" },
        { source = "src/scripts/controller.lua", target = "src/scripts/controller.lua" },
        { source = "src/remote/server.lua", target = "src/remote/server.lua" },
        { source = "src/services/safety.lua", target = "src/services/safety.lua" },
        { source = "src/services/capability.lua", target = "src/services/capability.lua" },
        { source = "src/services/watchdog.lua", target = "src/services/watchdog.lua" },
        { source = "src/services/history.lua", target = "src/services/history.lua" },
        { source = "src/services/telemetry.lua", target = "src/services/telemetry.lua" },
        { source = "src/services/journal.lua", target = "src/services/journal.lua" },
        { source = "src/services/alarm.lua", target = "src/services/alarm.lua" },
        { source = "src/util/config.lua", target = "src/util/config.lua" },
        { source = "src/util/draw.lua", target = "src/util/draw.lua" },
        { source = "src/classes/deque.lua", target = "src/classes/deque.lua" },
        { source = "src/classes/energybuffer.lua", target = "src/classes/energybuffer.lua" },
        { source = "src/classes/reactor.lua", target = "src/classes/reactor.lua" },
        { source = "src/classes/touchpoint.lua", target = "src/classes/touchpoint.lua" },
        { source = "src/classes/vector2.lua", target = "src/classes/vector2.lua" },
        { source = "src/classes/turbine.lua", target = "src/classes/turbine.lua" },
        { source = "src/classes/monitor.lua", target = "src/classes/monitor.lua" },
    },
    display = {
        { source = "remote-display.lua", target = "remote-display.lua" },
        { source = "remote-startup.lua", target = "startup.lua" },
    },
    watchdog = {
        { source = "watchdog.lua", target = "watchdog.lua" },
        { source = "watchdog-startup.lua", target = "startup.lua" },
    },
}

local files = MANIFEST[ROLE]
if not files then
    error("Unknown role: " .. tostring(ROLE) .. " (use controller, display, or watchdog)")
end

local function get(url)
    local response, err = http.get(url)
    if not response then error("HTTP failed: " .. tostring(err)) end
    local body = response.readAll()
    response.close()
    return body
end

local function writeFile(path, body)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(path, "w")
    f.write(body)
    f.close()
end

local function copyIfPresent(source, destination)
    if not fs.exists(source) then return end
    local dir = fs.getDir(destination)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    fs.copy(source, destination)
end

if fs.exists(STAGE) then fs.delete(STAGE) end
if fs.exists(BACKUP) then fs.delete(BACKUP) end
fs.makeDir(STAGE)
fs.makeDir(BACKUP)

print("Installing " .. ROLE .. " from " .. OWNER .. "/" .. REPO .. " (" .. BRANCH .. ")")

for i, item in ipairs(files) do
    local staged = fs.combine(STAGE, item.target)
    writeFile(staged, get(RAW_BASE .. item.source))
    if item.target:sub(-4) == ".lua" then
        local fn, err = loadfile(staged)
        if not fn then
            error("Syntax validation failed for " .. item.target .. ": " .. tostring(err))
        end
    end
    print(("[%d/%d] validated %s"):format(i, #files, item.target))
end

for _, item in ipairs(files) do
    copyIfPresent("/" .. item.target, fs.combine(BACKUP, item.target))
end

local committed = {}
local ok, err = pcall(function()
    for _, item in ipairs(files) do
        local target = "/" .. item.target
        local dir = fs.getDir(target)
        if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
        if fs.exists(target) then fs.delete(target) end
        fs.move(fs.combine(STAGE, item.target), target)
        committed[#committed + 1] = item.target
    end
end)

if not ok then
    print("Commit failed; rolling back: " .. tostring(err))
    for _, target in ipairs(committed) do
        local live = "/" .. target
        local saved = fs.combine(BACKUP, target)
        if fs.exists(live) then fs.delete(live) end
        if fs.exists(saved) then fs.copy(saved, live) end
    end
    error("Update rolled back")
end

writeFile("/.reactor-install.conf", textutils.serialize({
    role = ROLE,
    owner = OWNER,
    repo = REPO,
    branch = BRANCH,
    installedAt = os.epoch("utc"),
    backup = BACKUP,
}))
fs.delete(STAGE)
print("Install complete. Backup saved to " .. BACKUP)
print("Reboot now? (y/n)")
if string.lower(read()) == "y" then os.reboot() end
