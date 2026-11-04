---@brief HTTP + SSE server built on vim.uv (libuv).
---
--- One TCP server per Neovim instance, started lazily and bound to localhost.
--- Each previewed buffer registers a "preview" (an unguessable token) that owns
--- five routes:
---   GET /p/<token>        rendered preview page (HTML shell)
---   GET /events/<token>   Server-Sent Events stream pushing buffer content
---   GET /f/<token>/<path> files resolved relative to the buffer's directory
---   POST /sync/<token>    browser -> editor messages (cursor line, checkbox)
---   POST /prefs/<token>   browser -> editor page-preference changes
--- Plus shared routes:
---   GET /                 server status page (never exposes preview tokens)
---   GET /assets/<path>    plugin frontend assets (immutable-cached)
---
--- This module owns routing, the SSE streams, and the connection lifecycle;
--- wire-level helpers live in mdpv.http, file responses in mdpv.files, and
--- the served-file watchers (live image reload) in mdpv.watch.
---
--- All socket callbacks run in libuv's fast context: no vim.api calls happen
--- there. Anything that needs buffer state hops to the main loop via
--- vim.schedule.

local uv = vim.uv
local http = require('mdpv.http')
local files = require('mdpv.files')
local watch = require('mdpv.watch')

local respond, close_sock, sse_frame = http.respond, http.close_sock, http.sse_frame
local MIME = http.MIME

local M = {}

-- Declared before routing because an SSE client is registered before its
-- response head has finished flushing.
local pending_frame, write_client, queue_client, prune_client

local state = {
  tcp = nil, ---@type uv.uv_tcp_t?
  host = nil, ---@type string?
  port = nil, ---@type integer?
  requested_port = nil, ---@type integer?
  theme = 'auto',
  previews = {}, ---@type table<string, mdpv.Preview> token -> preview
  heartbeat = nil, ---@type uv.uv_timer_t?
  -- Cache-buster appended to asset URLs. Assets are served immutable for
  -- speed; a per-session version keeps plugin updates from being masked by
  -- stale browser caches (a recurring bug class in similar plugins).
  buster = '0',
  -- Renderer feature flags shipped to static .md pages, which have no
  -- preview payload to carry them.
  features = { math = true, mermaid = true, emoji = true, wikilinks = true },
  template = nil, ---@type string? assets/index.html, read once per server run
  reload_images = true, -- watch served files and push `assets` events on change
  attachment_dirs = {}, ---@type string[] fallback dirs for bare-name embeds
  css = {}, ---@type string[] user stylesheets inlined into the page
  user_css_html = '', -- inlined <style> blocks, rebuilt on reconfigure
  prefs = {}, ---@type table<string, string> page preferences, mirrored to disk
  connections = {}, ---@type table<uv.uv_tcp_t, true>
  connection_count = 0,
}

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
local asset_dir = plugin_root .. '/assets'

local MAX_HEADER_BYTES = 16 * 1024
local MAX_BODY_BYTES = 4 * 1024 -- POST bodies are tiny sync messages
local MAX_CONNECTIONS = 256
local REQUEST_TIMEOUT_MS = 3000

--- Theme -> stylesheets injected into the page shell.
local THEME_CSS = {
  auto = { 'vendor/github-markdown.css', 'vendor/hljs-github-auto.css' },
  light = { 'vendor/github-markdown-light.css', 'vendor/github.min.css' },
  dark = { 'vendor/github-markdown-dark.css', 'vendor/github-dark.min.css' },
}

-- The ids let the client's theme toggle swap in another theme's pair.
local CSS_IDS = { 'mdpv-css-md', 'mdpv-css-hljs' }

local function css_links(theme)
  local out = {}
  for i, rel in ipairs(THEME_CSS[theme] or THEME_CSS.auto) do
    out[#out + 1] = ('<link rel="stylesheet" id="%s" href="/assets/%s?v=%s">'):format(CSS_IDS[i], rel, state.buster)
  end
  return table.concat(out, '\n')
end

-- User stylesheets are inlined (not linked) so no extra file routes are
-- needed, and they land after mdpv.css so their rules win the cascade.
-- Read on the main loop (from apply_runtime_config), not at page-build time:
-- the build runs in a uv fast context where vim.fn is unavailable.
local function read_user_css(paths)
  local styles = {}
  for _, path in ipairs(paths) do
    local expanded = vim.fn.expand(path)
    if vim.fn.filereadable(expanded) == 0 then
      vim.notify('mdpv: css file not readable: ' .. path, vim.log.levels.WARN)
    else
      local lines = vim.fn.readfile(expanded)
      styles[#styles + 1] = '<style>\n' .. table.concat(lines, '\n') .. '\n</style>'
    end
  end
  return table.concat(styles, '\n')
end

local function features_for(config)
  return {
    math = config.math == false and false or (type(config.math) == 'table' and config.math or true),
    mermaid = config.mermaid ~= false,
    emoji = config.emoji ~= false,
    wikilinks = config.wikilinks ~= false,
  }
end

local function apply_runtime_config(config)
  local old_reload = state.reload_images
  local features = features_for(config)
  local changed = state.theme ~= config.theme
    or not vim.deep_equal(state.features, features)
    or old_reload ~= (config.reload_images ~= false)
    or not vim.deep_equal(state.css, config.css or {})
  state.theme = config.theme
  state.features = features
  state.reload_images = config.reload_images ~= false
  state.attachment_dirs = config.attachment_dirs or {}
  state.css = config.css or {}
  state.user_css_html = read_user_css(state.css)
  if old_reload and not state.reload_images then
    for token in pairs(state.previews) do
      watch.drop(token)
    end
  end
  return changed
end

------------------------------------------------------------------------------
-- Page preferences
------------------------------------------------------------------------------
-- The page's choices (theme, outline, sync switches, corners) live in
-- localStorage, but localStorage is per-origin and the default ephemeral port
-- makes every Neovim session a new origin. The editor keeps the authoritative
-- copy in a state file: pages POST changes here, and the current set ships in
-- the page shell to seed a fresh origin with the last session's choices.

-- Key -> allowed values. The file is user-editable and the values land in the
-- page, so anything outside this table is dropped, never shipped.
local BOOL_PREF = { ['0'] = true, ['1'] = true }
local CORNER_PREF = { tl = true, tr = true, bl = true, br = true }
local PREF_VALUES = {
  ['mdpv-theme'] = { auto = true, light = true, dark = true },
  ['mdpv-wide'] = BOOL_PREF,
  ['mdpv-outline'] = BOOL_PREF,
  ['mdpv-follow'] = BOOL_PREF,
  ['mdpv-sync-back'] = BOOL_PREF,
  ['mdpv-fab-corner'] = CORNER_PREF,
  ['mdpv-toc-corner'] = CORNER_PREF,
}

-- Main loop only (stdpath), like everything below that touches the file.
local function prefs_path()
  return vim.fn.stdpath('state') .. '/mdpv-prefs.json'
end

---@return table<string, string> only the known keys of `t` with known values
local function sanitize_prefs(t)
  local out = {}
  if type(t) == 'table' then
    for key, allowed in pairs(PREF_VALUES) do
      local v = t[key]
      if type(v) == 'string' and allowed[v] then
        out[key] = v
      end
    end
  end
  return out
end

local function load_prefs()
  local f = io.open(prefs_path(), 'r')
  if not f then
    return {}
  end
  local data = f:read('*a')
  f:close()
  local ok, t = pcall(vim.json.decode, data)
  return sanitize_prefs(ok and t)
end

local function save_prefs()
  local path = prefs_path()
  local f = io.open(path, 'w')
  if not f then
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    f = io.open(path, 'w')
    if not f then
      return -- unwritable state dir: prefs just stay session-local
    end
  end
  f:write(vim.json.encode(next(state.prefs) and state.prefs or vim.empty_dict()))
  f:close()
end

local function prefs_json()
  return vim.json.encode(next(state.prefs) and state.prefs or vim.empty_dict())
end

------------------------------------------------------------------------------
-- Routes
------------------------------------------------------------------------------

local CSP = table.concat({
  "default-src 'self'",
  "base-uri 'none'",
  "object-src 'none'",
  "frame-ancestors 'none'",
  "img-src 'self' data: https: http:",
  "media-src 'self' data: https: http:",
  "style-src 'self' 'unsafe-inline'",
  "script-src 'self'",
  "connect-src 'self'",
}, '; ')

local function page_headers(content_type)
  return {
    ['Content-Type'] = content_type or MIME.html,
    ['Cache-Control'] = 'no-store',
    ['Content-Security-Policy'] = CSP,
    ['Referrer-Policy'] = 'no-referrer',
    ['X-Content-Type-Options'] = 'nosniff',
    ['X-Frame-Options'] = 'DENY',
  }
end

local function page_shell(title, boot_json, cb)
  local function build(tpl)
    local subst = {
      TITLE = http.html_escape(title),
      THEME = state.theme,
      COLOR_SCHEME = state.theme == 'auto' and 'light dark' or state.theme,
      CSS_LINKS = css_links(state.theme),
      USER_CSS = state.user_css_html,
      V = state.buster,
      -- Boot data ships in a non-executable JSON data block (inline scripts
      -- would violate the page's own CSP). Escaping '<' as unicode prevents
      -- '</script>' breakout and is transparent to JSON.parse.
      BOOT = (boot_json:gsub('<', '\\u003c')),
      PREFS = (prefs_json():gsub('<', '\\u003c')),
    }
    cb((tpl:gsub('{{([%u_]+)}}', subst)))
  end
  if state.template then
    return build(state.template)
  end
  files.read(asset_dir .. '/index.html', function(tpl)
    if not tpl then
      return cb(nil)
    end
    state.template = tpl
    build(tpl)
  end)
end

---@return mdpv.SseClient
local function new_sse_client()
  return {
    assets = {},
    other = {},
    pending_bytes = 0,
    writing = false,
  }
end

local function route_page(sock, token, req)
  local pv = state.previews[token]
  if not pv then
    return respond(
      sock,
      404,
      page_headers(MIME.html),
      '<!DOCTYPE html><meta charset="utf-8"><title>mdpv</title>'
        .. '<p style="font-family:sans-serif">This preview has been closed. '
        .. '<a href="/">Open previews from Neovim</a></p>',
      req.head_only
    )
  end
  -- Buffer content is embedded for an instant first paint, and reading it
  -- requires the main loop.
  vim.schedule(function()
    if not state.previews[token] then
      return respond(sock, 404, nil, nil, req.head_only)
    end
    local boot_json = pv.payload()
    if not boot_json then
      return respond(sock, 404, nil, nil, req.head_only)
    end
    page_shell(pv.title, boot_json, function(html)
      if not html then
        return respond(sock, 500, nil, nil, req.head_only)
      end
      respond(sock, 200, page_headers(MIME.html), html, req.head_only)
    end)
  end)
end

--- Render a markdown file reached through /f/<token>/… as a one-shot page:
--- same shell and renderer as a live preview, but no buffer behind it, so no
--- SSE stream. Relative links keep working because `base` points the client
--- at this file's directory within the token's file namespace.
local function route_static_md(sock, token, rel, fpath, req)
  files.read(fpath, function(data, err)
    if not data then
      return respond(sock, err == 'toobig' and 413 or 404, nil, nil, req.head_only)
    end
    vim.schedule(function()
      local title = rel:match('([^/]+)$') or rel
      local dir = rel:match('^(.+)/[^/]+$')
      local base = '/f/' .. token .. (dir and ('/' .. dir) or '')
      local ok, boot_json = pcall(vim.json.encode, {
        token = token,
        title = title,
        md = data,
        static = true,
        base = base,
        features = state.features,
      })
      if not ok then
        return respond(sock, 500, nil, nil, req.head_only) -- e.g. not valid UTF-8
      end
      page_shell(title, boot_json, function(html)
        if not html then
          return respond(sock, 500, nil, nil, req.head_only)
        end
        respond(sock, 200, page_headers(MIME.html), html, req.head_only)
      end)
    end)
  end)
end

local function route_events(sock, token, req, since)
  local pv = state.previews[token]
  if not pv then
    return respond(sock, 404, nil, nil, req.head_only)
  end
  if req.head_only then
    return respond(sock, 200, {
      ['Content-Type'] = 'text/event-stream',
      ['Cache-Control'] = 'no-cache',
      ['X-Accel-Buffering'] = 'no',
    }, '', true, true)
  end
  local client = new_sse_client()
  client.writing = true
  pv.clients[sock] = client
  local ok = pcall(
    sock.write,
    sock,
    table.concat({
      'HTTP/1.1 200 OK',
      'Content-Type: text/event-stream',
      'Cache-Control: no-cache',
      'Connection: keep-alive',
      'X-Accel-Buffering: no',
      '',
      'retry: 1000\n\n',
    }, '\r\n'),
    function(werr)
      if werr then
        return prune_client(sock)
      end
      client.writing = false
      if client.closing then
        client.closing = false
        return write_client(pv, sock, client, client.close_frame, true)
      end
      if pv.clients[sock] ~= client or sock:is_closing() then
        return
      end
      local frame, is_close = pending_frame(client)
      if frame then
        write_client(pv, sock, client, frame, is_close)
      end
      -- Initial content push needs buffer access -> main loop. Queue it only for
      -- this connection; broadcasting it would duplicate work for every client.
      vim.schedule(function()
        if not state.previews[token] or pv.clients[sock] ~= client or sock:is_closing() then
          return
        end
        if since == nil or since ~= pv.revision() then
          local json = pv.payload()
          if json then
            queue_client(pv, sock, 'update', json)
          end
        end
      end)
    end
  )
  if not ok then
    return prune_client(sock)
  end
  return true -- keep the socket open (SSE)
end

--- Browser -> editor messages, POSTed to /sync/<token>. Two shapes:
---   { line = N }                          scroll sync 'both': move the cursor
---   { toggle = { line = N, checked = b }} task checkbox clicked: flip [ ]/[x]
--- Fire-and-forget: always 204, bad payloads are ignored.
local function route_sync(sock, token, body)
  local pv = state.previews[token]
  if not pv then
    return respond(sock, 404)
  end
  vim.schedule(function()
    local ok, msg = pcall(vim.json.decode, body or '')
    if not (ok and type(msg) == 'table' and state.previews[token]) then
      return
    end
    local toggle = msg.toggle
    if type(toggle) == 'table' and type(toggle.line) == 'number' and pv.on_toggle then
      pv.on_toggle(math.floor(toggle.line), toggle.checked == true)
    elseif type(msg.line) == 'number' and pv.on_sync then
      pv.on_sync(math.floor(msg.line))
    end
  end)
  respond(sock, 204)
end

--- Browser -> editor preference changes, POSTed to /prefs/<token> as a JSON
--- object of localStorage key -> value pairs. Unknown keys and values are
--- dropped; a real change is merged and written through to the state file.
--- Fire-and-forget like /sync: always 204, bad payloads are ignored.
local function route_prefs(sock, token, body)
  if not state.previews[token] then
    return respond(sock, 404)
  end
  vim.schedule(function()
    local ok, msg = pcall(vim.json.decode, body or '')
    if not ok then
      return
    end
    local changed = false
    for key, value in pairs(sanitize_prefs(msg)) do
      if state.prefs[key] ~= value then
        state.prefs[key] = value
        changed = true
      end
    end
    if changed then
      save_prefs()
    end
  end)
  respond(sock, 204)
end

local function route_index(sock, req)
  local body = table.concat({
    '<!DOCTYPE html><html><head><meta charset="utf-8"><title>mdpv</title>',
    '<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">',
    '<style>body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;',
    'max-width:640px;margin:48px auto;padding:0 16px;color:#1f2328;background:#fff}',
    'a{color:#0969da;text-decoration:none}a:hover{text-decoration:underline}',
    'li{margin:4px 0}h1{font-size:20px}',
    '@media(prefers-color-scheme:dark){body{color:#f0f6fc;background:#0d1117}a{color:#4493f8}}',
    '</style></head><body><h1>mdpv server</h1>',
    '<p>Open a preview from Neovim to receive its private URL.</p>',
    '</body></html>',
  })
  respond(sock, 200, page_headers(MIME.html), body, req.head_only)
end

-- Resolve a preview-relative file. When the name is absent next to the note,
-- look it up by bare filename in the attachment directories — Obsidian
-- `![[name.png]]` embeds carry no path, so the attachment folder is the
-- fallback search space.
local function resolve_preview_file(pv, frel, cb)
  files.resolve_confined(pv.dir, pv.dir .. '/' .. frel, function(real, err)
    if real then
      return cb(real, nil)
    end
    local fname = frel:match('[^/]+$')
    local dirs = state.attachment_dirs
    local i = 0
    local function try_next()
      i = i + 1
      local adir = dirs[i]
      if not adir then
        return cb(nil, err)
      end
      files.resolve_confined(adir, adir .. '/' .. fname, function(real2, err2)
        if real2 then
          cb(real2, nil)
        else
          try_next()
        end
      end)
    end
    try_next()
  end)
end

local function handle_request(sock, head, body)
  local method, target = head:match('^(%u+)%s+(%S+)%s+HTTP/1%.[01]\r\n')
  if not method then
    return respond(sock, 400)
  end
  local path = target:gsub('%?.*$', '')
  local query = target:match('%?(.*)$') or ''

  if method == 'POST' then
    local stoken = path:match('^/sync/(%x+)$')
    if stoken then
      return route_sync(sock, stoken, body)
    end
    stoken = path:match('^/prefs/(%x+)$')
    if stoken then
      return route_prefs(sock, stoken, body)
    end
    return respond(sock, 405, { Allow = 'GET, HEAD' })
  end
  if method ~= 'GET' and method ~= 'HEAD' then
    return respond(sock, 405, { Allow = 'GET, HEAD' })
  end
  local req = {
    head_only = method == 'HEAD',
    range = http.req_header(head, 'range'),
    if_modified_since = http.req_header(head, 'if-modified-since'),
  }

  if path == '/' then
    return route_index(sock, req)
  end

  local token = path:match('^/p/(%x+)$')
  if token then
    return route_page(sock, token, req)
  end

  token = path:match('^/events/(%x+)$')
  if token then
    local since = query:match('^since=([^&;]+)') or query:match('&since=([^&;]+)')
    since = since and http.percent_decode(since)
    return route_events(sock, token, req, since)
  end

  local rel = path:match('^/assets/(.+)$')
  if rel then
    rel = http.percent_decode(rel)
    if not http.is_confined(rel) then
      return respond(sock, 403, nil, nil, req.head_only)
    end
    return files.resolve_confined(asset_dir, asset_dir .. '/' .. rel, function(real, err)
      if not real then
        return respond(sock, err == 'outside' and 403 or 404, nil, nil, req.head_only)
      end
      files.serve(sock, real, 'public, max-age=31536000, immutable', req)
    end)
  end

  local ftoken, frel = path:match('^/f/(%x+)/(.+)$')
  if ftoken then
    local pv = state.previews[ftoken]
    if not pv then
      return respond(sock, 404, nil, nil, req.head_only)
    end
    frel = http.percent_decode(frel)
    -- Same confinement as /assets/: reject NUL, absolute paths, and any `..`
    -- segment so a token holder cannot traverse out of the file's directory.
    if not http.is_confined(frel) then
      return respond(sock, 403, nil, nil, req.head_only)
    end
    return resolve_preview_file(pv, frel, function(real, err)
      if not real then
        return respond(sock, err == 'outside' and 403 or 404, nil, nil, req.head_only)
      end
      -- Markdown files render as a page (GitHub-style), so relative .md links
      -- are followable. `?raw` serves the bytes instead.
      local low = frel:lower()
      if (low:match('%.md$') or low:match('%.markdown$')) and not http.has_param(query, 'raw') then
        return route_static_md(sock, ftoken, frel, real, req)
      end
      return files.serve(sock, real, nil, req, {
        secure = true,
        on_open = function(path)
          if state.reload_images and watch.is_watchable(frel) then
            watch.add(ftoken, path, frel)
          end
        end,
      })
    end)
  end

  return respond(sock, 404, nil, nil, req.head_only)
end

------------------------------------------------------------------------------
-- Connection handling
------------------------------------------------------------------------------

prune_client = function(sock)
  if state.connections[sock] then
    state.connections[sock] = nil
    state.connection_count = state.connection_count - 1
  end
  for _, pv in pairs(state.previews) do
    pv.clients[sock] = nil
  end
  close_sock(sock)
end

local MAX_SSE_PENDING_BYTES = 8 * 1024 * 1024

local function pending_assets_frame(client)
  local paths = {}
  for path in pairs(client.assets) do
    paths[#paths + 1] = path
  end
  if #paths == 0 then
    return nil
  end
  table.sort(paths)
  return sse_frame('assets', vim.json.encode({ paths = paths }))
end

pending_frame = function(client)
  if client.closing then
    return client.close_frame, true
  end
  if client.update then
    local frame = client.update
    client.update = nil
    client.pending_bytes = client.pending_bytes - #frame
    return frame
  end
  if client.scroll then
    local frame = client.scroll
    client.scroll = nil
    client.pending_bytes = client.pending_bytes - #frame
    return frame
  end
  if client.assets_frame then
    local frame = client.assets_frame
    client.assets_frame = nil
    client.assets = {}
    client.pending_bytes = client.pending_bytes - #frame
    return frame
  end
  for event, frame in pairs(client.other) do
    client.other[event] = nil
    client.pending_bytes = client.pending_bytes - #frame
    return frame
  end
end

write_client = function(pv, sock, client, frame, close_after)
  if client.writing then
    return
  end
  client.writing = true
  local ok = pcall(sock.write, sock, frame, function(werr)
    if werr then
      prune_client(sock)
      return
    end
    client.writing = false
    if client.closing then
      client.closing = false
      write_client(pv, sock, client, client.close_frame, true)
      return
    end
    if close_after then
      pv.clients[sock] = nil
      close_sock(sock)
      return
    end
    if pv.clients[sock] ~= client then
      return
    end
    local next_frame, is_close = pending_frame(client)
    if next_frame then
      write_client(pv, sock, client, next_frame, is_close)
    end
  end)
  if not ok then
    prune_client(sock)
  end
end

local function clear_pending(client)
  client.update = nil
  client.scroll = nil
  client.assets_frame = nil
  client.assets = {}
  client.other = {}
  client.pending_bytes = 0
end

queue_client = function(pv, sock, event, data, frame)
  local client = pv.clients[sock]
  if not client or sock:is_closing() then
    return
  end
  frame = frame or sse_frame(event, data)
  if not client.writing and client.pending_bytes == 0 then
    return write_client(pv, sock, client, frame)
  end

  if event == 'assets' then
    local ok, payload = pcall(vim.json.decode, data)
    if ok and type(payload) == 'table' and type(payload.paths) == 'table' then
      local old = client.assets_frame
      for _, path in ipairs(payload.paths) do
        if type(path) == 'string' then
          client.assets[path] = true
        end
      end
      client.assets_frame = pending_assets_frame(client)
      client.pending_bytes = client.pending_bytes
        - (old and #old or 0)
        + (client.assets_frame and #client.assets_frame or 0)
    end
  elseif event == 'update' then
    client.pending_bytes = client.pending_bytes - (client.update and #client.update or 0) + #frame
    client.update = frame
  elseif event == 'scroll' then
    client.pending_bytes = client.pending_bytes - (client.scroll and #client.scroll or 0) + #frame
    client.scroll = frame
  else
    client.pending_bytes = client.pending_bytes - (client.other[event] and #client.other[event] or 0) + #frame
    client.other[event] = frame
  end

  if client.pending_bytes > MAX_SSE_PENDING_BYTES then
    pv.clients[sock] = nil
    close_sock(sock)
  end
end

local function sweep_connections()
  local count = 0
  for sock in pairs(state.connections) do
    local ok, closing = pcall(sock.is_closing, sock)
    if not ok or closing then
      state.connections[sock] = nil
    else
      count = count + 1
    end
  end
  state.connection_count = count
end

local function on_connection()
  -- Normal responses close their handles asynchronously. Sweep those handles
  -- before enforcing the cap so sequential requests do not exhaust it.
  sweep_connections()
  local sock = uv.new_tcp()
  if not sock then
    return
  end
  if state.connection_count >= MAX_CONNECTIONS or not state.tcp then
    return close_sock(sock)
  end
  local accepted, accept_err = state.tcp:accept(sock)
  if not (accepted == 0 or accepted == true or accepted == nil and not accept_err) then
    return close_sock(sock)
  end
  state.connections[sock] = true
  state.connection_count = state.connection_count + 1
  local chunks, handled = {}, false
  local head_end, body_len -- set once the request head has fully arrived
  local timeout = uv.new_timer()
  local function stop_timeout()
    if timeout then
      timeout:stop()
      timeout:close()
      timeout = nil
    end
  end
  if not timeout then
    return prune_client(sock)
  end
  local timeout_ok, timeout_err = pcall(function()
    local started, start_err = timeout:start(REQUEST_TIMEOUT_MS, 0, function()
      if not handled then
        handled = true
        stop_timeout()
        prune_client(sock)
      end
    end)
    if not (started == 0 or started == true or started == nil and not start_err) then
      error(start_err or 'request timeout timer failed to start')
    end
  end)
  if not timeout_ok then
    stop_timeout()
    return prune_client(sock)
  end
  sock:read_start(function(err, chunk)
    if err or not chunk then
      stop_timeout()
      return prune_client(sock)
    end
    if handled then
      return -- ignore pipelined/extra data
    end
    chunks[#chunks + 1] = chunk
    local data = table.concat(chunks)
    if not head_end then
      head_end = data:find('\r\n\r\n', 1, true)
      if not head_end then
        if #data > MAX_HEADER_BYTES then
          handled = true
          stop_timeout()
          return respond(sock, 431)
        end
        return -- keep accumulating headers
      end
      if head_end + 3 > MAX_HEADER_BYTES then
        handled = true
        stop_timeout()
        return respond(sock, 431)
      end
      -- Only POST carries a body here (sync messages). No Content-Length
      -- means a body-less POST; chunked encoding is not supported. Header
      -- names are case-insensitive per RFC 9110.
      if data:match('^POST%s') then
        local request_head = data:sub(1, head_end + 3)
        if http.req_header(request_head, 'transfer-encoding') then
          handled = true
          stop_timeout()
          return respond(sock, 400)
        end
        local content_lengths = http.req_headers(request_head, 'content-length')
        if #content_lengths > 1 then
          handled = true
          stop_timeout()
          return respond(sock, 400)
        end
        local content_length = content_lengths[1]
        if content_length and not content_length:match('^%d+$') then
          handled = true
          stop_timeout()
          return respond(sock, 400)
        end
        body_len = content_length and tonumber(content_length) or 0
        if not body_len or body_len % 1 ~= 0 then
          handled = true
          stop_timeout()
          return respond(sock, 400)
        end
        if body_len > MAX_BODY_BYTES then
          handled = true
          stop_timeout()
          return respond(sock, 413)
        end
      end
    end
    if body_len and #data < head_end + 3 + body_len then
      return -- body still streaming in
    end
    handled = true
    stop_timeout()
    chunks = nil
    local head = data:sub(1, head_end + 3)
    local body = body_len and data:sub(head_end + 4, head_end + 3 + body_len) or nil
    -- Handlers own the socket lifecycle: a normal response closes it once the
    -- write flushes, while an SSE stream keeps it open. read_start stays armed
    -- either way, so a client disconnect surfaces as EOF and prunes the socket.
    local ok = pcall(handle_request, sock, head, body)
    if not ok then
      respond(sock, 500)
    end
  end)
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

function M.is_running()
  return state.tcp ~= nil
end

---@param config { host: string, port: integer, theme: string, math?: boolean|table, mermaid?: boolean, emoji?: boolean, wikilinks?: boolean, reload_images?: boolean }
---@return boolean ok, string? err
function M.start(config)
  if state.tcp then
    local ok, err, changed = M.reconfigure(config)
    if ok and changed then
      M.notify_reconfigure()
    end
    return ok, err
  end
  apply_runtime_config(config)
  state.prefs = load_prefs() -- M.start runs on the main loop (user command)
  local tcp = uv.new_tcp()
  if not tcp then
    return false, 'could not create TCP handle'
  end
  local heartbeat
  local ok, err = pcall(function()
    local bok, berr = tcp:bind(config.host, config.port)
    if not (bok == 0 or bok == true or bok == nil and not berr) then
      error(berr or 'bind failed')
    end
    local lok, lerr = tcp:listen(128, function(lerr2)
      if not lerr2 then
        on_connection()
      end
    end)
    if not (lok == 0 or lok == true or lok == nil and not lerr) then
      error(lerr or 'listen failed')
    end
    heartbeat = uv.new_timer()
    if not heartbeat then
      error('could not create heartbeat timer')
    end
    local started, start_err = heartbeat:start(30000, 30000, function()
      for _, pv in pairs(state.previews) do
        for client in pairs(pv.clients) do
          if client:is_closing() then
            pv.clients[client] = nil
          else
            local stream = pv.clients[client]
            if stream and not stream.writing and stream.pending_bytes == 0 then
              write_client(pv, client, stream, ': hb\n\n')
            end
          end
        end
      end
    end)
    if not (started == 0 or started == true or started == nil and not start_err) then
      error(start_err or 'heartbeat timer failed to start')
    end
  end)
  if not ok then
    if heartbeat then
      pcall(heartbeat.close, heartbeat)
    end
    pcall(tcp.close, tcp)
    return false, ('could not bind %s:%d (%s)'):format(config.host, config.port, err)
  end
  state.tcp = tcp
  state.host = config.host
  state.port = tcp:getsockname().port
  state.requested_port = config.port
  -- A high-resolution value keeps immutable asset URLs fresh even when a
  -- fixed-port server is stopped and restarted within the same second.
  state.buster = tostring(uv.hrtime())

  -- SSE heartbeat: keeps proxies/browsers from timing out idle streams and
  -- flushes out dead sockets via write errors.
  state.heartbeat = heartbeat
  return true
end

---@param config table
---@return boolean ok, string? err, boolean? changed
function M.reconfigure(config)
  if not state.tcp then
    return true, nil, false
  end
  if config.host ~= state.host or config.port ~= state.requested_port then
    if next(state.previews) then
      return false, 'host and port cannot change while previews are open; close them first'
    end
    M.stop()
    return M.start(config)
  end
  local changed = apply_runtime_config(config)
  return true, nil, changed
end

function M.notify_reconfigure()
  for token in pairs(state.previews) do
    M.broadcast(token, 'config', '{}')
  end
end

---@param pv mdpv.Preview
function M.register(pv)
  state.previews[pv.token] = pv
end

---@param token string
---@param notify boolean? send a final `close` event to attached clients
function M.close_preview(token, notify)
  local pv = state.previews[token]
  if not pv then
    return
  end
  state.previews[token] = nil
  watch.drop(token)
  for sock in pairs(pv.clients) do
    local client = pv.clients[sock]
    if notify and client and not sock:is_closing() then
      clear_pending(client)
      client.closing = true
      client.close_frame = sse_frame('close', '{}')
      if not client.writing then
        local frame, is_close = pending_frame(client)
        write_client(pv, sock, client, frame, is_close)
      end
    else
      close_sock(sock)
    end
  end
  pv.clients = {}
end

--- Push an SSE event to every client of a preview. Callable from the main loop.
---@param token string
---@param event string
---@param data string JSON payload (single line)
function M.broadcast(token, event, data)
  local pv = state.previews[token]
  if not pv then
    return
  end
  if next(pv.clients) == nil then
    return
  end
  -- The payload is identical for every client. Build the wire frame once;
  -- queue_client only replaces/coalesces it when a client is already busy.
  local frame = sse_frame(event, data)
  for sock in pairs(pv.clients) do
    if sock:is_closing() then
      pv.clients[sock] = nil
    else
      queue_client(pv, sock, event, data, frame)
    end
  end
end

---@param token string
---@return string
function M.url(token)
  return ('http://%s:%d/p/%s'):format(state.host, state.port, token)
end

function M.info()
  local n = 0
  for _ in pairs(state.previews) do
    n = n + 1
  end
  return { host = state.host, port = state.port, previews = n, asset_dir = asset_dir }
end

function M.stop()
  if state.heartbeat then
    state.heartbeat:stop()
    state.heartbeat:close()
    state.heartbeat = nil
  end
  local tokens = {}
  for token in pairs(state.previews) do
    tokens[#tokens + 1] = token
  end
  for _, token in ipairs(tokens) do
    M.close_preview(token, true)
  end
  if state.tcp then
    close_sock(state.tcp)
    state.tcp = nil
  end
  for sock in pairs(state.connections) do
    close_sock(sock)
  end
  state.host, state.port, state.requested_port, state.template = nil, nil, nil, nil
  state.connections = {}
  state.connection_count = 0
end

return M
