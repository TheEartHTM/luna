-- kill - Terminate a process by PID via kernel.syscall
local args = { ... }
if #args == 0 or args[1] == "-h" or args[1] == "--help" then
    print("Usage: kill [-s signal | -signal] pid...")
    return
end

local sig = 15 -- SIGTERM
local pids = {}
for _, a in ipairs(args) do
    if a:match("^%-(%d+)$") then
        sig = tonumber(a:match("^%-(%d+)$"))
    elseif tonumber(a) then
        table.insert(pids, tonumber(a))
    end
end

if #pids == 0 then
    print("kill: no process ID specified")
    return
end

for _, pid in ipairs(pids) do
    if _G.kernel and _G.kernel.syscall then
        local res, err, errno = _G.kernel.syscall("kill", pid, sig)
        if not res then
            print(string.format("kill: (%d) - %s", pid, err or "failed"))
        end
    elseif _G.kernel and _G.kernel.proc and _G.kernel.proc.kill then
        local ok, err = _G.kernel.proc.kill(pid, sig)
        if not ok then
            print(string.format("kill: (%d) - %s", pid, err or "failed"))
        end
    else
        print("kill: kernel process subsystem not available")
    end
end
