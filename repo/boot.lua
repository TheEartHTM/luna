-- RAID-0 Pooled Filesystem Driver with Virtual Root Mount
local CHUNK_SIZE = 900 * 1024
local drives = {}

local orig = _G.ORIG_FS or {
    open = fs.open,
    exists = fs.exists,
    isDir = fs.isDir,
    isReadOnly = fs.isReadOnly,
    list = fs.list,
    delete = fs.delete,
    makeDir = fs.makeDir,
    getSize = fs.getSize,
    getFreeSpace = fs.getFreeSpace,
    getCapacity = fs.getCapacity,
    attributes = fs.attributes,
    move = fs.move,
    copy = fs.copy,
    find = fs.find,
    complete = fs.complete,
    getDir = fs.getDir,
    getName = fs.getName
}
_G.ORIG_FS = orig

-- Discover all CEE memory modules (mem, mem2..mem32)
for _, name in ipairs(orig.list("/")) do
    if name:match("^mem%d*$") and orig.isDir(name) then
        table.insert(drives, name)
    end
end
table.sort(drives)

if #drives == 0 then
    if _G.logBootOk then
        _G.logBootOk("VFS: Running in standalone local storage mode")
    end
end

local function cleanPath(path)
    return fs.combine(path, "")
end

local function isHiddenRootItem(name)
    if name:match("^mem%d*$") then return true end
    if name == "startup.lua" or name == "boot.lua" or name == "install.lua" then return true end
    if name == "cee" or name == "rom" then return true end
    return false
end


local function getParentDir(path)
    if orig.getDir then return orig.getDir(path) end
    if fs.getDir then return fs.getDir(path) end
    local p = path:match("^(.-)/[^/]+$")
    return p or ""
end

local function mapSpecial(rel)
    if rel == "boot" then
        return orig.exists("mem") and "mem/boot" or "boot"
    elseif rel:sub(1, 5) == "boot/" then
        return orig.exists("mem") and fs.combine("mem/boot", rel:sub(6)) or rel
    elseif rel == "rom" or rel:sub(1, 4) == "rom/" then
        return rel
    end
    return nil
end

local function findChunks(rel)
    if rel == "" then return {} end
    local chunks = {}
    local idx = 1
    while true do
        local found = nil
        local partName = rel .. ".part" .. idx
        for _, d in ipairs(drives) do
            local full = fs.combine(d, partName)
            if orig.exists(full) then
                found = full
                break
            end
        end
        if found then
            table.insert(chunks, found)
            idx = idx + 1
        else
            break
        end
    end
    if #chunks == 0 then
        for _, d in ipairs(drives) do
            local full = fs.combine(d, rel)
            if orig.exists(full) and not orig.isDir(full) then
                return { full }
            end
        end
        if orig.exists(rel) and not orig.isDir(rel) and not isHiddenRootItem(rel) then
            return { rel }
        end
    end
    return chunks
end

local function findRealDir(rel)
    if rel == "" then return drives[1] or "" end
    for _, d in ipairs(drives) do
        local full = fs.combine(d, rel)
        if orig.exists(full) and orig.isDir(full) then
            return full
        end
    end
    if orig.exists(rel) and orig.isDir(rel) and not isHiddenRootItem(rel) then
        return rel
    end
    return nil
end

local function getBestDrive()
    if #drives == 0 then return "" end
    local best, maxSpace = drives[1], -1
    for _, d in ipairs(drives) do
        local s = orig.getFreeSpace(d)
        if s > maxSpace then
            maxSpace = s
            best = d
        end
    end
    return best
end

-- ============================================================
-- Virtual ProcFS & Dynamic DevFS Subsystem (Lag-Free On-Demand)
-- ============================================================
local virtualDirs = {
    ["proc"] = { "cpuinfo", "meminfo", "net", "uptime", "version" },
    ["proc/net"] = { "dev" }
}

local DEV_CACHE_TTL = 3.0
local devCache = {
    lastScan = 0,
    list = { "boot", "null", "raid0", "random", "urandom", "zero", "tty" },
    map = {}
}

local function getDevList()
    local now = os.clock()
    if (now - devCache.lastScan) < DEV_CACHE_TTL and devCache.lastScan > 0 then
        return devCache.list
    end
    devCache.lastScan = now

    local list = { "boot", "null", "raid0", "random", "urandom", "zero", "tty", "terminal", "tty1", "tty2", "tty3", "tty4", "speaker", "audio", "sound", "mon", "monitor" }
    local map = {
        ["tty"] = { type = "tty", name = "tty" },
        ["terminal"] = { type = "tty", name = "terminal" },
        ["tty1"] = { type = "tty", name = "tty1" },
        ["tty2"] = { type = "tty", name = "tty2" },
        ["tty3"] = { type = "tty", name = "tty3" },
        ["tty4"] = { type = "tty", name = "tty4" }
    }
    local typeCounts = {}
    local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }

    if peripheral and peripheral.getNames then
        local names = peripheral.getNames()
        for _, name in ipairs(names) do
            local pType = peripheral.getType(name) or "device"
            typeCounts[pType] = (typeCounts[pType] or 0) + 1
            local idx = typeCounts[pType] - 1
            local devName = pType .. idx
            if pType == "monitor" or pType == "ceemonitor" then
                devName = "mon" .. idx
                if idx == 0 then
                    map["mon"] = { name = name, type = pType, bus = SIDES[name] and "side" or "network" }
                    map["monitor"] = map["mon"]
                end
            elseif pType == "speaker" or pType == "cee_speaker" then
                devName = "speaker" .. idx
                if idx == 0 then
                    map["speaker"] = { name = name, type = pType, bus = SIDES[name] and "side" or "network" }
                    map["audio"] = map["speaker"]
                    map["sound"] = map["speaker"]
                    map["dsp"] = map["speaker"]
                end
            elseif pType == "keyboard" or pType == "cee_keyboard" then
                devName = "keyboard" .. idx
                if idx == 0 then
                    map["keyboard"] = { name = name, type = pType, bus = SIDES[name] and "side" or "network" }
                end
            elseif pType == "mouse" or pType == "cee_mouse" then
                devName = "mouse" .. idx
                if idx == 0 then
                    map["mouse"] = { name = name, type = pType, bus = SIDES[name] and "side" or "network" }
                end
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

            table.insert(list, devName)
            map[devName] = {
                name = name,
                type = pType,
                bus = SIDES[name] and "side" or "network"
            }
        end
    end

    if _G.cee then
        local maxPins = (_G.cee.getSignalCount and _G.cee.getSignalCount()) or 11
        for pin = 1, maxPins do
            local devName = "sig" .. pin
            table.insert(list, devName)
            map[devName] = {
                pin = pin,
                type = "signal_port",
                bus = "cee"
            }
        end
    end

    table.sort(list)
    devCache.list = list
    devCache.map = map
    return list
end

local virtualFiles = {
    ["proc/uptime"] = function()
        local up = os.clock()
        return string.format("%.2f %.2f\n", up, up)
    end,
    ["proc/meminfo"] = function()
        local total = (os.totalMemory and os.totalMemory()) or 131072
        local free = (os.freeMemory and os.freeMemory()) or 65536
        return string.format("MemTotal:       %8d kB\nMemFree:        %8d kB\nMemAvailable:   %8d kB\nBuffers:               0 kB\nCached:                0 kB\n",
            math.floor(total / 1024), math.floor(free / 1024), math.floor(free / 1024))
    end,
    ["proc/version"] = function()
        return "Luna Kernel 0.2 (Luna BIOS v0.2) (luna@distro) #1 PREEMPT\n"
    end,
    ["proc/cpuinfo"] = function()
        return "processor\t: 0\nvendor_id\t: ComputerCraft\nmodel name\t: CEE Lua Virtual Core\nstepping\t: 1\ncpu MHz\t\t: 50.000\ncache size\t: 128 KB\nflags\t\t: fpu vme de pse tsc msr pae mce cx8 apic\n"
    end,
    ["proc/net/dev"] = function()
        return "Inter-|   Receive                                                |  Transmit\n face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n    lo:       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0\n  cce0:   10240      85    0    0    0     0          0         0     5120      42    0    0    0     0       0          0\n"
    end,
    ["dev/raid0"] = function()
        return string.format("Luna RAID-0 Storage Device (%d modules, %d KB chunk size)\n", #drives, math.floor(CHUNK_SIZE / 1024))
    end,
    ["dev/boot"] = function()
        return "Luna Boot Device Partition (/mem/boot)\n"
    end,
    ["dev/tty"] = function()
        return "Luna Terminal Console\n"
    end
}

local function isVirtualSpecial(rel)
    return rel == "dev/null" or rel == "dev/zero" or rel == "dev/urandom" or rel == "dev/random" or rel == "dev/tty"
end

local function isVirtualFile(rel)
    if virtualFiles[rel] ~= nil or isVirtualSpecial(rel) then return true end
    if rel:sub(1, 4) == "dev/" then
        local sub = rel:sub(5)
        -- Always handle virtual Luna devices: tty, speaker, monitors, keyboards, mice, signals
        if sub:match("^speaker%d*$") or sub == "audio" or sub == "sound" or sub == "dsp"
           or sub:match("^tty%d*$") or sub == "terminal"
           or sub:match("^mon%d*$") or sub:match("^monitor%d*$") or sub == "monitor"
           or sub:match("^keyboard%d*$") or sub:match("^mouse%d*$")
           or sub:match("^sig%d+$")
           or (_G._DEVICE_MONITORS and _G._DEVICE_MONITORS[sub] ~= nil) then
            return true
        end
        getDevList()
        if devCache.map[sub] ~= nil then return true end
    end
    return false
end

local function isVirtualDir(rel)
    return virtualDirs[rel] ~= nil or rel == "dev"
end

local function isVirtual(rel)
    return isVirtualDir(rel) or isVirtualFile(rel)
end

local function openVirtual(rel, mode)
    if rel == "dev/null" then
        return {
            read = function(n) return nil end,
            readLine = function() return nil end,
            readAll = function() return nil end,
            write = function(d) end,
            writeLine = function(d) end,
            flush = function() end,
            close = function() end
        }
    elseif rel == "dev/zero" then
        if mode:find("w") or mode:find("a") then return nil end
        return {
            read = function(n) return string.rep("\0", n or 1) end,
            readLine = function() return string.rep("\0", 64) end,
            readAll = function() return string.rep("\0", 512) end,
            close = function() end
        }
    elseif rel == "dev/urandom" or rel == "dev/random" then
        if mode:find("w") or mode:find("a") then return nil end
        return {
            read = function(n)
                local count = n or 1
                local t = {}
                for _ = 1, count do table.insert(t, string.char(math.random(0, 255))) end
                return table.concat(t)
            end,
            readLine = function()
                local t = {}
                for _ = 1, 32 do table.insert(t, string.char(math.random(33, 126))) end
                return table.concat(t)
            end,
            readAll = function()
                local t = {}
                for _ = 1, 256 do table.insert(t, string.char(math.random(0, 255))) end
                return table.concat(t)
            end,
            close = function() end
        }
    elseif rel == "dev/tty" then
        return {
            write = function(d) term.write(tostring(d)) end,
            writeLine = function(d) print(tostring(d)) end,
            flush = function() end,
            close = function() end
        }
    elseif rel:sub(1, 4) == "dev/" then
        local sub = rel:sub(5)
        getDevList()

        -- 1. TTY & Monitor terminal redirection: /dev/tty1, /dev/tty2, /dev/tty, /dev/terminal, /dev/mon0, /dev/mon, /dev/monitor
        if sub:match("^tty%d+$") or sub == "tty" or sub == "terminal" or sub:match("^mon%d+$") or sub == "mon" or sub:match("^monitor%d*$") or (_G._DEVICE_MONITORS and _G._DEVICE_MONITORS[sub] ~= nil) then
            if mode:find("w") or mode:find("a") then
                local targetTerm = nil
                if _G._DEVICE_MONITORS and _G._DEVICE_MONITORS[sub] then
                    targetTerm = _G._DEVICE_MONITORS[sub]
                elseif sub:match("^tty%d+$") and _G._TTY_TERMS and _G._TTY_TERMS[sub] then
                    targetTerm = _G._TTY_TERMS[sub]
                elseif (sub == "tty" or sub == "terminal") then
                    targetTerm = (_G._DEVICE_MONITORS and _G._DEVICE_MONITORS["terminal"]) or (term and term.native and term.native()) or (term and term.current and term.current())
                elseif devCache.map[sub] and (devCache.map[sub].type == "monitor" or devCache.map[sub].type == "ceemonitor") then
                    targetTerm = peripheral.wrap(devCache.map[sub].name)
                elseif devCache.map["mon0"] then
                    targetTerm = peripheral.wrap(devCache.map["mon0"].name)
                elseif devCache.map["mon"] then
                    targetTerm = peripheral.wrap(devCache.map["mon"].name)
                elseif peripheral and peripheral.find then
                    targetTerm = peripheral.find("ceemonitor") or peripheral.find("monitor")
                end

                local lineBuf = ""
                local function flushBuf()
                    if #lineBuf == 0 or not targetTerm then return end
                    pcall(targetTerm.write, lineBuf)
                    lineBuf = ""
                end

                local function writeChar(ch)
                    if not targetTerm then return end
                    if ch == "\n" then
                        flushBuf()
                        local x, y = 1, 1
                        if targetTerm.getCursorPos then x, y = targetTerm.getCursorPos() end
                        local w, h = 51, 19
                        if targetTerm.getSize then w, h = targetTerm.getSize() end
                        if y >= h then
                            if targetTerm.scroll then pcall(targetTerm.scroll, 1) end
                            if targetTerm.setCursorPos then pcall(targetTerm.setCursorPos, 1, h) end
                        else
                            if targetTerm.setCursorPos then pcall(targetTerm.setCursorPos, 1, y + 1) end
                        end
                    elseif ch == "\r" then
                        flushBuf()
                        if targetTerm.getCursorPos and targetTerm.setCursorPos then
                            local _, y = targetTerm.getCursorPos()
                            pcall(targetTerm.setCursorPos, 1, y)
                        end
                    elseif ch == "\t" then
                        lineBuf = lineBuf .. "    "
                    else
                        lineBuf = lineBuf .. ch
                        if #lineBuf >= 128 then flushBuf() end
                    end
                end

                local function writeText(text)
                    text = tostring(text)
                    for i = 1, #text do
                        writeChar(text:sub(i, i))
                    end
                end

                return {
                    write = function(d) writeText(d) end,
                    writeLine = function(d) writeText(tostring(d) .. "\n") end,
                    flush = function() flushBuf() end,
                    close = function() flushBuf() end
                }
            end
        end

        -- 2. Speaker redirection: /dev/speaker, /dev/speaker0, /dev/dsp, /dev/audio, /dev/sound
        local isSpeaker = (sub:find("speaker") or sub == "dsp" or sub == "audio" or sub == "sound")
        if isSpeaker and (mode:find("w") or mode:find("a")) then
            local p = nil
            if devCache.map[sub] and devCache.map[sub].name then
                p = peripheral.wrap(devCache.map[sub].name)
            elseif devCache.map["speaker0"] and devCache.map["speaker0"].name then
                p = peripheral.wrap(devCache.map["speaker0"].name)
            elseif devCache.map["speaker"] and devCache.map["speaker"].name then
                p = peripheral.wrap(devCache.map["speaker"].name)
            elseif peripheral and peripheral.find then
                p = peripheral.find("speaker") or peripheral.find("cee_speaker")
            end

            local audioBuf = {}
            local function playBuffer()
                if not p then return end
                local data = table.concat(audioBuf)
                audioBuf = {}
                if #data == 0 then return end

                -- Check if data is plain text commands (e.g. echo "bell" > /dev/speaker, "pling 18", etc.)
                -- Text command check: ASCII printable characters, newlines, spaces
                local isText = not data:find("[%z\1-\8\11\12\14-\31\127-\255]")
                if isText then
                    for line in (data .. "\n"):gmatch("([^\r\n]+)") do
                        local s = line:match("^%s*(.-)%s*$")
                        if #s > 0 then
                            local lower = s:lower()
                            local inst = "pling"
                            local pitch = 12

                            if lower:find("bell") then inst = "bell"; pitch = 16
                            elseif lower:find("pling") then inst = "pling"; pitch = 18
                            elseif lower:find("chime") then inst = "chime"; pitch = 20
                            elseif lower:find("bass") or lower:find("basedrum") then inst = "bass"; pitch = 6
                            elseif lower:find("flute") then inst = "flute"; pitch = 14
                            elseif lower:find("guitar") then inst = "guitar"; pitch = 10
                            elseif lower:find("harp") then inst = "harp"; pitch = 12
                            elseif lower:find("snare") then inst = "snare"; pitch = 10
                            elseif lower:find("hat") then inst = "hat"; pitch = 14
                            elseif lower:find("bit") then inst = "bit"; pitch = 16
                            elseif lower:find("iron_xylophone") or lower:find("xylophone") then inst = "iron_xylophone"; pitch = 18
                            end

                            local numPitch = tonumber(s:match("%d+"))
                            if numPitch and numPitch >= 0 and numPitch <= 24 then
                                pitch = numPitch
                            end

                            if p.playNote then
                                pcall(p.playNote, inst, 1.0, pitch)
                            elseif p.playSound then
                                local pitchFactor = math.pow(2, (pitch - 12) / 12)
                                pcall(p.playSound, "minecraft:block.note_block." .. inst, 1.0, pitchFactor)
                            end
                            sleep(0.05)
                        end
                    end
                    return
                end

                -- Binary Audio Playback (DFPWM audio stream)
                local okD, dfpwm = pcall(require, "cc.audio.dfpwm")
                if okD and dfpwm and dfpwm.make_decoder and p.playAudio then
                    local decoder = dfpwm.make_decoder()
                    local pos = 1
                    local chunkBytes = 16 * 128 -- 2048 bytes of DFPWM -> 16384 samples (CC limit)
                    while pos <= #data do
                        local chunk = data:sub(pos, pos + chunkBytes - 1)
                        pos = pos + chunkBytes
                        local okDec, pcm = pcall(decoder, chunk)
                        if okDec and pcm and #pcm > 0 then
                            while not p.playAudio(pcm) do
                                os.pullEvent("speaker_audio_empty")
                            end
                        end
                    end
                    return
                end

                -- Fallback to custom audio methods if present
                if p.speakAudio and pcall(p.speakAudio, data) then return end
                if p.speakMp3 and pcall(p.speakMp3, data) then return end
                if p.speakOgg and pcall(p.speakOgg, data) then return end
                if p.speakWav and pcall(p.speakWav, data) then return end
            end

            return {
                write = function(d) table.insert(audioBuf, tostring(d)) end,
                writeLine = function(d) table.insert(audioBuf, tostring(d) .. "\n") end,
                flush = function() playBuffer() end,
                close = function() playBuffer() end
            }
        end

        local devInfo = devCache.map[sub]
        if devInfo then
            if mode:find("w") or mode:find("a") then
                if devInfo.type == "printer" then
                    local p = peripheral.wrap(devInfo.name)
                    local buf = {}
                    return {
                        write = function(d) table.insert(buf, tostring(d)) end,
                        writeLine = function(d) table.insert(buf, tostring(d) .. "\n") end,
                        flush = function() end,
                        close = function()
                            if p and p.newPage then
                                pcall(function()
                                    if p.newPage() then
                                        local full = table.concat(buf)
                                        local y = 1
                                        for l in full:gmatch("[^\r\n]+") do
                                            p.setCursorPos(1, y)
                                            p.write(l)
                                            y = y + 1
                                        end
                                        p.endPage()
                                    end
                                end)
                            end
                        end
                    }
                elseif devInfo.type == "signal_port" then
                    return {
                        write = function(d)
                            if _G.cee and _G.cee.send then
                                pcall(_G.cee.send, devInfo.pin, tostring(d))
                            end
                        end,
                        writeLine = function(d)
                            if _G.cee and _G.cee.send then
                                pcall(_G.cee.send, devInfo.pin, tostring(d))
                            end
                        end,
                        flush = function() end,
                        close = function() end
                    }
                else
                    return {
                        write = function(d) end,
                        writeLine = function(d) end,
                        flush = function() end,
                        close = function() end
                    }
                end
            else
                local desc = string.format("device: %s\ntype: %s\nbus: %s\ninterface: %s\n",
                    sub, devInfo.type, devInfo.bus or "unknown", devInfo.name or ("pin_" .. tostring(devInfo.pin or 0)))
                local pos = 1
                return {
                    read = function(n)
                        if pos > #desc then return nil end
                        if not n then local c = desc:sub(pos, pos); pos = pos + 1; return c end
                        local s = desc:sub(pos, pos + n - 1)
                        pos = pos + #s
                        return #s > 0 and s or nil
                    end,
                    readLine = function()
                        if pos > #desc then return nil end
                        local nl = desc:find("\n", pos, true)
                        local line = nl and desc:sub(pos, nl - 1) or desc:sub(pos)
                        pos = (nl or #desc) + 1
                        return line
                    end,
                    readAll = function()
                        if pos > #desc then return nil end
                        local rem = desc:sub(pos)
                        pos = #desc + 1
                        return rem
                    end,
                    close = function() end
                }
            end
        end
    elseif virtualFiles[rel] then
        if mode:find("w") or mode:find("a") then return nil end
        local content = virtualFiles[rel]()
        local pos = 1
        return {
            read = function(count)
                if pos > #content then return nil end
                if not count then
                    local ch = content:sub(pos, pos)
                    pos = pos + 1
                    return ch
                end
                local slice = content:sub(pos, pos + count - 1)
                pos = pos + #slice
                return #slice > 0 and slice or nil
            end,
            readLine = function(withTrailing)
                if pos > #content then return nil end
                local nl = content:find("\n", pos, true)
                local line
                if nl then
                    line = content:sub(pos, withTrailing and nl or nl - 1)
                    pos = nl + 1
                else
                    line = content:sub(pos)
                    pos = #content + 1
                end
                return line
            end,
            readAll = function()
                if pos > #content then return nil end
                local rem = content:sub(pos)
                pos = #content + 1
                return rem
            end,
            close = function() pos = #content + 1 end
        }
    end
    return nil
end

-- ============================================================
-- Kernel VFS Security Subsystem
-- ============================================================
local inVfsCheck = false
local function checkVfsAccess(rel, req)
    local user = _G.CURRENT_USER or "root"
    if user == "root" then return true end
    if inVfsCheck then return true end

    -- System internal databases required for access checks must never trigger re-entrant VFS checks
    if rel == "etc/permissions.db" or rel == "etc/passwd" or rel == "etc/group" or rel == "etc/sudoers" then
        return true
    end

    if not _G.systemd or not _G.systemd.checkAccess then return true end
    inVfsCheck = true
    local ok, res = pcall(_G.systemd.checkAccess, rel, user, req)
    inVfsCheck = false
    if ok then return res else return true end
end

-- 1. fs.exists
fs.exists = function(path)
    local rel = cleanPath(path)
    local spec = mapSpecial(rel)
    if spec then return orig.exists(spec) end
    if isVirtual(rel) then return true end
    return findRealDir(rel) ~= nil or #findChunks(rel) > 0
end

-- 2. fs.isDir
fs.isDir = function(path)
    local rel = cleanPath(path)
    local spec = mapSpecial(rel)
    if spec then return orig.isDir(spec) end
    if isVirtualDir(rel) then return true end
    if isVirtualFile(rel) then return false end
    return findRealDir(rel) ~= nil
end

-- 3. fs.isReadOnly
fs.isReadOnly = function(path)
    local rel = cleanPath(path)
    if rel == "rom" or rel:sub(1, 4) == "rom/" then
        return true
    end
    if rel == "proc" or rel:sub(1, 5) == "proc/" then
        return true
    end
    if rel == "dev" or rel == "dev/zero" or rel == "dev/urandom" or rel == "dev/random" or rel == "dev/raid0" or rel == "dev/boot" then
        return true
    end
    if rel == "dev/null" then
        return false
    end
    return false
end

-- 4. fs.makeDir
fs.makeDir = function(path)
    local rel = cleanPath(path)
    if isVirtual(rel) or rel == "" or rel == "rom" or rel:sub(1, 4) == "rom/" or findRealDir(rel) then return end
    local parent = getParentDir(rel)
    if not checkVfsAccess(parent, "w") then return end
    local spec = mapSpecial(rel)
    if spec then return orig.makeDir(spec) end
    local best = getBestDrive()
    orig.makeDir(fs.combine(best, rel))
end

-- 5. fs.delete
fs.delete = function(path)
    local rel = cleanPath(path)
    if isVirtual(rel) or rel == "" or rel == "rom" or rel:sub(1, 4) == "rom/" then return end
    if not checkVfsAccess(rel, "w") then return end
    local spec = mapSpecial(rel)
    if spec then return orig.delete(spec) end
    if orig.exists(rel) and not isHiddenRootItem(rel) then
        orig.delete(rel)
    end
    for _, d in ipairs(drives) do
        local full = fs.combine(d, rel)
        if orig.exists(full) then
            orig.delete(full)
        end
        local idx = 1
        while true do
            local part = fs.combine(d, rel .. ".part" .. idx)
            if orig.exists(part) then
                orig.delete(part)
                idx = idx + 1
            else
                break
            end
        end
    end
end

-- 6. fs.getSize
fs.getSize = function(path)
    local rel = cleanPath(path)
    local spec = mapSpecial(rel)
    if spec then return orig.getSize(spec) end
    if virtualFiles[rel] then
        local str = virtualFiles[rel]()
        return #str
    end
    if isVirtualSpecial(rel) then return 0 end
    local chunks = findChunks(rel)
    local total = 0
    for _, c in ipairs(chunks) do
        total = total + orig.getSize(c)
    end
    return total
end

-- 7. fs.getFreeSpace
fs.getFreeSpace = function(path)
    local rel = cleanPath(path)
    local spec = mapSpecial(rel)
    if spec then
        if spec == "rom" or spec:sub(1, 4) == "rom/" then return 0 end
        return orig.exists("mem") and orig.getFreeSpace("mem") or orig.getFreeSpace("")
    end
    if #drives == 0 then
        return orig.getFreeSpace(rel)
    end
    local total = 0
    for _, d in ipairs(drives) do
        total = total + orig.getFreeSpace(d)
    end
    return total
end

-- 8. fs.getCapacity
if orig.getCapacity then
    fs.getCapacity = function(path)
        local rel = cleanPath(path)
        local spec = mapSpecial(rel)
        if spec then
            if spec == "rom" or spec:sub(1, 4) == "rom/" then return orig.getCapacity("rom") end
            return orig.exists("mem") and orig.getCapacity("mem") or orig.getCapacity("")
        end
        if #drives == 0 then
            return orig.getCapacity(rel)
        end
        local total = 0
        for _, d in ipairs(drives) do
            local cap = orig.getCapacity(d)
            if cap then total = total + cap end
        end
        return total > 0 and total or nil
    end
end

-- 9. fs.attributes
fs.attributes = function(path)
    local rel = cleanPath(path)
    local spec = mapSpecial(rel)
    if spec then return orig.attributes(spec) end
    if isVirtualDir(rel) then
        return {
            isDir = true,
            isReadOnly = true,
            size = 0,
            created = 0,
            modified = 0
        }
    end
    if isVirtualFile(rel) then
        return {
            isDir = false,
            isReadOnly = rel ~= "dev/null",
            size = fs.getSize(path),
            created = 0,
            modified = 0
        }
    end
    local dir = findRealDir(rel)
    if dir then
        local attr = orig.attributes(dir)
        attr.isReadOnly = false
        return attr
    end
    local chunks = findChunks(rel)
    if #chunks > 0 then
        local attr = orig.attributes(chunks[1])
        attr.size = fs.getSize(path)
        attr.isReadOnly = false
        return attr
    end
    return nil
end

-- 10. fs.list
fs.list = function(path)
    local rel = cleanPath(path)
    if rel == "dev" then
        return getDevList()
    end
    if isVirtualDir(rel) then
        local items = {}
        for _, item in ipairs(virtualDirs[rel]) do table.insert(items, item) end
        table.sort(items)
        return items
    end
    if isVirtualFile(rel) then error("Not a directory", 2) end

    local spec = mapSpecial(rel)
    if spec then return orig.list(spec) end

    local seen, result = {}, {}
    if rel == "" then
        if orig.exists("mem/boot") then
            seen["boot"] = true
            table.insert(result, "boot")
        end
        seen["proc"] = true
        table.insert(result, "proc")
        seen["dev"] = true
        table.insert(result, "dev")
    end

    if orig.exists(rel) and orig.isDir(rel) then
        for _, item in ipairs(orig.list(rel)) do
            local cleanName = item:gsub("%.part%d+$", "")
            if rel == "" and isHiddenRootItem(cleanName) then
                -- Filter out raw mounts and low-level bootloaders
            elseif not seen[cleanName] then
                seen[cleanName] = true
                table.insert(result, cleanName)
            end
        end
    end

    for _, d in ipairs(drives) do
        local target = fs.combine(d, rel)
        if orig.exists(target) and orig.isDir(target) then
            for _, item in ipairs(orig.list(target)) do
                local cleanName = item:gsub("%.part%d+$", "")
                if rel == "" and isHiddenRootItem(cleanName) then
                    -- Filter out raw mounts and low-level bootloaders
                elseif not seen[cleanName] then
                    seen[cleanName] = true
                    table.insert(result, cleanName)
                end
            end
        end
    end
    table.sort(result)
    return result
end

-- 11. fs.open
fs.open = function(path, mode)
    local rel = cleanPath(path)

    -- Intercept virtual files
    if isVirtualFile(rel) then
        return openVirtual(rel, mode)
    end
    if isVirtualDir(rel) then return nil end

    -- VFS Security Permission Check
    local isWrite = mode == "w" or mode == "wb" or mode == "a" or mode == "ab"
    local isRead = mode == "r" or mode == "rb"
    if isRead then
        if not checkVfsAccess(rel, "r") then
            return nil, "Permission denied"
        end
    elseif isWrite then
        if fs.exists(path) then
            if not checkVfsAccess(rel, "w") then
                return nil, "Permission denied"
            end
        else
            local parent = getParentDir(rel)
            if not checkVfsAccess(parent, "w") then
                return nil, "Permission denied"
            end
        end
    end

    local spec = mapSpecial(rel)
    if spec then return orig.open(spec, mode) end

    if rel == "" or findRealDir(rel) then return nil end
    local isBinary = mode:find("b") ~= nil

    -- Read mode
    if mode == "r" or mode == "rb" then
        local chunks = findChunks(rel)
        if #chunks == 0 then return nil end

        local curIdx = 1
        local curHandle = orig.open(chunks[1], mode)
        if not curHandle then return nil end

        local handle = {}
        function handle.read(count)
            if not curHandle then return nil end
            if isBinary and count then
                local res = ""
                while #res < count and curHandle do
                    local data = curHandle.read(count - #res)
                    if data then
                        res = res .. data
                    else
                        curHandle.close()
                        curIdx = curIdx + 1
                        curHandle = chunks[curIdx] and orig.open(chunks[curIdx], mode) or nil
                    end
                end
                return #res > 0 and res or nil
            else
                local data = curHandle.read(count)
                while data == nil and curIdx < #chunks do
                    curHandle.close()
                    curIdx = curIdx + 1
                    curHandle = orig.open(chunks[curIdx], mode)
                    if curHandle then data = curHandle.read(count) end
                end
                return data
            end
        end

        function handle.readLine(withTrailing)
            if isBinary or not curHandle then return nil end
            local line = curHandle.readLine(withTrailing)
            while line == nil and curIdx < #chunks do
                curHandle.close()
                curIdx = curIdx + 1
                curHandle = orig.open(chunks[curIdx], mode)
                if curHandle then line = curHandle.readLine(withTrailing) end
            end
            return line
        end

        function handle.readAll()
            local buf = {}
            while curHandle do
                local all = curHandle.readAll()
                if all then table.insert(buf, all) end
                curHandle.close()
                curIdx = curIdx + 1
                curHandle = chunks[curIdx] and orig.open(chunks[curIdx], mode) or nil
            end
            return table.concat(buf)
        end

        function handle.close()
            if curHandle then curHandle.close() end
            curHandle = nil
        end

        return handle
    end

    -- Write / Append mode
    if mode == "w" or mode == "wb" or mode == "a" or mode == "ab" then
        local existingData = ""
        if (mode == "a" or mode == "ab") and fs.exists(path) then
            local r = fs.open(path, isBinary and "rb" or "r")
            if r then
                existingData = r.readAll() or ""
                r.close()
            end
        end

        fs.delete(path)
        local writeMode = isBinary and "wb" or "w"
        local chunkIdx = 1
        local writtenInChunk = 0
        local parentRel = fs.getDir(rel)

        local function openNextChunk(idx)
            local drive = getBestDrive()
            if parentRel ~= "" then
                orig.makeDir(fs.combine(drive, parentRel))
            end
            return orig.open(fs.combine(drive, rel .. ".part" .. idx), writeMode)
        end

        local curHandle = openNextChunk(1)
        if not curHandle then return nil end

        local function rotateChunk()
            curHandle.close()
            chunkIdx = chunkIdx + 1
            writtenInChunk = 0
            curHandle = openNextChunk(chunkIdx)
        end

        local handle = {}
        function handle.write(data)
            if not curHandle or data == nil then return end
            local str = type(data) == "number" and string.char(data) or tostring(data)
            local pos = 1
            while pos <= #str do
                local spaceLeft = CHUNK_SIZE - writtenInChunk
                if spaceLeft <= 0 then
                    rotateChunk()
                    spaceLeft = CHUNK_SIZE
                end
                local slice = str:sub(pos, pos + spaceLeft - 1)
                curHandle.write(slice)
                writtenInChunk = writtenInChunk + #slice
                pos = pos + #slice
            end
        end

        function handle.writeLine(data)
            handle.write(tostring(data) .. "\n")
        end

        function handle.flush()
            if curHandle then curHandle.flush() end
        end

        function handle.close()
            if curHandle then curHandle.close() end
            curHandle = nil
        end

        if #existingData > 0 then
            handle.write(existingData)
        end
        return handle
    end

    return nil
end

-- 12. fs.copy
fs.copy = function(from, to)
    if not fs.exists(from) then error("No such file: " .. tostring(from)) end
    if fs.isDir(from) then
        fs.makeDir(to)
        for _, item in ipairs(fs.list(from)) do
            fs.copy(fs.combine(from, item), fs.combine(to, item))
        end
    else
        local r = fs.open(from, "rb")
        local w = fs.open(to, "wb")
        if r and w then
            w.write(r.readAll())
        end
        if r then r.close() end
        if w then w.close() end
    end
end

-- 13. fs.move
fs.move = function(from, to)
    fs.copy(from, to)
    fs.delete(from)
end

-- 14. fs.find
fs.find = function(wildcard)
    local clean = cleanPath(wildcard)
    local results = {}
    local seen = {}
    local pattern = "^"
    for i = 1, #clean do
        local c = clean:sub(i, i)
        if c == "*" then
            pattern = pattern .. ".*"
        elseif c == "?" then
            pattern = pattern .. "."
        elseif c:match("[%w_/%.%-]") then
            pattern = pattern .. c
        else
            pattern = pattern .. "%" .. c
        end
    end
    pattern = pattern .. "$"

    local function scan(dir)
        if not fs.exists(dir) or not fs.isDir(dir) then return end
        for _, item in ipairs(fs.list(dir)) do
            local full = (dir == "") and item or fs.combine(dir, item)
            if full:match(pattern) and not seen[full] then
                seen[full] = true
                table.insert(results, full)
            end
            if fs.isDir(full) then
                scan(full)
            end
        end
    end

    scan("")
    table.sort(results)
    return results
end

-- 15. fs.complete
fs.complete = function(path, location, includeFiles, includeDirs)
    if type(includeFiles) == "table" then
        local opt = includeFiles
        includeFiles = opt.includeFiles ~= false
        includeDirs = opt.includeDirs ~= false
    else
        includeFiles = includeFiles ~= false
        includeDirs = includeDirs ~= false
    end

    location = location or ""
    local fullPath = fs.combine(location, path)
    local dirPart = fs.getDir(fullPath)
    local namePart = fs.getName(fullPath)
    if fullPath:sub(-1) == "/" or fullPath == "" then
        dirPart = fullPath
        namePart = ""
    end

    local results = {}
    local seen = {}
    if fs.isDir(dirPart) then
        for _, name in ipairs(fs.list(dirPart)) do
            if name:sub(1, #namePart) == namePart and not seen[name] then
                seen[name] = true
                local childPath = fs.combine(dirPart, name)
                local isChildDir = fs.isDir(childPath)
                if (isChildDir and includeDirs) or (not isChildDir and includeFiles) then
                    local rem = name:sub(#namePart + 1)
                    if isChildDir then rem = rem .. "/" end
                    table.insert(results, rem)
                end
            end
        end
    end
    table.sort(results)
    return results
end

if _G.logBootOk then
    _G.logBootOk(string.format("Mounted /dev/raid0 (%d memory modules) -> /", #drives))
    _G.logBootOk("Mounted /dev/boot (/mem/boot) -> /boot")
    _G.logBootOk("Mounted procfs -> /proc")
    _G.logBootOk("Mounted devfs -> /dev")
    _G.logBootOk("VFS: Enforced DAC (rwx) security policies active")
else
    print("RAID pool mounted: " .. #drives .. " modules -> /")
end
_G.RAID_DRIVES = drives
_G.ORIG_FS = orig

-- System directories initialization
local sysDirs = { "etc", "etc/conf", "usr", "usr/bin", "usr/bin/core", "usr/bin/extra", "usr/bin/fastfetch", "home" }
for _, sd in ipairs(sysDirs) do
    if not fs.exists(sd) then
        fs.makeDir(sd)
    end
end
