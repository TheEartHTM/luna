-- passwd - Change user password
local args = { ... }
local targetUser = args[1] or _G.CURRENT_USER or "root"

local systemd = _G.systemd or (fs.exists("/etc/systemd.lua") and dofile("/etc/systemd.lua"))
local u = systemd and systemd.getUser and systemd.getUser(targetUser)

if not u then
    printError("passwd: user '" .. targetUser .. "' does not exist")
    return
end

-- If not root, current password is required
if (_G.CURRENT_USER or "root") ~= "root" then
    if targetUser ~= _G.CURRENT_USER then
        printError("passwd: You may not view or modify password information for " .. targetUser)
        return
    end
    write("Current password: ")
    local curPwd = read("*")
    if not systemd.verifyPassword(targetUser, curPwd) then
        printError("passwd: Authentication token manipulation error / password incorrect")
        return
    end
end

write("New password: ")
local newPwd = read("*")
if #newPwd == 0 then
    printError("passwd: password unchanged (empty)")
    return
end

write("Retype new password: ")
local confirmPwd = read("*")

if newPwd ~= confirmPwd then
    printError("passwd: Passwords do not match")
    return
end

systemd.setPassword(targetUser, newPwd)
print("passwd: password updated successfully")
