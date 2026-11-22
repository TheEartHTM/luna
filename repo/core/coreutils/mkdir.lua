-- mkdir - Create directories
local args = { ... }
if #args == 0 then
    printError("Usage: mkdir <dir1> [dir2...]")
    return
end

for _, path in ipairs(args) do
    local resolved = shell.resolve(path)
    if fs.exists(resolved) then
        printError("mkdir: cannot create directory '" .. path .. "': File exists")
    else
        fs.makeDir(resolved)
    end
end
