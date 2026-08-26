-- Restore the most recent transactional-installer backup.
local BACKUP = "/.reactor-update-backup"
if not fs.exists(BACKUP) then error("No update backup found") end
local function restore(path, relative)
    for _, name in ipairs(fs.list(path)) do
        local source = fs.combine(path, name)
        local targetRelative = relative == "" and name or fs.combine(relative, name)
        if fs.isDir(source) then
            restore(source, targetRelative)
        else
            local target = "/" .. targetRelative
            local dir = fs.getDir(target); if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
            if fs.exists(target) then fs.delete(target) end
            fs.copy(source, target)
            print("restored " .. target)
        end
    end
end
restore(BACKUP, "")
print("Rollback complete; reboot when ready.")
