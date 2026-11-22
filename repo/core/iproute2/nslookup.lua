-- nslookup.lua - Query Internet Name Servers interactively
local args = { ... }

if #args == 0 or args[1] == "-h" or args[1] == "--help" then
    print("usage: nslookup <hostname> [dns_server]")
    return
end

local net = _G.LunaNet or (fs.exists("/usr/bin/core/net.lua") and dofile("/usr/bin/core/net.lua"))
if not net then
    printError("nslookup: Network stack not available.")
    return
end

local host = args[1]
local conf = net.loadConfig()
local dnsServer = args[2] or conf.dns or conf.server_ip or "10.0.0.1"

print(string.format("Server:    %s", dnsServer))
print(string.format("Address:   %s#53\n", dnsServer))

local ip = net.resolveHost(host, 2.0)
if ip then
    print("Non-authoritative answer:")
    print(string.format("Name:      %s", host))
    print(string.format("Address:   %s", ip))
else
    print(string.format("** server can't find %s: NXDOMAIN", host))
end
