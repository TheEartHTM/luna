-- udevadm.lua - udev management and query tool for Luna OS
local udev = require("udev") or _G.udev
if not udev then
    if fs.exists("/usr/lib/udev.lua") then
        udev = dofile("/usr/lib/udev.lua")
    else
        print("udevadm: udev subsystem not found")
        return
    end
end

local args = { ... }
local cmd = args[1]

if not cmd or cmd == "-h" or cmd == "--help" then
    print("usage: udevadm {info|list|trigger} [options]")
    print("commands:")
    print("  info -p <dev_path>       query device properties by path (e.g. /dev/mon0)")
    print("  info -n <name>           query device by hardware name")
    print("  list [-s <subsystem>]    list devices (subsystems: create, display, sound, signal_port, block)")
    print("  trigger                  rescan hardware buses and refresh devices")
    return
end

if cmd == "list" then
    local sub = nil
    if args[2] == "-s" or args[2] == "--subsystem" then
        sub = args[3]
    end
    local list = udev.find(sub and { subsystem = sub } or nil)
    print(string.format("Found %d device(s)%s:", #list, sub and (" in subsystem '" .. sub .. "'") or ""))
    print(string.rep("-", 55))
    print(string.format(" %-18s | %-12s | %-15s", "DEV PATH", "SUBSYSTEM", "TYPE"))
    print(string.rep("-", 55))
    for _, d in ipairs(list) do
        print(string.format(" %-18s | %-12s | %-15s", d.dev, d.subsystem, d.type))
    end
    print(string.rep("-", 55))

elseif cmd == "info" then
    local target = nil
    for i = 2, #args do
        if (args[i] == "-p" or args[i] == "--path" or args[i] == "-n" or args[i] == "--name") and args[i+1] then
            target = args[i+1]
            break
        elseif not target and args[i]:sub(1, 1) ~= "-" then
            target = args[i]
        end
    end

    if not target then
        print("udevadm info: missing device path or name (-p /dev/... or -n name)")
        return
    end

    local d = udev.get(target)
    if not d then
        print("udevadm: device not found: " .. target)
        return
    end

    print("P: " .. d.dev)
    print("N: " .. d.name)
    print("E: DEVNAME=" .. d.dev)
    print("E: SUBSYSTEM=" .. d.subsystem)
    print("E: TYPE=" .. d.type)
    print("E: BUS=" .. (d.bus or "unknown"))
    print("E: STATUS=" .. (d.status or "READY"))
    if d.pin then print("E: PIN=" .. tostring(d.pin)) end
    if d.methods and #d.methods > 0 then
        print("E: METHODS=" .. table.concat(d.methods, ", "))
    end

elseif cmd == "trigger" then
    local list = udev.list()
    print(string.format("udevadm: successfully triggered and rescanned %d hardware device(s).", #list))

else
    print("udevadm: unknown command: " .. cmd)
end
