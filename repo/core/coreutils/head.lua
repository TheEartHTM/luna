-- head - Output the first part of files
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

if #files == 0 then
    local count = 0
    while count < nLines do
        local line = read()
        if not line then break end
        print(line)
        count = count + 1
    end
else
    for _, f in ipairs(files) do
        local r = (shell and shell.resolve and shell.resolve(f)) or f
        if fs.exists(r) and not fs.isDir(r) then
            local h = fs.open(r, "r")
            if h then
                local count = 0
                while count < nLines do
                    local line = h.readLine()
                    if not line then break end
                    print(line)
                    count = count + 1
                end
                h.close()
            end
        end
    end
end
