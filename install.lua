-- Transactional installer/updater for reactor controller components.
-- Usage:
--   wget run <raw install.lua URL> controller [owner] [repo] [branch] [backup]
--   wget run <raw install.lua URL> display [owner] [repo] [branch]
--   wget run <raw install.lua URL> watchdog [owner] [repo] [branch]
--
-- Roles: controller, display, watchdog.
-- Defaults: coolguy1771 / cc-reactor-controller / main
-- Disk usage: installs one file at a time via /.reactor-install.tmp (no full-tree staging).
-- Optional trailing "backup" keeps /.reactor-update-backup after success (uses more disk).

local args = { ... }
local ROLE = args[1] or "controller"
local OWNER = args[2] or "coolguy1771"
local REPO = args[3] or "cc-reactor-controller"
local BRANCH = args[4] or "main"
local KEEP_BACKUP = args[5] == "backup"
local TEMP = "/.reactor-install.tmp"
local BACKUP = "/.reactor-update-backup"
local STAGE = "/.reactor-update-staging"
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

local function deleteTree(path)
    if not fs.exists(path) then return end
    if fs.isDir(path) then
        for _, name in ipairs(fs.list(path)) do
            deleteTree(fs.combine(path, name))
        end
        fs.delete(path)
    else
        fs.delete(path)
    end
end

local function freeBytes()
    if fs.getFreeSpace then return fs.getFreeSpace("/") end
    return nil
end

deleteTree(STAGE)
deleteTree(BACKUP)
if fs.exists(TEMP) then fs.delete(TEMP) end

local free = freeBytes()
if free then
    print(("Disk free: %d bytes"):format(free))
    if free < 8192 then
        error("Disk full. Delete /.reactor-update-backup, /.reactor-update-staging, /logs/events.log*")
    end
end

print("Installing " .. ROLE .. " from " .. OWNER .. "/" .. REPO .. " (" .. BRANCH .. ")")

local function restoreBackup(committed)
    for _, target in ipairs(committed) do
        local live = "/" .. target
        local saved = fs.combine(BACKUP, target)
        if fs.exists(live) then fs.delete(live) end
        if fs.exists(saved) then fs.copy(saved, live) end
    end
end

local committed = {}
local ok, err = pcall(function()
    for i, item in ipairs(files) do
        local target = "/" .. item.target
        writeFile(TEMP, get(RAW_BASE .. item.source))
        if item.target:sub(-4) == ".lua" then
            local fn, loadErr = loadfile(TEMP)
            if not fn then
                fs.delete(TEMP)
                error("Syntax validation failed for " .. item.target .. ": " .. tostring(loadErr))
            end
        end
        if KEEP_BACKUP and fs.exists(target) then
            copyIfPresent(target, fs.combine(BACKUP, item.target))
        end
        local dir = fs.getDir(target)
        if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
        if fs.exists(target) then fs.delete(target) end
        fs.move(TEMP, target)
        committed[#committed + 1] = item.target
        print(("[%d/%d] installed %s"):format(i, #files, item.target))
    end
end)

if fs.exists(TEMP) then fs.delete(TEMP) end
deleteTree(STAGE)

if not ok then
    print("Install failed: " .. tostring(err))
    if KEEP_BACKUP and #committed > 0 then
        print("Restoring partial backup...")
        restoreBackup(committed)
    end
    error("Update failed")
end

if not KEEP_BACKUP then
    deleteTree(BACKUP)
else
    print("Backup kept at " .. BACKUP)
end

writeFile("/.reactor-install.conf", textutils.serialize({
    role = ROLE,
    owner = OWNER,
    repo = REPO,
    branch = BRANCH,
    installedAt = os.epoch("utc"),
    backup = KEEP_BACKUP and BACKUP or nil,
}))

free = freeBytes()
if free then print(("Disk free after install: %d bytes"):format(free)) end
print("Install complete.")
print("Reboot now? (y/n)")
if string.lower(read()) == "y" then os.reboot() end
