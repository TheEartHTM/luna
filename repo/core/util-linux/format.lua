-- format.lua - Completely format and wipe Luna, returning to vanilla CraftOS
local term = term
local colors = colors
local isColor = term.isColor and term.isColor()

local function setColor(c)
    if isColor and c then term.setTextColor(c) end
end

local function resetColor()
    if isColor then term.setTextColor(colors.white) end
end

local curUser = _G.CURRENT_USER or "root"
local systemd = _G.systemd or (fs.exists("/etc/systemd.lua") and dofile("/etc/systemd.lua"))

-- 1. Sudo / Permission verification
local function isSudoer(user)
    if user == "root" then return true end
    if systemd and systemd.checkSudoers then return systemd.checkSudoers(user) end
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
            if u == user or u == "%wheel" or u == "%sudo" then
                allowed = true
                break
            end
        end
    end
    h.close()
    return allowed
end

if not isSudoer(curUser) then
    printError("format: " .. curUser .. " is not in the sudoers file. Permission denied.")
    return
end

local function isAffirmative(ans)
    if not ans then return false end
    local a = ans:match("^%s*(.-)%s*$"):lower()
    return a == "yes" or a == "y"
end

-- 2. Warning message
setColor(colors.red)
print("==================================================================")
print("           CRITICAL WARNING: SYSTEM FORMAT REQUESTED              ")
print("==================================================================")
resetColor()
print(":: This operation will COMPLETELY DESTROY and REMOVE Luna:")
print("   - All files, packages, user accounts, and home directories.")
print("   - All RAID-0 memory pool storage modules (mem, mem2..memN).")
print("   - Kernel and bootloaders (startup.lua, boot.lua).")
print("   - The computer will be returned to clean vanilla CraftOS.")
print()

if curUser == "root" then
    -- ROOT FLOW: Two simple confirmations (yes/no)
    setColor(colors.yellow)
    io.write("Are you sure you want to format this system? (yes/no): ")
    resetColor()
    local ans1 = read()
    if not isAffirmative(ans1) then
        print("Format cancelled.")
        return
    end

    print()
    setColor(colors.red)
    io.write("All system data and memory pool will be lost. Are you absolutely sure? (yes/no): ")
    resetColor()
    local ans2 = read()
    if not isAffirmative(ans2) then
        print("Format aborted.")
        return
    end
else
    -- NON-ROOT (SUDO) FLOW: Two password confirmations
    local userToVerify = curUser
    write("[sudo] password for " .. userToVerify .. ": ")
    local p1 = read("*")
    if not (systemd and systemd.verifyPassword and systemd.verifyPassword(userToVerify, p1)) then
        printError("format: Authentication failure.")
        return
    end

    print()
    setColor(colors.red)
    write("Re-enter password to authorize irreversible format: ")
    resetColor()
    local p2 = read("*")
    if not (systemd and systemd.verifyPassword and systemd.verifyPassword(userToVerify, p2)) then
        printError("format: Authentication failure. Format aborted.")
        return
    end
end

print()
setColor(colors.red)
print(":: AUTHORIZATION ACCEPTED. WIPING SYSTEM...")
resetColor()
sleep(1)

-- 7. Execute format
local orig = _G.ORIG_FS or fs

-- Step A: Wipe secondary memory modules
if orig.list then
    for _, name in ipairs(orig.list("/")) do
        if name:match("^mem%d*$") and orig.isDir(name) then
            print(string.format("  [ WIPING ] Memory module %s...", name))
            for _, item in ipairs(orig.list(name)) do
                pcall(orig.delete, fs.combine(name, item))
            end
        end
    end
end

-- Step B: Wipe root filesystem
local rootItems = orig.list and orig.list("/") or fs.list("/")
for _, item in ipairs(rootItems) do
    if item ~= "rom" then
        print(string.format("  [ DELETING ] /%s...", item))
        pcall(orig.delete, item)
        pcall(fs.delete, "/" .. item)
    end
end

print()
setColor(colors.green)
print("[  OK  ] Luna has been completely formatted.")
print("[  OK  ] Rebooting into CraftOS in 2 seconds...")
resetColor()
sleep(2)
os.reboot()
