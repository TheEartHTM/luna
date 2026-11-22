-- sh.lua - POSIX / Bash Compatible Shell Script Engine for Luna OS
-- Supports: variables ($VAR, ${VAR}), $?, $#, $0..$9, $(cmd), `cmd`,
--           pipes (|), redirections (>, >>, <),
--           if/then/elif/else/fi, for/in/do/done, while/do/done,
--           test / [ conditions, built-ins, and external command execution.

local term = term
local colors = colors
local isColor = term and term.isColor and term.isColor()

local function trim(s)
    return s:match("^%s*(.-)%s*$") or ""
end

-- Test condition evaluator ([ ... ] or test ...)
local function evaluateTest(args, env)
    local cleanArgs = {}
    for _, a in ipairs(args) do
        if a ~= "]" then table.insert(cleanArgs, a) end
    end

    if #cleanArgs == 0 then return false end

    -- Unary tests: -f, -d, -e, -z, -n
    if cleanArgs[1] == "-f" then
        local p = cleanArgs[2] or ""
        return fs.exists(p) and not fs.isDir(p)
    elseif cleanArgs[1] == "-d" then
        local p = cleanArgs[2] or ""
        return fs.exists(p) and fs.isDir(p)
    elseif cleanArgs[1] == "-e" then
        local p = cleanArgs[2] or ""
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

-- Create Interpreter Instance
local function createInterpreter(customEnv)
    local interp = {
        env = {
            HOME = (_G.kernel and _G.kernel.getHome and _G.kernel.getHome()) or "/root",
            USER = _G.CURRENT_USER or "root",
            HOSTNAME = (_G.kernel and _G.kernel.getHostname and _G.kernel.getHostname()) or "luna",
            PWD = (_G.shell and _G.shell.dir and ("/" .. _G.shell.dir())) or "/",
            PATH = "/usr/bin/core:/usr/bin/extra:/usr/bin:/etc",
            SHLVL = "1"
        },
        lastExitCode = 0,
        scriptArgs = {},
        shouldExit = false
    }

    if customEnv then
        for k, v in pairs(customEnv) do interp.env[k] = tostring(v) end
    end

    -- Variable & Substitution Expander
    function interp:expand(line)
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
        line = line:gsub("%$%?", tostring(self.lastExitCode))
        line = line:gsub("%$%#", tostring(#self.scriptArgs))
        line = line:gsub("%$[%*@]", table.concat(self.scriptArgs, " "))
        for i = 0, 9 do
            local val = (i == 0) and (self.scriptName or "sh") or (self.scriptArgs[i] or "")
            line = line:gsub("%$" .. i, val)
        end

        -- 4. Normal Variables: $VAR
        line = line:gsub("%$([%w_]+)", function(k)
            return self.env[k] or ""
        end)

        return line
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
        -- Check for output redirection (> or >>)
        local redirFile = nil
        local redirAppend = false

        if cmdStr:find(">>") then
            local pre, post = cmdStr:match("^(.-)>>%s*(.-)$")
            if pre and post then
                cmdStr = trim(pre)
                redirFile = trim(post)
                redirAppend = true
            end
        elseif cmdStr:find(">") then
            local pre, post = cmdStr:match("^(.-)>%s*(.-)$")
            if pre and post then
                cmdStr = trim(pre)
                redirFile = trim(post)
                redirAppend = false
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
        local needsCapture = captureOutputRequired or redirFile ~= nil

        if needsCapture and term and term.redirect then
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

        -- 1. Built-in: echo
        if cmd == "echo" then
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
            if args[1] then
                local k, v = args[1]:match("^([%w_]+)=(.*)$")
                if k then self.env[k] = v or "" end
            end
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
            local pathList = {}
            for p in (self.env.PATH or ""):gmatch("[^:]+") do table.insert(pathList, p) end
            table.insert(pathList, "")

            for _, prefix in ipairs(pathList) do
                local candidate = (prefix == "") and cmd or (prefix .. "/" .. cmd)
                local full = candidate
                if not fs.exists(full) and fs.exists(full .. ".lua") then full = full .. ".lua" end
                if not fs.exists(full) and fs.exists(full .. ".sh") then full = full .. ".sh" end

                if fs.exists(full) and not fs.isDir(full) then
                    found = true
                    -- Check if it's a shell script
                    if full:sub(-3) == ".sh" then
                        local h = fs.open(full, "r")
                        if h then
                            local shText = h.readAll()
                            h.close()
                            local subInterp = createInterpreter(self.env)
                            exitCode = subInterp:runScript(shText, args, full)
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
                                print("sh: syntax error in " .. full .. ": " .. tostring(err))
                                exitCode = 127
                            end
                        end
                    end
                    break
                end
            end

            if not found then
                print("sh: " .. cmd .. ": command not found")
                exitCode = 127
            end
        end

        if needsCapture and term and term.redirect and oldTerm then
            term.redirect(oldTerm)
        end

        local capturedText = table.concat(outputBuffer, "")

        -- Write captured output to file if redirected
        if redirFile and redirFile ~= "" then
            local mode = redirAppend and "a" or "w"
            local parent = fs.getDir(redirFile)
            if parent ~= "" and not fs.exists(parent) then pcall(fs.makeDir, parent) end
            local h = fs.open(redirFile, mode)
            if h then
                h.write(capturedText)
                h.close()
            else
                print("sh: cannot write to " .. redirFile)
                exitCode = 1
            end
        end

        return capturedText, exitCode
    end

    function interp:executeCapture(cmdStr)
        local out, code = self:executeCommandString(cmdStr, nil, true)
        return out or ""
    end

    -- Run multi-line script
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
                    -- skip comments and empty lines
                else
                    for _, kw in ipairs(endKeywords) do
                        if l == kw or l:match("^" .. kw .. "%f[%s;]") then
                            return statements, l
                        end
                    end

                    if l:match("^if%s+") or l:match("^if%[") then
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

        local function executeStatements(stmts)
            for _, s in ipairs(stmts) do
                if self.shouldExit then break end

                if s.type == "cmd" then
                    self:executePipeline(s.line)
                elseif s.type == "if" then
                    local condExpanded = self:expand(s.cond)
                    local condTokens = tokenize(condExpanded)
                    local ok = false
                    if condTokens[1] == "[" or condTokens[1] == "test" then
                        table.remove(condTokens, 1)
                        ok = evaluateTest(condTokens, self.env)
                    else
                        local _, code = self:executeCommandString(s.cond, nil, true)
                        ok = (code == 0)
                    end

                    if ok then
                        executeStatements(s.thenBlock)
                    else
                        local elifMatched = false
                        for _, eb in ipairs(s.elifBlocks or {}) do
                            local eExp = self:expand(eb.cond)
                            local eToks = tokenize(eExp)
                            local eOk = false
                            if eToks[1] == "[" or eToks[1] == "test" then
                                table.remove(eToks, 1)
                                eOk = evaluateTest(eToks, self.env)
                            else
                                local _, code = self:executeCommandString(eb.cond, nil, true)
                                eOk = (code == 0)
                            end
                            if eOk then
                                executeStatements(eb.block)
                                elifMatched = true
                                break
                            end
                        end
                        if not elifMatched and s.elseBlock then
                            executeStatements(s.elseBlock)
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
                        executeStatements(s.block)
                    end
                elseif s.type == "while" then
                    while not self.shouldExit do
                        local condExp = self:expand(s.cond)
                        local cToks = tokenize(condExp)
                        local ok = false
                        if cToks[1] == "[" or cToks[1] == "test" then
                            table.remove(cToks, 1)
                            ok = evaluateTest(cToks, self.env)
                        else
                            local _, code = self:executeCommandString(s.cond, nil, true)
                            ok = (code == 0)
                        end
                        if not ok then break end
                        executeStatements(s.block)
                    end
                end
            end
        end

        executeStatements(rootStatements)
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
    local scriptFile = args[1]
    if not fs.exists(scriptFile) then
        print("sh: " .. scriptFile .. ": No such file or directory")
        return
    end
    local h = fs.open(scriptFile, "r")
    if not h then
        print("sh: " .. scriptFile .. ": Permission denied or unreadable")
        return
    end
    local scriptText = h.readAll()
    h.close()

    local interp = createInterpreter()
    local scriptArgs = {}
    for i = 2, #args do table.insert(scriptArgs, args[i]) end
    interp:runScript(scriptText, scriptArgs, scriptFile)
end
