--[[--
Pure LuaSocket WebDAV & Mobile Web File Manager for KOReader.
Zero external binaries required. Provides mobile browser file management,
in-browser code editing, drag-and-drop book uploads, and native WebDAV for iOS/Android Files apps.
--]]--

local Device = require("device")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local socket = require("socket")

local WebServer = {}
WebServer.__index = WebServer

function WebServer:new(settings, manager)
    local self = setmetatable({}, WebServer)
    self.settings = settings
    self.manager = manager
    self.server = nil
    self.is_running = false
    return self
end

-- URL decoding
local function urlDecode(str)
    if not str then return "" end
    str = str:gsub("+", "")
    str = str:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
    return str
end

-- URL encoding
local function urlEncode(str)
    if not str then return "" end
    str = str:gsub("\n", "\r\n")
    str = str:gsub("([^%w %-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    str = str:gsub("", "+")
    return str
end

-- Sanitize path to prevent escaping root
local function sanitizePath(base, req_path)
    req_path = urlDecode(req_path or "/")
    -- Strip query string
    req_path = req_path:match("^([^?]*)") or req_path
    -- Strip directory traversal
    req_path = req_path:gsub("%.%./", ""):gsub("/%.%.", ""):gsub("%.%.", "")
    if not req_path:match("^/") then req_path = "/".. req_path end

    local full = base .. req_path
    full = full:gsub("//+", "/")
    if #full > 1 and full:sub(-1) == "/" then
        full = full:sub(1, -2)
    end
    return full, req_path
end

-- Format bytes into human-readable size
local function formatSize(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1024 then return bytes .. "B" end
    if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
    if bytes < 1024 * 1024 * 1024 then return string.format("%.1f MB", bytes / (1024 * 1024)) end
    return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
end

-- Check if a file is an editable text/script file
local function isEditable(name)
    local ext = name:match("%.([^.]+)$")
    if not ext then return false end
    ext = ext:lower()
    local text_exts = {
        lua = true, txt = true, json = true, conf = true, cfg = true,
        ini = true, sh = true, log = true, xml = true, html = true,
        css = true, js = true, md = true, py = true, properties = true
    }
    return text_exts[ext] == true
end

-- Check if file is a reading book
local function isBook(name)
    local ext = name:match("%.([^.]+)$")
    if not ext then return false end
    ext = ext:lower()
    local book_exts = { epub = true, pdf = true, mobi = true, azw3 = true, cbz = true, cbr = true, fb2 = true }
    return book_exts[ext] == true
end

--------------------------------------------------------------------------------
-- HTML MOBILE WEB APP GENERATOR
--------------------------------------------------------------------------------

local function generateMobileHtml(current_path, base_root)
    local rel_path = current_path:sub(#base_root + 1)
    if rel_path == "" then rel_path = "/" end

    -- Build parent path
    local parent_rel = "/"
    if rel_path ~= "/" then
        parent_rel = rel_path:match("^(.*)/[^/]+$") or "/"
        if parent_rel == "" then parent_rel = "/" end
    end

    -- Collect items in directory
    local folders = {}
    local files = {}

    pcall(function()
        for entry in lfs.dir(current_path) do
            if entry ~= "." and entry ~= ".." then
                local full = current_path .. "/".. entry
                local mode = lfs.attributes(full, "mode")
                local size = lfs.attributes(full, "size") or 0
                local mtime = lfs.attributes(full, "modification") or 0
                local time_str = os.date("%Y-%m-%d %H:%M", mtime)

                if mode == "directory" then
                    table.insert(folders, { name = entry, time = time_str })
                elseif mode == "file" then
                    table.insert(files, {
                        name = entry,
                        size = formatSize(size),
                        raw_size = size,
                        time = time_str,
                        editable = isEditable(entry),
                        book = isBook(entry),
                    })
                end
            end
        end
    end)

    table.sort(folders, function(a, b) return a.name:lower() < b.name:lower() end)
    table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)

    -- Generate rows
    local rows_html = {}
    if rel_path ~= "/" then
        table.insert(rows_html, string.format([[
        <tr class="folder-row"onclick="location.href='/?path=%s'">
            <td colspan="4"><strong> ️ .. (Up to Parent Folder)</strong></td>
        </tr>]], urlEncode(parent_rel)))
    end

    for _, f in ipairs(folders) do
        local target = rel_path == "/" and ("/".. f.name) or (rel_path .. "/".. f.name)
        table.insert(rows_html, string.format([[
        <tr class="folder-row"onclick="location.href='/?path=%s'">
            <td> <strong>%s/</strong></td>
            <td>Folder</td>
            <td>%s</td>
            <td class="actions"onclick="event.stopPropagation()">
                <button class="btn btn-sm btn-danger"onclick="deleteItem('%s', true)">Delete</button>
            </td>
        </tr>]], urlEncode(target), f.name, f.time, urlEncode(target)))
    end

    for _, f in ipairs(files) do
        local file_rel = rel_path == "/" and ("/".. f.name) or (rel_path .. "/".. f.name)
        local icon = f.book and "" or (f.editable and "" or "")
        local edit_btn = f.editable and string.format([[<button class="btn btn-sm btn-primary"onclick="openEditor('%s', '%s')">️ Edit</button> ]], urlEncode(file_rel), f.name) or ""

        table.insert(rows_html, string.format([[
        <tr>
            <td>%s%s</td>
            <td>%s</td>
            <td>%s</td>
            <td class="actions">
                %s
                <a class="btn btn-sm btn-secondary"href="/download?path=%s"download>️ Get</a>
                <button class="btn btn-sm btn-danger"onclick="deleteItem('%s', false)">️</button>
            </td>
        </tr>]], icon, f.name, f.size, f.time, edit_btn, urlEncode(file_rel), urlEncode(file_rel)))
    end

local HTML_TEMPLATE = [[<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport"content="width=device-width, initial-scale=1, maximum-scale=1">
<title>Kindle File Manager & Code Editor</title>
<style>
  :root { --bg: #121212; --card: #1e1e1e; --text: #f0f0f0; --dim: #a0a0a0; --accent: #3b82f6; --accent-hover: #2563eb; --border: #333; --danger: #ef4444; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; padding: 12px; font-size: 15px; }
  .header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px; padding-bottom: 12px; border-bottom: 1px solid var(--border); }
  .header h1 { font-size: 1.25rem; font-weight: 700; color: #fff; }
  .badge { background: #10b981; color: #000; font-size: 0.75rem; font-weight: 700; padding: 2px 8px; border-radius: 9999px; }
  .toolbar { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 12px; margin-bottom: 16px; display: flex; flex-wrap: wrap; gap: 10px; align-items: center; justify-content: space-between; }
  .breadcrumb { font-family: monospace; font-size: 0.9rem; color: var(--dim); word-break: break-all; }
  .btn { display: inline-flex; align-items: center; justify-content: center; padding: 8px 14px; border-radius: 6px; font-size: 0.875rem; font-weight: 600; cursor: pointer; border: none; text-decoration: none; transition: 0.15s ease; }
  .btn-primary { background: var(--accent); color: #fff; }
  .btn-primary:hover { background: var(--accent-hover); }
  .btn-secondary { background: #374151; color: #fff; }
  .btn-danger { background: #7f1d1d; color: #fca5a5; }
  .btn-sm { padding: 4px 8px; font-size: 0.75rem; border-radius: 4px; }
  table { width: 100%; border-collapse: collapse; background: var(--card); border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
  th, td { padding: 10px 12px; text-align: left; border-bottom: 1px solid var(--border); }
  th { background: #262626; color: var(--dim); font-size: 0.8rem; text-transform: uppercase; }
  tr.folder-row { cursor: pointer; }
  tr.folder-row:hover { background: #2a2a2a; }
  td.actions { text-align: right; white-space: nowrap; }
  .upload-box { border: 2px dashed #4b5563; border-radius: 8px; padding: 16px; text-align: center; margin-bottom: 16px; background: rgba(255,255,255,0.02); }
  .modal { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.85); z-index: 999; padding: 12px; flex-direction: column; }
  .modal-content { background: var(--card); border: 1px solid var(--border); border-radius: 8px; display: flex; flex-direction: column; height: 100%; max-width: 1000px; margin: 0 auto; width: 100%; overflow: hidden; }
  .modal-header { padding: 12px 16px; border-bottom: 1px solid var(--border); display: flex; justify-content: space-between; align-items: center; }
  .modal-body { flex: 1; padding: 0; display: flex; }
  .modal-body textarea { width: 100%; height: 100%; background: #141414; color: #e5e5e5; font-family: monospace; font-size: 14px; padding: 12px; border: none; resize: none; outline: none; line-height: 1.5; tab-size: 4; }
  .modal-footer { padding: 12px 16px; border-top: 1px solid var(--border); display: flex; justify-content: flex-end; gap: 10px; }
  #statusToast { position: fixed; bottom: 20px; right: 20px; background: #10b981; color: #000; font-weight: 700; padding: 10px 18px; border-radius: 6px; display: none; z-index: 1000; box-shadow: 0 4px 12px rgba(0,0,0,0.5); }
</style>
</head>
<body>

<div class="header">
  <div>
    <h1>Kindle Paperwhite Wireless</h1>
    <span style="font-size: 0.8rem; color: var(--dim);">High-Speed Wi-Fi Storage</span>
  </div>
  <span class="badge">CONNECTED</span>
</div>

<div class="upload-box">
  <form id="uploadForm"onsubmit="uploadFiles(event)">
    <p style="margin-bottom: 8px; font-weight: 600;"> Transfer Books / Files into this folder</p>
    <input type="file"id="fileInput"multiple style="margin-bottom: 10px; color: var(--dim);">
    <br>
    <button type="submit"class="btn btn-primary"> Send to Kindle (Full Wi-Fi Speed)</button>
  </form>
  <div id="uploadProgress"style="display:none; margin-top: 10px; font-weight: bold; color: var(--accent);">Uploading...</div>
</div>

<div class="toolbar">
  <div class="breadcrumb"> Path: <strong>{{CURRENT_PATH}}</strong></div>
  <div>
    <button class="btn btn-secondary btn-sm"onclick="createNewFolder()"> New Folder</button>
  </div>
</div>

<table>
  <thead>
    <tr>
      <th>Name</th>
      <th>Size</th>
      <th>Modified</th>
      <th style="text-align: right;">Action</th>
    </tr>
  </thead>
  <tbody>
    {{ROWS_HTML}}
  </tbody>
</table>

<!-- CODE EDITOR MODAL -->
<div id="editorModal"class="modal">
  <div class="modal-content">
    <div class="modal-header">
      <h3 id="editorTitle">Editing file</h3>
      <span id="saveStatus"style="font-size: 0.8rem; color: #10b981; margin-left: 12px;"></span>
      <button class="btn btn-sm btn-secondary"onclick="closeEditor()"> Close</button>
    </div>
    <div class="modal-body">
      <textarea id="editorText"spellcheck="false"></textarea>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary"onclick="closeEditor()">Cancel</button>
      <button class="btn btn-primary"id="saveBtn"onclick="saveEditorContent()"> Save to Kindle</button>
    </div>
  </div>
</div>

<div id="statusToast"></div>

<script>
  let currentEditingPath = "";

  function showToast(msg) {
    const toast = document.getElementById('statusToast');
    toast.innerText = msg;
    toast.style.display = 'block';
    setTimeout(() => { toast.style.display = 'none'; }, 3000);
  }

  async function openEditor(path, name) {
    currentEditingPath = path;
    document.getElementById('editorTitle').innerText = "️ "+ name;
    document.getElementById('saveStatus').innerText = "Loading...";
    document.getElementById('editorModal').style.display = 'flex';

    try {
      const res = await fetch('/api/read?path=' + encodeURIComponent(path));
      if (!res.ok) throw new Error("Could not read file");
      const text = await res.text();
      document.getElementById('editorText').value = text;
      document.getElementById('saveStatus').innerText = "";
    } catch (e) {
      alert("Error loading file: "+ e.message);
      closeEditor();
    }
  }

  function closeEditor() {
    document.getElementById('editorModal').style.display = 'none';
    document.getElementById('editorText').value = "";
    currentEditingPath = "";
  }

  async function saveEditorContent() {
    if (!currentEditingPath) return;
    const btn = document.getElementById('saveBtn');
    const status = document.getElementById('saveStatus');
    btn.disabled = true;
    status.innerText = "Saving to Kindle...";

    try {
      const text = document.getElementById('editorText').value;
      const res = await fetch('/api/save?path=' + encodeURIComponent(currentEditingPath), {
        method: 'POST',
        headers: { 'Content-Type': 'text/plain' },
        body: text
      });

      if (!res.ok) throw new Error("Failed to save file.");
      status.innerText = "Saved!";
      showToast("File saved successfully!");
      setTimeout(() => { status.innerText = ""; }, 2000);
    } catch (e) {
      alert("Error saving: "+ e.message);
      status.innerText = "Save failed!";
    } finally {
      btn.disabled = false;
    }
  }

  async function uploadFiles(e) {
    e.preventDefault();
    const files = document.getElementById('fileInput').files;
    if (!files.length) return alert("Select at least one file to upload.");

    const p = document.getElementById('uploadProgress');
    p.style.display = 'block';

    for (let i = 0; i < files.length; i++) {
      const file = files[i];
      p.innerText = `Uploading (${i+1}/${files.length}): ${file.name}...`;
      const targetPath = "{{CURRENT_PATH}}/"+ file.name;

      await fetch('/api/upload?path=' + encodeURIComponent(targetPath), {
        method: 'POST',
        body: file
      });
    }

    p.innerText = "Upload complete!";
    showToast("Books uploaded successfully!");
    setTimeout(() => { location.reload(); }, 800);
  }

  async function deleteItem(path, isDir) {
    if (!confirm("Are you sure you want to delete this "+ (isDir ? "folder": "file") + "?")) return;
    try {
      const res = await fetch('/api/delete?path=' + encodeURIComponent(path), { method: 'POST' });
      if (!res.ok) throw new Error("Delete failed");
      showToast("Deleted successfully.");
      location.reload();
    } catch(e) {
      alert("Error: "+ e.message);
    }
  }

  async function createNewFolder() {
    const name = prompt("Enter new folder name:");
    if (!name) return;
    const base = "{{CURRENT_PATH}}";
    const target = (base === "/"? "": base) + "/"+ name;
    try {
      const res = await fetch('/api/mkdir?path=' + encodeURIComponent(target), { method: 'POST' });
      if (!res.ok) throw new Error("Could not create folder");
      location.reload();
    } catch(e) {
      alert("Error: "+ e.message);
    }
  }
</script>
</body>
</html>]]

    local html = HTML_TEMPLATE
    local safe_path = rel_path:gsub("%%", "%%%%")
    local safe_rows = table.concat(rows_html, "\n"):gsub("%%", "%%%%")
    html = html:gsub("{{CURRENT_PATH}}", safe_path)
    html = html:gsub("{{ROWS_HTML}}", safe_rows)
    return html
end

--------------------------------------------------------------------------------
-- WEBDAV XML GENERATOR (for iOS Files App & Android CX/Solid Explorer)
--------------------------------------------------------------------------------

local function generateWebDavPropfind(current_path, base_root, depth)
    local target_mode = lfs.attributes(current_path, "mode")
    if not target_mode then
        return nil
    end

    local rel_base = current_path:sub(#base_root + 1)
    if rel_base == "" then rel_base = "/" end

    local responses = {}

    if target_mode == "file" then
        local size = lfs.attributes(current_path, "size") or 0
        local name = rel_base:match("([^/]+)$") or "file"
        table.insert(responses, string.format([[
  <D:response>
    <D:href>%s</D:href>
    <D:propstat>
      <D:prop>
        <D:resourcetype/>
        <D:displayname>%s</D:displayname>
        <D:getcontentlength>%d</D:getcontentlength>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>]], rel_base, name, size))
    else
        -- Collection / directory
        if rel_base:sub(-1) ~= "/" then rel_base = rel_base .. "/" end
        local dir_name = rel_base == "/" and "Kindle Storage" or (rel_base:match("([^/]+)/$") or "folder")
        table.insert(responses, string.format([[
  <D:response>
    <D:href>%s</D:href>
    <D:propstat>
      <D:prop>
        <D:resourcetype><D:collection/></D:resourcetype>
        <D:displayname>%s</D:displayname>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>]], rel_base, dir_name))

        -- Children if depth > 0
        if depth ~= "0" then
            pcall(function()
                for entry in lfs.dir(current_path) do
                    if entry ~= "." and entry ~= ".." then
                        local full = current_path .. "/".. entry
                        local mode = lfs.attributes(full, "mode")
                        local size = lfs.attributes(full, "size") or 0
                        local href = rel_base .. urlEncode(entry)

                        if mode == "directory" then
                            table.insert(responses, string.format([[
  <D:response>
    <D:href>%s/</D:href>
    <D:propstat>
      <D:prop>
        <D:resourcetype><D:collection/></D:resourcetype>
        <D:displayname>%s</D:displayname>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>]], href, entry))
                        elseif mode == "file" then
                            table.insert(responses, string.format([[
  <D:response>
    <D:href>%s</D:href>
    <D:propstat>
      <D:prop>
        <D:resourcetype/>
        <D:displayname>%s</D:displayname>
        <D:getcontentlength>%d</D:getcontentlength>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>]], href, entry, size))
                        end
                    end
                end
            end)
        end
    end

    return string.format([[<?xml version="1.0"encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
%s
</D:multistatus>]], table.concat(responses, "\n"))
end

--------------------------------------------------------------------------------
-- HTTP REQUEST HANDLER
--------------------------------------------------------------------------------

function WebServer:handleClient(client)
    local line = client:receive("*l")
    if not line then return end

    local method, raw_uri, proto = line:match("^(%u+)%s+(%S+)%s+(%S+)$")
    if not method or not raw_uri then return end

    -- Read headers
    local headers = {}
    while true do
        local hline = client:receive("*l")
        if not hline or hline == "" then break end
        local k, v = hline:match("^([^:]+):%s*(.*)$")
        if k and v then
            headers[k:lower()] = v
        end
    end

    local base_root = self.settings:get("web_root") or "/mnt/us"
    local full_path, clean_rel = sanitizePath(base_root, raw_uri)

    -- Extract query param ?path= if present
    local query_path = raw_uri:match("[?&]path=([^&]+)")
    if query_path then
        query_path = urlDecode(query_path)
        full_path = sanitizePath(base_root, query_path)
    end

    -- 1. WEBDAV OPTIONS (Queried by iOS Files App & Windows Explorer)
    if method == "OPTIONS" then
        client:send("HTTP/1.1 200 OK\r\n"..
                    "DAV: 1, 2\r\n"..
                    "MS-Author-Via: DAV\r\n"..
                    "Allow: OPTIONS, GET, HEAD, POST, PUT, DELETE, PROPFIND, MKCOL, MOVE, COPY\r\n"..
                    "Content-Length: 0\r\n"..
                    "Connection: close\r\n\r\n")
        return
    end

    -- 2. WEBDAV PROPFIND (Directory listing for iOS Files / Windows Drive)
    if method == "PROPFIND" then
        local depth = headers["depth"] or "1"
        local xml = generateWebDavPropfind(full_path, base_root, depth)
        if not xml then
            client:send("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found")
            return
        end
        client:send("HTTP/1.1 207 Multi-Status\r\n"..
                    "Content-Type: application/xml; charset=utf-8\r\n"..
                    "Content-Length: ".. #xml .. "\r\n"..
                    "Connection: close\r\n\r\n".. xml)
        return
    end

    -- 3. API: Read file text for live code editing
    if method == "GET" and raw_uri:match("^/api/read") then
        local f = io.open(full_path, "r")
        if f then
            local content = f:read("*a") or ""
            f:close()
            client:send("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ".. #content .. "\r\nConnection: close\r\n\r\n".. content)
        else
            client:send("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found")
        end
        return
    end

    -- 4. API: Save edited file text
    if method == "POST" and raw_uri:match("^/api/save") then
        local len = tonumber(headers["content-length"]) or 0
        local body = ""
        if len > 0 then
            body = client:receive(len) or ""
        end
        local f = io.open(full_path, "w")
        if f then
            f:write(body)
            f:close()
            client:send("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
        else
            client:send("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 5\r\nConnection: close\r\n\r\nError")
        end
        return
    end

    -- 5. API: Upload binary book/file (or WebDAV PUT)
    if (method == "POST" and raw_uri:match("^/api/upload")) or method == "PUT" then
        local len = tonumber(headers["content-length"]) or 0
        local f = io.open(full_path, "wb")
        if not f then
            client:send("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 12\r\nConnection: close\r\n\r\nCannot write")
            return
        end

        local received = 0
        local chunk_size = 65536
        while received < len do
            local to_read = math.min(chunk_size, len - received)
            local chunk = client:receive(to_read)
            if not chunk then break end
            f:write(chunk)
            received = received + #chunk
        end
        f:close()

        local status_code = (method == "PUT") and "201 Created" or "200 OK"
        client:send("HTTP/1.1 ".. status_code .. "\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
        return
    end

    -- 6. API: Delete item (or WebDAV DELETE)
    if (method == "POST" and raw_uri:match("^/api/delete")) or method == "DELETE" then
        local mode = lfs.attributes(full_path, "mode")
        if mode == "directory" then
            pcall(lfs.rmdir, full_path)
        else
            pcall(os.remove, full_path)
        end
        client:send("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
        return
    end

    -- 7. API: Create folder (or WebDAV MKCOL)
    if (method == "POST" and raw_uri:match("^/api/mkdir")) or method == "MKCOL" then
        local mode = lfs.attributes(full_path, "mode")
        if mode then
            local code = (method == "MKCOL") and "405 Method Not Allowed" or "400 Bad Request"
            client:send("HTTP/1.1 ".. code .. "\r\nContent-Length: 14\r\nConnection: close\r\n\r\nAlready exists")
            return
        end
        local ok, err = pcall(lfs.mkdir, full_path)
        local status_code = ok and ((method == "MKCOL") and "201 Created" or "200 OK") or "500 Internal Server Error"
        client:send("HTTP/1.1 ".. status_code .. "\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
        return
    end

    -- 8. Download binary file
    if method == "GET" and (raw_uri:match("^/download") or lfs.attributes(full_path, "mode") == "file") then
        local f = io.open(full_path, "rb")
        if not f then
            client:send("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found")
            return
        end
        local size = lfs.attributes(full_path, "size") or 0
        client:send(string.format("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", size))

        local chunk_size = 65536
        while true do
            local chunk = f:read(chunk_size)
            if not chunk or #chunk == 0 then break end
            client:send(chunk)
        end
        f:close()
        return
    end

    -- 9. Mobile Web App Interface (Home / Folder Browser)
    local mode = lfs.attributes(full_path, "mode")
    if mode == "directory" then
        local html = generateMobileHtml(full_path, base_root)
        client:send("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ".. #html .. "\r\nConnection: close\r\n\r\n".. html)
        return
    end

    client:send("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found")
end

--------------------------------------------------------------------------------
-- LIFECYCLE CONTROLS
--------------------------------------------------------------------------------

function WebServer:start()
    if self.is_running then return true end

    local port = tonumber(self.settings:get("web_port")) or 8080
    local s, err = socket.bind("*", port)
    if not s then
        return false, tostring(err)
    end

    -- Open firewall port for incoming Wi-Fi connections
    if self.manager and self.manager.openFirewallPort then
        self.manager:openFirewallPort(port)
    end

    s:settimeout(0.01) -- 10ms timeout for non-blocking accept
    self.server = s
    self.is_running = true

    -- Hook directly into KOReader's master event loop so the loop never sleeps on touchscreen wait
    pcall(function()
        UIManager:insertZMQ(self)
    end)

    -- Start backup polling loop
    self:pollLoop()
    return true
end

function WebServer:stop()
    self.is_running = false

    pcall(function()
        UIManager:removeZMQ(self)
    end)

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
    client:settimeout(5)
    local ok, err = pcall(function()
        self:handleClient(client)
    end)
    if not ok and err then
        pcall(function()
            local msg = "500 Internal Server Error\n\n".. tostring(err)
            client:send("HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nContent-Length: ".. #msg .. "\r\nConnection: close\r\n\r\n".. msg)
        end)
    end
    pcall(function() client:close() end)
end

-- Called automatically by KOReader's master event loop (UIManager:processZMQs)
function WebServer:waitEvent()
    if not self.is_running or not self.server then return nil end

    local client = self.server:accept()
    if client then
        self:processClient(client)
    end
    return nil
end

function WebServer:pollLoop()
    if not self.is_running or not self.server then return end

    -- Check for incoming connection
    local client = self.server:accept()
    if client then
        self:processClient(client)
    end

    -- Reschedule next backup check
    if self.is_running then
        UIManager:scheduleIn(0.2, function()
            self:pollLoop()
        end)
    end
end

function WebServer:isRunning()
    return self.is_running
end

return WebServer
