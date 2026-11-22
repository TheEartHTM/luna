-- play - Luna OS Audio Player for CEE Electric Speaker and CC Speakers
local term = term
local colors = colors
local isColor = term.isColor and term.isColor()

-- Load audio library
local sound = nil
if fs and fs.exists and fs.exists("/usr/lib/sound.lua") then
    local fn, err = loadfile("/usr/lib/sound.lua")
    if fn then sound = fn() end
end
if not sound then
    local ok, mod = pcall(require, "sound")
    if ok then sound = mod end
end

if not sound then
    printError("play: sound library (/usr/lib/sound.lua) not found")
    return
end

local args = { ... }
if #args == 0 or args[1] == "-h" or args[1] == "--help" then
    print("usage: play <file | sound> [volume]")
    print("       play stop")
    print("       play status")
    print("options:")
    print("  -v, --volume <0.0-1.0>   playback volume (default 1.0)")
    print("  -s, --sound <mc_sound>   play Minecraft sound event")
    print("  -d, --dev <speaker>      target speaker (/dev/speaker0 or side)")
    print("  -w, --wait               wait until playback finishes")
    print("  -h, --help               show this help message")
    return
end

-- Command: play stop
if args[1] == "stop" then
    sound.stop()
    if isColor then term.setTextColor(colors.green or colors.lime) end
    print(":: Playback stopped on all speakers.")
    if isColor then term.setTextColor(colors.white) end
    return
end

-- Command: play status
if args[1] == "status" then
    local speakers = sound.getSpeakers()
    if #speakers == 0 then
        if isColor then term.setTextColor(colors.yellow) end
        print(":: No speaker devices detected.")
        if isColor then term.setTextColor(colors.white) end
        return
    end

    print(":: Detected Audio Hardware:")
    for _, spk in ipairs(speakers) do
        local playing = sound.isPlaying(spk.name)
        local hasPwr = sound.hasPower(spk.name)
        local pwrStr = spk.isCee and (hasPwr and " [POWER: OK]" or " [POWER: NO POWER]") or ""
        local stStr = playing and "PLAYING" or "IDLE"

        if isColor then term.setTextColor(colors.cyan) end
        io.write(string.format("  %-15s ", spk.dev))
        if isColor then term.setTextColor(colors.white) end
        io.write(string.format("(%-12s on %-7s) ", spk.type, spk.bus))

        if isColor then
            if playing then term.setTextColor(colors.green)
            else term.setTextColor(colors.lightGray or colors.gray) end
        end
        io.write(stStr)

        if isColor then
            if hasPwr then term.setTextColor(colors.green)
            else term.setTextColor(colors.red) end
        end
        io.write(pwrStr .. "\n")
        if isColor then term.setTextColor(colors.white) end
    end
    return
end

-- Parse options
local targetDev = nil
local volume = 1.0
local waitPlayback = false
local isMcSound = false
local targetFile = nil

local idx = 1
while idx <= #args do
    local a = args[idx]
    if a == "-d" or a == "--dev" or a == "--device" then
        idx = idx + 1
        targetDev = args[idx]
    elseif a == "-v" or a == "--volume" then
        idx = idx + 1
        volume = tonumber(args[idx]) or 1.0
    elseif a == "-w" or a == "--wait" then
        waitPlayback = true
    elseif a == "-s" or a == "--sound" then
        isMcSound = true
        idx = idx + 1
        targetFile = args[idx]
    elseif not targetFile then
        targetFile = a
    elseif not volume or volume == 1.0 then
        local num = tonumber(a)
        if num then volume = num end
    end
    idx = idx + 1
end

if not targetFile then
    printError("play: no audio file or sound specified")
    return
end

-- Resolve speaker
local spk, err = sound.getSpeaker(targetDev)
if not spk then
    printError("play: " .. tostring(err))
    return
end

-- Check power for CEE Electric Speaker
if spk.isCee and spk.wrap.hasPower and not spk.wrap.hasPower() then
    if isColor then term.setTextColor(colors.yellow) end
    print("[WARN] CEE Electric Speaker (" .. spk.dev .. ") has no electrical power!")
    if isColor then term.setTextColor(colors.white) end
end

-- Resolve file path if relative
local fullPath = targetFile
if not isMcSound and fs.exists(shell.resolve(targetFile)) then
    fullPath = shell.resolve(targetFile)
end

-- Detect audio format
local format = "Audio"
if isMcSound or targetFile:find("^minecraft:") then
    format = "Minecraft Sound Event"
else
    local ext = fullPath:match("%.([%a%d]+)$")
    if ext then
        format = ext:upper()
    end
end

-- Print playback info
if isColor then term.setTextColor(colors.cyan or colors.lightBlue) end
print(":: Audio Playback")
if isColor then term.setTextColor(colors.white) end
print(string.format("   File/Sound: %s", targetFile))
print(string.format("   Format:     %s", format))
print(string.format("   Speaker:    %s (%s on %s)", spk.dev, spk.type, spk.bus))
print(string.format("   Volume:     %d%%", math.floor(volume * 100)))

-- Start playback
local ok, playErr
if isMcSound then
    ok, playErr = sound.playSound(targetFile, volume, 1.0, spk.name)
else
    ok, playErr = sound.play(fullPath, volume, spk.name)
end

if not ok then
    printError("play: playback failed: " .. tostring(playErr))
    return
end

if isColor then term.setTextColor(colors.green or colors.lime) end
print("[  OK  ] Playback started successfully.")
if isColor then term.setTextColor(colors.white) end

-- Handle wait mode or monitoring
if waitPlayback or (spk.isCee and spk.wrap.speakIsPlaying) then
    print("Press 'q' or 'Ctrl+C' to stop playback.")
    local timerId = os.startTimer(0.5)
    while true do
        local event, p1 = os.pullEvent()
        if event == "timer" and p1 == timerId then
            if not sound.isPlaying(spk.name) then
                break
            end
            timerId = os.startTimer(0.5)
        elseif event == "key" then
            if p1 == keys.q or p1 == keys.x then
                sound.stop(spk.name)
                print("\n:: Playback stopped by user.")
                break
            end
        elseif event == "terminate" then
            sound.stop(spk.name)
            print("\n:: Playback aborted.")
            break
        end
    end
end
