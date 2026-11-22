-- POSIX chown utility
local args = { ... }
local recursive = false
local spec, target

for _, a in ipairs(args) do
    if a == "-R" or a == "-r" then
        recursive = true
    elseif not spec then
        spec = a
    elseif not target then
        target = a
    end
end

if not spec or not target then
    printError("Usage: chown [-R] [owner][:group] <file|dir>")
    return
end

local owner, group = spec:match("^([^:]*):?(.*)$")
if owner == "" then owner = nil end
if group == "" then group = nil end

local systemd = _G.systemd or dofile("/etc/systemd.lua")

local function apply(path)
    local resolved = shell.resolve(path)
    if not fs.exists(resolved) then
        printError("chown: cannot access '" .. path .. "': No such file or directory")
        return
    end

    systemd.setFileAttr(resolved, owner, group, nil)

    if recursive and fs.isDir(resolved) then
        for _, child in ipairs(fs.list(resolved)) do
            apply(fs.combine(resolved, child))
        end
    end
end

apply(target)
