-- ssh.lua - OpenSSH Client for Luna OS (CEE Edition)
local args = { ... }

local net = _G.LunaNet or (fs.exists("/usr/bin/core/net.lua") and dofile("/usr/bin/core/net.lua"))
if not net then
    error("Luna Network Stack (/usr/bin/core/net.lua) is not available.")
end

if #args == 0 or args[1] == "-h" or args[1] == "--help" then
    print("usage: ssh [options] [user@]destination [command]")
    print("options:")
    print("  -p <pin>       specify CEE signal pin (1..11) or fabric")
    print("  -l <user>      login name")
    print("  -h, --help     display this help")
    print("\nexample:")
    print("  ssh root@10.0.1")
    print("  ssh -p 1 earth@10.0.2")
    print("  ssh -p fabric root@10.0.3 ls -la")
    return
end

local targetUser = nil
local targetIP   = nil
local cmdArgs    = {}
local overridePin = nil

local i = 1
while i <= #args do
    local a = args[i]
    if a == "-p" and args[i + 1] then
        local rawPin = args[i + 1]
        overridePin = (rawPin == "fabric") and "fabric" or (tonumber(rawPin) or 1)
        i = i + 2
    elseif a == "-l" and args[i + 1] then
        targetUser = args[i + 1]
        i = i + 2
    elseif not targetIP then
        if a:find("@") then
            targetUser, targetIP = a:match("^(.-)@(.-)$")
        else
            targetIP = a
        end
        i = i + 1
    else
        table.insert(cmdArgs, a)
        i = i + 1
    end
end

if not targetIP then
    printError("ssh: destination host required")
    return
end

local targetHost = targetIP
local resolvedIp = net.resolveHost and net.resolveHost(targetIP, 1.5, overridePin)
if not resolvedIp then
    printError("ssh: Could not resolve hostname " .. targetHost .. ": Name or service not known")
    return
end
targetIP = resolvedIp

targetUser = targetUser or (_G.CURRENT_USER or "root")

local conf = net.loadConfig()
if not conf.ip then
    printError("ssh: connect to host " .. targetIP .. ": Network is unconfigured. Run 'dhcpcd' to obtain an IP address.")
    return
end

local isUp, statusMsg = net.checkPinStatus(overridePin)
if not isUp then
    printError("ssh: connect to host " .. targetIP .. ": " .. statusMsg)
    return
end

-- Password prompt (masked input)
local function readPassword(prompt)
    write(prompt)
    local pass = ""
    while true do
        local ev, key = os.pullEvent()
        if ev == "char" then
            pass = pass .. key
            write("*")
        elseif ev == "key" then
            if key == keys.enter or key == 13 then
                print()
                break
            elseif key == keys.backspace or key == 8 then
                if #pass > 0 then
                    pass = pass:sub(1, -2)
                    local cx, cy = term.getCursorPos()
                    if cx > 1 then
                        term.setCursorPos(cx - 1, cy)
                        write(" ")
                        term.setCursorPos(cx - 1, cy)
                    end
                end
            end
        end
    end
    return pass
end

write(targetUser .. "@" .. targetIP .. "'s password: ")
local pass = readPassword("")

local authReq = {
    action = "AUTH",
    user = targetUser,
    pass = pass
}

local authResp, err = net.request(targetIP, 22, authReq, 3.5, overridePin)
if not authResp then
    printError("ssh: connect to host " .. targetIP .. " port 22: " .. (err or "Connection refused"))
    return
end

if not authResp.ok then
    printError("Permission denied (" .. (authResp.error or "authentication failed") .. ").")
    return
end

local session = authResp.session
local remoteHost = authResp.hostname or "remote"

-- If single command was passed
if #cmdArgs > 0 then
    local fullCmd = table.concat(cmdArgs, " ")
    local execReq = {
        action = "EXEC",
        session = session,
        command = fullCmd
    }
    local execResp, execErr = net.request(targetIP, 22, execReq, 5.0, overridePin)
    if execResp and execResp.output then
        if execResp.output ~= "" then print(execResp.output) end
    else
        printError("ssh: command execution failed: " .. tostring(execErr or "no response"))
    end
    net.send(targetIP, 22, { action = "CLOSE", session = session }, overridePin)
    return
end

-- Interactive SSH session
if authResp.banner and authResp.banner ~= "" then
    if term.isColor() then term.setTextColor(colors.cyan) end
    print(authResp.banner)
    if term.isColor() then term.setTextColor(colors.white) end
end

print("Last login: " .. os.date("%a %b %d %H:%M:%S %Y") .. " from " .. (net.loadConfig().ip or "local"))
print("Type 'exit' or 'logout' to terminate remote connection.\n")

while true do
    local promptSymbol = (targetUser == "root") and "#" or "$"
    if term.isColor() then
        term.setTextColor(colors.lime)
        write("[" .. targetUser .. "@" .. remoteHost .. "]")
        term.setTextColor(colors.white)
        write(" ~" .. promptSymbol .. " ")
    else
        write("[" .. targetUser .. "@" .. remoteHost .. "] ~" .. promptSymbol .. " ")
    end

    local line = read()
    if not line then break end
    line = line:match("^%s*(.-)%s*$")

    if line == "exit" or line == "logout" then
        print("Connection to " .. targetIP .. " closed.")
        net.send(targetIP, 22, { action = "CLOSE", session = session }, overridePin)
        break
    elseif line ~= "" then
        local execReq = {
            action = "EXEC",
            session = session,
            command = line
        }
        local execResp, execErr = net.request(targetIP, 22, execReq, 8.0, overridePin)
        if execResp and execResp.output then
            if execResp.output ~= "" then
                print(execResp.output)
            end
        else
            printError("ssh: connection dropped: " .. tostring(execErr or "no response"))
            break
        end
    end
end
