-- focus.lua - Switch keyboard input focus to a specific monitor or TTY
local args = { ... }
local target = args[1]

if not target or target == "-h" or target == "--help" then
    print("usage: focus <dev|name|num>")
    print("       focus -l | --list")
    print("examples:")
    print("  focus /dev/mon0      focus first/main monitor")
    print("  focus /dev/mon1      focus second/left monitor")
    print("  focus left           focus monitor named 'left'")
    print("  focus 1              focus monitor 1")
    return
end

if target == "-l" or target == "--list" then
    local cur = _G.getFocus and _G.getFocus() or (_G.kernel and _G.kernel.getTTY and _G.kernel.getTTY()) or "tty1"
    local list = _G._MONITOR_LIST or {}
    print("Connected monitors:")
    if #list == 0 then
        print(string.format("  * %s (system)", cur))
    else
        for _, m in ipairs(list) do
            local isCur = (m.tty == cur)
            local marker = isCur and "* " or "  "
            print(string.format("%s%s (%s) -> %s", marker, m.dev, m.name, m.tty))
        end
    end
    return
end

if _G.setFocus then
    local ok, res = _G.setFocus(target)
    if ok then
        print("Focus switched to " .. tostring(target) .. " (" .. tostring(res) .. ")")
    else
        printError("focus: " .. tostring(res))
    end
elseif _G.kernel and _G.kernel.setTTY then
    local ok, err = _G.kernel.setTTY(target)
    if ok == 0 or ok == true then
        print("Focus switched to " .. tostring(target))
    else
        printError("focus: " .. tostring(err))
    end
else
    printError("focus: Display manager not active")
end
