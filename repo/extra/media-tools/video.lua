-- video - High-performance Video Player for CC/CEE Monitors and Video Walls
-- Supports 2x3 square-pixel teletext rendering (characters 128-159),
-- A/V sync with CEE OGG speaker audio, and delta compression drop-frame handling.

local term = term
local colors = colors
local keys = keys
local isColor = term.isColor and term.isColor()

-- Load audio library
local sound = nil
if fs and fs.exists and fs.exists("/usr/lib/sound.lua") then
    local fn, err = loadfile("/usr/lib/sound.lua")
    if fn then sound = fn() end
end
if not sound then
    local ok, mod = pcall(require, "sound")
    if ok then sound = mod end
end

-- Parse CLI arguments
local args = { ... }
if #args == 0 or args[1] == "-h" or args[1] == "--help" then
    print("usage: video [options] <video_file> [audio_file]")
    print("       lunavid [options] <video_file> [audio_file]")
    print("options:")
    print("  -m, --monitor <name>     target monitor (/dev/mon0, side, or peripheral name)")
    print("  -w, --wall <cols>x<rows> multi-monitor grid layout (e.g. 2x2, 3x2)")
    print("      --monitors <m1,m2..> comma-separated list of monitors for video wall")
    print("  -a, --audio <file.ogg>   explicit companion audio file")
    print("  -v, --volume <0.0-1.0>   audio playback volume (default 1.0)")
    print("  -s, --scale <scale>      monitor text scale (default 0.5)")
    print("  -f, --fps <fps>          override playback frame rate")
    print("      --no-audio           disable companion audio playback")
    print("      --loop               loop video playback")
    print("  -h, --help               show this help message")
    return
end

local targetVideo = nil
local targetAudio = nil
local monitorArg = nil
local wallArg = nil
local monitorsArg = nil
local volume = 1.0
local textScale = 0.5
local fpsOverride = nil
local noAudio = false
local loopPlayback = false

local idx = 1
while idx <= #args do
    local a = args[idx]
    if a == "-m" or a == "--monitor" then
        idx = idx + 1
        monitorArg = args[idx]
    elseif a == "-w" or a == "--wall" then
        idx = idx + 1
        wallArg = args[idx]
    elseif a == "--monitors" then
        idx = idx + 1
        monitorsArg = args[idx]
    elseif a == "-a" or a == "--audio" then
        idx = idx + 1
        targetAudio = args[idx]
    elseif a == "-v" or a == "--volume" then
        idx = idx + 1
        volume = tonumber(args[idx]) or 1.0
    elseif a == "-s" or a == "--scale" then
        idx = idx + 1
        textScale = tonumber(args[idx]) or 0.5
    elseif a == "-f" or a == "--fps" then
        idx = idx + 1
        fpsOverride = tonumber(args[idx])
    elseif a == "--no-audio" then
        noAudio = true
    elseif a == "--loop" then
        loopPlayback = true
    elseif not targetVideo and not a:find("^%-") then
        targetVideo = a
    elseif not targetAudio and not a:find("^%-") then
        targetAudio = a
    end
    idx = idx + 1
end

if not targetVideo then
    printError("video: no video file specified")
    return
end

-- Resolve video file path
local videoPath = targetVideo
if shell and shell.resolve and fs and fs.exists then
    local res = shell.resolve(targetVideo)
    if fs.exists(res) then
        videoPath = res
    end
end

-- Check video file exists
local exists = false
if fs and fs.exists then
    exists = fs.exists(videoPath)
else
    local test = io.open(videoPath, "rb")
    if test then
        exists = true
        test:close()
    end
end

if not exists then
    printError("video: file not found: " .. tostring(targetVideo))
    return
end

-- Auto-detect companion audio file if not explicitly given and not disabled
if not targetAudio and not noAudio then
    local candidate = videoPath:gsub("%.lvd$", "") .. ".ogg"
    local hasOgg = false
    if fs and fs.exists then
        hasOgg = fs.exists(candidate)
    else
        local test = io.open(candidate, "rb")
        if test then
            hasOgg = true
            test:close()
        end
    end
    if hasOgg then
        targetAudio = candidate
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

-- Helper: Resolve monitor target across direct sides, network peripherals, /dev/monX, and CEE pins
local function resolveMonitorTarget(name)
    if not name or name == "" then return nil end
    local clean = name:gsub("^/dev/", "")

    if clean == "term" or clean == "terminal" or clean == "native" or clean == "builtin" or clean == "tty1" then
        return (term.native and term.native()) or term.current()
    end

    if peripheral and peripheral.wrap then
        local obj = peripheral.wrap(name) or peripheral.wrap(clean)
        if obj and (obj.getSize or obj.blit or obj.write) then
            return obj
        end
    end

    local mIdx = clean:match("^mon(%d+)$") or clean:match("^monitor(%d+)$")
    if mIdx then
        local targetIdx = tonumber(mIdx)
        local curr = 0
        for _, pName in ipairs(getSortedPeripheralNames()) do
            local pType = peripheral.getType(pName)
            if pType == "monitor" or pType == "ceemonitor" then
                if curr == targetIdx then
                    return peripheral.wrap(pName)
                end
                curr = curr + 1
            end
        end
    end

    local pNum = clean:match("^sig(%d+)$") or clean:match("^pin_?(%d+)$") or clean:match("^cee_signal_?(%d+)$")
    if pNum and _G.cee and _G.cee.getMonitors then
        local ok, m = pcall(_G.cee.getMonitors, tonumber(pNum))
        if ok and m and (m.getSize or m.blit or m.write) then
            return m
        end
    end

    if _G._MONITOR_LIST then
        for _, item in ipairs(_G._MONITOR_LIST) do
            if item.name == name or item.name == clean or item.dev == name then
                if item.obj then return item.obj end
                if item.name and peripheral then return peripheral.wrap(item.name) end
            end
        end
    end

    return nil
end

-- Setup Display Adapter (Single Monitor, Video Wall, or Terminal)
local function setupDisplayAdapter(monArg, wArg, monsArg, scale)
    if wArg then
        local gCols, gRows = wArg:match("^(%d+)x(%d+)$")
        if not gCols or not gRows then
            return nil, "Invalid wall format: expected <cols>x<rows> (e.g. 2x2, 3x2)"
        end
        gCols = tonumber(gCols)
        gRows = tonumber(gRows)
        local needed = gCols * gRows
        local monList = {}
        if monsArg then
            for m in monsArg:gmatch("[^,]+") do
                table.insert(monList, m:match("^%s*(.-)%s*$"))
            end
        else
            for _, name in ipairs(getSortedPeripheralNames()) do
                local pType = peripheral.getType(name)
                if pType == "monitor" or pType == "ceemonitor" then
                    table.insert(monList, name)
                end
            end
            if _G.cee and _G.cee.getMonitors then
                for pin = 1, 11 do
                    local ok, m = pcall(_G.cee.getMonitors, pin)
                    if ok and m and m.getSize then
                        table.insert(monList, "sig" .. pin)
                    end
                end
            end
        end
        if #monList < needed then
            return nil, string.format("Video wall %dx%d requires %d monitors, but only %d found", gCols, gRows, needed, #monList)
        end

        local grid = {}
        local tileW, tileH = nil, nil
        local mIdx = 1
        for r = 1, gRows do
            for c = 1, gCols do
                grid[c] = grid[c] or {}
                local monName = monList[mIdx]
                mIdx = mIdx + 1
                local monObj = resolveMonitorTarget(monName)
                if not monObj then
                    return nil, "Failed to wrap monitor peripheral: " .. tostring(monName)
                end
                if monObj.setTextScale then monObj.setTextScale(scale) end
                local mw, mh = monObj.getSize()
                if not tileW then
                    tileW, tileH = mw, mh
                end
                monObj.setBackgroundColor(colors.black or 32768)
                monObj.clear()
                grid[c][r] = monObj
            end
        end

        local totalW = gCols * tileW
        local totalH = gRows * tileH

        return {
            isWall = true,
            cols = gCols,
            rows = gRows,
            tileW = tileW,
            tileH = tileH,
            width = totalW,
            height = totalH,
            blitSpan = function(self, y, x, chars, fgs, bgs)
                local r = math.floor((y - 1) / self.tileH) + 1
                if r < 1 or r > self.rows then return end
                if not chars or not fgs or not bgs then return end
                local minLen = math.min(#chars, #fgs, #bgs)
                if minLen == 0 then return end
                if #chars ~= minLen then chars = chars:sub(1, minLen) end
                if #fgs ~= minLen then fgs = fgs:sub(1, minLen) end
                if #bgs ~= minLen then bgs = bgs:sub(1, minLen) end
                local localY = ((y - 1) % self.tileH) + 1
                local len = #chars
                for c = 1, self.cols do
                    local colStart = (c - 1) * self.tileW + 1
                    local colEnd = c * self.tileW
                    local spanStart = math.max(x, colStart)
                    local spanEnd = math.min(x + len - 1, colEnd)
                    if spanStart <= spanEnd then
                        local localX = spanStart - colStart + 1
                        local sliceStart = spanStart - x + 1
                        local sliceEnd = spanEnd - x + 1
                        local mon = grid[c][r]
                        mon.setCursorPos(localX, localY)
                        mon.blit(chars:sub(sliceStart, sliceEnd), fgs:sub(sliceStart, sliceEnd), bgs:sub(sliceStart, sliceEnd))
                    end
                end
            end,
            blitRow = function(self, y, chars, fgs, bgs)
                self:blitSpan(y, 1, chars, fgs, bgs)
            end,
            clear = function(self)
                for c = 1, self.cols do
                    for r = 1, self.rows do
                        grid[c][r].setBackgroundColor(colors.black or 32768)
                        grid[c][r].clear()
                    end
                end
            end,
            restore = function(self)
                for c = 1, self.cols do
                    for r = 1, self.rows do
                        grid[c][r].setCursorPos(1, 1)
                    end
                end
            end
        }
    else
        -- Single monitor or terminal
        local monObj = nil
        if monArg then
            monObj = resolveMonitorTarget(monArg)
        else
            if peripheral then
                monObj = peripheral.find("ceemonitor") or peripheral.find("monitor")
            end
            if not monObj and _G.cee and _G.cee.getMonitors then
                for pin = 1, 11 do
                    local ok, m = pcall(_G.cee.getMonitors, pin)
                    if ok and m and m.getSize then monObj = m break end
                end
            end
        end

        local isTerm = false
        if not monObj then
            monObj = term
            isTerm = true
        end

        if monObj.setTextScale then
            monObj.setTextScale(scale)
        end
        local mw, mh = monObj.getSize()
        monObj.setBackgroundColor(colors.black or 32768)
        monObj.clear()

        return {
            isWall = false,
            isTerm = isTerm,
            width = mw,
            height = mh,
            blitSpan = function(self, y, x, chars, fgs, bgs)
                if y < 1 or y > self.height or x > self.width then return end
                if not chars or not fgs or not bgs then return end
                local minLen = math.min(#chars, #fgs, #bgs)
                if minLen == 0 then return end
                if #chars ~= minLen then chars = chars:sub(1, minLen) end
                if #fgs ~= minLen then fgs = fgs:sub(1, minLen) end
                if #bgs ~= minLen then bgs = bgs:sub(1, minLen) end
                if x + #chars - 1 > self.width then
                    local allowed = self.width - x + 1
                    if allowed <= 0 then return end
                    chars = chars:sub(1, allowed)
                    fgs = fgs:sub(1, allowed)
                    bgs = bgs:sub(1, allowed)
                end
                monObj.setCursorPos(x, y)
                monObj.blit(chars, fgs, bgs)
            end,
            blitRow = function(self, y, chars, fgs, bgs)
                if y < 1 or y > self.height then return end
                if not chars or not fgs or not bgs then return end
                local minLen = math.min(#chars, #fgs, #bgs)
                if minLen == 0 then return end
                if #chars ~= minLen then chars = chars:sub(1, minLen) end
                if #fgs ~= minLen then fgs = fgs:sub(1, minLen) end
                if #bgs ~= minLen then bgs = bgs:sub(1, minLen) end
                if #chars > self.width then
                    chars = chars:sub(1, self.width)
                    fgs = fgs:sub(1, self.width)
                    bgs = bgs:sub(1, self.width)
                end
                monObj.setCursorPos(1, y)
                monObj.blit(chars, fgs, bgs)
            end,
            clear = function(self)
                monObj.setBackgroundColor(colors.black or 32768)
                monObj.clear()
            end,
            restore = function(self)
                monObj.setCursorPos(1, 1)
            end
        }
    end
end

-- Binary stream reader wrapper
local function openBinaryStream(path)
    if fs and fs.open then
        local h = fs.open(path, "rb")
        if not h then return nil end
        return {
            read = function(self, count)
                if count then
                    return h.read(count)
                else
                    return h.read()
                end
            end,
            seek = function(self, offset)
                if h.seek then
                    h.seek("set", offset)
                end
            end,
            close = function(self)
                h.close()
            end
        }
    elseif io and io.open then
        local h = io.open(path, "rb")
        if not h then return nil end
        return {
            read = function(self, count)
                if count then
                    return h:read(count)
                else
                    local b = h:read(1)
                    return b and string.byte(b) or nil
                end
            end,
            seek = function(self, offset)
                h:seek("set", offset)
            end,
            close = function(self)
                h:close()
            end
        }
    end
    return nil
end

local function readUint16(stream)
    local b1 = stream:read()
    local b2 = stream:read()
    if not b1 or not b2 then return nil end
    return b1 * 256 + b2
end

local function readUint32(stream)
    local b1 = stream:read()
    local b2 = stream:read()
    local b3 = stream:read()
    local b4 = stream:read()
    if not b1 or not b2 or not b3 or not b4 then return nil end
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

local function readString(stream, len)
    if not len or len <= 0 then return "" end
    local s = stream:read(len)
    if type(s) == "string" then
        return s
    elseif type(s) == "number" then
        -- Fallback if stream returns byte numbers
        local t = { string.char(s) }
        for i = 2, len do
            local b = stream:read()
            if not b then break end
            t[#t + 1] = string.char(b)
        end
        return table.concat(t)
    end
    return s or ""
end

-- Initialize display
local display, dispErr = setupDisplayAdapter(monitorArg, wallArg, monitorsArg, textScale)
if not display then
    printError("video: " .. tostring(dispErr))
    return
end

-- Initialize Speaker if audio companion available
local activeSpeaker = nil
if targetAudio and sound then
    local spk, spkErr = sound.getSpeaker()
    if spk then
        if spk.isCee and sound.hasPower and not sound.hasPower(spk.name) then
            print("[WARN] CEE Electric Speaker (" .. spk.dev .. ") has no power. Audio disabled.")
        else
            activeSpeaker = spk
        end
    end
end

-- Main playback execution
local function playVideoFile()
    local stream = openBinaryStream(videoPath)
    if not stream then
        return false, "Failed to open video file"
    end

    -- Read 16-byte header
    local magic = readString(stream, 4)
    if magic ~= "LVD1" then
        stream:close()
        return false, "Invalid video container magic: " .. tostring(magic) .. " (expected LVD1)"
    end

    local pixelWidth = readUint16(stream)
    local pixelHeight = readUint16(stream)
    local cols = stream:read()
    local rows = stream:read()
    local fileFps = stream:read()
    local flags = stream:read()
    local totalFrames = readUint32(stream)

    if not pixelWidth or not pixelHeight or not cols or not rows or not fileFps or not flags or not totalFrames then
        stream:close()
        return false, "Truncated video header"
    end
    if cols <= 0 or rows <= 0 then
        stream:close()
        return false, "Invalid video dimensions in header"
    end

    local fps = fpsOverride or fileFps
    if fps <= 0 then fps = 10 end
    local frameDurationMs = 1000 / fps

    -- In-memory frame buffer
    local buffer = {}
    for y = 1, rows do
        buffer[y] = {
            text = string.rep(" ", cols),
            fg = string.rep("0", cols),
            bg = string.rep("f", cols)
        }
    end

    -- Start audio playback if available
    if activeSpeaker and targetAudio then
        sound.playOgg(targetAudio, volume, activeSpeaker.name)
    end

    local startTime = (os.epoch and os.epoch("utc")) or (os.time() * 1000)
    local currentFrame = 0
    local wasDropping = false
    local interrupted = false

    display:clear()

    while currentFrame < totalFrames do
        currentFrame = currentFrame + 1
        local now = (os.epoch and os.epoch("utc")) or (os.time() * 1000)
        local targetFrame = math.floor((now - startTime) / frameDurationMs) + 1
        if targetFrame > totalFrames then targetFrame = totalFrames end

        local isDropping = (currentFrame < targetFrame - 1)

        local frameType = stream:read()
        if not frameType then break end -- EOF

        if frameType == 0x01 then
            -- Keyframe (Full frame)
            local keyOk = true
            for y = 1, rows do
                local txt = readString(stream, cols)
                local fg  = readString(stream, cols)
                local bg  = readString(stream, cols)

                if not txt or not fg or not bg or #txt ~= cols or #fg ~= cols or #bg ~= cols then
                    keyOk = false
                    break
                end

                buffer[y].text = txt
                buffer[y].fg   = fg
                buffer[y].bg   = bg

                if not isDropping then
                    display:blitRow(y, txt, fg, bg)
                end
            end
            if not keyOk then break end

            if isDropping then
                wasDropping = true
            elseif wasDropping then
                -- Redraw screen from buffer on recovery
                for y = 1, rows do
                    display:blitRow(y, buffer[y].text, buffer[y].fg, buffer[y].bg)
                end
                wasDropping = false
            end

        elseif frameType == 0x02 then
            -- Delta frame
            local diffCount = readUint16(stream)
            if not diffCount then break end
            local deltaOk = true
            for d = 1, diffCount do
                local y = stream:read()
                local x = stream:read()
                local len = stream:read()
                if not len then
                    deltaOk = false
                    break
                end

                local txt = readString(stream, len)
                local fg  = readString(stream, len)
                local bg  = readString(stream, len)

                if not txt or not fg or not bg or #txt ~= len or #fg ~= len or #bg ~= len then
                    deltaOk = false
                    break
                end

                if y and 1 <= y and y <= rows and x and 1 <= x and x + len - 1 <= cols then
                    local row = buffer[y]
                    row.text = row.text:sub(1, x - 1) .. txt .. row.text:sub(x + len)
                    row.fg   = row.fg:sub(1, x - 1)   .. fg  .. row.fg:sub(x + len)
                    row.bg   = row.bg:sub(1, x - 1)   .. bg  .. row.bg:sub(x + len)

                    if not isDropping and not wasDropping then
                        display:blitSpan(y, x, txt, fg, bg)
                    end
                end
            end
            if not deltaOk then break end

            if isDropping then
                wasDropping = true
            elseif wasDropping then
                -- Redraw full screen from updated buffer once caught up
                for y = 1, rows do
                    display:blitRow(y, buffer[y].text, buffer[y].fg, buffer[y].bg)
                end
                wasDropping = false
            end
        end

        -- Frame pacing
        local nextFrameTime = startTime + (currentFrame * frameDurationMs)
        local curNow = (os.epoch and os.epoch("utc")) or (os.time() * 1000)
        local sleepMs = nextFrameTime - curNow

        if sleepMs > 2 then
            if os.startTimer and os.pullEvent then
                local timerId = os.startTimer(sleepMs / 1000)
                while true do
                    local ev, p1 = os.pullEvent()
                    if ev == "timer" and p1 == timerId then
                        break
                    elseif ev == "key" then
                        if p1 == (keys and keys.q or 113) or p1 == (keys and keys.x or 120) then
                            interrupted = true
                            break
                        end
                    elseif ev == "terminate" then
                        interrupted = true
                        break
                    end
                end
            else
                if sleepMs >= 50 then
                    os.sleep(sleepMs / 1000)
                end
            end
        elseif currentFrame % 10 == 0 then
            -- Yield to prevent CC "Too long without yielding" watchdog
            if os.queueEvent and os.pullEvent then
                os.queueEvent("video_tick")
                local ev, p1 = os.pullEvent("video_tick")
            end
        end

        if interrupted then break end
    end

    if stream then
        pcall(function() stream:close() end)
    end
    return true, interrupted
end

-- Playback loop
local playbackErr = nil
repeat
    local callOk, ok, interrupted = pcall(playVideoFile)
    if not callOk then
        playbackErr = ok
        break
    end
    if not ok then
        playbackErr = interrupted
        break
    end
    if interrupted then break end
until not loopPlayback

-- Cleanup
if activeSpeaker and sound then
    pcall(sound.stop, activeSpeaker.name)
end
if display and display.restore then
    pcall(display.restore, display)
end

if playbackErr then
    printError("video: " .. tostring(playbackErr))
end
