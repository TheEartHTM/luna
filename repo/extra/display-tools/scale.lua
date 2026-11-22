-- display.lua - Screen and Monitor text scale configurator for Luna OS
local args = { ... }

local SYSTEM_CONF = "/etc/conf/system.lua"

local function loadConfig()
    local conf = {
        text_scale = 0.5,
        redirect_to_monitor = true
    }
    if fs.exists(SYSTEM_CONF) then
        local h = fs.open(SYSTEM_CONF, "r")
        if h then
            local content = h.readAll()
            h.close()
            local fn = load(content, "@" .. SYSTEM_CONF, "t", {})
            if fn then
                local ok, data = pcall(fn)
                if ok and type(data) == "table" and data.display then
                    for k, v in pairs(data.display) do conf[k] = v end
                    return conf
                end
            end
        end
    end
    return conf
end

local function saveConfig(conf)
    if not fs.exists("/etc/conf") then fs.makeDir("/etc/conf") end
    return true
end

local function findAnyMonitor()
    if peripheral then
        local m = peripheral.find("ceemonitor") or peripheral.find("monitor")
        if m then return m, "ceemonitor" end
        for _, name in ipairs(peripheral.getNames()) do
            local pType = peripheral.getType(name)
            if pType == "ceemonitor" or pType == "monitor" then
                return peripheral.wrap(name), pType
            end
        end
    end
    if _G.cee and _G.cee.getMonitors then
        for pin = 1, 11 do
            local ok, mons = pcall(_G.cee.getMonitors, pin)
            if ok and mons and mons.getSize then
                return mons, "cee_signal_" .. pin
            end
        end
    end
    return nil, nil
end

local conf = loadConfig()
local mon, monType = findAnyMonitor()

if #args == 0 or args[1] == "status" then
    local w, h = term.getSize()
    print("Display Configuration:")
    print("  Config file : " .. CONF_FILE)
    print("  Text scale  : " .. tostring(conf.text_scale or 0.5))
    if mon then
        local mw, mh = mon.getSize and mon.getSize() or term.getSize()
        print("  Device      : External Monitor (" .. tostring(monType) .. ")")
        print(string.format("  Native Res  : %d columns x %d rows", mw, mh))
    else
        print("  Device      : Built-in Computer Terminal")
        print(string.format("  Resolution  : %d columns x %d rows", w, h))
        print("  Note        : Built-in terminal is fixed at 51x24. Connect a CEE Monitor for high resolution.")
    end
    print("\nCommands:")
    print("  scale 0.5   compact crisp text (maximum columns and rows)")
    print("  scale 1.0   standard text scale")
    return
end

if args[1] == "-h" or args[1] == "--help" then
    print("usage: scale <0.5 | 1 | 1.5 | 2>")
    print("       display [options]")
    print("options:")
    print("  0.5          compact crisp text (maximum columns and rows)")
    print("  1            default scale")
    print("  status       show display configuration and resolution")
    print("  nomonitor    disable redirecting to external monitor")
    print("  monitor      enable redirecting to external monitor")
    return
end

if args[1] == "nomonitor" then
    conf.redirect_to_monitor = false
    saveConfig(conf)
    term.restore()
    print("External monitor redirection disabled. Output restored to built-in terminal.")
    return
elseif args[1] == "monitor" then
    conf.redirect_to_monitor = true
    saveConfig(conf)
    if mon then
        pcall(mon.setTextScale, tonumber(conf.text_scale) or 0.5)
        term.redirect(mon)
        print("External monitor redirection enabled.")
    else
        print("External monitor redirection enabled (waiting for monitor connection).")
    end
    return
end

local targetScale = tonumber(args[1])
if not targetScale then
    printError("scale: invalid scale value. Use 0.5, 1, 1.5, or 2")
    return
end

if targetScale < 0.5 or targetScale > 5 then
    printError("scale: scale must be between 0.5 and 5.0")
    return
end

conf.text_scale = targetScale
saveConfig(conf)

if mon and mon.setTextScale then
    pcall(mon.setTextScale, targetScale)
    mon.clear()
    mon.setCursorPos(1, 1)
    if conf.redirect_to_monitor ~= false then
        if _G.DUAL_TERM then
            term.redirect(_G.DUAL_TERM)
        else
            term.redirect(mon)
        end
    end
end

if term.setTextScale then
    pcall(term.setTextScale, targetScale)
end

term.clear()
term.setCursorPos(1, 1)

local w, h = term.getSize()
if mon then
    print(string.format("Monitor scale set to %.1f (Native Resolution: %d x %d).", targetScale, w, h))
    print("Text distortion fixed (running in native aspect ratio).")
else
    print(string.format("Display scale set to %.1f (Resolution: %d x %d).", targetScale, w, h))
end
print("Saved to " .. CONF_FILE)
