--[[--
Daemon controller for Native High-Speed Servers (Dropbear / OpenSSH & Network Management).
Handles IP resolution, iptables firewall punch-through, and USBNetwork SSH daemons.
--]]--

local Device = require("device")
local lfs = require("libs/libkoreader-lfs")

local ServerManager = {}
ServerManager.__index = ServerManager

function ServerManager:new(settings)
    local self = setmetatable({}, ServerManager)
    self.settings = settings
    self.ssh_pid_file = "/tmp/nativeservers_ssh.pid"
    self.web_server = nil
    return self
end

function ServerManager:setWebServer(web_server)
    self.web_server = web_server
end

local function fileExists(path)
    if not path or #path == 0 then return false end
    local mode = lfs.attributes(path, "mode")
    return mode ~= nil
end

-- Resolve the live device IP address (Wi-Fi)
function ServerManager:getDeviceIp()
    -- Method 1: Ask KOReader's NetInfo FFI
    local ok_ni, NetInfo = pcall(require, "ffi/netinfo")
    if ok_ni and NetInfo then
        local ok, ni = pcall(function() return NetInfo:new() end)
        if ok and ni and ni.retrieve then
            local interfaces = ni:retrieve()
            for _, iface in ipairs(interfaces) do
                if iface.ipv4 and iface.name ~= "lo" and (iface.name:match("^wl") or iface.name:match("^wlan")) then
                    local ip = iface.ipv4
                    pcall(function() ni:free() end)
                    return ip
                end
            end
            for _, iface in ipairs(interfaces) do
                if iface.ipv4 and iface.name ~= "lo" then
                    local ip = iface.ipv4
                    pcall(function() ni:free() end)
                    return ip
                end
            end
            pcall(function() ni:free() end)
        end
    end

    -- Method 2: Shell query on wlan0 (Kindle standard)
    local ok_h, h = pcall(io.popen, "ip -4 addr show wlan0 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2")
    if ok_h and h then
        local ip = h:read("*l")
        h:close()
        if ip and #ip >= 7 then
            return ip:gsub("%s+", "")
        end
    end

    return "Offline / Not Connected"
end

-- Check if a process identified by PID file is actively running in the OS
function ServerManager:isPidRunning(pid_file)
    if not fileExists(pid_file) then
        return false, nil
    end

    local f = io.open(pid_file, "r")
    if not f then return false, nil end
    local pid_str = f:read("*l")
    f:close()

    local pid = tonumber(pid_str)
    if not pid or pid <= 1 then
        return false, nil
    end

    -- Direct /proc/<pid> check on Linux (fastest and 100% reliable)
    if fileExists("/proc/".. pid) then
        return true, pid
    end

    return false, nil
end

-- Punch a hole in Kindle's iptables firewall for a port
function ServerManager:openFirewallPort(port)
    if not port or port <= 0 then return end
    self:closeFirewallPort(port)
    os.execute(string.format("iptables -I INPUT 1 -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null", port))
    os.execute(string.format("iptables -I OUTPUT 1 -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null", port))
    os.execute(string.format("iptables -I INPUT 1 -p tcp --dport %d -j ACCEPT 2>/dev/null", port))
    os.execute(string.format("iptables -I OUTPUT 1 -p tcp --sport %d -j ACCEPT 2>/dev/null", port))
end

-- Close hole in Kindle's iptables firewall for a port
function ServerManager:closeFirewallPort(port)
    if not port or port <= 0 then return end
    os.execute(string.format("iptables -D INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null", port))
    os.execute(string.format("iptables -D OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null", port))
    os.execute(string.format("iptables -D INPUT -p tcp --dport %d -j ACCEPT 2>/dev/null", port))
    os.execute(string.format("iptables -D OUTPUT -p tcp --sport %d -j ACCEPT 2>/dev/null", port))
end

-- Locate native Dropbear binary on Kindle
function ServerManager:findDropbear()
    local candidates = {
        "./dropbear",
        "/mnt/us/koreader/dropbear",
        "/mnt/base-us/koreader/dropbear",
        "/mnt/us/kmc/kpm/packages/dropbear-ssh/bin/dropbearmulti",
        "/mnt/us/kmc/kpm/packages/dropbear-ssh/bin/dropbear",
        "/mnt/us/kmc/kpm/packages/dropbear-ssh/sbin/dropbear",
        "/mnt/base-us/kmc/kpm/packages/dropbear-ssh/bin/dropbearmulti",
        "/mnt/us/usbnetlite/bin/dropbearmulti",
        "/mnt/us/usbnetlite/bin/dropbear",
        "/mnt/base-us/usbnetlite/bin/dropbearmulti",
        "/mnt/base-us/usbnetlite/bin/dropbear",
        "/mnt/us/usbnet/bin/dropbearmulti",
        "/mnt/us/usbnet/bin/dropbear",
        "/mnt/base-us/usbnet/bin/dropbear",
        "/mnt/us/extensions/usbnet/bin/dropbear",
        "/mnt/base-us/extensions/usbnet/bin/dropbear",
        "/usr/sbin/dropbear",
        "/usr/bin/dropbear",
    }
    for _, path in ipairs(candidates) do
        if fileExists(path) then
            return path
        end
    end
    if os.execute("which dropbear >/dev/null 2>&1") == 0 then
        return "dropbear"
    end
    return nil
end

-- Read saved SSH password if present (from dropbear-ssh / usbnetlite / kpm)
function ServerManager:getSshPassword()
    local pass_paths = {
        "/mnt/us/kmc/kpm/packages/dropbear-ssh/etc/ssh_password",
        "/mnt/us/kmc/kpm/packages/dropbear-ssh/config/password",
        "/mnt/us/usbnetlite/etc/ssh_password",
        "/mnt/us/usbnet/etc/ssh_password",
    }
    for _, p in ipairs(pass_paths) do
        if fileExists(p) then
            local f = io.open(p, "r")
            if f then
                local pass = f:read("*l")
                f:close()
                if pass and #pass > 0 then
                    return pass:gsub("%s+", "")
                end
            end
        end
    end
    return nil
end

-- Locate native OpenSSH binary on Kindle
function ServerManager:findOpenSsh()
    local candidates = {
        "/mnt/us/usbnet/bin/sshd",
        "/mnt/us/extensions/usbnet/bin/sshd",
        "/usr/sbin/sshd",
        "/usr/bin/sshd",
    }
    for _, path in ipairs(candidates) do
        if fileExists(path) then
            return path
        end
    end
    if os.execute("which sshd >/dev/null 2>&1") == 0 then
        return "sshd"
    end
    return nil
end

--------------------------------------------------------------------------------
-- NATIVE SSH / SFTP DAEMON (USBNetwork Dropbear / OpenSSH)
--------------------------------------------------------------------------------

function ServerManager:isSshRunning()
    -- Check local PID
    local running, pid = self:isPidRunning(self.ssh_pid_file)
    if running then return true, pid end

    -- Check dropbear-ssh / usbnetlite PID
    local lite_pid_file = "/mnt/us/usbnetlite/etc/dropbear.pid"
    if fileExists(lite_pid_file) then
        local r, p = self:isPidRunning(lite_pid_file)
        if r then return true, p end
    end

    -- Process check fallback
    local ok_h, h = pcall(io.popen, "pidof dropbear 2>/dev/null || pgrep dropbear 2>/dev/null")
    if ok_h and h then
        local p_str = h:read("*l")
        h:close()
        local p = tonumber(p_str)
        if p and p > 1 then
            return true, p
        end
    end

    return false, nil
end

function ServerManager:startSsh()
    local running, pid = self:isSshRunning()
    if running then return true, pid end

    local dropbear = self:findDropbear()
    local sshd = not dropbear and self:findOpenSsh()

    if not dropbear and not sshd then
        return false, "Neither Dropbear nor OpenSSH was found on Kindle.\nInstall Dropbear SSH or USBNetwork."
    end

    local port = tonumber(self.settings:get("ssh_port")) or 2222
    if fileExists("/mnt/us/usbnetlite/bin/dropbearmulti") and (port == 2222 or not port) then
        port = 2022
        self.settings:set("ssh_port", 2022)
    end
    self:openFirewallPort(port)

    if dropbear then
        local run_cmd = dropbear:match("dropbearmulti") and (dropbear .. "dropbear") or dropbear
        local lib_env = ""
        if fileExists("/mnt/us/usbnetlite/bin/libcrypt.so.1") then
            lib_env = "LD_LIBRARY_PATH=/mnt/us/usbnetlite/bin "
        end

        local pass = self:getSshPassword()
        local pass_arg = (pass and #pass > 0) and string.format("-Y '%s'", pass) or ""
        local pid_file = dropbear:match("usbnetlite") and "/mnt/us/usbnetlite/etc/dropbear.pid" or self.ssh_pid_file

        local cmd = string.format("%ssetsid %s -R -p 0.0.0.0:%d %s -K 60 -I 1800 -P %s </dev/null >/tmp/dropbear_run.log 2>&1 &",
            lib_env, run_cmd, port, pass_arg, pid_file)
        os.execute(cmd)
    else
        local cmd = string.format("%s -p %d -o PidFile=%s >/dev/null 2>&1",
            sshd, port, self.ssh_pid_file)
        os.execute(cmd)
    end

    -- Settle time to allow daemon to fork and record PID
    os.execute("sleep 1")

    local verify_running, new_pid = self:isSshRunning()
    if verify_running then
        return true, new_pid
    else
        self:closeFirewallPort(port)
        return false, "Failed to start native SSH daemon."
    end
end

function ServerManager:stopSsh()
    local running, pid = self:isSshRunning()
    local port = tonumber(self.settings:get("ssh_port")) or 2022
    if running and pid then
        os.execute(string.format("kill %d 2>/dev/null", pid))
        os.execute("sleep 1")
        if fileExists("/proc/".. pid) then
            os.execute(string.format("kill -9 %d 2>/dev/null", pid))
        end
    end
    self:closeFirewallPort(port)
    pcall(os.remove, self.ssh_pid_file)
    pcall(os.remove, "/mnt/us/usbnetlite/etc/dropbear.pid")
    return true
end

--------------------------------------------------------------------------------
-- AGGREGATE & LIFECYCLE HELPERS
--------------------------------------------------------------------------------

function ServerManager:getActiveCount()
    local count = 0
    if self.web_server and self.web_server:isRunning() then count = count + 1 end
    if self:isSshRunning() then count = count + 1 end
    return count
end

function ServerManager:stopAll()
    if self.web_server then
        self.web_server:stop()
    end
    self:stopSsh()
end

return ServerManager
