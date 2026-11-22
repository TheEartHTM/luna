-- curl - Command-line tool for transferring data with URLs in Luna OS
local term = term
local colors = colors
local isColor = term.isColor and term.isColor()

if not http then
    printError("curl: (1) Protocol 'http' not supported: http API is disabled in ComputerCraft")
    return 1
end

-- Base64 encoder for HTTP Basic Authentication
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64Encode(data)
    local out = {}
    local len = #data
    for i = 1, len, 3 do
        local b1 = data:byte(i)
        local b2 = data:byte(i + 1) or 0
        local b3 = data:byte(i + 2) or 0
        local n = (b1 * 65536) + (b2 * 256) + b3
        table.insert(out, b64chars:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1))
        table.insert(out, b64chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1))
        table.insert(out, (i + 1 <= len) and b64chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "=")
        table.insert(out, (i + 2 <= len) and b64chars:sub(n % 64 + 1, n % 64 + 1) or "=")
    end
    return table.concat(out)
end

-- Format bytes into human readable format
local function formatBytes(bytes)
    local num = tonumber(bytes) or 0
    if num >= 1024 * 1024 then
        return string.format("%.2f MB", num / (1024 * 1024))
    elseif num >= 1024 then
        return string.format("%.1f KB", num / 1024)
    else
        return string.format("%d B", num)
    end
end

-- Extract filename from URL
local function extractFilename(url)
    local clean = url:match("^([^?#]+)") or url
    local name = clean:match("([^/]+)$")
    if not name or name == "" then
        name = "index.html"
    end
    return name
end

-- Parse command line arguments
local args = { ... }
local opts = {
    url = nil,
    output = nil,
    remoteName = false,
    silent = false,
    showError = false,
    includeHeaders = false,
    headOnly = false,
    headers = {},
    data = nil,
    method = nil,
    location = true,
    user = nil,
    timeout = 15,
    fail = false,
    verbose = false
}

local i = 1
while i <= #args do
    local a = args[i]
    if a == "-h" or a == "--help" then
        print("Usage: curl [options...] <url>")
        print("Options:")
        print("  -o, --output <file>     Write to file instead of stdout")
        print("  -O, --remote-name       Write output to file named like remote file")
        print("  -s, --silent            Silent mode (no progress or status)")
        print("  -S, --show-error        Show error even when -s is used")
        print("  -i, --include           Include HTTP response headers in output")
        print("  -I, --head              Show document info / headers only (HEAD)")
        print("  -H, --header <header>   Pass custom header (e.g. 'Key: Value')")
        print("  -d, --data <data>       HTTP POST data")
        print("  -X, --request <method>  Specify request method (GET, POST, HEAD, etc.)")
        print("  -L, --location          Follow redirects (default: on)")
        print("  -u, --user <user:pass>  Server user and password for Basic Auth")
        print("  -m, --max-time <sec>    Maximum time allowed for the transfer")
        print("  -f, --fail              Fail silently on HTTP errors (>= 400)")
        print("  -v, --verbose           Make the operation more talkative")
        print("  -k, --insecure          Allow insecure connections (ignored)")
        print("  -h, --help              This help text")
        return 0
    elseif a == "-o" or a == "--output" then
        i = i + 1
        opts.output = args[i]
    elseif a == "-O" or a == "--remote-name" then
        opts.remoteName = true
    elseif a == "-s" or a == "--silent" then
        opts.silent = true
    elseif a == "-S" or a == "--show-error" then
        opts.showError = true
    elseif a == "-i" or a == "--include" then
        opts.includeHeaders = true
    elseif a == "-I" or a == "--head" then
        opts.headOnly = true
        opts.method = "HEAD"
    elseif a == "-H" or a == "--header" then
        i = i + 1
        local hdr = args[i]
        if hdr then
            local k, v = hdr:match("^([^:]+):%s*(.*)$")
            if k and v then
                opts.headers[k] = v
            end
        end
    elseif a == "-d" or a == "--data" then
        i = i + 1
        opts.data = args[i]
        if not opts.method then opts.method = "POST" end
    elseif a == "-X" or a == "--request" then
        i = i + 1
        if args[i] then opts.method = args[i]:upper() end
    elseif a == "-L" or a == "--location" then
        opts.location = true
    elseif a == "-u" or a == "--user" then
        i = i + 1
        opts.user = args[i]
    elseif a == "-m" or a == "--max-time" then
        i = i + 1
        opts.timeout = tonumber(args[i]) or 15
    elseif a == "-f" or a == "--fail" then
        opts.fail = true
    elseif a == "-v" or a == "--verbose" then
        opts.verbose = true
    elseif a == "-k" or a == "--insecure" then
        -- Compatibility flag
    elseif not a:find("^-") and not opts.url then
        opts.url = a
    end
    i = i + 1
end

if not opts.url then
    printError("curl: try 'curl --help' for more information")
    return 2
end

-- Normalize URL
local url = opts.url
if not url:find("^https?://") then
    url = "http://" .. url
end

-- Default method and headers
if not opts.method then
    opts.method = opts.data and "POST" or "GET"
end

if not opts.headers["User-Agent"] and not opts.headers["user-agent"] then
    opts.headers["User-Agent"] = "curl/8.4.0 (Luna OS)"
end

if opts.data and not opts.headers["Content-Type"] and not opts.headers["content-type"] then
    opts.headers["Content-Type"] = "application/x-www-form-urlencoded"
end

if opts.user then
    opts.headers["Authorization"] = "Basic " .. base64Encode(opts.user)
end

-- Determine output destination
local targetFile = nil
if opts.output then
    targetFile = opts.output
elseif opts.remoteName then
    targetFile = extractFilename(url)
end

local resolvedTarget = targetFile and shell.resolve(targetFile) or nil

-- Verbose output
if opts.verbose then
    print("* Connecting to " .. url .. " ...")
    print(string.format("> %s %s HTTP/1.1", opts.method, url))
    for k, v in pairs(opts.headers) do
        print(string.format("> %s: %s", k, v))
    end
    print("> ")
end

-- Download notification (when saving to file and not silent)
if targetFile and not opts.silent then
    if isColor then term.setTextColor(colors.cyan or colors.lightBlue) end
    print(string.format(":: Downloading %s -> %s", url, targetFile))
    if isColor then term.setTextColor(colors.white) end
end

-- Send request
local reqOptions = {
    url = url,
    headers = opts.headers,
    method = opts.method,
    redirect = opts.location,
    timeout = opts.timeout,
    binary = true
}

local res, errStr, errHandle
if opts.data then
    reqOptions.body = opts.data
    res, errStr, errHandle = http.post(reqOptions)
else
    res, errStr, errHandle = http.get(reqOptions)
end

local handle = res or errHandle
if not handle then
    if not opts.silent or opts.showError then
        printError(string.format("curl: (6) Could not transfer: %s", tostring(errStr or "Connection failed")))
    end
    return 6
end

-- Inspect response
local code, status = handle.getResponseCode()
code = tonumber(code) or 200
local respHeaders = handle.getResponseHeaders() or {}

if opts.verbose then
    print(string.format("< HTTP/1.1 %d %s", code, tostring(status or "OK")))
    for k, v in pairs(respHeaders) do
        print(string.format("< %s: %s", k, v))
    end
    print("< ")
end

-- Check HTTP error with -f / --fail
if opts.fail and code >= 400 then
    handle.close()
    if not opts.silent or opts.showError then
        printError(string.format("curl: (22) The requested URL returned error: %d", code))
    end
    return 22
end

-- Handle -I / --head
if opts.headOnly then
    print(string.format("HTTP/1.1 %d %s", code, tostring(status or "OK")))
    for k, v in pairs(respHeaders) do
        print(string.format("%s: %s", k, v))
    end
    handle.close()
    return 0
end

-- Handle -i / --include headers
if opts.includeHeaders then
    print(string.format("HTTP/1.1 %d %s", code, tostring(status or "OK")))
    for k, v in pairs(respHeaders) do
        print(string.format("%s: %s", k, v))
    end
    print("")
end

-- Output to file or stdout
if resolvedTarget then
    local h, fErr = fs.open(resolvedTarget, "wb")
    if not h then
        handle.close()
        printError(string.format("curl: (23) Failed to open output file: %s", tostring(fErr)))
        return 23
    end

    local rawLen = respHeaders["Content-Length"] or respHeaders["content-length"]
    local totalLen = rawLen and tonumber(rawLen)
    local downloaded = 0
    local chunkSize = 16 * 1024
    local lastYield = os.clock()
    local lastDraw = 0

    local function drawProgress(force)
        if opts.silent then return end
        local now = os.clock()
        if not force and (now - lastDraw < 0.1) then return end
        lastDraw = now

        local w, _ = term.getSize()
        local pct = (totalLen and totalLen > 0) and math.floor((downloaded / totalLen) * 100) or nil
        local curStr = formatBytes(downloaded)
        local totStr = totalLen and (" / " .. formatBytes(totalLen)) or ""
        local pctStr = pct and string.format("%3d%%", pct) or " --%"
        local info = string.format(" %s%s %s", curStr, totStr, pctStr)

        local barWidth = math.max(6, w - #info - 4)
        local filled = pct and math.floor(barWidth * math.min(100, pct) / 100) or 0
        local bar = "[" .. string.rep("=", math.max(0, filled - 1)) .. (filled > 0 and ">" or "") .. string.rep(" ", barWidth - filled) .. "]"

        local x, y = term.getCursorPos()
        term.setCursorPos(1, y)
        term.clearLine()
        if isColor then term.setTextColor(colors.cyan or colors.lightBlue) end
        term.write(bar)
        if isColor then term.setTextColor(colors.white) end
        term.write(info)
    end

    drawProgress(true)

    while true do
        local chunk = handle.read(chunkSize)
        if not chunk or #chunk == 0 then break end
        h.write(chunk)
        downloaded = downloaded + #chunk
        drawProgress(false)
        if os.clock() - lastYield > 0.1 then
            if sleep then sleep(0) end
            lastYield = os.clock()
        end
    end
    handle.close()
    h.close()

    drawProgress(true)
    if not opts.silent then
        print("")
        if isColor then term.setTextColor(colors.green or colors.lime) end
        print(string.format("[  OK  ] Downloaded %s successfully (%s).", targetFile, formatBytes(downloaded)))
        if isColor then term.setTextColor(colors.white) end
    end
else
    -- Output directly to stdout (supports pipes)
    local body = handle.readAll() or ""
    handle.close()
    io.write(body)
    io.flush()
end

return 0
