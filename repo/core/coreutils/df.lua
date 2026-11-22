-- df - Report filesystem disk space usage
local args = { ... }

local human = true
local showAll = false
local showType = false

for _, a in ipairs(args) do
    if a == "-h" or a == "--human-readable" then
        human = true
    elseif a == "-k" then
        human = false
    elseif a == "-a" or a == "--all" then
        showAll = true
    elseif a == "-T" or a == "--print-type" then
        showType = true
    elseif a == "--help" then
        print("Usage: df [OPTION]...")
        print("Show filesystem disk space usage.")
        print("  -h, --human-readable  print sizes in powers of 1024 (default)")
        print("  -k                    print sizes in 1K blocks")
        print("  -a, --all             include individual memory modules and rom")
        print("  -T, --print-type      print filesystem type")
        return
    end
end

local function formatSize(bytes)
    if not bytes then return "-" end
    if not human then
        return string.format("%dK", math.floor(bytes / 1024))
    end
    if bytes < 1024 then
        return string.format("%dB", bytes)
    elseif bytes < 1024 * 1024 then
        local k = bytes / 1024
        if k >= 100 then
            return string.format("%dK", math.floor(k))
        else
            return string.format("%.1fK", k):gsub("%.0K", "K")
        end
    elseif bytes < 1024 * 1024 * 1024 then
        local m = bytes / (1024 * 1024)
        if m >= 100 then
            return string.format("%dM", math.floor(m))
        else
            return string.format("%.1fM", m):gsub("%.0M", "M")
        end
    else
        return string.format("%.1fG", bytes / (1024 * 1024 * 1024)):gsub("%.0G", "G")
    end
end

local rows = {}

-- 1. Pooled Root Filesystem (RAID-0)
local rootCap = (fs.getCapacity and fs.getCapacity("/")) or 0
local rootFree = fs.getFreeSpace("/") or 0
if rootCap == 0 and _G.RAID_DRIVES and _G.ORIG_FS and _G.ORIG_FS.getCapacity then
    for _, d in ipairs(_G.RAID_DRIVES) do
        rootCap = rootCap + (_G.ORIG_FS.getCapacity(d) or 0)
    end
end
local rootUsed = math.max(0, rootCap - rootFree)
local rootUsePct = (rootCap > 0) and math.floor((rootUsed / rootCap) * 100) or 0

table.insert(rows, {
    fs = "/dev/raid0",
    fstype = "luna_raid0",
    size = rootCap,
    used = rootUsed,
    avail = rootFree,
    pcent = rootUsePct .. "%",
    mount = "/"
})

-- 2. Boot Partition (/boot)
if fs.exists("/boot") or fs.exists("/mem") then
    local bootCap = (fs.getCapacity and (fs.getCapacity("/boot") or fs.getCapacity("/mem"))) or 0
    if bootCap == 0 and _G.ORIG_FS and _G.ORIG_FS.getCapacity then
        bootCap = _G.ORIG_FS.getCapacity("mem") or 0
    end
    local bootFree = (fs.getFreeSpace("/boot") or fs.getFreeSpace("/mem")) or 0
    local bootUsed = math.max(0, bootCap - bootFree)
    local bootUsePct = (bootCap > 0) and math.floor((bootUsed / bootCap) * 100) or 0

    table.insert(rows, {
        fs = "/dev/boot",
        fstype = "luna_boot",
        size = bootCap,
        used = bootUsed,
        avail = bootFree,
        pcent = bootUsePct .. "%",
        mount = "/boot"
    })
end

-- 3. Additional drives / individual modules if -a was specified
if showAll then
    if _G.RAID_DRIVES and _G.ORIG_FS then
        for _, d in ipairs(_G.RAID_DRIVES) do
            local cap = (_G.ORIG_FS.getCapacity and _G.ORIG_FS.getCapacity(d)) or 0
            local free = (_G.ORIG_FS.getFreeSpace and _G.ORIG_FS.getFreeSpace(d)) or 0
            local used = math.max(0, cap - free)
            local pct = (cap > 0) and math.floor((used / cap) * 100) or 0

            table.insert(rows, {
                fs = "/dev/" .. d,
                fstype = "luna_mem",
                size = cap,
                used = used,
                avail = free,
                pcent = pct .. "%",
                mount = "[raid]"
            })
        end
    end

    if fs.exists("rom") then
        local romCap = (fs.getCapacity and fs.getCapacity("rom")) or 0
        table.insert(rows, {
            fs = "/dev/rom",
            fstype = "romfs",
            size = romCap,
            used = romCap,
            avail = 0,
            pcent = "100%",
            mount = "/rom"
        })
    end
end

-- Output formatting
if showType then
    print(string.format("%-11s %-9s %6s %5s %5s %4s %s", "Filesystem", "Type", "Size", "Used", "Avail", "Use%", "Mounted on"))
    for _, r in ipairs(rows) do
        print(string.format("%-11s %-9s %6s %5s %5s %4s %s",
            r.fs,
            r.fstype,
            formatSize(r.size),
            formatSize(r.used),
            formatSize(r.avail),
            r.pcent,
            r.mount
        ))
    end
else
    print(string.format("%-12s %6s %6s %6s %5s %s", "Filesystem", "Size", "Used", "Avail", "Use%", "Mounted on"))
    for _, r in ipairs(rows) do
        print(string.format("%-12s %6s %6s %6s %5s %s",
            r.fs,
            formatSize(r.size),
            formatSize(r.used),
            formatSize(r.avail),
            r.pcent,
            r.mount
        ))
    end
end
