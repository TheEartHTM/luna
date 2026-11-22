-- ping.lua - ICMP Ping Utility for Luna OS (CEE Edition)
local args = { ... }

if #args == 0 or args[1] == "-h" or args[1] == "--help" then
    print("usage: ping <target_ip> [-c count] [-p pin]")
    return
end

local net = _G.LunaNet or (fs.exists("/usr/bin/core/net.lua") and dofile("/usr/bin/core/net.lua"))
if not net then
    error("Network driver not available.")
end

local target = args[1]
local count = 4
local overridePin = nil

local i = 2
while i <= #args do
    if args[i] == "-c" and args[i + 1] then
        count = tonumber(args[i + 1]) or 4
        i = i + 2
    elseif args[i] == "-p" and args[i + 1] then
        local rawPin = args[i + 1]
        overridePin = (rawPin == "fabric") and "fabric" or (tonumber(rawPin) or 1)
        i = i + 2
    else
        i = i + 1
    end
end

local conf = net.loadConfig()
if not conf.ip then
    printError("ping: connect: Network is unconfigured. Run 'dhcpcd' to obtain an IP address.")
    return
end

local isUp, statusMsg = net.checkPinStatus(overridePin)
if not isUp then
    printError("ping: connect: Network is down (" .. statusMsg .. ")")
    return
end

local targetHost = target
local resolvedIp = net.resolveHost and net.resolveHost(target, 1.5, overridePin)
if not resolvedIp then
    printError("ping: " .. target .. ": Name or service not known")
    return
end
target = resolvedIp

local activePin = overridePin or net.loadConfig().pin or 1
print(string.format("PING %s (%s) via %s: 56 data bytes.", targetHost, target, (activePin == "fabric" and "Fabric" or ("Signal " .. activePin))))

local received = 0
for seq = 1, count do
    if target == conf.ip or target == "127.0.0.1" then
        received = received + 1
        print(string.format("64 bytes from %s: icmp_seq=%d ttl=64 time=1 ms", target, seq))
    else
        local tStart = os.epoch and os.epoch("utc") or (os.time() * 1000)
        local resp, err = net.request(target, 22, { cmd = "PING", seq = seq }, 1.5, overridePin)
        local tEnd = os.epoch and os.epoch("utc") or (os.time() * 1000)
        local rtt = math.max(5, tEnd - tStart)

        if resp and resp.cmd == "PONG" then
            received = received + 1
            print(string.format("64 bytes from %s: icmp_seq=%d ttl=64 time=%d ms", target, seq, rtt))
        else
            print(string.format("From %s icmp_seq=%d Destination Host Unreachable", net.loadConfig().ip, seq))
        end
    end
    if seq < count then sleep(0.5) end
end

print("\n--- " .. target .. " ping statistics ---")
local loss = math.floor(((count - received) / count) * 100)
print(string.format("%d packets transmitted, %d received, %d%% packet loss", count, received, loss))
