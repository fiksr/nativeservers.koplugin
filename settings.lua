--[[--
Settings manager for Native High-Speed Servers (WebDAV + USBNetwork SSH).
Persists configuration into KOReader's G_reader_settings.
--]]--

local Settings = {}
Settings.__index = Settings

local DEFAULT_SETTINGS = {
    web_port = 8080,
    web_root = "/mnt/us",
    ssh_port = 2222,
    prevent_standby = true,
    auto_stop_on_exit = true,
}

function Settings:new()
    local self = setmetatable({}, Settings)
    self.data = {}
    self:load()
    return self
end

function Settings:load()
    local loaded = nil
    if G_reader_settings and G_reader_settings.readSetting then
        loaded = G_reader_settings:readSetting("nativeservers")
    end

    self.data = {}
    for k, v in pairs(DEFAULT_SETTINGS) do
        self.data[k] = v
    end

    if type(loaded) == "table" then
        for k, v in pairs(loaded) do
            self.data[k] = v
        end
    end
end

function Settings:save()
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting("nativeservers", self.data)
    end
end

function Settings:get(key)
    return self.data[key]
end

function Settings:set(key, value)
    self.data[key] = value
    self:save()
end

return Settings
