-- Ender Modem remote-display server.
--
-- The controller still runs beside the reactor and owns every safety/control decision. This
-- module only presents remote monitors as buffered terminal peripherals. A complete screen is
-- sent after Monitor:draw(), while touches travel in the opposite direction.

local state = {
    running = false,
    modemName = nil,
    callbacks = nil,
    clients = {}, -- sender id -> { lastSeen, monitors = { localName -> remoteId }, lastTouchAt, lastTouchKey }
    terminals = {},
    session = nil,
}

local function blankRow(width)
    return {
        text = string.rep(" ", width),
        fg = string.rep(colors.toBlit(colors.white), width),
        bg = string.rep(colors.toBlit(colors.black), width),
    }
end

local function makeBufferedTerminal(sender, localName, width, height, role)
    local cursorX, cursorY = 1, 1
    local foreground, background = colors.white, colors.black
    local cursorBlink, visible, scale = false, true, 0.5
    local rows = {}
    local dirty = true
    local lastFlush = -math.huge
    local lastRows = nil
    local frameSequence = 0

    local terminal = { _remote = true, _remoteRole = role, _clientId = sender }

    local function resetRows()
        rows = {}
        for y = 1, height do rows[y] = blankRow(width) end
        dirty = true
    end

    local function replaceRange(source, startAt, replacement)
        if startAt > #source or startAt + #replacement - 1 < 1 then return source end
        local clippedStart = math.max(1, startAt)
        local clippedEnd = math.min(#source, startAt + #replacement - 1)
        local replacementStart = clippedStart - startAt + 1
        local replacementEnd = replacementStart + clippedEnd - clippedStart
        return source:sub(1, clippedStart - 1)
            .. replacement:sub(replacementStart, replacementEnd)
            .. source:sub(clippedEnd + 1)
    end

    local function writeBlit(text, fg, bg)
        text, fg, bg = tostring(text), tostring(fg), tostring(bg)
        if #text ~= #fg or #text ~= #bg then error("Arguments must be the same length", 2) end
        if cursorY >= 1 and cursorY <= height then
            local row = rows[cursorY]
            row.text = replaceRange(row.text, cursorX, text)
            row.fg = replaceRange(row.fg, cursorX, fg)
            row.bg = replaceRange(row.bg, cursorX, bg)
            dirty = true
        end
        cursorX = cursorX + #text
    end

    function terminal.write(text)
        text = tostring(text)
        writeBlit(text, string.rep(colors.toBlit(foreground), #text),
            string.rep(colors.toBlit(background), #text))
    end
    terminal.blit = writeBlit
    function terminal.clear() resetRows() end
    function terminal.clearLine()
        if cursorY >= 1 and cursorY <= height then rows[cursorY] = blankRow(width); dirty = true end
    end
    function terminal.getCursorPos() return cursorX, cursorY end
    function terminal.setCursorPos(x, y) cursorX, cursorY = math.floor(x), math.floor(y) end
    function terminal.getCursorBlink() return cursorBlink end
    function terminal.setCursorBlink(value) cursorBlink = value == true end
    function terminal.getTextColor() return foreground end
    function terminal.setTextColor(value) foreground = value end
    terminal.getTextColour = terminal.getTextColor
    terminal.setTextColour = terminal.setTextColor
    function terminal.getBackgroundColor() return background end
    function terminal.setBackgroundColor(value) background = value end
    terminal.getBackgroundColour = terminal.getBackgroundColor
    terminal.setBackgroundColour = terminal.setBackgroundColor
    function terminal.getSize() return width, height end
    function terminal.isColor() return true end
    terminal.isColour = terminal.isColor
    function terminal.scroll(lines)
        lines = math.floor(lines)
        if lines > 0 then
            for _ = 1, math.min(lines, height) do table.remove(rows, 1); rows[#rows + 1] = blankRow(width) end
        elseif lines < 0 then
            for _ = 1, math.min(-lines, height) do table.remove(rows); table.insert(rows, 1, blankRow(width)) end
        end
        dirty = true
    end
    function terminal.setTextScale(value) scale = value end
    function terminal.getTextScale() return scale end
    function terminal.setVisible(value) visible = value ~= false end
    function terminal.getPosition() return 1, 1 end
    function terminal.getPaletteColour(colour)
        if colors.getPaletteColour then
            return colors.getPaletteColour(colour)
        end
        return 1, 1, 1
    end
    terminal.getPaletteColor = terminal.getPaletteColour
    function terminal.setPaletteColour(colour, r, g, b) end
    terminal.setPaletteColor = terminal.setPaletteColour
    function terminal.reposition(_, _, newWidth, newHeight)
        if newWidth and newHeight then terminal.resize(newWidth, newHeight) end
    end
    function terminal.resize(newWidth, newHeight)
        newWidth, newHeight = math.max(1, math.floor(newWidth)), math.max(1, math.floor(newHeight))
        if newWidth == width and newHeight == height then return false end
        width, height = newWidth, newHeight
        cursorX, cursorY = 1, 1
        resetRows()
        lastRows = nil
        frameSequence = 0
        dirty = true
        return true
    end
    function terminal.flush(force)
        if not state.running or not visible or not dirty then return end
        local now = os.clock()
        local interval = CONTROL_CONFIG.remoteRefreshSeconds or 0.25
        if not force and now - lastFlush < interval then return end
        local sendFull = lastRows == nil or CONTROL_CONFIG.remoteDeltaFrames == false
        local payloadRows, changed = {}, 0
        for y = 1, height do
            local row = rows[y]
            local packed = { row.text, row.fg, row.bg }
            local previous = lastRows and lastRows[y]
            if sendFull or not previous
                or previous[1] ~= packed[1] or previous[2] ~= packed[2] or previous[3] ~= packed[3] then
                payloadRows[y] = packed
                changed = changed + 1
            end
        end
        if changed == 0 then dirty = false; return end
        frameSequence = frameSequence + 1
        rednet.send(sender, {
            kind = "frame",
            secret = CONTROL_CONFIG.remoteSecret,
            session = state.session,
            seq = frameSequence,
            full = sendFull,
            monitor = localName,
            width = width,
            height = height,
            rows = payloadRows,
        }, CONTROL_CONFIG.remoteProtocol)
        lastRows = {}
        for y = 1, height do
            local row = rows[y]
            lastRows[y] = { row.text, row.fg, row.bg }
        end
        dirty = false
        lastFlush = now
    end

    resetRows()
    return terminal
end

local function findWirelessModem()
    if not rednet then return nil end
    for _, name in ipairs(peripheral.getNames()) do
        local wrapped = peripheral.wrap(name)
        if wrapped and type(wrapped.isWireless) == "function" and wrapped.isWireless() then
            return name
        end
    end
    return nil
end

local function remoteId(sender, localName)
    return ("remote:%d:%s"):format(sender, localName)
end

local function detachClient(sender)
    local client = state.clients[sender]
    if not client then return end
    for _, id in pairs(client.monitors) do
        state.terminals[id] = nil
        if state.callbacks and state.callbacks.detach then state.callbacks.detach(id) end
    end
    state.clients[sender] = nil
end

local function handleHello(sender, message)
    local configuredRole = (CONTROL_CONFIG.remoteClients or {})[sender]
        or (CONTROL_CONFIG.remoteClients or {})[tostring(sender)]
        or CONTROL_CONFIG.remoteDefaultRole or "read-only"
    if configuredRole ~= "control" and configuredRole ~= "read-only" then return end
    local client = state.clients[sender] or { monitors = {}, lastCommandSeq = 0 }
    client.lastSeen = os.clock()
    client.role = configuredRole
    state.clients[sender] = client

    local advertised = {}
    for _, info in ipairs(message.monitors or {}) do
        if type(info.name) == "string" and type(info.width) == "number" and type(info.height) == "number" then
            advertised[info.name] = true
            local id = remoteId(sender, info.name)
            if not client.monitors[info.name] then
                local terminal = makeBufferedTerminal(sender, info.name, info.width, info.height, client.role)
                client.monitors[info.name] = id
                state.terminals[id] = terminal
                state.callbacks.attach(id, terminal)
            else
                local terminal = state.terminals[id]
                if terminal and terminal.resize(info.width, info.height) and state.callbacks.resize then
                    state.callbacks.resize(id)
                end
            end
        end
    end

    for name, id in pairs(client.monitors) do
        if not advertised[name] then
            client.monitors[name] = nil
            state.terminals[id] = nil
            if state.callbacks.detach then state.callbacks.detach(id) end
        end
    end

    rednet.send(sender, {
        kind = "hello_ack",
        secret = CONTROL_CONFIG.remoteSecret,
        session = state.session,
        role = client.role,
        server = os.getComputerID(),
    }, CONTROL_CONFIG.remoteProtocol)
end

local function start(callbacks)
    state.callbacks = callbacks
    if CONTROL_CONFIG.remoteDisplays == false then return false end
    if type(CONTROL_CONFIG.remoteSecret) ~= "string" or CONTROL_CONFIG.remoteSecret == "" then
        print("Remote displays disabled: set remoteSecret in /overrides/control.override.conf")
        return false
    end

    local modemName = findWirelessModem()
    if not modemName then
        print("Remote displays disabled: no wireless/Ender Modem found")
        return false
    end

    state.modemName = modemName
    rednet.open(modemName)
    local ok, err = pcall(rednet.host, CONTROL_CONFIG.remoteProtocol, CONTROL_CONFIG.remoteHost)
    if not ok then
        print("Remote displays disabled: host collision: " .. tostring(err))
        rednet.close(modemName)
        return false
    end
    state.session = tostring(os.getComputerID()) .. ":" .. tostring(os.epoch("utc"))
    state.running = true
    print("Remote display server: " .. CONTROL_CONFIG.remoteHost .. " via " .. modemName)
    return true
end

local function handleMessage(sender, message, protocol)
    if not state.running or protocol ~= CONTROL_CONFIG.remoteProtocol or type(message) ~= "table" then return end
    if message.secret ~= CONTROL_CONFIG.remoteSecret then return end

    if (message.kind == "hello" or message.kind == "discover")
        and (message.requestedHost == nil or message.requestedHost == CONTROL_CONFIG.remoteHost) then
        handleHello(sender, message)
    elseif message.kind == "heartbeat" then
        if state.clients[sender] then state.clients[sender].lastSeen = os.clock() end
    elseif message.kind == "touch" and type(message.monitor) == "string" then
        local client = state.clients[sender]
        local id = client and client.monitors[message.monitor]
        local sequence = tonumber(message.commandSeq) or 0
        if id and client.role == "control" and message.session == state.session
            and sequence > (client.lastCommandSeq or 0)
            and type(message.x) == "number" and type(message.y) == "number" then
            local touchKey = message.monitor .. ":" .. message.x .. ":" .. message.y
            local now = os.clock()
            if client.lastTouchKey == touchKey and now - (client.lastTouchAt or -math.huge) < 0.5 then
                client.lastCommandSeq = sequence
                return
            end
            client.lastTouchKey = touchKey
            client.lastTouchAt = now
            client.lastSeen = now
            client.lastCommandSeq = sequence
            state.callbacks.touch(id, message.x, message.y, { clientId = sender, role = client.role })
        end
    end
end

local function update()
    if not state.running then return end
    local now = os.clock()
    local timeout = CONTROL_CONFIG.remoteClientTimeoutSeconds or 15
    local expired = {}
    for sender, client in pairs(state.clients) do
        if now - client.lastSeen > timeout then expired[#expired + 1] = sender end
    end
    for _, sender in ipairs(expired) do detachClient(sender) end
end

_G.RemoteDisplayServer = {
    start = start,
    handleMessage = handleMessage,
    update = update,
    _state = state,
}
