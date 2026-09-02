
-- Config persistence with a defaults/overrides split:
--   /defaults/<id>.default.conf   - the shipped defaults, rewritten every boot
--   /overrides/<id>.override.conf - only the keys the user changed from default
--   /state/<id>.state.conf        - free-form runtime state (writeState/readState)
-- readConfig() layers defaults then overrides onto the live table; writeConfig() diffs the
-- live table against defaults and stores just the difference (deleting the override file
-- when nothing differs). An override file that exists but cannot be parsed is left on disk.

local CONFIGS = {}
CONFIGS["control"] = CONTROL_CONFIG

local DEFAULTS_PATH = "/defaults/"
local OVERRIDES_PATH = "/overrides/"
local STATE_PATH = "/state/"
local CONFIG_EXTENSION = ".default.conf"
local OVERRIDE_EXTENSION = ".override.conf"
local STATE_EXTENSION = ".state.conf"

-- Set when an on-disk override exists but cannot be parsed. writeConfig must not
-- treat that as "no overrides" and delete or replace the user's file.
local overrideUnreadable = {}

local function isTableEmpty(value)
    if type(value) ~= "table" then
        return true
    end
    for _, _ in pairs(value) do
        return false
    end
    return true
end

local function serializeTableAndWriteToFile(table, path)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local file = fs.open(path, "w")
    file.write(textutils.serialize(table))
    file.close()
end

-- Returns table, "ok" | nil, "missing" | nil, "invalid"
local function readSerializedTable(path)
    local file = fs.open(path, "r")
    if file == nil then
        return nil, "missing"
    end
    local contents = file.readAll() or ""
    file.close()
    local data = textutils.unserialise(contents)
    if type(data) ~= "table" then
        return nil, "invalid"
    end
    return data, "ok"
end

local function readFileAndReturnDeserialized(path)
    local data = readSerializedTable(path)
    if type(data) ~= "table" then
        return {}
    end
    return data
end

local function readState(stateID)
    return readFileAndReturnDeserialized(STATE_PATH..stateID..STATE_EXTENSION)
end

local function spread(source, destination)
    if type(source) ~= "table" or type(destination) ~= "table" then
        return
    end
    for key, value in pairs(source) do
        destination[key] = value
    end
end

-- Accept the common edit typo `_reactors` so a loadable override still groups.
local function normalizeSteamGroups(configData)
    local groups = configData.steamGroups
    if type(groups) ~= "table" then
        return
    end
    for _, group in ipairs(groups) do
        if type(group) == "table" and group.reactors == nil
            and type(group._reactors) == "table" then
            group.reactors = group._reactors
        end
    end
end

local function readConfig(configID)
    local configData = CONFIGS[configID]
    local defaults = readFileAndReturnDeserialized(DEFAULTS_PATH..configID..CONFIG_EXTENSION)
    spread(defaults, configData)

    local overridePath = OVERRIDES_PATH..configID..OVERRIDE_EXTENSION
    local overrides, status = readSerializedTable(overridePath)
    if status == "invalid" then
        overrideUnreadable[configID] = true
        return
    end
    overrideUnreadable[configID] = nil
    spread(overrides or {}, configData)
    normalizeSteamGroups(configData)
end

-- Value equality that also works for table-valued config keys (compared by content,
-- not identity - defaults read back from disk are never the same table object).
local function valuesEqual(a, b)
    if type(a) == "table" and type(b) == "table" then
        return textutils.serialize(a) == textutils.serialize(b)
    end
    return a == b
end

local function writeConfig(configID)
    if overrideUnreadable[configID] then
        return
    end
    local configData = CONFIGS[configID]
    local defaults = readFileAndReturnDeserialized(DEFAULTS_PATH..configID..CONFIG_EXTENSION)
    local overrides = {}
    for key, value in pairs(configData) do
        if not valuesEqual(configData[key], defaults[key]) then
            overrides[key] = value
        end
    end

    if isTableEmpty(overrides) then
        fs.delete(OVERRIDES_PATH..configID..OVERRIDE_EXTENSION)
        return
    end
    serializeTableAndWriteToFile(overrides, OVERRIDES_PATH..configID..OVERRIDE_EXTENSION)
end

local function writeState(stateID, stateData)
    serializeTableAndWriteToFile(stateData, STATE_PATH..stateID..STATE_EXTENSION)
end

local function writeConfigAsDefault(configID)
    local configData = CONFIGS[configID]
    serializeTableAndWriteToFile(configData, DEFAULTS_PATH..configID..CONFIG_EXTENSION)
end

local function writeAllConfigsAsDefaults()
    for configID, _ in pairs(CONFIGS) do
        writeConfigAsDefault(configID)
    end
end

local function readAllConfigs()
    for configID, _ in pairs(CONFIGS) do
        readConfig(configID)
    end
end

local function writeAllConfigs()
    for configID, _ in pairs(CONFIGS) do
        writeConfig(configID)
    end
end

local function resetConfig(configID)
    fs.delete(OVERRIDES_PATH..configID..OVERRIDE_EXTENSION)
    readConfig(configID)
end

_G.ConfigUtil = {
    writeAllConfigsAsDefaults = writeAllConfigsAsDefaults,
    writeAllConfigs = writeAllConfigs,
    readAllConfigs = readAllConfigs,
    writeConfig = writeConfig,
    writeState = writeState,
    readConfig = readConfig,
    readState = readState,
    resetConfig = resetConfig,
}
