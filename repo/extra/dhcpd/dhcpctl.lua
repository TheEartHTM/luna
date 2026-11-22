-- dhcpctl.lua - Luna DHCP Monitor, Control & Cluster Management
local term = term
local colors = colors
local isColor = term.isColor and term.isColor()

local CONF_FILE = "/etc/conf/dhcpd.conf"
local LEASES_FILE = "/etc/conf/dhcp_leases.db"

local function setColor(c)
    if isColor and c then term.setTextColor(c) end
end

local function resetColor()
    if isColor then term.setTextColor(colors.white) end
end

local function loadConfig()
    if fs.exists(CONF_FILE) then
        local h = fs.open(CONF_FILE, "r")
        if h then
            local data = textutils.unserialize(h.readAll())
            h.close()
            if type(data) == "table" then return data end
        end
    end
    return { pin = 1, cluster_pin = 2, cluster_enabled = true, server_ip = "10.0.0.1", netmask = "255.0.0.0", blocked_macs = {}, blocked_ips = {} }
end

local function saveConfig(c)
    local h = fs.open(CONF_FILE, "w")
    if not h then return false end
    h.write(textutils.serialize(c))
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

local function broadcastBlockSync(target, isMac, blocked)
    local conf = loadConfig()
    if not conf.cluster_enabled then return end
    local pkt = {
        protocol = "LUNA_DHCP_CLUSTER",
        type = "SYNC_BLOCK",
        target = target,
        is_mac = isMac,
        blocked = blocked,
        sender_server = os.getComputerID and os.getComputerID() or 0
    }
    local pin = conf.cluster_pin or 2
    if _G.cee and _G.cee.send then
        _G.cee.send(tonumber(pin) or 2, pkt)
    end
end

local args = { ... }

-- CLI command handlers
if args[1] == "block" and args[2] then
    local target = args[2]
    local conf = loadConfig()
    conf.blocked_macs = conf.blocked_macs or {}
    conf.blocked_ips = conf.blocked_ips or {}
    local isMac = target:find(":") ~= nil
    if isMac then conf.blocked_macs[target] = true else conf.blocked_ips[target] = true end
    saveConfig(conf)
    broadcastBlockSync(target, isMac, true)
    print(":: Blocked " .. (isMac and "MAC" or "IP") .. ": " .. target .. " (synchronized across cluster)")
    return
elseif args[1] == "unblock" and args[2] then
    local target = args[2]
    local conf = loadConfig()
    conf.blocked_macs = conf.blocked_macs or {}
    conf.blocked_ips = conf.blocked_ips or {}
    local isMac = target:find(":") ~= nil
    if isMac then conf.blocked_macs[target] = nil else conf.blocked_ips[target] = nil end
    saveConfig(conf)
    broadcastBlockSync(target, isMac, false)
    print(":: Unblocked " .. (isMac and "MAC" or "IP") .. ": " .. target .. " (synchronized across cluster)")
    return
elseif args[1] == "leases" then
    local db = loadLeases()
    print("IP ADDRESS        MAC ADDRESS        HOSTNAME    STATUS   PACKETS   SERVER")
    print("----------------  -----------------  ----------  -------  --------  ------")
    for mac, l in pairs(db.leases) do
        print(string.format("%-16s  %-17s  %-10s  %-7s  %-8s  srv-%s",
            l.ip or "none", mac, l.hostname or "unknown", l.status or "READY", tostring(l.rx_packets or 0), tostring(l.origin_server or "local")))
    end
    return
elseif args[1] == "-h" or args[1] == "--help" then
    print("usage: dhcpctl [command]")
    print("commands:")
    print("  (no args)             launch interactive TUI monitor")
    print("  leases                list current dynamic leases")
    print("  block <mac|ip>        block device from obtaining IP or network access")
    print("  unblock <mac|ip>      remove device from blacklist")
    return
end

-- Interactive Dashboard Mode
local running = true

local function drawDashboard()
    local conf = loadConfig()
    local db = loadLeases()
    local w, h = term.getSize()

    term.clear()
    term.setCursorPos(1, 1)

    -- Header
    setColor(colors.cyan)
    print(string.format(" Luna DHCP Server Monitor [Client: Sig %s | Cluster: Sig %s]", tostring(conf.pin), tostring(conf.cluster_pin)))
    local peerList = {}
    if db.peers then
        for pid, _ in pairs(db.peers) do table.insert(peerList, "srv-" .. pid) end
    end
    local clusterStr = (#peerList > 0) and table.concat(peerList, ", ") or "standalone"
    print(string.format(" IP Pool: %s - %s | Cluster: %s", conf.pool_start or "10.0.0.10", conf.pool_end or "10.0.0.250", clusterStr))
    resetColor()
    print(string.rep("-", w))

    -- Leases table
    setColor(colors.yellow)
    print(" ACTIVE LEASES & CLIENTS:")
    resetColor()
    setColor(colors.lightGray or colors.gray)
    print(string.format(" %-15s %-17s %-10s %-7s %s", "IP", "MAC", "HOST", "STATUS", "TRAFFIC"))
    resetColor()

    local count = 0
    for mac, l in pairs(db.leases) do
        count = count + 1
        local isBlk = (conf.blocked_macs and conf.blocked_macs[mac]) or (conf.blocked_ips and conf.blocked_ips[l.ip])
        local stColor = isBlk and colors.red or (l.status == "ONLINE" and colors.green or colors.white)
        setColor(stColor)
        local statusText = isBlk and "BLOCKED" or (l.status or "ACTIVE")
        local bytesStr = (l.rx_bytes and l.rx_bytes > 1024) and string.format("%.1f KB", l.rx_bytes / 1024) or string.format("%d B", l.rx_bytes or 0)
        local originStr = l.origin_server and (" [srv-" .. l.origin_server .. "]") or ""
        print(string.format(" %-15s %-17s %-10s %-7s %s (%d pkts)%s",
            l.ip or "none", mac, l.hostname or "device", statusText, bytesStr, l.rx_packets or 0, originStr))
    end
    if count == 0 then
        setColor(colors.gray or colors.lightGray)
        print("  (No active leases. Waiting for DHCP requests...)")
    end
    resetColor()
    print()

    -- Live Traffic Logs
    setColor(colors.yellow)
    print(" RECENT TRAFFIC & CONNECTION EVENTS:")
    resetColor()

    local logs = db.logs or {}
    local maxLogs = math.max(1, h - 14)
    local startIdx = math.max(1, #logs - maxLogs + 1)
    for i = startIdx, #logs do
        local entry = logs[i]
        local tagColor = colors.cyan
        if entry.tag == "DISCOVER" then tagColor = colors.lightBlue
        elseif entry.tag == "OFFER" then tagColor = colors.yellow
        elseif entry.tag == "ACK" then tagColor = colors.green
        elseif entry.tag == "BLOCKED" then tagColor = colors.red
        elseif entry.tag == "CLUSTER" or entry.tag == "SYNC" then tagColor = colors.purple or colors.magenta
        end
        setColor(colors.gray or colors.lightGray)
        io.write(string.format(" [%s] ", entry.time or "now"))
        setColor(tagColor)
        io.write(string.format("[%-8s] ", entry.tag or "EVENT"))
        resetColor()
        print(entry.msg or "")
    end

    -- Bottom controls
    term.setCursorPos(1, h)
    setColor(colors.cyan)
    io.write("[B]lock MAC   [U]nblock   [K]ick Lease   [R]efresh   [Q]uit")
    resetColor()
end

while running do
    drawDashboard()
    local timer = os.startTimer(2.0)
    local ev, p1 = os.pullEvent()
    if ev == "char" then
        local c = p1:lower()
        if c == "q" then
            running = false
            term.clear()
            term.setCursorPos(1, 1)
            print(":: Exited dhcpctl.")
        elseif c == "b" then
            term.setCursorPos(1, select(2, term.getSize()))
            term.clearLine()
            io.write("Enter MAC or IP to block: ")
            local target = read()
            if target and target ~= "" then
                local conf = loadConfig()
                conf.blocked_macs = conf.blocked_macs or {}
                conf.blocked_ips = conf.blocked_ips or {}
                local isMac = target:find(":") ~= nil
                if isMac then conf.blocked_macs[target] = true else conf.blocked_ips[target] = true end
                saveConfig(conf)
                broadcastBlockSync(target, isMac, true)
            end
        elseif c == "u" then
            term.setCursorPos(1, select(2, term.getSize()))
            term.clearLine()
            io.write("Enter MAC or IP to unblock: ")
            local target = read()
            if target and target ~= "" then
                local conf = loadConfig()
                conf.blocked_macs = conf.blocked_macs or {}
                conf.blocked_ips = conf.blocked_ips or {}
                local isMac = target:find(":") ~= nil
                if isMac then conf.blocked_macs[target] = nil else conf.blocked_ips[target] = nil end
                saveConfig(conf)
                broadcastBlockSync(target, isMac, false)
            end
        elseif c == "k" then
            term.setCursorPos(1, select(2, term.getSize()))
            term.clearLine()
            io.write("Enter MAC to kick: ")
            local target = read()
            if target and target ~= "" then
                local db = loadLeases()
                db.leases[target] = nil
                local h = fs.open(LEASES_FILE, "w")
                if h then h.write(textutils.serialize(db)); h.close() end
            end
        end
    end
end
