-- ps - Report a snapshot of the current processes
local term = term
local colors = colors
local isColor = term.isColor and term.isColor()

local args = { ... }
local showAll = false
for _, a in ipairs(args) do
    if a:find("a") or a:find("e") or a:find("A") or a == "-ef" or a == "-aux" or a == "aux" then
        showAll = true
    end
end

local curUser = (_G.kernel and _G.kernel.syscall and _G.kernel.syscall("getuser")) or _G.CURRENT_USER or "root"
local procs = (_G.kernel and _G.kernel.syscall and _G.kernel.syscall("proclist"))
    or (_G.kernel and _G.kernel.proc and _G.kernel.proc.list and _G.kernel.proc.list())

if not procs then
    print("ps: kernel process table unavailable")
    return
end

-- Header (Real Unix process attributes: User, PID, PPID, State, Elapsed Time, Command)
local header = string.format("%-8s %5s %5s %-5s %6s %s",
    "USER", "PID", "PPID", "STAT", "TIME", "COMMAND")

if isColor then
    term.setTextColor(colors.lightBlue or colors.cyan)
end
print(header)
if isColor then
    term.setTextColor(colors.white)
end

local curTime = (_G.kernel and _G.kernel.syscall and _G.kernel.syscall("uptime")) or os.clock()
for _, p in ipairs(procs) do
    if showAll or p.user == curUser or curUser == "root" then
        local elapsed = math.max(0, math.floor(curTime - (p.startTime or 0)))
        local mins = math.floor(elapsed / 60)
        local secs = elapsed % 60
        local timeStr = string.format("%d:%02d", mins, secs)

        local line = string.format("%-8s %5d %5d %-5s %6s %s",
            p.user or "root",
            p.pid,
            p.ppid or 0,
            p.state or "S",
            timeStr,
            p.cmd or p.name or "unknown"
        )
        print(line)
    end
end
