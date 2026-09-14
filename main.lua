--[[--
Native High-Speed Servers Controller for KOReader on Jailbroken Kindle.
Provides one-tap controls for WebDAV & Mobile Web Manager (browser upload + code editor)
and native USBNetwork SSH / SFTP daemon (Dropbear).
--]]--

local _ = require("gettext")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

-- Submodule loaders
local plugin_dir = debug.getinfo(1, "S").source:match("@?(.*[/\\])") or ""
local Settings, ServerManager, WebServer
local ok, mod

ok, mod = pcall(dofile, plugin_dir .. "settings.lua")
if ok then Settings = mod end

ok, mod = pcall(dofile, plugin_dir .. "servermanager.lua")
if ok then ServerManager = mod end

ok, mod = pcall(dofile, plugin_dir .. "webserver.lua")
if ok then WebServer = mod end

local NativeServers = WidgetContainer:extend{
    name = "nativeservers",
    is_doc_only = false,
}


function NativeServers:onDispatcherRegisterActions()
    Dispatcher:registerAction("nativeservers", {
        category = "none",
        event = "ShowNativeServers",
        title = _("Native Servers"),
        general = true,
    })
end

function NativeServers:onShowNativeServers()
    local Menu = require("ui/widget/menu")
    local menu = Menu:new{
        title = _("Native Servers"),
        item_table = self:getSubMenuItems(),
        is_borderless = true,
    }
    UIManager:show(menu)
end

function NativeServers:init()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    if Settings then
        self.settings = Settings:new()
    end
    if ServerManager and self.settings then
        self.manager = ServerManager:new(self.settings)
    end
    if WebServer and self.settings and self.manager then
        self.web = WebServer:new(self.settings, self.manager)
        self.manager:setWebServer(self.web)
    end

    self.standby_prevented = false
    self:updateStandbyState()
end

-- Manage KOReader power saving lock during file transfers
function NativeServers:updateStandbyState()
    if not self.manager or not self.settings then return end

    local has_active = self.manager:getActiveCount() > 0
    local should_prevent = has_active and self.settings:get("prevent_standby")

    if should_prevent and not self.standby_prevented then
        pcall(function() UIManager:preventStandby() end)
        self.standby_prevented = true
    elseif not should_prevent and self.standby_prevented then
        pcall(function() UIManager:allowStandby() end)
        self.standby_prevented = false
    end
end

-- Lifecycle cleanup
function NativeServers:onClose()
    if self.standby_prevented then
        pcall(function() UIManager:allowStandby() end)
        self.standby_prevented = false
    end

    if self.settings and self.settings:get("auto_stop_on_exit") and self.manager then
        self.manager:stopAll()
    end
end

function NativeServers:onExit()
    self:onClose()
end

function NativeServers:onSuspend()
    if self.settings and self.settings:get("auto_stop_on_exit") and self.manager then
        self.manager:stopAll()
        self:updateStandbyState()
    end
    return false
end

-- Registration to KOReader Main Menu
function NativeServers:addToMainMenu(menu_items)
    menu_items.nativeservers = {
        text = _("Wireless File Manager & Servers"),
        sorting_hint = "more_tools",
        sub_item_table = self:getSubMenuItems(),
    } end

function NativeServers:getSubMenuItems()
    local self_ref = self

    if not self.manager or not self.settings or not self.web then
        return {
            {
                text = _("Plugin failed to load submodules"),
                help_text = _("Check settings.lua, servermanager.lua, and webserver.lua in nativeservers.koplugin/"),
                enabled = false,
            },
        } end

    return {
        -- Status & Network Summary
        {
            text_func = function()
                local ip = self_ref.manager:getDeviceIp()
                local count = self_ref.manager:getActiveCount()
                return string.format(_("Wi-Fi IP: %s (Active Servers: %d)"), ip, count)
            end,
            help_text = _("Shows current Wi-Fi IP and running servers. Tap to refresh."),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end,
        },

        ------------------------------------------------------------------------
        -- 1. WEBDAV & MOBILE WEB FILE MANAGER (Zero Dependencies, Works Everywhere)
        ------------------------------------------------------------------------
        {
            text_func = function()
                local running = self_ref.web:isRunning()
                local port = self_ref.settings:get("web_port")
                return string.format(_("WebDAV & Mobile Web Manager (%s)"), running and string.format(_("RUNNING :%d"), port) or _("Stopped"))
            end,
            sub_item_table = {
                {
                    text = _("Toggle Web Manager (Start / Stop)"),
                    checked_func = function() return self_ref.web:isRunning() end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local running = self_ref.web:isRunning()
                        if running then
                            self_ref.web:stop()
                            self_ref:updateStandbyState()
                            UIManager:show(InfoMessage:new{
                                text = _("Web Manager & WebDAV stopped."),
                                timeout = 2,
                            })
                        else
                            local ok_start, err = self_ref.web:start()
                            self_ref:updateStandbyState()
                            if ok_start then
                                local ip = self_ref.manager:getDeviceIp()
                                local port = self_ref.settings:get("web_port")
                                UIManager:show(InfoMessage:new{
                                    text = string.format(_("Web Manager is RUNNING!\n\n Mobile Browser (Safari/Chrome):\nhttp://%s:%d/\n\n iOS Files App:\nConnect to Server -> http://%s:%d/\n\n(Transfer books & edit code in browser!)"),
                                        ip, port, ip, port),
                                    timeout = 8,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    icon = "notice-warning",
                                    text = string.format(_("Failed to start Web Manager:\n%s"), tostring(err)),
                                    timeout = 4,
                                })
                            end
                        end
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
                {
                    text = _("Show Connection Info & Mobile Guide"),
                    callback = function()
                        local ip = self_ref.manager:getDeviceIp()
                        local port = self_ref.settings:get("web_port")
                        local running = self_ref.web:isRunning()
                        local msg
                        if running then
                            msg = string.format(_("Web Manager is ACTIVE on port %d.\n\n1. From Phone / PC Browser:\nOpen: http://%s:%d/\n(Browse folders, drag-and-drop books, edit code)\n\n2. From iPhone Files App:\nFiles -> '...' -> Connect to Server -> http://%s:%d/\n\n3. From Android:\nSolid Explorer / CX File Explorer -> Add WebDAV"),
                                port, ip, port, ip, port)
                        else
                            msg = string.format(_("Web Manager is STOPPED.\n\nWhen started, connect via phone/PC browser or iOS Files at:\nhttp://%s:%d/"),
                                ip, port)
                        end
                        UIManager:show(InfoMessage:new{ text = msg, timeout = 9 })
                    end,
                },
                {
                    text_func = function()
                        return string.format(_("Set Port (Current: %d)"), self_ref.settings:get("web_port"))
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local dialog
                        dialog = InputDialog:new{
                            title = _("Enter Web Server Port"),
                            input = tostring(self_ref.settings:get("web_port")),
                            type = "number",
                            buttons = {
                                {
                                    { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                                    {
                                        text = _("Save"),
                                        is_enter_default = true,
                                        callback = function()
                                            local val = tonumber(dialog:getInputText())
                                            UIManager:close(dialog)
                                            if val and val >= 80 and val <= 65535 then
                                                self_ref.settings:set("web_port", val)
                                                if touchmenu_instance and touchmenu_instance.updateItems then
                                                    touchmenu_instance:updateItems()
                                                end
                                            else
                                                UIManager:show(InfoMessage:new{ text = _("Invalid port (use 80 to 65535)."), timeout = 2 })
                                            end
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(dialog)
                        dialog:onShowKeyboard()
                    end,
                },
                {
                    text_func = function()
                        return string.format(_("Set Directory (Current: %s)"), self_ref.settings:get("web_root"))
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local dialog
                        dialog = InputDialog:new{
                            title = _("Enter Root Directory"),
                            input = self_ref.settings:get("web_root"),
                            buttons = {
                                {
                                    { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                                    {
                                        text = _("Save"),
                                        is_enter_default = true,
                                        callback = function()
                                            local val = dialog:getInputText()
                                            UIManager:close(dialog)
                                            if #val > 0 then
                                                self_ref.settings:set("web_root", val)
                                                if touchmenu_instance and touchmenu_instance.updateItems then
                                                    touchmenu_instance:updateItems()
                                                end
                                            end
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(dialog)
                        dialog:onShowKeyboard()
                    end,
                },
            },
        },

        ------------------------------------------------------------------------
        -- 2. NATIVE USBNETWORK SSH / SFTP DAEMON (Dropbear / OpenSSH)
        ------------------------------------------------------------------------
        {
            text_func = function()
                local running = self_ref.manager:isSshRunning()
                local port = self_ref.settings:get("ssh_port")
                return string.format(_("USBNetwork SSH / SFTP (%s)"), running and string.format(_("RUNNING :%d"), port) or _("Stopped"))
            end,
            sub_item_table = {
                {
                    text = _("Toggle SSH / SFTP (Start / Stop)"),
                    checked_func = function() return self_ref.manager:isSshRunning() end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local running = self_ref.manager:isSshRunning()
                        if running then
                            self_ref.manager:stopSsh()
                            self_ref:updateStandbyState()
                            UIManager:show(InfoMessage:new{
                                text = _("Native SSH Server stopped."),
                                timeout = 2,
                            })
                        else
                            local ok_start, res = self_ref.manager:startSsh()
                            self_ref:updateStandbyState()
                            if ok_start then
                                local ip = self_ref.manager:getDeviceIp()
                                local port = self_ref.settings:get("ssh_port")
                                local pass = self_ref.manager:getSshPassword()
                                local pass_txt = pass and string.format(_("\nPassword: %s"), pass) or ""
                                UIManager:show(InfoMessage:new{
                                    text = string.format(_("Native SSH / SFTP is RUNNING!\n\nSFTP (WinSCP / Mobile):\nsftp -P %d root@%s\n\nTerminal:\nssh -p %d root@%s%s"),
                                        port, ip, port, ip, pass_txt),
                                    timeout = 8,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    icon = "notice-warning",
                                    text = string.format(_("Failed to start SSH server:\n%s"), tostring(res)),
                                    timeout = 6,
                                })
                            end
                        end
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
                {
                    text = _("Show Connection Info & Setup Guide"),
                    callback = function()
                        local ip = self_ref.manager:getDeviceIp()
                        local port = self_ref.settings:get("ssh_port")
                        local running = self_ref.manager:isSshRunning()
                        local pass = self_ref.manager:getSshPassword()
                        local pass_txt = pass and string.format(_("\nPassword: %s"), pass) or _("\nPassword: (Use your Kindle root password or key)")
                        local msg
                        if running then
                            msg = string.format(_("Native SSH is ACTIVE.\n\nConnect in WinSCP / Cyberduck / Mobile SFTP:\nHost: %s\nPort: %d\nUser: root%s\n\nTerminal command:\nssh -p %d root@%s"),
                                ip, port, pass_txt, port, ip)
                        else
                            msg = string.format(_("SSH Server is currently STOPPED.\n\nNote: Requires Dropbear SSH or USBNetwork on Kindle.\nWhen started, connect at:\nssh -p %d root@%s%s"),
                                port, ip, pass_txt)
                        end
                        UIManager:show(InfoMessage:new{ text = msg, timeout = 9 })
                    end,
                },
                {
                    text_func = function()
                        return string.format(_("Set Port (Current: %d)"), self_ref.settings:get("ssh_port"))
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local dialog
                        dialog = InputDialog:new{
                            title = _("Enter SSH Server Port"),
                            input = tostring(self_ref.settings:get("ssh_port")),
                            type = "number",
                            buttons = {
                                {
                                    { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                                    {
                                        text = _("Save"),
                                        is_enter_default = true,
                                        callback = function()
                                            local val = tonumber(dialog:getInputText())
                                            UIManager:close(dialog)
                                            if val and val >= 22 and val <= 65535 then
                                                self_ref.settings:set("ssh_port", val)
                                                if touchmenu_instance and touchmenu_instance.updateItems then
                                                    touchmenu_instance:updateItems()
                                                end
                                            else
                                                UIManager:show(InfoMessage:new{ text = _("Invalid port (use 22 to 65535)."), timeout = 2 })
                                            end
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(dialog)
                        dialog:onShowKeyboard()
                    end,
                },
                {
                    text = _("View SSH Startup Log / Diagnostics"),
                    callback = function()
                        local log_path = "/tmp/dropbear_run.log"
                        local content = "No log found at " .. log_path
                        local f = io.open(log_path, "r")
                        if f then
                            local data = f:read("*a")
                            f:close()
                            if data and #data > 0 then
                                content = data
                            else
                                content = "Log is empty (daemon started or exited with no stdout/stderr)."
                            end
                        end
                        local dropbear_bin = self_ref.manager:findDropbear() or "Not found"
                        local sshd_bin = self_ref.manager:findOpenSsh() or "Not found"
                        local diag = string.format("Detected Binaries:\nDropbear: %s\nOpenSSH: %s\n\nLast Startup Output:\n%s",
                            dropbear_bin, sshd_bin, content)
                        UIManager:show(InfoMessage:new{
                            text = diag,
                            timeout = 15,
                        })
                    end,
                },
                {
                    text = _("Install Dropbear SSH via KPM (Wi-Fi)"),
                    callback = function()
                        if os.execute("test -x /var/local/kmc/bin/kpm") ~= 0 then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = _("KPM (Kindle Package Manager) not found at /var/local/kmc/bin/kpm.\nPlease install USBNetwork or Dropbear via KUAL / Jailbreak tools."),
                                timeout = 6,
                            })
                            return
                        end
                        UIManager:show(InfoMessage:new{
                            text = _("Downloading and installing Dropbear SSH via KPM... Please wait."),
                            timeout = 4,
                        })
                        os.execute("/var/local/kmc/bin/kpm add-repo https://nealing.net/manifest.json && /var/local/kmc/bin/kpm install dropbear-ssh >/tmp/kpm_install.log 2>&1")
                        UIManager:show(InfoMessage:new{
                            text = _("Dropbear SSH installation finished. Try starting SSH now!"),
                            timeout = 4,
                        })
                    end,
                },
            },
        },

        ------------------------------------------------------------------------
        -- 3. GLOBAL CONTROLS & POWER SETTINGS
        ------------------------------------------------------------------------
        {
            text = _("Stop All Servers Now"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self_ref.manager:stopAll()
                self_ref:updateStandbyState()
                UIManager:show(InfoMessage:new{
                    text = _("All servers stopped and firewall ports closed."),
                    timeout = 2,
                })
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end,
        },
        {
            text = _("Power & Background Options"),
            sub_item_table = {
                {
                    text = _("Prevent Sleep / Keep Wi-Fi Awake While Servers Run"),
                    checked_func = function() return self_ref.settings:get("prevent_standby") end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local new_val = not self_ref.settings:get("prevent_standby")
                        self_ref.settings:set("prevent_standby", new_val)
                        self_ref:updateStandbyState()
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
                {
                    text = _("Stop Servers When Exiting KOReader"),
                    checked_func = function() return self_ref.settings:get("auto_stop_on_exit") end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local new_val = not self_ref.settings:get("auto_stop_on_exit")
                        self_ref.settings:set("auto_stop_on_exit", new_val)
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
            },
        },
    } end

return NativeServers
