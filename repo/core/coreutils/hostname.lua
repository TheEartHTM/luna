-- hostname - Show or set system hostname
local args = { ... }
if #args == 0 then
    print(_G.SYSTEM_NAME or "luna")
else
    local newHost = args[1]
    _G.SYSTEM_NAME = newHost
    local h = fs.open("/etc/hostname", "w")
    if h then
        h.write(newHost .. "\n")
        h.close()
    end
end
