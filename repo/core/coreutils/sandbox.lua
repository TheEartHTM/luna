-- /usr/bin/core/sandbox.lua
-- sandbox - Advanced process isolation and sandboxing subsystem for Luna OS
-- Supports CLI execution and module loading: local sandbox = require("sandbox")

local sandbox = {}

-- -----------------------------------------------------------------------------
-- Helper: Path Normalization & Chroot Jail Resolver
-- -----------------------------------------------------------------------------
function sandbox.resolveChroot(root, path)
    root = tostring(root or "/"):gsub("/+$", "")
    if root == "" then root = "/" end
    
    local parts = {}
    for part in tostring(path or ""):gmatch("[^/\\]+") do
        if part == ".." then
            if #parts > 0 then
                table.remove(parts)
            end
        elseif part ~= "." and part ~= "" then
            table.insert(parts, part)
        end
    end
    
    local rel = table.concat(parts, "/")
    if root == "/" then
        return "/" .. rel
    elseif rel == "" then
        return root
    else
        return root .. "/" .. rel
    end
end

-- -----------------------------------------------------------------------------
-- Chroot, Read-Only & Isolated Empty VFS Wrappers
-- -----------------------------------------------------------------------------
function sandbox.createEmptyFs()
    local eFs = {}
    local realFs = fs or {}
    eFs.combine = realFs.combine or function(a, b) return (a or "") .. "/" .. (b or "") end
    eFs.getName = realFs.getName or function(p) return tostring(p or ""):match("[^/\\]+$") or p end
    eFs.getDir = realFs.getDir or function(p) return tostring(p or ""):match("^(.-)[/\\][^/\\]+$") or "" end
    eFs.exists = function() return false end
    eFs.isDir = function() return false end
    eFs.isReadOnly = function() return true end
    eFs.list = function() return {} end
    eFs.getSize = function() return 0 end
    eFs.getFreeSpace = function() return 0 end
    eFs.attributes = function() return nil end
    eFs.open = function() return nil, "Permission denied (no filesystem in sandbox)" end
    eFs.makeDir = function() return false, "Permission denied (no filesystem in sandbox)" end
    eFs.delete = function() return false, "Permission denied (no filesystem in sandbox)" end
    eFs.copy = function() return false, "Permission denied (no filesystem in sandbox)" end
    eFs.move = function() return false, "Permission denied (no filesystem in sandbox)" end
    eFs.find = function() return {} end
    return eFs
end

function sandbox.createChrootFs(baseFs, rootDir, readOnly)
    baseFs = baseFs or fs
    local cFs = {}

    local function mapPath(p)
        return sandbox.resolveChroot(rootDir, p)
    end

    cFs.combine = function(base, localPath)
        return sandbox.resolveChroot(rootDir, (base or "") .. "/" .. (localPath or ""))
    end

    cFs.open = function(path, mode)
        mode = tostring(mode or "r")
        if readOnly and (mode:find("w") or mode:find("a") or mode:find("+")) then
            return nil, "Read-only file system"
        end
        return baseFs.open(mapPath(path), mode)
    end

    cFs.list = function(path)
        return baseFs.list(mapPath(path))
    end

    cFs.exists = function(path)
        return baseFs.exists(mapPath(path))
    end

    cFs.isDir = function(path)
        return baseFs.isDir(mapPath(path))
    end

    cFs.isReadOnly = function(path)
        if readOnly then return true end
        return baseFs.isReadOnly(mapPath(path))
    end

    cFs.getName = function(path)
        return baseFs.getName(path)
    end

    cFs.getDir = function(path)
        local parts = {}
        for part in tostring(path or ""):gmatch("[^/\\]+") do
            table.insert(parts, part)
        end
        if #parts <= 1 then return "" end
        table.remove(parts)
        return table.concat(parts, "/")
    end

    cFs.getSize = function(path)
        return baseFs.getSize(mapPath(path))
    end

    cFs.getFreeSpace = function(path)
        return baseFs.getFreeSpace(mapPath(path))
    end

    cFs.attributes = function(path)
        return baseFs.attributes(mapPath(path))
    end

    if not readOnly then
        cFs.makeDir = function(path)
            return baseFs.makeDir(mapPath(path))
        end
        cFs.delete = function(path)
            return baseFs.delete(mapPath(path))
        end
        cFs.copy = function(from, to)
            return baseFs.copy(mapPath(from), mapPath(to))
        end
        cFs.move = function(from, to)
            return baseFs.move(mapPath(from), mapPath(to))
        end
    else
        cFs.makeDir = function() return false, "Read-only file system" end
        cFs.delete = function() return false, "Read-only file system" end
        cFs.copy = function() return false, "Read-only file system" end
        cFs.move = function() return false, "Read-only file system" end
    end

    cFs.find = function(wildcard)
        local mapped = mapPath(wildcard)
        local rawResults = baseFs.find(mapped)
        local out = {}
        local rootPrefix = rootDir:gsub("^/+", "")
        for _, item in ipairs(rawResults or {}) do
            local clean = item:gsub("^/+", "")
            if clean:sub(1, #rootPrefix) == rootPrefix then
                local trimmed = clean:sub(#rootPrefix + 1):gsub("^/+", "")
                table.insert(out, trimmed)
            else
                table.insert(out, item)
            end
        end
        return out
    end

    return cFs
end

function sandbox.createReadOnlyFs(baseFs)
    baseFs = baseFs or fs
    local rFs = {}
    for k, v in pairs(baseFs) do
        rFs[k] = v
    end
    rFs.open = function(path, mode)
        mode = tostring(mode or "r")
        if mode:find("w") or mode:find("a") or mode:find("+") then
            return nil, "Read-only file system"
        end
        return baseFs.open(path, mode)
    end
    rFs.makeDir = function() return false, "Read-only file system" end
    rFs.delete = function() return false, "Read-only file system" end
    rFs.copy = function() return false, "Read-only file system" end
    rFs.move = function() return false, "Read-only file system" end
    rFs.isReadOnly = function() return true end
    return rFs
end

-- -----------------------------------------------------------------------------
-- Sanitized OS Table Wrapper
-- -----------------------------------------------------------------------------
function sandbox.createSanitizedOs(baseOs, allowShutdown)
    baseOs = baseOs or os
    local sOs = {}
    for k, v in pairs(baseOs) do
        sOs[k] = v
    end

    if not allowShutdown then
        sOs.shutdown = function()
            error("os.shutdown: permission denied (insufficient privileges in sandbox)", 2)
        end
        sOs.reboot = function()
            error("os.reboot: permission denied (insufficient privileges in sandbox)", 2)
        end
        sOs.setComputerLabel = function()
            error("os.setComputerLabel: permission denied in sandbox", 2)
        end
    end

    return sOs
end

-- -----------------------------------------------------------------------------
-- Environment Constructor
-- -----------------------------------------------------------------------------
function sandbox.create(opts)
    opts = opts or {}
    local profile = opts.profile or "default"
    if opts.strict then profile = "strict" end

    local env = {}

    -- 1. Essential Safe Language Globals
    local safeGlobals = {
        "assert", "error", "ipairs", "pairs", "next", "pcall", "xpcall",
        "select", "tonumber", "tostring", "type", "unpack",
        "_VERSION"
    }
    for _, g in ipairs(safeGlobals) do
        env[g] = _G[g]
    end

    -- 2. Safe Standard Libraries (deep copied or passed safely)
    if math then
        env.math = {}
        for k, v in pairs(math) do env.math[k] = v end
    end
    if string then
        env.string = {}
        for k, v in pairs(string) do env.string[k] = v end
    end
    if table then
        env.table = {}
        for k, v in pairs(table) do env.table[k] = v end
    end
    if bit32 then
        env.bit32 = {}
        for k, v in pairs(bit32) do env.bit32[k] = v end
    elseif bit then
        env.bit = {}
        for k, v in pairs(bit) do env.bit[k] = v end
    end
    if coroutine then
        env.coroutine = {}
        for k, v in pairs(coroutine) do env.coroutine[k] = v end
    end

    -- 3. ComputerCraft TUI & Display Constants
    local ccLibs = { "colors", "colours", "keys", "textutils", "window", "vector" }
    for _, lib in ipairs(ccLibs) do
        if _G[lib] then
            env[lib] = {}
            for k, v in pairs(_G[lib]) do env[lib][k] = v end
        end
    end

    -- 4. Terminal IO
    env.write = write or (term and term.write) or io.write
    env.print = print
    env.printError = printError or print
    env.read = read
    env.sleep = sleep or (os and os.sleep)
    env.term = opts.term or term

    -- 5. Strict Sandboxing checks
    local isStrict = (profile == "strict" or profile == "pure")

    -- 6. OS Subsystem
    local allowShutdown = (opts.allowShutdown == true) and (not isStrict)
    env.os = sandbox.createSanitizedOs(os, allowShutdown)

    -- 7. Filesystem (VFS)
    if opts.no_fs then
        env.fs = sandbox.createEmptyFs()
        if io then
            env.io = {}
            for k, v in pairs(io) do env.io[k] = v end
            env.io.open = function() return nil, "Permission denied (no filesystem in sandbox)" end
        end
    elseif opts.root then
        env.fs = sandbox.createChrootFs(fs, opts.root, opts.read_only or isStrict)
    elseif opts.read_only or isStrict then
        env.fs = sandbox.createReadOnlyFs(fs)
    else
        env.fs = fs
    end

    -- 8. Networking & Peripherals
    if isStrict or opts.no_net then
        env.http = nil
        env.rednet = nil
        env.peripheral = nil
    else
        if http then
            env.http = {}
            for k, v in pairs(http) do env.http[k] = v end
        end
        if rednet then
            env.rednet = {}
            for k, v in pairs(rednet) do env.rednet[k] = v end
        end
        if peripheral then
            env.peripheral = {}
            for k, v in pairs(peripheral) do env.peripheral[k] = v end
        end
    end

    -- 9. Shell Environment (always provided so child commands/scripts run in sandbox)
    if not opts.no_shell then
        local sShell = {}
        local srcShell = opts.shell or shell or _G.shell
        if srcShell then
            for k, v in pairs(srcShell) do sShell[k] = v end
        end
        sShell.dir = (srcShell and srcShell.dir) or function() return "" end
        sShell.setDir = (srcShell and srcShell.setDir) or function(d) return true end
        sShell.resolve = (srcShell and srcShell.resolve) or function(p) return p end
        sShell.path = (srcShell and srcShell.path) or function() return "/usr/bin/core:/usr/bin/extra:/usr/bin:/etc" end
        -- Wrap shell.run and shell.execute to run in child sandbox
        sShell.run = function(prog, ...)
            local ok, code = sandbox.run(prog, { ... }, opts)
            return (code == 0 or ok == true)
        end
        sShell.execute = function(prog, ...)
            local ok, code = sandbox.run(prog, { ... }, opts)
            return (code == 0 or ok == true)
        end
        env.shell = sShell
    end

    -- 10. Self-Referential Environment (_G points to env, NOT the host!)
    env._G = env
    env._ENV = env

    -- 11. Custom variables & security context
    local user = opts.user or _G.CURRENT_USER or "root"
    env.CURRENT_USER = user

    if opts.customEnv then
        for k, v in pairs(opts.customEnv) do
            env[k] = v
        end
    end

    return env
end

-- -----------------------------------------------------------------------------
-- Program Loader and Executor
-- -----------------------------------------------------------------------------
function sandbox.resolveProgram(command, env)
    if not command or command == "" then return nil end
    local sFs = (env and env.fs) or fs
    if not sFs then return nil end

    -- Absolute or direct path
    if command:find("/") or command:find("\\") then
        if sFs.exists(command) and not sFs.isDir(command) then return command end
        if sFs.exists(command .. ".lua") and not sFs.isDir(command .. ".lua") then return command .. ".lua" end
        return nil
    end

    -- Search directories
    local searchDirs = { "/usr/bin/core", "/usr/bin/extra", "/usr/bin/fastfetch", "/usr/bin", "/etc", "" }
    for _, sDir in ipairs(searchDirs) do
        local cand = (sDir == "") and command or (sDir .. "/" .. command)
        if sFs.exists(cand) and not sFs.isDir(cand) then return cand end
        if sFs.exists(cand .. ".lua") and not sFs.isDir(cand .. ".lua") then return cand .. ".lua" end
    end

    return nil
end

function sandbox.run(target, args, opts)
    args = args or {}
    opts = opts or {}

    local env = sandbox.create(opts)
    local resolved = sandbox.resolveProgram(target, env)
    if not resolved then
        if env.printError then
            env.printError("sandbox: " .. tostring(target) .. ": command or file not found")
        else
            printError("sandbox: " .. tostring(target) .. ": command or file not found")
        end
        return false, 127
    end

    local code = nil
    local sFs = env.fs or fs
    if sFs and sFs.open then
        local h = sFs.open(resolved, "r")
        if h then
            code = h.readAll()
            h.close()
        end
    end

    if not code and fs and fs.open then
        local h = fs.open(resolved, "r")
        if h then
            code = h.readAll()
            h.close()
        end
    end

    if not code then
        printError("sandbox: cannot read file: " .. resolved)
        return false, 1
    end

    -- Detect Shell Scripts (.sh or #! shebang)
    local isShellScript = (resolved:sub(-3) == ".sh") or (code:sub(1, 2) == "#!")

    if isShellScript then
        local shPath = "/usr/bin/core/sh.lua"
        if not fs.exists(shPath) then shPath = "/usr/bin/core/sh" end
        if not fs.exists(shPath) and fs.exists("/usr/bin/core/bash.lua") then
            shPath = "/usr/bin/core/bash.lua"
        end

        local shCode = nil
        if fs and fs.open then
            local shH = fs.open(shPath, "r")
            if shH then
                shCode = shH.readAll()
                shH.close()
            end
        end

        if not shCode then
            printError("sandbox: shell interpreter not found at /usr/bin/core/sh")
            return false, 127
        end

        local shFn, shErr
        if load then
            shFn, shErr = load(shCode, "@" .. shPath, "t", env)
            if not shFn and setfenv then
                shFn, shErr = load(shCode, "@" .. shPath)
                if shFn then pcall(setfenv, shFn, env) end
            end
        elseif loadstring then
            shFn, shErr = loadstring(shCode, "@" .. shPath)
            if shFn and setfenv then pcall(setfenv, shFn, env) end
        end

        if not shFn then
            printError("sandbox: failed to load shell: " .. tostring(shErr))
            return false, 1
        end

        if setfenv then pcall(setfenv, shFn, env) end

        -- Run shell interpreter with -c so script executes directly inside sandbox
        local shArgs = { "-c", code, table.unpack(args) }
        local ok, res = pcall(shFn, table.unpack(shArgs))
        if not ok then
            if tostring(res):find("Terminated") then
                print("^C")
                return false, 130
            else
                printError("sandbox: " .. tostring(res))
                return false, 1
            end
        end

        local exitCode = 0
        if type(res) == "number" then
            exitCode = res
        elseif res == false then
            exitCode = 1
        end

        return true, exitCode
    end

    local fn, err
    if load then
        fn, err = load(code, "@" .. resolved, "t", env)
        if not fn and setfenv then
            fn, err = load(code, "@" .. resolved)
            if fn then pcall(setfenv, fn, env) end
        end
    elseif loadstring then
        fn, err = loadstring(code, "@" .. resolved)
        if fn and setfenv then pcall(setfenv, fn, env) end
    end

    if not fn then
        printError("sandbox: syntax error: " .. tostring(err))
        return false, 1
    end

    if setfenv then
        pcall(setfenv, fn, env)
    end

    local ok, res = pcall(fn, table.unpack(args))
    if not ok then
        if tostring(res):find("Terminated") then
            print("^C")
            return false, 130
        else
            printError("sandbox: " .. tostring(res))
            return false, 1
        end
    end

    local exitCode = 0
    if type(res) == "number" then
        exitCode = res
    elseif res == false then
        exitCode = 1
    end

    return true, exitCode
end

-- -----------------------------------------------------------------------------
-- CLI Entry Point
-- -----------------------------------------------------------------------------
local rawArgs = { ... }

-- If invoked as a module (e.g. require("sandbox") or pcall(fn, "--module"))
if #rawArgs == 1 and rawArgs[1] == "--module" then
    return sandbox
end

-- If executed from CLI, parse arguments
if #rawArgs > 0 and rawArgs[1] ~= "--module" then
    local opts = {
        strict = false,
        root = nil,
        read_only = false,
        no_net = false,
        no_fs = false,
        no_reboot = true,
        user = nil,
        profile = "default",
        customEnv = {}
    }

    local cmd = nil
    local cmdArgs = {}
    local idx = 1

    local function printHelp()
        print("Usage: sandbox [OPTIONS] <COMMAND> [ARGS...]")
        print("Run programs in an isolated, sandboxed environment.")
        print("")
        print("Options:")
        print("  -s, --strict       Strict sandbox (read-only fs, no net, no os.shutdown)")
        print("  -r, --root <DIR>   Chroot / jail filesystem to specified directory")
        print("  -R, --read-only    Mount filesystem in read-only mode")
        print("      --no-net       Disable network interfaces (http, rednet, modems)")
        print("      --no-fs        Disable filesystem APIs entirely")
        print("      --no-reboot    Disable os.shutdown and os.reboot")
        print("  -u, --user <NAME>  Execute under specified user context (root only)")
        print("  -p, --profile <P>  Predefined profile: 'strict', 'jail', 'user'")
        print("  -e, --env K=V      Inject environment variable into sandbox")
        print("  -h, --help         Display this help message")
    end

    while idx <= #rawArgs do
        local a = rawArgs[idx]
        if a == "-h" or a == "--help" then
            printHelp()
            return 0
        elseif a == "-s" or a == "--strict" then
            opts.strict = true
            opts.profile = "strict"
        elseif a == "-r" or a == "--root" then
            idx = idx + 1
            opts.root = rawArgs[idx]
        elseif a == "-R" or a == "--read-only" then
            opts.read_only = true
        elseif a == "--no-net" then
            opts.no_net = true
        elseif a == "--no-fs" then
            opts.no_fs = true
        elseif a == "--no-reboot" then
            opts.no_reboot = true
        elseif a == "-u" or a == "--user" then
            idx = idx + 1
            local targetUser = rawArgs[idx]
            local curUser = _G.CURRENT_USER or "root"
            if curUser ~= "root" and targetUser ~= curUser then
                printError("sandbox: permission denied: only root can specify --user")
                return 1
            end
            opts.user = targetUser
        elseif a == "-p" or a == "--profile" then
            idx = idx + 1
            opts.profile = rawArgs[idx]
        elseif a == "-e" or a == "--env" then
            idx = idx + 1
            local kv = rawArgs[idx] or ""
            local k, v = kv:match("^([^=]+)=(.*)$")
            if k then opts.customEnv[k] = v end
        elseif a:sub(1, 1) == "-" then
            printError("sandbox: unrecognized option '" .. a .. "'")
            print("Try 'sandbox --help' for more information.")
            return 1
        else
            cmd = a
            idx = idx + 1
            while idx <= #rawArgs do
                table.insert(cmdArgs, rawArgs[idx])
                idx = idx + 1
            end
            break
        end
        idx = idx + 1
    end

    if not cmd then
        printHelp()
        return 0
    end

    local ok, code = sandbox.run(cmd, cmdArgs, opts)
    return code or (ok and 0 or 1)
end

return sandbox
