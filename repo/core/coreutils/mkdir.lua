-- mkdir - Create directories
local args = { ... }
local pFlag = false
local dirs = {}

for _, a in ipairs(args) do
    if a == "-p" or a == "--parents" then
        pFlag = true
    elseif a:sub(1, 1) ~= "-" then
        table.insert(dirs, a)
    end
end

if #dirs == 0 then
    printError("Usage: mkdir [-p] <dir1> [dir2...]")
    return
end

for _, path in ipairs(dirs) do
    local resolved = (shell and shell.resolve and shell.resolve(path)) or path
    if fs.exists(resolved) and not pFlag then
        printError("mkdir: cannot create directory '" .. path .. "': File exists")
    else
        fs.makeDir(resolved)
    end
end
