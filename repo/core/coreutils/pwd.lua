local args = { ... }

if args[1] == "-h" or args[1] == "--help" then
    print("Usage: pwd [-L | -P]")
    print("Print the full filename of the current working directory.")
    return
end

local sDir = shell.dir and shell.dir() or ""
if sDir == "" or sDir == "." or sDir == ".." or sDir:sub(1, 3) == "../" then
    print("/")
else
    if sDir:sub(1, 1) == "/" then
        print(sDir)
    else
        print("/" .. sDir)
    end
end
