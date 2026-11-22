-- sshd.lua - OpenSSH-compatible Daemon for Luna OS (CEE Edition)
local args = { ... }
local write = _G.write or io.write or function(s) io.stdout:write(s) end

local CONF_FILE   = "/etc/conf/sshd.conf"
local SERVICES_DB = "/etc/conf/services.db"
local SSH_PORT    = 22

local function loadSSHDConf()
    local conf = {
        port = 22,
        pin = 1, -- CEE signal pin number (1..11) or "fabric"
        permit_root = true,
        max_auth_tries = 3,
        banner = "Welcome to Luna OS (Kernel 6.1.0-luna)"
    }
    if fs.exists(CONF_FILE) then
        local h = fs.open(CONF_FILE, "r")
        if h then
            local content = h.readAll()
            h.close()
            local ok, data = pcall(textutils.unserialize, content)
            if ok and type(data) == "table" then
                for k, v in pairs(data) do conf[k] = v end
            end
        end
    end
    if conf.pin ~= "fabric" and tonumber(conf.pin) then
        conf.pin = tonumber(conf.pin)
    end
    return conf
end

local function saveSSHDConf(conf)
    if not fs.exists("/etc/conf") then fs.makeDir("/etc/conf") end
    local h = fs.open(CONF_FILE, "w")
    if not h then return false end
    h.write(textutils.serialize(conf))
    h.close()
    return true
end

local function getServiceState()
    if fs.exists(SERVICES_DB) then
        local h = fs.open(SERVICES_DB, "r")
        if h then
            local content = h.readAll()
            h.close()
            local ok, data = pcall(textutils.unserialize, content)
            if ok and type(data) == "table" and data.sshd then
                local s = data.sshd
                if s.active == "false" or s.active == 0 or s.active == "0" then
                    s.active = false
                elseif s.active == "true" or s.active == 1 or s.active == "1" then
                    s.active = true
                end
                return s
            end
        end
    end
    return { active = false, sub = "dead", enabled = true }
end

local function setServiceState(isActive)
    local db = {}
    if fs.exists(SERVICES_DB) then
        local h = fs.open(SERVICES_DB, "r")
        if h then
            local content = h.readAll()
            h.close()
            local ok, data = pcall(textutils.unserialize, content)
            if ok and type(data) == "table" then db = data end
        end
    end
    db.sshd = db.sshd or {}
    db.sshd.active = isActive
    db.sshd.sub = isActive and "running" or "dead"
    db.sshd.started_at = isActive and os.date("%a %b %d %H:%M:%S %Y") or nil
    if not fs.exists("/etc/conf") then fs.makeDir("/etc/conf") end
    local h = fs.open(SERVICES_DB, "w")
    if h then
        h.write(textutils.serialize(db))
        h.close()
    end
end

local net = _G.LunaNet or (fs.exists("/usr/bin/core/net.lua") and dofile("/usr/bin/core/net.lua"))
if not net then
    error("Failed to load Luna Network driver (/usr/bin/core/net.lua)")
end

local sshdConf = loadSSHDConf()
local netConf  = net.loadConfig()
local action   = args[1] or "status"

if action == "status" then
    local svcState = getServiceState()
    local isConnected, statusMsg = net.checkPinStatus(sshdConf.pin)

    if term.isColor() then
        term.setTextColor(svcState.active and colors.lime or colors.lightGray)
        write("* ")
        term.setTextColor(colors.white)
    else
        write(svcState.active and "* " or "o ")
    end
    print("sshd.service - OpenSSH server daemon (CEE)")
    print("     Loaded: loaded (/etc/conf/sshd.conf; " .. (svcState.enabled and "enabled" or "disabled") .. ")")

    if svcState.active then
        local sinceStr = svcState.started_at and (" since " .. svcState.started_at) or ""
        print("     Active: active (running)" .. sinceStr)
        print("     IP    : " .. (netConf.ip or "10.0.0"))
        print("     Port  : " .. tostring(sshdConf.port))
        print("     Pin   : Signal " .. tostring(sshdConf.pin) .. " (status: " .. (isConnected and "connected" or "offline") .. ")")
        print("     Status: listening for incoming network connections")
    else
        print("     Active: inactive (dead)")
        print("     IP    : " .. (netConf.ip or "10.0.0"))
        print("     Port  : " .. tostring(sshdConf.port))
        print("     Pin   : Signal " .. tostring(sshdConf.pin))
    end
    return

elseif action == "stop" then
    setServiceState(false)
    _G._DAEMON_sshd = false
    print("[  OK  ] Stopped sshd.service")
    return

elseif action == "help" or action == "-h" or action == "--help" then
    print("usage: sshd [start | stop | status | configure <pin> | -D]")
    print("options:")
    print("  start        start sshd in daemon listener mode")
    print("  stop         stop sshd daemon")
    print("  status       check sshd service status")
    print("  configure    configure network pin (e.g. sshd configure 1)")
    print("  -D           run daemon in foreground")
    return

elseif action == "configure" then
    local newPin = args[2] or "1"
    sshdConf.pin = (newPin == "fabric") and "fabric" or (tonumber(newPin) or 1)
    saveSSHDConf(sshdConf)
    print("sshd pin set to: " .. tostring(sshdConf.pin))
    return
end

local myId = os.getComputerID and os.getComputerID() or 0
local sessions = {}

setServiceState(true)
_G._DAEMON_sshd = true

if action == "start" or action == "-D" then
    print("sshd: Started OpenSSH daemon on " .. netConf.ip .. ":" .. SSH_PORT .. " (pin: " .. tostring(sshdConf.pin) .. ")")
end

local function executeRemoteCommand(cmdStr, user)
    local oldUser = _G.CURRENT_USER
    _G.CURRENT_USER = user

    local outputLines = {}
    local oldPrint = print
    local oldWrite = write

    local buf = ""
    local customWrite = function(text)
        buf = buf .. tostring(text)
        while buf:find("\n") do
            local line, rest = buf:match("^(.-)\n(.*)$")
            table.insert(outputLines, line)
            buf = rest
        end
    end
    local customPrint = function(...)
        local parts = { ... }
        local str = ""
        for i, p in ipairs(parts) do
            str = str .. (i > 1 and " " or "") .. tostring(p)
        end
        table.insert(outputLines, str)
    end

    _G.print = customPrint
    _G.write = customWrite

    local ok, err = pcall(function()
        if shell and shell.run then
            return shell.run(cmdStr)
        else
            local f = loadstring or load
            local fn, lErr = f(cmdStr)
            if fn then return fn() else error(lErr) end
        end
    end)

    if buf ~= "" then table.insert(outputLines, buf) end

    _G.print = oldPrint
    _G.write = oldWrite
    _G.CURRENT_USER = oldUser

    local fullOutput = table.concat(outputLines, "\n")
    if not ok then
        fullOutput = (fullOutput ~= "" and (fullOutput .. "\n") or "") .. "bash: " .. tostring(err)
    end
    return fullOutput, ok and 0 or 1
end

local function sendReply(rxPin, replyPacket)
    if net and net.send then
        net.send(replyPacket.dst_ip, replyPacket.dst_port or SSH_PORT, replyPacket.payload, rxPin, replyPacket.req_id)
        return
    end
    if rxPin == "fabric" and _G.cee and _G.cee.fabricBroadcast then
        _G.cee.fabricBroadcast(replyPacket)
    elseif tonumber(rxPin) and _G.cee and _G.cee.send then
        _G.cee.send(tonumber(rxPin), replyPacket)
    elseif peripheral and peripheral.find("modem") then
        local mod = peripheral.find("modem")
        mod.transmit(SSH_PORT, 22, replyPacket)
    end
    net.trackTX(#textutils.serialize(replyPacket))
end

-- Server main event loop
while _G._DAEMON_sshd ~= false do
    local ev, p1, p2, p3, p4 = os.pullEvent()
    local netConf = net.loadConfig()
    local msg = nil
    local srcPin = sshdConf.pin
    local senderCompId = 0

    if ev == "cee_message" then
        senderCompId = p1
        srcPin = p2
        msg = p3
    elseif ev == "cee_packet" then
        msg = p1
        srcPin = p2
        senderCompId = p3
    elseif ev == "cee_fabric_message" then
        senderCompId = p1
        msg = p2
        srcPin = "fabric"
    elseif ev == "modem_message" then
        msg = p4
    end

    if type(msg) == "table" and msg.protocol == "LUNA_NET" then
        net.trackRX(#textutils.serialize(msg))

        -- 1. Respond to ARP broadcast
        if msg.type == "ARP_REQ" and msg.target_ip == netConf.ip then
            local rep = {
                protocol = "LUNA_NET",
                type = "ARP_REP",
                req_id = msg.req_id,
                ip = netConf.ip,
                sender_id = myId
            }
            sendReply(srcPin, rep)

        -- 2. Respond to PING (Fallback if not handled by kernel)
        elseif (msg.type == "DATA" or msg.type == "REQUEST") and msg.dst_ip == netConf.ip and msg.payload and msg.payload.cmd == "PING" and not _G._KERNEL_ICMP then
            local replyPacket = {
                protocol = "LUNA_NET",
                type = "DATA",
                req_id = msg.req_id,
                src_ip = netConf.ip,
                dst_ip = msg.src_ip,
                sender_id = myId,
                payload = { cmd = "PONG", seq = msg.payload.seq }
            }
            sendReply(srcPin, replyPacket)

        -- 3. SSH Service Requests
        elseif msg.type == "DATA" and (msg.dst_port == SSH_PORT or msg.dst_ip == netConf.ip) and msg.payload then
            local req = msg.payload
            local repData = nil

            -- Authentication
            if req.action == "AUTH" then
                local user = req.user or "root"
                local pass = req.pass or ""

                if user == "root" and not sshdConf.permit_root then
                    repData = { ok = false, error = "Root login is disabled on this server." }
                else
                    local sysd = _G.systemd or (fs.exists("/usr/bin/core/systemd.lua") and dofile("/usr/bin/core/systemd.lua"))
                    local authOk = false
                    if sysd and sysd.verifyPassword then
                        authOk = sysd.verifyPassword(user, pass)
                    else
                        authOk = (pass == "123")
                    end

                    if authOk then
                        local sessId = tostring(math.random(100000, 999999))
                        sessions[sessId] = { user = user, created = os.time(), client_ip = msg.src_ip }
                        repData = {
                            ok = true,
                            session = sessId,
                            banner = sshdConf.banner,
                            hostname = netConf.hostname or "luna",
                            user = user
                        }
                    else
                        repData = { ok = false, error = "Permission denied, please try again." }
                    end
                end

            -- Execute command
            elseif req.action == "EXEC" then
                local sess = sessions[req.session]
                if not sess then
                    repData = { ok = false, error = "Session expired or invalid. Please re-authenticate." }
                else
                    local out, code = executeRemoteCommand(req.command or "", sess.user)
                    repData = {
                        ok = true,
                        output = out,
                        code = code,
                        hostname = netConf.hostname or "luna",
                        user = sess.user
                    }
                end

            -- Close session
            elseif req.action == "CLOSE" then
                if req.session then sessions[req.session] = nil end
                repData = { ok = true }
            end

            if repData then
                local replyPacket = {
                    protocol = "LUNA_NET",
                    type = "DATA",
                    req_id = msg.req_id,
                    src_ip = netConf.ip,
                    dst_ip = msg.src_ip,
                    sender_id = myId,
                    payload = repData
                }
                sendReply(srcPin, replyPacket)
            end
        end
    end
end
