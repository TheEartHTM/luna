-- touch - Change file access and modification times / create empty file
local args = { ... }
if #args == 0 then
    printError("Usage: touch <file> [file2...]")
    return
end

local systemd = _G.systemd or (fs.exists("/etc/systemd.lua") and dofile("/etc/systemd.lua"))
local curUser = _G.CURRENT_USER or "root"

for _, path in ipairs(args) do
    if path:sub(1, 1) ~= "-" then
        local resolved = shell.resolve(path)
        if fs.exists(resolved) then
            if systemd and systemd.checkAccess and not systemd.checkAccess(resolved, curUser, "w") then
                printError("touch: cannot touch '" .. path .. "': Permission denied")
            else
                local h = fs.open(resolved, "a")
                if h then h.close() end
            end
        else
            local parent = fs.getDir(resolved)
            if parent ~= "" and systemd and systemd.checkAccess and not systemd.checkAccess(parent, curUser, "w") then
                printError("touch: cannot touch '" .. path .. "': Permission denied")
            else
                local h = fs.open(resolved, "w")
                if not h then
                    printError("touch: cannot touch '" .. path .. "': Permission denied or invalid path")
                else
                    h.close()
                    if systemd and systemd.setFileAttr then
                        systemd.setFileAttr(resolved, curUser, curUser, "rw-r--r--")
                    end
                end
            end
        end
    end
end
