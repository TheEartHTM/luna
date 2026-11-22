-- systemd - Core System & Service Manager for Luna (Lua-Unified Network Architecture) OS
local M = {}

local PASSWD_FILE  = "/etc/passwd"
local GROUP_FILE   = "/etc/group"
local SUDOERS_FILE = "/etc/sudoers"
local PERMS_FILE   = "/etc/permissions.db"

-- ==========================================================
-- Cryptographic Salted Hashing Functions
-- ==========================================================
local _bit = bit32 or bit or {}
local function band(a, b)
    if _bit.band then return _bit.band(a, b) end
    local r, p = 0, 1
    a = a % 0x100000000
    b = b % 0x100000000
    while a > 0 and b > 0 do
        local ra, rb = a % 2, b % 2
        if ra == 1 and rb == 1 then r = r + p end
        a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
    end
    return r
end

local function bxor(a, b)
    if _bit.bxor then return _bit.bxor(a, b) end
    local r, p = 0, 1
    a = a % 0x100000000
    b = b % 0x100000000
    while a > 0 or b > 0 do
        local ra, rb = a % 2, b % 2
        if ra ~= rb then r = r + p end
        a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
    end
    return r
end

local function lshift(a, n)
    if _bit.lshift then return _bit.lshift(a, n) end
    if _bit.blshift then return _bit.blshift(a, n) end
    return math.floor(a * (2^n)) % 0x100000000
end

local function rshift(a, n)
    if _bit.rshift then return _bit.rshift(a, n) end
    if _bit.brshift then return _bit.brshift(a, n) end
    return math.floor(a / (2^n))
end

local function generateSalt()
    local chars = "0123456789abcdef"
    local s = ""
    for _ = 1, 8 do
        local r = math.random(1, #chars)
        s = s .. chars:sub(r, r)
    end
    return s
end

local function computeHash(password, salt)
    -- Multi-round bitwise hash with salt (safe 32-bit math, no float truncation)
    local h1 = 0x811c9dc5
    local h2 = 0x1505
    local text = salt .. ":" .. password

    for i = 1, #text do
        local b = text:byte(i)
        h1 = bxor(h1, b)
        h1 = band(lshift(h1, 5) + h1 + b, 0xFFFFFFFF)
        h2 = band(lshift(h2, 7) + bxor(h2, b), 0xFFFFFFFF)
    end

    -- Additional mixing rounds
    for _ = 1, 32 do
        h1 = band(bxor(h1, rshift(h2, 3)) + lshift(h2, 5), 0xFFFFFFFF)
        h2 = band(bxor(h2, lshift(h1, 5)) + rshift(h1, 3), 0xFFFFFFFF)
    end

    return string.format("%08x%08x", h1, h2)
end

function M.hashPassword(plainPassword)
    local salt = generateSalt()
    local digest = computeHash(plainPassword, salt)
    return "$hash$" .. salt .. "$" .. digest
end

function M.verifyPassword(username, candidatePassword)
    local u = M.getUser(username)
    if not u then return false end
    if not u.password or u.password == "" or u.password == "none" then
        return true
    end

    local stored = u.password
    -- Support both salted hash ($hash$<salt>$<digest>) and legacy plain text
    local salt, digest = stored:match("^%$hash%$([0-9a-fA-F]+)%$([0-9a-fA-F]+)$")
    if salt and digest then
        return computeHash(candidatePassword or "", salt) == digest
    else
        return stored == candidatePassword
    end
end

-- ==========================================================
-- User and Group Management
-- ==========================================================
function M.getUserHome(username)
    if username == "root" then
        return "/"
    else
        return "/home/" .. username
    end
end

function M.loadPasswd()
    local users = {}
    if fs.exists(PASSWD_FILE) then
        local h = fs.open(PASSWD_FILE, "r")
        if h then
            while true do
                local line = h.readLine()
                if not line then break end
                local username, pwd, uid, gid, gecos, home, shell_path = line:match("^([^:]+):([^:]*):([^:]+):([^:]+):([^:]*):([^:]+):([^:]*)$")
                if username then
                    users[username] = {
                        name = username,
                        password = pwd or "",
                        uid = tonumber(uid) or 1000,
                        gid = tonumber(gid) or 1000,
                        gecos = gecos or "",
                        home = home or ("/home/" .. username),
                        shell = (shell_path and shell_path ~= "") and shell_path or "/usr/bin/core/shell"
                    }
                end
            end
            h.close()
        end
    end

    -- Ensure root always exists
    if not users["root"] then
        users["root"] = {
            name = "root",
            password = "",
            uid = 0,
            gid = 0,
            gecos = "Superuser",
            home = "/",
            shell = "/usr/bin/core/shell"
        }
    end

    return users
end

function M.savePasswd(users)
    -- Ensure root is always saved
    if not users["root"] then
        users["root"] = {
            name = "root",
            password = "",
            uid = 0,
            gid = 0,
            gecos = "Superuser",
            home = "/",
            shell = "/usr/bin/core/shell"
        }
    end

    local h = fs.open(PASSWD_FILE, "w")
    if not h then return false end
    for _, u in pairs(users) do
        h.writeLine(string.format("%s:%s:%d:%d:%s:%s:%s",
            u.name, u.password or "", u.uid or 1000, u.gid or 1000, u.gecos or "", u.home or "/", u.shell or "/usr/bin/core/shell"))
    end
    h.close()
    return true
end

function M.getUser(username)
    local users = M.loadPasswd()
    return users[username]
end

function M.getUserByUid(uid)
    local users = M.loadPasswd()
    for _, u in pairs(users) do
        if u.uid == uid then return u end
    end
    return nil
end

function M.setPassword(username, newPlainPassword)
    local users = M.loadPasswd()
    if not users[username] then return false, "User not found" end
    if not newPlainPassword or newPlainPassword == "" or newPlainPassword == "none" then
        users[username].password = ""
    else
        users[username].password = M.hashPassword(newPlainPassword)
    end
    M.savePasswd(users)
    return true
end

function M.addUser(username, password, uid, gid, gecos, home, shell_path)
    if not username or username == "" or username:match("[^%w_%-]") then
        return false, "Invalid username: only alphanumeric and - _ allowed"
    end
    if username:lower() == "root" then
        return false, "Cannot create user 'root': reserved username"
    end
    local users = M.loadPasswd()
    if users[username] then
        return false, "User already exists"
    end

    if not uid then
        local maxUid = 999
        for _, u in pairs(users) do
            if u.uid >= 1000 and u.uid > maxUid then
                maxUid = u.uid
            end
        end
        uid = maxUid + 1
    end
    gid = gid or uid
    home = home or ("/home/" .. username)
    shell_path = shell_path or "/usr/bin/core/shell"

    local pwdField = ""
    if password and password ~= "" and password ~= "none" then
        pwdField = M.hashPassword(password)
    end

    users[username] = {
        name = username,
        password = pwdField,
        uid = uid,
        gid = gid,
        gecos = gecos or (username:sub(1, 1):upper() .. username:sub(2)),
        home = home,
        shell = shell_path
    }
    M.savePasswd(users)

    if fs.exists(GROUP_FILE) then
        local gh = fs.open(GROUP_FILE, "a")
        if gh then
            gh.writeLine(string.format("%s:x:%d:%s", username, gid, username))
            gh.close()
        end
    end

    return true, users[username]
end

function M.delUser(username, removeHome)
    if username == "root" then
        return false, "Cannot remove root user"
    end
    local users = M.loadPasswd()
    if not users[username] then
        return false, "User does not exist"
    end

    local uObj = users[username]
    users[username] = nil
    M.savePasswd(users)

    if fs.exists(GROUP_FILE) then
        local lines = {}
        local gh = fs.open(GROUP_FILE, "r")
        if gh then
            while true do
                local line = gh.readLine()
                if not line then break end
                local gName = line:match("^([^:]+):")
                if gName ~= username then
                    table.insert(lines, line)
                end
            end
            gh.close()
            local wh = fs.open(GROUP_FILE, "w")
            if wh then
                for _, l in ipairs(lines) do wh.writeLine(l) end
                wh.close()
            end
        end
    end

    if fs.exists(SUDOERS_FILE) then
        local lines = {}
        local sh = fs.open(SUDOERS_FILE, "r")
        if sh then
            while true do
                local line = sh.readLine()
                if not line then break end
                local uMatch = line:match("^([%w_%-]+)%s+")
                if uMatch ~= username then
                    table.insert(lines, line)
                end
            end
            sh.close()
            local wsh = fs.open(SUDOERS_FILE, "w")
            if wsh then
                for _, l in ipairs(lines) do wsh.writeLine(l) end
                wsh.close()
            end
        end
    end

    if removeHome and uObj.home and uObj.home ~= "/" and fs.exists(uObj.home) then
        fs.delete(uObj.home)
    end

    return true
end

-- ==========================================================
-- Permissions and Access Control
-- ==========================================================
function M.loadPerms()
    if not fs.exists(PERMS_FILE) then return {} end
    local h = fs.open(PERMS_FILE, "r")
    if not h then return {} end
    local content = h.readAll()
    h.close()
    local ok, data = pcall(textutils.unserialize, content)
    return (ok and type(data) == "table") and data or {}
end

function M.savePerms(perms)
    local h = fs.open(PERMS_FILE, "w")
    if not h then return false end
    h.write(textutils.serialize(perms))
    h.close()
    return true
end

local function cleanPath(p)
    return fs.combine(p, "")
end

function M.getFileAttr(path)
    local p = cleanPath(path)
    local perms = M.loadPerms()
    local entry = perms[p]
    if entry then
        return entry.owner or "root", entry.group or "root", entry.mode or "rwxr-xr-x"
    end

    local homeUser = p:match("^home/([^/]+)")
    if homeUser and homeUser ~= "root" then
        return homeUser, homeUser, "rwx------"
    end
    return "root", "root", "rwxr-xr-x"
end

function M.setFileAttr(path, owner, group, mode)
    local p = cleanPath(path)
    local perms = M.loadPerms()
    local entry = perms[p] or {}
    if owner then entry.owner = owner end
    if group then entry.group = group end
    if mode then entry.mode = mode end
    perms[p] = entry
    M.savePerms(perms)
end

function M.checkAccess(path, user, req)
    user = user or _G.CURRENT_USER or "root"
    if user == "root" then return true end

    local owner, group, mode = M.getFileAttr(path)
    local isOwner = (user == owner)
    local offset = isOwner and 1 or 7

    local permChar = ""
    if req == "r" then permChar = mode:sub(offset, offset)
    elseif req == "w" then permChar = mode:sub(offset + 1, offset + 1)
    elseif req == "x" then permChar = mode:sub(offset + 2, offset + 2)
    end

    return permChar == req
end

function M.checkSudoers(username)
    if username == "root" then return true end
    if not fs.exists(SUDOERS_FILE) then return false end
    local h = fs.open(SUDOERS_FILE, "r")
    if not h then return false end
    local allowed = false
    while true do
        local line = h.readLine()
        if not line then break end
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local u = line:match("^([%w_%-]+)")
            if u == username then
                allowed = true
                break
            end
        end
    end
    h.close()
    return allowed
end

function M.init()
    math.randomseed(os.epoch and os.epoch("utc") or os.time())

    if not fs.exists("/etc") then fs.makeDir("/etc") end
    if not fs.exists("/etc/conf") then fs.makeDir("/etc/conf") end
    if not fs.exists("/usr/bin") then fs.makeDir("/usr/bin") end
    if not fs.exists("/home") then fs.makeDir("/home") end

    if not fs.exists(PASSWD_FILE) then
        local users = {
            root = { name = "root", password = "", uid = 0, gid = 0, gecos = "Superuser", home = "/", shell = "/etc/sh" }
        }
        M.savePasswd(users)
    end

    if not fs.exists(GROUP_FILE) then
        local gh = fs.open(GROUP_FILE, "w")
        if gh then
            gh.writeLine("root:x:0:root")
            gh.close()
        end
    end

    if not fs.exists(SUDOERS_FILE) then
        local sh = fs.open(SUDOERS_FILE, "w")
        if sh then
            sh.writeLine("# /etc/sudoers - Host privilege configuration")
            sh.writeLine("root ALL=(ALL:ALL) ALL")
            sh.close()
        end
        M.setFileAttr("etc/sudoers", "root", "root", "r--------")
    end

    local users = M.loadPasswd()
    for _, u in pairs(users) do
        if u.name ~= "root" and not fs.exists(u.home) then
            fs.makeDir(u.home)
            local cDir = fs.combine(u.home, ".config")
            if not fs.exists(cDir) then fs.makeDir(cDir) end
        end
    end
end

_G.systemd = M
return M
