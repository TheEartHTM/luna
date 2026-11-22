-- poweroff - Gracefully power off the system (systemd / Luna Kernel Syscall)
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

-- Permission check via kernel
local curUser = (_G.kernel and _G.kernel.syscall and _G.kernel.syscall("getuser")) or _G.CURRENT_USER or "root"
if curUser ~= "root" then
    if not (_G.systemd and _G.systemd.checkSudoers and _G.systemd.checkSudoers(curUser)) then
        print("poweroff: Must be root.")
        return
    end
end

print("System is going down for poweroff NOW!")
sleep(0.3)

-- 1. Stop User Services & Shells
logOk("Stopped target Multi-User System.")
logOk("Stopped OpenSSH Server Daemon (sshd.service).")

-- 2. Kernel Storage Buffer Sync
if _G.kernel and _G.kernel.syscall then
    _G.kernel.syscall("sync")
elseif _G.kernel and _G.kernel.sync then
    _G.kernel.sync()
end
logOk("Synchronized filesystem buffers to storage.")

-- 3. Unmount Filesystems
logOk("Unmounted procfs (/proc).")
logOk("Unmounted devfs (/dev).")
logOk("Unmounted /dev/raid0 from /.")
logOk("Reached target System Power Off.")

sleep(0.5)
if _G.kernel and _G.kernel.syscall then
    local ok, err = _G.kernel.syscall("poweroff")
    if not ok and err then print("poweroff: " .. tostring(err)) end
else
    os.shutdown()
end
