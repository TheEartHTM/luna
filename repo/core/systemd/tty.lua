-- /usr/lib/tty.lua - Luna OS TTY & Workspace Manager Library
-- Provides developer API for multi-seat, multi-display, and background TTY execution

local tty = {}

function tty.list()
    if _G.kernel and _G.kernel.tty and _G.kernel.tty.list then
        return _G.kernel.tty.list()
    end
    return { { name = "tty1", active = true, resolution = { width = 51, height = 19 } } }
end

function tty.get(name)
    if _G.kernel and _G.kernel.tty and _G.kernel.tty.get then
        return _G.kernel.tty.get(name)
    end
    if _G._TTY_TERMS and _G._TTY_TERMS[name] then
        return _G._TTY_TERMS[name]
    end
    return term.current()
end

function tty.write(name, text)
    if _G.kernel and _G.kernel.tty and _G.kernel.tty.write then
        return _G.kernel.tty.write(name, text)
    end
    local h = fs.open("/dev/" .. (name or "tty1"), "w")
    if h then
        h.write(text)
        h.close()
        return true
    end
    return false, "Failed to open /dev/" .. tostring(name)
end

function tty.clear(name)
    if _G.kernel and _G.kernel.tty and _G.kernel.tty.clear then
        return _G.kernel.tty.clear(name)
    end
    local t = tty.get(name)
    if t and t.clear then
        pcall(t.clear)
        if t.setCursorPos then pcall(t.setCursorPos, 1, 1) end
        return true
    end
    return false
end

function tty.switch(name)
    if _G.kernel and _G.kernel.tty and _G.kernel.tty.switch then
        return _G.kernel.tty.switch(name)
    end
    return false, "Not supported"
end

function tty.run(name, cmd, ...)
    if _G.kernel and _G.kernel.tty and _G.kernel.tty.run then
        return _G.kernel.tty.run(name, cmd, ...)
    end
    local t = tty.get(name)
    if not t then return false, "TTY not found" end
    local oldTerm = term.current()
    pcall(term.redirect, t)
    local args = { ... }
    local ok, err = pcall(function()
        if cmd:sub(-3) == ".sh" then
            shell.execute("/usr/bin/core/sh", cmd, table.unpack(args))
        else
            shell.execute(cmd, table.unpack(args))
        end
    end)
    pcall(term.redirect, oldTerm)
    return ok, err
end

function tty.spawn(name, cmd, ...)
    if _G.kernel and _G.kernel.proc and _G.kernel.proc.spawn then
        local t = tty.get(name)
        return _G.kernel.proc.spawn(cmd, { ... }, "user", { tty = name, term = t })
    end
    return false, "Proc manager not available"
end

return tty
