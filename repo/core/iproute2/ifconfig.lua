-- ifconfig.lua - Network interface configurator for Luna OS (CEE Edition)
local args = { ... }

local net = _G.LunaNet or (fs.exists("/usr/bin/core/net.lua") and dofile("/usr/bin/core/net.lua"))
if not net then
    error("Network stack not available.")
end

local function formatBytes(bytes)
    if not bytes or bytes <= 0 then return "0 B" end
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MiB", bytes / (1024 * 1024))
    elseif bytes >= 1024 then
        return string.format("%.1f KiB", bytes / 1024)
    else
        return string.format("%d B", bytes)
    end
end

local conf = net.loadConfig()
local isUp, statusMsg = net.checkPinStatus()

if #args == 0 then
    local flags = isUp and (conf.ip and "4163<UP,BROADCAST,RUNNING>" or "4099<UP,BROADCAST,MULTICAST>") or "4098<BROADCAST,MULTICAST>"
    print("eth0: flags=" .. flags .. "  mtu 1500")
    if conf.ip then
        print("        inet " .. conf.ip .. "  netmask " .. (conf.netmask or "255.255.255.0"))
    else
        print("        inet (unconfigured)  broadcast 255.255.255.255")
    end
    if conf.pin == "fabric" then
        print("        hardware: Server Rack Fabric (" .. statusMsg .. ")")
    else
        print("        pin: Signal " .. tostring(conf.pin or 1) .. " (status: " .. (isUp and "connected" or "disconnected") .. ")")
    end
    local mac = conf.mac or (net.getMAC and net.getMAC()) or "52:54:00:12:00:00"
    print("        ether " .. mac)

    local stats = net.getStats and net.getStats() or { rx_packets = 0, rx_bytes = 0, tx_packets = 0, tx_bytes = 0 }
    print(string.format("        RX packets %d  bytes %s", stats.rx_packets, formatBytes(stats.rx_bytes)))
    print(string.format("        TX packets %d  bytes %s", stats.tx_packets, formatBytes(stats.tx_bytes)))
    return
end

if args[1] == "-h" or args[1] == "--help" then
    print("usage: ifconfig [interface] [IP] [pin <1..11|fabric>]")
    print("examples:")
    print("  ifconfig                      display network interface")
    print("  ifconfig 10.0.2               set local IP address")
    print("  ifconfig pin 1                bind to CEE Signal Pin 1")
    print("  ifconfig pin fabric           bind to Server Rack Fabric")
    print("  ifconfig 10.0.3 pin 2         set IP and Signal Pin")
    return
end

local curUser = _G.CURRENT_USER or "root"
if curUser ~= "root" then
    printError("ifconfig: SIOCSIFADDR: Permission denied (must be root)")
    return
end

local i = 1
while i <= #args do
    local a = args[i]
    if a == "pin" and args[i + 1] then
        local rawPin = args[i + 1]
        conf.pin = (rawPin == "fabric") and "fabric" or (tonumber(rawPin) or 1)
        i = i + 2
    elseif a:match("^%d+%.%d+%.%d+%.%d+$") or a:match("^%d+%.%d+%.%d+$") then
        local isServer = fs.exists("/usr/bin/server/dhcpd.lua") and fs.exists("/etc/conf/dhcpd.conf")
        if not isServer then
            printError("ifconfig: manual IP assignment is disabled on client nodes.")
            printError("All routing and IP assignment is strictly managed by the DHCP server.")
            print(":: Run 'dhcpcd' to obtain an authorized IP lease.")
            return
        end
        conf.ip = a
        i = i + 1
    elseif a == "eth0" or a == "lo" then
        i = i + 1
    else
        printError("ifconfig: invalid argument '" .. a .. "'")
        return
    end
end

net.saveConfig(conf)
print("Updated network configuration:")
print("  IP : " .. conf.ip)
print("  Pin: " .. tostring(conf.pin))
