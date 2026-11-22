-- dhcpcd.lua - DHCP Client Daemon for Luna OS
local args = { ... }
local net = _G.LunaNet or (fs.exists("/usr/bin/core/net.lua") and dofile("/usr/bin/core/net.lua"))
if not net then
    error("Network stack not available")
end

local conf = net.loadConfig()
local isUp, statusMsg = net.checkPinStatus()
if not isUp then
    printError("dhcpcd: eth0: carrier lost (" .. statusMsg .. ")")
    return
end

print(":: eth0: soliciting a DHCP lease...")
local ok, res = net.dhcpClient(5.0)
if ok then
    print(string.format(":: eth0: offered %s from %s", res.ip, res.server_ip or "DHCP server"))
    print(string.format(":: eth0: leased %s for %d seconds", res.ip, res.lease_time or 86400))
    print(":: eth0: adding default route via " .. (res.gateway or "none"))
else
    printError("dhcpcd: " .. tostring(res))
end
