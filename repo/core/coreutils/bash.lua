-- sh.lua - POSIX / Bash Compatible Shell Script Engine for Luna OS
-- Supports: variables ($VAR, ${VAR}), arithmetic ($((expr))), $?, $#, $0..$9, $(cmd), `cmd`,
--           pipes (|), redirections (>, >>, <), functions (name() { ... }),
--           if/then/elif/else/fi, for/in/do/done, while/do/done,
--           test / [ conditions with !, &&, ||, built-ins, and external command execution.

local term = term
local colors = colors
local isColor = term and term.isColor and term.isColor()

local function trim(s)
    return s:match("^%s*(.-)%s*$") or ""
end

-- Safely evaluate unary and binary tests in [ ... ] or test ...
local function evaluateTest(args, env)
    local cleanArgs = {}
    for _, a in ipairs(args) do
        if a ~= "]" then table.insert(cleanArgs, a) end
    end

    if #cleanArgs == 0 then return false end

    -- Unary negation: ! <test>
    if cleanArgs[1] == "!" then
        local subArgs = {}
        for i = 2, #cleanArgs do table.insert(subArgs, cleanArgs[i]) end
        return not evaluateTest(subArgs, env)
    end

    -- Unary tests: -f, -d, -e, -z, -n
    if cleanArgs[1] == "-f" then
        local p = cleanArgs[2] or ""
        if shell and shell.resolve then p = shell.resolve(p) end
        return fs.exists(p) and not fs.isDir(p)
    elseif cleanArgs[1] == "-d" then
        local p = cleanArgs[2] or ""
        if shell and shell.resolve then p = shell.resolve(p) end
        return fs.exists(p) and fs.isDir(p)
    elseif cleanArgs[1] == "-e" then
        local p = cleanArgs[2] or ""
        if shell and shell.resolve then p = shell.resolve(p) end
        return fs.exists(p)
    elseif cleanArgs[1] == "-z" then
        local s = cleanArgs[2] or ""
        return #s == 0
    elseif cleanArgs[1] == "-n" then
        local s = cleanArgs[2] or ""
        return #s > 0
    end

    -- Binary operators: =, ==, !=, -eq, -ne, -lt, -le, -gt, -ge
    if #cleanArgs >= 3 then
        local left = cleanArgs[1]
        local op = cleanArgs[2]
        local right = cleanArgs[3]

        if op == "=" or op == "==" then
            return left == right
        elseif op == "!=" then
            return left ~= right
        elseif op == "-eq" then
            return (tonumber(left) or 0) == (tonumber(right) or 0)
        elseif op == "-ne" then
            return (tonumber(left) or 0) ~= (tonumber(right) or 0)
        elseif op == "-lt" then
            return (tonumber(left) or 0) < (tonumber(right) or 0)
        elseif op == "-le" then
            return (tonumber(left) or 0) <= (tonumber(right) or 0)
        elseif op == "-gt" then
            return (tonumber(left) or 0) > (tonumber(right) or 0)
        elseif op == "-ge" then
            return (tonumber(left) or 0) >= (tonumber(right) or 0)
        end
    end

    -- Standalone non-empty string is true
    return cleanArgs[1] ~= "" and cleanArgs[1] ~= "0" and cleanArgs[1] ~= "false"
end

-- Tokenize line respecting single and double quotes
local function tokenize(line)
    local tokens = {}
    local cur = {}
    local inDouble = false
    local inSingle = false
    local i = 1
    local len = #line

    while i <= len do
        local c = line:sub(i, i)
        if c == "'" and not inDouble then
            inSingle = not inSingle
            i = i + 1
        elseif c == '"' and not inSingle then
            inDouble = not inDouble
            i = i + 1
        elseif (c == ' ' or c == '\t') and not inDouble and not inSingle then
            if #cur > 0 then
                table.insert(tokens, table.concat(cur))
                cur = {}
            end
            i = i + 1
        else
            table.insert(cur, c)
            i = i + 1
        end
    end
    if #cur > 0 then
        table.insert(tokens, table.concat(cur))
    end
    return tokens
end

-- Redirection splitter that respects single and double quotes
local function splitRedirection(str)
    local inSingle = false
    local inDouble = false
    local len = #str
    local i = 1
    while i <= len do
        local c = str:sub(i, i)
        if c == "'" and not inDouble then
            inSingle = not inSingle
        elseif c == '"' and not inSingle then
            inDouble = not inDouble
        elseif not inSingle and not inDouble then
            if c == ">" then
                if str:sub(i + 1, i + 1) == ">" then
                    local pre = trim(str:sub(1, i - 1))
                    local post = trim(str:sub(i + 2))
                    return pre, post, true
                else
                    local pre = trim(str:sub(1, i - 1))
                    local post = trim(str:sub(i + 1))
                    return pre, post, false
                end
            end
        end
        i = i + 1
    end
    return str, nil, false
end

-- Create Interpreter Instance
local function createInterpreter(customEnv, parentFunctions)
    local interp = {
        env = {
            HOME = (_G.kernel and _G.kernel.getHome and _G.kernel.getHome()) or "/root",
            USER = _G.CURRENT_USER or "root",
            HOSTNAME = (_G.kernel and _G.kernel.getHostname and _G.kernel.getHostname()) or (_G.SYSTEM_NAME or "luna"),
            PWD = (_G.shell and _G.shell.dir and ("/" .. _G.shell.dir())) or "/",
            PATH = "/usr/bin/core:/usr/bin/extra:/usr/bin:/etc",
            SHLVL = "1"
        },
        functions = {},
        lastExitCode = 0,
        scriptArgs = {},
        shouldExit = false
    }

    if parentFunctions then
        for k, v in pairs(parentFunctions) do interp.functions[k] = v end
    end

    if customEnv then
        for k, v in pairs(customEnv) do interp.env[k] = tostring(v) end
    end

    -- Variable & Arithmetic Expander
    function interp:expand(line)
        -- 0. Arithmetic expansion: $(( expr ))
        line = line:gsub("%$%(%((.-)%)%)", function(expr)
            local cleanExpr = expr:gsub("([%w_]+)", function(var)
                local v = self.env[var] or _G[var]
                if v and tonumber(v) then return tostring(v) end
                return var
            end)
            local fn = load("return math.floor(" .. cleanExpr .. ")", "expr", "t", { math = math })
            if fn then
                local ok, res = pcall(fn)
                if ok and type(res) == "number" then return tostring(res) end
            end
            return "0"
        end)

        -- 1. Command substitution: $(cmd) or `cmd`
        line = line:gsub("%$%(%s*(.-)%s*%)", function(subCmd)
            local out = self:executeCapture(subCmd)
            return out:gsub("[\r\n]+$", "")
        end)
        line = line:gsub("`%s*(.-)%s*`", function(subCmd)
            local out = self:executeCapture(subCmd)
            return out:gsub("[\r\n]+$", "")
        end)

        -- 2. Variables: ${VAR}
        line = line:gsub("%${([%w_]+)}", function(k)
            return self.env[k] or ""
        end)

        -- 3. Special Variables: $?, $#, $*, $@, $0..$9
        line = line:gsub("%$%?", function() return tostring(self.lastExitCode) end)
        line = line:gsub("%$%#", function() return tostring(#self.scriptArgs) end)
        line = line:gsub("%$[%*@]", function() return table.concat(self.scriptArgs, " ") end)
        for i = 0, 9 do
            local val = (i == 0) and (self.scriptName or "sh") or (self.scriptArgs[i] or "")
            line = line:gsub("%$" .. i, function() return val end)
        end

        -- 4. Normal Variables: $VAR
        line = line:gsub("%$([%w_]+)", function(k)
            return self.env[k] or ""
        end)

        return line
    end

    -- Condition Evaluator with &&, ||, and [ ... ]
    function interp:evaluateCondition(condStr)
        condStr = trim(condStr)
        if condStr:find("||") then
            local pre, post = condStr:match("^(.-)%s*||%s*(.*)$")
            if pre and post then
                return self:evaluateCondition(pre) or self:evaluateCondition(post)
            end
        end
        if condStr:find("&&") then
            local pre, post = condStr:match("^(.-)%s*&&%s*(.*)$")
            if pre and post then
                return self:evaluateCondition(pre) and self:evaluateCondition(post)
            end
        end

        local condExp = self:expand(condStr)
        local cToks = tokenize(condExp)
        if #cToks == 0 then return false end
        if cToks[1] == "[" or cToks[1] == "test" then
            table.remove(cToks, 1)
            return evaluateTest(cToks, self.env)
        else
            local _, code = self:executeCommandString(condStr, nil, true)
            return code == 0
        end
    end

    -- Execute a pipeline (handles pipes | and redirections)
    function interp:executePipeline(pipeLineStr)
        local pipeParts = {}
        for part in pipeLineStr:gmatch("[^|]+") do
            table.insert(pipeParts, trim(part))
        end

        local inputData = nil
        local finalExit = 0

        for pIdx, cmdStr in ipairs(pipeParts) do
            local isLast = (pIdx == #pipeParts)
            local out, exitCode = self:executeCommandString(cmdStr, inputData, not isLast)
            inputData = out
            finalExit = exitCode
        end

        self.lastExitCode = finalExit
        return finalExit
    end

    -- Execute one command with optional input string and output capture
    function interp:executeCommandString(cmdStr, pipeInput, captureOutputRequired)
        -- Check for output redirection (> or >>) respecting quotes
        local cleanCmd, rawRedir, isAppend = splitRedirection(cmdStr)
        local redirFile = nil
        local redirAppend = isAppend
        local isDevTerm = false
        local devTermObj = nil

        if rawRedir then
            cmdStr = cleanCmd
            local expTarget = self:expand(rawRedir)
            if (expTarget:sub(1, 1) == '"' and expTarget:sub(-1) == '"') or (expTarget:sub(1, 1) == "'" and expTarget:sub(-1) == "'") then
                expTarget = expTarget:sub(2, -2)
            end
            redirFile = trim(expTarget)
            local rawDev = redirFile
            if rawDev:sub(1, 5) == "/dev/" then rawDev = rawDev:sub(6) end
            if _G._DEVICE_MONITORS then
                devTermObj = _G._DEVICE_MONITORS[redirFile] or _G._DEVICE_MONITORS[rawDev]
            end
            if not devTermObj and rawDev:match("^mon%d+$") then
                local idx = rawDev:match("%d+$")
                devTermObj = _G._DEVICE_MONITORS and (_G._DEVICE_MONITORS["mon" .. idx] or _G._DEVICE_MONITORS["/dev/mon" .. idx])
            end
            if devTermObj then
                isDevTerm = true
                redirFile = nil
            elseif shell and shell.resolve then
                redirFile = shell.resolve(redirFile)
            end
        end

        -- Check for variable assignment: VAR=val
        if cmdStr:match("^([%w_]+)=(.*)$") and not cmdStr:match("^%[") and not cmdStr:match("^export") then
            local varName, varVal = cmdStr:match("^([%w_]+)=(.*)$")
            varVal = self:expand(varVal)
            if (varVal:sub(1, 1) == '"' and varVal:sub(-1) == '"') or (varVal:sub(1, 1) == "'" and varVal:sub(-1) == "'") then
                varVal = varVal:sub(2, -2)
            end
            self.env[varName] = varVal
            self.lastExitCode = 0
            return "", 0
        end

        local expanded = self:expand(cmdStr)
        local tokens = tokenize(expanded)
        if #tokens == 0 then return "", 0 end

        local cmd = tokens[1]
        local args = {}
        for i = 2, #tokens do table.insert(args, tokens[i]) end

        local outputBuffer = {}
        local oldTerm = (term and term.current and term.current()) or nil
        local needsCapture = captureOutputRequired or (redirFile ~= nil)

        if isDevTerm and devTermObj and term and term.redirect then
            oldTerm = term.current()
            term.redirect(devTermObj)
            if not redirAppend then
                pcall(devTermObj.clear)
                pcall(devTermObj.setCursorPos, 1, 1)
            end
        elseif needsCapture and term and term.redirect then
            local captureTerm = {
                write = function(s) table.insert(outputBuffer, tostring(s)) end,
                blit = function(t, f, b) table.insert(outputBuffer, tostring(t)) end,
                clear = function() outputBuffer = {} end,
                clearLine = function() end,
                getCursorPos = function() return 1, 1 end,
                setCursorPos = function() end,
                setCursorBlink = function() end,
                getCursorBlink = function() return false end,
                getSize = function() return 80, 25 end,
                scroll = function() end,
                setTextColor = function() end,
                setTextColour = function() end,
                getTextColor = function() return 1 end,
                getTextColour = function() return 1 end,
                setBackgroundColor = function() end,
                setBackgroundColour = function() end,
                getBackgroundColor = function() return 32768 end,
                getBackgroundColour = function() return 32768 end,
                isColor = function() return true end,
                isColour = function() return true end,
                setPaletteColor = function() end,
                setPaletteColour = function() end,
                getPaletteColor = function() return 0, 0, 0 end,
                getPaletteColour = function() return 0, 0, 0 end
            }
            term.redirect(captureTerm)
        end

        local exitCode = 0

        -- 0. Shell Defined Function
        if self.functions and self.functions[cmd] then
            local savedArgs = self.scriptArgs
            self.scriptArgs = args
            self:executeStatements(self.functions[cmd])
            exitCode = self.lastExitCode or 0
            self.scriptArgs = savedArgs

        -- 1. Built-in: echo
        elseif cmd == "echo" then
            local echoStr = table.concat(args, " ")
            if needsCapture then
                table.insert(outputBuffer, echoStr .. "\n")
            end
            if not redirFile then
                print(echoStr)
            end
            exitCode = 0

        -- 2. Built-in: test / [
        elseif cmd == "test" or cmd == "[" then
            local ok = evaluateTest(args, self.env)
            exitCode = ok and 0 or 1

        -- 3. Built-in: export
        elseif cmd == "export" then
            local assign = args[1] or ""
            local k, v = assign:match("^([%w_]+)=(.*)$")
            if k then self.env[k] = v or "" end
            exitCode = 0

        -- 4. Built-in: read
        elseif cmd == "read" then
            local varName = args[1] or "REPLY"
            local val = read and read() or ""
            self.env[varName] = val
            exitCode = 0

        -- 5. Built-in: cd
        elseif cmd == "cd" then
            local targetDir = args[1] or self.env.HOME or "/"
            if shell and shell.setDir then
                local ok = shell.setDir(targetDir)
                if ok then self.env.PWD = targetDir; exitCode = 0 else exitCode = 1 end
            else
                self.env.PWD = targetDir
                exitCode = 0
            end

        -- 6. Built-in: pwd
        elseif cmd == "pwd" then
            local curDir = (shell and shell.dir and ("/" .. shell.dir())) or self.env.PWD or "/"
            if needsCapture then table.insert(outputBuffer, curDir .. "\n") end
            if not redirFile then print(curDir) end
            exitCode = 0

        -- 7. Built-in: sleep
        elseif cmd == "sleep" then
            local sec = tonumber(args[1]) or 1
            if sleep then sleep(sec) end
            exitCode = 0

        -- 8. Built-in: exit
        elseif cmd == "exit" then
            exitCode = tonumber(args[1]) or 0
            self.shouldExit = true

        -- 9. Built-in: true / false
        elseif cmd == "true" then
            exitCode = 0
        elseif cmd == "false" then
            exitCode = 1

        -- 10. External program execution
        else
            local found = false
            local searchPaths = {}

            if cmd:find("/") then
                local resolved = (shell and shell.resolve and shell.resolve(cmd)) or cmd
                table.insert(searchPaths, resolved)
                if not resolved:sub(-4) == ".lua" then
                    table.insert(searchPaths, resolved .. ".lua")
                end
            else
                local pathList = {}
                for p in (self.env.PATH or ""):gmatch("[^:]+") do table.insert(pathList, p) end
                table.insert(pathList, "/usr/bin/core")
                table.insert(pathList, "/usr/bin/extra")
                table.insert(pathList, "/usr/bin")
                table.insert(pathList, "/etc")

                for _, p in ipairs(pathList) do
                    table.insert(searchPaths, fs.combine(p, cmd))
                    table.insert(searchPaths, fs.combine(p, cmd .. ".lua"))
                end
            end

            for _, full in ipairs(searchPaths) do
                if fs.exists(full) and not fs.isDir(full) then
                    found = true
                    if full:sub(-3) == ".sh" then
                        local subInterp = createInterpreter(self.env, self.functions)
                        local h = fs.open(full, "r")
                        if h then
                            local sText = h.readAll()
                            h.close()
                            exitCode = subInterp:runScript(sText, args, full)
                        else
                            exitCode = 127
                        end
                    else
                        if shell and shell.run then
                            local ok = shell.run(full, table.unpack(args))
                            exitCode = ok and 0 or 1
                        else
                            local fn, err = loadfile(full)
                            if fn then
                                local ok, res = pcall(fn, table.unpack(args))
                                exitCode = ok and 0 or 1
                            else
                                if oldTerm then pcall(term.redirect, oldTerm) end
                                printError("sh: syntax error in " .. full .. ": " .. tostring(err))
                                exitCode = 127
                            end
                        end
                    end
                    break
                end
            end

            if not found then
                if oldTerm then pcall(term.redirect, oldTerm) end
                printError("sh: " .. cmd .. ": command not found")
                exitCode = 127
            end
        end

        if isDevTerm and oldTerm and term and term.redirect then
            term.redirect(oldTerm)
        elseif needsCapture and term and term.redirect and oldTerm then
            term.redirect(oldTerm)
        end

        local capturedText = table.concat(outputBuffer, "")

        -- Write captured output to file if redirected
        if redirFile and redirFile ~= "" then
            if redirFile == "/dev/null" or redirFile == "dev/null" then
                -- discarded quietly
            else
                local mode = redirAppend and "a" or "w"
                local parent = fs.getDir(redirFile)
                if parent ~= "" and not fs.exists(parent) then pcall(fs.makeDir, parent) end
                local h = fs.open(redirFile, mode)
                if h then
                    h.write(capturedText)
                    h.close()
                else
                    printError("sh: cannot write to " .. redirFile)
                    exitCode = 1
                end
            end
        end

        self.lastExitCode = exitCode
        return capturedText, exitCode
    end

    function interp:executeCapture(cmdStr)
        local out, code = self:executeCommandString(cmdStr, nil, true)
        return out or ""
    end

    -- Run multi-line script or statement block
    function interp:executeStatements(stmts)
        for _, s in ipairs(stmts) do
            if self.shouldExit then break end

            if s.type == "cmd" then
                self:executePipeline(s.line)
            elseif s.type == "func" then
                self.functions[s.name] = s.block
            elseif s.type == "if" then
                local ok = self:evaluateCondition(s.cond)
                if ok then
                    self:executeStatements(s.thenBlock)
                else
                    local elifMatched = false
                    for _, eb in ipairs(s.elifBlocks or {}) do
                        if self:evaluateCondition(eb.cond) then
                            self:executeStatements(eb.block)
                            elifMatched = true
                            break
                        end
                    end
                    if not elifMatched and s.elseBlock then
                        self:executeStatements(s.elseBlock)
                    end
                end
            elseif s.type == "for" then
                local expandedItems = self:expand(s.items or "")
                local itemTokens = tokenize(expandedItems)
                local finalItems = {}
                for _, it in ipairs(itemTokens) do
                    if it:find("%*") then
                        local dir = fs.getDir(it)
                        if dir == "" then dir = "." end
                        if fs.exists(dir) and fs.isDir(dir) then
                            for _, fn in ipairs(fs.list(dir)) do
                                table.insert(finalItems, (dir == ".") and fn or (dir .. "/" .. fn))
                            end
                        end
                    else
                        table.insert(finalItems, it)
                    end
                end

                for _, val in ipairs(finalItems) do
                    if self.shouldExit then break end
                    self.env[s.var] = val
                    self:executeStatements(s.block)
                end
            elseif s.type == "while" then
                while not self.shouldExit do
                    if not self:evaluateCondition(s.cond) then break end
                    self:executeStatements(s.block)
                end
            end
        end
    end

    function interp:runScript(scriptText, args, scriptName)
        self.scriptArgs = args or {}
        self.scriptName = scriptName or "sh"

        local rawLines = {}
        for l in scriptText:gmatch("[^\r\n]+") do
            table.insert(rawLines, l)
        end

        local lineIdx = 1
        local totalLines = #rawLines

        local function parseBlock(endKeywords)
            local statements = {}
            while lineIdx <= totalLines and not self.shouldExit do
                local l = trim(rawLines[lineIdx])
                lineIdx = lineIdx + 1

                if l == "" or l:sub(1, 1) == "#" then
                    -- skip comments and blank lines
                else
                    for _, kw in ipairs(endKeywords) do
                        if l == kw or l:match("^" .. kw .. "%f[%s;]") then
                            return statements, l
                        end
                    end

                    -- Function declaration: name() { ... } or function name() { ... } or function name { ... }
                    local fName = l:match("^([%w_%-]+)%s*%(%s*%)%s*{?$")
                        or l:match("^function%s+([%w_%-]+)%s*%(?%s*%)?%s*{?$")

                    if fName then
                        if not l:find("{") and lineIdx <= totalLines and trim(rawLines[lineIdx]) == "{" then
                            lineIdx = lineIdx + 1
                        end
                        local fBlock, _ = parseBlock({ "}" })
                        table.insert(statements, {
                            type = "func",
                            name = fName,
                            block = fBlock
                        })

                    elseif l:match("^if%s+") or l:match("^if%[") then
                        local condStr = l:match("^if%s+(.-)%s*;?%s*then?$") or l:match("^if%s+(.*)$")
                        if not l:find("then") then
                            if lineIdx <= totalLines and trim(rawLines[lineIdx]) == "then" then
                                lineIdx = lineIdx + 1
                            end
                        end
                        local thenBlock, endKw = parseBlock({ "elif", "else", "fi" })
                        local elifBlocks = {}
                        local elseBlock = nil

                        while endKw:match("^elif") do
                            local eCond = endKw:match("^elif%s+(.-)%s*;?%s*then?$") or endKw:match("^elif%s+(.*)$")
                            local eBlock, nextKw = parseBlock({ "elif", "else", "fi" })
                            table.insert(elifBlocks, { cond = eCond, block = eBlock })
                            endKw = nextKw
                        end

                        if endKw:match("^else") then
                            elseBlock, endKw = parseBlock({ "fi" })
                        end

                        table.insert(statements, {
                            type = "if",
                            cond = condStr,
                            thenBlock = thenBlock,
                            elifBlocks = elifBlocks,
                            elseBlock = elseBlock
                        })

                    elseif l:match("^for%s+") then
                        local varName, itemsStr = l:match("^for%s+([%w_]+)%s+in%s+(.-)%s*;?%s*do?$")
                        if not itemsStr then
                            varName, itemsStr = l:match("^for%s+([%w_]+)%s+in%s+(.*)$")
                        end
                        if not l:find("do") then
                            if lineIdx <= totalLines and trim(rawLines[lineIdx]) == "do" then
                                lineIdx = lineIdx + 1
                            end
                        end
                        local doBlock, _ = parseBlock({ "done" })
                        table.insert(statements, {
                            type = "for",
                            var = varName,
                            items = itemsStr,
                            block = doBlock
                        })

                    elseif l:match("^while%s+") then
                        local condStr = l:match("^while%s+(.-)%s*;?%s*do?$") or l:match("^while%s+(.*)$")
                        if not l:find("do") then
                            if lineIdx <= totalLines and trim(rawLines[lineIdx]) == "do" then
                                lineIdx = lineIdx + 1
                            end
                        end
                        local doBlock, _ = parseBlock({ "done" })
                        table.insert(statements, {
                            type = "while",
                            cond = condStr,
                            block = doBlock
                        })

                    else
                        table.insert(statements, {
                            type = "cmd",
                            line = l
                        })
                    end
                end
            end
            return statements, ""
        end

        local rootStatements, _ = parseBlock({})
        self:executeStatements(rootStatements)
        return self.lastExitCode
    end

    return interp
end

-- CLI Runner
local args = { ... }

if #args == 0 then
    -- Interactive mode
    print("Luna sh - POSIX shell v5.2")
    print("Type 'exit' to quit.")
    local interp = createInterpreter()
    while not interp.shouldExit do
        io.write("sh$ ")
        local line = read and read() or nil
        if not line or line == "exit" then break end
        if trim(line) ~= "" then
            interp:executePipeline(trim(line))
        end
    end
elseif args[1] == "-c" then
    -- Inline command mode
    local cmdText = args[2] or ""
    local interp = createInterpreter()
    interp:runScript(cmdText, { table.unpack(args, 3) }, "sh")
else
    -- Script file mode
    local rawScript = args[1]
    local scriptFile = (shell and shell.resolve and shell.resolve(rawScript)) or rawScript
    if not fs.exists(scriptFile) and shell and shell.dir then
        local combined = fs.combine(shell.dir(), rawScript)
        if fs.exists(combined) then scriptFile = combined end
    end
    if not fs.exists(scriptFile) then
        printError("sh: " .. rawScript .. ": No such file or directory")
        return
    end
    local h = fs.open(scriptFile, "r")
    if not h then
        printError("sh: " .. rawScript .. ": Permission denied or unreadable")
        return
    end
    local scriptText = h.readAll()
    h.close()

    local interp = createInterpreter()
    local scriptArgs = {}
    for i = 2, #args do table.insert(scriptArgs, args[i]) end
    interp:runScript(scriptText, scriptArgs, rawScript)
end
