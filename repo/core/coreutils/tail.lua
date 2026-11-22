-- tail - Output the last part of files
local args = { ... }
local nLines = 10
local files = {}

local i = 1
while i <= #args do
    local a = args[i]
    if a == "-n" and args[i + 1] then
        nLines = tonumber(args[i + 1]) or 10
        i = i + 1
    elseif a:match("^%-n(%d+)$") then
        nLines = tonumber(a:match("^%-n(%d+)$")) or 10
    elseif a:sub(1, 1) ~= "-" then
        table.insert(files, a)
    end
    i = i + 1
end

local function printTail(lines)
    local startIdx = math.max(1, #lines - nLines + 1)
    for j = startIdx, #lines do
        print(lines[j])
    end
end

if #files == 0 then
    local allLines = {}
    while true do
        local line = read()
        if not line then break end
        table.insert(allLines, line)
    end
    printTail(allLines)
else
    for _, f in ipairs(files) do
        local r = (shell and shell.resolve and shell.resolve(f)) or f
        if fs.exists(r) and not fs.isDir(r) then
            local h = fs.open(r, "r")
            if h then
                local allLines = {}
                while true do
                    local line = h.readLine()
                    if not line then break end
                    table.insert(allLines, line)
                end
                h.close()
                printTail(allLines)
            end
        else
            printError("tail: " .. f .. ": No such file or directory")
        end
    end
end
