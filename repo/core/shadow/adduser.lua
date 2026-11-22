-- useradd - Create a new user (Luna OS)
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
    print("useradd: " .. msg)
    if isColor then term.setTextColor(colors.white) end
end

local curUser = (_G.kernel and _G.kernel.syscall and _G.kernel.syscall("getuser")) or _G.CURRENT_USER or "root"
if curUser ~= "root" then
    printErr("Permission denied: only root can add users.")
    return
end

local args = { ... }
if #args == 0 or args[1] == "-h" or args[1] == "--help" then
    print("Usage: useradd [options] LOGIN")
    print("Options:")
    print("  -m, --create-home   create the user's home directory (/home/LOGIN)")
    print("  -s, --shell SHELL   login shell for the user")
    print("  -p, --password PWD  password for the user (optional)")
    print("  -u, --uid UID       user ID for the user")
    return
end

local username = nil
local createHome = true
local customShell = "/usr/bin/core/shell"
local customPwd = ""
local customUid = nil

local i = 1
while i <= #args do
    local a = args[i]
    if a == "-m" or a == "--create-home" then
        createHome = true
    elseif (a == "-s" or a == "--shell") and i < #args then
        i = i + 1
        customShell = args[i]
    elseif (a == "-p" or a == "--password") and i < #args then
        i = i + 1
        customPwd = args[i]
    elseif (a == "-u" or a == "--uid") and i < #args then
        i = i + 1
        customUid = tonumber(args[i])
    elseif not a:find("^%-") then
        username = a
    end
    i = i + 1
end

if not username then
    printErr("no username specified.")
    return
end

if username:lower() == "root" then
    printErr("user 'root' already exists (username 'root' is reserved for superuser).")
    return
end

if isColor then term.setTextColor(colors.cyan or colors.lightBlue) end
print(":: Creating user '" .. username .. "'...")
if isColor then term.setTextColor(colors.white) end

local ok, res, errno = nil, nil, nil
if _G.kernel and _G.kernel.syscall then
    res, ok, errno = _G.kernel.syscall("useradd", username, customPwd, customUid, nil, nil, "/home/" .. username, customShell)
elseif _G.systemd and _G.systemd.addUser then
    ok, res = _G.systemd.addUser(username, customPwd, customUid, nil, nil, "/home/" .. username, customShell)
end

if not ok and not res then
    printErr(tostring(res or ok or "Failed to add user"))
    return
end

local uObj = type(res) == "table" and res or (_G.systemd and _G.systemd.getUser and _G.systemd.getUser(username))

if createHome and uObj and uObj.home then
    if not fs.exists(uObj.home) then
        fs.makeDir(uObj.home)
    end
    local cfg = fs.combine(uObj.home, ".config")
    if not fs.exists(cfg) then fs.makeDir(cfg) end
    if _G.systemd and _G.systemd.setFileAttr then
        _G.systemd.setFileAttr(uObj.home, username, username, "rwx------")
        _G.systemd.setFileAttr(cfg, username, username, "rwx------")
    end
end

logOk(string.format("User '%s' (UID %d) created successfully.", username, (uObj and uObj.uid) or 1000))
