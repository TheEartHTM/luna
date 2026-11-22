-- Luna OS Stage-1 Bootstrap Installer (install.lua)
-- Lightweight loader: initializes VFS storage pool, then pulls and launches setup.lua

-- 1. Display Setup: Stays strictly on primary native screen
local nativeTerm = term.native and term.native() or term.current()
term.redirect(nativeTerm)

-- Blank external monitors
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

local isColor = term.isColor and term.isColor()
local function setColor(c) if isColor and c then term.setTextColor(c) end end
local function resetColor() if isColor then term.setTextColor(colors.white) end end

term.clear()
term.setCursorPos(1, 1)

setColor(colors.cyan)
print(":: Luna OS Bootstrap (Stage 1)")
resetColor()

-- 2. Pre-flight HTTP check
if not http then
    setColor(colors.red)
    print(":: [ERROR] HTTP API is disabled in ComputerCraft config!")
    resetColor()
    return
end

-- 3. Resolve Repository URL
local DEFAULT_GITHUB_REPO = "https://raw.githubusercontent.com/TheEartHTM/luna/main/repo"
local tArgs = { ... }
local REPO_URL = tArgs[1] or DEFAULT_GITHUB_REPO

-- 4. Download and Mount VFS Storage Pool
setColor(colors.lightBlue)
write(":: Mounting storage pool... ")
resetColor()

local rawFs = _G.ORIG_FS or fs
local bootTarget = "/boot.lua"

if rawFs.exists("/mem") and rawFs.isDir("/mem") then
    -- Clean previous failed install leftovers on root to keep space clean
    pcall(rawFs.delete, "/usr")
    pcall(rawFs.delete, "/etc")
    pcall(rawFs.delete, "/boot.lua")
    pcall(rawFs.delete, "/boot")

    if not rawFs.exists("/mem/boot") then pcall(rawFs.makeDir, "/mem/boot") end
    bootTarget = "/mem/boot/boot.lua"
end

-- Fetch boot.lua
local okB, resB = pcall(http.get, REPO_URL .. "/boot.lua")
if not okB or not resB then
    setColor(colors.red)
    print("[FAIL]\n:: Could not fetch boot driver from " .. REPO_URL)
    resetColor()
    return
end
local bootContent = resB.readAll()
resB.close()

local bH = rawFs.open(bootTarget, "w")
if not bH then
    setColor(colors.red)
    print("[FAIL]\n:: Cannot write boot driver to " .. bootTarget)
    resetColor()
    return
end
bH.write(bootContent)
bH.close()

-- Mount VFS driver (all subsequent file operations route to storage pool)
local okMount, errMount = pcall(dofile, bootTarget)
if not okMount then
    setColor(colors.red)
    print("[FAIL]\n:: VFS mount failed: " .. tostring(errMount))
    resetColor()
    return
end
setColor(colors.green)
print("[ OK ]")
resetColor()

-- 5. Fetch Stage-2 Interactive Setup into Storage Pool (/tmp/setup.lua)
setColor(colors.lightBlue)
write(":: Fetching setup installer... ")
resetColor()

if not fs.exists("/tmp") then pcall(fs.makeDir, "/tmp") end
local okS, resS = pcall(http.get, REPO_URL .. "/setup.lua")
if not okS or not resS then
    setColor(colors.red)
    print("[FAIL]\n:: Could not fetch setup.lua from " .. REPO_URL)
    resetColor()
    return
end
local setupContent = resS.readAll()
resS.close()

local sH = fs.open("/tmp/setup.lua", "w")
if not sH then
    setColor(colors.red)
    print("[FAIL]\n:: Cannot write /tmp/setup.lua")
    resetColor()
    return
end
sH.write(setupContent)
sH.close()

setColor(colors.green)
print("[ OK ]")
resetColor()

-- 6. Clean up Stage-1 bootstrap script from root/mem
local myProg = shell and shell.getRunningProgram() or "install.lua"
if rawFs.exists(myProg) then pcall(rawFs.delete, myProg) end
if rawFs.exists("/install.lua") then pcall(rawFs.delete, "/install.lua") end
if rawFs.exists("/mem/install.lua") then pcall(rawFs.delete, "/mem/install.lua") end
if rawFs.exists("install.lua") then pcall(rawFs.delete, "install.lua") end

-- 7. Execute Stage-2 Setup
shell.run("/tmp/setup.lua", REPO_URL)
