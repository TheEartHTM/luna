-- POSIX chmod utility
local args = { ... }
local recursive = false
local mode, target

for _, a in ipairs(args) do
    if a == "-R" or a == "-r" then
        recursive = true
    elseif not mode then
        mode = a
    elseif not target then
        target = a
    end
end

if not mode or not target then
    printError("Usage: chmod [-R] <mode> <file|dir>")
    print("Example: chmod 755 /etc or chmod 700 /home/test")
    return
end

local function octalToSymbolic(oct)
    local mapping = {
        ["0"] = "---",
        ["1"] = "--x",
        ["2"] = "-w-",
        ["3"] = "-wx",
        ["4"] = "r--",
        ["5"] = "r-x",
        ["6"] = "rw-",
        ["7"] = "rwx"
    }
    if #oct == 3 then
        local u = mapping[oct:sub(1, 1)] or "rwx"
        local g = mapping[oct:sub(2, 2)] or "r-x"
        local o = mapping[oct:sub(3, 3)] or "r-x"
        return u .. g .. o
    end
    return nil
end

local symbolicMode = mode
if mode:match("^%d%d%d$") then
    symbolicMode = octalToSymbolic(mode)
end

if not symbolicMode or #symbolicMode ~= 9 then
    printError("chmod: invalid mode: '" .. mode .. "'")
    return
end

local systemd = _G.systemd or dofile("/etc/systemd.lua")

local function apply(path)
    local resolved = shell.resolve(path)
    if not fs.exists(resolved) then
        printError("chmod: cannot access '" .. path .. "': No such file or directory")
        return
    end

    systemd.setFileAttr(resolved, nil, nil, symbolicMode)

    if recursive and fs.isDir(resolved) then
        for _, child in ipairs(fs.list(resolved)) do
            apply(fs.combine(resolved, child))
        end
    end
end

apply(target)
