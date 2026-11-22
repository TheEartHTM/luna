-- lsdev - List hardware devices, peripherals, and signal ports
local term = term
local colors = colors
local isColor = term.isColor and term.isColor()

local args = { ... }
local verbose = false
local filterType = nil

for _, a in ipairs(args) do
    if a == "-h" or a == "--help" then
        print("usage: lsdev [options]")
        print("options:")
        print("  -v, --verbose    show device capabilities and exported methods")
        print("  -s, --sound      show only audio and speaker devices")
        print("  -d, --display    show only monitors and displays")
        print("  -k, --keyboard   show only keyboards and input devices")
        print("  -c, --cee        show only CEE Signal Port and energy bus pins")
        print("  -n, --net        show only modems and network devices")
        print("  -h, --help       show this help message")
        return
    elseif a == "-v" or a == "--verbose" then
        verbose = true
    elseif a == "-s" or a == "--sound" or a == "--audio" then
        filterType = "speaker"
    elseif a == "-d" or a == "--display" or a == "--monitor" then
        filterType = "display"
    elseif a == "-k" or a == "--keyboard" or a == "--input" then
        filterType = "keyboard"
    elseif a == "-c" or a == "--cee" or a == "--signal" then
        filterType = "signal_port"
    elseif a == "-n" or a == "--net" or a == "--network" then
        filterType = "modem"
    end
end

-- Query devices via Kernel Syscall SYS.DEVLIST
local devices = nil
if _G.kernel and _G.kernel.syscall then
    devices = _G.kernel.syscall("devlist")
elseif _G.syscall then
    devices = _G.syscall("devlist")
end

-- Fallback to direct detection if kernel syscall unavailable
if not devices then
    devices = {}
    table.insert(devices, { dev = "/dev/raid0", bus = "mem", type = "storage", interface = "RAID-0 Block", status = "ONLINE" })
    table.insert(devices, { dev = "/dev/boot", bus = "mem", type = "storage", interface = "/mem/boot", status = "ONLINE" })
    local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }
    local typeCounts = {}
    if peripheral and peripheral.getNames then
        for _, name in ipairs(peripheral.getNames()) do
            local pType = peripheral.getType(name) or "device"
            typeCounts[pType] = (typeCounts[pType] or 0) + 1
            local idx = typeCounts[pType] - 1
            local devName = pType .. idx
            if pType == "monitor" or pType == "ceemonitor" then devName = "mon" .. idx
            elseif pType == "speaker" or pType == "cee_speaker" then devName = "speaker" .. idx
            elseif pType == "printer" then devName = "lp" .. idx
            elseif pType == "modem" then devName = "modem" .. idx
            elseif pType == "cee_radio" then devName = "radio" .. idx
            elseif pType == "cee_data_scriber" then devName = "scriber" .. idx
            elseif pType == "cee_hub" then devName = "hub" .. idx
            end

            table.insert(devices, {
                dev = "/dev/" .. devName,
                bus = SIDES[name] and "side" or "network",
                type = pType,
                interface = name,
                status = "READY",
                methods = peripheral.getMethods(name) or {}
            })
        end
    end
    if _G.cee then
        local maxPins = (_G.cee.getSignalCount and _G.cee.getSignalCount()) or 11
        for pin = 1, maxPins do
            table.insert(devices, {
                dev = "/dev/sig" .. pin,
                bus = "cee",
                type = "signal_port",
                interface = "pin_" .. pin,
                status = "ONLINE",
                methods = { "read", "write", "send" }
            })
        end

        -- CEE Data Hubs
        if _G.cee.listHubs then
            local ok, hubs = pcall(_G.cee.listHubs)
            if ok and type(hubs) == "table" then
                for idx, hub in ipairs(hubs) do
                    local hId = (type(hub) == "table" and (hub.id or hub.hubId)) or tostring(hub)
                    local status = "ONLINE"
                    if type(hub) == "table" and hub.isPowered == false then
                        status = "NO_POWER"
                    end
                    table.insert(devices, {
                        dev = "/dev/hub" .. (idx - 1),
                        bus = "cee",
                        type = "data_hub",
                        interface = "hub_" .. tostring(hId),
                        status = status,
                        methods = { "claimHubPin", "releaseHubPin", "hubSendPeers", "listHubClaims", "hubInfo" }
                    })
                end
            end
        end
    end
end

local filtered = {}
for _, d in ipairs(devices) do
    local match = true
    if filterType then
        if filterType == "display" then
            match = (d.type == "monitor" or d.type == "ceemonitor" or d.type == "display")
        elseif filterType == "speaker" then
            match = (d.type == "speaker" or d.type == "cee_speaker" or d.type == "sound" or d.type == "audio")
        elseif filterType == "keyboard" then
            match = (d.type == "keyboard" or d.type == "cee_keyboard" or d.type == "mouse" or d.type == "cee_mouse" or d.type == "input")
        else
            match = (d.type == filterType)
        end
    end
    if match then
        table.insert(filtered, d)
    end
end

-- Dynamically compute column widths so labels NEVER shift or collide
local wDev  = #"DEVICE"
local wBus  = #"BUS"
local wType = #"TYPE"
local wIf   = #"INTERFACE"

for _, d in ipairs(filtered) do
    if #d.dev > wDev then wDev = #d.dev end
    local bLen = #(d.bus or "unknown")
    if bLen > wBus then wBus = bLen end
    local tLen = #(d.type or "device")
    if tLen > wType then wType = tLen end
    local iLen = #(d.interface or "direct")
    if iLen > wIf then wIf = iLen end
end

-- Format with 2 spaces between columns
local fmtHdr = string.format("%%-%ds  %%-%ds  %%-%ds  %%-%ds  %%s", wDev, wBus, wType, wIf)

if isColor then term.setTextColor(colors.cyan or colors.lightBlue) end
print(string.format(fmtHdr, "DEVICE", "BUS", "TYPE", "INTERFACE", "STATUS"))
if isColor then term.setTextColor(colors.white) end

local function getTypeColor(t)
    if not isColor then return colors.white end
    if t == "storage" then return colors.yellow
    elseif t == "monitor" or t == "ceemonitor" or t == "display" then return colors.cyan
    elseif t == "keyboard" or t == "cee_keyboard" then return colors.yellow
    elseif t == "mouse" or t == "cee_mouse" then return colors.lightGray
    elseif t == "speaker" or t == "cee_speaker" or t == "sound" or t == "audio" then return colors.magenta or colors.purple
    elseif t == "printer" then return colors.green or colors.lime
    elseif t == "signal_port" then return colors.lightBlue
    elseif t == "data_hub" or t == "hub" then return colors.lime or colors.green
    elseif t == "modem" or t == "cee_radio" then return colors.orange
    else return colors.white end
end

for _, d in ipairs(filtered) do
    if isColor then term.setTextColor(getTypeColor(d.type)) end
    io.write(string.format("%-" .. wDev .. "s  ", d.dev))
    if isColor then term.setTextColor(colors.white) end
    io.write(string.format("%-" .. wBus .. "s  %-" .. wType .. "s  %-" .. wIf .. "s  ",
        d.bus or "unknown", d.type or "device", d.interface or "direct"))

    if isColor then
        local s = d.status or "READY"
        if s:find("ONLINE") then term.setTextColor(colors.green or colors.lime)
        elseif s:find("READY") then term.setTextColor(colors.lightBlue or colors.cyan)
        else term.setTextColor(colors.yellow) end
        io.write(s .. "\n")
        term.setTextColor(colors.white)
    else
        io.write((d.status or "READY") .. "\n")
    end

    if verbose and d.methods and #d.methods > 0 then
        if isColor then term.setTextColor(colors.lightGray or colors.gray) end
        print(string.format("  -> Methods: %s", table.concat(d.methods, ", ")))
        if isColor then term.setTextColor(colors.white) end
    end
end

if isColor then term.setTextColor(colors.gray or colors.lightGray) end
print(string.format("\nTotal devices detected: %d", #filtered))
if isColor then term.setTextColor(colors.white) end
