-- Luna Guided Installer
-- Designed to run directly in vanilla CraftOS on any CC computer

-- 1. Display Setup: Stays strictly on primary native screen
local nativeTerm = term.native and term.native() or term.current()
term.redirect(nativeTerm)

-- Blank external monitors to prevent residual text
if peripheral and peripheral.getNames then
    for _, name in ipairs(peripheral.getNames()) do
        local t = peripheral.getType(name)
        if t == "ceemonitor" or t == "monitor" then
            local m = peripheral.wrap(name)
            if m and m.clear then
                pcall(m.clear)
                pcall(m.setCursorBlink, false)
            end
        end
    end
end

local term = term
local colors = colors
local isColor = term.isColor and term.isColor()

local function setColor(c)
    if isColor and c then term.setTextColor(c) end
end

local function resetColor()
    if isColor then term.setTextColor(colors.white) end
end

local function printSys(tag, msg, c)
    local trimmed = tostring(tag):gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "OK" then
        setColor(colors.green)
        io.write("[  OK  ] ")
        resetColor()
        print(msg)
    else
        setColor(c or colors.cyan)
        io.write(trimmed .. " > ")
        resetColor()
        print(msg)
    end
end

local function prompt(text, default, mask)
    setColor(colors.yellow)
    io.write(":: ")
    resetColor()
    io.write(text .. ": ")
    local res = read(mask)
    if not res or res == "" then return default end
    return res
end

term.clear()
term.setCursorPos(1, 1)

local BANNER = [=[
================================================
  _                                ___    ____  
 | |      _   _   _ __     __ _   / _ \  / ___| 
 | |     | | | | | '_ \   / _` | | | | | \___ \ 
 | |___  | |_| | | | | | | (_| | | |_| |  ___) |
 |_____|  \__,_| |_| |_|  \__,_|  \___/  |____/ 
                   Installer                    
================================================]=]

setColor(colors.cyan)
print(BANNER)
resetColor()
print()

-- Check HTTP API
if not http then
    printSys("FAIL", "HTTP API is disabled in ComputerCraft config!", colors.red)
    print("Enable 'http.enabled = true' in computercraft.cfg or server config.")
    return
end

-- Pre-flight: Check CEE Memory Modules
local memCount = 0
for _, name in ipairs(fs.list("/")) do
    if name:match("^mem%d*$") and fs.isDir(name) then
        memCount = memCount + 1
    end
end

if memCount >= 2 then
    printSys(" OK ", string.format("Storage: %d CEE memory modules detected (RAID-0 pool ready)", memCount), colors.green)
elseif memCount == 1 then
    printSys(" OK ", "Storage: 1 CEE memory module (/mem) detected (Single module storage mode)", colors.green)
    printSys("TIP ", "Add secondary modules (mem2..memN) for RAID-0 striping across modules.", colors.yellow)
else
    local free = fs.getFreeSpace("/")
    if free < 450000 then
        printSys("FAIL", string.format("No CEE memory modules found and root storage has only %d KB free.", math.floor(free / 1024)), colors.red)
        print("Luna requires at least 1 CEE memory module (or 450 KB free root storage) to install.")
        print("Please insert a CEE memory module (/mem) into the computer module/rack.")
        return
    else
        printSys(" OK ", string.format("Storage: Standalone local storage (%d KB available)", math.floor(free / 1024)), colors.green)
    end
end

-- Resolve Repository URL
local DEFAULT_GITHUB_REPO = "https://raw.githubusercontent.com/TheEartHTM/luna/main/repo"
local tArgs = { ... }
local REPO_URL = (tArgs[1] and tArgs[1] ~= "") and tArgs[1] or DEFAULT_GITHUB_REPO

local compId = os.getComputerID and os.getComputerID() or 0
printSys("INFO", string.format("Computer ID: %d | Repository: %s", compId, REPO_URL), colors.lightBlue)
print()

-- 2. Configuration Prompts
local defaultHost = (compId == 0) and "luna" or ("luna" .. compId)
local hostname = prompt("Enter system hostname", defaultHost)

-- Root security
setColor(colors.cyan)
print(":: Root account security:")
resetColor()
print("   1) Set root password")
print("   2) Lock root account (disable root login, use sudo)")
local rootChoice = prompt("Select root option (1/2)", "2")

local rootPass = "!"
if rootChoice == "1" then
    while true do
        local p1 = prompt("Enter root password", "", "*")
        local p2 = prompt("Confirm root password", "", "*")
        if p1 == p2 and p1 ~= "" then
            rootPass = p1
            break
        else
            printSys("ERR ", "Passwords do not match or empty, try again.", colors.red)
        end
    end
else
    printSys("SEC ", "Root account direct login will be locked.", colors.green)
end
print()

-- User creation
local createUser = false
local userName = "earth"
local userPass = ""

while true do
    local askMsg = (rootPass == "!")
        and "Create an administrative user (sudoer)? (Y/n)"
        or "Create a regular user (member of wheel/sudo)? (Y/n)"
    local createUserPrompt = prompt(askMsg, "y")
    local wantUser = (createUserPrompt:lower():sub(1, 1) == "y")

    if not wantUser and rootPass == "!" then
        printSys("WARN", "Root account is locked! You MUST create a user to administer the system.", colors.yellow)
    else
        createUser = wantUser
        break
    end
end

if createUser then
    while true do
        userName = prompt("Username", "earth")
        if userName:lower() == "root" then
            printSys("ERR ", "Username 'root' is reserved for superuser. Choose another username.", colors.red)
        elseif not userName:match("^[%w_%-]+$") then
            printSys("ERR ", "Invalid username format: only letters, digits, '_' and '-' allowed.", colors.red)
        else
            break
        end
    end
    while true do
        local p1 = prompt("Password for " .. userName, "", "*")
        local p2 = prompt("Confirm password", "", "*")
        if p1 == p2 and p1 ~= "" then
            userPass = p1
            break
        else
            printSys("ERR ", "Passwords do not match or empty, try again.", colors.red)
        end
    end
end
print()

-- Detect CEE Signal Pins
local maxPins = 11
local hasFabric = false
if _G.cee then
    if _G.cee.getSignalCount then
        local okCnt, cnt = pcall(_G.cee.getSignalCount)
        if okCnt and type(cnt) == "number" and cnt > 0 then maxPins = cnt end
    end
    if _G.cee.fabricPeers then
        local okF, peers = pcall(_G.cee.fabricPeers)
        if okF and peers then hasFabric = true end
    end
end

local netPin = "1"
if maxPins == 1 and not hasFabric then
    printSys("INFO", "Only 1 CEE Signal Pin available on this hardware (pin 1).", colors.lightBlue)
    netPin = "1"
else
    local pinPromptStr = string.format("Default Network Pin (1..%d%s)", maxPins, hasFabric and ", or 'fabric'" or "")
    while true do
        local entered = prompt(pinPromptStr, "1")
        if hasFabric and entered:lower() == "fabric" then
            netPin = "fabric"
            break
        else
            local num = tonumber(entered)
            if num and num >= 1 and num <= maxPins then
                netPin = tostring(math.floor(num))
                break
            else
                printSys("ERR ", string.format("Invalid pin. Enter a number between 1 and %d.", maxPins), colors.red)
            end
        end
    end
end
print()

-- Packages to install (Base system + Userland)
local selectedPackages = {
    "systemd",
    "coreutils",
    "shadow",
    "sudo",
    "iproute2",
    "util-linux",
    "dust",
    "curl",
    "micro",
    "fastfetch"
}

-- Summary & Confirm
setColor(colors.cyan)
print("================ Installation Summary ================")
resetColor()
print(string.format("  Hostname    : %s", hostname))
print(string.format("  Root Login  : %s", rootPass == "!" and "LOCKED (sudo only)" or "PASSWORD PROTECTED"))
if createUser then
    print(string.format("  User        : %s (wheel, sudo)", userName))
end
print(string.format("  Network Pin : Signal %s", netPin))
print(string.format("  Base System : coreutils, systemd, shadow, sudo, iproute2, util-linux, dust"))
print(string.format("  Extra Tools : curl, micro, fastfetch"))
setColor(colors.cyan)
print("======================================================")
resetColor()

local confirm = prompt("Proceed with Luna deployment? (Y/n)", "y")
if confirm:lower():sub(1, 1) ~= "y" then
    printSys("ABRT", "Installation aborted by user.", colors.yellow)
    return
end

print()
printSys("INIT", "Beginning deployment to storage...", colors.cyan)

-- Helper to download and write file safely
local function downloadFile(url, dest)
    local ok, res = pcall(http.get, url)
    if not ok or not res then
        return false, "Failed to download " .. url
    end
    local content = res.readAll()
    res.close()
    local parent = fs.getDir(dest)
    if parent ~= "" and not fs.exists(parent) then
        pcall(fs.makeDir, parent)
    end
    local h = fs.open(dest, "w")
    if not h then return false, "Cannot write to " .. dest end
    local okW, errW = pcall(h.write, content)
    h.close()
    if not okW then
        return false, "Write error: " .. tostring(errW)
    end
    return true
end

-- Save reference to raw unwrapped filesystem
local rawFs = _G.ORIG_FS or {
    open = fs.open,
    exists = fs.exists,
    delete = fs.delete,
    makeDir = fs.makeDir,
    getFreeSpace = fs.getFreeSpace,
    list = fs.list,
    isDir = fs.isDir
}

-- Reclaim space on local root if previous install left leftovers
if rawFs.exists("/mem") then
    pcall(rawFs.delete, "/usr")
    pcall(rawFs.delete, "/etc")
    pcall(rawFs.delete, "/boot.lua")
    pcall(rawFs.delete, "/boot")
end

-- Download boot driver (boot.lua)
printSys("DOWN", "Installing VFS boot driver (boot.lua)...", colors.lightBlue)
local bootContent = nil
do
    local ok, res = pcall(http.get, REPO_URL .. "/boot.lua")
    if ok and res then
        bootContent = res.readAll()
        res.close()
    else
        printSys("FAIL", "Failed to download boot.lua from repository!", colors.red)
        return
    end
end

-- Download kernel (startup.lua)
printSys("DOWN", "Installing Luna kernel (startup.lua)...", colors.lightBlue)
local kernelContent = nil
do
    local ok, res = pcall(http.get, REPO_URL .. "/startup.lua")
    if ok and res then
        kernelContent = res.readAll()
        res.close()
    else
        printSys("FAIL", "Failed to download startup.lua from repository!", colors.red)
        return
    end
end

-- Write low-level bootloader and kernel directly to physical storage (rawFs)
if rawFs.exists("/mem") and rawFs.isDir("/mem") then
    -- Ensure /mem/boot directory exists
    if not rawFs.exists("/mem/boot") then pcall(rawFs.makeDir, "/mem/boot") end

    -- 1. Write boot driver to /mem/boot/boot.lua
    local bH = rawFs.open("/mem/boot/boot.lua", "w")
    if bH then bH.write(bootContent); bH.close() end

    -- 2. Write kernel to /mem/boot/startup.lua and /mem/startup.lua
    local kH = rawFs.open("/mem/boot/startup.lua", "w")
    if kH then kH.write(kernelContent); kH.close() end
    local kH2 = rawFs.open("/mem/startup.lua", "w")
    if kH2 then kH2.write(kernelContent); kH2.close() end

    -- 3. Write physical boot forwarder on /startup.lua (waits for CEE rack bus mounting)
    local bootForwarder = [[-- Luna OS Bootloader
if term and term.clear then
    term.clear()
    term.setCursorPos(1, 1)
end

local found = false
for i = 1, 40 do
    if fs.exists("mem/boot/startup.lua") then
        shell.run("mem/boot/startup.lua")
        found = true
        break
    elseif fs.exists("mem/startup.lua") then
        shell.run("mem/startup.lua")
        found = true
        break
    end
    sleep(0.05)
end
]]
    pcall(rawFs.delete, "/startup.lua")
    pcall(rawFs.delete, "/startup")
    pcall(rawFs.delete, "/autostart.lua")
    pcall(rawFs.delete, "/autostart")
    local fH = rawFs.open("/startup.lua", "w")
    if fH then
        fH.write(bootForwarder)
        fH.close()
    end

    -- 4. NOW activate the VFS driver so all packages and /etc route to storage pool
    printSys("INIT", "Activating pooled storage VFS driver...", colors.cyan)
    local okBoot, errBoot = pcall(dofile, "/mem/boot/boot.lua")
    if not okBoot then
        printSys("WARN", "Could not activate VFS driver: " .. tostring(errBoot), colors.yellow)
    else
        printSys(" OK ", "Storage pool mounted successfully!", colors.green)
    end
else
    -- Standalone CC computer mode
    local bH = rawFs.open("/boot.lua", "w")
    if bH then bH.write(bootContent); bH.close() end
    if not rawFs.exists("/boot") then pcall(rawFs.makeDir, "/boot") end
    local bH2 = rawFs.open("/boot/boot.lua", "w")
    if bH2 then bH2.write(bootContent); bH2.close() end

    local kH = rawFs.open("/startup.lua", "w")
    if kH then kH.write(kernelContent); kH.close() end
    local kH2 = rawFs.open("/startup", "w")
    if kH2 then kH2.write(kernelContent); kH2.close() end

    printSys("INIT", "Activating local storage VFS driver...", colors.cyan)
    pcall(dofile, "/boot.lua")
end

-- 3. Base directory structure
local dirs = {
    "/etc", "/etc/conf", "/usr/bin/core", "/usr/bin/extra", "/usr/bin/server",
    "/home", "/dev", "/proc", "/boot", "/var", "/tmp"
}
if createUser then
    table.insert(dirs, "/home/" .. userName)
end
for _, d in ipairs(dirs) do
    if not fs.exists(d) then fs.makeDir(d) end
end

-- 4. Security & User tables
printSys("CONF", "Generating user accounts and security policies...", colors.lightBlue)

-- /etc/passwd
local passwdLines = {}
table.insert(passwdLines, string.format("root:%s:0:0:Superuser:/:/usr/bin/core/shell", rootPass))
if createUser then
    table.insert(passwdLines, string.format("%s:%s:1000:1000:%s:/home/%s:/usr/bin/core/shell",
        userName, userPass, userName, userName))
end
local pwH = fs.open("/etc/passwd", "w")
pwH.write(table.concat(passwdLines, "\n") .. "\n")
pwH.close()

-- /etc/group
local groupLines = {
    "root:x:0:",
    "wheel:x:10:" .. (createUser and userName or ""),
    "sudo:x:27:" .. (createUser and userName or "")
}
if createUser then
    table.insert(groupLines, string.format("%s:x:1000:", userName))
end
local grpH = fs.open("/etc/group", "w")
grpH.write(table.concat(groupLines, "\n") .. "\n")
grpH.close()

-- /etc/sudoers
local sudH = fs.open("/etc/sudoers", "w")
sudH.write("root ALL=(ALL:ALL) ALL\n%wheel ALL=(ALL:ALL) ALL\n%sudo ALL=(ALL:ALL) ALL\n")
sudH.close()

-- /etc/hostname
local hnH = fs.open("/etc/hostname", "w")
hnH.write(hostname .. "\n")
hnH.close()

-- Generate Deterministic Realistic Hardware MAC based on Computer ID
local function generateMac(id)
    id = id or 0
    local h = (id * 1664525 + 1013904223) % 4294967296
    local function nextByte()
        h = (h * 1664525 + 1013904223) % 4294967296
        return math.floor(h / 16777216) % 256
    end

    local b1 = bit32 and bit32.bor(bit32.band(nextByte(), 0xFE), 0x02) or (math.floor(nextByte() / 4) * 4 + 2)
    local b2 = nextByte()
    local b3 = nextByte()
    local b4 = nextByte()
    local b5 = nextByte()
    local b6 = nextByte()

    return string.format("%02x:%02x:%02x:%02x:%02x:%02x", b1, b2, b3, b4, b5, b6)
end

local mac = generateMac(compId)

-- /etc/conf/network.conf
local netConf = {
    hostname = hostname,
    mac = mac,
    ip = nil, -- Unconfigured until DHCP
    pin = (netPin == "fabric") and "fabric" or (tonumber(netPin) or 1)
}
local netH = fs.open("/etc/conf/network.conf", "w")
netH.write(textutils.serialize(netConf))
netH.close()

-- Master System Configuration: /etc/conf/system.lua (Hyprland Lua Style)
local sysLuaContent = string.format([[-- /etc/conf/system.lua
-- Luna OS System Configuration (Hyprland Lua Style)

-- 1. Modular Config Sourcing
-- source("/etc/conf/monitors.lua")

-- 2. Display & Multi-Monitor Configuration
-- All monitors mirror console output with individual text scaling.
-- Any specific monitor can be targeted directly via shell redirection: cmd > /dev/mon1
monitors = {
    -- Example multi-monitor setup (supports any number of monitors):
    -- { name = "main",  dev = "/dev/terminal", scale = 1.0 },
    -- { name = "left",  dev = "/dev/mon1",     scale = 0.5 },
    -- { name = "right", dev = "/dev/mon2",     scale = 0.5 },
}

-- 3. Autostart Applications (exec_once)
exec_once = {}

-- 4. Keybindings (bind)
bind = {
    -- Format: { MODIFIER, KEY, COMMAND }
    -- { "CTRL", "ALT", "1", "chvt 1" },
    -- { "CTRL", "ALT", "2", "chvt 2" },
}

-- 5. Package Manager Configuration
dust = {
    repo_url = %q,
    etc_compat = false,
}

-- 6. Background Services
services = {}
]], REPO_URL)

local sysH = fs.open("/etc/conf/system.lua", "w")
if sysH then
    sysH.write(sysLuaContent)
    sysH.close()
end

-- Backwards compatibility mirror files

local srvH = fs.open("/etc/conf/services.db", "w")
if srvH then srvH.write(textutils.serialize({})); srvH.close() end

-- Install Test Suite to /tests/test_all_apis.sh
local testUrl = REPO_URL .. "/tests/test_all_apis.sh"
local okT, resT = pcall(http.get, testUrl)
if okT and resT then
    fs.makeDir("/tests")
    local tH = fs.open("/tests/test_all_apis.sh", "w")
    if tH then
        tH.write(resT.readAll())
        tH.close()
    end
    resT.close()
end

-- 5. Download and Install Packages
local installedDB = {}
local syncDB = {}

local function fetchRepo(repoName)
    local dbUrl = REPO_URL .. "/" .. repoName .. "/" .. repoName .. ".db"
    local okD, dbRes = pcall(http.get, dbUrl)
    if okD and dbRes then
        local dbContent = dbRes.readAll()
        dbRes.close()
        local okT, rData = pcall(textutils.unserialize, dbContent)
        if okT and type(rData) == "table" then
            for k, v in pairs(rData) do
                syncDB[k] = v
            end
            return true
        end
    end
    return false
end

printSys("SYNC", "Synchronizing package databases...", colors.yellow)
fetchRepo("core")
fetchRepo("extra")

local function installPackage(pkgName)
    local pkg = syncDB[pkgName]
    if not pkg then
        printSys("FAIL", "Package not found in repositories: " .. pkgName, colors.red)
        return false
    end
    printSys("PKG ", string.format("Installing %s (%s)...", pkgName, pkg.version or "1.0"), colors.yellow)

    local repo = pkg.repo or "core"
    local files = pkg.files or {}
    local pkgDir = pkg.package_dir or pkgName
    for _, fPath in ipairs(files) do
        local fn = fs.getName(fPath)
        local fileUrl = REPO_URL .. "/" .. repo .. "/" .. pkgDir .. "/" .. fn
        local okF, errF = downloadFile(fileUrl, fPath)
        if not okF then
            printSys("WARN", "Failed to fetch file: " .. fn .. " (" .. tostring(errF) .. ")", colors.yellow)
        end
    end

    -- Write .PKGINFO and detect services
    local pkgInfoDir = fs.combine("/etc/conf/packages", pkgName)
    if not fs.exists(pkgInfoDir) then fs.makeDir(pkgInfoDir) end
    local infoPath = fs.combine(pkgInfoDir, ".PKGINFO")

    local pkgInfoContent = nil
    local pInfoUrl = REPO_URL .. "/" .. repo .. "/" .. pkgDir .. "/.PKGINFO"
    local okPi, piRes = pcall(http.get, pInfoUrl)
    if okPi and piRes then
        pkgInfoContent = piRes.readAll()
        piRes.close()
        local ih = fs.open(infoPath, "w")
        if ih then ih.write(pkgInfoContent); ih.close() end
    else
        local ih = fs.open(infoPath, "w")
        if ih then
            ih.write("# Generated for Luna OS\n")
            ih.write("pkgname = " .. pkgName .. "\n")
            ih.write("pkgver = " .. (pkg.version or "1.0.0-1") .. "\n")
            ih.write("pkgdesc = " .. (pkg.description or "") .. "\n")
            ih.write("repo = " .. repo .. "\n")
            if pkg.path then ih.write("path = " .. pkg.path .. "\n") end
            if pkg.groups then ih.write("group = " .. pkg.groups .. "\n") end
            if pkg.licenses then ih.write("license = " .. pkg.licenses .. "\n") end
            if pkg.packager then ih.write("packager = " .. pkg.packager .. "\n") end
            if pkg.url then ih.write("url = " .. pkg.url .. "\n") end
            if pkg.build_date then ih.write("builddate = " .. pkg.build_date .. "\n") end
            if pkg.provides then ih.write("provides = " .. pkg.provides .. "\n") end
            if pkg.deps and #pkg.deps > 0 then
                ih.write("deps = " .. table.concat(pkg.deps, ", ") .. "\n")
            end
            ih.close()
        end
    end

    if pkgInfoContent then
        local sName = pkgInfoContent:match("service_name%s*=%s*([%w_%-]+)")
        local sScript = pkgInfoContent:match("service_script%s*=%s*([^\r\n]+)")
        local sOrder = pkgInfoContent:match("service_order%s*=%s*(%d+)")
        local sDesc = pkgInfoContent:match("service_desc%s*=%s*([^\r\n]+)")
        if sName and sScript then
            sScript = sScript:match("^%s*(.-)%s*$")
            sDesc = sDesc and sDesc:match("^%s*(.-)%s*$") or sName
            systemConf.services[sName] = {
                enabled = false,
                order = tonumber(sOrder) or 50,
                desc = sDesc,
                script = sScript,
                active = "inactive",
                sub = "dead",
                pkg = pkgName
            }
            local sH = fs.open("/etc/conf/system.conf", "w")
            if sH then sH.write(textutils.serialize(systemConf)); sH.close() end
            local sdbH = fs.open("/etc/conf/services.db", "w")
            if sdbH then sdbH.write(textutils.serialize(systemConf.services)); sdbH.close() end
            printSys("SVC ", string.format("Registered service unit '%s.service' (disabled)", sName), colors.purple or colors.magenta)
        end
    end

    installedDB[pkgName] = pkg
    printSys(" OK ", string.format("Installed %s (%s)", pkgName, pkg.version or "1.0"), colors.green)
    return true
end

-- Install all selected packages
for _, pkg in ipairs(selectedPackages) do
    installPackage(pkg)
end

-- Write installed dust.db and remote sync.db
local idbH = fs.open("/etc/conf/dust.db", "w")
if idbH then
    idbH.write(textutils.serialize(installedDB))
    idbH.close()
end
local sdbH = fs.open("/etc/conf/sync.db", "w")
if sdbH then
    sdbH.write(textutils.serialize(syncDB))
    sdbH.close()
end

print()
printSys(" OK ", "Luna installation completed successfully!", colors.green)
printSys("MAC ", "Hardware MAC address: " .. mac, colors.lightBlue)
printSys("NET ", "Network: unconfigured (run 'dhcpcd' to obtain IP)", colors.lightBlue)
print()

-- Self-deletion of installer files
local myProg = shell and shell.getRunningProgram() or "setup.lua"
if fs.exists(myProg) then pcall(fs.delete, myProg) end
if fs.exists("/tmp/setup.lua") then pcall(fs.delete, "/tmp/setup.lua") end
if fs.exists("setup.lua") then pcall(fs.delete, "setup.lua") end
if fs.exists("/setup.lua") then pcall(fs.delete, "/setup.lua") end
if fs.exists("/mem/setup.lua") then pcall(fs.delete, "/mem/setup.lua") end
if fs.exists("/install.lua") then pcall(fs.delete, "/install.lua") end
if fs.exists("/mem/install.lua") then pcall(fs.delete, "/mem/install.lua") end
if fs.exists("install.lua") then pcall(fs.delete, "install.lua") end

local rebootChoice = prompt("Reboot into Luna now? (Y/n)", "y")
if rebootChoice:lower():sub(1, 1) == "y" then
    setColor(colors.cyan)
    print(":: Rebooting system...")
    resetColor()
    sleep(1)
    os.reboot()
end
