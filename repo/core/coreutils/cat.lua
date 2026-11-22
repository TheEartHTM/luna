-- cat - Concatenate and display files (with binary & streaming support)
local args = { ... }
if #args == 0 then
    printError("Usage: cat <file1> [file2...]")
    return
end

for _, path in ipairs(args) do
    local resolved = shell.resolve(path)
    if not fs.exists(resolved) then
        printError("cat: " .. path .. ": No such file or directory")
    elseif fs.isDir(resolved) then
        printError("cat: " .. path .. ": Is a directory")
    else
        local h = fs.open(resolved, "rb")
        if not h then
            printError("cat: " .. path .. ": Permission denied or unreadable")
        else
            local chunkSize = 16 * 1024
            local totalRead = 0
            while true do
                local chunk = h.read(chunkSize)
                if not chunk or #chunk == 0 then break end
                write(chunk)
                totalRead = totalRead + #chunk
                -- Prevent CC "Too long without yielding" on large binary files
                if totalRead >= 64 * 1024 then
                    totalRead = 0
                    os.queueEvent("cat_yield")
                    os.pullEvent("cat_yield")
                end
            end
            h.close()
        end
    end
end
