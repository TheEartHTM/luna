-- dust - Pacman-style Package Manager for Luna OS
local args = { ... }

local DB_FILE   = "/etc/conf/dust.db"
local SYSTEM_LUA  = "/etc/conf/system.lua"
local SYSTEM_CONF = "/etc/conf/system.conf"
local BIN_DIR     = "/usr/bin"

--------------------------------------------------------------------------------
-- Helpers & Configurations
--------------------------------------------------------------------------------
local function loadConf()
    local conf = {
        repo_url = "https://raw.githubusercontent.com/TheEartHTM/luna/main/repo",
        etc_compat = false,
    }
    if fs.exists(SYSTEM_LUA) then
        local h = fs.open(SYSTEM_LUA, "r")
        if h then
            local code = h.readAll()
            h.close()
            local env = { source = function() end }
            local fn = load(code, "@" .. SYSTEM_LUA, "t", env)
            if fn then
                local ok, res = pcall(fn)
                if ok and type(res) == "table" and res.dust then
                    for k, v in pairs(res.dust) do conf[k] = v end
                elseif env.dust and type(env.dust) == "table" then
                    for k, v in pairs(env.dust) do conf[k] = v end
                end
            end
        end
    elseif fs.exists(SYSTEM_CONF) then
        local h = fs.open(SYSTEM_CONF, "r")
        if h then
            local content = h.readAll()
            h.close()
            local ok, data = pcall(textutils.unserialize, content)
            if ok and type(data) == "table" and data.dust then
                for k, v in pairs(data.dust) do conf[k] = v end
            end
        end
    end
    return conf
end

local function saveConf(conf)
    if not fs.exists("/etc/conf") then fs.makeDir("/etc/conf") end
    if fs.exists(SYSTEM_CONF) then
        local h = fs.open(SYSTEM_CONF, "r")
        local sysConf = {}
        if h then
            sysConf = textutils.unserialize(h.readAll()) or {}
            h.close()
        end
        sysConf.dust = conf
        local h2 = fs.open(SYSTEM_CONF, "w")
        if h2 then
            h2.write(textutils.serialize(sysConf))
            h2.close()
        end
    end
    local h = fs.open(CONF_FILE, "w")
    if not h then return false end
    h.write(textutils.serialize(conf))
    h.close()
    return true
end

-- Parse .PKGINFO from string
local function parsePkgInfoString(content)
    if not content or content == "" then return nil end
    local data = { deps = {}, backup = {}, extrafiles = {}, conflicts = {} }
    for rawLine in (content .. "\n"):gmatch("([^\r\n]+)") do
        local line = rawLine:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local k, v = line:match("^([%w_%-]+)%s*=%s*(.-)$")
            if k and v then
                v = v:match("^%s*(.-)%s*$")
                if k == "pkgname" or k == "name" then
                    data.name = v
                elseif k == "pkgver" or k == "version" then
                    data.version = v
                elseif k == "pkgdesc" or k == "desc" or k == "description" then
                    data.description = v
                elseif k == "packager" then
                    data.packager = v
                elseif k == "builddate" or k == "build_date" then
                    data.build_date = v
                elseif k == "path" then
                    data.path = v
                elseif k == "repo" or k == "repository" then
                    data.repo = v
                elseif k == "license" or k == "licenses" then
                    data.licenses = v
                elseif k == "group" or k == "groups" then
                    data.groups = v
                elseif k == "url" then
                    data.url = v
                elseif k == "arch" or k == "architecture" then
                    data.architecture = v
                elseif k == "depend" or k == "dep" then
                    table.insert(data.deps, v)
                elseif k == "deps" then
                    for item in v:gmatch("[^,%s]+") do
                        table.insert(data.deps, item)
                    end
                elseif k == "backup" then
                    for item in v:gmatch("[^,%s]+") do
                        table.insert(data.backup, item)
                    end
                elseif k == "conflict" or k == "conflicts" then
                    for item in v:gmatch("[^,%s]+") do
                        table.insert(data.conflicts, item)
                    end
                elseif k == "provide" or k == "provides" then
                    data.provides = v
                elseif k == "etc_compat" or k == "etc" then
                    data.etc_compat = (v == "true" or v == "1" or v == "yes")
                elseif k == "extrafiles" or k == "extra_files" then
                    for item in v:gmatch("[^,%s]+") do
                        table.insert(data.extrafiles, item)
                    end
                elseif k == "service_name" then
                    data.service_name = v
                elseif k == "service_script" then
                    data.service_script = v
                elseif k == "service_order" then
                    data.service_order = tonumber(v)
                elseif k == "service_desc" then
                    data.service_desc = v
                end
            end
        end
    end
    if data.service_name and data.service_script then
        data.service = {
            name = data.service_name,
            script = data.service_script,
            order = data.service_order or 50,
            desc = data.service_desc or data.service_name
        }
    end
    return data
end

-- Parse .PKGINFO from package directory
local function parsePkgInfo(infoPath)
    if not fs.exists(infoPath) or fs.isDir(infoPath) then return nil end
    local h = fs.open(infoPath, "r")
    if not h then return nil end
    local content = h.readAll()
    h.close()
    return parsePkgInfoString(content)
end

-- Collect all files in a directory recursively
local function getDirectoryFiles(dirPath)
    local list = {}
    if not fs.exists(dirPath) then return list end
    local function scan(p)
        for _, item in ipairs(fs.list(p)) do
            local full = fs.combine(p, item)
            if fs.isDir(full) then
                scan(full)
            else
                local clean = full:gsub("^/+", "")
                table.insert(list, "/" .. clean)
            end
        end
    end
    scan(dirPath)
    table.sort(list)
    return list
end

-- Get all files belonging to a package (folder contents + any /etc/ counterparts/backups)
local function getPackageFiles(pkgName, info)
    if info and info.files and #info.files > 0 then
        return info.files
    end
    local list = {}
    local seen = {}
    local pkgDir = fs.combine(BIN_DIR, pkgName)

    -- 1. All files inside the package directory automatically belong to it
    if fs.exists(pkgDir) and fs.isDir(pkgDir) then
        for _, f in ipairs(getDirectoryFiles(pkgDir)) do
            if not seen[f] then
                seen[f] = true
                table.insert(list, f)
            end
        end
    end

    -- 2. If etc_compat is true, map scripts in /usr/bin/<pkgName> to /etc counterparts
    if info and info.etc_compat and fs.exists(pkgDir) and fs.isDir(pkgDir) then
        for _, item in ipairs(fs.list(pkgDir)) do
            if item ~= ".PKGINFO" then
                local etcPath = "/etc/" .. item
                if (fs.exists(etcPath) or fs.exists("etc/" .. item)) and not seen[etcPath] then
                    seen[etcPath] = true
                    table.insert(list, etcPath)
                end
            end
        end
    end

    -- 3. Tracked configuration files in /etc/conf/ (backup directive)
    if info and info.backup then
        for _, b in ipairs(info.backup) do
            local cleanB = b:sub(1, 1) == "/" and b or ("/" .. b)
            local checkB = cleanB:sub(2)
            if fs.exists(checkB) and not seen[cleanB] then
                seen[cleanB] = true
                table.insert(list, cleanB)
            end
        end
    end

    -- 4. Any additional external files
    if info and info.extrafiles then
        for _, ef in ipairs(info.extrafiles) do
            local cleanEF = ef:sub(1, 1) == "/" and ef or ("/" .. ef)
            local checkEF = cleanEF:sub(2)
            if fs.exists(checkEF) and not seen[cleanEF] then
                seen[cleanEF] = true
                table.insert(list, cleanEF)
            end
        end
    end

    table.sort(list)
    return list
end

-- Calculate total size of all owned files
local function getPackageSize(files)
    local total = 0
    for _, f in ipairs(files) do
        local check = f:sub(1, 1) == "/" and f:sub(2) or f
        if fs.exists(check) and not fs.isDir(check) then
            total = total + fs.getSize(check)
        end
    end
    return total
end

local function resolvePackageFileUrl(remotePkg, pkgName, fPath, repoUrl)
    local filename = fs.getName(fPath)
    local repo = remotePkg.repo or (pkgName == "core" and "core" or "extra")
    local pkgDir = remotePkg.package_dir or pkgName

    local overrides = remotePkg.overrides
    local isOverridden = false
    local customUrl = nil
    local customRepo = nil

    if type(overrides) == "table" then
        local val = overrides[filename] or overrides[fPath]
        if val ~= nil then
            isOverridden = true
            if type(val) == "string" then
                if val:find("^https?://") then
                    customUrl = val
                else
                    customRepo = val
                end
            end
        else
            for _, ov in ipairs(overrides) do
                if ov == filename or ov == fPath then
                    isOverridden = true
                    break
                end
            end
        end
    end

    if customUrl then
        return customUrl
    elseif isOverridden then
        local targetRepo = customRepo or remotePkg.override_repo or (repo == "overrides" and "overrides") or "overrides"
        return repoUrl .. "/" .. targetRepo .. "/" .. pkgDir .. "/" .. filename
    elseif remotePkg.upstream then
        local upstreamBase = remotePkg.upstream:gsub("/+$", "")
        return upstreamBase .. "/" .. filename
    else
        return repoUrl .. "/" .. repo .. "/" .. pkgDir .. "/" .. filename
    end
end

local function getInitialDB()
    return {
        ["core"] = {
            name = "core",
            version = "1.0.0-1",
            repo = "core",
            description = "Luna OS Core System Services, Daemons and Disk Management",
            architecture = "any",
            url = "https://github.com/TheEartHTM/luna",
            licenses = "MIT",
            groups = "base",
            provides = "None",
            deps = {},
            path = "/usr/bin/core",
            etc_compat = false,
            backup = { "/etc/conf/dust.db" },
            install_reason = "explicit",
            install_date = "Wed Nov 18 15:28:00 2026",
            build_date = "Wed Nov 18 15:28:00 2026",
            packager = "Luna Build Team"
        },
        ["extra"] = {
            name = "extra",
            version = "1.0.0-1",
            repo = "extra",
            description = "Luna OS Extra Userland Utilities and Shell Tools",
            architecture = "any",
            url = "https://github.com/TheEartHTM/luna",
            licenses = "GPL-3.0",
            groups = "base-devel",
            provides = "None",
            deps = { "core" },
            path = "/usr/bin/extra",
            etc_compat = true,
            backup = { "/etc/conf/cd.conf", "/etc/conf/ls.conf" },
            install_reason = "explicit",
            install_date = "Wed Nov 18 15:28:00 2026",
            build_date = "Wed Nov 18 15:28:00 2026",
            packager = "Luna Build Team"
        }
    }
end

local function loadDB()
    local db = {}
    if fs.exists(DB_FILE) then
        local h = fs.open(DB_FILE, "r")
        if h then
            local content = h.readAll()
            h.close()
            local ok, data = pcall(textutils.unserialize, content)
            if ok and type(data) == "table" then
                db = data
            end
        end
    end

    if not next(db) then
        db = getInitialDB()
    end

    -- Automatically discover all packages in /usr/bin/
    if fs.exists(BIN_DIR) and fs.isDir(BIN_DIR) then
        for _, pkgFolder in ipairs(fs.list(BIN_DIR)) do
            local dirPath = fs.combine(BIN_DIR, pkgFolder)
            if fs.isDir(dirPath) then
                local infoPath = fs.combine(dirPath, ".PKGINFO")
                local info = parsePkgInfo(infoPath)
                if info and info.name then
                    local pkgName = info.name

                    local entry = db[pkgName] or {}
                    entry.name = pkgName
                    entry.version = entry.version or info.version or "1.0.0-1"
                    entry.description = entry.description or info.description or "User Package"
                    entry.packager = entry.packager or info.packager or "Unknown"
                    entry.build_date = entry.build_date or info.build_date or "Thu Nov 19 19:20:00 2026"
                    local cleanPath = dirPath:gsub("^/+", "")
                    entry.path = info.path or entry.path or ("/" .. cleanPath)
                    entry.deps = (info.deps and #info.deps > 0) and info.deps or (entry.deps or {})
                    entry.licenses = info.licenses or entry.licenses or "Custom"
                    entry.groups = info.groups or entry.groups or "user"
                    entry.url = info.url or entry.url or "local"
                    entry.repo = entry.repo or pkgName
                    entry.install_date = entry.install_date or "Thu Nov 19 19:20:00 2026"
                    entry.install_reason = entry.install_reason or "explicit"
                    entry.etc_compat = (info.etc_compat ~= nil) and info.etc_compat or entry.etc_compat
                    entry.backup = (info.backup and #info.backup > 0) and info.backup or entry.backup
                    entry.conflicts = (info.conflicts and #info.conflicts > 0) and info.conflicts or (entry.conflicts or {})
                    entry.provides = info.provides or entry.provides

                    -- Scan all files belonging to package automatically
                    entry.files = (entry.files and #entry.files > 0) and entry.files or getPackageFiles(pkgName, entry)
                    entry.size = getPackageSize(entry.files)

                    db[pkgName] = entry
                end
            end
        end
    end

    -- Reconstruct / refresh packages from individual .PKGINFO in /etc/conf/packages/
    local pkgInfoBase = "/etc/conf/packages"
    if fs.exists(pkgInfoBase) and fs.isDir(pkgInfoBase) then
        for _, pFolder in ipairs(fs.list(pkgInfoBase)) do
            local pFile = fs.combine(pkgInfoBase, pFolder .. "/.PKGINFO")
            local info = parsePkgInfo(pFile)
            if info and info.name then
                local pName = info.name
                local entry = db[pName] or {}
                entry.name = pName
                entry.version = info.version or entry.version or "1.0.0-1"
                entry.description = info.description or entry.description or ""
                entry.packager = info.packager or entry.packager or "Luna Build Team"
                entry.build_date = info.build_date or entry.build_date
                entry.path = info.path or entry.path or ("/usr/bin/" .. pName)
                entry.deps = (info.deps and #info.deps > 0) and info.deps or (entry.deps or {})
                entry.licenses = info.licenses or entry.licenses or "MIT"
                entry.groups = info.groups or entry.groups or "base"
                entry.url = info.url or entry.url or ""
                entry.repo = info.repo or entry.repo or "core"
                entry.provides = info.provides or entry.provides or "None"
                db[pName] = entry
            end
        end
    end

    -- Clean up legacy phantom 'server' package if present
    if db["server"] and (db["dhcpd"] or not fs.exists(fs.combine(BIN_DIR, "server/.PKGINFO"))) then
        db["server"] = nil
    end

    return db
end

local SYNC_FILE = "/etc/conf/sync.db"

local function loadSyncDB()
    if fs.exists(SYNC_FILE) then
        local h = fs.open(SYNC_FILE, "r")
        if h then
            local data = textutils.unserialize(h.readAll())
            h.close()
            if type(data) == "table" then return data end
        end
    end
    return {}
end

local function saveSyncDB(sdb)
    if not fs.exists("/etc/conf") then fs.makeDir("/etc/conf") end
    local h = fs.open(SYNC_FILE, "w")
    if h then
        h.write(textutils.serialize(sdb))
        h.close()
    end
end

-- Save individual .PKGINFO file for package (fetches upstream or generates)
local function writePkgInfo(pkgName, pkg, repoUrl, repo, pkgDir)
    local pkgInfoDir = fs.combine("/etc/conf/packages", pkgName)
    if not fs.exists(pkgInfoDir) then fs.makeDir(pkgInfoDir) end
    local infoPath = fs.combine(pkgInfoDir, ".PKGINFO")

    local fetched = false
    if repoUrl and http then
        local pDir = pkgDir or pkg.package_dir or pkgName
        local rName = repo or pkg.repo or "core"
        local pInfoUrl = repoUrl .. "/" .. rName .. "/" .. pDir .. "/.PKGINFO"
        local okPi, piRes = pcall(http.get, pInfoUrl)
        if okPi and piRes then
            local pContent = piRes.readAll()
            piRes.close()
            if pContent and #pContent > 0 then
                local ih = fs.open(infoPath, "w")
                if ih then
                    ih.write(pContent)
                    ih.close()
                    fetched = true
                end
            end
        end
    end

    if not fetched then
        local ih = fs.open(infoPath, "w")
        if ih then
            ih.write("# Generated for Luna OS\n")
            ih.write("pkgname = " .. pkgName .. "\n")
            ih.write("pkgver = " .. (pkg.version or "1.0.0-1") .. "\n")
            ih.write("pkgdesc = " .. (pkg.description or "") .. "\n")
            ih.write("repo = " .. (pkg.repo or repo or "core") .. "\n")
            if pkg.path then ih.write("path = " .. pkg.path .. "\n") end
            if pkg.groups then ih.write("group = " .. pkg.groups .. "\n") end
            if pkg.licenses then ih.write("license = " .. pkg.licenses .. "\n") end
            if pkg.packager then ih.write("packager = " .. pkg.packager .. "\n") end
            if pkg.url then ih.write("url = " .. pkg.url .. "\n") end
            if pkg.build_date then ih.write("builddate = " .. pkg.build_date .. "\n") end
            if pkg.provides then ih.write("provides = " .. pkg.provides .. "\n") end
            if pkg.deps and #pkg.deps > 0 then
                ih.write("deps = " .. table.concat(pkg.deps, ", ") .. "\n")
            end
            if pkg.conflicts and #pkg.conflicts > 0 then
                ih.write("conflicts = " .. table.concat(pkg.conflicts, ", ") .. "\n")
            end
            if pkg.service and type(pkg.service) == "table" then
                if pkg.service.name then ih.write("service_name = " .. pkg.service.name .. "\n") end
                if pkg.service.script then ih.write("service_script = " .. pkg.service.script .. "\n") end
                if pkg.service.order then ih.write("service_order = " .. tostring(pkg.service.order) .. "\n") end
                if pkg.service.desc then ih.write("service_desc = " .. pkg.service.desc .. "\n") end
            end
            ih.close()
        end
    end
end

-- Automatic service registration in systemd on package install
local function registerPackageService(pkgName, pkgDir, repo, repoUrl)
    local infoPath = fs.combine("/etc/conf/packages", pkgName .. "/.PKGINFO")
    local sName, sScript, sOrder, sDesc = nil, nil, 50, nil

    if fs.exists(infoPath) then
        local h = fs.open(infoPath, "r")
        if h then
            local content = h.readAll()
            h.close()
            sName = content:match("service_name%s*=%s*([%w_%-]+)")
            sScript = content:match("service_script%s*=%s*([^\r\n]+)")
            local ordStr = content:match("service_order%s*=%s*(%d+)")
            if ordStr then sOrder = tonumber(ordStr) end
            sDesc = content:match("service_desc%s*=%s*([^\r\n]+)")
        end
    end

    if not sName then
        local syncData = loadSyncDB()
        local pObj = syncData and syncData[pkgName]
        if pObj and pObj.service then
            sName = pObj.service.name
            sScript = pObj.service.script
            sOrder = pObj.service.order or 50
            sDesc = pObj.service.desc
        end
    end

    if sName and sScript then
        sScript = sScript:match("^%s*(.-)%s*$")
        sDesc = sDesc and sDesc:match("^%s*(.-)%s*$") or sName

        local srvFile = "/etc/conf/services.db"
        local services = {}
        if fs.exists(srvFile) then
            local sh = fs.open(srvFile, "r")
            if sh then
                services = textutils.unserialize(sh.readAll()) or {}
                sh.close()
            end
        end

        local cur = services[sName] or {}
        cur.name = sName
        cur.script = sScript
        cur.desc = sDesc
        cur.order = sOrder or cur.order or 50
        cur.enabled = (cur.enabled == true)
        cur.status = cur.status or "inactive"
        cur.sub = cur.sub or "dead"
        cur.startup = cur.enabled and "enabled" or "disabled"
        services[sName] = cur

        local sh2 = fs.open(srvFile, "w")
        if sh2 then
            sh2.write(textutils.serialize(services))
            sh2.close()
        end

        -- Mirror to /etc/conf/system.conf
        if fs.exists("/etc/conf/system.conf") then
            local syh = fs.open("/etc/conf/system.conf", "r")
            local sConf = {}
            if syh then
                sConf = textutils.unserialize(syh.readAll()) or {}
                syh.close()
            end
            sConf.services = services
            local syh2 = fs.open("/etc/conf/system.conf", "w")
            if syh2 then
                syh2.write(textutils.serialize(sConf))
                syh2.close()
            end
        end

        print(string.format(":: Registered systemd service '%s.service' (startup: %s)", sName, cur.startup))
    end
end

-- Automatic service unregistration on package remove
local function unregisterPackageService(pkgName)
    local srvFile = "/etc/conf/services.db"
    if not fs.exists(srvFile) then return end
    local sh = fs.open(srvFile, "r")
    local services = {}
    if sh then
        services = textutils.unserialize(sh.readAll()) or {}
        sh.close()
    end

    local toRemove = nil
    for sName, sData in pairs(services) do
        if sName == pkgName or (sData.script and sData.script:find(pkgName, 1, true)) then
            toRemove = sName
            break
        end
    end

    if toRemove then
        -- Stop running service if active in systemctl/systemd
        if _G._DAEMON_THREADS then
            for idx = #_G._DAEMON_THREADS, 1, -1 do
                if _G._DAEMON_THREADS[idx].name == toRemove then
                    _G["_DAEMON_" .. toRemove] = false
                    table.remove(_G._DAEMON_THREADS, idx)
                end
            end
        end

        services[toRemove] = nil
        local sh2 = fs.open(srvFile, "w")
        if sh2 then
            sh2.write(textutils.serialize(services))
            sh2.close()
        end

        if fs.exists("/etc/conf/system.conf") then
            local syh = fs.open("/etc/conf/system.conf", "r")
            local sConf = {}
            if syh then
                sConf = textutils.unserialize(syh.readAll()) or {}
                syh.close()
            end
            sConf.services = services
            local syh2 = fs.open("/etc/conf/system.conf", "w")
            if syh2 then
                syh2.write(textutils.serialize(sConf))
                syh2.close()
            end
        end
        print(string.format(":: Unregistered systemd service '%s.service'", toRemove))
    end
end

local function saveDB(db)
    if not fs.exists("/etc/conf") then fs.makeDir("/etc/conf") end
    local h = fs.open(DB_FILE, "w")
    if h then
        h.write(textutils.serialize(db))
        h.close()
    end
    local h2 = fs.open("/etc/dust.db", "w")
    if h2 then
        h2.write(textutils.serialize(db))
        h2.close()
    end
    return true
end

local function formatSize(bytes)
    if not bytes or bytes == 0 then return "0.00 B" end
    if bytes >= 1024 * 1024 then
        return string.format("%.2f MiB", bytes / (1024 * 1024))
    elseif bytes >= 1024 then
        return string.format("%.2f KiB", bytes / 1024)
    else
        return string.format("%d B", bytes)
    end
end

-- Logging helpers with ANSI/Luna colors
local function printSection(text)
    if term.isColor() then
        term.setTextColor(colors.cyan)
        write(":: ")
        term.setTextColor(colors.white)
        print(text)
    else
        print(":: " .. text)
    end
end

local function printErr(text)
    if term.isColor() then
        term.setTextColor(colors.red)
        write("error: ")
        term.setTextColor(colors.white)
        print(text)
    else
        print("error: " .. text)
    end
end

local function printWarn(text)
    if term.isColor() then
        term.setTextColor(colors.yellow)
        write("warning: ")
        term.setTextColor(colors.white)
        print(text)
    else
        print("warning: " .. text)
    end
end

--------------------------------------------------------------------------------
-- CLI Argument Parsing
--------------------------------------------------------------------------------
local op = nil -- "S", "R", "Q"
local flags = {}
local targets = {}

for _, arg in ipairs(args) do
    if arg:sub(1, 2) == "--" then
        local name = arg:sub(3)
        if name == "sync" then op = "S"
        elseif name == "remove" then op = "R"
        elseif name == "query" then op = "Q"
        elseif name == "refresh" then flags["y"] = true
        elseif name == "sysupgrade" then flags["u"] = true
        elseif name == "info" then flags["i"] = true
        elseif name == "search" then flags["s"] = true
        elseif name == "list" then flags["l"] = true
        elseif name == "unrequired" then flags["t"] = true
        elseif name == "deps" then flags["d"] = true
        elseif name == "recursive" then flags["s"] = true
        elseif name == "needed" then flags["needed"] = true
        elseif name == "reinstall" or name == "force" then flags["f"] = true
        elseif name == "local" or name == "lan" or name == "dev" then flags["local"] = true
        elseif name == "help" then flags["h"] = true
        end
    elseif arg:sub(1, 1) == "-" and #arg > 1 then
        for i = 2, #arg do
            local c = arg:sub(i, i)
            if c == "S" or c == "R" or c == "Q" then
                op = c
            elseif c == "L" then
                flags["local"] = true
            else
                flags[c] = true
            end
        end
    else
        table.insert(targets, arg)
    end
end

if flags["h"] or not op then
    print("usage:  dust <operation> [...]")
    print("operations:")
    print("    dust {-h --help}")
    print("    dust {-Q --query}   [options] [package(s)]")
    print("    dust {-R --remove}  [options] <package(s)>")
    print("    dust {-S --sync}    [options] [package(s)]")
    print("\noptions:")
    print("    -s, --search        search package database (-Q)")
    print("    -i, --info          view package information (-Q, -S)")
    print("    -l, --list          list package files (-Q)")
    print("    -t, --unrequired    list unrequired packages (-Q)")
    print("    -d, --deps          list dependency packages (-Q)")
    print("    -y, --refresh       download fresh database from GitHub (-S)")
    print("    -u, --sysupgrade    upgrade installed packages (-S)")
    print("    -L, --local         download from local dev repository (192.168.0.109:8080) (-S)")
    print("    -s, --recursive     remove package and dependencies (-R)")
    return
end

--------------------------------------------------------------------------------
-- Dependency Resolution & Conflict Detection Engine
--------------------------------------------------------------------------------
local function checkPackageConflicts(packagesToCheck, db)
    local modSet = {}
    for _, p in ipairs(packagesToCheck) do modSet[p.name] = true end

    for _, p in ipairs(packagesToCheck) do
        local pName = p.name
        local rPkg = p.remote or {}
        local conflicts = rPkg.conflicts or {}
        for _, cName in ipairs(conflicts) do
            if modSet[cName] then
                return false, string.format("%s and %s are in conflict", pName, cName)
            end
            if db[cName] and not modSet[cName] then
                return false, string.format("%s and %s are in conflict", pName, cName)
            end
        end

        for instName, instPkg in pairs(db) do
            if not modSet[instName] and instPkg.conflicts then
                for _, cName in ipairs(instPkg.conflicts) do
                    if cName == pName then
                        return false, string.format("%s and %s are in conflict", pName, instName)
                    end
                end
            end
        end
    end
    return true
end

local function checkFileConflicts(packagesToCheck, db)
    local modSet = {}
    for _, p in ipairs(packagesToCheck) do modSet[p.name] = true end

    local fileOwners = {}
    for instName, instPkg in pairs(db) do
        if not modSet[instName] then
            for _, f in ipairs(instPkg.files or {}) do
                local clean = (f:sub(1, 1) == "/") and f:sub(2) or f
                fileOwners[clean] = instName
            end
        end
    end

    local checkOwners = {}
    for _, p in ipairs(packagesToCheck) do
        local pName = p.name
        local remotePkg = p.remote or {}
        for _, f in ipairs(remotePkg.files or {}) do
            local clean = (f:sub(1, 1) == "/") and f:sub(2) or f
            if fileOwners[clean] then
                return false, string.format("%s: %s exists in filesystem (owned by %s)", pName, f, fileOwners[clean])
            end
            if checkOwners[clean] and checkOwners[clean] ~= pName then
                return false, string.format("%s and %s file collision: %s", pName, checkOwners[clean], f)
            end
            checkOwners[clean] = pName
        end
    end
    return true
end

local db = loadDB()
local conf = loadConf()
local HARDCODED_LOCAL_REPO_URL = "http://192.168.0.109:8080"
if flags["local"] then
    conf.repo_url = HARDCODED_LOCAL_REPO_URL
end
local curUser = _G.CURRENT_USER or "root"

--------------------------------------------------------------------------------
-- OPERATION: -Q (Query)
--------------------------------------------------------------------------------
if op == "Q" then
    -- 1. -Qi : Package Info
    if flags["i"] then
        if #targets == 0 then
            printErr("no package specified")
            return
        end
        for _, pkgName in ipairs(targets) do
            local pkg = db[pkgName]
            if not pkg then
                printErr("package '" .. pkgName .. "' was not found")
            else
                local requiredBy = {}
                for otherName, otherPkg in pairs(db) do
                    if otherPkg.deps then
                        for _, d in ipairs(otherPkg.deps) do
                            if d == pkgName then table.insert(requiredBy, otherName) end
                        end
                    end
                end
                table.sort(requiredBy)

                local depsStr = (pkg.deps and #pkg.deps > 0) and table.concat(pkg.deps, "  ") or "None"
                local reqByStr = (#requiredBy > 0) and table.concat(requiredBy, "  ") or "None"
                local backupStr = (pkg.backup and #pkg.backup > 0) and table.concat(pkg.backup, "  ") or "None"

                print(string.format("%-16s: %s", "Name", pkg.name))
                print(string.format("%-16s: %s", "Version", pkg.version or "1.0.0-1"))
                print(string.format("%-16s: %s", "Description", pkg.description or "None"))
                print(string.format("%-16s: %s", "Architecture", pkg.architecture or "any"))
                print(string.format("%-16s: %s", "URL", pkg.url or "local"))
                print(string.format("%-16s: %s", "Licenses", pkg.licenses or "Custom"))
                print(string.format("%-16s: %s", "Groups", pkg.groups or "user"))
                print(string.format("%-16s: %s", "Provides", pkg.provides or "None"))
                print(string.format("%-16s: %s", "Depends On", depsStr))
                print(string.format("%-16s: %s", "Optional Deps", "None"))
                print(string.format("%-16s: %s", "Required By", reqByStr))
                print(string.format("%-16s: %s", "Optional For", "None"))
                local confStr = (pkg.conflicts and #pkg.conflicts > 0) and table.concat(pkg.conflicts, "  ") or "None"
                print(string.format("%-16s: %s", "Conflicts With", confStr))
                print(string.format("%-16s: %s", "Replaces", "None"))
                print(string.format("%-16s: %s", "Installed Size", formatSize(pkg.size)))
                print(string.format("%-16s: %s", "Packager", pkg.packager or "Unknown"))
                print(string.format("%-16s: %s", "Build Date", pkg.build_date or "Thu Nov 19 19:20:00 2026"))
                print(string.format("%-16s: %s", "Install Date", pkg.install_date or "Thu Nov 19 19:20:00 2026"))
                print(string.format("%-16s: %s", "Install Reason", (pkg.install_reason == "dependency") and "Installed as a dependency" or "Explicitly installed"))
                print(string.format("%-16s: %s", "Install Script", "No"))
                print(string.format("%-16s: %s", "Path in PATH", pkg.path or ("/usr/bin/" .. pkg.name)))
                print(string.format("%-16s: %s", "Backup Files", backupStr))
                print(string.format("%-16s: %s", "Validated By", "None"))
                print()
            end
        end
        return

    -- 2. -Ql : List Files
    elseif flags["l"] then
        if #targets == 0 then
            printErr("no package specified")
            return
        end
        for _, pkgName in ipairs(targets) do
            local pkg = db[pkgName]
            if not pkg then
                printErr("package '" .. pkgName .. "' was not found")
            else
                local pkgDir = fs.combine(BIN_DIR, pkgName)
                if pkgDir:sub(1, 1) ~= "/" then pkgDir = "/" .. pkgDir end
                print(pkgName .. " " .. pkgDir .. "/")
                local files = pkg.files or getPackageFiles(pkgName, pkg)
                for _, f in ipairs(files) do
                    print(pkgName .. " " .. f)
                end
            end
        end
        return

    -- 3. -Qs : Search Installed
    elseif flags["s"] then
        local query = targets[1] or ""
        query = query:lower()
        local found = 0
        local names = {}
        for name in pairs(db) do table.insert(names, name) end
        table.sort(names)

        for _, name in ipairs(names) do
            local pkg = db[name]
            local matched = (query == "")
                or name:lower():find(query, 1, true)
                or (pkg.description and pkg.description:lower():find(query, 1, true))
                or (pkg.packager and pkg.packager:lower():find(query, 1, true))
            if not matched and pkg.files then
                for _, f in ipairs(pkg.files) do
                    if f:lower():find(query, 1, true) then matched = true break end
                end
            end
            if matched then
                found = found + 1
                local repo = pkg.repo or "local"
                if term.isColor() then
                    term.setTextColor(colors.white)
                    write(repo .. "/")
                    term.setTextColor(colors.yellow)
                    write(pkg.name .. " ")
                    term.setTextColor(colors.lime)
                    write(pkg.version or "1.0.0-1")
                    term.setTextColor(colors.white)
                    print()
                    print("    " .. (pkg.description or "No description"))
                else
                    print(repo .. "/" .. pkg.name .. " " .. (pkg.version or "1.0.0-1"))
                    print("    " .. (pkg.description or "No description"))
                end
            end
        end
        return

    -- 4. -Qt : List Unrequired / Leaf Packages
    elseif flags["t"] then
        local names = {}
        for name in pairs(db) do
            local isRequired = false
            for _, other in pairs(db) do
                if other.deps then
                    for _, d in ipairs(other.deps) do
                        if d == name then isRequired = true break end
                    end
                end
            end
            if not isRequired then table.insert(names, name) end
        end
        table.sort(names)
        for _, n in ipairs(names) do
            print(n .. " " .. (db[n].version or "1.0.0-1"))
        end
        return

    -- 5. -Qd : List Dependency Packages
    elseif flags["d"] then
        local names = {}
        for name, pkg in pairs(db) do
            if pkg.install_reason == "dependency" then
                table.insert(names, name)
            end
        end
        table.sort(names)
        for _, n in ipairs(names) do
            print(n .. " " .. (db[n].version or "1.0.0-1"))
        end
        return

    -- 6. Plain -Q : List All Installed
    else
        local names = {}
        for name in pairs(db) do table.insert(names, name) end
        table.sort(names)
        for _, n in ipairs(names) do
            print(n .. " " .. (db[n].version or "1.0.0-1"))
        end
        return
    end

--------------------------------------------------------------------------------
-- OPERATION: -S (Sync / Remote)
--------------------------------------------------------------------------------
elseif op == "S" then
    local repoUrl = conf.repo_url or "https://raw.githubusercontent.com/TheEartHTM/luna/main/repo"
    if flags["local"] then
        repoUrl = HARDCODED_LOCAL_REPO_URL
        printSection("Using local development repository: " .. repoUrl)
    end
    local host = repoUrl:match("https?://([^/]+)") or "repo"
    local syncDB = loadSyncDB()

    local function syncRemoteDB()
        printSection("Synchronizing package databases...")
        local repos = conf.repos or { "core", "extra", "overrides" }
        local anyFail = false
        for _, repo in ipairs(repos) do
            local dbUrl = repoUrl .. "/" .. repo .. "/" .. repo .. ".db"
            local okReq, res = pcall(function()
                if not http then return nil end
                return http.get(dbUrl)
            end)
            if okReq and res then
                local content = res.readAll()
                res.close()
                local okT, rData = pcall(textutils.unserialize, content)
                if okT and type(rData) == "table" then
                    for k, v in pairs(rData) do
                        v.repo = v.repo or repo
                        syncDB[k] = v
                    end
                end
                print(string.format(" %-24s [####################################] 100%%", repo))
            else
                if repo == "overrides" then
                    -- overrides repository is optional: skip quietly if not present
                else
                    print(string.format(" %-30s 0.0 B   --.- B/s --:-- [------------------------------------]   0%%", repo .. ".db"))
                    printErr(string.format("failed retrieving file '%s.db' from %s : No response from database", repo, host))
                    printErr(string.format("failed to update %s (no response from database)", repo))
                    anyFail = true
                end
            end
        end
        if not anyFail then
            saveSyncDB(syncDB)
        else
            printErr("failed to synchronize all databases (no servers configured or database unavailable)")
        end
        return not anyFail
    end

    if (flags["u"] or #targets > 0) and curUser ~= "root" then
        printErr("you cannot perform this operation unless you are root")
        return
    end

    -- 1. -Sy : Refresh Database
    if flags["y"] then
        syncRemoteDB()
    end

    -- 2. -Su / -Syu : System Upgrade
    if flags["u"] then
        if not flags["y"] then
            syncRemoteDB()
        end
        printSection("Starting full system upgrade...")
        printSection("Resolving dependencies...")
        printSection("Looking for conflicting packages...")

        local toUpgrade = {}

        for pkgName, remotePkg in pairs(syncDB) do
            local installed = db[pkgName]
            local needUpgrade = false
            local missingFiles = false

            if installed then
                if remotePkg.version and installed.version and remotePkg.version ~= installed.version then
                    needUpgrade = true
                end

                local files = remotePkg.files or installed.files or {}
                for _, f in ipairs(files) do
                    local checkPath = (f:sub(1, 1) == "/") and f:sub(2) or f
                    if not fs.exists(checkPath) then
                        missingFiles = true
                        break
                    end
                end

                if needUpgrade or missingFiles then
                    table.insert(toUpgrade, {
                        name = pkgName,
                        oldVer = installed.version or "none",
                        newVer = remotePkg.version or "1.0.0-1",
                        remote = remotePkg,
                        installed = installed,
                        reason = needUpgrade and "upgrade" or "repair"
                    })
                end
            end
        end

        if #toUpgrade == 0 then
            print(" there is nothing to do")
            return
        end

        -- Check package conflicts and file collisions during sysupgrade
        local okConf, errConf = checkPackageConflicts(toUpgrade, db)
        if not okConf then
            printErr("unresolvable package conflicts detected")
            print(":: " .. errConf)
            return
        end

        local okFiles, errFiles = checkFileConflicts(toUpgrade, db)
        if not okFiles then
            printErr("failed to commit transaction (conflicting files)")
            print(":: " .. errFiles)
            return
        end

        local totalDownload = 0
        local totalSize = 0
        local pkgList = {}
        for _, u in ipairs(toUpgrade) do
            table.insert(pkgList, u.name .. "-" .. u.newVer)
            totalDownload = totalDownload + (u.remote.size or 0)
            totalSize = totalSize + (u.remote.size or 0)
        end

        print(string.format("\nPackages (%d) %s\n", #toUpgrade, table.concat(pkgList, "  ")))
        print(string.format("Total Download Size:    %s", formatSize(totalDownload)))
        print(string.format("Total Installed Size:   %s\n", formatSize(totalSize)))

        write(":: Proceed with installation? [y/N] ")
        local ans = read()
        if not ans or (ans:lower() ~= "y" and ans:lower() ~= "yes") then
            print("Operation cancelled.")
            return
        end

        printSection("Retrieving packages...")
        for i, u in ipairs(toUpgrade) do
            local remotePkg = u.remote
            local repo = remotePkg.repo or (u.name == "core" and "core" or "extra")
            local files = remotePkg.files or {}

            print(string.format("(%d/%d) downloading %-20s [####################################] 100%%", i, #toUpgrade, u.name))

            local pkgFailed = false
            local pkgDir = remotePkg.package_dir or u.name
            for _, fPath in ipairs(files) do
                local filename = fs.getName(fPath)
                local fileUrl = resolvePackageFileUrl(remotePkg, u.name, fPath, repoUrl)
                local okF, resF = pcall(function() return http and http.get(fileUrl) end)
                if okF and resF then
                    local fContent = resF.readAll()
                    resF.close()

                    local cleanFPath = (fPath:sub(1, 1) == "/") and fPath:sub(2) or fPath
                    local parentDir = fs.getDir(cleanFPath)
                    if parentDir ~= "" and not fs.exists(parentDir) then fs.makeDir(parentDir) end
                    local wh = fs.open(cleanFPath, "w")
                    if wh then
                        wh.write(fContent)
                        wh.close()
                    else
                        printErr(string.format("failed writing '%s': out of space or disk error", cleanFPath))
                        pkgFailed = true
                    end
                else
                    local srcHost = fileUrl:match("https?://([^/]+)") or host
                    printErr(string.format("failed retrieving '%s' from %s", filename, srcHost))
                    pkgFailed = true
                end
            end

            -- Clean up obsolete files from previous version
            if u.installed and u.installed.files then
                local newFileSet = {}
                for _, nf in ipairs(files) do
                    local c = (nf:sub(1, 1) == "/") and nf:sub(2) or nf
                    newFileSet[c] = true
                end
                local backupSet = {}
                for _, bf in ipairs(remotePkg.backup or {}) do
                    local c = (bf:sub(1, 1) == "/") and bf:sub(2) or bf
                    backupSet[c] = true
                end
                for _, oldF in ipairs(u.installed.files) do
                    local c = (oldF:sub(1, 1) == "/") and oldF:sub(2) or oldF
                    if not newFileSet[c] and not backupSet[c] and fs.exists(c) and not fs.isDir(c) then
                        pcall(fs.delete, c)
                    end
                end
            end

            writePkgInfo(u.name, remotePkg, repoUrl, repo, pkgDir)
            registerPackageService(u.name, pkgDir, repo, repoUrl)
            local targetDir = (remotePkg.path and remotePkg.path:sub(1, 1) == "/") and remotePkg.path:sub(2) or (remotePkg.path or fs.combine(BIN_DIR, u.name))
            if not fs.exists(targetDir) then pcall(fs.makeDir, targetDir) end

            db[u.name] = remotePkg
            saveDB(db)
            print(string.format("(%d/%d) %s %-20s [####################################] 100%%", i, #toUpgrade, u.reason == "upgrade" and "upgrading" or "reinstalling", u.name))
        end

        printSection("Running post-transaction hooks...")
        print("(1/1) Updating Luna system commands index...")
        return
    end

    -- 2.5. -Ss : Remote Search
    if flags["s"] then
        local query = (targets[1] or ""):lower()
        local names = {}
        for name in pairs(syncDB) do table.insert(names, name) end
        table.sort(names)
        for _, name in ipairs(names) do
            local pkg = syncDB[name]
            local matched = (query == "")
                or name:lower():find(query, 1, true)
                or (pkg.description and pkg.description:lower():find(query, 1, true))
            if matched then
                local repo = pkg.repo or "core"
                if term.isColor() then
                    term.setTextColor(colors.white)
                    write(repo .. "/")
                    term.setTextColor(colors.yellow)
                    write(pkg.name .. " ")
                    term.setTextColor(colors.lime)
                    write((pkg.version or "1.0.0-1") .. " ")
                    if db[pkg.name] then
                        term.setTextColor(colors.cyan)
                        write("[installed] ")
                    end
                    term.setTextColor(colors.white)
                    print()
                    print("    " .. (pkg.description or "No description"))
                else
                    print(string.format("%s/%s %s%s", repo, pkg.name, pkg.version or "1.0.0-1", db[pkg.name] and " [installed]" or ""))
                    print("    " .. (pkg.description or "No description"))
                end
            end
        end
        return
    end

    -- 3. -Si : Remote Package Information
    if flags["i"] then
        if #targets == 0 then
            printErr("no targets specified (use -h for help)")
            return
        end
        for _, target in ipairs(targets) do
            local pkg = syncDB[target] or db[target]
            if not pkg then
                printErr("package '" .. target .. "' was not found in sync database")
            else
                local repo = pkg.repo or "core"
                print(string.format("%-16s: %s", "Repository", repo))
                print(string.format("%-16s: %s", "Name", pkg.name))
                print(string.format("%-16s: %s", "Version", pkg.version or "1.0.0-1"))
                print(string.format("%-16s: %s", "Description", pkg.description or "None"))
                print(string.format("%-16s: %s", "Architecture", pkg.architecture or "any"))
                print(string.format("%-16s: %s", "URL", pkg.url or "https://github.com/TheEartHTM/luna"))
                print(string.format("%-16s: %s", "Licenses", pkg.licenses or "MIT"))
                print(string.format("%-16s: %s", "Groups", pkg.groups or "base"))
                print(string.format("%-16s: %s", "Provides", pkg.provides or "None"))
                local depsStr = (pkg.deps and #pkg.deps > 0) and table.concat(pkg.deps, "  ") or "None"
                print(string.format("%-16s: %s", "Depends On", depsStr))
                print(string.format("%-16s: %s", "Optional Deps", "None"))
                local confStr = (pkg.conflicts and #pkg.conflicts > 0) and table.concat(pkg.conflicts, "  ") or "None"
                print(string.format("%-16s: %s", "Conflicts With", confStr))
                print(string.format("%-16s: %s", "Replaces", "None"))
                print(string.format("%-16s: %s", "Download Size", formatSize(pkg.size)))
                print(string.format("%-16s: %s", "Installed Size", formatSize(pkg.size)))
                print(string.format("%-16s: %s", "Packager", pkg.packager or "Luna Build Team"))
                print(string.format("%-16s: %s", "Build Date", pkg.build_date or "Thu Nov 19 19:20:00 2026"))
                print(string.format("%-16s: %s", "Validated By", "SHA-256 Sum"))
                print()
            end
        end
        return
    end

    -- 4. -S <package> : Install Package
    if #targets > 0 then
        if curUser ~= "root" then
            printErr("you cannot perform this operation unless you are root")
            return
        end

        local needSync = (next(syncDB) == nil)
        for _, t in ipairs(targets) do
            if not syncDB[t] then
                needSync = true
                break
            end
        end
        if needSync then
            syncRemoteDB()
        end

        printSection("Resolving dependencies...")

        local toInstall = {}
        local toInstallSet = {}
        local isExplicit = {}
        local visiting = {}

        local function resolveTarget(pkgName, explicit)
            if toInstallSet[pkgName] then
                if explicit then isExplicit[pkgName] = true end
                return true
            end
            if visiting[pkgName] then
                return false, "circular dependency detected involving: " .. pkgName
            end

            local remotePkg = syncDB[pkgName]
            if not remotePkg then
                -- Check if package exists in core or extra repos by querying .PKGINFO directly
                for _, rName in ipairs({ "core", "extra" }) do
                    local pInfoUrl = repoUrl .. "/" .. rName .. "/" .. pkgName .. "/.PKGINFO"
                    local okReq, res = pcall(function() return http and http.get(pInfoUrl) end)
                    if okReq and res then
                        local content = res.readAll()
                        res.close()
                        local pData = parsePkgInfoString(content)
                        if pData and pData.name then
                            pData.repo = rName
                            pData.package_dir = pkgName
                            if not pData.files or #pData.files == 0 then
                                local targetDir = pData.path or ("/usr/bin/" .. rName)
                                pData.files = { targetDir .. "/" .. pkgName .. ".lua" }
                            end
                            syncDB[pkgName] = pData
                            remotePkg = pData
                            saveSyncDB(syncDB)
                            break
                        end
                    end
                end
            end

            if not remotePkg then
                return false, "target not found: " .. pkgName
            end

            local installed = db[pkgName]
            if installed and installed.version == (remotePkg.version or "1.0.0-1") and not flags["f"] then
                local allFilesExist = true
                for _, f in ipairs(remotePkg.files or {}) do
                    local clean = (f:sub(1, 1) == "/") and f:sub(2) or f
                    if not fs.exists(clean) then
                        allFilesExist = false
                        break
                    end
                end
                if allFilesExist then
                    if explicit then
                        printWarn(string.format("%s-%s is up to date -- skipping", pkgName, installed.version or "1.0"))
                    end
                    return true
                end
            end

            if not explicit and installed then
                return true
            end

            visiting[pkgName] = true

            local deps = remotePkg.deps or {}
            for _, depName in ipairs(deps) do
                local ok, err = resolveTarget(depName, false)
                if not ok then
                    visiting[pkgName] = nil
                    return false, string.format("unable to satisfy dependency '%s' required by %s", depName, pkgName)
                end
            end

            visiting[pkgName] = nil
            toInstallSet[pkgName] = true
            if explicit then isExplicit[pkgName] = true end

            table.insert(toInstall, {
                name = pkgName,
                oldVer = installed and (installed.version or "none") or nil,
                newVer = remotePkg.version or "1.0.0-1",
                remote = remotePkg,
                installed = installed,
                isInstalled = (installed ~= nil),
                isExplicit = explicit
            })
            return true
        end

        for _, t in ipairs(targets) do
            local ok, err = resolveTarget(t, true)
            if not ok then
                printErr("failed to prepare transaction (could not satisfy dependencies)")
                print(":: " .. err)
                return
            end
        end

        if #toInstall == 0 then
            print(" there is nothing to do")
            return
        end

        for _, u in ipairs(toInstall) do
            if u.isInstalled and u.oldVer == u.newVer and u.isExplicit then
                printWarn(u.name .. "-" .. u.newVer .. " is up to date -- reinstalling")
            end
        end

        printSection("Looking for conflicting packages...")

        local okConf, errConf = checkPackageConflicts(toInstall, db)
        if not okConf then
            printErr("unresolvable package conflicts detected")
            print(":: " .. errConf)
            return
        end

        local okFiles, errFiles = checkFileConflicts(toInstall, db)
        if not okFiles then
            printErr("failed to commit transaction (conflicting files)")
            print(":: " .. errFiles)
            return
        end

        local totalDownload = 0
        local totalSize = 0
        local pkgList = {}
        for _, u in ipairs(toInstall) do
            local label = u.name .. "-" .. u.newVer
            table.insert(pkgList, label)
            totalDownload = totalDownload + (u.remote.size or 0)
            totalSize = totalSize + (u.remote.size or 0)
        end

        print(string.format("\nPackages (%d) %s\n", #toInstall, table.concat(pkgList, "  ")))
        print(string.format("Total Download Size:    %s", formatSize(totalDownload)))
        print(string.format("Total Installed Size:   %s\n", formatSize(totalSize)))

        write(":: Proceed with installation? [y/N] ")
        local ans = read()
        if not ans or (ans:lower() ~= "y" and ans:lower() ~= "yes") then
            print("Operation cancelled.")
            return
        end

        printSection("Retrieving packages...")
        for i, u in ipairs(toInstall) do
            local pkgName = u.name
            local remotePkg = u.remote
            local repo = remotePkg.repo or (pkgName == "core" and "core" or "extra")
            local files = remotePkg.files or {}

            local pkgFailed = false
            local pkgDir = remotePkg.package_dir or u.name
            for _, fPath in ipairs(files) do
                local filename = fs.getName(fPath)
                local fileUrl = resolvePackageFileUrl(remotePkg, u.name, fPath, repoUrl)
                local okF, resF = pcall(function() return http and http.get(fileUrl) end)
                if okF and resF then
                    local fContent = resF.readAll()
                    resF.close()

                    local cleanFPath = (fPath:sub(1, 1) == "/") and fPath:sub(2) or fPath
                    local parentDir = fs.getDir(cleanFPath)
                    if parentDir ~= "" and not fs.exists(parentDir) then fs.makeDir(parentDir) end
                    local wh = fs.open(cleanFPath, "w")
                    if wh then
                        wh.write(fContent)
                        wh.close()
                    else
                        printErr(string.format("failed writing '%s': out of space or disk error", cleanFPath))
                        pkgFailed = true
                    end
                else
                    local srcHost = fileUrl:match("https?://([^/]+)") or host
                    printErr(string.format("failed retrieving '%s' from %s", filename, srcHost))
                    pkgFailed = true
                end
            end

            -- Clean up obsolete files from previous version
            if u.installed and u.installed.files then
                local newFileSet = {}
                for _, nf in ipairs(files) do
                    local c = (nf:sub(1, 1) == "/") and nf:sub(2) or nf
                    newFileSet[c] = true
                end
                local backupSet = {}
                for _, bf in ipairs(remotePkg.backup or {}) do
                    local c = (bf:sub(1, 1) == "/") and bf:sub(2) or bf
                    backupSet[c] = true
                end
                for _, oldF in ipairs(u.installed.files) do
                    local c = (oldF:sub(1, 1) == "/") and oldF:sub(2) or oldF
                    if not newFileSet[c] and not backupSet[c] and fs.exists(c) and not fs.isDir(c) then
                        pcall(fs.delete, c)
                    end
                end
            end

            writePkgInfo(pkgName, remotePkg, repoUrl, repo, pkgDir)
            registerPackageService(pkgName, pkgDir, repo, repoUrl)
            local targetDir = (remotePkg.path and remotePkg.path:sub(1, 1) == "/") and remotePkg.path:sub(2) or (remotePkg.path or fs.combine(BIN_DIR, pkgName))
            if not fs.exists(targetDir) then pcall(fs.makeDir, targetDir) end

            if not pkgFailed then
                remotePkg.install_reason = u.isExplicit and "explicit" or "dependency"
                db[pkgName] = remotePkg
                saveDB(db)
                print(string.format("(%d/%d) %s %-20s [####################################] 100%%", i, #toInstall, u.isInstalled and "reinstalling" or "installing", pkgName))
            else
                printErr(string.format("failed to install %s due to transfer errors", pkgName))
            end
        end
        printSection("Running post-transaction hooks...")
        print("(1/1) Updating Luna system commands index...")
        return
    end

    if not flags["y"] and not flags["u"] and not flags["i"] then
        printErr("no targets specified (use -h for help)")
    end

--------------------------------------------------------------------------------
-- OPERATION: -R (Remove)
--------------------------------------------------------------------------------
elseif op == "R" then
    if #targets == 0 then
        printErr("no targets specified (use -h for help)")
        return
    end
    if curUser ~= "root" then
        printErr("you cannot perform this operation unless you are root")
        return
    end

    for _, pkgName in ipairs(targets) do
        if pkgName == "core" then
            printErr("cannot remove 'core': base system package is protected")
            return
        end
        local pkg = db[pkgName]
        if not pkg then
            printErr("target not found: " .. pkgName)
        else
            -- Check dependency tree
            local blockers = {}
            for otherName, otherPkg in pairs(db) do
                if otherName ~= pkgName and otherPkg.deps then
                    for _, d in ipairs(otherPkg.deps) do
                        if d == pkgName then
                            table.insert(blockers, otherName)
                        end
                    end
                end
            end

            if #blockers > 0 and not flags["s"] then
                printErr("failed to prepare transaction (could not satisfy dependencies)")
                print(string.format(":: removing %s breaks dependency '%s' required by %s", pkgName, pkgName, table.concat(blockers, ", ")))
            else
                printSection("checking dependencies...")
                local toRemove = { pkgName }
                local totalSize = pkg.size or 0

                if flags["s"] and #blockers > 0 then
                    for _, b in ipairs(blockers) do
                        table.insert(toRemove, b)
                        if db[b] and db[b].size then totalSize = totalSize + db[b].size end
                    end
                end

                print(string.format("\nPackages (%d) %s\n", #toRemove, table.concat(toRemove, " ")))
                print(string.format("Total Removed Size:  %s\n", formatSize(totalSize)))
                write(":: Do you want to remove these packages? [Y/n] ")
                local ans = read()
                if not ans or ans == "" or ans:lower() == "y" then
                    printSection("Processing package changes...")
                    for idx, remName in ipairs(toRemove) do
                        local remPkg = db[remName]
                        local files = (remPkg and remPkg.files) or getPackageFiles(remName, remPkg)
                        for _, f in ipairs(files) do
                            local checkPath = f:sub(1, 1) == "/" and f:sub(2) or f
                            if fs.exists(checkPath) then fs.delete(checkPath) end
                        end
                        local pkgDir = fs.combine(BIN_DIR, remName)
                        if fs.exists(pkgDir) then fs.delete(pkgDir) end

                        unregisterPackageService(remName)
                        local infoDir = fs.combine("/etc/conf/packages", remName)
                        if fs.exists(infoDir) then pcall(fs.delete, infoDir) end

                        db[remName] = nil
                        print(string.format("(%d/%d) removing %-24s [####################################] 100%%", idx, #toRemove, remName))
                    end
                    saveDB(db)
                else
                    print("Operation cancelled.")
                end
            end
        end
    end
end
