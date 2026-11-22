-- mv - Move or rename files and directories
local args = { ... }
local src, dst = args[1], args[2]

if not src or not dst then
    printError("Usage: mv <source> <destination>")
    return
end

local rSrc = shell.resolve(src)
local rDst = shell.resolve(dst)

if not fs.exists(rSrc) then
    printError("mv: cannot stat '" .. src .. "': No such file or directory")
    return
end

if fs.isDir(rDst) then
    rDst = fs.combine(rDst, fs.getName(rSrc))
end

if fs.exists(rDst) then
    fs.delete(rDst)
end

fs.move(rSrc, rDst)
