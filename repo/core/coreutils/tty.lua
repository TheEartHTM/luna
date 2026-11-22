-- tty.lua - Print current virtual terminal name for Luna OS
local t = (_G.kernel and _G.kernel.getTTY and _G.kernel.getTTY()) or "tty1"
print("/dev/" .. tostring(t))
