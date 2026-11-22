-- chvt.lua - Switch active terminal / monitor focus
local args = { ... }
local target = args[1]

if not target or target == "-h" or target == "--help" then
    local cur = _G.getFocus and _G.getFocus() or (_G.kernel and _G.kernel.getTTY and _G.kernel.getTTY()) or "tty1"
    print("usage: chvt <number|dev|name>")
    print("current: " .. tostring(cur))
    return
end

if _G.setFocus then
    local ok, res = _G.setFocus(target)
    if ok then
        print("Switched foreground terminal to " .. tostring(target) .. " (" .. tostring(res) .. ")")
    else
        printError("chvt: " .. tostring(res))
    end
elseif _G.kernel and _G.kernel.setTTY then
    local targetTTY = tonumber(target) and ("tty" .. target) or target
    local ok, err = _G.kernel.setTTY(targetTTY)
    if ok == 0 or ok == true then
        print("Switched foreground terminal to " .. targetTTY)
    else
        printError("chvt: " .. tostring(err))
    end
else
    printError("chvt: Display manager not active")
end
