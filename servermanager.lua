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
    if fileExists("/proc/" .. pid) then
        return true, pid
    end

    return false, nil
end

-- Punch a hole in Kindle's iptables firewall for a port
function ServerManager:openFirewallPort(port)
    if not port or port <= 0 then return end
    self:closeFirewallPort(port)
    os.execute(string.format("iptables -I INPUT 1 -p tcp --dport %d -j ACCEPT 2>/dev/null", port))
    os.execute(string.format("iptables -I OUTPUT 1 -p tcp --sport %d -j ACCEPT 2>/dev/null", port))
    os.execute(string.format("iptables -I INPUT 1 -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null", port))
    os.execute(string.format("iptables -I OUTPUT 1 -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null", port))
end

-- Close hole in Kindle's iptables firewall for a port
function ServerManager:closeFirewallPort(port)
    if not port or port <= 0 then return end
    os.execute(string.format("iptables -D INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null", port))
    os.execute(string.format("iptables -D OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null", port))
    os.execute(string.format("iptables -D INPUT -p tcp --dport %d -j ACCEPT 2>/dev/null", port))
    os.execute(string.format("iptables -D OUTPUT -p tcp --sport %d -j ACCEPT 2>/dev/null", port))
end

-- Ensure host key exists or generate one on writable path
function ServerManager:ensureHostKey()
    local hostkey_candidates = {
        "/mnt/us/usbnet/etc/dropbear_rsa_host_key",
        "/mnt/base-us/usbnet/etc/dropbear_rsa_host_key",
        "/mnt/us/kmc/kpm/packages/dropbear-ssh/etc/dropbear_rsa_host_key",
        "/mnt/base-us/kmc/kpm/packages/dropbear-ssh/etc/dropbear_rsa_host_key",
        "/mnt/us/usbnetlite/etc/dropbear_rsa_host_key",
        "/mnt/base-us/usbnetlite/etc/dropbear_rsa_host_key",
        "/mnt/us/koreader/settings/SSH/dropbear_rsa_host_key",
        "/mnt/base-us/koreader/settings/SSH/dropbear_rsa_host_key",
        "/tmp/dropbear_rsa_host_key",
        "/etc/dropbear/dropbear_rsa_host_key",
    }
    for _, path in ipairs(hostkey_candidates) do
        if fileExists(path) then
            return path
        end
    end

    -- Try generating a host key in /tmp/dropbear_rsa_host_key using dropbearkey
    local keygen_candidates = {
        "./dropbearkey",
        "/mnt/us/koreader/dropbearkey",
        "/mnt/base-us/koreader/dropbearkey",
        "/mnt/us/usbnet/bin/dropbearkey",
        "/mnt/base-us/usbnet/bin/dropbearkey",
        "/mnt/us/kmc/kpm/packages/dropbear-ssh/bin/dropbearkey",
        "/mnt/base-us/kmc/kpm/packages/dropbear-ssh/bin/dropbearkey",
        "/mnt/us/usbnetlite/bin/dropbearkey",
        "/mnt/base-us/usbnetlite/bin/dropbearkey",
        "/usr/bin/dropbearkey",
        "/usr/sbin/dropbearkey",
        "dropbearkey",
    }
    for _, keygen in ipairs(keygen_candidates) do
        if fileExists(keygen) or keygen == "dropbearkey" then
            pcall(os.execute, string.format("chmod +x %s 2>/dev/null", keygen))
            local ok = os.execute(string.format("%s -t rsa -f /tmp/dropbear_rsa_host_key -s 2048 2>/dev/null", keygen))
            if ok == 0 and fileExists("/tmp/dropbear_rsa_host_key") then
                return "/tmp/dropbear_rsa_host_key"
            end
        end
    end

    return nil
end

-- Locate native Dropbear binary on Kindle
function ServerManager:findDropbear()
    local candidates = {
        "./dropbear",
        "/mnt/us/koreader/dropbear",
        "/mnt/base-us/koreader/dropbear",
        "/mnt/us/kmc/kpm/packages/dropbear-ssh/bin/dropbearmulti",
        "/mnt/base-us/kmc/kpm/packages/dropbear-ssh/bin/dropbearmulti",
        "/mnt/us/kmc/kpm/packages/dropbear-ssh/bin/dropbear",
        "/mnt/base-us/kmc/kpm/packages/dropbear-ssh/bin/dropbear",
        "/mnt/us/kmc/kpm/packages/dropbear-ssh/sbin/dropbear",
        "/mnt/us/usbnetlite/bin/dropbearmulti",
        "/mnt/base-us/usbnetlite/bin/dropbearmulti",
        "/mnt/us/usbnetlite/bin/dropbear",
        "/mnt/base-us/usbnetlite/bin/dropbear",
        "/mnt/us/usbnet/bin/dropbearmulti",
        "/mnt/base-us/usbnet/bin/dropbearmulti",
        "/mnt/us/usbnet/bin/dropbear",
        "/mnt/base-us/usbnet/bin/dropbear",
        "/mnt/us/extensions/usbnet/bin/dropbear",
        "/mnt/base-us/extensions/usbnet/bin/dropbear",
        "/usr/sbin/dropbear",
        "/usr/bin/dropbear",
        "/sbin/dropbear",
        "/bin/dropbear",
    }
    for _, path in ipairs(candidates) do
        if fileExists(path) then
            pcall(os.execute, string.format("chmod +x %s 2>/dev/null", path))
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
        "/mnt/base-us/usbnet/bin/sshd",
        "/mnt/us/extensions/usbnet/bin/sshd",
        "/mnt/base-us/extensions/usbnet/bin/sshd",
        "/usr/sbin/sshd",
        "/usr/bin/sshd",
    }
    for _, path in ipairs(candidates) do
        if fileExists(path) then
            pcall(os.execute, string.format("chmod +x %s 2>/dev/null", path))
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
    -- Check known PID files
    local pid_files = {
        self.ssh_pid_file,
        "/tmp/dropbear_koreader.pid",
        "/mnt/us/usbnetlite/etc/dropbear.pid",
        "/mnt/us/usbnet/etc/dropbear.pid",
        "/var/run/dropbear.pid",
        "/var/run/sshd.pid",
    }
    for _, pf in ipairs(pid_files) do
        local running, pid = self:isPidRunning(pf)
        if running then return true, pid end
    end

    -- Process check fallback
    local ok_h, h = pcall(io.popen, "pidof dropbear 2>/dev/null || pidof dropbearmulti 2>/dev/null || pgrep dropbear 2>/dev/null || pidof sshd 2>/dev/null")
    if ok_h and h then
        local p_str = h:read("*l")
        h:close()
        if p_str then
            local pid = tonumber(p_str:match("(%d+)"))
            if pid and pid > 1 and fileExists("/proc/" .. pid) then
                return true, pid
            end
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
        return false, "Neither Dropbear nor OpenSSH binary was found on Kindle.\nInstall Dropbear SSH (via KPM / KUAL) or USBNetwork."
    end

    local port = tonumber(self.settings:get("ssh_port")) or 2222
    self:openFirewallPort(port)

    local log_file = "/tmp/dropbear_run.log"
    pcall(os.remove, log_file)

    if dropbear then
        local run_cmd = dropbear
        if dropbear:match("dropbearmulti") then
            run_cmd = dropbear .. " dropbear"
        end

        local lib_dirs = {
            "/mnt/us/usbnet/lib",
            "/mnt/base-us/usbnet/lib",
            "/mnt/us/usbnetlite/bin",
            "/mnt/base-us/usbnetlite/bin",
            "/mnt/us/kmc/kpm/packages/dropbear-ssh/lib",
            "/mnt/base-us/kmc/kpm/packages/dropbear-ssh/lib",
        }
        local active_lib_dirs = {}
        for _, ld in ipairs(lib_dirs) do
            if fileExists(ld) then
                table.insert(active_lib_dirs, ld)
            end
        end
        local lib_env = ""
        if #active_lib_dirs > 0 then
            lib_env = "LD_LIBRARY_PATH=" .. table.concat(active_lib_dirs, ":") .. ":$LD_LIBRARY_PATH "
        end

        local hostkey = self:ensureHostKey()
        local hostkey_arg = hostkey and string.format("-r %s", hostkey) or ""

        local pass = self:getSshPassword()
        local pass_arg = ""
        if pass and #pass > 0 and (dropbear:match("kmc") or dropbear:match("usbnetlite")) then
            pass_arg = string.format("-Y '%s'", pass)
        end

        pcall(os.execute, "mkdir -p /mnt/us/koreader/settings/SSH /mnt/base-us/koreader/settings/SSH /tmp/dropbear 2>/dev/null")

        local cmd = string.format("%s%s -E -R %s -p 0.0.0.0:%d %s -K 60 -I 1800 -P %s >%s 2>&1 &",
            lib_env, run_cmd, hostkey_arg, port, pass_arg, self.ssh_pid_file, log_file)
        os.execute(cmd)
    else
        local cmd = string.format("%s -p %d -o PidFile=%s >%s 2>&1 &",
            sshd, port, self.ssh_pid_file, log_file)
        os.execute(cmd)
    end

    -- Settle time to allow daemon to fork and record PID
    os.execute("sleep 1")

    local verify_running, new_pid = self:isSshRunning()
    if verify_running then
        return true, new_pid
    else
        self:closeFirewallPort(port)
        local err_detail = ""
        if fileExists(log_file) then
            local f = io.open(log_file, "r")
            if f then
                local content = f:read("*a")
                f:close()
                if content and #content > 0 then
                    err_detail = content:gsub("^%s+", ""):gsub("%s+$", "")
                end
            end
        end
        if #err_detail > 0 then
            return false, err_detail
        else
            return false, "Failed to start native SSH daemon (process did not remain active)."
        end
    end
end

function ServerManager:stopSsh()
    local running, pid = self:isSshRunning()
    local port = tonumber(self.settings:get("ssh_port")) or 2222
    if running and pid then
        os.execute(string.format("kill %d 2>/dev/null", pid))
        os.execute("sleep 0.5")
        if fileExists("/proc/" .. pid) then
            os.execute(string.format("kill -9 %d 2>/dev/null", pid))
        end
    end
    os.execute("pkill -9 dropbear 2>/dev/null")
    self:closeFirewallPort(port)
    pcall(os.remove, self.ssh_pid_file)
    pcall(os.remove, "/tmp/dropbear_koreader.pid")
    pcall(os.remove, "/mnt/us/usbnetlite/etc/dropbear.pid")
    pcall(os.remove, "/mnt/us/usbnet/etc/dropbear.pid")
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
