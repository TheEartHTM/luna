-- cd - Change working directory with ~ support, permissions check, and tree view (-t / --tree)
local args = { ... }

local showTree = false
local targets = {}

for _, arg in ipairs(args) do
    if arg == "-t" or arg == "--tree" then
        showTree = true
    elseif arg:sub(1, 1) ~= "-" then
        table.insert(targets, arg)
    end
end

local target = targets[1]

local user = _G.CURRENT_USER or "root"
local systemd = _G.systemd or (fs.exists("/etc/systemd.lua") and dofile("/etc/systemd.lua"))
local home = (systemd and systemd.getUserHome and systemd.getUserHome(user))
    or (user == "root" and "/" or ("/home/" .. user))

if not target or target == "~" then
    target = home
elseif target:sub(1, 2) == "~/" then
    target = fs.combine(home, target:sub(3))
end

local resolved = shell.resolve(target)
local clean = fs.combine(resolved, "")
if clean == ".." or clean:sub(1, 3) == "../" then
    clean = ""
end

if not fs.exists(clean) then
    printError("cd: " .. tostring(target or "") .. ": No such file or directory")
    return
end

if not fs.isDir(clean) then
    printError("cd: " .. tostring(target or "") .. ": Not a directory")
    return
end

-- Permission check: execute/traverse permission required
if systemd and systemd.checkAccess then
    if not systemd.checkAccess(clean, user, "x") then
        printError("cd: " .. tostring(target or "") .. ": Permission denied")
        return
    end
end

shell.setDir(clean)

if showTree then
    local displayRoot = (clean == "" and "/" or ("/" .. clean))
    if term.isColor() then term.setTextColor(colors.cyan) end
    print(displayRoot)
    if term.isColor() then term.setTextColor(colors.white) end

    local function printTree(dir, prefix, depth)
        if depth > 3 then return end
        local list = fs.list(dir)
        table.sort(list)
        for i, item in ipairs(list) do
            local isLast = (i == #list)
            local branch = isLast and "\\-- " or "|-- "
            local nextPrefix = prefix .. (isLast and "    " or "|   ")
            local fullItem = fs.combine(dir, item)
            if fs.isDir(fullItem) then
                if term.isColor() then term.setTextColor(colors.blue) end
                print(prefix .. branch .. item .. "/")
                if term.isColor() then term.setTextColor(colors.white) end
                printTree(fullItem, nextPrefix, depth + 1)
            else
                print(prefix .. branch .. item)
            end
        end
    end
    printTree(clean, "", 1)
end
