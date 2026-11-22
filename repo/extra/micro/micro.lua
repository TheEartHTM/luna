-- micro - Terminal text editor for Luna OS
local args = { ... }
if #args == 0 or args[1] == "-h" or args[1] == "--help" then
    print("micro - Terminal text editor (Luna OS)")
    print("Usage: micro <filename>")
    print("Keybindings:")
    print("  Ctrl-Q : Quit")
    print("  Ctrl-S : Save")
    print("  Ctrl-F : Find (toggle mode, Up/Down or W/S to navigate)")
    print("  Ctrl-Z : Undo")
    print("  Ctrl-Y : Redo")
    print("  Ctrl-A : Select All")
    return
end

local rawPath = args[1]
local fullPath = shell.resolve(rawPath)
local cleanPath = fs.combine(fullPath, "")
local filename = fs.getName(cleanPath)
if filename == "" then filename = "unnamed.txt" end

local curUser = _G.CURRENT_USER or "root"
local systemd = _G.systemd or (fs.exists("/etc/systemd.lua") and dofile("/etc/systemd.lua"))

-- Permission check on open
if fs.exists(cleanPath) then
    if fs.isDir(cleanPath) then
        printError("micro: '" .. rawPath .. "' is a directory")
        return
    end
    if systemd and systemd.checkAccess and not systemd.checkAccess(cleanPath, curUser, "r") then
        printError("micro: cannot open '" .. rawPath .. "': Permission denied")
        return
    end
end

-- Determine file extension
local fileExt = filename:match("%.([^%.]+)$") or "txt"
fileExt = fileExt:lower()

-- Load lines
local lines = {}
local isNewFile = not fs.exists(cleanPath)
if not isNewFile then
    local h = fs.open(cleanPath, "r")
    if h then
        local l = h.readLine()
        while l do
            table.insert(lines, l)
            l = h.readLine()
        end
        h.close()
    end
end
if #lines == 0 then
    lines = { "" }
end

-- Smart Language Detection Engine
local function detectLanguage(fn, firstLine)
    local fnLower = fn:lower()
    local ext = fnLower:match("%.([^%.]+)$") or ""

    if fnLower == "pkgbuild" or fnLower == ".pkginfo" then
        return "pkgbuild", "PKGBUILD"
    elseif fnLower == "makefile" then
        return "make", "Makefile"
    elseif fnLower == "dockerfile" then
        return "docker", "Dockerfile"
    elseif fnLower == ".bashrc" or fnLower == ".bash_profile" or fnLower == ".profile" or fnLower == ".zshrc" then
        return "sh", "Shell Script"
    elseif fnLower == "hosts" or fnLower == "passwd" or fnLower == "shadow" or fnLower == "group" or fnLower == "sudoers" then
        return "conf", "Config"
    end

    if ext == "sh" or ext == "bash" or ext == "zsh" or ext == "ksh" then
        return "sh", "Shell Script"
    elseif ext == "lua" then
        return "lua", "Lua"
    elseif ext == "conf" or ext == "cfg" or ext == "ini" or ext == "db" or ext == "inf" or ext == "properties" then
        return "conf", "Config"
    elseif ext == "json" then
        return "json", "JSON"
    elseif ext == "md" or ext == "markdown" then
        return "markdown", "Markdown"
    end

    local fl = firstLine and firstLine:match("^%s*(.-)%s*$") or ""
    if fl:sub(1, 2) == "#!" then
        if fl:find("sh") or fl:find("bash") or fl:find("zsh") or fl:find("ash") then
            return "sh", "Shell Script"
        elseif fl:find("lua") then
            return "lua", "Lua"
        elseif fl:find("python") then
            return "python", "Python"
        end
    end

    if fl:sub(1, 6) == "local " or fl:sub(1, 9) == "function " or fl:sub(1, 2) == "--" then
        return "lua", "Lua"
    elseif fl:sub(1, 5) == "echo " or fl:sub(1, 7) == "export " or fl:sub(1, 4) == "if [" then
        return "sh", "Shell Script"
    elseif fl:sub(1, 1) == "[" and fl:find("=") then
        return "conf", "Config"
    end

    return (ext ~= "" and ext or "txt"), (ext ~= "" and ext:upper() or "Plain Text")
end

local detectedLang, langDisplayName = detectLanguage(filename, lines[1])

-- Terminal state & dimensions
local termW, termH = term.getSize()
local editH = math.max(termH - 2, 1)

local cursorX, cursorY = 1, 1
local scrollX, scrollY = 0, 0
local modified = false
local selection = nil -- { startY, startX, endY, endX }
local statusMsg = ""
local running = true

-- Find mode state
local searchMode = false
local searchQuery = ""
local matches = {}
local matchIndex = 0

-- Undo / Redo history
local undoStack = {}
local redoStack = {}
local MAX_HISTORY = 100

local function cloneLines(src)
    local t = {}
    for i = 1, #src do t[i] = src[i] end
    return t
end

local function pushUndo()
    table.insert(undoStack, {
        lines = cloneLines(lines),
        cx = cursorX,
        cy = cursorY,
        mod = modified
    })
    if #undoStack > MAX_HISTORY then
        table.remove(undoStack, 1)
    end
    redoStack = {}
end

local function setMessage(msg)
    statusMsg = msg or ""
end

-- Syntax Highlighting Tokenizer for Lua
local keywords = {
    ["and"]=true, ["break"]=true, ["do"]=true, ["else"]=true, ["elseif"]=true,
    ["end"]=true, ["false"]=true, ["for"]=true, ["function"]=true, ["goto"]=true,
    ["if"]=true, ["in"]=true, ["local"]=true, ["nil"]=true, ["not"]=true,
    ["or"]=true, ["repeat"]=true, ["return"]=true, ["then"]=true, ["true"]=true,
    ["until"]=true, ["while"]=true
}
local builtins = {
    ["print"]=true, ["write"]=true, ["read"]=true, ["sleep"]=true, ["pairs"]=true,
    ["ipairs"]=true, ["type"]=true, ["tostring"]=true, ["tonumber"]=true, ["pcall"]=true,
    ["xpcall"]=true, ["error"]=true, ["assert"]=true, ["fs"]=true, ["shell"]=true,
    ["term"]=true, ["textutils"]=true, ["os"]=true, ["colors"]=true, ["colours"]=true,
    ["keys"]=true, ["bit32"]=true, ["string"]=true, ["table"]=true, ["math"]=true,
    ["systemd"]=true, ["io"]=true, ["dofile"]=true, ["load"]=true, ["loadstring"]=true
}

local function highlightLua(line)
    local len = #line
    if len == 0 then return "" end
    local chars = {}
    for i = 1, len do chars[i] = "0" end -- default white
    local i = 1
    while i <= len do
        local sub2 = line:sub(i, i + 1)
        if sub2 == "--" then
            for k = i, len do chars[k] = "7" end -- gray for comments
            break
        end
        local c = line:sub(i, i)
        if c == "\"" or c == "'" then
            local q = c
            chars[i] = "d" -- green for strings
            local j = i + 1
            while j <= len do
                chars[j] = "d"
                local cj = line:sub(j, j)
                if cj == "\\" and j + 1 <= len then
                    j = j + 1
                    chars[j] = "d"
                elseif cj == q then
                    j = j + 1
                    break
                end
                j = j + 1
            end
            i = j
        elseif c:match("[%a_]") then
            local j = i
            while j <= len and line:sub(j, j):match("[%w_]") do
                j = j + 1
            end
            local word = line:sub(i, j - 1)
            local col = "0"
            if keywords[word] then col = "4" -- yellow for keywords
            elseif builtins[word] then col = "9" -- cyan for builtins
            end
            for k = i, j - 1 do chars[k] = col end
            i = j
        elseif c:match("%d") then
            local j = i
            while j <= len and line:sub(j, j):match("[%w%.]") do
                j = j + 1
            end
            for k = i, j - 1 do chars[k] = "1" end -- orange for numbers
            i = j
        elseif c:match("[%+%-%*%/%%%^%#%=%~%<%>%(%)%{%}%[%]%;%:%&%|%,]") then
            chars[i] = "8" -- lightGray for symbols
            i = i + 1
        else
            chars[i] = "0"
            i = i + 1
        end
    end
    return table.concat(chars)
end

-- Syntax Highlighting Tokenizer for Bash / Shell Scripts
local shKeywords = {
    ["if"]=true, ["then"]=true, ["elif"]=true, ["else"]=true, ["fi"]=true,
    ["for"]=true, ["in"]=true, ["do"]=true, ["done"]=true, ["while"]=true,
    ["until"]=true, ["case"]=true, ["esac"]=true, ["function"]=true,
    ["return"]=true, ["exit"]=true, ["select"]=true, ["time"]=true
}

local shBuiltins = {
    ["echo"]=true, ["read"]=true, ["export"]=true, ["cd"]=true, ["pwd"]=true,
    ["sleep"]=true, ["test"]=true, ["true"]=true, ["false"]=true, ["local"]=true,
    ["alias"]=true, ["unalias"]=true, ["source"]=true, ["eval"]=true, ["exec"]=true,
    ["trap"]=true, ["kill"]=true, ["set"]=true, ["unset"]=true, ["shift"]=true,
    ["cat"]=true, ["ls"]=true, ["grep"]=true, ["mkdir"]=true, ["rm"]=true,
    ["cp"]=true, ["mv"]=true, ["chmod"]=true, ["chown"]=true, ["systemctl"]=true,
    ["udevadm"]=true, ["dust"]=true, ["ping"]=true, ["ifconfig"]=true, ["chvt"]=true,
    ["tty"]=true, ["clear"]=true, ["whoami"]=true
}

local function highlightSh(line)
    local len = #line
    if len == 0 then return "" end
    local chars = {}
    for i = 1, len do chars[i] = "0" end

    local i = 1
    while i <= len do
        local c = line:sub(i, i)

        if i == 1 and line:sub(1, 2) == "#!" then
            for k = 1, len do chars[k] = "2" end -- magenta for shebang
            break
        elseif c == "#" then
            for k = i, len do chars[k] = "7" end -- gray for comments
            break
        elseif c == '"' then
            chars[i] = "d" -- green for strings
            local j = i + 1
            while j <= len do
                local cj = line:sub(j, j)
                if cj == "\\" and j + 1 <= len then
                    chars[j] = "d"
                    chars[j + 1] = "d"
                    j = j + 2
                elseif cj == '"' then
                    chars[j] = "d"
                    j = j + 1
                    break
                elseif cj == "$" then
                    chars[j] = "3" -- lightBlue for $VAR inside strings
                    local k = j + 1
                    if k <= len and line:sub(k, k) == "{" then
                        chars[k] = "3"
                        k = k + 1
                        while k <= len and line:sub(k, k) ~= "}" do
                            chars[k] = "3"
                            k = k + 1
                        end
                        if k <= len and line:sub(k, k) == "}" then
                            chars[k] = "3"
                            k = k + 1
                        end
                    elseif k <= len and line:sub(k, k):match("[%w_?#*@0-9]") then
                        while k <= len and line:sub(k, k):match("[%w_]") do
                            chars[k] = "3"
                            k = k + 1
                        end
                    end
                    j = k
                else
                    chars[j] = "d"
                    j = j + 1
                end
            end
            i = j
        elseif c == "'" then
            chars[i] = "d"
            local j = i + 1
            while j <= len do
                chars[j] = "d"
                if line:sub(j, j) == "'" then
                    j = j + 1
                    break
                end
                j = j + 1
            end
            i = j
        elseif c == "`" then
            chars[i] = "2"
            local j = i + 1
            while j <= len and line:sub(j, j) ~= "`" do
                chars[j] = "2"
                j = j + 1
            end
            if j <= len then chars[j] = "2"; j = j + 1 end
            i = j
        elseif c == "$" then
            chars[i] = "3" -- lightBlue
            local j = i + 1
            if j <= len and line:sub(j, j) == "(" then
                chars[j] = "2"
                j = j + 1
                while j <= len and line:sub(j, j) ~= ")" do
                    chars[j] = "2"
                    j = j + 1
                end
                if j <= len then chars[j] = "2"; j = j + 1 end
                i = j
            elseif j <= len and line:sub(j, j) == "{" then
                chars[j] = "3"
                j = j + 1
                while j <= len and line:sub(j, j) ~= "}" do
                    chars[j] = "3"
                    j = j + 1
                end
                if j <= len then chars[j] = "3"; j = j + 1 end
                i = j
            elseif j <= len and line:sub(j, j):match("[%w_?#*@0-9]") then
                chars[j] = "3"
                j = j + 1
                while j <= len and line:sub(j, j):match("[%w_]") do
                    chars[j] = "3"
                    j = j + 1
                end
                i = j
            else
                i = i + 1
            end
        elseif c:match("[%a_]") then
            local j = i
            while j <= len and line:sub(j, j):match("[%w_%-]") do
                j = j + 1
            end
            local word = line:sub(i, j - 1)
            local col = "0"
            if shKeywords[word] then
                col = "4" -- yellow for keywords
            elseif shBuiltins[word] then
                col = "9" -- cyan for commands
            elseif j <= len and line:sub(j, j) == "=" then
                col = "e" -- red for assignment target
            end
            for k = i, j - 1 do chars[k] = col end
            i = j
        elseif c:match("%d") then
            local j = i
            while j <= len and line:sub(j, j):match("[%w%.]") do
                j = j + 1
            end
            for k = i, j - 1 do chars[k] = "1" end -- orange
            i = j
        elseif c:match("[%|%<%>%&%;%[%]%{%}%(%)%=\\^%+%-]") then
            if c == "[" or c == "]" then
                chars[i] = "4" -- yellow for [ ]
            elseif c == "|" or c == ">" or c == "<" or c == "&" or c == ";" then
                chars[i] = "b" -- blue for pipes/redirection
            else
                chars[i] = "8"
            end
            i = i + 1
        else
            chars[i] = "0"
            i = i + 1
        end
    end

    return table.concat(chars)
end

-- Syntax Highlighting Tokenizer for Config / INI / PKGINFO
local function highlightConf(line)
    local len = #line
    if len == 0 then return "" end
    local chars = {}
    for i = 1, len do chars[i] = "0" end

    local i = 1
    while i <= len do
        local c = line:sub(i, i)
        if c == "#" or c == ";" then
            for k = i, len do chars[k] = "7" end
            break
        elseif c == "[" then
            local j = line:find("]", i + 1, true)
            if j then
                for k = i, j do chars[k] = "4" end
                i = j + 1
            else
                chars[i] = "8"
                i = i + 1
            end
        elseif c == '"' or c == "'" then
            local q = c
            chars[i] = "d"
            local j = i + 1
            while j <= len do
                chars[j] = "d"
                if line:sub(j, j) == q and line:sub(j - 1, j - 1) ~= "\\" then
                    j = j + 1
                    break
                end
                j = j + 1
            end
            i = j
        elseif c == "=" then
            chars[i] = "8"
            i = i + 1
        elseif c:match("%d") then
            local j = i
            while j <= len and line:sub(j, j):match("[%w%.]") do j = j + 1 end
            for k = i, j - 1 do chars[k] = "1" end
            i = j
        elseif c:match("[%a_]") then
            local j = i
            while j <= len and line:sub(j, j):match("[%w_%-]") do j = j + 1 end
            local rest = line:sub(j):match("^%s*=")
            local col = rest and "9" or "0"
            for k = i, j - 1 do chars[k] = col end
            i = j
        else
            chars[i] = "0"
            i = i + 1
        end
    end
    return table.concat(chars)
end

local function getLineColors(line)
    if not term.isColor() then
        return string.rep("0", #line)
    end
    if detectedLang == "lua" then
        return highlightLua(line)
    elseif detectedLang == "sh" then
        return highlightSh(line)
    elseif detectedLang == "conf" or detectedLang == "pkgbuild" then
        return highlightConf(line)
    end
    return string.rep("0", #line)
end

local function ensureCursorVisible()
    cursorY = math.max(1, math.min(cursorY, #lines))
    local lineLen = #lines[cursorY]
    cursorX = math.max(1, math.min(cursorX, lineLen + 1))

    local gutterW = math.max(#tostring(#lines) + 1, 3)
    local textW = termW - gutterW

    if cursorY <= scrollY then
        scrollY = cursorY - 1
    elseif cursorY > scrollY + editH then
        scrollY = cursorY - editH
    end

    if cursorX <= scrollX then
        scrollX = cursorX - 1
    elseif cursorX > scrollX + textW then
        scrollX = cursorX - textW
    end

    if scrollY < 0 then scrollY = 0 end
    if scrollX < 0 then scrollX = 0 end
end

-- Rendering
local function render()
    termW, termH = term.getSize()
    editH = math.max(termH - 2, 1)
    ensureCursorVisible()

    local gutterW = math.max(#tostring(#lines) + 1, 3)
    local textW = termW - gutterW

    -- 1. Render editor lines
    for screenRow = 1, editH do
        local fileRow = scrollY + screenRow
        term.setCursorPos(1, screenRow)
        if fileRow <= #lines then
            local lineText = lines[fileRow]
            local numStr = string.format("%" .. (gutterW - 1) .. "d ", fileRow)

            -- Visible slice of the line
            local visibleSlice = ""
            if #lineText > scrollX then
                visibleSlice = lineText:sub(scrollX + 1, scrollX + textW)
            end
            local paddedText = visibleSlice .. string.rep(" ", textW - #visibleSlice)

            -- Base text colors
            local lineFg = getLineColors(lineText)
            local visibleFg = ""
            if #lineFg > scrollX then
                visibleFg = lineFg:sub(scrollX + 1, scrollX + textW)
            end
            local rawFg = visibleFg .. string.rep("0", textW - #visibleFg)

            -- Build foreground and background tables
            local fgChars = {}
            local bgChars = {}
            for i = 1, textW do
                fgChars[i] = rawFg:sub(i, i)
                bgChars[i] = "f" -- default black
            end

            local hasMatch = false

            -- Check selection
            if selection and fileRow >= selection.startY and fileRow <= selection.endY then
                for i = 1, textW do bgChars[i] = "7" end -- gray background
            elseif searchMode and #matches > 0 then
                -- Highlight all matches on this line
                for idx, m in ipairs(matches) do
                    if m.y == fileRow then
                        hasMatch = true
                        local isCurMatch = (idx == matchIndex)
                        local mBg = isCurMatch and "4" or "1" -- yellow for active, orange for others
                        local mFg = "f" -- black text on highlight
                        for col = m.startX, m.endX do
                            local sc = col - scrollX
                            if sc >= 1 and sc <= textW then
                                bgChars[sc] = mBg
                                fgChars[sc] = mFg
                            end
                        end
                    end
                end
            end

            local paddedFg = table.concat(fgChars)
            local paddedBg = table.concat(bgChars)

            local gutterColor = hasMatch and "4" or "7"
            local gutterFg = string.rep(gutterColor, #numStr)
            local gutterBg = string.rep("f", #numStr)

            term.blit(numStr .. paddedText, gutterFg .. paddedFg, gutterBg .. paddedBg)
        else
            -- Empty lines past end of file
            local emptyGutter = string.rep(" ", gutterW)
            local emptyText = string.rep(" ", textW)
            term.blit(emptyGutter .. emptyText, string.rep("7", termW), string.rep("f", termW))
        end
    end

    -- 2. Render micro-like status line (Row H - 1)
    local statusY = termH - 1
    term.setCursorPos(1, statusY)

    local modMarker = modified and "*" or ""
    local leftStatus = " " .. filename .. modMarker
    local rightStatus = string.format("Line %d/%d  Col %d  [%s] ", cursorY, #lines, cursorX, langDisplayName)
    local spaceCount = termW - #leftStatus - #rightStatus
    if spaceCount < 0 then spaceCount = 0 end
    local statusText = leftStatus .. string.rep(" ", spaceCount) .. rightStatus
    if #statusText > termW then statusText = statusText:sub(1, termW) end

    local statusFg = string.rep("0", #statusText) -- white
    local statusBg = string.rep("b", #statusText) -- blue background like micro
    term.blit(statusText, statusFg, statusBg)

    -- 3. Render info / command line (Row H)
    local infoY = termH
    term.setCursorPos(1, infoY)
    local infoText, infoFg

    if searchMode then
        local countStr = (#matches > 0) and string.format("(%d/%d)", matchIndex, #matches) or "(0 matches)"
        infoText = string.format("Find: \"%s\" %s  [W/S or Up/Down: next/prev, ^F: exit]", searchQuery, countStr)
        if #infoText < termW then
            infoText = infoText .. string.rep(" ", termW - #infoText)
        else
            infoText = infoText:sub(1, termW)
        end
        infoFg = string.rep("0", #infoText)
    elseif statusMsg and statusMsg ~= "" then
        infoText = statusMsg
        if #infoText < termW then
            infoText = infoText .. string.rep(" ", termW - #infoText)
        else
            infoText = infoText:sub(1, termW)
        end
        infoFg = string.rep("0", #infoText)
    else
        -- Standard micro legend
        infoText = "^Q Quit  ^S Save  ^F Find  ^Z Undo  ^Y Redo  ^A All"
        if #infoText < termW then
            infoText = infoText .. string.rep(" ", termW - #infoText)
        else
            infoText = infoText:sub(1, termW)
        end
        local fgChars = {}
        for i = 1, #infoText do
            local c = infoText:sub(i, i)
            if c == "^" or (i > 1 and infoText:sub(i - 1, i - 1) == "^") then
                table.insert(fgChars, "9") -- cyan for ^X
            else
                table.insert(fgChars, "8") -- lightGray for description
            end
        end
        infoFg = table.concat(fgChars)
    end
    local infoBg = string.rep("f", termW)
    term.blit(infoText, infoFg, infoBg)

    -- 4. Position hardware cursor
    local screenCurX = gutterW + (cursorX - scrollX)
    local screenCurY = cursorY - scrollY
    term.setCursorPos(screenCurX, screenCurY)
    term.setCursorBlink(true)
end

-- Save operations
local function canWrite()
    if fs.exists(cleanPath) then
        if systemd and systemd.checkAccess then
            return systemd.checkAccess(cleanPath, curUser, "w")
        end
        return not fs.isReadOnly(cleanPath)
    else
        local parent = fs.getDir(cleanPath)
        if parent ~= "" and fs.exists(parent) and systemd and systemd.checkAccess then
            return systemd.checkAccess(parent, curUser, "w")
        end
        return true
    end
end

local function doSaveFile()
    if not canWrite() then
        return false, "Permission denied"
    end
    local parent = fs.getDir(cleanPath)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
    local h = fs.open(cleanPath, "w")
    if not h then
        return false, "Cannot open file for writing"
    end
    for i = 1, #lines do
        h.write(lines[i] .. "\n")
    end
    h.close()

    if isNewFile and systemd and systemd.setFileAttr then
        systemd.setFileAttr(cleanPath, curUser, curUser, "rw-r--r--")
    end

    isNewFile = false
    modified = false
    return true
end

local function handleSave()
    if isNewFile and fs.exists(cleanPath) then
        setMessage("File already exists. Overwrite? (y/n): ")
        render()
        while true do
            local ev, p1 = os.pullEvent()
            if ev == "char" then
                local c = p1:lower()
                if c == "y" then
                    local ok, err = doSaveFile()
                    if ok then
                        setMessage("Overwritten and saved " .. filename)
                    else
                        setMessage("Error: " .. tostring(err))
                    end
                    break
                elseif c == "n" then
                    setMessage("Save cancelled")
                    break
                end
            elseif ev == "key" and p1 == keys.escape then
                setMessage("Save cancelled")
                break
            end
        end
    else
        local ok, err = doSaveFile()
        if ok then
            if isNewFile then
                setMessage("Created and saved " .. filename)
            else
                setMessage("Saved " .. filename)
            end
        else
            setMessage("Error: " .. tostring(err))
        end
    end
    render()
end

local function handleQuit()
    if modified then
        setMessage("Save changes before quitting? (y/n/esc): ")
        render()
        while true do
            local ev, p1 = os.pullEvent()
            if ev == "char" then
                local c = p1:lower()
                if c == "y" then
                    local ok, err = doSaveFile()
                    if ok then
                        running = false
                    else
                        setMessage("Error: " .. tostring(err))
                    end
                    break
                elseif c == "n" then
                    running = false
                    break
                end
            elseif ev == "key" and p1 == keys.escape then
                setMessage("Quit cancelled")
                break
            end
        end
    else
        running = false
    end
end

-- Find operations & match management
local function updateMatches(q)
    matches = {}
    if q and #q > 0 then
        local lowerQ = q:lower()
        for y = 1, #lines do
            local line = lines[y]
            local lowerLine = line:lower()
            local startPos = 1
            while true do
                local sCol, eCol = lowerLine:find(lowerQ, startPos, true)
                if not sCol then break end
                table.insert(matches, { y = y, startX = sCol, endX = eCol })
                startPos = eCol + 1
            end
        end
    end
end

local function jumpToMatch(idx)
    if #matches == 0 then return end
    if idx < 1 then idx = #matches end
    if idx > #matches then idx = 1 end
    matchIndex = idx
    cursorY = matches[matchIndex].y
    cursorX = matches[matchIndex].startX
    ensureCursorVisible()
end

local function handleFindToggle()
    if searchMode then
        -- Already in search mode: exit search mode!
        searchMode = false
        searchQuery = ""
        matches = {}
        matchIndex = 0
        statusMsg = ""
        return
    end

    -- Enter search query prompt
    local query = ""
    local ctrlInFind = false
    while true do
        statusMsg = "Find: " .. query .. "_"
        render()
        local ev, p1 = os.pullEvent()
        if ev == "key" then
            if p1 == keys.leftCtrl or p1 == keys.rightCtrl then
                ctrlInFind = true
            elseif ctrlInFind and p1 == keys.f then
                -- Pressed ^F while typing -> cancel
                statusMsg = ""
                render()
                return
            elseif p1 == keys.backspace then
                if #query > 0 then
                    query = query:sub(1, -2)
                end
            elseif p1 == keys.enter or p1 == keys.numPadEnter then
                break
            elseif p1 == keys.escape then
                statusMsg = ""
                render()
                return
            end
        elseif ev == "key_up" then
            if p1 == keys.leftCtrl or p1 == keys.rightCtrl then
                ctrlInFind = false
            end
        elseif ev == "char" then
            if not ctrlInFind then
                query = query .. p1
            end
        end
    end

    statusMsg = ""
    if query == "" then
        searchMode = false
        render()
        return
    end

    searchQuery = query
    updateMatches(searchQuery)
    searchMode = true

    if #matches > 0 then
        -- Jump to match closest to or following current cursor
        local bestIdx = 1
        for i, m in ipairs(matches) do
            if m.y > cursorY or (m.y == cursorY and m.startX >= cursorX) then
                bestIdx = i
                break
            end
        end
        jumpToMatch(bestIdx)
    else
        matchIndex = 0
    end
    render()
end

-- Undo / Redo operations (silent, no annoying message box)
local function handleUndo()
    if #undoStack == 0 then
        return
    end
    table.insert(redoStack, {
        lines = cloneLines(lines),
        cx = cursorX,
        cy = cursorY,
        mod = modified
    })
    local prev = table.remove(undoStack)
    lines = prev.lines
    cursorX = prev.cx
    cursorY = prev.cy
    modified = prev.mod or true
    selection = nil
    ensureCursorVisible()
    statusMsg = ""
end

local function handleRedo()
    if #redoStack == 0 then
        return
    end
    table.insert(undoStack, {
        lines = cloneLines(lines),
        cx = cursorX,
        cy = cursorY,
        mod = modified
    })
    local nxt = table.remove(redoStack)
    lines = nxt.lines
    cursorX = nxt.cx
    cursorY = nxt.cy
    modified = nxt.mod or true
    selection = nil
    ensureCursorVisible()
    statusMsg = ""
end

-- Select All (silent)
local function handleSelectAll()
    selection = {
        startY = 1,
        startX = 1,
        endY = #lines,
        endX = #lines[#lines] + 1
    }
    statusMsg = ""
end

-- Text editing helpers
local function clearSelection()
    if selection then
        pushUndo()
        lines = { "" }
        cursorX, cursorY = 1, 1
        selection = nil
        modified = true
        statusMsg = ""
        return true
    end
    return false
end

local function handleChar(c)
    if selection then
        pushUndo()
        lines = { c }
        cursorX = 2
        cursorY = 1
        selection = nil
        modified = true
        return
    end

    pushUndo()
    local cur = lines[cursorY]
    lines[cursorY] = cur:sub(1, cursorX - 1) .. c .. cur:sub(cursorX)
    cursorX = cursorX + 1
    modified = true
    statusMsg = ""
end

local function handleBackspace()
    if clearSelection() then return end

    if cursorX > 1 then
        pushUndo()
        local cur = lines[cursorY]
        lines[cursorY] = cur:sub(1, cursorX - 2) .. cur:sub(cursorX)
        cursorX = cursorX - 1
        modified = true
        statusMsg = ""
    elseif cursorY > 1 then
        pushUndo()
        local prev = lines[cursorY - 1]
        local cur = lines[cursorY]
        cursorX = #prev + 1
        lines[cursorY - 1] = prev .. cur
        table.remove(lines, cursorY)
        cursorY = cursorY - 1
        modified = true
        statusMsg = ""
    end
end

local function handleDelete()
    if clearSelection() then return end

    local cur = lines[cursorY]
    if cursorX <= #cur then
        pushUndo()
        lines[cursorY] = cur:sub(1, cursorX - 1) .. cur:sub(cursorX + 1)
        modified = true
        statusMsg = ""
    elseif cursorY < #lines then
        pushUndo()
        local nxt = lines[cursorY + 1]
        lines[cursorY] = cur .. nxt
        table.remove(lines, cursorY + 1)
        modified = true
        statusMsg = ""
    end
end

local function handleEnter()
    if clearSelection() then return end

    pushUndo()
    local cur = lines[cursorY]
    local left = cur:sub(1, cursorX - 1)
    local right = cur:sub(cursorX)

    -- Auto-indent: preserve leading spaces from current line
    local indent = left:match("^(%s*)") or ""

    lines[cursorY] = left
    table.insert(lines, cursorY + 1, indent .. right)
    cursorY = cursorY + 1
    cursorX = #indent + 1
    modified = true
    statusMsg = ""
end

local function handlePaste(text)
    if not text or #text == 0 then return end
    clearSelection()
    pushUndo()

    -- Normalize CRLF and CR to LF, tabs to spaces
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", "  ")

    local cur = lines[cursorY] or ""
    local left = cur:sub(1, cursorX - 1)
    local right = cur:sub(cursorX)

    local pasteLines = {}
    local startIdx = 1
    while true do
        local nlIdx = text:find("\n", startIdx, true)
        if nlIdx then
            table.insert(pasteLines, text:sub(startIdx, nlIdx - 1))
            startIdx = nlIdx + 1
        else
            table.insert(pasteLines, text:sub(startIdx))
            break
        end
    end

    if #pasteLines == 1 then
        lines[cursorY] = left .. pasteLines[1] .. right
        cursorX = cursorX + #pasteLines[1]
    else
        lines[cursorY] = left .. pasteLines[1]
        for i = 2, #pasteLines - 1 do
            table.insert(lines, cursorY + i - 1, pasteLines[i])
        end
        table.insert(lines, cursorY + #pasteLines - 1, pasteLines[#pasteLines] .. right)
        cursorY = cursorY + #pasteLines - 1
        cursorX = #pasteLines[#pasteLines] + 1
    end

    modified = true
    statusMsg = ""
end

local function handleTab()
    if clearSelection() then return end

    pushUndo()
    local cur = lines[cursorY]
    lines[cursorY] = cur:sub(1, cursorX - 1) .. "  " .. cur:sub(cursorX)
    cursorX = cursorX + 2
    modified = true
    statusMsg = ""
end

-- Main editor loop
local ctrlHeld = false

while running do
    render()
    local ev, p1, p2, p3 = os.pullEvent()

    if ev == "key" then
        if p1 == keys.leftCtrl or p1 == keys.rightCtrl then
            ctrlHeld = true

        elseif ctrlHeld then
            if p1 == keys.q then
                handleQuit()
            elseif p1 == keys.s then
                handleSave()
            elseif p1 == keys.f then
                handleFindToggle()
            elseif p1 == keys.z then
                if not searchMode then handleUndo() end
            elseif p1 == keys.y then
                if not searchMode then handleRedo() end
            elseif p1 == keys.a then
                if not searchMode then handleSelectAll() end
            end

        elseif searchMode then
            -- Navigation in search mode: Up/Down, W/S, Enter, Escape
            if p1 == keys.up or p1 == keys.w then
                jumpToMatch(matchIndex - 1)
            elseif p1 == keys.down or p1 == keys.s or p1 == keys.enter or p1 == keys.numPadEnter then
                jumpToMatch(matchIndex + 1)
            elseif p1 == keys.left then
                jumpToMatch(matchIndex - 1)
            elseif p1 == keys.right then
                jumpToMatch(matchIndex + 1)
            elseif p1 == keys.escape then
                handleFindToggle()
            end

        else
            -- Normal editor navigation and editing keys
            if p1 == keys.up then
                selection = nil
                cursorY = math.max(1, cursorY - 1)
                statusMsg = ""
            elseif p1 == keys.down then
                selection = nil
                cursorY = math.min(#lines, cursorY + 1)
                statusMsg = ""
            elseif p1 == keys.left then
                selection = nil
                if cursorX > 1 then
                    cursorX = cursorX - 1
                elseif cursorY > 1 then
                    cursorY = cursorY - 1
                    cursorX = #lines[cursorY] + 1
                end
                statusMsg = ""
            elseif p1 == keys.right then
                selection = nil
                if cursorX <= #lines[cursorY] then
                    cursorX = cursorX + 1
                elseif cursorY < #lines then
                    cursorY = cursorY + 1
                    cursorX = 1
                end
                statusMsg = ""
            elseif p1 == keys.home then
                selection = nil
                cursorX = 1
                statusMsg = ""
            elseif p1 == keys["end"] then
                selection = nil
                cursorX = #lines[cursorY] + 1
                statusMsg = ""
            elseif p1 == keys.pageUp then
                selection = nil
                cursorY = math.max(1, cursorY - editH)
                statusMsg = ""
            elseif p1 == keys.pageDown then
                selection = nil
                cursorY = math.min(#lines, cursorY + editH)
                statusMsg = ""
            elseif p1 == keys.backspace then
                handleBackspace()
            elseif p1 == keys.delete then
                handleDelete()
            elseif p1 == keys.enter or p1 == keys.numPadEnter then
                handleEnter()
            elseif p1 == keys.tab then
                handleTab()
            end
        end

    elseif ev == "key_up" then
        if p1 == keys.leftCtrl or p1 == keys.rightCtrl then
            ctrlHeld = false
        end

    elseif ev == "char" then
        if not ctrlHeld and not searchMode then
            handleChar(p1)
        end

    elseif ev == "paste" then
        if not searchMode then
            handlePaste(p1)
        end

    elseif ev == "mouse_scroll" then
        selection = nil
        scrollY = math.max(0, math.min(scrollY + p1 * 2, #lines - 1))

    elseif ev == "mouse_click" then
        local gutterW = math.max(#tostring(#lines) + 1, 3)
        local clickX, clickY = p2, p3
        if clickY <= editH then
            selection = nil
            local targetRow = scrollY + clickY
            if targetRow <= #lines then
                cursorY = targetRow
                cursorX = math.max(1, math.min(scrollX + (clickX - gutterW), #lines[cursorY] + 1))
            end
        end
    end
end

-- Clear terminal on exit and restore cursor
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
