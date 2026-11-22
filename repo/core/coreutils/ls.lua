-- POSIX ls implementation
local args = { ... }
local showAll = false
local longFormat = false
local humanReadable = false
local onePerLine = false
local reverseSort = false
local sortBySize = false
local sortByTime = false
local classify = false

local targets = {}

for _, arg in ipairs(args) do
    if arg:sub(1, 2) == "--" then
        local flag = arg:sub(3)
        if flag == "all" then showAll = true
        elseif flag == "human-readable" then humanReadable = true
        end
    elseif arg:sub(1, 1) == "-" and #arg > 1 then
        for i = 2, #arg do
            local c = arg:sub(i, i)
            if c == "a" then showAll = true
            elseif c == "l" then longFormat = true
            elseif c == "h" then humanReadable = true
            elseif c == "1" then onePerLine = true
            elseif c == "r" then reverseSort = true
            elseif c == "S" then sortBySize = true
            elseif c == "t" then sortByTime = true
            elseif c == "F" then classify = true
            end
        end
    else
        table.insert(targets, arg)
    end
end

if #targets == 0 then
    table.insert(targets, ".")
end

local function formatSize(bytes)
    if not humanReadable then return bytes .. " B" end
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    elseif bytes >= 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return bytes .. " B"
    end
end

local systemd = _G.systemd or (fs.exists("/etc/systemd.lua") and dofile("/etc/systemd.lua"))
local curUser = _G.CURRENT_USER or "root"
local curHome = (systemd and systemd.getUserHome and systemd.getUserHome(curUser))
    or (curUser == "root" and "/" or ("/home/" .. curUser))

local function resolvePath(path)
    if path == "~" then
        return curHome
    elseif path:sub(1, 2) == "~/" then
        return fs.combine(curHome, path:sub(3))
    end
    return shell.resolve(path)
end

local fileTargets = {}
local dirTargets = {}

for _, rawTarget in ipairs(targets) do
    local fullPath = resolvePath(rawTarget)
    local clean = fs.combine(fullPath, "")

    if not fs.exists(clean) then
        printError("ls: cannot access '" .. rawTarget .. "': No such file or directory")
    elseif not fs.isDir(clean) then
        table.insert(fileTargets, { raw = rawTarget, clean = clean, name = fs.getName(clean) })
    else
        table.insert(dirTargets, { raw = rawTarget, clean = clean })
    end
end

-- Process direct file targets first
if #fileTargets > 0 then
    if longFormat then
        for _, f in ipairs(fileTargets) do
            local size = fs.getSize(f.clean) or 0
            local owner, group, mode = "root", "root", "rw-r--r--"
            if systemd and systemd.getFileAttr then
                owner, group, mode = systemd.getFileAttr(f.clean)
            end
            print(string.format("-%s 1 %-5s %-5s %8s %s", mode, owner, group, formatSize(size), f.raw))
        end
    elseif onePerLine then
        for _, f in ipairs(fileTargets) do
            print(f.raw)
        end
    else
        local w, _ = term.getSize()
        local maxLen = 0
        for _, f in ipairs(fileTargets) do
            if #f.raw > maxLen then maxLen = #f.raw end
        end
        local colWidth = math.max(maxLen + 2, 12)
        local numCols = math.max(math.floor(w / colWidth), 1)
        local colIdx = 0
        for _, f in ipairs(fileTargets) do
            local padded = f.raw .. string.rep(" ", colWidth - #f.raw)
            write(padded)
            colIdx = colIdx + 1
            if colIdx >= numCols then
                print()
                colIdx = 0
            end
        end
        if colIdx > 0 then print() end
    end
    if #dirTargets > 0 then print() end
end

-- Process directory targets
for _, dt in ipairs(dirTargets) do
    local rawTarget = dt.raw
    local clean = dt.clean

    -- Check read permission
    if systemd and systemd.checkAccess and not systemd.checkAccess(clean, curUser, "r") then
        printError("ls: cannot open directory '" .. rawTarget .. "': Permission denied")
    else
        local rawEntries = fs.list(clean)
            local entries = {}

            if showAll then
                table.insert(entries, ".")
                table.insert(entries, "..")
            end

            for _, e in ipairs(rawEntries) do
                if showAll or e:sub(1, 1) ~= "." then
                    table.insert(entries, e)
                end
            end

            local items = {}
            for _, name in ipairs(entries) do
                local itemPath
                if name == "." then
                    itemPath = clean
                elseif name == ".." then
                    itemPath = fs.getDir(clean)
                else
                    itemPath = fs.combine(clean, name)
                end

                local isDir = (name == "." or name == "..") or fs.isDir(itemPath)
                local size = isDir and 4096 or (fs.getSize(itemPath) or 0)
                local attr = fs.attributes(itemPath) or {}
                local modTime = attr.modified or 0
                local owner, group, mode = "root", "root", "rwxr-xr-x"
                if systemd and systemd.getFileAttr then
                    owner, group, mode = systemd.getFileAttr(itemPath)
                end

                table.insert(items, {
                    name = name,
                    isDir = isDir,
                    size = size,
                    time = modTime,
                    owner = owner,
                    group = group,
                    mode = mode
                })
            end

            table.sort(items, function(a, b)
                local res
                if sortBySize then
                    res = a.size > b.size
                elseif sortByTime then
                    res = a.time > b.time
                else
                    res = a.name:lower() < b.name:lower()
                end
                if reverseSort then return not res end
                return res
            end)

            if #dirTargets > 1 or #fileTargets > 0 then
                print(rawTarget .. ":")
            end

            if longFormat then
                for _, item in ipairs(items) do
                    local prefix = item.isDir and "d" or "-"
                    local perm = prefix .. item.mode
                    local displayName = item.name
                    if classify and item.isDir then displayName = displayName .. "/" end

                    if term.isColor() and item.isDir then
                        term.setTextColor(colors.blue)
                    end
                    print(string.format("%s 1 %-5s %-5s %8s %s", perm, item.owner, item.group, formatSize(item.size), displayName))
                    if term.isColor() then
                        term.setTextColor(colors.white)
                    end
                end
            else
                if onePerLine then
                    for _, item in ipairs(items) do
                        if term.isColor() and item.isDir then term.setTextColor(colors.blue) end
                        print(item.name .. (classify and item.isDir and "/" or ""))
                        if term.isColor() then term.setTextColor(colors.white) end
                    end
                else
                    local w, _ = term.getSize()
                    local maxLen = 0
                    for _, item in ipairs(items) do
                        local l = #item.name + (classify and item.isDir and 1 or 0)
                        if l > maxLen then maxLen = l end
                    end
                    local colWidth = math.max(maxLen + 2, 12)
                    local numCols = math.max(math.floor(w / colWidth), 1)

                    local colIdx = 0
                    for _, item in ipairs(items) do
                        local dn = item.name .. (classify and item.isDir and "/" or "")
                        local padded = dn .. string.rep(" ", colWidth - #dn)
                        if term.isColor() and item.isDir then term.setTextColor(colors.blue) end
                        write(padded)
                        if term.isColor() then term.setTextColor(colors.white) end

                        colIdx = colIdx + 1
                        if colIdx >= numCols then
                            print()
                            colIdx = 0
                        end
                    end
                    if colIdx > 0 then print() end
                end
            end

            if #dirTargets > 1 then print() end
    end
end
