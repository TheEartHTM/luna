-- udev.lua - Luna OS Dynamic Device Manager & Hardware Subsystem
local M = {}

local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }

-- Subsystem classifier
local function classifySubsystem(pType, devName, methods)
    pType = (pType or ""):lower()
    devName = (devName or ""):lower()
    local methodSet = {}
    if methods then
        for _, m in ipairs(methods) do methodSet[m] = true end
    end

    if pType:find("speedometer") or pType:find("stressometer") or pType:find("tachometer")
       or methodSet["getSpeed"] or methodSet["getStress"] or methodSet["getTargetSpeed"] then
        return "create"
    elseif pType:find("monitor") or methodSet["setTextScale"] or methodSet["blit"] then
        return "display"
    elseif pType:find("speaker") or methodSet["playAudio"] or methodSet["playSound"] then
        return "sound"
    elseif pType:find("keyboard") or pType == "cee_keyboard" then
        return "input"
    elseif pType:find("mouse") or pType == "cee_mouse" then
        return "input"
    elseif pType:find("modem") or methodSet["transmit"] or methodSet["open"] then
        return "net"
    elseif pType:find("printer") or methodSet["writePage"] then
        return "printer"
    elseif devName:find("sig") or pType == "signal_port" then
        return "signal_port"
    elseif devName:find("hub") or pType == "cee_hub" then
        return "hub"
    elseif devName:find("raid") or devName:find("boot") or pType == "storage" then
        return "block"
    else
        return "peripheral"
    end
end

-- Wrapper metatable to allow direct method access on device object
local function wrapDeviceObject(devInfo)
    local rawWrapped = devInfo.wrap
    local mt = {
        __index = function(t, key)
            if rawWrapped and type(rawWrapped[key]) == "function" then
                return function(...)
                    return rawWrapped[key](...)
                end
            end
            return rawget(t, key)
        end,
        __tostring = function(t)
            return string.format("<udev: %s (%s, %s)>", t.dev, t.subsystem, t.type)
        end
    }
    return setmetatable(devInfo, mt)
end

-- Scan the hardware and return list of all devices
function M.list()
    local devices = {}
    local typeCounts = {}

    local function getNextDevName(base)
        local c = typeCounts[base] or 0
        typeCounts[base] = c + 1
        return string.format("/dev/%s%d", base, c)
    end

    -- 1. Built-in Block Storage
    table.insert(devices, wrapDeviceObject({
        dev = "/dev/raid0",
        name = "raid0",
        type = "storage",
        subsystem = "block",
        bus = "mem",
        status = "ONLINE",
        methods = { "read", "write", "seek" },
        properties = { DEVNAME = "/dev/raid0", SUBSYSTEM = "block", DRIVER = "cee_raid0" }
    }))
    table.insert(devices, wrapDeviceObject({
        dev = "/dev/boot",
        name = "boot",
        type = "storage",
        subsystem = "block",
        bus = "mem",
        status = "ONLINE",
        methods = { "read", "write" },
        properties = { DEVNAME = "/dev/boot", SUBSYSTEM = "block", DRIVER = "vfs_boot" }
    }))

    -- 2. Built-in Terminal & Console Input
    local nativeTerm = term.native and term.native() or term.current()
    table.insert(devices, wrapDeviceObject({
        dev = "/dev/terminal",
        name = "terminal",
        type = "terminal",
        subsystem = "display",
        bus = "builtin",
        status = "ONLINE",
        methods = { "write", "clear", "setCursorPos", "getSize" },
        wrap = nativeTerm,
        properties = { DEVNAME = "/dev/terminal", SUBSYSTEM = "display", DRIVER = "native_console" }
    }))
    table.insert(devices, wrapDeviceObject({
        dev = "/dev/keyboard0",
        name = "keyboard0",
        type = "keyboard",
        subsystem = "input",
        bus = "builtin",
        status = "ONLINE",
        methods = { "key", "char", "paste" },
        properties = { DEVNAME = "/dev/keyboard0", SUBSYSTEM = "input", DRIVER = "chassis_keyboard" }
    }))
    table.insert(devices, wrapDeviceObject({
        dev = "/dev/mouse0",
        name = "mouse0",
        type = "mouse",
        subsystem = "input",
        bus = "builtin",
        status = "ONLINE",
        methods = { "mouse_click", "mouse_up", "mouse_scroll", "mouse_drag" },
        properties = { DEVNAME = "/dev/mouse0", SUBSYSTEM = "input", DRIVER = "native_mouse" }
    }))

    -- 3. CC & Create Peripherals
    if peripheral and peripheral.getNames then
        for _, rawName in ipairs(peripheral.getNames()) do
            local pType = peripheral.getType(rawName) or "unknown"
            local methods = peripheral.getMethods(rawName) or {}
            local wrapped = peripheral.wrap(rawName)
            local isSide = SIDES[rawName] == true
            local bus = isSide and "side" or "network"
            local subsystem = classifySubsystem(pType, rawName, methods)

            local devBase = pType:gsub("[^%w_%-]", "")
            if devBase == "monitor" or devBase == "ceemonitor" then
                devBase = "mon"
            elseif devBase == "speaker" or devBase == "cee_speaker" then
                devBase = "speaker"
            elseif devBase == "keyboard" or devBase == "cee_keyboard" then
                devBase = "keyboard"
            elseif devBase == "mouse" or devBase == "cee_mouse" then
                devBase = "mouse"
            elseif devBase:find("speedometer") then
                devBase = "speedometer"
            elseif devBase:find("stressometer") then
                devBase = "stressometer"
            end

            local devPath = getNextDevName(devBase)
            local devObj = {
                dev = devPath,
                name = rawName,
                type = pType,
                subsystem = subsystem,
                bus = bus,
                status = "ONLINE",
                methods = methods,
                wrap = wrapped,
                properties = {
                    DEVNAME = devPath,
                    NAME = rawName,
                    TYPE = pType,
                    SUBSYSTEM = subsystem,
                    BUS = bus
                }
            }
            table.insert(devices, wrapDeviceObject(devObj))
        end
    end

    -- 4. CEE Signal Port Pins
    if _G.cee then
        local maxPins = (_G.cee.getSignalCount and _G.cee.getSignalCount()) or 11
        for pin = 1, maxPins do
            local pinDev = "/dev/sig" .. pin
            local pinObj = {
                dev = pinDev,
                name = "pin_" .. pin,
                type = "signal_port",
                subsystem = "signal_port",
                bus = "cee",
                pin = pin,
                status = "ONLINE",
                methods = { "send", "read", "isDataPin" },
                wrap = {
                    send = function(packet) return _G.cee.send(pin, packet) end,
                    isDataPin = function() return _G.cee.isDataPin and _G.cee.isDataPin(pin) end,
                    getMonitors = function() return _G.cee.getMonitors and _G.cee.getMonitors(pin) end
                },
                properties = {
                    DEVNAME = pinDev,
                    PIN = pin,
                    SUBSYSTEM = "signal_port",
                    BUS = "cee"
                }
            }
            table.insert(devices, wrapDeviceObject(pinObj))
        end
    end

    return devices
end

-- Query devices matching filter table
function M.find(filter)
    local all = M.list()
    if not filter or next(filter) == nil then
        return all
    end

    local matches = {}
    for _, d in ipairs(all) do
        local ok = true
        if filter.type and d.type ~= filter.type then ok = false end
        if filter.subsystem and d.subsystem ~= filter.subsystem then ok = false end
        if filter.bus and d.bus ~= filter.bus then ok = false end
        if filter.dev and d.dev ~= filter.dev then ok = false end
        if filter.name and d.name ~= filter.name then ok = false end
        if filter.pin and d.pin ~= filter.pin then ok = false end
        if filter.method then
            local foundM = false
            for _, m in ipairs(d.methods or {}) do
                if m == filter.method then foundM = true; break end
            end
            if not foundM then ok = false end
        end
        if ok then table.insert(matches, d) end
    end
    return matches
end

-- Get single device by /dev path or peripheral name
function M.get(query)
    if not query then return nil end
    local all = M.list()
    for _, d in ipairs(all) do
        if d.dev == query or d.name == query or d.dev == ("/dev/" .. query) then
            return d
        end
    end
    return nil
end

return M
