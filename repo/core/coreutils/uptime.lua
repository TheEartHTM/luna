-- uptime - Tell how long the system has been running
local sec = math.floor(os.clock())
local m = math.floor(sec / 60)
local s = sec % 60
local h = math.floor(m / 60)
m = m % 60

local timeStr = textutils and textutils.formatTime and textutils.formatTime(os.time(), true) or "12:00"
if h > 0 then
    print(string.format(" %s up %d hours, %d min, load average: 0.05, 0.02, 0.01", timeStr, h, m))
else
    print(string.format(" %s up %d min, load average: 0.05, 0.02, 0.01", timeStr, m))
end
