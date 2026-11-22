-- su - Switch user (Luna OS)
local term = term
local colors = colors
local isColor = term.isColor and term.isColor()

local args = { ... }
local targetUser = args[1] or "root"

local systemd = _G.systemd or (fs.exists("/etc/systemd.lua") and dofile("/etc/systemd.lua"))
local u = systemd and systemd.getUser and systemd.getUser(targetUser)

if not u then
    printError("su: user " .. targetUser .. " does not exist")
    return
end

if u.password == "!" or (u.password and u.password:sub(1, 1) == "!") then
    printError("su: account '" .. targetUser .. "' is locked (direct login disabled)")
    return
end

local curUser = (_G.kernel and _G.kernel.syscall and _G.kernel.syscall("getuser")) or _G.CURRENT_USER or "root"

-- If switching from non-root to a different user, password is required
if curUser ~= "root" and targetUser ~= curUser then
    if u.password and u.password ~= "" and u.password ~= "none" then
        write("Password: ")
        local pwd = read("*")
        if not systemd.verifyPassword(targetUser, pwd) then
            printError("su: Authentication failure")
            return
        end
    end
end

-- Update kernel process user and global environment
if _G.kernel and _G.kernel.syscall then
    _G.kernel.syscall("setuser", targetUser)
end
_G.CURRENT_USER = targetUser

-- Ensure home directory exists and switch directory
local userHome = u.home or (targetUser == "root" and "/" or ("/home/" .. targetUser))
if not fs.exists(userHome) then
    pcall(fs.makeDir, userHome)
end

if shell and shell.setDir then
    shell.setDir(userHome)
end

if isColor then term.setTextColor(colors.green or colors.lime) end
print(":: Switched to user " .. targetUser)
if isColor then term.setTextColor(colors.white) end
