-- /usr/bin/core/ttymgr.lua - CLI utility for TTY, Workspace & Multi-monitor management
local args = { ... }

local ttyLib = nil
local okL, mod = pcall(require, "tty")
if okL and mod then
    ttyLib = mod
else
    local ok2, mod2 = pcall(dofile, "/usr/lib/tty.lua")
    if ok2 and mod2 then ttyLib = mod2 end
end

local isColor = term.isColor and term.isColor()
local function printCyan(text)
    if isColor then term.setTextColor(colors.cyan) end
    print(text)
    if isColor then term.setTextColor(colors.white) end
end

local function printErr(text)
    if isColor then term.setTextColor(colors.red) end
    print("ttymgr: " .. text)
    if isColor then term.setTextColor(colors.white) end
end

local cmd = args[1]

if not cmd or cmd == "list" or cmd == "status" then
    printCyan(":: Luna OS Workspaces & TTY Subsystem")
    local list = (ttyLib and ttyLib.list and ttyLib.list()) or {}
    if #list == 0 then
        table.insert(list, { name = "tty1", active = true, resolution = { width = 51, height = 19 } })
    end

    print(string.format("%-8s %-8s %-12s %s", "TTY", "ACTIVE", "RESOLUTION", "ATTACHED MONITORS"))
    print(string.rep("-", 60))
    for _, item in ipairs(list) do
        local actStr = item.active and "[ * ]" or "[   ]"
        local resStr = string.format("%dx%d", item.resolution.width, item.resolution.height)
        local monStr = (item.monitors and #item.monitors > 0) and table.concat(item.monitors, ", ") or "/dev/terminal"
        print(string.format("%-8s %-8s %-12s %s", item.name, actStr, resStr, monStr))
    end
    print()
    print("Commands:")
    print("  ttymgr run <tty> <prog> [args...]    execute program on target TTY")
    print("  ttymgr spawn <tty> <prog> [args...]  launch daemon process on target TTY")
    print("  ttymgr write <tty> <text>            send text message to target TTY")
    print("  ttymgr clear <tty>                   clear screen of target TTY")
    print("  ttymgr switch <tty>                  switch active focus to target TTY")
    return
end

if cmd == "-h" or cmd == "--help" or cmd == "help" then
    print("Usage: ttymgr <command> [args...]")
    print("Commands:")
    print("  list, status                         show all TTYs and attached monitors")
    print("  run <tty> <program> [args...]        run program on specified TTY")
    print("  spawn <tty> <program> [args...]      spawn background process on TTY")
    print("  write <tty> <text>                   output text directly to TTY")
    print("  clear <tty>                          clear TTY display")
    print("  switch <tty>                         switch local active TTY focus")
    return
end

local targetTTY = args[2]
if not targetTTY then
    printErr("missing target TTY (e.g. tty1, tty2)")
    return
end

if cmd == "write" then
    local text = table.concat(args, " ", 3)
    if #text == 0 then
        printErr("missing text to write")
        return
    end
    local ok, err = ttyLib.write(targetTTY, text .. "\n")
    if not ok then
        printErr(tostring(err or "failed to write to TTY"))
    end
    return
end

if cmd == "clear" then
    local ok, err = ttyLib.clear(targetTTY)
    if ok then
        print("Screen cleared on " .. targetTTY)
    else
        printErr(tostring(err or "failed to clear TTY"))
    end
    return
end

if cmd == "switch" then
    local ok, err = ttyLib.switch(targetTTY)
    if ok then
        printCyan("Active workspace switched to " .. targetTTY)
    else
        printErr(tostring(err or "failed to switch TTY"))
    end
    return
end

if cmd == "run" then
    local prog = args[3]
    if not prog then
        printErr("missing program name to run")
        return
    end
    local progArgs = {}
    for i = 4, #args do table.insert(progArgs, args[i]) end
    local ok, err = ttyLib.run(targetTTY, prog, table.unpack(progArgs))
    if not ok then
        printErr("execution error on " .. targetTTY .. ": " .. tostring(err))
    end
    return
end

if cmd == "spawn" then
    local prog = args[3]
    if not prog then
        printErr("missing program name to spawn")
        return
    end
    local progArgs = {}
    for i = 4, #args do table.insert(progArgs, args[i]) end
    local pid = ttyLib.spawn(targetTTY, prog, table.unpack(progArgs))
    if pid then
        printCyan(string.format("Spawned %s on %s (PID: %s)", prog, targetTTY, tostring(pid)))
    else
        printErr("failed to spawn process on " .. targetTTY)
    end
    return
end

printErr("unknown command '" .. cmd .. "'. Run 'ttymgr help' for usage.")
