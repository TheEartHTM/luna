-- userdel - Delete a user account (Luna OS)
local term = term
local colors = colors
local isColor = term.isColor and term.isColor()

local function logOk(msg)
    if isColor then
        term.setTextColor(colors.white)
        term.write("[  ")
        term.setTextColor(colors.green or colors.lime)
        term.write("OK")
        term.setTextColor(colors.white)
        term.write("  ] ")
        term.setTextColor(colors.white)
        print(msg)
    else
        print("[  OK  ] " .. msg)
    end
end

local function printErr(msg)
    if isColor then term.setTextColor(colors.red) end
    print("userdel: " .. msg)
    if isColor then term.setTextColor(colors.white) end
end

local curUser = (_G.kernel and _G.kernel.syscall and _G.kernel.syscall("getuser")) or _G.CURRENT_USER or "root"
if curUser ~= "root" then
    printErr("Permission denied: only root can remove users.")
    return
end

local args = { ... }
if #args == 0 or args[1] == "-h" or args[1] == "--help" then
    print("Usage: userdel [options] LOGIN")
    print("Options:")
    print("  -r, --remove   remove home directory and mail spool")
    print("  -f, --force    force removal")
    return
end

local username = nil
local removeHome = false

for _, a in ipairs(args) do
    if a == "-r" or a == "--remove" then
        removeHome = true
    elseif not a:find("^%-") then
        username = a
    end
end

if not username then
    printErr("no username specified.")
    return
end

if username == "root" then
    printErr("user 'root' cannot be removed.")
    return
end

if isColor then term.setTextColor(colors.cyan or colors.lightBlue) end
print(":: Removing user '" .. username .. "'...")
if isColor then term.setTextColor(colors.white) end

local ok, err = nil, nil
if _G.kernel and _G.kernel.syscall then
    local res, msg = _G.kernel.syscall("userdel", username, removeHome)
    if res == 0 then ok = true else ok = false err = msg end
elseif _G.systemd and _G.systemd.delUser then
    ok, err = _G.systemd.delUser(username, removeHome)
end

if not ok then
    printErr(tostring(err or "Failed to remove user"))
    return
end

logOk(string.format("User '%s' removed successfully.", username))
