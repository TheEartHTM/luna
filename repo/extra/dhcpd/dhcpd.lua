-- dhcpd.lua - Luna DHCP Server Daemon with Cluster Mesh Sync & MAC-Derived IP Allocation
-- Supports multi-server cluster synchronization over dedicated CEE Signal pins

local CONF_FILE = "/etc/conf/dhcpd.conf"
local LEASES_FILE = "/etc/conf/dhcp_leases.db"

local function getComputerId()
    return os.getComputerID and os.getComputerID() or 0
end

local compId = getComputerId()

local function loadConfig()
    local conf = {
        pin = 1,                 -- Client-facing Signal pin (1..11, or 'fabric')
        cluster_pin = 2,         -- Inter-server Signal pin for DHCP sync (or 'fabric')
        cluster_enabled = true,  -- Enable multi-server synchronization mesh
        server_ip = "10.0.0.1",
        netmask = "255.0.0.0",   -- Class A subnet allows any 10.A.B.C client to talk
        gateway = nil,
        dns = nil,
        pool_start = "10.0.0.10",
        pool_end = "10.0.0.250",
        lease_time = 86400,
        blocked_macs = {},
        blocked_ips = {}
    }
    if fs.exists(CONF_FILE) then
        local h = fs.open(CONF_FILE, "r")
        if h then
            local data = textutils.unserialize(h.readAll())
            h.close()
            if type(data) == "table" then
                for k, v in pairs(data) do conf[k] = v end
            end
        end
    end
    if not conf.gateway or (conf.gateway == "10.0.0.1" and conf.server_ip ~= "10.0.0.1") then
        conf.gateway = conf.server_ip
    end
    if not conf.dns or (conf.dns == "10.0.0.1" and conf.server_ip ~= "10.0.0.1") then
        conf.dns = conf.server_ip
    end
    return conf
end

local function saveConfig(conf)
    if not fs.exists("/etc/conf") then fs.makeDir("/etc/conf") end
    local h = fs.open(CONF_FILE, "w")
    if not h then return false end
    h.write(textutils.serialize(conf))
    h.close()
    return true
end

local function loadLeases()
    if fs.exists(LEASES_FILE) then
        local h = fs.open(LEASES_FILE, "r")
        if h then
            local data = textutils.unserialize(h.readAll())
            h.close()
            if type(data) == "table" then return data end
        end
    end
    return { leases = {}, logs = {}, peers = {} }
end

local function saveLeases(db)
    if not fs.exists("/etc/conf") then fs.makeDir("/etc/conf") end
    local h = fs.open(LEASES_FILE, "w")
    if not h then return false end
    h.write(textutils.serialize(db))
    h.close()
    return true
end

local conf = loadConfig()
local db = loadLeases()
db.peers = db.peers or {}

local tArgs = { ... }

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

local function isPinAvailable(pin)
    local np = normalizePin(pin)
    if np == "fabric" then
        return _G.cee and _G.cee.fabricPeers and true or false
    elseif type(np) == "table" then
        if _G.cee and _G.cee.isDataPin then
            local ok, res = pcall(_G.cee.isDataPin, np)
            return ok
        end
        return false
    else
        local pinNum = tonumber(np) or 1
        if _G.cee then
            local maxPins = _G.cee.getSignalCount and _G.cee.getSignalCount() or 11
            if pinNum < 1 or pinNum > maxPins then return false end
            return true
        end
        local mod = peripheral and peripheral.find("modem")
        return mod and true or false
    end
end

local function formatPin(pin)
    local np = normalizePin(pin)
    local avail = isPinAvailable(pin)
    local statusSuffix = avail and "" or " [OFFLINE/NOT FOUND]"
    if type(np) == "table" then
        return string.format("Data Hub %d (pin %d)%s", np[1], np[2], statusSuffix)
    elseif np == "fabric" then
        return "Server Rack Fabric" .. statusSuffix
    else
        return "Signal " .. tostring(np) .. statusSuffix
    end
end

local function logEvent(tag, msg, srcMac, srcIp)
    local t = os.date and os.date("%H:%M:%S") or tostring(os.time())
    local entry = { time = t, tag = tag, msg = msg, mac = srcMac or "", ip = srcIp or "" }
    table.insert(db.logs, entry)
    while #db.logs > 100 do table.remove(db.logs, 1) end
    saveLeases(db)

    pcall(function()
        if not fs.exists("/var/log") then fs.makeDir("/var/log") end
        local lf = fs.open("/var/log/dhcpd.log", "a")
        if lf then
            lf.write(string.format("[%s] %s > %s\n", t, tag, msg))
            lf.close()
        end
    end)

    if cmd ~= "--daemon" then
        print(string.format("[%s] %s > %s", t, tag, msg))
    end
end

local function isBlocked(mac, ip)
    conf = loadConfig()
    if mac and conf.blocked_macs and conf.blocked_macs[mac] then return true end
    if ip and conf.blocked_ips and conf.blocked_ips[ip] then return true end
    return false
end

-- Generate Deterministic Realistic 4-Octet IP from MAC Address
-- Sequential Dynamic IP Allocator from Pool
local function parseIP(ipStr)
    if not ipStr then return nil end
    local o1, o2, o3, o4 = ipStr:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if o1 and o2 and o3 and o4 then
        return tonumber(o1), tonumber(o2), tonumber(o3), tonumber(o4)
    end
    return nil
end

local function ipToNumber(ipStr)
    local o1, o2, o3, o4 = parseIP(ipStr)
    if not o1 then return 0 end
    return o1 * 16777216 + o2 * 65536 + o3 * 256 + o4
end

local function numberToIP(n)
    local o1 = math.floor(n / 16777216) % 256
    local o2 = math.floor(n / 65536) % 256
    local o3 = math.floor(n / 256) % 256
    local o4 = n % 256
    return string.format("%d.%d.%d.%d", o1, o2, o3, o4)
end

local function allocateIP(mac)
    -- 1. If MAC already holds an assigned lease, keep it
    if db.leases[mac] and db.leases[mac].ip then
        return db.leases[mac].ip
    end

    -- 2. Build map of used IPs
    local used = {}
    for _, l in pairs(db.leases) do
        if l.ip then used[l.ip] = true end
    end
    if conf.server_ip then used[conf.server_ip] = true end
    if conf.gateway then used[conf.gateway] = true end
    if conf.dns then used[conf.dns] = true end
    if db.peers then
        for _, p in pairs(db.peers) do
            if p.ip then used[p.ip] = true end
        end
    end

    -- 3. Determine pool range
    local pStartStr = conf.pool_start or "10.0.0.10"
    local pEndStr = conf.pool_end or "10.0.0.250"
    local startNum = ipToNumber(pStartStr)
    local endNum = ipToNumber(pEndStr)

    if startNum == 0 or endNum == 0 or startNum > endNum then
        startNum = ipToNumber("10.0.0.10")
        endNum = ipToNumber("10.0.0.250")
    end

    -- 4. Find the first available sequential IP in the pool
    for num = startNum, endNum do
        local candidate = numberToIP(num)
        if not used[candidate] and not isBlocked(mac, candidate) then
            return candidate
        end
    end

    return numberToIP(startNum)
end

local function transmitRaw(pin, packet)
    local ok, res = pcall(function()
        local targetPin = normalizePin(pin)
        if targetPin == "fabric" then
            if _G.cee and _G.cee.fabricBroadcast then
                return pcall(_G.cee.fabricBroadcast, packet)
            end
        elseif type(targetPin) == "table" then
            if _G.cee and _G.cee.send then
                local sOk, sRes = pcall(_G.cee.send, targetPin, packet)
                return sOk and sRes
            end
        else
            local pinNum = tonumber(targetPin) or 1
            if _G.cee then
                local maxPins = _G.cee.getSignalCount and _G.cee.getSignalCount() or 11
                if pinNum < 1 or pinNum > maxPins then return false end
                if _G.cee.send then
                    local sOk, sRes = pcall(_G.cee.send, pinNum, packet)
                    return sOk and sRes
                end
            end
        end
        local mod = peripheral and peripheral.find("modem")
        if mod then
            local chan = (targetPin == "fabric") and 65535 or (type(targetPin) == "number" and targetPin or 22)
            pcall(mod.transmit, chan, 22, packet)
            return true
        end
        return false
    end)
    return ok and res or false
end

-- Cluster Mesh Sync Broadcast
local function broadcastCluster(pkt)
    if not conf.cluster_enabled then return end
    if not isPinAvailable(conf.cluster_pin) then return end
    pkt.protocol = "LUNA_DHCP_CLUSTER"
    pkt.sender_server = compId
    pcall(transmitRaw, conf.cluster_pin, pkt)
end

-- CLI subcommands: attach, logs, status
local cmd = tArgs[1]
if cmd == "attach" or cmd == "-f" or cmd == "--follow" then
    print(":: Attaching to Luna DHCP Server (dhcpd) log stream...")
    print(":: (Press 'q', Esc, or Ctrl+T to detach)")
    local lastSeen = 0
    local curDb = loadLeases()
    if curDb.logs then
        local start = math.max(1, #curDb.logs - 15)
        for i = start, #curDb.logs do
            local e = curDb.logs[i]
            print(string.format("[%s] %s > %s", e.time or "", e.tag or "INFO", e.msg or ""))
        end
        lastSeen = #curDb.logs
    end

    local pollTimer = os.startTimer(0.5)
    while true do
        local ev, p1 = os.pullEventRaw()
        if ev == "terminate" then
            print("\n:: Detached from dhcpd.")
            return
        elseif ev == "char" and (p1 == "q" or p1 == "Q") then
            print("\n:: Detached from dhcpd.")
            return
        elseif ev == "key" and (p1 == (keys and keys.q or 16) or p1 == (keys and keys.escape or 1)) then
            print("\n:: Detached from dhcpd.")
            return
        elseif ev == "timer" and p1 == pollTimer then
            local pollDb = loadLeases()
            if pollDb.logs and #pollDb.logs > lastSeen then
                for i = lastSeen + 1, #pollDb.logs do
                    local e = pollDb.logs[i]
                    print(string.format("[%s] %s > %s", e.time or "", e.tag or "INFO", e.msg or ""))
                end
                lastSeen = #pollDb.logs
            end
            pollTimer = os.startTimer(0.5)
        end
    end
    return
end

if cmd == "logs" or cmd == "-l" or cmd == "--logs" then
    local curDb = loadLeases()
    print(":: Luna DHCP Server recent events:")
    if curDb.logs and #curDb.logs > 0 then
        for _, e in ipairs(curDb.logs) do
            print(string.format("[%s] %s > %s", e.time or "", e.tag or "INFO", e.msg or ""))
        end
    else
        print("   (no events logged yet)")
    end
    return
end

if cmd == "status" or cmd == "--status" then
    local curDb = loadLeases()
    print(":: Luna DHCP Server Status:")
    print("   Server IP   : " .. tostring(conf.server_ip))
    print("   Client Pin  : " .. formatPin(conf.pin))
    print("   Cluster Pin : " .. formatPin(conf.cluster_pin))
    print("   IP Pool     : " .. (conf.pool_start or "10.0.0.10") .. " - " .. (conf.pool_end or "10.0.0.250"))
    local count = 0
    if curDb.leases then
        for _ in pairs(curDb.leases) do count = count + 1 end
    end
    print("   Active Leases: " .. count)
    return
end

if cmd == "leases" or cmd == "clients" or cmd == "-a" then
    local curDb = loadLeases()
    print("IP ADDRESS        MAC ADDRESS        HOSTNAME    SERVER")
    print("----------------  -----------------  ----------  ------")
    local count = 0
    if curDb.leases then
        for mac, l in pairs(curDb.leases) do
            count = count + 1
            print(string.format("%-16s  %-17s  %-10s  srv-%s",
                l.ip or "none", mac, l.hostname or "unknown", tostring(l.computer_id or "local")))
        end
    end
    if count == 0 then
        print("(no active leases)")
    end
    return
end

if _G._LUNA_DHCPD_RUNNING and cmd ~= "--daemon" and cmd ~= "--force" then
    print(":: dhcpd is already running in background.")
    print(":: Run 'dhcpd attach' (or 'dhcpd -f') to stream live output.")
    print(":: Run 'dhcpd status' or 'dhcpd logs' to view current state.")
    return
end

-- Ensure DHCP server network interface has its assigned server IP
local net = _G.LunaNet or (fs.exists("/usr/bin/core/net.lua") and dofile("/usr/bin/core/net.lua"))
if net then
    local netConf = net.loadConfig()
    if not netConf.ip or netConf.ip == "" or netConf.ip ~= conf.server_ip then
        netConf.ip = conf.server_ip
        netConf.netmask = conf.netmask or "255.0.0.0"
        net.saveConfig(netConf)
    end
end

print(":: Starting Luna DHCP Server Daemon (dhcpd)...")
print(string.format(":: Client Pin   : %s | Server IP: %s", formatPin(conf.pin), conf.server_ip))
print(string.format(":: Cluster Pin  : %s (Mesh sync %s)", formatPin(conf.cluster_pin), conf.cluster_enabled and "ENABLED" or "DISABLED"))
print(string.format(":: IP Pool      : %s - %s", conf.pool_start or "10.0.0.10", conf.pool_end or "10.0.0.250"))
saveConfig(conf)
saveLeases(db)

-- Solicit database sync from cluster peers upon startup
if conf.cluster_enabled then
    broadcastCluster({ type = "CLUSTER_HELLO", server_ip = conf.server_ip })
end

_G._LUNA_DHCPD_RUNNING = true

local seenPackets = {}
local function isDuplicate(reqId)
    if not reqId then return false end
    local now = os.epoch and os.epoch("utc") or (os.time() * 1000)
    if seenPackets[reqId] and (now - seenPackets[reqId] < 2000) then
        return true
    end
    seenPackets[reqId] = now
    return false
end

local function handlePacket(data)
    if type(data) ~= "table" then return end
    if data.req_id and isDuplicate(data.req_id) then return end

    -- 1. Cluster Synchronization Protocol
    if data.protocol == "LUNA_DHCP_CLUSTER" then
        if data.sender_server == compId then return end -- ignore echo

        local srvId = data.sender_server
        db.peers[srvId] = { ip = data.server_ip or "peer", last_seen = os.time() }

        -- Peer solicited cluster database
        if data.type == "CLUSTER_HELLO" then
            logEvent("CLUSTER", string.format("Detected peer DHCP server ID %d", srvId))
            broadcastCluster({
                type = "CLUSTER_DUMP",
                leases = db.leases,
                blocked_macs = conf.blocked_macs or {},
                blocked_ips = conf.blocked_ips or {}
            })

        -- Received database dump from peer
        elseif data.type == "CLUSTER_DUMP" then
            logEvent("CLUSTER", string.format("Synchronized full database from server ID %d", srvId))
            if data.leases then
                for m, l in pairs(data.leases) do
                    if not db.leases[m] then db.leases[m] = l end
                end
                saveLeases(db)
            end
            if data.blocked_macs then
                for bm, val in pairs(data.blocked_macs) do conf.blocked_macs[bm] = val end
                saveConfig(conf)
            end

        -- Incremental lease sync
        elseif data.type == "SYNC_LEASE" and data.lease then
            local l = data.lease
            db.leases[l.mac] = l
            saveLeases(db)
            logEvent("SYNC", string.format("Synced lease %s -> %s (from srv %d)", l.mac, l.ip, srvId), l.mac, l.ip)

        -- Incremental block sync
        elseif data.type == "SYNC_BLOCK" and data.target then
            conf = loadConfig()
            if data.is_mac then
                conf.blocked_macs = conf.blocked_macs or {}
                if data.blocked then conf.blocked_macs[data.target] = true else conf.blocked_macs[data.target] = nil end
            else
                conf.blocked_ips = conf.blocked_ips or {}
                if data.blocked then conf.blocked_ips[data.target] = true else conf.blocked_ips[data.target] = nil end
            end
            saveConfig(conf)
            logEvent("SYNC", string.format("Synced block state for %s (%s)", data.target, data.blocked and "BLOCKED" or "UNBLOCKED"))

        -- Inter-Server Mesh Packet Routing (Forwarded from another DHCP server)
        elseif data.type == "CLUSTER_ROUTE" and data.packet then
            local pkt = data.packet
            local dIp = data.dst_ip or pkt.dst_ip

            -- If packet is addressed to THIS DHCP server itself (e.g. client on remote server pinging this server)
            if dIp == conf.server_ip or dIp == conf.gateway then
                if pkt.payload and pkt.payload.cmd == "PING" then
                    logEvent("ICMP", string.format("Remote ping from %s -> replying PONG", pkt.src_ip or "net"))
                    local pongPkt = {
                        protocol = "LUNA_NET",
                        type = "DATA",
                        req_id = pkt.req_id,
                        src_ip = conf.server_ip,
                        dst_ip = pkt.src_ip,
                        payload = { ok = true, cmd = "PONG", seq = pkt.payload.seq }
                    }
                    broadcastCluster({
                        type = "CLUSTER_ROUTE",
                        dst_ip = pkt.src_ip,
                        packet = pongPkt
                    })
                end
                return
            end

            local forwarded = false
            for m, l in pairs(db.leases) do
                if l.ip == dIp and (l.origin_server == compId or not l.origin_server) then
                    logEvent("ROUTE", string.format("Cluster Inbound FWD: %s -> %s to local pin", pkt.src_ip or "net", dIp))
                    transmitRaw(conf.pin, pkt)
                    forwarded = true
                    break
                end
            end
            if not forwarded then
                -- Target not strictly in local lease table (static IP or unexpired cache); forward to client pin
                logEvent("ROUTE", string.format("Cluster Inbound FWD: %s -> %s to local pin", pkt.src_ip or "net", dIp))
                transmitRaw(conf.pin, pkt)
            end
        end
        return
    end

    -- 2. L3 Routing, Anti-Spoofing & Packet Forwarder
    if data.protocol == "LUNA_NET" and data.type == "DATA" then
        local sIp = data.src_ip
        local dIp = data.dst_ip
        if not sIp or not dIp then return end

        -- Anti-Spoofing Check: Verify that sender holds a valid DHCP lease, is server, or belongs to local subnet
        local authorized = false
        if sIp == conf.server_ip or sIp == "127.0.0.1" then
            authorized = true
        else
            for m, l in pairs(db.leases) do
                if l.ip == sIp then
                    authorized = true
                    l.rx_packets = (l.rx_packets or 0) + 1
                    l.rx_bytes = (l.rx_bytes or 0) + 128
                    l.last_seen = os.time()
                    saveLeases(db)
                    break
                end
            end
            if not authorized and sIp:sub(1, 3) == "10." and not (conf.blocked_ips and conf.blocked_ips[sIp]) then
                authorized = true
            end
        end

        if not authorized then
            logEvent("DROP", string.format("Unauthorized src_ip %s -> %s (no valid lease)", sIp, dIp))
            return
        end

        -- Check if packet is destined for DHCP server itself
        if dIp == conf.server_ip or dIp == "127.0.0.1" or dIp == conf.gateway then
            if data.payload and data.payload.cmd == "PING" then
                local pongPkt = {
                    protocol = "LUNA_NET",
                    type = "DATA",
                    req_id = data.req_id,
                    src_ip = conf.server_ip,
                    dst_ip = sIp,
                    payload = { ok = true, cmd = "PONG", seq = data.payload.seq }
                }
                transmitRaw(conf.pin, pongPkt)
            end
            return -- processed locally
        end

        -- Check if destination is a local client on this server
        local isLocal = false
        for m, l in pairs(db.leases) do
            if l.ip == dIp and l.origin_server == compId then
                isLocal = true
                break
            end
        end

        if isLocal then
            logEvent("ROUTE", string.format("Local FWD: %s -> %s (port %s)", sIp, dIp, tostring(data.dst_port or 0)))
            transmitRaw(conf.pin, data)
            return
        end

        -- Check if destination is reachable via mesh cluster peer
        if conf.cluster_enabled and conf.cluster_pin then
            logEvent("ROUTE", string.format("Mesh FWD: %s -> %s via cluster pin %s", sIp, dIp, tostring(conf.cluster_pin)))
            broadcastCluster({
                type = "CLUSTER_ROUTE",
                dst_ip = dIp,
                packet = data
            })
            return
        end
        return
    end

    -- 2.5. DNS Query Resolution Protocol (DDNS from leases + /etc/hosts + cluster)
    if data.protocol == "LUNA_DNS" and data.type == "QUERY" then
        local qName = (data.name or ""):lower():match("^%s*(.-)%s*$")
        local respIp = nil

        -- Check server itself
        if qName == "localhost" or qName == "router" or qName == "gateway" or qName == "dns" or qName == conf.server_ip or qName == (conf.hostname or ""):lower() then
            respIp = conf.server_ip
        end

        -- Check peer servers
        if not respIp and db.peers then
            for sId, pInfo in pairs(db.peers) do
                if qName == ("server" .. sId) or qName == ("dhcp" .. sId) then
                    respIp = pInfo.ip
                    break
                end
            end
        end

        -- Check /etc/hosts file if present
        if not respIp and fs.exists("/etc/hosts") then
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
                                if n:lower() == qName then
                                    respIp = ipPart
                                    break
                                end
                            end
                        end
                    end
                    if respIp then break end
                end
                h.close()
            end
        end

        -- Check active DHCP leases (Dynamic DNS)
        if not respIp and db.leases then
            for _, l in pairs(db.leases) do
                if l.hostname and l.hostname:lower() == qName then
                    respIp = l.ip
                    break
                end
            end
        end

        -- Reply to DNS query
        local dnsResp = {
            protocol = "LUNA_DNS",
            type = "RESPONSE",
            name = data.name,
            ip = respIp,
            xid = data.xid
        }
        transmitRaw(conf.pin, dnsResp)
        if respIp then
            logEvent("DNS", string.format("Resolved '%s' -> %s", data.name, respIp))
        end
        return
    end

    -- 3. DHCP Client Requests
    if data.protocol ~= "LUNA_DHCP" then return end

    local mac = data.mac or "unknown"
    local xid = data.xid
    local host = data.hostname or "device"
    local clientCompId = data.sender_id or 0

    -- Check blacklist
    if isBlocked(mac, nil) then
        logEvent("BLOCKED", "Rejected " .. tostring(data.type) .. " from blocked MAC: " .. mac, mac, nil)
        if data.type == "REQUEST" then
            local nak = { protocol = "LUNA_DHCP", type = "NAK", xid = xid, mac = mac, reason = "Host is blacklisted" }
            transmitRaw(conf.pin, nak)
        end
        return
    end

    -- DISCOVER
    if data.type == "DISCOVER" then
        local offeredIp = allocateIP(mac)
        logEvent("DISCOVER", string.format("Request from %s (%s)", mac, host), mac, nil)

        local offer = {
            protocol = "LUNA_DHCP",
            type = "OFFER",
            xid = xid,
            mac = mac,
            offered_ip = offeredIp,
            netmask = conf.netmask or "255.0.0.0",
            gateway = conf.gateway,
            dns = conf.dns,
            lease_time = conf.lease_time,
            server_ip = conf.server_ip,
            server_id = compId
        }

        transmitRaw(conf.pin, offer)
        logEvent("OFFER", string.format("Offered %s to %s", offeredIp, mac), mac, offeredIp)

    -- REQUEST
    elseif data.type == "REQUEST" then
        local reqIp = data.requested_ip or allocateIP(mac)

        if isBlocked(mac, reqIp) then
            logEvent("BLOCKED", string.format("Request for %s rejected (blocked)", reqIp), mac, reqIp)
            local nak = { protocol = "LUNA_DHCP", type = "NAK", xid = xid, mac = mac, reason = "Blocked" }
            transmitRaw(conf.pin, nak)
            return
        end

        local lease = db.leases[mac] or {}
        lease.mac = mac
        lease.ip = reqIp
        lease.hostname = host
        lease.computer_id = clientCompId
        lease.assigned_at = os.time()
        lease.lease_time = conf.lease_time
        lease.last_seen = os.time()
        lease.rx_packets = lease.rx_packets or 0
        lease.rx_bytes = lease.rx_bytes or 0
        lease.status = "ONLINE"
        lease.origin_server = compId
        db.leases[mac] = lease
        saveLeases(db)

        local ack = {
            protocol = "LUNA_DHCP",
            type = "ACK",
            xid = xid,
            mac = mac,
            ip = reqIp,
            netmask = conf.netmask or "255.0.0.0",
            gateway = conf.gateway,
            dns = conf.dns,
            lease_time = conf.lease_time,
            server_ip = conf.server_ip
        }

        transmitRaw(conf.pin, ack)
        logEvent("ACK", string.format("Bound %s -> %s (%s)", mac, reqIp, host), mac, reqIp)

        -- Synchronize lease to peer DHCP servers immediately
        broadcastCluster({
            type = "SYNC_LEASE",
            lease = lease
        })
    end
end

-- Daemon event loop
while _G._LUNA_DHCPD_RUNNING do
    local ev, p1, p2, p3, p4 = os.pullEvent()
    if ev == "cee_message" or ev == "cee_packet" or ev == "cee_fabric_message" or ev == "modem_message" then
        local data = nil
        if type(p3) == "table" and (p3.protocol or p3.payload) then data = p3.protocol and p3 or p3.payload
        elseif type(p1) == "table" and (p1.protocol or p1.payload) then data = p1.protocol and p1 or p1.payload
        elseif type(p2) == "table" and (p2.protocol or p2.payload) then data = p2.protocol and p2 or p2.payload
        elseif type(p4) == "table" and (p4.protocol or p4.payload) then data = p4.protocol and p4 or p4.payload end
        if data then handlePacket(data) end
    elseif ev == "terminate" then
        print(":: dhcpd terminated.")
        break
    end
end
