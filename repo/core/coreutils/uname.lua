-- uname - Print system information
local args = { ... }
local flag = args[1] or "-s"

local osName = "Luna OS"
local release = "0.2"
local version = "6.1.0-luna"
local arch = "cc:craftos"

if flag == "-a" or flag == "--all" then
    print(string.format("%s %s %s %s %s", osName, _G.SYSTEM_NAME or "luna", release, version, arch))
elseif flag == "-r" or flag == "--kernel-release" then
    print(release)
elseif flag == "-v" or flag == "--kernel-version" then
    print(version)
elseif flag == "-m" or flag == "--machine" then
    print(arch)
elseif flag == "-n" or flag == "--nodename" then
    print(_G.SYSTEM_NAME or "luna")
else
    print(osName)
end
