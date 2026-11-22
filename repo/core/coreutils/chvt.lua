-- chvt.lua - Switch virtual terminal (TTY) for Luna OS
local args = { ... }
local num = tonumber(args[1])
if not num then
    local cur = _G.kernel and _G.kernel.getTTY and _G.kernel.getTTY() or "tty1"
    print("usage: chvt <number>")
    print("current: " .. tostring(cur))
    return
end

local targetTTY = "tty" .. num
if _G.kernel and _G.kernel.setTTY then
    local ok, err = _G.kernel.setTTY(targetTTY)
    if ok == 0 or ok == true then
        print("Switched foreground virtual terminal to " .. targetTTY)
    else
        print("Failed to switch: " .. tostring(err))
    end
else
    print("Kernel does not support virtual terminal switching.")
end
