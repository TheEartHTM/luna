-- fastfetch - Compact System Information Tool for Luna OS (CEE Edition)
local term = term
local colors = colors
local isColor = term.isColor and term.isColor()

-- 1. Real System Data Collection
local user = _G.CURRENT_USER or "root"
local host = "luna"
if fs.exists("/etc/conf/network.conf") then
    local h = fs.open("/etc/conf/network.conf", "r")
    if h then
        local content = h.readAll()
        h.close()
        local ok, data = pcall(textutils.unserialize, content)
        if ok and type(data) == "table" and data.hostname then host = data.hostname end
    end
end

-- Uptime
local uptimeSec = math.floor(os.clock())
local uptimeStr = ""
if uptimeSec >= 3600 then
    local hrs = math.floor(uptimeSec / 3600)
    local mins = math.floor((uptimeSec % 3600) / 60)
    uptimeStr = string.format("%dh %dm", hrs, mins)
elseif uptimeSec >= 60 then
    local mins = math.floor(uptimeSec / 60)
    local secs = uptimeSec % 60
    uptimeStr = string.format("%dm %ds", mins, secs)
else
    uptimeStr = string.format("%ds", uptimeSec)
end

-- Packages Count
local pkgCount = 0
local dbPath = fs.exists("/etc/conf/dust.db") and "/etc/conf/dust.db" or "/etc/dust.db"
if fs.exists(dbPath) then
    local h = fs.open(dbPath, "r")
    if h then
        local c = h.readAll()
        h.close()
        local ok, data = pcall(textutils.unserialize, c)
        if ok and type(data) == "table" then
            for _ in pairs(data) do pkgCount = pkgCount + 1 end
        end
    end
end
local pkgStr = tostring(pkgCount) .. " (dust)"

-- Storage (/)
local function fmtBytes(bytes)
    if not bytes or bytes <= 0 then return "0 B" end
    if bytes < 1024 then return bytes .. " B" end
    if bytes < 1024 * 1024 then return string.format("%.1f KiB", bytes / 1024) end
    if bytes < 1024 * 1024 * 1024 then return string.format("%.1f MiB", bytes / (1024 * 1024)) end
    return string.format("%.1f GiB", bytes / (1024 * 1024 * 1024))
end

local rootCap = (fs.getCapacity and fs.getCapacity("/")) or 0
local rootFree = (fs.getFreeSpace and fs.getFreeSpace("/")) or 0
local rootUsed = math.max(0, rootCap - rootFree)
local rootPercent = (rootCap > 0) and math.floor((rootUsed / rootCap) * 100) or 0
local diskStr = string.format("%s / %s (%d%%)", fmtBytes(rootUsed), fmtBytes(rootCap), rootPercent)

-- Safe Memory Measurement
local memStr = "128 KiB"
if os.totalMemory and os.freeMemory then
    local total = os.totalMemory()
    local free = os.freeMemory()
    local used = math.max(0, total - free)
    memStr = string.format("%d KiB / %d KiB", math.floor(used / 1024), math.floor(total / 1024))
elseif _G.collectgarbage then
    local ok, kb = pcall(_G.collectgarbage, "count")
    if ok and kb then memStr = string.format("%d KiB", math.floor(kb)) end
end

-- Resolution
local termW, termH = term.getSize()
local resStr = string.format("%dx%d", termW, termH)

-- Computer ID & Label
local compId = os.getComputerID and os.getComputerID() or 0
local compLabel = os.getComputerLabel and os.getComputerLabel() or "ComputerCraft"
local hostStr = string.format("%s (#%d)", compLabel, compId)

-- Network IP
local ipStr = "offline"
if _G.LunaNet then
    local netConf = _G.LunaNet.loadConfig()
    if netConf and netConf.ip then ipStr = netConf.ip end
elseif fs.exists("/etc/conf/network.conf") then
    local h = fs.open("/etc/conf/network.conf", "r")
    if h then
        local c = h.readAll()
        h.close()
        local ok, data = pcall(textutils.unserialize, c)
        if ok and type(data) == "table" and data.ip then ipStr = data.ip end
    end
end

-- Connected Peripherals
local periphList = {}
if peripheral and peripheral.getNames then
    local seenTypes = {}
    for _, name in ipairs(peripheral.getNames()) do
        local pType = peripheral.getType(name) or name
        if not seenTypes[pType] then
            seenTypes[pType] = true
            table.insert(periphList, pType)
        end
    end
end
local periphStr = (#periphList > 0) and table.concat(periphList, ", ") or "None"

-- Compact Scaled Crescent Moon (15 lines tall, 22 chars wide)
local moonArt = {
    "                .     ",
    "                .-.   ",
    "                .:=:  ",
    "                .:-=: ",
    "                .:-==.",
    "                ::-==:",
    "               .:-===-",
    "              .:-====-",
    "             .::-====:",
    "            .::--==== ",
    "         .:::---====. ",
    "        .:-:-======.  ",
    "      .:----=====-    ",
    "    .:--======-:      ",
    "..::====---:.         "
}

-- Information lines
local infoRows = {
    { type = "title", val = user .. "@" .. host },
    { type = "div" },
    { key = "OS",          val = "Luna OS 0.2" },
    { key = "Host",        val = host },
    { key = "Kernel",      val = "Luna BIOS v0.2" },
    { key = "Uptime",      val = uptimeStr },
    { key = "Packages",    val = pkgStr },
    { key = "Shell",       val = "Luna Shell" },
    { key = "Display",     val = resStr },
    { key = "Disk (/)",    val = diskStr },
    { key = "Memory",      val = memStr },
    { key = "Network",     val = ipStr },
    { key = "Hardware",    val = periphStr }
}

-- Shading color map for the moon:
-- = -> white (0)
-- - -> yellow (4)
-- : -> orange (1)
-- . -> lightGray (8)
-- space -> black (f)
local function getMoonHex(char)
    if char == "=" then return "0"
    elseif char == "-" then return "4"
    elseif char == ":" then return "1"
    elseif char == "." then return "8"
    else return "f" end
end

local maxLines = math.max(#moonArt, #infoRows)

for i = 1, maxLines do
    local mLine = moonArt[i] or "                      "
    local row = infoRows[i]

    -- Build moon text and color
    local moonText = mLine
    local moonFg = {}
    local moonBg = {}
    for cIdx = 1, #moonText do
        local ch = moonText:sub(cIdx, cIdx)
        table.insert(moonFg, getMoonHex(ch))
        table.insert(moonBg, "f")
    end

    -- Build info text and color
    local infoText = ""
    local infoFg = ""
    if row then
        if row.type == "title" then
            infoText = row.val
            infoFg = string.rep("4", #infoText) -- yellow
        elseif row.type == "div" then
            local divLen = math.min(30, math.max(16, #user + #host + 1))
            infoText = string.rep("-", divLen)
            infoFg = string.rep("7", divLen) -- gray
        else
            local prefix = string.format("%-10s: ", row.key)
            infoText = prefix .. row.val
            local prefCol = string.rep("3", #prefix) -- lightBlue
            local valCol  = string.rep("0", #row.val)  -- white
            infoFg = prefCol .. valCol
        end
    end

    local gap = "   "
    local gapFg = "fff"

    local fullText = moonText .. gap .. infoText
    local fullFg   = table.concat(moonFg) .. gapFg .. infoFg
    local fullBg   = table.concat(moonBg) .. "fff" .. string.rep("f", #infoText)

    if term.blit and isColor then
        term.blit(fullText, fullFg, fullBg)
        print()
    else
        print(fullText)
    end
end

-- Fastfetch Color Blocks (classic bottom color bar)
local colorBlocks = { "f", "e", "d", "4", "b", "2", "9", "0" }
local brightBlocks = { "7", "8", "5", "4", "3", "6", "9", "0" }

if term.blit and isColor then
    local pad = string.rep(" ", 25)
    local bT = string.rep(" ", #colorBlocks * 3)
    local bF = string.rep("0", #colorBlocks * 3)
    local bB1 = ""
    local bB2 = ""
    for _, c in ipairs(colorBlocks) do bB1 = bB1 .. string.rep(c, 3) end
    for _, c in ipairs(brightBlocks) do bB2 = bB2 .. string.rep(c, 3) end

    term.blit(pad .. bT, pad .. bF, string.rep("f", #pad) .. bB1)
    print()
    term.blit(pad .. bT, pad .. bF, string.rep("f", #pad) .. bB2)
    print()
end
if isColor then term.setTextColor(colors.white) end
