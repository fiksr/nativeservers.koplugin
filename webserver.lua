--[[--
Native Servers - Web file manager + WebDAV for KOReader (pure LuaSocket).

  * Single-page mobile web app (webui.html) talking to a small JSON API.
  * Full file management: browse, search, upload (with progress), download,
    preview, edit, rename, move, copy, delete (recursive), new file / folder.
  * Storage analytics: disk usage, KOReader / plugin / file-type breakdown,
    biggest files, and duplicate detection. Scans run in small time-slices
    inside KOReader's event loop so the e-ink UI never freezes.
  * Native WebDAV (OPTIONS / PROPFIND / GET / PUT / DELETE / MKCOL / MOVE / COPY)
    for iOS Files, CX File Explorer, Solid Explorer, Windows / macOS.
  * Optional HTTP Basic password (settings key: web_password).
--]]--

local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local socket = require("socket")

local plugin_dir = debug.getinfo(1, "S").source:match("@?(.*[/\\])") or ""

local WebServer = {}
WebServer.__index = WebServer

function WebServer:new(settings, manager)
    local self = setmetatable({}, WebServer)
    self.settings = settings
    self.manager = manager
    self.server = nil
    self.is_running = false
    self.scan = nil
    self.html_cache = nil
    self.disk_cache = {}
    return self
end

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function urlDecode(s, plus)
    if not s then return "" end
    if plus then s = s:gsub("%+", " ") end
    s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return s
end

-- percent-encode everything except unreserved chars (and "/" when keep_slash)
local function urlEncode(s, keep_slash)
    s = tostring(s or "")
    return (s:gsub("[^%w%-%_%.%~" .. (keep_slash and "/" or "") .. "]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function xmlEscape(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
    return s
end

local function parseQuery(qs)
    local q = {}
    if not qs or qs == "" then return q end
    for pair in qs:gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        if k and k ~= "" then q[urlDecode(k, true)] = urlDecode(v, true) end
    end
    return q
end

local function jsonStr(s)
    s = tostring(s)
    s = s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return string.format("\\u%04x", string.byte(c))
    end)
    return '"' .. s .. '"'
end

-- Minimal JSON encoder. Empty tables are encoded as [] (objects are never empty).
local function jsonEncode(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "0" end
        if v == math.floor(v) then return string.format("%.0f", v) end
        return string.format("%.4f", v)
    end
    if t == "string" then return jsonStr(v) end
    if t == "table" then
        if next(v) == nil then return "[]" end
        if #v > 0 then
            local out = {}
            for i = 1, #v do out[i] = jsonEncode(v[i]) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local out = {}
        for k, val in pairs(v) do
            if val ~= nil then out[#out + 1] = jsonStr(k) .. ":" .. jsonEncode(val) end
        end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return "null"
end

local function b64decode(data)
    local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    data = data:gsub("[^" .. b .. "=]", "")
    local bits = data:gsub(".", function(x)
        if x == "=" then return "" end
        local r, f = "", (b:find(x, 1, true) - 1)
        for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end)
    return (bits:gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then return "" end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0) end
        return string.char(c)
    end))
end

local MIME = {
    html = "text/html; charset=utf-8", htm = "text/html; charset=utf-8",
    txt = "text/plain; charset=utf-8", log = "text/plain; charset=utf-8",
    lua = "text/plain; charset=utf-8", sh = "text/plain; charset=utf-8",
    md = "text/plain; charset=utf-8", json = "application/json; charset=utf-8",
    css = "text/css; charset=utf-8", js = "text/javascript; charset=utf-8",
    xml = "application/xml; charset=utf-8",
    png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg", gif = "image/gif",
    webp = "image/webp", svg = "image/svg+xml", bmp = "image/bmp", ico = "image/x-icon",
    pdf = "application/pdf", epub = "application/epub+zip",
    mp3 = "audio/mpeg", ogg = "audio/ogg", wav = "audio/wav", m4a = "audio/mp4",
    mp4 = "video/mp4", webm = "video/webm",
    zip = "application/zip",
}

-- Never let an uploaded .html/.js run on this origin when "previewed".
local INLINE_AS_TEXT = { html = true, htm = true, js = true, xml = true, css = true }

local function extOf(name)
    return (name:match("%.([^.]+)$") or ""):lower()
end

local STATUS = {
    [200] = "OK", [201] = "Created", [204] = "No Content", [206] = "Partial Content",
    [207] = "Multi-Status", [400] = "Bad Request", [401] = "Unauthorized",
    [403] = "Forbidden", [404] = "Not Found", [405] = "Method Not Allowed",
    [409] = "Conflict", [411] = "Length Required", [412] = "Precondition Failed",
    [413] = "Payload Too Large", [415] = "Unsupported Media Type",
    [416] = "Range Not Satisfiable", [500] = "Internal Server Error",
    [507] = "Insufficient Storage",
}

local function respond(client, code, ctype, body, extra)
    body = body or ""
    local h = {
        "HTTP/1.1 " .. code .. " " .. (STATUS[code] or "OK"),
        "Content-Type: " .. (ctype or "text/plain; charset=utf-8"),
        "Content-Length: " .. #body,
        "Connection: close",
        "Cache-Control: no-store",
    }
    if extra then for _, l in ipairs(extra) do h[#h + 1] = l end end
    client:send(table.concat(h, "\r\n") .. "\r\n\r\n" .. body)
end

local function respondJson(client, code, tbl)
    respond(client, code, "application/json; charset=utf-8", jsonEncode(tbl))
end

local function respondErr(client, code, msg)
    respondJson(client, code, { error = msg or STATUS[code] or "error" })
end

--------------------------------------------------------------------------------
-- Path handling (never escapes the configured root)
--------------------------------------------------------------------------------

local function normalizeRel(rel)
    local parts = {}
    for seg in (rel or "/"):gmatch("[^/]+") do
        if seg == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return "/" .. table.concat(parts, "/")
end

local function trimRoot(root)
    root = (root or "/mnt/us"):gsub("/+$", "")
    return root
end

-- returns full path on disk, normalized relative path ("/" for root)
local function resolve(root, rel)
    local nrel = normalizeRel(rel)
    if nrel == "/" then return (root == "" and "/" or root), "/" end
    return root .. nrel, nrel
end

local function joinPath(dir, name)
    if dir:sub(-1) == "/" then return dir .. name end
    return dir .. "/" .. name
end

local function baseName(p) return p:match("([^/]+)$") or p end

local function attrs(path) return lfs.attributes(path) end
local function isDir(path) return lfs.attributes(path, "mode") == "directory" end
local function exists(path) return lfs.attributes(path, "mode") ~= nil end

local function listDir(path)
    local names = {}
    local ok, iter, obj = pcall(lfs.dir, path)
    if not ok or not iter then return names end
    while true do
        local e = iter(obj)
        if not e then break end
        if e ~= "." and e ~= ".." then names[#names + 1] = e end
    end
    return names
end

local function mkdirp(path)
    if isDir(path) then return true end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and not isDir(parent) then
        local ok = mkdirp(parent)
        if not ok then return false end
    end
    return lfs.mkdir(path) and true or isDir(path)
end

local function removeTree(path)
    local a = (lfs.symlinkattributes or lfs.attributes)(path)
    if not a then return false, "not found" end
    if a.mode == "directory" then
        for _, e in ipairs(listDir(path)) do
            local ok, err = removeTree(joinPath(path, e))
            if not ok then return false, err end
        end
        local ok, err = lfs.rmdir(path)
        return ok and true or false, err
    end
    local ok, err = os.remove(path)
    return ok and true or false, err
end

local function copyFile(src, dst)
    local fi = io.open(src, "rb")
    if not fi then return false, "cannot read source" end
    local fo = io.open(dst, "wb")
    if not fo then fi:close(); return false, "cannot write destination" end
    while true do
        local chunk = fi:read(65536)
        if not chunk then break end
        if not fo:write(chunk) then
            fi:close(); fo:close(); os.remove(dst)
            return false, "write failed (disk full?)"
        end
    end
    fi:close(); fo:close()
    return true
end

local function copyTree(src, dst)
    if isDir(src) then
        if dst == src or dst:sub(1, #src + 1) == src .. "/" then
            return false, "cannot copy a folder into itself"
        end
        if not mkdirp(dst) then return false, "cannot create folder" end
        for _, e in ipairs(listDir(src)) do
            local ok, err = copyTree(joinPath(src, e), joinPath(dst, e))
            if not ok then return false, err end
        end
        return true
    end
    return copyFile(src, dst)
end

local function uniqueName(dir, name)
    if not exists(joinPath(dir, name)) then return name end
    local stem, ext = name:match("^(.*)(%.[^.]+)$")
    if not stem or stem == "" then stem, ext = name, "" end
    for i = 1, 999 do
        local cand = string.format("%s (%d)%s", stem, i, ext)
        if not exists(joinPath(dir, cand)) then return cand end
    end
    return name .. "." .. os.time()
end

local function validName(name)
    return name and name ~= "" and name ~= "." and name ~= ".."
        and not name:find("/", 1, true) and not name:find("%z")
end

--------------------------------------------------------------------------------
-- Disk / device info
--------------------------------------------------------------------------------

function WebServer:diskUsage(path)
    local c = self.disk_cache[path]
    if c and os.time() - c.at < 5 then return c.v end
    local ok, res = pcall(function()
        local p = io.popen('df -k "' .. (path:gsub('"', "")) .. '" 2>/dev/null')
        if not p then return nil end
        local out = p:read("*a") or ""
        p:close()
        local lines = {}
        for l in out:gmatch("[^\n]+") do lines[#lines + 1] = l end
        if #lines < 2 then return nil end
        local t = {}
        for w in table.concat(lines, " ", 2):gmatch("%S+") do t[#t + 1] = w end
        local total, avail = tonumber(t[2]), tonumber(t[4])
        if not (total and avail) then return nil end
        total = total * 1024
        avail = avail * 1024
        return { total = total, free = avail, used = math.max(0, total - avail) }
    end)
    local v = ok and res or nil
    self.disk_cache[path] = { at = os.time(), v = v }
    return v
end

function WebServer:rootPath()
    return trimRoot(self.settings:get("web_root") or "/mnt/us")
end

function WebServer:koDir()
    local root = self:rootPath()
    local dir
    pcall(function() dir = require("datastorage"):getDataDir() end)
    if not dir or dir == "" or dir == "." then
        dir = plugin_dir:match("^(.*)/plugins/[^/]+/?$")
    end
    if not dir or dir == "" then dir = root .. "/koreader" end
    dir = dir:gsub("/+$", "")
    if not isDir(dir) then return nil end
    return dir
end

function WebServer:deviceInfo()
    local info = { model = "Kindle" }
    pcall(function()
        local Device = require("device")
        if Device.model then info.model = tostring(Device.model) end
        local pd = Device:getPowerDevice()
        if pd then
            local cap = pd:getCapacity()
            if type(cap) == "number" then info.battery = cap end
            if pd.isCharging then info.charging = pd:isCharging() and true or false end
        end
    end)
    pcall(function()
        local v = require("version"):getCurrentRevision()
        if v then info.version = tostring(v) end
    end)
    return info
end

--------------------------------------------------------------------------------
-- Storage scanner (time-sliced; runs inside KOReader's UI loop)
--------------------------------------------------------------------------------

local EXT_CAT = {}
local function regExt(cat, list)
    for e in list:gmatch("%S+") do EXT_CAT[e] = cat end
end
regExt("book", "epub pdf mobi azw azw3 azw4 azw1 kfx prc cbz cbr cb7 fb2 djvu djv lit kepub")
regExt("doc", "txt rtf doc docx html htm md xhtml odt")
regExt("image", "jpg jpeg png gif webp bmp svg tif tiff ico")
regExt("media", "mp3 m4a ogg wav flac aac mp4 mkv avi webm mov")
regExt("archive", "zip rar 7z tar gz bz2 xz")
regExt("font", "ttf otf ttc woff woff2")
regExt("code", "lua sh so py js json css conf cfg ini log xml sql db sqlite")

local SYSTEM_TOP = { ["system"] = true, [".active_content_sandbox"] = true, ["diagnostic_logs"] = true }
local MIN_DUP = 1024
local TOP_N = 25

local function bump(t, key, size)
    local e = t[key]
    if not e then e = { s = 0, f = 0 }; t[key] = e end
    e.s = e.s + size
    e.f = e.f + 1
end

local function sortedList(t, name_key, cap)
    local list = {}
    for k, e in pairs(t) do list[#list + 1] = { [name_key] = k, s = e.s, f = e.f } end
    table.sort(list, function(a, b) return a.s > b.s end)
    if cap and #list > cap then
        for i = #list, cap + 1, -1 do list[i] = nil end
    end
    return list
end

-- keeps singletons as plain values so that unique sizes cost almost nothing
local function pushCandidate(map, key, value)
    local cur = map[key]
    if cur == nil then
        map[key] = value
    elseif type(cur) == "table" and cur.__multi then
        cur[#cur + 1] = value
    else
        map[key] = { __multi = true, cur, value }
    end
end

local function normTitle(lname)
    local stem = lname:gsub("%.[^.]+$", "")
    stem = stem:gsub("%(%d+%)", ""):gsub("[%s%p_]+", "")
    return stem
end

local function fingerprint(path, size)
    local ok, util = pcall(require, "util")
    if ok and util and util.partialMD5 then
        local okm, md5 = pcall(util.partialMD5, path)
        if okm and md5 then return md5 end
    end
    -- fallback: a few raw samples of the file
    local f = io.open(path, "rb")
    if not f then return nil end
    local parts = {}
    local offsets = { 0, math.floor(size / 3), math.floor(size * 2 / 3), math.max(0, size - 512) }
    for _, off in ipairs(offsets) do
        f:seek("set", off)
        parts[#parts + 1] = f:read(512) or ""
    end
    f:close()
    return table.concat(parts, "|")
end

function WebServer:scanStart()
    local S = self.scan
    if S and (S.state == "walking" or S.state == "hashing") then return S end
    local root = self:rootPath()
    S = {
        state = "walking", started = os.time(), t0 = socket.gettime(), root = root,
        stack = { { path = (root == "" and "/" or root) } },
        files = 0, dirs = 0, bytes = 0, current = "",
        top = {}, types = {}, groups = { books = 0, koreader = 0, system = 0, other = 0 },
        kopart = {}, plugins = {}, largest = {},
        by_size = {}, names = {},
    }
    local ko = self:koDir()
    if ko and ko:sub(1, #root + 1) == root .. "/" then
        S.ko_rel = ko:sub(#root + 2)
    end
    self.scan = S
    UIManager:scheduleIn(0.01, function() self:scanTick(S) end)
    return S
end

function WebServer:scanAccount(S, full, name, size, mtime)
    local rel = full:sub(#S.root + 2)
    local first = rel:match("^([^/]+)/") or "(root files)"
    local lname = name:lower()
    local ext = lname:match("%.([^.]+)$") or ""
    local insdr = rel:find("%.sdr/") ~= nil
    local in_ko = S.ko_rel and rel:sub(1, #S.ko_rel + 1) == S.ko_rel .. "/"
    local cat = insdr and "sidecar" or (EXT_CAT[ext] or "other")

    S.files = S.files + 1
    S.bytes = S.bytes + size
    bump(S.types, cat, size)
    bump(S.top, first, size)

    local sys_top = SYSTEM_TOP[first] or (first:sub(1, 1) == "." and first ~= "(root files)")
    if in_ko then
        S.groups.koreader = S.groups.koreader + size
        local krel = rel:sub(#S.ko_rel + 2)
        bump(S.kopart, krel:match("^([^/]+)/") or "(loose files)", size)
        local pl = krel:match("^plugins/([^/]+)/")
        if pl then bump(S.plugins, pl, size) end
    elseif cat == "book" or cat == "doc" then
        S.groups.books = S.groups.books + size
    elseif sys_top then
        S.groups.system = S.groups.system + size
    else
        S.groups.other = S.groups.other + size
    end

    -- biggest files
    local L = S.largest
    if #L < TOP_N or size > L[1].s then
        local pos = #L + 1
        for i = 1, #L do
            if size < L[i].s then pos = i; break end
        end
        table.insert(L, pos, { p = "/" .. rel, s = size, m = mtime })
        if #L > TOP_N then table.remove(L, 1) end
    end

    -- duplicate candidates (outside KOReader, sidecars and system)
    if size >= MIN_DUP and not in_ko and not insdr and not sys_top then
        pushCandidate(S.by_size, size, rel)
        if cat == "book" then
            local key = normTitle(lname)
            if #key >= 4 then pushCandidate(S.names, key, { rel, size }) end
        end
    end
end

function WebServer:scanTick(S)
    if self.scan ~= S or S.state ~= "walking" then return end
    local t_end = socket.gettime() + 0.04
    local n = 0
    while S.state == "walking" do
        local top = S.stack[#S.stack]
        if not top then
            self:scanFinishWalk(S)
            return
        end
        if not top.iter then
            local ok, iter, obj = pcall(lfs.dir, top.path)
            if ok and iter then
                top.iter, top.obj = iter, obj
                S.current = top.path
            else
                table.remove(S.stack)
            end
        else
            local entry = top.iter(top.obj)
            if not entry then
                pcall(function() if top.obj and top.obj.close then top.obj:close() end end)
                table.remove(S.stack)
            elseif entry ~= "." and entry ~= ".." then
                local full = joinPath(top.path, entry)
                local a = (lfs.symlinkattributes or lfs.attributes)(full)
                if a then
                    if a.mode == "directory" then
                        S.dirs = S.dirs + 1
                        S.stack[#S.stack + 1] = { path = full }
                    elseif a.mode == "file" then
                        self:scanAccount(S, full, entry, a.size or 0, a.modification or 0)
                    end
                end
            end
        end
        n = n + 1
        if n % 40 == 0 and socket.gettime() > t_end then break end
    end
    if S.state == "walking" then
        UIManager:scheduleIn(0.01, function() self:scanTick(S) end)
    end
end

function WebServer:scanFinishWalk(S)
    local root = self:rootPath()
    local disk = self:diskUsage(root == "" and "/" or root)
    local hidden = 0
    if disk then hidden = math.max(0, disk.used - S.bytes) end

    S.result = {
        at = os.time(),
        root = root == "" and "/" or root,
        ko_dir = S.ko_rel and ("/" .. S.ko_rel) or nil,
        files = S.files, dirs = S.dirs, bytes = S.bytes,
        disk = disk,
        rootfs = self:diskUsage("/"),
        groups = {
            books = S.groups.books, koreader = S.groups.koreader,
            system = S.groups.system, other = S.groups.other, hidden = hidden,
        },
        ko = { total = S.groups.koreader, parts = sortedList(S.kopart, "n", 30), plugins = sortedList(S.plugins, "n", 60) },
        top = sortedList(S.top, "n", 30),
        types = sortedList(S.types, "id"),
        largest = {},
    }
    for i = #S.largest, 1, -1 do S.result.largest[#S.result.largest + 1] = S.largest[i] end

    -- build duplicate work queue
    S.queue, S.qi = {}, 1
    for size, v in pairs(S.by_size) do
        if type(v) == "table" then
            for i = 1, #v do S.queue[#S.queue + 1] = { size = size, rel = v[i] } end
        end
    end
    S.fp_groups = {}
    S.hash_total = #S.queue
    S.hash_done = 0
    S.state = "hashing"
    S.by_size = nil
    UIManager:scheduleIn(0.01, function() self:scanHashTick(S) end)
end

function WebServer:scanHashTick(S)
    if self.scan ~= S or S.state ~= "hashing" then return end
    local t_end = socket.gettime() + 0.04
    local base = S.root == "" and "" or S.root
    while S.qi <= #S.queue do
        local item = S.queue[S.qi]
        S.qi = S.qi + 1
        S.hash_done = S.hash_done + 1
        local fp = fingerprint(base .. "/" .. item.rel, item.size)
        if fp then
            local key = item.size .. "|" .. fp
            local g = S.fp_groups[key]
            if not g then g = { size = item.size, list = {} }; S.fp_groups[key] = g end
            g.list[#g.list + 1] = item.rel
        end
        if socket.gettime() > t_end then break end
    end
    if S.qi > #S.queue then
        self:scanFinishHash(S)
    else
        UIManager:scheduleIn(0.01, function() self:scanHashTick(S) end)
    end
end

function WebServer:scanFinishHash(S)
    local base = S.root == "" and "" or S.root
    local exact, reclaim = {}, 0
    for _, g in pairs(S.fp_groups) do
        if #g.list >= 2 then
            local files = {}
            for _, rel in ipairs(g.list) do
                local m = lfs.attributes(base .. "/" .. rel, "modification") or 0
                files[#files + 1] = { p = "/" .. rel, m = m }
            end
            table.sort(files, function(a, b) return a.m < b.m end)
            local waste = g.size * (#files - 1)
            reclaim = reclaim + waste
            exact[#exact + 1] = { size = g.size, waste = waste, files = files }
        end
    end
    table.sort(exact, function(a, b) return a.waste > b.waste end)
    local exact_count = #exact
    for i = #exact, 151, -1 do exact[i] = nil end

    local similar = {}
    for _, v in pairs(S.names) do
        if type(v) == "table" and v.__multi then
            local same_size, sz = true, v[1][2]
            for i = 2, #v do if v[i][2] ~= sz then same_size = false end end
            if not same_size then
                local files = {}
                for i = 1, #v do
                    local m = lfs.attributes(base .. "/" .. v[i][1], "modification") or 0
                    files[#files + 1] = { p = "/" .. v[i][1], s = v[i][2], m = m }
                end
                table.sort(files, function(a, b) return a.s > b.s end)
                similar[#similar + 1] = { name = baseName(v[1][1]), files = files }
            end
        end
    end
    table.sort(similar, function(a, b) return #a.files > #b.files end)
    for i = #similar, 101, -1 do similar[i] = nil end

    local okutil, util = pcall(require, "util")
    S.result.dups = {
        exact = exact, similar = similar, reclaim = reclaim, exact_count = exact_count,
        method = (okutil and util and util.partialMD5) and "md5" or "sample",
    }
    S.result.took = socket.gettime() - S.t0
    S.state = "done"
    S.fp_groups, S.queue, S.names = nil, nil, nil
end

function WebServer:scanStatus()
    local S = self.scan
    if not S then return { state = "idle" } end
    return {
        state = S.state, files = S.files, dirs = S.dirs, bytes = S.bytes,
        current = S.current, hash_done = S.hash_done, hash_total = S.hash_total,
        at = S.result and S.result.at or nil,
        has_result = S.result ~= nil,
        elapsed = math.floor(socket.gettime() - S.t0),
    }
end

--------------------------------------------------------------------------------
-- Recursive helpers with a time budget (search / folder size)
--------------------------------------------------------------------------------

local function walkBudget(path, budget_s, visit)
    local t_end = socket.gettime() + budget_s
    local visited, partial = 0, false
    local function rec(dir)
        if partial then return end
        for _, e in ipairs(listDir(dir)) do
            local full = joinPath(dir, e)
            local a = (lfs.symlinkattributes or lfs.attributes)(full)
            if a then
                visited = visited + 1
                if visit(full, e, a) == false then partial = true; return end
                if a.mode == "directory" then rec(full) end
                if partial then return end
            end
            if visited % 200 == 0 and socket.gettime() > t_end then partial = true; return end
        end
    end
    rec(path)
    return partial
end

--------------------------------------------------------------------------------
-- WebDAV
--------------------------------------------------------------------------------

local function httpDate(t)
    return os.date("!%a, %d %b %Y %H:%M:%S GMT", t or 0)
end

local function davEntry(href, name, a)
    local is_dir = a.mode == "directory"
    local props = {
        "<D:displayname>" .. xmlEscape(name) .. "</D:displayname>",
        "<D:getlastmodified>" .. httpDate(a.modification) .. "</D:getlastmodified>",
        is_dir and "<D:resourcetype><D:collection/></D:resourcetype>" or "<D:resourcetype/>",
    }
    if not is_dir then
        props[#props + 1] = "<D:getcontentlength>" .. string.format("%.0f", a.size or 0) .. "</D:getcontentlength>"
        props[#props + 1] = "<D:getcontenttype>" .. (MIME[extOf(name)] or "application/octet-stream") .. "</D:getcontenttype>"
    end
    return "<D:response><D:href>" .. href .. "</D:href><D:propstat><D:prop>" ..
        table.concat(props) .. "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
end

local function davPropfind(full, rel, depth)
    local a = attrs(full)
    if not a then return nil end
    local out = {}
    local href_base = urlEncode(rel, true)
    if a.mode == "directory" then
        if href_base:sub(-1) ~= "/" then href_base = href_base .. "/" end
        out[#out + 1] = davEntry(href_base, rel == "/" and "Kindle" or baseName(rel), a)
        if depth ~= "0" then
            for _, e in ipairs(listDir(full)) do
                local ca = attrs(joinPath(full, e))
                if ca then
                    local href = href_base .. urlEncode(e)
                    if ca.mode == "directory" then href = href .. "/" end
                    out[#out + 1] = davEntry(href, e, ca)
                end
            end
        end
    else
        out[#out + 1] = davEntry(href_base, baseName(rel), a)
    end
    return '<?xml version="1.0" encoding="utf-8"?>\n<D:multistatus xmlns:D="DAV:">' ..
        table.concat(out) .. "</D:multistatus>"
end

--------------------------------------------------------------------------------
-- File serving (download / inline preview, with Range support)
--------------------------------------------------------------------------------

local function serveFile(client, full, headers, inline)
    local size = lfs.attributes(full, "size") or 0
    local name = baseName(full)
    local f = io.open(full, "rb")
    if not f then return respondErr(client, 404, "Not found") end

    local ext = extOf(name)
    local ctype = MIME[ext] or "application/octet-stream"
    if inline and INLINE_AS_TEXT[ext] then ctype = "text/plain; charset=utf-8" end

    local first, last, code = 0, size - 1, 200
    local rng = headers["range"]
    if rng and size > 0 then
        local a, b = rng:match("bytes=(%d*)%-(%d*)")
        if a and (a ~= "" or b ~= "") then
            if a == "" then
                first = math.max(0, size - tonumber(b))
            else
                first = tonumber(a)
                if b ~= "" then last = math.min(size - 1, tonumber(b)) end
            end
            if first > last or first >= size then
                f:close()
                return respond(client, 416, "text/plain", "Bad range",
                    { "Content-Range: bytes */" .. string.format("%.0f", size) })
            end
            code = 206
        end
    end
    local length = (size == 0) and 0 or (last - first + 1)

    local ascii = name:gsub("[^%w%.%-_ ]", "_")
    local h = {
        "HTTP/1.1 " .. code .. " " .. STATUS[code],
        "Content-Type: " .. ctype,
        "Content-Length: " .. string.format("%.0f", length),
        "Accept-Ranges: bytes",
        "Connection: close",
        "Content-Disposition: " .. (inline and "inline" or "attachment") ..
            "; filename=\"" .. ascii .. "\"; filename*=UTF-8''" .. urlEncode(name),
    }
    if code == 206 then
        h[#h + 1] = string.format("Content-Range: bytes %.0f-%.0f/%.0f", first, last, size)
    end
    client:send(table.concat(h, "\r\n") .. "\r\n\r\n")

    if length > 0 then
        f:seek("set", first)
        local remaining = length
        while remaining > 0 do
            local chunk = f:read(math.min(65536, remaining))
            if not chunk or #chunk == 0 then break end
            local ok = client:send(chunk)
            if not ok then break end
            remaining = remaining - #chunk
        end
    end
    f:close()
end

--------------------------------------------------------------------------------
-- Web UI
--------------------------------------------------------------------------------

function WebServer:getHtml()
    if self.html_cache then return self.html_cache end
    local f = io.open(plugin_dir .. "webui.html", "rb")
    if f then
        self.html_cache = f:read("*a")
        f:close()
    else
        self.html_cache = "<h1>webui.html is missing from the plugin folder</h1>"
    end
    return self.html_cache
end

--------------------------------------------------------------------------------
-- Request handling
--------------------------------------------------------------------------------

local function readBody(client, headers, limit)
    local len = tonumber(headers["content-length"]) or 0
    if len <= 0 then return "" end
    if limit and len > limit then return nil end
    return client:receive(len) or ""
end

-- body: newline separated, each line a percent-encoded relative path
local function bodyPaths(body)
    local list = {}
    for line in (body or ""):gmatch("[^\n]+") do
        list[#list + 1] = urlDecode(line, false)
    end
    return list
end

-- absolute disk path -> "/relative/path" below the web root
local function relFromFull(rootfull, full)
    local r = full:sub(#rootfull + 1)
    if rootfull == "/" then r = "/" .. full:sub(2) end
    if r:sub(1, 1) ~= "/" then r = "/" .. r end
    return r
end

function WebServer:handleApi(client, method, route, query, headers)
    local root = self:rootPath()
    local rootfull = (root == "" and "/" or root)

    if route == "/api/info" and method == "GET" then
        local info = self:deviceInfo()
        info.root = rootfull
        info.ko = self:koDir()
        info.disk = self:diskUsage(rootfull)
        info.rootfs = self:diskUsage("/")
        info.auth = (self.settings:get("web_password") or "") ~= ""
        return respondJson(client, 200, info)
    end

    if route == "/api/list" and method == "GET" then
        local full, rel = resolve(root, query.path)
        if not isDir(full) then return respondErr(client, 404, "Folder not found") end
        local items = {}
        for _, e in ipairs(listDir(full)) do
            local a = attrs(joinPath(full, e))
            if a then
                items[#items + 1] = {
                    n = e, d = (a.mode == "directory") and 1 or 0,
                    s = a.size or 0, m = a.modification or 0,
                }
            end
        end
        return respondJson(client, 200, { path = rel, count = #items, items = items })
    end

    if route == "/api/search" and method == "GET" then
        local q = (query.q or ""):lower()
        if q == "" then return respondJson(client, 200, { items = {} }) end
        local base, rel = resolve(root, query.path)
        local items = {}
        local partial = walkBudget(base, 4, function(full, name, a)
            if name:lower():find(q, 1, true) then
                items[#items + 1] = {
                    p = relFromFull(rootfull, full), n = name,
                    d = (a.mode == "directory") and 1 or 0,
                    s = a.size or 0, m = a.modification or 0,
                }
                if #items >= 300 then return false end
            end
        end)
        return respondJson(client, 200, { items = items, truncated = partial and true or false, base = rel })
    end

    if route == "/api/dirsize" and method == "GET" then
        local full = resolve(root, query.path)
        local size, files, dirs = 0, 0, 0
        local partial = walkBudget(full, 3, function(_, _, a)
            if a.mode == "directory" then dirs = dirs + 1
            elseif a.mode == "file" then files = files + 1; size = size + (a.size or 0) end
        end)
        return respondJson(client, 200, { size = size, files = files, dirs = dirs, partial = partial and true or false })
    end

    if route == "/api/scan/start" and method == "POST" then
        self:scanStart()
        return respondJson(client, 200, self:scanStatus())
    end
    if route == "/api/scan/status" and method == "GET" then
        return respondJson(client, 200, self:scanStatus())
    end
    if route == "/api/scan/result" and method == "GET" then
        local S = self.scan
        if not S or not S.result then return respondJson(client, 200, { state = S and S.state or "idle" }) end
        local out = {}
        for k, v in pairs(S.result) do out[k] = v end
        out.state = S.state
        return respondJson(client, 200, out)
    end

    if route == "/api/read" and method == "GET" then
        local full = resolve(root, query.path)
        if not exists(full) or isDir(full) then return respondErr(client, 404, "Not found") end
        local size = lfs.attributes(full, "size") or 0
        if size > 1500000 then return respondErr(client, 413, "File too large to edit (max 1.5 MB)") end
        local f = io.open(full, "rb")
        if not f then return respondErr(client, 403, "Cannot open file") end
        local content = f:read("*a") or ""
        f:close()
        if content:find("%z") then return respondErr(client, 415, "Binary file") end
        return respond(client, 200, "text/plain; charset=utf-8", content)
    end

    if route == "/api/save" and method == "POST" then
        local full, rel = resolve(root, query.path)
        if rel == "/" or isDir(full) then return respondErr(client, 400, "Invalid file") end
        local body = readBody(client, headers, 4000000)
        if not body then return respondErr(client, 413, "Too large") end
        local f = io.open(full, "wb")
        if not f then return respondErr(client, 500, "Cannot write file") end
        local ok = f:write(body)
        f:close()
        if not ok then return respondErr(client, 507, "Write failed") end
        return respondJson(client, 200, { ok = true })
    end

    if route == "/api/newfile" and method == "POST" then
        local full, rel = resolve(root, query.path)
        if rel == "/" or exists(full) then return respondErr(client, 409, "Already exists") end
        local f = io.open(full, "wb")
        if not f then return respondErr(client, 500, "Cannot create file") end
        f:close()
        return respondJson(client, 200, { ok = true })
    end

    if route == "/api/upload" and method == "POST" then
        local full, rel = resolve(root, query.path)
        if rel == "/" or isDir(full) then return respondErr(client, 400, "Invalid target") end
        local len = tonumber(headers["content-length"])
        if not len then return respondErr(client, 411, "Length required") end
        local parent = full:match("^(.*)/[^/]+$")
        if parent and parent ~= "" and not mkdirp(parent) then
            return respondErr(client, 500, "Cannot create folder")
        end
        local tmp = full .. ".part"
        local f = io.open(tmp, "wb")
        if not f then return respondErr(client, 500, "Cannot write file") end
        local received, ok = 0, true
        while received < len do
            local chunk, _, partial = client:receive(math.min(65536, len - received))
            chunk = chunk or partial
            if not chunk or #chunk == 0 then ok = false; break end
            if not f:write(chunk) then ok = false; break end
            received = received + #chunk
        end
        f:close()
        if not ok or received < len then
            os.remove(tmp)
            return respondErr(client, 500, "Upload interrupted or disk full")
        end
        os.remove(full)
        if not os.rename(tmp, full) then
            os.remove(tmp)
            return respondErr(client, 500, "Cannot finalize upload")
        end
        self.disk_cache = {}
        return respondJson(client, 200, { ok = true, size = received })
    end

    if route == "/api/mkdir" and method == "POST" then
        local full, rel = resolve(root, query.path)
        if rel == "/" or exists(full) then return respondErr(client, 409, "Already exists") end
        if not mkdirp(full) then return respondErr(client, 500, "Cannot create folder") end
        return respondJson(client, 200, { ok = true })
    end

    if route == "/api/rename" and method == "POST" then
        local full, rel = resolve(root, query.path)
        local name = query.name
        if rel == "/" then return respondErr(client, 403, "Cannot rename root") end
        if not validName(name) then return respondErr(client, 400, "Invalid name") end
        local target = joinPath(full:match("^(.*)/[^/]+$") or "", name)
        if exists(target) then return respondErr(client, 409, "A file with this name already exists") end
        local ok, err = os.rename(full, target)
        if not ok then return respondErr(client, 500, tostring(err)) end
        return respondJson(client, 200, { ok = true })
    end

    if (route == "/api/delete" or route == "/api/move" or route == "/api/copy") and method == "POST" then
        local body = readBody(client, headers, 1000000)
        local paths = bodyPaths(body)
        if #paths == 0 and query.path then paths = { query.path } end
        if #paths == 0 then return respondErr(client, 400, "Nothing selected") end

        local dest_full
        if route ~= "/api/delete" then
            local df = resolve(root, query.dest)
            if not isDir(df) then return respondErr(client, 404, "Destination folder not found") end
            dest_full = df
        end

        local done, failed = 0, {}
        for _, p in ipairs(paths) do
            local full, rel = resolve(root, p)
            local ok, err = true, nil
            if rel == "/" then
                ok, err = false, "Cannot modify root"
            elseif not exists(full) and not (lfs.symlinkattributes and lfs.symlinkattributes(full)) then
                ok, err = false, "Not found"
            elseif route == "/api/delete" then
                ok, err = removeTree(full)
            else
                local name = baseName(full)
                if route == "/api/move" then
                    local target = joinPath(dest_full, name)
                    if target == full then
                        ok, err = false, "Already in this folder"
                    elseif exists(target) then
                        ok, err = false, "Already exists in destination"
                    elseif isDir(full) and (target:sub(1, #full + 1) == full .. "/") then
                        ok, err = false, "Cannot move a folder into itself"
                    else
                        ok, err = os.rename(full, target)
                        if not ok then -- cross-device fallback
                            ok, err = copyTree(full, target)
                            if ok then ok, err = removeTree(full) end
                        end
                    end
                else
                    local target = joinPath(dest_full, uniqueName(dest_full, name))
                    ok, err = copyTree(full, target)
                end
            end
            if ok then done = done + 1 else failed[#failed + 1] = { p = rel, e = tostring(err) } end
        end
        self.disk_cache = {}
        return respondJson(client, 200, { ok = done, failed = failed, failed_count = #failed })
    end

    return respondErr(client, 404, "Unknown API")
end

function WebServer:checkAuth(client, headers)
    local pass = self.settings:get("web_password")
    if not pass or pass == "" then return true end
    local auth = headers["authorization"]
    if auth then
        local b64 = auth:match("^[Bb]asic%s+(.+)$")
        if b64 then
            local creds = b64decode(b64)
            local given = creds:match("^[^:]*:(.*)$")
            if given == pass then return true end
        end
    end
    respond(client, 401, "text/plain", "Authentication required",
        { 'WWW-Authenticate: Basic realm="Kindle Files"' })
    return false
end

function WebServer:handleClient(client)
    local line = client:receive("*l")
    if not line then return end
    local method, raw_uri = line:match("^(%u+)%s+(%S+)%s+HTTP")
    if not method or not raw_uri then return end

    local headers = {}
    for _ = 1, 100 do
        local hline = client:receive("*l")
        if not hline or hline == "" then break end
        local k, v = hline:match("^([^:]+):%s*(.*)$")
        if k then headers[k:lower()] = v end
    end

    if not self:checkAuth(client, headers) then return end

    local path_raw, qs = raw_uri:match("^([^?]*)%??(.*)$")
    path_raw = path_raw or "/"
    local query = parseQuery(qs)
    local root = self:rootPath()

    -- JSON API used by the web app
    if path_raw:sub(1, 5) == "/api/" then
        return self:handleApi(client, method, path_raw, query, headers)
    end

    -- Path in the URL itself (WebDAV, direct file links)
    local full, rel = resolve(root, urlDecode(path_raw, false))

    if method == "OPTIONS" then
        return respond(client, 200, "text/plain", "", {
            "DAV: 1, 2", "MS-Author-Via: DAV",
            "Allow: OPTIONS, GET, HEAD, POST, PUT, DELETE, PROPFIND, MKCOL, MOVE, COPY",
        })
    end

    if method == "PROPFIND" then
        readBody(client, headers, 100000)
        local xml = davPropfind(full, rel, headers["depth"] or "1")
        if not xml then return respond(client, 404, "text/plain", "Not Found") end
        return respond(client, 207, "application/xml; charset=utf-8", xml)
    end

    if method == "PUT" then
        local len = tonumber(headers["content-length"]) or 0
        if rel == "/" or isDir(full) then return respond(client, 405, "text/plain", "Is a directory") end
        local existed = exists(full)
        local tmp = full .. ".part"
        local f = io.open(tmp, "wb")
        if not f then return respond(client, 409, "text/plain", "Cannot write") end
        local received, ok = 0, true
        while received < len do
            local chunk, _, partial = client:receive(math.min(65536, len - received))
            chunk = chunk or partial
            if not chunk or #chunk == 0 then ok = false; break end
            if not f:write(chunk) then ok = false; break end
            received = received + #chunk
        end
        f:close()
        if not ok then os.remove(tmp); return respond(client, 500, "text/plain", "Interrupted") end
        os.remove(full)
        os.rename(tmp, full)
        return respond(client, existed and 204 or 201, "text/plain", "")
    end

    if method == "DELETE" then
        if rel == "/" then return respond(client, 403, "text/plain", "Forbidden") end
        if not exists(full) then return respond(client, 404, "text/plain", "Not Found") end
        local ok = removeTree(full)
        return respond(client, ok and 204 or 500, "text/plain", "")
    end

    if method == "MKCOL" then
        if exists(full) then return respond(client, 405, "text/plain", "Exists") end
        return respond(client, mkdirp(full) and 201 or 409, "text/plain", "")
    end

    if method == "MOVE" or method == "COPY" then
        local dest = headers["destination"] or ""
        dest = dest:match("^%a+://[^/]+(/.*)$") or dest
        local dfull, drel = resolve(root, urlDecode(dest, false))
        if rel == "/" or drel == "/" or not exists(full) then return respond(client, 404, "text/plain", "Not Found") end
        local overwrite = (headers["overwrite"] or "T"):upper() ~= "F"
        local existed = exists(dfull)
        if existed and not overwrite then return respond(client, 412, "text/plain", "Exists") end
        if existed then removeTree(dfull) end
        local ok
        if method == "MOVE" then
            ok = os.rename(full, dfull)
            if not ok then ok = copyTree(full, dfull) and removeTree(full) end
        else
            ok = copyTree(full, dfull)
        end
        return respond(client, ok and (existed and 204 or 201) or 500, "text/plain", "")
    end

    -- /file?path=...&inline=1  (download / preview used by the web app)
    if method == "GET" and (path_raw == "/file" or path_raw == "/download") and query.path then
        local f2 = resolve(root, query.path)
        if exists(f2) and not isDir(f2) then
            return serveFile(client, f2, headers, query.inline == "1")
        end
        return respond(client, 404, "text/plain", "Not Found")
    end

    if method == "GET" or method == "HEAD" then
        if path_raw ~= "/" and exists(full) and not isDir(full) then
            return serveFile(client, full, headers, false)
        end
        local html = self:getHtml()
        return respond(client, 200, "text/html; charset=utf-8", method == "HEAD" and "" or html)
    end

    return respond(client, 405, "text/plain", "Method Not Allowed")
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function WebServer:start()
    if self.is_running then return true end

    local port = tonumber(self.settings:get("web_port")) or 8080
    local s, err = socket.bind("*", port)
    if not s then return false, tostring(err) end

    if self.manager and self.manager.openFirewallPort then
        self.manager:openFirewallPort(port)
    end

    s:settimeout(0.01)
    self.server = s
    self.is_running = true
    self.html_cache = nil

    pcall(function() UIManager:insertZMQ(self) end)
    self:pollLoop()
    return true
end

function WebServer:stop()
    self.is_running = false
    if self.scan and (self.scan.state == "walking" or self.scan.state == "hashing") then
        self.scan.state = "stopped"
    end
    pcall(function() UIManager:removeZMQ(self) end)
    if self.server then
        pcall(function() self.server:close() end)
        self.server = nil
    end
    local port = tonumber(self.settings:get("web_port")) or 8080
    if self.manager and self.manager.closeFirewallPort then
        self.manager:closeFirewallPort(port)
    end
    return true
end

function WebServer:processClient(client)
    client:settimeout(20)
    local ok, err = pcall(function() self:handleClient(client) end)
    if not ok and err then
        pcall(function()
            local msg = jsonEncode({ error = "Internal error: " .. tostring(err) })
            client:send("HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: " ..
                #msg .. "\r\nConnection: close\r\n\r\n" .. msg)
        end)
    end
    pcall(function() client:close() end)
end

-- Called by KOReader's main loop (UIManager:processZMQs)
function WebServer:waitEvent()
    if not self.is_running or not self.server then return nil end
    local client = self.server:accept()
    if client then self:processClient(client) end
    return nil
end

function WebServer:pollLoop()
    if not self.is_running or not self.server then return end
    local client = self.server:accept()
    if client then self:processClient(client) end
    if self.is_running then
        UIManager:scheduleIn(0.2, function() self:pollLoop() end)
    end
end

function WebServer:isRunning()
    return self.is_running
end

return WebServer
