-- systemctl.lua - Systemd Service & Startup Pipeline Controller for Luna OS
local args = { ... }
local write = _G.write or io.write or function(s) io.stdout:write(s) end

local SYSTEM_CONF = "/etc/conf/system.conf"
local SERVICES_DB = "/etc/conf/services.db"

local function loadSystemConfig()
    local sysConf = {
        display = { text_scale = 0.5, redirect_to_monitor = true },
        dust = { repo_url = "http://127.0.0.1:8080" },
        services = {},
        autostart = {}
    }

    if fs.exists(SYSTEM_CONF) then
        local h = fs.open(SYSTEM_CONF, "r")
        if h then
            local data = textutils.unserialize(h.readAll())
            h.close()
            if type(data) == "table" then
                if data.display then for k, v in pairs(data.display) do sysConf.display[k] = v end end
                if data.dust then for k, v in pairs(data.dust) do sysConf.dust[k] = v end end
                if data.services then
                    for k, v in pairs(data.services) do
                        if type(v) == "table" then
                            sysConf.services[k] = v
                        end
                    end
                end
                if data.autostart then sysConf.autostart = data.autostart end
            end
        end
    elseif fs.exists(SERVICES_DB) then
        local h = fs.open(SERVICES_DB, "r")
        if h then
            local data = textutils.unserialize(h.readAll())
            h.close()
            if type(data) == "table" then
                for k, v in pairs(data) do
                    if type(v) == "table" then
                        sysConf.services[k] = v
                    end
                end
            end
        end
    end

    return sysConf
end

local function saveSystemConfig(sysConf)
    if not fs.exists("/etc/conf") then fs.makeDir("/etc/conf") end
    local h = fs.open(SYSTEM_CONF, "w")
    if not h then return false end
    h.write(textutils.serialize(sysConf))
    h.close()

    local h2 = fs.open(SERVICES_DB, "w")
    if h2 then
        h2.write(textutils.serialize(sysConf.services or {}))
        h2.close()
    end
    return true
end

local sysConf = loadSystemConfig()
local state = sysConf.services

local action = args[1]
local unit   = args[2]

if not action or action == "-h" or action == "--help" then
    print("usage: systemctl {start|stop|restart|status|enable|disable} <unit>")
    print("       systemctl list-units | list")
    print("       systemctl order <unit> <priority_number>")
    print("       systemctl add <name> <script_path> [order] [description]")
    print("       systemctl remove <name>")
    return
end

local function cleanUnitName(name)
    if not name then return "" end
    return name:gsub("%.service$", ""):gsub("%.autostart$", "")
end

local function resolveScriptPath(rawPath)
    if not rawPath then return nil end
    if fs.exists(rawPath) and not fs.isDir(rawPath) then return rawPath end
    local clean = (rawPath:sub(1, 1) == "/") and rawPath:sub(2) or rawPath
    if fs.exists(clean) and not fs.isDir(clean) then return "/" .. clean end
    if fs.exists("/usr/bin/core/" .. rawPath) then return "/usr/bin/core/" .. rawPath end
    if fs.exists("/usr/bin/extra/" .. rawPath) then return "/usr/bin/extra/" .. rawPath end
    if fs.exists("/usr/bin/server/" .. rawPath) then return "/usr/bin/server/" .. rawPath end
    return nil
end

local function isDaemonRunning(name)
    if _G._DAEMON_THREADS then
        for _, d in ipairs(_G._DAEMON_THREADS) do
            if d.name == name and coroutine.status(d.co) ~= "dead" then
                return true
            end
        end
    end
    return _G["_DAEMON_" .. name] == true
end

-- 1. LIST UNITS
if action == "list-units" or action == "list" then
    local list = {}
    for sName, sData in pairs(state) do
        local scriptPath = resolveScriptPath(sData.script)
        local exists = scriptPath ~= nil
        local isRunning = isDaemonRunning(sName)

        local activeStr, subStr
        if not exists then
            activeStr = "not-found"
            subStr    = "missing  "
        elseif isRunning then
            activeStr = "active   "
            subStr    = "running  "
        else
            activeStr = "inactive "
            subStr    = "dead     "
        end

        table.insert(list, {
            name = sName .. ".service",
            order = sData.order or 50,
            active = activeStr,
            sub = subStr,
            enabled = (sData.enabled == true) and "enabled " or "disabled",
            desc = sData.desc or (sName .. " daemon"),
            isCustom = sData.isCustom or false
        })
    end

    -- Legacy autostart migration / display
    for _, auto in ipairs(sysConf.autostart or {}) do
        local aName = auto.name or fs.getName(auto.script or "custom")
        if not state[aName] then
            local aPath = resolveScriptPath(auto.script)
            local isRunning = isDaemonRunning(aName)
            table.insert(list, {
                name = aName .. ".service",
                order = auto.order or 50,
                active = (aPath and isRunning) and "active   " or (aPath and "inactive " or "not-found"),
                sub = (aPath and isRunning) and "running  " or (aPath and "dead     " or "missing  "),
                enabled = "enabled ",
                desc = auto.desc or auto.script,
                isCustom = true
            })
        end
    end

    table.sort(list, function(a, b) return (a.order or 50) < (b.order or 50) end)

    print("ORDER  UNIT                         ACTIVE     SUB       STARTUP   DESCRIPTION")
    print("01     systemd-security.service     active     running   static    Authentication Subsystem")
    print("02     raid0-storage.service        active     running   static    CEE RAID0 Filesystem")
    for _, item in ipairs(list) do
        print(string.format("%-6d %-28s %s  %s  %s  %s", item.order, item.name, item.active, item.sub, item.enabled, item.desc))
    end
    return
end

-- 2. ADD ANY SCRIPT AS A SYSTEM SERVICE
if action == "add" then
    local curUser = _G.CURRENT_USER or "root"
    if curUser ~= "root" then
        printError("systemctl: Access denied (must be root)")
        return
    end

    local name = cleanUnitName(args[2])
    local scriptRaw = args[3]
    local order = tonumber(args[4]) or 50
    local desc = args[5]

    if not name or name == "" or not scriptRaw then
        print("Usage: systemctl add <name> <script_path> [order] [description]")
        return
    end

    local scriptPath = resolveScriptPath(scriptRaw)
    if not scriptPath then
        printError("systemctl: Script file '" .. scriptRaw .. "' does not exist")
        return
    end

    if not desc or desc == "" then
        desc = name:gsub("^%l", string.upper) .. " Service (" .. fs.getName(scriptPath) .. ")"
    end

    sysConf.services[name] = {
        name = name,
        script = scriptPath,
        order = order,
        desc = desc,
        enabled = true,
        active = false,
        sub = "dead",
        isCustom = true
    }

    -- Remove from legacy autostart if previously existed there
    if sysConf.autostart then
        for idx = #sysConf.autostart, 1, -1 do
            if sysConf.autostart[idx].name == name then
                table.remove(sysConf.autostart, idx)
            end
        end
    end

    saveSystemConfig(sysConf)
    if term.isColor() then term.setTextColor(colors.lime) end
    write("[  OK  ] ")
    if term.isColor() then term.setTextColor(colors.white) end
    print(string.format("Created service unit %s.service -> %s (order %d)", name, scriptPath, order))
    print("         To start now: systemctl start " .. name)
    return
end

-- 3. REMOVE A SERVICE UNIT
if action == "remove" or action == "delete" then
    local curUser = _G.CURRENT_USER or "root"
    if curUser ~= "root" then
        printError("systemctl: Access denied (must be root)")
        return
    end

    local name = cleanUnitName(args[2])
    if not name or name == "" then
        printError("Usage: systemctl remove <name>")
        return
    end

    local found = false
    if sysConf.services[name] then
        _G["_DAEMON_" .. name] = false
        if _G._DAEMON_THREADS then
            for idx = #_G._DAEMON_THREADS, 1, -1 do
                if _G._DAEMON_THREADS[idx].name == name then
                    table.remove(_G._DAEMON_THREADS, idx)
                end
            end
        end
        sysConf.services[name] = nil
        found = true
    end

    if sysConf.autostart then
        for idx = #sysConf.autostart, 1, -1 do
            if sysConf.autostart[idx].name == name then
                table.remove(sysConf.autostart, idx)
                found = true
            end
        end
    end

    if found then
        saveSystemConfig(sysConf)
        if term.isColor() then term.setTextColor(colors.lime) end
        write("[  OK  ] ")
        if term.isColor() then term.setTextColor(colors.white) end
        print("Removed service unit " .. name .. ".service")
    else
        printError("systemctl: unit '" .. name .. ".service' not found")
    end
    return
end

-- Standard Unit Actions: start | stop | restart | status | enable | disable | order
unit = cleanUnitName(unit)
if unit == "" then
    printError("systemctl: no unit specified")
    return
end

local svc = state[unit]

-- Auto-discover script if not yet in services table
if not svc then
    local candidates = {
        { path = "/usr/bin/server/" .. unit .. ".lua", desc = unit:upper() .. " Server Daemon" },
        { path = "/usr/bin/core/" .. unit .. ".lua", desc = unit:upper() .. " Core Service" },
        { path = "/usr/bin/extra/" .. unit .. ".lua", desc = unit:upper() .. " Userland Service" },
        { path = "/usr/bin/server/" .. unit .. "d.lua", desc = unit:upper() .. " Daemon" },
        { path = "/usr/bin/core/" .. unit .. "d.lua", desc = unit:upper() .. " Daemon" },
        { path = "/usr/bin/extra/" .. unit .. "d.lua", desc = unit:upper() .. " Daemon" },
        { path = "/" .. unit .. ".lua", desc = unit:upper() .. " Service" }
    }
    for _, c in ipairs(candidates) do
        if fs.exists(c.path) then
            svc = {
                active = false,
                sub = "dead",
                enabled = false,
                order = 50,
                started_at = nil,
                desc = c.desc,
                script = c.path,
                conf = fs.exists("/etc/conf/" .. unit .. ".conf") and ("/etc/conf/" .. unit .. ".conf") or nil
            }
            state[unit] = svc
            saveSystemConfig(sysConf)
            break
        end
    end
end

if not svc then
    printError("systemctl: unit '" .. unit .. ".service' not found")
    return
end

-- 4. ORDER COMMAND (SET STARTUP PRIORITY)
if action == "order" then
    local curUser = _G.CURRENT_USER or "root"
    if curUser ~= "root" then printError("systemctl: Access denied (must be root)"); return end
    local newOrder = tonumber(args[3])
    if not newOrder then printError("Usage: systemctl order <unit> <number>"); return end
    svc.order = newOrder
    saveSystemConfig(sysConf)
    print(string.format("[  OK  ] Startup order for %s.service set to %d", unit, newOrder))
    return
end

local function printBullet(isActive)
    if term.isColor() then
        term.setTextColor(isActive and colors.lime or colors.lightGray)
        write("* ")
        term.setTextColor(colors.white)
    else
        write(isActive and "* " or "o ")
    end
end

-- 5. STATUS
if action == "status" then
    local scriptPath = resolveScriptPath(svc.script)
    local isRunning = isDaemonRunning(unit)
    printBullet(isRunning)
    print(unit .. ".service - " .. (svc.desc or "Service"))

    local enableStr = (svc.enabled == true) and ("enabled (order " .. (svc.order or 50) .. ")") or "disabled"
    if not scriptPath then
        print("     Loaded: not-found (script '" .. tostring(svc.script) .. "' is missing)")
        print("     Active: inactive (dead)")
        return
    end

    print("     Loaded: loaded (" .. scriptPath .. "; " .. enableStr .. ")")
    if isRunning then
        local sinceStr = svc.started_at and (" since " .. svc.started_at) or ""
        print("     Active: active (running)" .. sinceStr)
    else
        print("     Active: inactive (dead)")
    end

    -- Specific runtime details
    local net = _G.LunaNet or (fs.exists("/usr/bin/core/net.lua") and dofile("/usr/bin/core/net.lua"))
    if unit == "sshd" and net then
        local netConf = net.loadConfig()
        local isUp, statusMsg = net.checkPinStatus()
        print("     IP    : " .. (netConf.ip or "10.0.0.x"))
        print("     Port  : 22")
        print("     Pin   : Signal " .. tostring(netConf.pin or 1) .. " (status: " .. (isUp and "connected" or "offline") .. ")")
        if isRunning then
            print("     Status: listening for incoming network connections")
        end
    end
    if unit == "dhcpd" then
        local dhcpConfFile = "/etc/conf/dhcpd.conf"
        local dConf = {}
        if fs.exists(dhcpConfFile) then
            local h = fs.open(dhcpConfFile, "r")
            if h then dConf = textutils.unserialize(h.readAll()) or {}; h.close() end
        end
        print("     Server IP  : " .. (dConf.server_ip or "10.0.0.1"))
        print("     Client Pin : Signal " .. tostring(dConf.pin or 1))
        print("     Cluster Pin: Signal " .. tostring(dConf.cluster_pin or 2))
        print("     Mesh Sync  : " .. (dConf.cluster_enabled and "ENABLED" or "DISABLED"))
        if isRunning then
            print("     Status     : actively serving leases & DNS routing")
        end
    end
    return

-- 6. START
elseif action == "start" then
    local curUser = _G.CURRENT_USER or "root"
    if curUser ~= "root" then printError("systemctl: Access denied (must be root)"); return end

    local scriptPath = resolveScriptPath(svc.script)
    if not scriptPath then
        printError("systemctl: Failed to start " .. unit .. ".service: Script '" .. tostring(svc.script) .. "' not found")
        return
    end

    if isDaemonRunning(unit) then
        print(unit .. ".service is already active (running)")
        return
    end

    local fn, loadErr = loadfile(scriptPath)
    if not fn then
        printError("systemctl: Failed to load " .. scriptPath .. ": " .. tostring(loadErr))
        return
    end

    local co = coroutine.create(function()
        pcall(fn, "--daemon")
    end)

    _G["_DAEMON_" .. unit] = true
    local okResume, resErr = coroutine.resume(co)
    if not okResume then
        printError("systemctl: Failed to start " .. unit .. ".service: " .. tostring(resErr))
        _G["_DAEMON_" .. unit] = false
        return
    end

    if not _G._DAEMON_THREADS then _G._DAEMON_THREADS = {} end
    table.insert(_G._DAEMON_THREADS, {
        name = unit,
        co = co,
        fn = fn,
        script = scriptPath
    })

    svc.active = true
    svc.sub = "running"
    svc.started_at = os.date("%a %b %d %H:%M:%S %Y")
    saveSystemConfig(sysConf)

    if term.isColor() then term.setTextColor(colors.lime) end
    write("[  OK  ] ")
    if term.isColor() then term.setTextColor(colors.white) end
    print("Started " .. (svc.desc or (unit .. ".service")))

-- 7. STOP
elseif action == "stop" then
    local curUser = _G.CURRENT_USER or "root"
    if curUser ~= "root" then printError("systemctl: Access denied (must be root)"); return end

    if not isDaemonRunning(unit) and not svc.active then
        print(unit .. ".service is already inactive (dead)")
        return
    end

    _G["_DAEMON_" .. unit] = false
    if _G._DAEMON_THREADS then
        for idx = #_G._DAEMON_THREADS, 1, -1 do
            if _G._DAEMON_THREADS[idx].name == unit then
                table.remove(_G._DAEMON_THREADS, idx)
            end
        end
    end

    svc.active = false
    svc.sub = "dead"
    svc.started_at = nil
    saveSystemConfig(sysConf)

    if term.isColor() then term.setTextColor(colors.lime) end
    write("[  OK  ] ")
    if term.isColor() then term.setTextColor(colors.white) end
    print("Stopped " .. (svc.desc or (unit .. ".service")))

-- 8. RESTART
elseif action == "restart" then
    local curUser = _G.CURRENT_USER or "root"
    if curUser ~= "root" then printError("systemctl: Access denied (must be root)"); return end

    -- Stop
    _G["_DAEMON_" .. unit] = false
    if _G._DAEMON_THREADS then
        for idx = #_G._DAEMON_THREADS, 1, -1 do
            if _G._DAEMON_THREADS[idx].name == unit then
                table.remove(_G._DAEMON_THREADS, idx)
            end
        end
    end

    -- Start
    local scriptPath = resolveScriptPath(svc.script)
    if not scriptPath then
        printError("systemctl: Failed to restart: Script '" .. tostring(svc.script) .. "' not found")
        svc.active = false
        svc.sub = "dead"
        saveSystemConfig(sysConf)
        return
    end

    local fn, loadErr = loadfile(scriptPath)
    if not fn then
        printError("systemctl: Failed to load " .. scriptPath .. ": " .. tostring(loadErr))
        return
    end

    local co = coroutine.create(function() pcall(fn, "--daemon") end)
    _G["_DAEMON_" .. unit] = true
    coroutine.resume(co)

    if not _G._DAEMON_THREADS then _G._DAEMON_THREADS = {} end
    table.insert(_G._DAEMON_THREADS, {
        name = unit,
        co = co,
        fn = fn,
        script = scriptPath
    })

    svc.active = true
    svc.sub = "running"
    svc.started_at = os.date("%a %b %d %H:%M:%S %Y")
    saveSystemConfig(sysConf)

    if term.isColor() then term.setTextColor(colors.lime) end
    write("[  OK  ] ")
    if term.isColor() then term.setTextColor(colors.white) end
    print("Restarted " .. (svc.desc or (unit .. ".service")))

-- 9. ENABLE
elseif action == "enable" then
    local curUser = _G.CURRENT_USER or "root"
    if curUser ~= "root" then printError("systemctl: Access denied (must be root)"); return end

    local newOrder = tonumber(args[3])
    if newOrder then svc.order = newOrder end
    svc.enabled = true
    saveSystemConfig(sysConf)
    print(string.format("Created symlink /etc/systemd/system/multi-user.target.wants/%s.service (order %d)", unit, svc.order or 50))

-- 10. DISABLE
elseif action == "disable" then
    local curUser = _G.CURRENT_USER or "root"
    if curUser ~= "root" then printError("systemctl: Access denied (must be root)"); return end

    svc.enabled = false
    saveSystemConfig(sysConf)
    print("Removed symlink /etc/systemd/system/multi-user.target.wants/" .. unit .. ".service")

else
    printError("systemctl: Unknown command: '" .. action .. "'")
end
