-- rm - Remove files and directories
local args = { ... }
local recursive = false
local force = false
local targets = {}

for _, a in ipairs(args) do
    if a:sub(1, 1) == "-" and #a > 1 then
        for i = 2, #a do
            local c = a:sub(i, i)
            if c == "r" or c == "R" then
                recursive = true
            elseif c == "f" or c == "F" then
                force = true
            end
        end
    else
        table.insert(targets, a)
    end
end

if #targets == 0 then
    if not force then
        printError("Usage: rm [-r] [-f] <file|dir>...")
    end
    return
end

local systemd = _G.systemd or (fs.exists("/etc/systemd.lua") and dofile("/etc/systemd.lua"))
local curUser = _G.CURRENT_USER or "root"

for _, path in ipairs(targets) do
    local resolved = shell.resolve(path)
    if not fs.exists(resolved) then
        if not force then
            printError("rm: cannot remove '" .. path .. "': No such file or directory")
        end
    elseif fs.isDir(resolved) and not recursive then
        printError("rm: cannot remove '" .. path .. "': Is a directory (use -r)")
    else
        if not force and systemd and systemd.checkAccess and not systemd.checkAccess(resolved, curUser, "w") then
            printError("rm: cannot remove '" .. path .. "': Permission denied")
        else
            local ok, err = pcall(fs.delete, resolved)
            if not ok and not force then
                printError("rm: cannot remove '" .. path .. "': " .. tostring(err))
            end
        end
    end
end
