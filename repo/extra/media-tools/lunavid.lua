-- lunavid - CLI forwarding wrapper for video player
local args = { ... }
local shell = shell
if shell and shell.run then
    return shell.run("video", table.unpack(args))
else
    local fn = loadfile("/usr/bin/extra/video.lua") or loadfile("video.lua")
    if fn then
        return fn(table.unpack(args))
    end
end
