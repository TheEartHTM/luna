-- net.lua - Luna OS Network Stack for Create: Computer Energetics (CEE)
local M = {}

local CONF_FILE = "/etc/conf/network.conf"

if not _G._LUNA_NET_STATS then
    _G._LUNA_NET_STATS = {
        rx_packets = 0,
        rx_bytes = 0,
        tx_packets = 0,
        tx_bytes = 0
    }
end

function M.getStats()
    return _G._LUNA_NET_STATS
end

function M.trackTX(bytes)
    _G._LUNA_NET_STATS.tx_packets = _G._LUNA_NET_STATS.tx_packets + 1
    _G._LUNA_NET_STATS.tx_bytes = _G._LUNA_NET_STATS.tx_bytes + (bytes or 64)
end

function M.trackRX(bytes)
    _G._LUNA_NET_STATS.rx_packets = _G._LUNA_NET_STATS.rx_packets + 1
    _G._LUNA_NET_STATS.rx_bytes = _G._LUNA_NET_STATS.rx_bytes + (bytes or 64)
end

local function getComputerId()
    return os.getComputerID and os.getComputerID() or 0
end

local function getMacAddress(id)
    id = id or getComputerId()
    local h = (id * 1664525 + 1013904223) % 4294967296
    local function nextByte()
        h = (h * 1664525 + 1013904223) % 4294967296
        return math.floor(h / 16777216) % 256
    end

    local b1 = bit32 and bit32.bor(bit32.band(nextByte(), 0xFE), 0x02) or (math.floor(nextByte() / 4) * 4 + 2)
    local b2 = nextByte()
    local b3 = nextByte()
    local b4 = nextByte()
    local b5 = nextByte()
    local b6 = nextByte()

    return string.format("%02x:%02x:%02x:%02x:%02x:%02x", b1, b2, b3, b4, b5, b6)
end

function M.getMAC()
    local conf = M.loadConfig()
    return conf.mac or getMacAddress()
end

function M.loadConfig()
    local conf = {
        mac = getMacAddress(),
        ip = nil, -- Unconfigured until DHCP or static assignment
        netmask = nil,
        gateway = nil,
        dns = nil,
        pin = 1, -- CEE signal pin number (1..11) or "fabric"
        hostname = "luna"
    }
    if fs.exists(CONF_FILE) then
        local h = fs.open(CONF_FILE, "r")
        if h then
            local content = h.readAll()
            h.close()
            local ok, data = pcall(textutils.unserialize, content)
            if ok and type(data) == "table" then
                for k, v in pairs(data) do conf[k] = v end
            end
        end
    end
    -- Ensure numeric pin if not "fabric"
    if conf.pin ~= "fabric" and tonumber(conf.pin) then
        conf.pin = tonumber(conf.pin)
    end
    return conf
end

function M.saveConfig(conf)
    if not fs.exists("/etc/conf") then fs.makeDir("/etc/conf") end
    local h = fs.open(CONF_FILE, "w")
    if not h then return false end
    h.write(textutils.serialize(conf))
    h.close()
    return true
end

local function normalizePin(pin)
    if type(pin) == "table" then return pin end
    if type(pin) == "number" then return pin end
    if type(pin) == "string" then
        if pin == "fabric" then return "fabric" end
        local h, p = pin:match("^[hH]?[uU]?[bB]?[_%-:]?(%d+)[:%.](%d+)$")
        if h and p then
            return { tonumber(h), tonumber(p) }
        end
        return tonumber(pin) or 1
    end
    return 1
end

local function formatPin(pin)
    local np = normalizePin(pin)
    if type(np) == "table" then
        return string.format("Data Hub %d (pin %d)", np[1], np[2])
    elseif np == "fabric" then
        return "Server Rack Fabric"
    else
        return "Signal " .. tostring(np)
    end
end

-- Check hardware pin status in CEE
function M.checkPinStatus(overridePin)
    local conf = M.loadConfig()
    local pin = overridePin or conf.pin or 1

    if pin == "fabric" then
        if _G.cee and _G.cee.fabricPeers then
            local peers = _G.cee.fabricPeers()
            return true, "Server Rack Fabric (" .. #(peers or {}) .. " peers)"
        end
        return false, "Fabric bus offline (not in server rack)"
    end

    local np = normalizePin(pin)
    if type(np) == "table" then
        if _G.cee then
            local isData = _G.cee.isDataPin and _G.cee.isDataPin(np)
            return true, string.format("Data Hub %d Pin %d (%s)", np[1], np[2], isData and "connected [data cable]" or "active")
        end
        return false, "Data Hub requires CEE interface"
    end

    local pinNum = tonumber(np) or 1
    if _G.cee then
        -- Check if pin is within valid CEE range
        local maxPins = _G.cee.getSignalCount and _G.cee.getSignalCount() or 11
        if pinNum < 1 or pinNum > maxPins then
            return false, "Invalid Signal Pin " .. pinNum .. " (valid: 1.." .. maxPins .. ")"
        end

        local isData = _G.cee.isDataPin and _G.cee.isDataPin(pinNum)
        if isData then
            return true, "Signal " .. pinNum .. " (connected [data cable])"
        else
            return true, "Signal " .. pinNum .. " (active)"
        end
    end

    -- Fallback for CC modem if testing outside CEE
    local mod = peripheral and peripheral.find("modem")
    if mod then
        return true, "Modem peripheral (emulation mode)"
    end

    return false, "No CEE Signal Pin or network cable connected"
end

local arpCache = {}

-- Send a low-level packet over CEE pin or fabric
local function transmitRaw(pin, packet)
    local serialized = textutils.serialize(packet)
    local bytes = #serialized
    local np = normalizePin(pin)

    if np == "fabric" then
        if _G.cee and _G.cee.fabricBroadcast then
            _G.cee.fabricBroadcast(packet)
            M.trackTX(bytes)
            return true
        end
    else
        if _G.cee and _G.cee.send then
            _G.cee.send(np, packet)
            M.trackTX(bytes)
            return true
        end
    end

    -- Fallback to CC modem if present
    local mod = peripheral and peripheral.find("modem")
    if mod then
        local chan = (np == "fabric") and 65535 or (type(np) == "number" and np or 22)
        mod.transmit(chan, 22, packet)
        M.trackTX(bytes)
        return true
    end

    return false, "No CEE hardware found"
end

local dnsCache = {}

-- Resolve Hostname to IP via local /etc/hosts or network DNS query
function M.resolveHost(target, timeout, overridePin)
    if not target or target == "" then return nil end

    -- 1. If target is already a valid IPv4 address, return as-is
    if target:match("^%d+%.%d+%.%d+%.%d+$") then
        return target
    end

    local cleanTarget = target:lower():match("^%s*(.-)%s*$")
    if cleanTarget == "localhost" or cleanTarget == "127.0.0.1" then
        return "127.0.0.1"
    end

    -- 2. Check local DNS cache
    if dnsCache[cleanTarget] then
        return dnsCache[cleanTarget]
    end

    -- 3. Check local /etc/hosts
    if fs.exists("/etc/hosts") then
        local h = fs.open("/etc/hosts", "r")
        if h then
            while true do
                local line = h.readLine()
                if not line then break end
                line = line:match("^%s*(.-)%s*$")
                if line ~= "" and line:sub(1, 1) ~= "#" then
                    local ipPart, namesPart = line:match("^(%S+)%s+(.+)$")
                    if ipPart and namesPart then
                        for n in namesPart:gmatch("%S+") do
                            if n:lower() == cleanTarget then
                                h.close()
                                dnsCache[cleanTarget] = ipPart
                                return ipPart
                            end
                        end
                    end
                end
            end
            h.close()
        end
    end

    -- 4. Send DNS query to network
    local conf = M.loadConfig()
    local pin = overridePin or conf.pin or 1
    local xid = math.random(100000, 999999)
    local queryPkt = {
        protocol = "LUNA_DNS",
        type = "QUERY",
        name = cleanTarget,
        xid = xid,
        sender_id = getComputerId()
    }

    transmitRaw(pin, queryPkt)

    local timer = os.startTimer(timeout or 1.2)
    while true do
        local ev, p1, p2, p3 = os.pullEvent()
        if ev == "timer" and p1 == timer then
            break
        elseif (ev == "cee_message" or ev == "cee_fabric_message" or ev == "modem_message") then
            local data = (ev == "cee_message") and p3 or ((ev == "cee_fabric_message") and p2 or p3)
            if type(data) == "table" and data.protocol == "LUNA_DNS" and data.type == "RESPONSE" and data.xid == xid then
                if data.ip and data.ip ~= "" then
                    dnsCache[cleanTarget] = data.ip
                    M.trackRX(#textutils.serialize(data))
                    return data.ip
                else
                    return nil
                end
            end
        end
    end

    return nil
end

-- Resolve IP via CEE ARP broadcast
function M.resolve(targetIP, pin, timeout)
    targetIP = M.resolveHost(targetIP, timeout, pin) or targetIP
    if arpCache[targetIP] then return arpCache[targetIP] end

    local conf = M.loadConfig()
    if targetIP == conf.ip or targetIP == "127.0.1" or targetIP == "localhost" then
        return getComputerId()
    end

    local candidateId = targetIP:match("^10%.0%.(%d+)$")
    if candidateId then candidateId = tonumber(candidateId) end

    local reqId = math.random(100000, 999999)
    local arpPacket = {
        protocol = "LUNA_NET",
        type = "ARP_REQ",
        req_id = reqId,
        target_ip = targetIP,
        sender_ip = conf.ip,
        sender_id = getComputerId()
    }

    transmitRaw(pin or conf.pin, arpPacket)

    local timer = os.startTimer(timeout or 0.6)
    while true do
        local ev, p1, p2, p3 = os.pullEvent()
        if ev == "timer" and p1 == timer then
            break
        elseif (ev == "cee_message" or ev == "cee_fabric_message" or ev == "modem_message") then
            local data = (ev == "cee_message") and p3 or ((ev == "cee_fabric_message") and p2 or p3)
            if type(data) == "table" and data.protocol == "LUNA_NET" and data.type == "ARP_REP" then
                if data.ip == targetIP then
                    arpCache[targetIP] = data.sender_id
                    M.trackRX(#textutils.serialize(data))
                    return data.sender_id
                end
            end
        end
    end

    return candidateId or 0
end

-- Send packet with response expectation
function M.request(targetIP, port, payload, timeout, overridePin)
    local conf = M.loadConfig()
    local pin = overridePin or conf.pin or 1

    local isConnected, statusMsg = M.checkPinStatus(pin)
    if not isConnected then
        return nil, "Network down on pin " .. tostring(pin) .. " (" .. statusMsg .. ")"
    end

    local reqId = tostring(math.random(100000, 999999))
    local packet = {
        protocol = "LUNA_NET",
        type = "DATA",
        req_id = reqId,
        src_ip = conf.ip,
        dst_ip = targetIP,
        dst_port = port,
        sender_id = getComputerId(),
        payload = payload
    }

    local ok, err = transmitRaw(pin, packet)
    if not ok then return nil, err end

    local timer = os.startTimer(timeout or 3.0)
    while true do
        local ev, p1, p2, p3, p4 = os.pullEvent()
        if ev == "timer" and p1 == timer then
            return nil, "Connection timed out (no response from " .. targetIP .. ":" .. port .. " on pin " .. tostring(pin) .. ")"
        elseif ev == "cee_message" or ev == "cee_packet" or ev == "cee_fabric_message" or ev == "modem_message" then
            local data = nil
            if type(p3) == "table" and (p3.protocol or p3.payload) then data = p3.protocol and p3 or p3.payload
            elseif type(p1) == "table" and (p1.protocol or p1.payload) then data = p1.protocol and p1 or p1.payload
            elseif type(p2) == "table" and (p2.protocol or p2.payload) then data = p2.protocol and p2 or p2.payload
            elseif type(p4) == "table" then data = p4.protocol and p4 or p4.payload end

            if type(data) == "table" and data.protocol == "LUNA_NET" and (data.type == "DATA" or data.type == "RESPONSE") then
                if tostring(data.req_id) == tostring(reqId) and data.payload ~= nil then
                    M.trackRX(#textutils.serialize(data))
                    return data.payload, nil
                end
            end
        end
    end
end

-- Send one-way packet
function M.send(targetIP, port, payload, overridePin, reqId)
    local conf = M.loadConfig()
    local pin = overridePin or conf.pin or 1

    local packet = {
        protocol = "LUNA_NET",
        type = "DATA",
        req_id = reqId,
        src_ip = conf.ip,
        dst_ip = targetIP,
        dst_port = port,
        sender_id = getComputerId(),
        payload = payload
    }

    return transmitRaw(pin, packet)
end


-- DHCP Client implementation
function M.dhcpClient(timeout, overridePin)
    local conf = M.loadConfig()
    local pin = overridePin or conf.pin or 1
    local isUp, statusMsg = M.checkPinStatus(pin)
    if not isUp then return false, "Interface is down (" .. statusMsg .. ")" end

    local mac = conf.mac or getMacAddress()
    local xid = math.random(100000, 999999)

    -- Step 1: DISCOVER
    local discoverPkt = {
        protocol = "LUNA_DHCP",
        type = "DISCOVER",
        xid = xid,
        mac = mac,
        hostname = conf.hostname or "luna",
        sender_id = getComputerId()
    }

    transmitRaw(pin, discoverPkt)

    local timer = os.startTimer(timeout or 4.0)
    local offer = nil

    while true do
        local ev, p1, p2, p3, p4 = os.pullEvent()
        if ev == "timer" and p1 == timer then
            return false, "DHCP discover timed out (no DHCP server on " .. tostring(pin) .. ")"
        elseif ev == "cee_message" or ev == "cee_packet" or ev == "cee_fabric_message" or ev == "modem_message" then
            local data = nil
            if type(p3) == "table" and p3.protocol then data = p3
            elseif type(p1) == "table" and p1.protocol then data = p1
            elseif type(p2) == "table" and p2.protocol then data = p2
            elseif type(p4) == "table" then data = p4.protocol and p4 or p4.payload end

            if type(data) == "table" and data.protocol == "LUNA_DHCP" and data.type == "OFFER" and tostring(data.xid) == tostring(xid) then
                if not data.mac or data.mac:lower() == mac:lower() then
                    offer = data
                    M.trackRX(#textutils.serialize(data))
                    break
                end
            end
        end
    end

    if not offer or not offer.offered_ip then
        return false, "Invalid DHCP offer"
    end

    -- Step 2: REQUEST
    local reqPkt = {
        protocol = "LUNA_DHCP",
        type = "REQUEST",
        xid = xid,
        mac = mac,
        requested_ip = offer.offered_ip,
        server_id = offer.server_id,
        sender_id = getComputerId()
    }

    transmitRaw(pin, reqPkt)

    timer = os.startTimer(timeout or 5.0)
    while true do
        local ev, p1, p2, p3, p4 = os.pullEvent()
        if ev == "timer" and p1 == timer then
            return false, "DHCP request timed out"
        elseif ev == "cee_message" or ev == "cee_packet" or ev == "cee_fabric_message" or ev == "modem_message" then
            local data = nil
            if type(p3) == "table" and p3.protocol then data = p3
            elseif type(p1) == "table" and p1.protocol then data = p1
            elseif type(p2) == "table" and p2.protocol then data = p2
            elseif type(p4) == "table" then data = p4.protocol and p4 or p4.payload end

            if type(data) == "table" and data.protocol == "LUNA_DHCP" and tostring(data.xid) == tostring(xid) then
                if data.type == "ACK" and (not data.mac or data.mac:lower() == mac:lower()) then
                    M.trackRX(#textutils.serialize(data))
                    -- Apply lease
                    conf.ip = offer.offered_ip
                    conf.netmask = offer.netmask or "255.255.255.0"
                    conf.gateway = offer.gateway
                    conf.dns = offer.dns
                    conf.lease_time = offer.lease_time
                    conf.server_ip = offer.server_ip
                    M.saveConfig(conf)
                    return true, conf
                elseif data.type == "NAK" and data.mac == mac then
                    return false, "DHCP NAK received from server"
                end
            end
        end
    end
end

_G.LunaNet = M
return M
