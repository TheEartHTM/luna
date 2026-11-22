-- sudo - Execute a command as another user (default: root)
local args = { ... }
if #args == 0 then
    printError("usage: sudo command [args...]")
    return
end

local curUser = _G.CURRENT_USER or "root"
local systemd = _G.systemd or (fs.exists("/etc/systemd.lua") and dofile("/etc/systemd.lua"))

-- Function to check if user is allowed in /etc/sudoers
local function isSudoer(user)
    if user == "root" then return true end
    if systemd and systemd.checkSudoers then
        return systemd.checkSudoers(user)
    end
    local sudoersPath = "/etc/sudoers"
    if not fs.exists(sudoersPath) then return false end
    local h = fs.open(sudoersPath, "r")
    if not h then return false end
    local allowed = false
    while true do
        local line = h.readLine()
        if not line then break end
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local u = line:match("^([%w_%-]+)")
            if u == user then
                allowed = true
                break
            end
        end
    end
    h.close()
    return allowed
end

-- If not root, verify membership in sudoers and authenticate
if curUser ~= "root" then
    if not isSudoer(curUser) then
        printError(curUser .. " is not in the sudoers file. This incident will be reported.")
        return
    end

    write("[sudo] password for " .. curUser .. ": ")
    local pwd = read("*")
    if not (systemd and systemd.verifyPassword and systemd.verifyPassword(curUser, pwd)) then
        printError("sudo: 1 incorrect password attempt")
        return
    end
end

-- Elevate to root privileges and execute command
local prevUser = _G.CURRENT_USER
_G.CURRENT_USER = "root"

local prog = args[1]
local cmdArgs = {}
for i = 2, #args do
    table.insert(cmdArgs, args[i])
end

local ok, err = pcall(function()
    shell.execute(prog, table.unpack(cmdArgs))
end)

_G.CURRENT_USER = prevUser

if not ok then
    printError(err)
end
