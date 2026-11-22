-- wc - Print newline, word, and byte counts for each file
local args = { ... }
local countLines = false
local countWords = false
local countBytes = false
local files = {}

for _, a in ipairs(args) do
    if a == "-l" or a == "--lines" then
        countLines = true
    elseif a == "-w" or a == "--words" then
        countWords = true
    elseif a == "-c" or a == "-m" or a == "--bytes" then
        countBytes = true
    elseif a:sub(1, 1) ~= "-" then
        table.insert(files, a)
    end
end

if not countLines and not countWords and not countBytes then
    countLines = true
    countWords = true
    countBytes = true
end

local function countContent(str)
    local lines = 0
    local words = 0
    local bytes = #str

    for _ in str:gmatch("\n") do lines = lines + 1 end
    for _ in str:gmatch("%S+") do words = words + 1 end
    return lines, words, bytes
end

local function printStats(l, w, b, name)
    local parts = {}
    if countLines then table.insert(parts, string.format("%d", l)) end
    if countWords then table.insert(parts, string.format("%d", w)) end
    if countBytes then table.insert(parts, string.format("%d", b)) end
    if name then table.insert(parts, name) end
    print(table.concat(parts, " "))
end

if #files == 0 then
    local allLines = {}
    while true do
        local line = read()
        if not line then break end
        table.insert(allLines, line)
    end
    local text = table.concat(allLines, "\n")
    local l, w, b = countContent(text)
    printStats(l, w, b)
else
    local totalL, totalW, totalB = 0, 0, 0
    for _, f in ipairs(files) do
        local r = (shell and shell.resolve and shell.resolve(f)) or f
        if fs.exists(r) and not fs.isDir(r) then
            local h = fs.open(r, "r")
            if h then
                local text = h.readAll() or ""
                h.close()
                local l, w, b = countContent(text)
                totalL = totalL + l
                totalW = totalW + w
                totalB = totalB + b
                printStats(l, w, b, f)
            end
        else
            printError("wc: " .. f .. ": No such file or directory")
        end
    end
    if #files > 1 then
        printStats(totalL, totalW, totalB, "total")
    end
end
