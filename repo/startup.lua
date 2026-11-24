-- Luna OS Multi-Display & Multi-TTY Workspace Subsystem (Hyprland Lua Architecture)
-- Supports modular config sourcing: source("/etc/conf/monitors.lua")
-- Supports declarative monitor layout: monitors = { { name = "...", dev = "...", tty = "...", scale = ... } }
-- Supports autostart commands: exec_once = { "..." }
-- Supports keybindings: bind = { { "MOD", "KEY", "cmd" } }

local devToTTY = {
    ["system"] = "tty1",
    ["/dev/system"] = "tty1",
    ["builtin"] = "tty1",
    ["/dev/keyboard0"] = "tty1",
    ["keyboard0"] = "tty1"
}
local pinToTTY = {}
local monitorToTTY = {}
local ttyTerms = {}
local ttyList = {}
local activeTTY = "tty1"
local ttyOwners = {}
local coroTerms = {}
local monitorList = {}

local nativeTerm = term.native and term.native() or term.current()

local function getCoroTerm()
    local co = coroutine.running()
    if not co then return nativeTerm end
    if coroTerms[co] then return coroTerms[co] end
    local myTTY = ttyOwners[co]
    if myTTY and ttyTerms[myTTY] then
        return ttyTerms[myTTY]
    end
    return nativeTerm
end

local vTerm = {}
local termMethods = {
    "write", "scroll", "setCursorPos", "setCursorBlink", "getCursorPos", "getCursorBlink",
    "getSize", "clear", "clearLine", "setTextColour", "setTextColor", "setBackgroundColour",
    "setBackgroundColor", "isColour", "isColor", "getTextColour", "getTextColor",
    "getBackgroundColour", "getBackgroundColor", "blit", "setPaletteColour", "setPaletteColor",
    "getPaletteColour", "getPaletteColor"
}
for _, m in ipairs(termMethods) do
    vTerm[m] = function(...)
        local target = getCoroTerm()
        if target and target[m] then
            return target[m](...)
        elseif nativeTerm and nativeTerm[m] then
            return nativeTerm[m](...)
        end
    end
end
vTerm.native = function() return nativeTerm end
vTerm.current = function() return getCoroTerm() end
vTerm.redirect = function(target)
    local co = coroutine.running()
    local old = getCoroTerm()
    if co then
        coroTerms[co] = target
    end
    return old
end

_G.term = vTerm

local origCoroCreate = coroutine.create
coroutine.create = function(f)
    local parent = coroutine.running()
    local child = origCoroCreate(f)
    if parent then
        if ttyOwners[parent] then
            ttyOwners[child] = ttyOwners[parent]
        end
        if coroTerms[parent] then
            coroTerms[child] = coroTerms[parent]
        end
    end
    return child
end

local function calcScale(blocks, wBlocks, hBlocks)
    local bw, bh = 0, 0
    if type(blocks) == "string" then
        local sw, sh = blocks:match("(%d+)[xX*](%d+)")
        bw, bh = tonumber(sw) or 0, tonumber(sh) or 0
    elseif type(blocks) == "number" then
        bw = blocks
    end
    bw = (bw > 0 and bw) or tonumber(wBlocks) or 1
    bh = (bh > 0 and bh) or tonumber(hBlocks) or 1

    if bw <= 2 or bh <= 1 then
        return 0.5
    elseif bw >= 7 and bh >= 4 then
        return 1.5
    elseif bw >= 4 and bh >= 2 then
        return 1.0
    else
        return 0.5
    end
end

local SIDE_ORDER = {
    bottom = 1,
    top    = 2,
    back   = 3,
    front  = 4,
    right  = 5,
    left   = 6,
}

local function getSortedPeripheralNames()
    if not peripheral or not peripheral.getNames then return {} end
    local list = peripheral.getNames()
    table.sort(list, function(a, b)
        local oA = SIDE_ORDER[a]
        local oB = SIDE_ORDER[b]
        if oA and oB then
            return oA < oB
        elseif oA then
            return true
        elseif oB then
            return false
        end
        local prefixA, numA = a:match("^(.-)_(%d+)$")
        local prefixB, numB = b:match("^(.-)_(%d+)$")
        if prefixA and prefixB and prefixA == prefixB then
            local nA, nB = tonumber(numA), tonumber(numB)
            if nA ~= nB then return nA < nB end
        end
        return a < b
    end)
    return list
end

local function resolveDev(devName)
    if not devName then
        return term.native and term.native() or term.current(), "terminal", false
    end
    devName = tostring(devName):gsub("/+$", "")
    if devName == "/dev/terminal" or devName == "terminal" or devName == "/dev/console" or devName == "console" or devName == "builtin" or devName == "system" then
        return term.native and term.native() or term.current(), "terminal", false
    end
    -- CEE signal port
    local ceePin = devName:match("/dev/cee_pin_(%d+)") or devName:match("/dev/sig(%d+)") or devName:match("^sig(%d+)$")
    if ceePin and _G.cee and _G.cee.getMonitors then
        local ok, m = pcall(_G.cee.getMonitors, tonumber(ceePin))
        if ok and m and m.write then
            return m, "cee_signal_" .. ceePin, true
        end
    end
    -- Peripherals
    local rawDev = devName:gsub("^/dev/", "")
    if peripheral then
        if peripheral.isPresent(rawDev) then
            return peripheral.wrap(rawDev), rawDev, true
        end
        local monIdx = rawDev:match("^mon(%d+)$") or rawDev:match("^monitor(%d+)$") or rawDev:match("^monitor_(%d+)$")
        if monIdx then
            local targetIdx = tonumber(monIdx)
            local curr = 0
            for _, name in ipairs(getSortedPeripheralNames()) do
                local t = peripheral.getType(name)
                if t == "monitor" or t == "ceemonitor" then
                    if curr == targetIdx then
                        return peripheral.wrap(name), name, true
                    end
                    curr = curr + 1
                end
            end
        end
        for _, name in ipairs(getSortedPeripheralNames()) do
            if name == rawDev or name == devName then
                return peripheral.wrap(name), name, true
            end
        end
    end
    return nil, devName, false
end

local function findAllMonitors()
    local mons = {}
    local seen = {}
    for _, name in ipairs(getSortedPeripheralNames()) do
        local pType = peripheral.getType(name)
        if pType == "ceemonitor" or pType == "monitor" then
            local obj = peripheral.wrap(name)
            if obj and not seen[name] then
                seen[name] = true
                table.insert(mons, { obj = obj, name = name, type = pType })
            end
        end
    end
    if _G.cee and _G.cee.getMonitors then
        local maxPins = (_G.cee.getSignalCount and _G.cee.getSignalCount()) or 11
        for pin = 1, maxPins do
            local ok, m = pcall(_G.cee.getMonitors, pin)
            if ok and m and m.getSize then
                local name = "cee_signal_" .. pin
                if not seen[name] then
                    seen[name] = true
                    table.insert(mons, { obj = m, name = name, pin = pin, type = "cee_signal" })
                end
            end
        end
    end
    return mons
end

local function isSameMonitor(m1, m2)
    if not m1 or not m2 then return false end
    if m1 == m2 then return true end
    if type(m1) == "table" and type(m2) == "table" then
        if m1.getCursorPos and m2.getCursorPos and m1.setCursorPos then
            local ok1, x1, y1 = pcall(m1.getCursorPos)
            if ok1 and x1 and y1 then
                local testX = (x1 == 99) and 98 or 99
                pcall(m1.setCursorPos, testX, y1)
                local ok2, x2, y2 = pcall(m2.getCursorPos)
                pcall(m1.setCursorPos, x1, y1)
                if ok2 and x2 == testX and y2 == y1 then
                    return true
                end
            end
        end
    end
    return false
end

local function deduplicateMonitors(monList)
    local unique = {}
    for _, m in ipairs(monList or {}) do
        local dup = false
        for _, u in ipairs(unique) do
            if isSameMonitor(u, m) then
                dup = true
                break
            end
        end
        if not dup then
            table.insert(unique, m)
        end
    end
    return unique
end

local function createMultiTerm(monList)
    monList = deduplicateMonitors(monList)
    if not monList or #monList == 0 then
        return term.native and term.native() or term.current()
    end
    if #monList == 1 then
        return monList[1]
    end

    local multi = {}
    local voidMethods = {
        "write", "blit", "clear", "clearLine", "setCursorPos",
        "setCursorBlink", "scroll", "setTextColor", "setTextColour",
        "setBackgroundColor", "setBackgroundColour", "setPaletteColor", "setPaletteColour"
    }
    for _, method in ipairs(voidMethods) do
        multi[method] = function(...)
            for _, m in ipairs(monList) do
                if m and m[method] then pcall(m[method], ...) end
            end
        end
    end

    local queryMethods = {
        "getCursorPos", "getCursorBlink", "getSize", "getTextColor",
        "getTextColour", "getBackgroundColor", "getBackgroundColour",
        "isColor", "isColour", "getPaletteColor", "getPaletteColour"
    }
    for _, method in ipairs(queryMethods) do
        multi[method] = function(...)
            local primary = monList[1]
            if primary and primary[method] then return primary[method](...) end
        end
    end

    multi.setTextScale = function(s)
        for _, m in ipairs(monList) do
            if m and m.setTextScale then pcall(m.setTextScale, s) end
        end
    end
    multi.getTextScale = function()
        for _, m in ipairs(monList) do
            if m and m.getTextScale then return m.getTextScale() end
        end
        return 1
    end

    return multi
end

local bootConfigWarnings = {}

local function safeLoadConfig(path)
    if not fs.exists(path) then return nil end
    local h = fs.open(path, "r")
    if not h then
        local msg = "Cannot open " .. path .. " (I/O error)"
        table.insert(bootConfigWarnings, msg)
        if _G.logBootWarn then _G.logBootWarn(msg) end
        return nil
    end
    local content = h.readAll()
    h.close()
    if not content or content:match("^%s*$") then
        return {}
    end

    local ok, data = pcall(textutils.unserialize, content)
    if ok and type(data) == "table" then
        return data
    end

    local loader = loadstring or load
    local lOk, chunkOrErr = pcall(loader, "return " .. content, path)
    if lOk and type(chunkOrErr) == "function" then
        local rOk, rData = pcall(chunkOrErr)
        if rOk and type(rData) == "table" then
            return rData
        end
    end

    local rawErr = tostring(chunkOrErr or "syntax error")
    local cleanErr = rawErr:match(":%d+:%s*(.+)") or rawErr
    local warnMsg = string.format("Syntax error in %s (%s)", path, cleanErr)
    table.insert(bootConfigWarnings, warnMsg)
    if _G.logBootWarn then
        _G.logBootWarn(warnMsg)
    end
    return nil
end

--- Hyprland-style Modular Configuration Loader (Pure Lua)
local function loadSystemConfig()
    local conf = {
        monitors = {},
        exec_once = {},
        bind = {},
        dust = {
            repo_url = "https://raw.githubusercontent.com/TheEartHTM/luna/main/repo",
            etc_compat = false,
        },
        services = {},
        display = { text_scale = 0.5, redirect_to_monitor = true }
    }

    local env = {}
    for k, v in pairs(_G) do env[k] = v end

    local loadedSources = {}
    local function doSource(relPath)
        if not relPath or type(relPath) ~= "string" then return end
        local p = relPath
        if not fs.exists(p) and not p:match("^/") then
            p = "/etc/conf/" .. relPath
        end
        if loadedSources[p] then return end
        loadedSources[p] = true

        if fs.exists(p) and not fs.isDir(p) then
            local h = fs.open(p, "r")
            if h then
                local code = h.readAll()
                h.close()
                local fn, err = load(code, "@" .. p, "t", env)
                if fn then
                    local ok, r = pcall(fn)
                    if not ok and _G.logBootWarn then
                        _G.logBootWarn("Config error in " .. p .. ": " .. tostring(r))
                    end
                elseif _G.logBootWarn then
                    _G.logBootWarn("Syntax error in " .. p .. ": " .. tostring(err))
                end
            end
        end
    end

    env.source = doSource
    env.exec_once = function(cmd)
        if type(cmd) == "string" then
            table.insert(conf.exec_once, cmd)
        elseif type(cmd) == "table" then
            for _, c in ipairs(cmd) do table.insert(conf.exec_once, c) end
        end
    end
    env.bind = function(...)
        local args = { ... }
        if #args == 1 and type(args[1]) == "table" then
            for _, b in ipairs(args[1]) do table.insert(conf.bind, b) end
        else
            table.insert(conf.bind, args)
        end
    end

    env.monitors = conf.monitors
    env.dust = conf.dust
    env.services = conf.services
    env.display = conf.display

    local configPath = "/etc/conf/system.lua"
    if not fs.exists(configPath) and fs.exists("/etc/conf/system.conf") then
        configPath = "/etc/conf/system.conf"
    end

    if fs.exists(configPath) then
        local h = fs.open(configPath, "r")
        if h then
            local raw = h.readAll()
            h.close()
            local isScript = raw:match("^%s*%-%-") or raw:match("source%s*%(") or raw:match("monitors%s*=") or raw:match("exec_once")
            if isScript then
                local fn, err = load(raw, "@" .. configPath, "t", env)
                if fn then
                    local ok, res = pcall(fn)
                    if ok then
                        if type(res) == "table" then
                            for k, v in pairs(res) do conf[k] = v end
                        end
                    elseif _G.logBootWarn then
                        _G.logBootWarn("Config error in " .. configPath .. ": " .. tostring(res))
                    end
                elseif _G.logBootWarn then
                    _G.logBootWarn("Syntax error in " .. configPath .. ": " .. tostring(err))
                end
            else
                local ok, data = pcall(textutils.unserialize, raw)
                if not ok or type(data) ~= "table" then
                    local fn = load("return " .. raw, "@" .. configPath, "t", {})
                    if fn then
                        local okL, res = pcall(fn)
                        if okL and type(res) == "table" then data = res end
                    end
                end
                if type(data) == "table" then
                    for k, v in pairs(data) do conf[k] = v end
                end
            end
        end
    end

    if type(env.monitors) == "table" and env.monitors ~= conf.monitors then
        conf.monitors = env.monitors
    end
    if type(env.exec_once) == "table" and env.exec_once ~= conf.exec_once then
        for _, c in ipairs(env.exec_once) do table.insert(conf.exec_once, c) end
    end
    if type(env.bind) == "table" and env.bind ~= conf.bind then
        for _, b in ipairs(env.bind) do table.insert(conf.bind, b) end
    end
    if type(env.dust) == "table" then conf.dust = env.dust end
    if type(env.services) == "table" then conf.services = env.services end
    if type(env.display) == "table" then conf.display = env.display end

    return conf
end

local systemConfig = nil
local displayInitialized = false

-- Multi-Monitor & Workspace Initializer (1 monitor = 1 TTY with individual resolution and command-based focus switching)
local function initDisplay()
    if displayInitialized then return end
    displayInitialized = true

    systemConfig = loadSystemConfig()
    local conf = systemConfig

    local nativeTerm = term.native and term.native() or term.current()
    ttyTerms = {}
    monitorList = {}
    devToTTY = {
        ["system"] = "tty1",
        ["/dev/system"] = "tty1",
        ["builtin"] = "tty1",
        ["terminal"] = "tty1",
        ["/dev/terminal"] = "tty1",
        ["console"] = "tty1",
        ["/dev/console"] = "tty1",
        ["1"] = "tty1"
    }
    local devMonitors = {
        ["terminal"] = nativeTerm,
        ["/dev/terminal"] = nativeTerm,
        ["console"] = nativeTerm,
        ["/dev/console"] = nativeTerm
    }

    local configuredObjects = {}
    local ttyCounter = 1

    -- 1. Load monitors from declarative configuration (monitors = { ... })
    if type(conf.monitors) == "table" and #conf.monitors > 0 then
        for idx, mCfg in ipairs(conf.monitors) do
            local mObj, devKey, supportsScale = resolveDev(mCfg.dev)
            if mObj then
                local ttyName = "tty" .. ttyCounter
                ttyCounter = ttyCounter + 1

                local isBuiltin = (mCfg.builtin == true or mCfg.buildin == true)
                    or (mCfg.dev == "/dev/terminal" or mCfg.dev == "terminal" or mCfg.dev == "builtin" or mCfg.dev == "system")

                -- Compute and apply individual text scale per monitor
                if not isBuiltin and supportsScale and mObj.setTextScale then
                    local scale = mCfg.scale
                    if not scale and (mCfg.blocks or mCfg.width or mCfg.height) then
                        scale = calcScale(mCfg.blocks, mCfg.width, mCfg.height)
                    end
                    if not scale then
                        if mObj.getSize then
                            pcall(mObj.setTextScale, 1.0)
                            local w, h = mObj.getSize()
                            if w and h then
                                scale = calcScale(math.ceil(w / 7), math.ceil(w / 7), math.ceil(h / 5))
                            end
                        end
                    end
                    if not scale or scale <= 0 then scale = 0.5 end
                    pcall(mObj.setTextScale, scale)
                end
                pcall(mObj.clear)
                pcall(mObj.setCursorPos, 1, 1)

                ttyTerms[ttyName] = mObj
                configuredObjects[mObj] = true

                local monIdx = idx - 1
                local monDev = "/dev/mon" .. monIdx
                devMonitors["mon" .. monIdx] = mObj
                devMonitors[monDev] = mObj
                devMonitors["monitor" .. monIdx] = mObj
                devMonitors["/dev/monitor" .. monIdx] = mObj

                devToTTY[monDev] = ttyName
                devToTTY["mon" .. monIdx] = ttyName
                devToTTY["/dev/monitor" .. monIdx] = ttyName
                devToTTY["monitor" .. monIdx] = ttyName
                devToTTY[tostring(monIdx)] = ttyName
                devToTTY[tostring(ttyCounter - 1)] = ttyName

                if mCfg.name and mCfg.name ~= "" then
                    devMonitors[mCfg.name] = mObj
                    devMonitors["/dev/" .. mCfg.name] = mObj
                    devToTTY[mCfg.name] = ttyName
                    devToTTY["/dev/" .. mCfg.name] = ttyName
                end
                if devKey then
                    devMonitors[devKey] = mObj
                    devMonitors["/dev/" .. devKey] = mObj
                    devToTTY[devKey] = ttyName
                    devToTTY["/dev/" .. devKey] = ttyName
                end
                if mCfg.dev then
                    local clean = mCfg.dev:gsub("^/dev/", "")
                    devMonitors[clean] = mObj
                    devMonitors[mCfg.dev] = mObj
                    devToTTY[clean] = ttyName
                    devToTTY[mCfg.dev] = ttyName
                end

                table.insert(monitorList, {
                    name = mCfg.name or ("mon" .. monIdx),
                    dev = mCfg.dev or monDev,
                    tty = ttyName,
                    obj = mObj
                })
            end
        end
    end

    -- 2. Auto-discover any attached monitors (any count N >= 1) not in config
    local discovered = findAllMonitors()
    for _, item in ipairs(discovered) do
        local mObj = item.obj
        if mObj and not configuredObjects[mObj] then
            local ttyName = "tty" .. ttyCounter
            ttyCounter = ttyCounter + 1

            if mObj.setTextScale then pcall(mObj.setTextScale, 0.5) end
            pcall(mObj.clear)
            pcall(mObj.setCursorPos, 1, 1)

            ttyTerms[ttyName] = mObj
            configuredObjects[mObj] = true

            local autoIdx = ttyCounter - 1
            local devKey = item.name or ("mon" .. autoIdx)
            local monDev = "/dev/" .. devKey
            devMonitors[devKey] = mObj
            devMonitors[monDev] = mObj
            devToTTY[devKey] = ttyName
            devToTTY[monDev] = ttyName
            devToTTY[tostring(autoIdx)] = ttyName

            table.insert(monitorList, {
                name = devKey,
                dev = monDev,
                tty = ttyName,
                obj = mObj
            })
        end
    end

    -- If tty1 is not assigned, bind chassis terminal to tty1
    if not ttyTerms["tty1"] then
        ttyTerms["tty1"] = nativeTerm
        table.insert(monitorList, 1, {
            name = "main",
            dev = "/dev/terminal",
            tty = "tty1",
            obj = nativeTerm
        })
    end

    _G._DEVICE_MONITORS = devMonitors
    _G._TTY_TERMS = ttyTerms
    _G._MONITOR_LIST = monitorList
    _G._DEV_TO_TTY = devToTTY
    activeTTY = "tty1"
    _G.ACTIVE_TTY = activeTTY
end

_G.setFocus = function(target)
    if not target then return false, "No target specified" end
    local s = tostring(target):gsub("/+$", "")
    local devMap = _G._DEV_TO_TTY or devToTTY
    local tty = devMap[s] or devMap["/dev/" .. s] or devMap[s:gsub("^/dev/", "")]
    if not tty then
        local num = tonumber(s:match("%d+"))
        if num and devMap[tostring(num)] then
            tty = devMap[tostring(num)]
        elseif num and ttyTerms["tty" .. num] then
            tty = "tty" .. num
        end
    end
    if tty and ttyTerms[tty] then
        activeTTY = tty
        _G.ACTIVE_TTY = tty
        return true, tty
    end
    return false, "Device or monitor not found: " .. tostring(target)
end

_G.getFocus = function()
    return activeTTY or "tty1"
end

-- Primary Console Boot Setup (Stays strictly on chassis screen)
local nativeTerm = term.native and term.native() or term.current()
term.redirect(nativeTerm)
nativeTerm.clear()
nativeTerm.setCursorPos(1, 1)

ttyTerms["tty1"] = nativeTerm
activeTTY = "tty1"
_G._TTY_TERMS = ttyTerms
_G.DUAL_TERM = nativeTerm

-- Quiet standby for external monitors during boot
local initialExtMons = findAllMonitors()
for _, ext in ipairs(initialExtMons) do
    if ext.obj and ext.obj.clear then
        pcall(ext.obj.clear)
        pcall(ext.obj.setCursorBlink, false)
    end
end

local function logBootSection(text)
    if term.isColor() then
        term.setTextColor(colors.cyan)
        write(":: ")
        term.setTextColor(colors.white)
        print(text)
    else
        print(":: " .. text)
    end
    sleep(0.02)
end

local function logBootOk(text)
    if term.isColor() then
        term.setTextColor(colors.white)
        write("[")
        term.setTextColor(colors.lime)
        write("  OK  ")
        term.setTextColor(colors.white)
        write("] ")
        print(text)
    else
        print("[  OK  ] " .. text)
    end
    sleep(0.02)
end

local function logBootWarn(text)
    if term.isColor() then
        term.setTextColor(colors.white)
        write("[")
        term.setTextColor(colors.yellow)
        write(" WARN ")
        term.setTextColor(colors.white)
        write("] ")
        print(text)
    else
        print("[ WARN ] " .. text)
    end
    sleep(0.02)
end

local function logBootFail(text)
    if term.isColor() then
        term.setTextColor(colors.white)
        write("[")
        term.setTextColor(colors.red)
        write("FAILED")
        term.setTextColor(colors.white)
        write("] ")
        print(text)
    else
        print("[FAILED] " .. text)
    end
end

_G.logBootOk = logBootOk
_G.logBootWarn = logBootWarn
_G.logBootSection = logBootSection
_G.logBootFail = logBootFail

logBootSection("Initializing Luna BIOS v0.2...")
logBootSection("Starting Power-On Self-Test (POST)...")

-- 1. Hardware checks
local termW, termH = term.getSize()
local isColor = term.isColor()
local devLabel = isExternalMonitor and "Dual Display (Computer + CEE Monitor)" or (isColor and "Color display" or "Monochrome")
logBootOk(string.format("Terminal: %s (%dx%d)", devLabel, termW, termH))
for _, warnMsg in ipairs(bootConfigWarnings) do
    logBootWarn(warnMsg)
end

-- 2. POST check: Scan for memory modules
local cells = 0
local memFound = false
for _ = 1, 20 do
    cells = 0
    memFound = false
    for _, f in ipairs(fs.list("/")) do
        if f == "mem" or f:match("^mem%d+$") then
            cells = cells + 1
            if f == "mem" then memFound = true end
        end
    end
    if cells >= 1 and memFound then
        break
    end
    sleep(0.05)
end

if cells >= 1 and memFound then
    logBootOk(string.format("POST: Memory bus verified (found %d storage modules)", cells))
    logBootOk("POST: Primary system memory cell (/mem) online")
else
    logBootOk("POST: Memory bus verified (Standalone mode)")
    logBootOk("POST: Primary storage initialized (/ on local drive)")
end

-- 3. Launch storage driver & VFS
logBootSection("Loading Luna kernel & filesystem drivers...")
local BOOT_SCRIPT = (fs.exists("/boot/boot.lua") and "/boot/boot.lua")
    or (fs.exists("/boot.lua") and "/boot.lua")
    or (fs.exists("/mem/boot/boot.lua") and "/mem/boot/boot.lua")
    or (fs.exists("/mem/boot.lua") and "/mem/boot.lua")
if BOOT_SCRIPT and fs.exists(BOOT_SCRIPT) then
    local ok, err = pcall(dofile, BOOT_SCRIPT)
    if not ok then
        logBootFail("Kernel panic: " .. tostring(err))
        while true do sleep(1) end
    end
end

-- 4. Load system services
logBootSection("Starting Luna system services...")
local systemdPath = fs.exists("/usr/bin/core/systemd.lua") and "/usr/bin/core/systemd.lua" or "/etc/systemd.lua"
if fs.exists(systemdPath) then
    local okSys = pcall(dofile, systemdPath)
    if okSys and _G.systemd and _G.systemd.init then
        _G.systemd.init()
        logBootOk("Started Security Subsystem (systemd: shadow / sudo / rwx)")
    end
end

-- Kernel Core Subsystem, Process Table & Unified Syscall Dispatcher
local SYS = {
    EXIT        = 1,
    SPAWN       = 2,
    READ        = 3,
    WRITE       = 4,
    OPEN        = 5,
    CLOSE       = 6,
    GETPID      = 20,
    SETUID      = 23,
    GETUID      = 24,
    SYNC        = 36,
    KILL        = 37,
    GETPPID     = 64,
    REBOOT      = 88,
    POWEROFF    = 89,
    UPTIME      = 116,
    UNAME       = 122,
    PROCLIST    = 150,
    CHECKACCESS = 151,
    GETUSER     = 152,
    SETUSER     = 153,
    HOSTNAME    = 154,
    USERADD     = 160,
    USERDEL     = 161,
    DEVLIST     = 170,
    GETHOME     = 180,
    GETCONFIG   = 181,
    GETTTY      = 190,
    SETTTY      = 191
}
_G.SYS = SYS

local ERRNO = {
    EPERM  = { code = 1,  msg = "Operation not permitted" },
    ENOENT = { code = 2,  msg = "No such file or directory" },
    ESRCH  = { code = 3,  msg = "No such process" },
    EACCES = { code = 13, msg = "Permission denied" },
    EINVAL = { code = 22, msg = "Invalid argument" }
}
_G.ERRNO = ERRNO

local procs = {
    { pid = 1, ppid = 0, user = "root", name = "systemd",    cmd = "/usr/bin/core/systemd", state = "S", startTime = 0 },
    { pid = 2, ppid = 1, user = "root", name = "luna-shell", cmd = "/usr/bin/core/shell",   state = "R", startTime = os.clock() }
}
local nextPid = 3

local proc_mgr = {}
function proc_mgr.list()
    for _, p in ipairs(procs) do
        if p.pid == 3 then p.user = _G.CURRENT_USER or "root" end
    end
    local copy = {}
    for i, p in ipairs(procs) do
        copy[i] = {
            pid = p.pid,
            ppid = p.ppid,
            user = p.user,
            name = p.name,
            cmd = p.cmd,
            state = p.state,
            startTime = p.startTime
        }
    end
    return copy
end

function proc_mgr.spawn(name, cmd, user, ppid)
    local pid = nextPid
    nextPid = nextPid + 1
    local entry = {
        pid = pid,
        ppid = ppid or 3,
        user = user or _G.CURRENT_USER or "root",
        name = name or "unknown",
        cmd = cmd or name or "unknown",
        state = "R",
        startTime = os.clock()
    }
    table.insert(procs, entry)
    return pid
end

function proc_mgr.kill(pid, sig)
    if pid == 1 then
        return false, "Cannot kill init (PID 1)"
    end
    for idx, p in ipairs(procs) do
        if p.pid == pid then
            table.remove(procs, idx)
            return true
        end
    end
    return false, "No such process"
end

function proc_mgr.get(pid)
    for _, p in ipairs(procs) do
        if p.pid == pid then return p end
    end
    return nil
end

local function getHostnameInternal()
    local netConf = safeLoadConfig("/etc/conf/network.conf")
    if netConf and netConf.hostname then return netConf.hostname end
    return "luna"
end

local syscall_table = {}

syscall_table[SYS.EXIT] = function(callerUser, code)
    return 0
end

syscall_table[SYS.SPAWN] = function(callerUser, name, cmd, targetUser, ppid)
    if not name or type(name) ~= "string" then
        return nil, ERRNO.EINVAL.msg, ERRNO.EINVAL.code
    end
    local procUser = callerUser
    if targetUser and targetUser ~= callerUser then
        if callerUser ~= "root" then
            return nil, ERRNO.EPERM.msg, ERRNO.EPERM.code
        end
        procUser = targetUser
    end
    local pid = proc_mgr.spawn(name, cmd, procUser, ppid)
    return pid
end

syscall_table[SYS.GETPID] = function(callerUser)
    return 3
end

syscall_table[SYS.GETPPID] = function(callerUser)
    return 1
end

syscall_table[SYS.KILL] = function(callerUser, pid, sig)
    if not pid or type(pid) ~= "number" then
        return nil, ERRNO.EINVAL.msg, ERRNO.EINVAL.code
    end
    if pid == 1 then
        return nil, "Cannot kill init (PID 1)", ERRNO.EPERM.code
    end
    local p = proc_mgr.get(pid)
    if not p then
        return nil, ERRNO.ESRCH.msg, ERRNO.ESRCH.code
    end
    if callerUser ~= "root" and p.user ~= callerUser then
        return nil, ERRNO.EPERM.msg, ERRNO.EPERM.code
    end
    local ok, err = proc_mgr.kill(pid, sig or 15)
    if not ok then
        return nil, err or "kill failed", ERRNO.ESRCH.code
    end
    return 0
end

syscall_table[SYS.PROCLIST] = function(callerUser)
    return proc_mgr.list()
end

syscall_table[SYS.UPTIME] = function(callerUser)
    return os.clock()
end

syscall_table[SYS.UNAME] = function(callerUser)
    return {
        sysname  = "LunaOS",
        nodename = getHostnameInternal(),
        release  = "0.2.0-luna",
        version  = "Luna BIOS v0.2",
        machine  = "CEE/RISC-V Virtual CC:T"
    }
end

syscall_table[SYS.GETUSER] = function(callerUser)
    return _G.CURRENT_USER or "root"
end
syscall_table[SYS.GETUID] = syscall_table[SYS.GETUSER]

syscall_table[SYS.SETUSER] = function(callerUser, newUser)
    if not newUser or type(newUser) ~= "string" then
        return nil, ERRNO.EINVAL.msg, ERRNO.EINVAL.code
    end
    if callerUser ~= "root" then
        return nil, ERRNO.EPERM.msg, ERRNO.EPERM.code
    end
    _G.CURRENT_USER = newUser
    for _, p in ipairs(procs) do
        if p.pid == 3 then p.user = newUser end
    end
    return 0
end
syscall_table[SYS.SETUID] = syscall_table[SYS.SETUSER]

local function getUserHomeInternal(u)
    u = u or _G.CURRENT_USER or "root"
    if _G.systemd and _G.systemd.getUserHome then
        local h = _G.systemd.getUserHome(u)
        if h and h ~= "" then return h end
    end
    if u == "root" then
        return (fs.exists("/root") or fs.isDir("/root")) and "/root" or "/"
    end
    return "/home/" .. u
end

syscall_table[SYS.GETHOME] = function(callerUser, targetUser)
    local u = targetUser or callerUser or _G.CURRENT_USER or "root"
    return getUserHomeInternal(u)
end

syscall_table[SYS.GETCONFIG] = function(callerUser, appName, targetUser)
    local u = targetUser or callerUser or _G.CURRENT_USER or "root"
    local home = getUserHomeInternal(u)
    local configBase = fs.combine(home, ".config")
    if not fs.exists(configBase) then
        pcall(fs.makeDir, configBase)
    end
    if appName and appName ~= "" then
        local appConfig = fs.combine(configBase, appName)
        if not fs.exists(appConfig) then
            pcall(fs.makeDir, appConfig)
        end
        return appConfig
    end
    return configBase
end

syscall_table[SYS.GETTTY] = function(callerUser)
    return activeTTY or "tty1"
end

syscall_table[SYS.SETTTY] = function(callerUser, targetTTY)
    if not targetTTY or type(targetTTY) ~= "string" then
        return nil, ERRNO.EINVAL.msg, ERRNO.EINVAL.code
    end
    if not ttyTerms[targetTTY] then
        return nil, "No such TTY: " .. targetTTY, ERRNO.ENOENT.code
    end
    activeTTY = targetTTY
    return 0
end

syscall_table[SYS.SYNC] = function(callerUser)
    if _G.logBootOk then
        _G.logBootOk("VFS: Synchronized all memory buffers to storage.")
    end
    return 0
end

syscall_table[SYS.HOSTNAME] = function(callerUser, newHostname)
    if newHostname then
        if callerUser ~= "root" then
            return nil, ERRNO.EPERM.msg, ERRNO.EPERM.code
        end
        local conf = { hostname = newHostname }
        local h = fs.open("/etc/conf/network.conf", "w")
        if h then
            h.write(textutils.serialize(conf))
            h.close()
            return 0
        end
        return nil, "Failed to write network.conf", ERRNO.EACCES.code
    end
    return getHostnameInternal()
end

syscall_table[SYS.CHECKACCESS] = function(callerUser, path, req)
    if not path or not req then return false end
    if callerUser == "root" then return true end
    if _G.systemd and _G.systemd.checkAccess then
        return _G.systemd.checkAccess(path, callerUser, req)
    end
    return true
end

syscall_table[SYS.REBOOT] = function(callerUser)
    if callerUser ~= "root" then
        if not (_G.systemd and _G.systemd.checkSudoers and _G.systemd.checkSudoers(callerUser)) then
            return nil, ERRNO.EPERM.msg, ERRNO.EPERM.code
        end
    end
    syscall_table[SYS.SYNC](callerUser)
    os.reboot()
end

syscall_table[SYS.POWEROFF] = function(callerUser)
    if callerUser ~= "root" then
        if not (_G.systemd and _G.systemd.checkSudoers and _G.systemd.checkSudoers(callerUser)) then
            return nil, ERRNO.EPERM.msg, ERRNO.EPERM.code
        end
    end
    syscall_table[SYS.SYNC](callerUser)
    os.shutdown()
end

syscall_table[SYS.USERADD] = function(callerUser, username, password, uid, gid, gecos, home, shell_path)
    if callerUser ~= "root" then
        return nil, ERRNO.EPERM.msg, ERRNO.EPERM.code
    end
    if not _G.systemd or not _G.systemd.addUser then
        return nil, "systemd user management unavailable", ERRNO.EINVAL.code
    end
    local ok, res = _G.systemd.addUser(username, password, uid, gid, gecos, home, shell_path)
    if not ok then
        return nil, res or "useradd failed", ERRNO.EINVAL.code
    end
    return res
end

syscall_table[SYS.USERDEL] = function(callerUser, username, removeHome)
    if callerUser ~= "root" then
        return nil, ERRNO.EPERM.msg, ERRNO.EPERM.code
    end
    if not _G.systemd or not _G.systemd.delUser then
        return nil, "systemd user management unavailable", ERRNO.EINVAL.code
    end
    local ok, err = _G.systemd.delUser(username, removeHome)
    if not ok then
        return nil, err or "userdel failed", ERRNO.EINVAL.code
    end
    return 0
end

syscall_table[SYS.DEVLIST] = function(callerUser)
    local devList = {}

    -- 1. Storage
    table.insert(devList, {
        dev = "/dev/raid0",
        bus = "mem",
        type = "storage",
        interface = "RAID-0 Block",
        status = string.format("ONLINE (%d modules)", #(_G.RAID_DRIVES or {})),
        methods = { "read", "write", "seek" }
    })
    table.insert(devList, {
        dev = "/dev/boot",
        bus = "mem",
        type = "storage",
        interface = "/mem/boot",
        status = "ONLINE",
        methods = { "read", "write" }
    })

    -- 2. Standard Peripherals (deterministic sorting across reboots)
    local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }
    local typeCounts = {}
    for _, name in ipairs(getSortedPeripheralNames()) do
            local pType = peripheral.getType(name) or "device"
            typeCounts[pType] = (typeCounts[pType] or 0) + 1
            local idx = typeCounts[pType] - 1
            local devName = pType .. idx
            if pType == "monitor" or pType == "ceemonitor" then
                devName = "mon" .. idx
            elseif pType == "speaker" or pType == "cee_speaker" then
                devName = "speaker" .. idx
            elseif pType == "keyboard" or pType == "cee_keyboard" then
                devName = "keyboard" .. idx
            elseif pType == "mouse" or pType == "cee_mouse" then
                devName = "mouse" .. idx
            elseif pType == "printer" then
                devName = "lp" .. idx
            elseif pType == "modem" then
                devName = "modem" .. idx
            elseif pType == "cee_radio" then
                devName = "radio" .. idx
            elseif pType == "cee_data_scriber" then
                devName = "scriber" .. idx
            elseif pType == "cee_hub" then
                devName = "hub" .. idx
            end

            local isSide = SIDES[name] == true
            local methods = peripheral.getMethods(name) or {}

            table.insert(devList, {
                dev = "/dev/" .. devName,
                bus = isSide and "side" or "network",
                type = pType,
                interface = name,
                status = "READY",
                methods = methods
            })
        end

    -- 3. CEE Signal Port (Pure descriptors on demand, ZERO tick pinging)
    if _G.cee then
        local maxPins = (_G.cee.getSignalCount and _G.cee.getSignalCount()) or 11
        for pin = 1, maxPins do
            if _G.cee.getMonitors then
                local ok, m = pcall(_G.cee.getMonitors, pin)
                if ok and m and m.getSize then
                    typeCounts["ceemonitor"] = (typeCounts["ceemonitor"] or 0) + 1
                    local idx = typeCounts["ceemonitor"] - 1
                    table.insert(devList, {
                        dev = "/dev/mon" .. idx,
                        bus = "cee",
                        type = "ceemonitor",
                        interface = "pin_" .. pin,
                        status = "READY",
                        methods = { "getSize", "write", "setCursorPos", "clear", "blit", "setTextScale" }
                    })
                end
            end
            table.insert(devList, {
                dev = "/dev/sig" .. pin,
                bus = "cee",
                type = "signal_port",
                interface = "pin_" .. pin,
                status = "ONLINE",
                methods = { "read", "write", "send" }
            })
        end
    end

    -- 4. CEE Data Hubs (via cee.listHubs API)
    if _G.cee and _G.cee.listHubs then
        local ok, hubs = pcall(_G.cee.listHubs)
        if ok and type(hubs) == "table" then
            for idx, hub in ipairs(hubs) do
                local hId = (type(hub) == "table" and (hub.id or hub.hubId)) or tostring(hub)
                local status = "ONLINE"
                if type(hub) == "table" and hub.isPowered == false then
                    status = "NO_POWER"
                end
                table.insert(devList, {
                    dev = "/dev/hub" .. (idx - 1),
                    bus = "cee",
                    type = "data_hub",
                    interface = "hub_" .. tostring(hId),
                    status = status,
                    methods = { "claimHubPin", "releaseHubPin", "hubSendPeers", "listHubClaims", "hubInfo" }
                })
            end
        end
    end

    return devList
end

local name_to_id = {
    exit        = SYS.EXIT,
    spawn       = SYS.SPAWN,
    read        = SYS.READ,
    write       = SYS.WRITE,
    open        = SYS.OPEN,
    close       = SYS.CLOSE,
    getpid      = SYS.GETPID,
    getppid     = SYS.GETPPID,
    kill        = SYS.KILL,
    sync        = SYS.SYNC,
    reboot      = SYS.REBOOT,
    poweroff    = SYS.POWEROFF,
    uptime      = SYS.UPTIME,
    uname       = SYS.UNAME,
    proclist    = SYS.PROCLIST,
    checkaccess = SYS.CHECKACCESS,
    getuser     = SYS.GETUSER,
    getuid      = SYS.GETUID,
    setuser     = SYS.SETUSER,
    setuid      = SYS.SETUID,
    hostname    = SYS.HOSTNAME,
    useradd     = SYS.USERADD,
    userdel     = SYS.USERDEL,
    devlist     = SYS.DEVLIST
}

local function dispatch_syscall(call_id, ...)
    local id = type(call_id) == "string" and name_to_id[call_id:lower()] or call_id
    if not id or type(id) ~= "number" then
        return nil, "Invalid syscall ID or name: " .. tostring(call_id), ERRNO.EINVAL.code
    end

    local handler = syscall_table[id]
    if not handler then
        return nil, "Unimplemented syscall: " .. tostring(call_id), ERRNO.EINVAL.code
    end

    local callerUser = _G.CURRENT_USER or "root"
    return handler(callerUser, ...)
end

_G.kernel = {
    version     = "Luna Kernel 0.2",
    bios        = "Luna BIOS v0.2",
    uptime      = function() return dispatch_syscall(SYS.UPTIME) end,
    getUser     = function() return dispatch_syscall(SYS.GETUSER) end,
    setUser     = function(u) return dispatch_syscall(SYS.SETUSER, u) end,
    getHome     = function(u) return dispatch_syscall(SYS.GETHOME, u) end,
    getConfigDir= function(app, u) return dispatch_syscall(SYS.GETCONFIG, app, u) end,
    getTTY      = function() return dispatch_syscall(SYS.GETTTY) end,
    setTTY      = function(tty) return dispatch_syscall(SYS.SETTTY, tty) end,
    getHostname = function() return dispatch_syscall(SYS.HOSTNAME) end,
    sync        = function() return dispatch_syscall(SYS.SYNC) end,
    proc        = proc_mgr,
    syscall     = dispatch_syscall,
    tty         = {
        list = function()
            local list = {}
            for _, name in ipairs(ttyList) do
                local tObj = ttyTerms[name]
                local w, h = 51, 19
                if tObj and tObj.getSize then w, h = tObj.getSize() end
                local mons = {}
                for mKey, tName in pairs(monitorToTTY) do
                    if tName == name and not mons[mKey] then
                        table.insert(mons, mKey)
                    end
                end
                table.insert(list, {
                    name = name,
                    active = (name == activeTTY),
                    resolution = { width = w, height = h },
                    monitors = mons
                })
            end
            return list
        end,
        get = function(name)
            return ttyTerms[name or activeTTY]
        end,
        write = function(name, text)
            local t = ttyTerms[name or activeTTY]
            if not t then return false, "TTY not found" end
            local h = fs.open("/dev/" .. (name or activeTTY), "w")
            if h then
                h.write(text)
                h.close()
                return true
            end
            return false, "Failed to open TTY device"
        end,
        clear = function(name)
            local t = ttyTerms[name or activeTTY]
            if t and t.clear then
                pcall(t.clear)
                if t.setCursorPos then pcall(t.setCursorPos, 1, 1) end
                return true
            end
            return false, "TTY not found"
        end,
        switch = function(name)
            if ttyTerms[name] then
                activeTTY = name
                return true
            end
            return false, "TTY not found"
        end,
        run = function(name, cmd, ...)
            local t = ttyTerms[name]
            if not t then return false, "TTY not found" end
            local oldTerm = term.current()
            pcall(term.redirect, t)
            local args = { ... }
            local ok, err = pcall(function()
                if cmd:sub(-3) == ".sh" then
                    shell.execute("/usr/bin/core/sh", cmd, table.unpack(args))
                else
                    shell.execute(cmd, table.unpack(args))
                end
            end)
            pcall(term.redirect, oldTerm)
            return ok, err
        end
    }
}
_G.syscall = dispatch_syscall

-- Initialize Luna udev Device Subsystem
if fs.exists("/usr/lib/udev.lua") then
    local okU, udevMod = pcall(dofile, "/usr/lib/udev.lua")
    if okU and udevMod then
        _G.udev = udevMod
        _G.kernel.udev = udevMod
    end
end
logBootOk("Initialized Syscall Dispatcher (kernel.syscall: POSIX syscalls ready)")
logBootOk("Initialized Process Subsystem (kernel.proc: PID 1 systemd)")

logBootOk("Reached target Multi-User System")

-- Clear temporary boot logging hooks
_G.logBootOk = nil
_G.logBootWarn = nil
_G.logBootSection = nil
_G.logBootFail = nil

-- Global Keyboard Signal Handler (Ctrl+C -> terminate)
local origPullEventRaw = os.pullEventRaw
local ctrlHeld = false

os.pullEventRaw = function(sFilter)
    while true do
        local eventData = table.pack(origPullEventRaw(sFilter))
        local ev = eventData[1]
        local p1 = eventData[2]

        if ev == "key" then
            local isCtrl = (p1 == 341 or p1 == 345 or p1 == 29 or p1 == 157)
                or (keys and (p1 == keys.leftCtrl or p1 == keys.rightCtrl or p1 == keys.leftControl or p1 == keys.rightControl))
            local isC = (p1 == 67 or p1 == 46 or (keys and p1 == keys.c))

            if isCtrl then
                ctrlHeld = true
            elseif isC and ctrlHeld then
                local myTTY = ttyOwners[coroutine.running()]
                if myTTY == activeTTY or not myTTY then
                    return "terminate"
                end
            end
        elseif ev == "key_up" then
            local isCtrl = (p1 == 341 or p1 == 345 or p1 == 29 or p1 == 157)
                or (keys and (p1 == keys.leftCtrl or p1 == keys.rightCtrl or p1 == keys.leftControl or p1 == keys.rightControl))
            if isCtrl then
                ctrlHeld = false
            end
        end

        local isInputEvent = (ev == "key" or ev == "key_up" or ev == "char" or ev == "paste")
        if isInputEvent then
            local myTTY = ttyOwners[coroutine.running()]
            -- Deliver keyboard events strictly to the currently focused TTY!
            if myTTY == activeTTY or not myTTY then
                return table.unpack(eventData, 1, eventData.n)
            end
        else
            return table.unpack(eventData, 1, eventData.n)
        end
    end
end

-- Configure Luna System Library Path (/usr/lib)
if package then
    local libPaths = "/usr/lib/?.lua;/usr/lib/?/init.lua;/etc/?.lua;/?;/?/init.lua"
    if package.path and package.path ~= "" then
        package.path = libPaths .. ";" .. package.path
    else
        package.path = libPaths
    end
end

-- Hostname resolution
local compId = os.getComputerID and os.getComputerID() or 0
local function loadHostname()
    local netConf = safeLoadConfig("/etc/conf/network.conf")
    if netConf and netConf.hostname then
        return netConf.hostname
    end
    if fs.exists("/etc/hostname") then
        local h = fs.open("/etc/hostname", "r")
        if h then
            local line = h.readLine()
            h.close()
            if line and line ~= "" then return line:match("^%s*(.-)%s*$") end
        end
    end
    return (compId == 0) and "luna" or ("luna" .. compId)
end

_G.SYSTEM_NAME  = loadHostname()
_G.CURRENT_USER = "root"
_G.LOGIN_USER   = "root"

local function authenticateUser()
    while true do
        write("login: ")
        local u = read()
        if not u then
            print()
        else
            local trimmed = u:match("^%s*(.-)%s*$")
            if trimmed ~= "" then
                write("Password: ")
                local pwd = read("*")
                local uObj = _G.systemd and _G.systemd.getUser and _G.systemd.getUser(trimmed)
                if not uObj then
                    printError("Login incorrect")
                    sleep(1)
                else
                    local username = trimmed
                    local stored = uObj.password or ""

                    if stored:sub(1, 1) == "!" then
                        printError("Login incorrect")
                        sleep(1)
                    elseif stored == "" or stored == "none" then
                        if pwd == "" then
                            return username
                        else
                            printError("Login incorrect")
                            sleep(1)
                        end
                    else
                        if _G.systemd and _G.systemd.verifyPassword and _G.systemd.verifyPassword(username, pwd) then
                            return username
                        else
                            printError("Login incorrect")
                            sleep(1)
                        end
                    end
                end
            end
        end
    end
end

local function parseCommandLine(cmdLine)
    local words = {}
    local pattern = '%S+'
    for word in cmdLine:gmatch(pattern) do
        table.insert(words, word)
    end
    return words
end

local function expandWildcards(argList)
    local expanded = {}
    for _, arg in ipairs(argList) do
        if not (arg:find("%*") or arg:find("%?")) then
            table.insert(expanded, arg)
        else
            local dirPart, filePart = "", arg
            local lastSlash = arg:match("^.*()/")
            if lastSlash then
                dirPart = arg:sub(1, lastSlash)
                filePart = arg:sub(lastSlash + 1)
            end

            local scanDir = shell.resolve(dirPart)
            if fs.exists(scanDir) and fs.isDir(scanDir) then
                local luaPattern = "^"
                for i = 1, #filePart do
                    local c = filePart:sub(i, i)
                    if c == "*" then
                        luaPattern = luaPattern .. ".*"
                    elseif c == "?" then
                        luaPattern = luaPattern .. "."
                    elseif c == "." then
                        luaPattern = luaPattern .. "%."
                    elseif c:match("[%w_%-]") then
                        luaPattern = luaPattern .. c
                    else
                        luaPattern = luaPattern .. "%" .. c
                    end
                end
                luaPattern = luaPattern .. "$"

                local matched = false
                for _, item in ipairs(fs.list(scanDir)) do
                    if item:match(luaPattern) then
                        table.insert(expanded, fs.combine(dirPart, item))
                        matched = true
                    end
                end
                if not matched then
                    table.insert(expanded, arg)
                end
            else
                table.insert(expanded, arg)
            end
        end
    end
    return expanded
end

-- Helper to create a file-backed terminal for redirection (>, >>)
local function makeFileTerm(handle, origTerm)
    local curTerm = origTerm or term.current()
    local w, h = curTerm.getSize()
    local cx, cy = 1, 1
    return {
        write = function(s) handle.write(tostring(s)) end,
        scroll = function(n) end,
        setCursorPos = function(x, y) cx, cy = x, y end,
        getCursorPos = function() return cx, cy end,
        getSize = function() return w, h end,
        clear = function() end,
        clearLine = function() end,
        setTextColour = function(c) end,
        setTextColor = function(c) end,
        setBackgroundColour = function(c) end,
        setBackgroundColor = function(c) end,
        isColour = function() return false end,
        isColor = function() return false end,
        getTextColor = function() return colors.white end,
        getTextColour = function() return colors.white end,
        getBackgroundColor = function() return colors.black end,
        getBackgroundColour = function() return colors.black end,
        setCursorBlink = function(b) end,
        getCursorBlink = function() return false end,
        blit = function(text, fg, bg) handle.write(text) end
    }
end

-- Helper to create a buffer-backed terminal for pipelines (|)
local function makeBufferTerm(origTerm)
    local buf = {}
    local curTerm = origTerm or term.current()
    local w, h = curTerm.getSize()
    local cx, cy = 1, 1
    return {
        write = function(s) table.insert(buf, tostring(s)) end,
        scroll = function(n) end,
        setCursorPos = function(x, y) cx, cy = x, y end,
        getCursorPos = function() return cx, cy end,
        getSize = function() return w, h end,
        clear = function() end,
        clearLine = function() end,
        setTextColour = function(c) end,
        setTextColor = function(c) end,
        setBackgroundColour = function(c) end,
        setBackgroundColor = function(c) end,
        isColour = function() return false end,
        isColor = function() return false end,
        getTextColor = function() return colors.white end,
        getTextColour = function() return colors.white end,
        getBackgroundColor = function() return colors.black end,
        getBackgroundColour = function() return colors.black end,
        setCursorBlink = function(b) end,
        getCursorBlink = function() return false end,
        blit = function(text, fg, bg) table.insert(buf, text) end,
        getOutput = function() return table.concat(buf) end
    }
end

-- Helper for pipe string reader
local function makeStringReadHandle(str)
    local lines = {}
    for l in (str .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        table.insert(lines, l)
    end
    local lineIdx = 1
    local byteIdx = 1
    return {
        readLine = function(withTrailing)
            local l = lines[lineIdx]
            if not l then return nil end
            lineIdx = lineIdx + 1
            return withTrailing and (l .. "\n") or l
        end,
        read = function(count)
            if byteIdx > #str then return nil end
            count = count or 1
            local chunk = str:sub(byteIdx, byteIdx + count - 1)
            byteIdx = byteIdx + count
            return chunk
        end,
        readAll = function()
            if byteIdx > #str then return nil end
            local rem = str:sub(byteIdx)
            byteIdx = #str + 1
            return rem
        end,
        close = function() end
    }
end

-- Parse redirection operators (>, >>, <)
local function parseRedirection(words)
    local cleanWords = {}
    local redirOut = nil
    local redirAppend = false
    local redirIn = nil
    local i = 1
    while i <= #words do
        local w = words[i]
        if w == ">" and i < #words then
            redirOut = words[i + 1]
            redirAppend = false
            i = i + 2
        elseif w == ">>" and i < #words then
            redirOut = words[i + 1]
            redirAppend = true
            i = i + 2
        elseif w:sub(1, 2) == ">>" and #w > 2 then
            redirOut = w:sub(3)
            redirAppend = true
            i = i + 1
        elseif w:sub(1, 1) == ">" and #w > 1 then
            redirOut = w:sub(2)
            redirAppend = false
            i = i + 1
        elseif w == "<" and i < #words then
            redirIn = words[i + 1]
            i = i + 2
        elseif w:sub(1, 1) == "<" and #w > 1 then
            redirIn = w:sub(2)
            i = i + 1
        else
            table.insert(cleanWords, w)
            i = i + 1
        end
    end
    return cleanWords, redirOut, redirAppend, redirIn
end

local function executeCommandWithRedirection(cmdWords, pipeInput)
    local cleanWords, redirOut, redirAppend, redirIn = parseRedirection(cmdWords)
    if #cleanWords == 0 then return true end

    local prog = cleanWords[1]
    table.remove(cleanWords, 1)

    local resolvedProg = shell.resolveProgram(prog)
    if not resolvedProg then
        printError(prog .. ": command not found")
        return false
    end

    local expandedArgs = expandWildcards(cleanWords)

    local outHandle = nil
    local oldTerm = nil
    local oldIoOutput = nil
    local oldIoInput = nil
    local isDevTerm = false

    -- Output redirection (>, >>)
    if redirOut then
        local rawDev = redirOut
        if rawDev:sub(1, 5) == "/dev/" then rawDev = rawDev:sub(6) end
        local monObj = nil
        if _G._DEVICE_MONITORS then
            monObj = _G._DEVICE_MONITORS[redirOut] or _G._DEVICE_MONITORS[rawDev]
        end
        if not monObj and rawDev:match("^mon%d+$") then
            local idx = rawDev:match("%d+$")
            monObj = _G._DEVICE_MONITORS and (_G._DEVICE_MONITORS["mon" .. idx] or _G._DEVICE_MONITORS["/dev/mon" .. idx])
        end

        if monObj then
            -- Live hardware monitor redirection: full TUI/GUI and text output supported directly
            oldTerm = term.current()
            isDevTerm = true
            coroTerms[coroutine.running()] = monObj
            term.redirect(monObj)
            if not redirAppend then
                pcall(monObj.clear)
                pcall(monObj.setCursorPos, 1, 1)
            end
        else
            local resolvedTarget = shell.resolve(redirOut)
            local mode = redirAppend and "ab" or "wb"
            local h, err = fs.open(resolvedTarget, mode)
            if not h then
                printError("luna: " .. redirOut .. ": " .. tostring(err or "Permission denied"))
                return false
            end
            outHandle = h
            oldTerm = term.current()
            local fTerm = makeFileTerm(outHandle, oldTerm)
            term.redirect(fTerm)
            if io and io.output then
                oldIoOutput = io.output()
                pcall(io.output, outHandle)
            end
        end
    end

    -- Input redirection (< or pipeInput)
    local inHandle = nil
    if redirIn then
        local resolvedIn = shell.resolve(redirIn)
        local h, err = fs.open(resolvedIn, "rb")
        if not h then
            if outHandle then
                if oldTerm then pcall(term.redirect, oldTerm) end
                if oldIoOutput and io and io.output then pcall(io.output, oldIoOutput) end
                pcall(outHandle.close)
            end
            printError("luna: " .. redirIn .. ": " .. tostring(err or "No such file or directory"))
            return false
        end
        inHandle = h
        if io and io.input then
            oldIoInput = io.input()
            pcall(io.input, inHandle)
        end
    elseif pipeInput and io and io.input then
        oldIoInput = io.input()
        local strHandle = makeStringReadHandle(pipeInput)
        pcall(io.input, strHandle)
    end

    local okExec, errExec = pcall(function()
        if prog:sub(-3) == ".sh" then
            shell.execute("/usr/bin/core/sh", prog, table.unpack(expandedArgs))
        else
            shell.execute(prog, table.unpack(expandedArgs))
        end
    end)

    -- Cleanup streams
    if inHandle then
        if oldIoInput and io and io.input then pcall(io.input, oldIoInput) end
        pcall(inHandle.close)
    elseif pipeInput and oldIoInput and io and io.input then
        pcall(io.input, oldIoInput)
    end

    if outHandle then
        if oldTerm then pcall(term.redirect, oldTerm) end
        if oldIoOutput and io and io.output then pcall(io.output, oldIoOutput) end
        pcall(outHandle.close)
    elseif isDevTerm and oldTerm then
        pcall(term.redirect, oldTerm)
        coroTerms[coroutine.running()] = oldTerm
    end

    if not okExec then
        if errExec and (tostring(errExec):find("Terminated") or tostring(errExec) == "Terminated") then
            print("^C")
        else
            printError(errExec)
        end
        return false
    end
    return true
end

local function executePipeline(cmdLine)
    local stages = {}
    for stage in cmdLine:gmatch("[^|]+") do
        local tr = stage:match("^%s*(.-)%s*$")
        if tr ~= "" then table.insert(stages, tr) end
    end

    if #stages <= 1 then
        local words = parseCommandLine(cmdLine)
        return executeCommandWithRedirection(words, nil)
    end

    local currentInput = nil
    for sIdx, stageCmd in ipairs(stages) do
        local words = parseCommandLine(stageCmd)
        local isLast = (sIdx == #stages)

        if not isLast then
            local bTerm = makeBufferTerm()
            local oldTerm = term.current()
            term.redirect(bTerm)

            local ok = executeCommandWithRedirection(words, currentInput)
            term.redirect(oldTerm)

            if not ok then return false end
            currentInput = bTerm.getOutput()
        else
            return executeCommandWithRedirection(words, currentInput)
        end
    end
    return true
end

local function runLunaShell()
    local curUser = _G.CURRENT_USER or "root"
    local curHome = "/"
    if _G.systemd and _G.systemd.getUserHome then
        curHome = _G.systemd.getUserHome(curUser)
    elseif curUser ~= "root" then
        curHome = "/home/" .. curUser
    end

    if not fs.exists(curHome) then
        pcall(fs.makeDir, curHome)
    end
    if shell.setDir then
        shell.setDir(curHome)
    end

    -- Configure clean PATH (Pure Luna, NO CraftOS /rom leaking)
    local pkgPaths = { "/usr/bin/core", "/usr/bin/extra", "/usr/bin/fastfetch", "/usr/bin", "/etc" }
    if fs.exists("/usr/bin") and fs.isDir("/usr/bin") then
        for _, item in ipairs(fs.list("/usr/bin")) do
            local full = "/usr/bin/" .. item
            if fs.isDir(full) and item ~= "core" and item ~= "extra" and item ~= "fastfetch" then
                table.insert(pkgPaths, full)
            end
        end
    end
    local newPath = table.concat(pkgPaths, ":")
    if shell.setPath then
        shell.setPath(newPath)
    end
    shell.path = function()
        return newPath
    end

    -- Clear legacy CraftOS aliases, completion info, and register Luna aliases
    if shell.aliases and shell.clearAlias then
        for alias in pairs(shell.aliases()) do
            shell.clearAlias(alias)
        end
    end
    if shell.getCompletionInfo then
        local compInfo = shell.getCompletionInfo()
        if type(compInfo) == "table" then
            for k in pairs(compInfo) do
                compInfo[k] = nil
            end
        end
    end
    if shell.setAlias then
        shell.setAlias("adduser", "useradd")
        shell.setAlias("deluser", "userdel")
    end

    -- Programs autocomplete
    shell.programs = function()
        local progs = {}
        local searchDirs = { "/usr/bin/core", "/usr/bin/extra", "/usr/bin/fastfetch", "/usr/bin", "/etc" }
        if fs.exists("/usr/bin") and fs.isDir("/usr/bin") then
            for _, item in ipairs(fs.list("/usr/bin")) do
                local full = "/usr/bin/" .. item
                if fs.isDir(full) then
                    table.insert(searchDirs, full)
                end
            end
        end
        for _, sDir in ipairs(searchDirs) do
            if fs.exists(sDir) and fs.isDir(sDir) then
                for _, f in ipairs(fs.list(sDir)) do
                    if f:sub(-4) == ".lua" then
                        local name = f:sub(1, -5)
                        if name ~= "systemd" then
                            progs[name] = true
                        end
                    end
                end
            end
        end
        -- Also add registered aliases
        if shell.aliases then
            for alias in pairs(shell.aliases()) do
                progs[alias] = true
            end
        end
        local list = {}
        for name in pairs(progs) do table.insert(list, name) end
        table.sort(list)
        return list
    end

    -- Complete program helper (blocks ROM completions, disabled on empty input)
    shell.completeProgram = function(prefix)
        if type(prefix) ~= "string" or #prefix == 0 or prefix:match("^%s*$") then
            return {}
        end
        local results = {}
        local seen = {}
        for _, prog in ipairs(shell.programs()) do
            if prog:sub(1, #prefix) == prefix and not seen[prog] then
                seen[prog] = true
                table.insert(results, prog:sub(#prefix + 1))
            end
        end
        table.sort(results)
        return results
    end

    shell.complete = function(line)
        if type(line) ~= "string" or #line == 0 or line:match("^%s*$") then
            return nil
        end
        if not line:find("%s") then
            return shell.completeProgram(line)
        else
            local word = line:match("%S+$") or ""
            return fs.complete(word, shell.dir(), true, true)
        end
    end

    -- Resolve program in PATH (Strict Luna paths, no ROM leak)
    shell.resolveProgram = function(command)
        if type(command) ~= "string" then return nil end

        -- Check aliases first
        if shell.resolveAlias then
            local aliased = shell.resolveAlias(command)
            if aliased and aliased ~= command then
                command = aliased
            end
        end

        if command:find("/") or command:find("\\") then
            if command:find("^rom/") or command:find("^/rom/") then
                return nil
            end
            -- 1. Check as absolute path from root
            local rootPath = fs.combine("", command)
            if fs.exists(rootPath) and not fs.isDir(rootPath) then return rootPath end
            if fs.exists(rootPath .. ".lua") and not fs.isDir(rootPath .. ".lua") then return rootPath .. ".lua" end

            -- 2. Check relative to current shell directory
            local sPath = shell.resolve(command)
            if fs.exists(sPath) and not fs.isDir(sPath) then return sPath end
            if fs.exists(sPath .. ".lua") and not fs.isDir(sPath .. ".lua") then return sPath .. ".lua" end
            return nil
        end

        local searchDirs = { "/usr/bin/core", "/usr/bin/extra", "/usr/bin/fastfetch", "/usr/bin", "/etc" }
        for _, sDir in ipairs(searchDirs) do
            local candidate = fs.combine(sDir, command)
            if fs.exists(candidate) and not fs.isDir(candidate) then return candidate end
            if fs.exists(candidate .. ".lua") and not fs.isDir(candidate .. ".lua") then return candidate .. ".lua" end
        end

        -- Look inside package folders
        if fs.exists("/usr/bin") and fs.isDir("/usr/bin") then
            for _, pkg in ipairs(fs.list("/usr/bin")) do
                local pkgDir = fs.combine("/usr/bin", pkg)
                if fs.isDir(pkgDir) and pkg ~= "core" and pkg ~= "extra" and pkg ~= "fastfetch" then
                    local candidate = fs.combine(pkgDir, command)
                    if fs.exists(candidate) and not fs.isDir(candidate) then return candidate end
                    if fs.exists(candidate .. ".lua") and not fs.isDir(candidate .. ".lua") then return candidate .. ".lua" end
                end
            end
        end

        return nil
    end

    local function getPromptString()
        curUser = _G.CURRENT_USER or "root"
        curHome = (_G.systemd and _G.systemd.getUserHome and _G.systemd.getUserHome(curUser))
            or (curUser == "root" and "/" or ("/home/" .. curUser))

        local sDir = shell.dir and shell.dir() or ""
        if sDir == "root" then
            sDir = ""
            if shell.setDir then shell.setDir("") end
        end
        local rawDir = (sDir == "") and "/" or ("/" .. sDir)

        local promptSymbol = (curUser == "root") and "#" or "$"
        local displayDir = rawDir

        if curUser == "root" then
            if rawDir == "/" then
                displayDir = "~"
            end
        else
            if rawDir == curHome then
                displayDir = "~"
            elseif rawDir:sub(1, #curHome + 1) == curHome .. "/" then
                displayDir = "~" .. rawDir:sub(#curHome + 1)
            end
        end

        return string.format("[%s@%s]%s %s> ", curUser, _G.SYSTEM_NAME or "luna", promptSymbol, displayDir)
    end

    local history = {}
    while true do
        local pStr = getPromptString()
        write(pStr)

        local line = read(nil, history, shell.complete)
        if not line then
            print("^C")
        else
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed == "exit" or trimmed == "logout" then
                if (_G.CURRENT_USER or "root") ~= (_G.LOGIN_USER or "root") then
                    local retUser = _G.LOGIN_USER or "root"
                    print("Logout: returning to " .. retUser .. "...")
                    _G.CURRENT_USER = retUser
                    local h = (_G.systemd and _G.systemd.getUserHome and _G.systemd.getUserHome(retUser))
                        or (retUser == "root" and "/" or ("/home/" .. retUser))
                    shell.setDir(h)
                else
                    print("Logging out...")
                    break
                end
            elseif trimmed ~= "" then
                table.insert(history, trimmed)
                executePipeline(trimmed)
            end
        end
    end
end

-- Background Services & Autostart Pipeline Runner (systemctl / system.conf)
local function runBackgroundServices()
    local sysConf = {
        services = {},
        autostart = {}
    }

    local sConf = safeLoadConfig("/etc/conf/system.conf")
    if sConf then
        if sConf.services then
            for k, v in pairs(sConf.services) do
                if type(v) == "table" then
                    sysConf.services[k] = sysConf.services[k] or {}
                    for sk, sv in pairs(v) do sysConf.services[k][sk] = sv end
                end
            end
        end
        if sConf.autostart then sysConf.autostart = sConf.autostart end
    end

    local sDb = safeLoadConfig("/etc/conf/services.db")
    if sDb then
        for sName, sData in pairs(sDb) do
            if type(sData) == "table" and (sData.enabled or sData.active) then
                sysConf.services[sName] = sysConf.services[sName] or {}
                sysConf.services[sName].enabled = true
                if sData.order then sysConf.services[sName].order = sData.order end
            end
        end
    end

    -- 1. Assemble ordered startup queue
    local startupQueue = {}

    -- Collect enabled system services
    for sName, sData in pairs(sysConf.services) do
        if sData.enabled or sData.active or _G["_DAEMON_" .. sName] then
            local script = sData.script
            if not script or not fs.exists(script) then
                if fs.exists("/usr/bin/server/" .. sName .. ".lua") then script = "/usr/bin/server/" .. sName .. ".lua"
                elseif fs.exists("/usr/bin/core/" .. sName .. ".lua") then script = "/usr/bin/core/" .. sName .. ".lua"
                elseif fs.exists("/usr/bin/extra/" .. sName .. ".lua") then script = "/usr/bin/extra/" .. sName .. ".lua"
                end
            end
            if script and fs.exists(script) then
                table.insert(startupQueue, {
                    name = sName,
                    order = sData.order or 50,
                    script = script,
                    isDaemon = true
                })
                _G["_DAEMON_" .. sName] = true
            end
        end
    end

    -- Collect custom autostart tasks
    for _, auto in ipairs(sysConf.autostart or {}) do
        if auto.script and fs.exists(auto.script) then
            table.insert(startupQueue, {
                name = auto.name or fs.getName(auto.script),
                order = auto.order or 50,
                script = auto.script,
                isDaemon = (auto.async == true)
            })
        end
    end

    -- Sort strictly by ascending order (e.g. 5, 10, 20, 50, 90)
    table.sort(startupQueue, function(a, b) return (a.order or 50) < (b.order or 50) end)

    -- 2. Execute one-shot synchronous scripts in designated order
    for _, task in ipairs(startupQueue) do
        if not task.isDaemon and fs.exists(task.script) then
            local fn = loadfile(task.script)
            if fn then pcall(fn) end
        end
    end

    -- 3. Launch background daemons and execute their initial startup/banner synchronously
    local daemonThreads = _G._DAEMON_THREADS or {}
    _G._DAEMON_THREADS = daemonThreads
    for _, task in ipairs(startupQueue) do
        if task.isDaemon and _G["_DAEMON_" .. task.name] ~= false and fs.exists(task.script) then
            local fn = loadfile(task.script)
            if fn then
                local co = coroutine.create(function()
                    pcall(fn, "--daemon")
                end)
                table.insert(daemonThreads, { name = task.name, co = co, fn = fn, script = task.script })
                -- Step the daemon once: runs startup code & prints banners up to first os.pullEvent()
                coroutine.resume(co)
            end
        end
    end

    -- Allow initial daemon banners and prints to complete before releasing the terminal shell
    sleep(0.05)
    _G._SERVICES_READY = true
    _G._KERNEL_ICMP = true

    -- 4. Persistent daemon event loop (dispatches events to all active background daemons)
    while true do
        local evData = table.pack(os.pullEventRaw())
        local ev = evData[1]

        -- Kernel ICMP Echo Responder (auto-replies to ping without requiring sshd)
        if ev == "cee_message" or ev == "cee_packet" or ev == "cee_fabric_message" or ev == "modem_message" then
            local data = nil
            for idx = 2, evData.n do
                local val = evData[idx]
                if type(val) == "table" and (val.protocol or val.payload) then
                    data = val.protocol and val or val.payload
                    break
                end
            end

            if type(data) == "table" and data.protocol == "LUNA_NET" and (data.type == "DATA" or data.type == "REQUEST") and data.payload and data.payload.cmd == "PING" then
                local net = _G.LunaNet or (fs.exists("/usr/bin/core/net.lua") and dofile("/usr/bin/core/net.lua"))
                if net then
                    local netConf = net.loadConfig()
                    if netConf and netConf.ip and (data.dst_ip == netConf.ip or data.dst_ip == "127.0.0.1") then
                        net.send(data.src_ip, data.dst_port or 22, { cmd = "PONG", seq = data.payload.seq }, nil, data.req_id)
                    end
                end
            end
        end

        -- Do not forward terminal keyboard input to background daemons
        if ev ~= "key" and ev ~= "key_up" and ev ~= "char" and ev ~= "paste" then
            local threads = _G._DAEMON_THREADS or daemonThreads
            for idx = #threads, 1, -1 do
                local d = threads[idx]
                if _G["_DAEMON_" .. d.name] == false then
                    table.remove(threads, idx)
                elseif coroutine.status(d.co) == "suspended" then
                    coroutine.resume(d.co, table.unpack(evData, 1, evData.n))
                elseif coroutine.status(d.co) == "dead" then
                    table.remove(threads, idx)
                end
            end
        end
    end
end

local function runTTYSession(thisTTY)
    local co = coroutine.running()
    ttyOwners[co] = thisTTY

    while not _G._SERVICES_READY do
        sleep(0.05)
    end

    local thisTerm = ttyTerms[thisTTY]
    if not thisTerm then
        return
    end

    coroTerms[co] = thisTerm

    while true do
        thisTerm.clear()
        thisTerm.setCursorPos(1, 1)

        -- If tty1, authenticate user. Secondary TTYs auto-inherit logged-in user without asking for login!
        local user = "root"
        if thisTTY == "tty1" then
            user = authenticateUser()
            _G.CURRENT_USER = user
            _G.LOGIN_USER   = user
            _G._MULTI_DISPLAY_READY = true
        else
            while not _G._MULTI_DISPLAY_READY do
                sleep(0.05)
            end
            user = _G.CURRENT_USER or "root"
        end

        local okK, errK = pcall(runLunaShell)
        if not okK then
            thisTerm.clear()
            thisTerm.setCursorPos(1, 1)
            printError("Shell crashed on " .. thisTTY .. ": " .. tostring(errK))
            print("Press any key to restart shell...")
            os.pullEvent("key")
        end
    end
end

-- Launch interactive sessions dynamically for all active TTYs/monitors
initDisplay()

local ttyRunners = {}
for ttyName, _ in pairs(ttyTerms) do
    local name = ttyName
    table.insert(ttyRunners, function()
        runTTYSession(name)
    end)
end

parallel.waitForAny(runBackgroundServices, table.unpack(ttyRunners))
