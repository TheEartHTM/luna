-- grep - Search for patterns in files or standard input
local args = { ... }
local ignoreCase = false
local invertMatch = false
local pattern = nil
local files = {}

local i = 1
while i <= #args do
    local a = args[i]
    if a == "-i" or a == "--ignore-case" then
        ignoreCase = true
    elseif a == "-v" or a == "--invert-match" then
        invertMatch = true
    elseif not pattern and a:sub(1, 1) ~= "-" then
        pattern = a
    elseif a:sub(1, 1) ~= "-" then
        table.insert(files, a)
    end
    i = i + 1
end

if not pattern then
    printError("Usage: grep [-i] [-v] <pattern> [files...]")
    return
end

local function matchLine(line, pat)
    local l = ignoreCase and line:lower() or line
    local p = ignoreCase and pat:lower() or pat
    local found = l:find(p, 1, true) ~= nil
    if invertMatch then return not found else return found end
end

if #files == 0 then
    while true do
        local line = read()
        if not line then break end
        if matchLine(line, pattern) then print(line) end
    end
else
    for _, f in ipairs(files) do
        local r = (shell and shell.resolve and shell.resolve(f)) or f
        if fs.exists(r) and not fs.isDir(r) then
            local h = fs.open(r, "r")
            if h then
                while true do
                    local line = h.readLine()
                    if not line then break end
                    if matchLine(line, pattern) then print(line) end
                end
                h.close()
            end
        end
    end
end
