---@brief HTTP + SSE server built on vim.uv (libuv).
---
--- One TCP server per Neovim instance, started lazily and bound to localhost.
--- Each previewed buffer registers a "preview" (an unguessable token) that owns
--- three routes:
---   GET /p/<token>        rendered preview page (HTML shell)
---   GET /events/<token>   Server-Sent Events stream pushing buffer content
---   GET /f/<token>/<path> files resolved relative to the buffer's directory
--- Plus shared routes:
---   GET /                 index of active previews
---   GET /assets/<path>    plugin frontend assets (immutable-cached)
---   POST /sync/<token>    browser -> editor messages (cursor line, checkbox)
---   POST /prefs/<token>   browser -> editor page-preference changes
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

local state = {
  tcp = nil, ---@type uv.uv_tcp_t?
  host = nil, ---@type string?
  port = nil, ---@type integer?
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
  prefs = {}, ---@type table<string, string> page preferences, mirrored to disk
}

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
local asset_dir = plugin_root .. '/assets'

local MAX_HEADER_BYTES = 16 * 1024
local MAX_BODY_BYTES = 4 * 1024 -- POST bodies are tiny sync messages

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
  "img-src 'self' data: https: http:",
  "media-src 'self' data: https: http:",
  "style-src 'self' 'unsafe-inline'",
  "script-src 'self'",
  "connect-src 'self'",
}, '; ')

local function page_shell(title, boot_json, cb)
  local function build(tpl)
    local subst = {
      TITLE = http.html_escape(title),
      THEME = state.theme,
      COLOR_SCHEME = state.theme == 'auto' and 'light dark' or state.theme,
      CSS_LINKS = css_links(state.theme),
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

local function route_page(sock, token)
  local pv = state.previews[token]
  if not pv then
    return respond(
      sock,
      404,
      { ['Content-Type'] = MIME.html },
      '<!DOCTYPE html><meta charset="utf-8"><title>mdpv</title>'
        .. '<p style="font-family:sans-serif">This preview has been closed. '
        .. '<a href="/">Active previews</a></p>'
    )
  end
  -- Buffer content is embedded for an instant first paint, and reading it
  -- requires the main loop.
  vim.schedule(function()
    if not state.previews[token] then
      return respond(sock, 404)
    end
    local boot_json = pv.payload()
    if not boot_json then
      return respond(sock, 404)
    end
    page_shell(pv.title, boot_json, function(html)
      if not html then
        return respond(sock, 500)
      end
      respond(sock, 200, {
        ['Content-Type'] = MIME.html,
        ['Content-Security-Policy'] = CSP,
      }, html)
    end)
  end)
end

--- Render a markdown file reached through /f/<token>/… as a one-shot page:
--- same shell and renderer as a live preview, but no buffer behind it, so no
--- SSE stream. Relative links keep working because `base` points the client
--- at this file's directory within the token's file namespace.
local function route_static_md(sock, token, rel, fpath)
  files.read(fpath, function(data, err)
    if not data then
      return respond(sock, err == 'toobig' and 413 or 404)
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
        return respond(sock, 500) -- e.g. not valid UTF-8
      end
      page_shell(title, boot_json, function(html)
        if not html then
          return respond(sock, 500)
        end
        respond(sock, 200, {
          ['Content-Type'] = MIME.html,
          ['Content-Security-Policy'] = CSP,
        }, html)
      end)
    end)
  end)
end

local function route_events(sock, token)
  local pv = state.previews[token]
  if not pv then
    return respond(sock, 404)
  end
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
    }, '\r\n')
  )
  if not ok then
    return close_sock(sock)
  end
  pv.clients[sock] = true
  -- Initial content push needs buffer access -> main loop.
  vim.schedule(function()
    if not state.previews[token] or sock:is_closing() then
      return
    end
    local json = pv.payload()
    if json then
      pcall(sock.write, sock, sse_frame('update', json))
    end
  end)
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

local function route_index(sock)
  local rows = {}
  for _, pv in pairs(state.previews) do
    rows[#rows + 1] = ('<li><a href="/p/%s">%s</a></li>'):format(pv.token, http.html_escape(pv.title))
  end
  table.sort(rows)
  local body = table.concat({
    '<!DOCTYPE html><html><head><meta charset="utf-8"><title>mdpv</title>',
    '<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">',
    '<style>body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;',
    'max-width:640px;margin:48px auto;padding:0 16px;color:#1f2328;background:#fff}',
    'a{color:#0969da;text-decoration:none}a:hover{text-decoration:underline}',
    'li{margin:4px 0}h1{font-size:20px}',
    '@media(prefers-color-scheme:dark){body{color:#f0f6fc;background:#0d1117}a{color:#4493f8}}',
    '</style></head><body><h1>mdpv &mdash; active previews</h1>',
    #rows > 0 and ('<ul>' .. table.concat(rows) .. '</ul>') or '<p>No active previews.</p>',
    '</body></html>',
  })
  respond(sock, 200, { ['Content-Type'] = MIME.html }, body)
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
    return route_index(sock)
  end

  local token = path:match('^/p/(%x+)$')
  if token then
    return route_page(sock, token)
  end

  token = path:match('^/events/(%x+)$')
  if token then
    return route_events(sock, token)
  end

  local rel = path:match('^/assets/(.+)$')
  if rel then
    rel = http.percent_decode(rel)
    if not http.is_confined(rel) then
      return respond(sock, 403)
    end
    return files.serve(sock, asset_dir .. '/' .. rel, 'public, max-age=31536000, immutable', req)
  end

  local ftoken, frel = path:match('^/f/(%x+)/(.+)$')
  if ftoken then
    local pv = state.previews[ftoken]
    if not pv then
      return respond(sock, 404)
    end
    frel = http.percent_decode(frel):gsub('^/+', '')
    -- Same confinement as /assets/: reject NUL, absolute paths, and any `..`
    -- segment so a token holder cannot traverse out of the file's directory.
    if not http.is_confined(frel) then
      return respond(sock, 403)
    end
    local fpath = pv.dir .. '/' .. frel
    -- Markdown files render as a page (GitHub-style), so relative .md links
    -- are followable. `?raw` serves the bytes instead.
    local low = frel:lower()
    if (low:match('%.md$') or low:match('%.markdown$')) and not http.has_param(query, 'raw') then
      return route_static_md(sock, ftoken, frel, fpath)
    end
    if state.reload_images then
      watch.add(ftoken, fpath, frel)
    end
    return files.serve(sock, fpath, nil, req)
  end

  return respond(sock, 404)
end

------------------------------------------------------------------------------
-- Connection handling
------------------------------------------------------------------------------

local function prune_client(sock)
  for _, pv in pairs(state.previews) do
    pv.clients[sock] = nil
  end
  close_sock(sock)
end

local function on_connection()
  local sock = uv.new_tcp()
  if not sock then
    return
  end
  state.tcp:accept(sock)
  local chunks, handled = {}, false
  local head_end, body_len -- set once the request head has fully arrived
  sock:read_start(function(err, chunk)
    if err or not chunk then
      return prune_client(sock)
    end
    if handled then
      return -- ignore pipelined/extra data
    end
    chunks[#chunks + 1] = chunk
    local data = table.concat(chunks)
    if not head_end then
      if #data > MAX_HEADER_BYTES then
        handled = true
        return respond(sock, 431)
      end
      head_end = data:find('\r\n\r\n', 1, true)
      if not head_end then
        return -- keep accumulating headers
      end
      -- Only POST carries a body here (sync messages). No Content-Length
      -- means a body-less POST; chunked encoding is not supported. Header
      -- names are case-insensitive per RFC 9110.
      if data:match('^POST%s') then
        body_len = tonumber(data:sub(1, head_end + 3):lower():match('content%-length:%s*(%d+)\r\n')) or 0
        if body_len > MAX_BODY_BYTES then
          handled = true
          return respond(sock, 413)
        end
      end
    end
    if body_len and #data < head_end + 3 + body_len then
      return -- body still streaming in
    end
    handled = true
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
    return true
  end
  state.theme = config.theme
  state.features = {
    math = config.math == false and false or (type(config.math) == 'table' and config.math or true),
    mermaid = config.mermaid ~= false,
    emoji = config.emoji ~= false,
    wikilinks = config.wikilinks ~= false,
  }
  state.reload_images = config.reload_images ~= false
  state.prefs = load_prefs() -- M.start runs on the main loop (user command)
  local tcp = uv.new_tcp()
  if not tcp then
    return false, 'could not create TCP handle'
  end
  local ok, err = pcall(function()
    local bok, berr = tcp:bind(config.host, config.port)
    assert(bok == 0 or bok == true or bok == nil and not berr, berr or 'bind failed')
    local lok, lerr = tcp:listen(128, function(lerr2)
      if not lerr2 then
        on_connection()
      end
    end)
    assert(lok == 0 or lok == true or lok == nil and not lerr, lerr or 'listen failed')
  end)
  if not ok then
    pcall(tcp.close, tcp)
    return false, ('could not bind %s:%d (%s)'):format(config.host, config.port, err)
  end
  state.tcp = tcp
  state.host = config.host
  state.port = tcp:getsockname().port
  state.buster = tostring(os.time())

  -- SSE heartbeat: keeps proxies/browsers from timing out idle streams and
  -- flushes out dead sockets via write errors.
  state.heartbeat = uv.new_timer()
  state.heartbeat:start(30000, 30000, function()
    for _, pv in pairs(state.previews) do
      for client in pairs(pv.clients) do
        if client:is_closing() then
          pv.clients[client] = nil
        else
          local wok = pcall(client.write, client, ': hb\n\n', function(werr)
            if werr then
              prune_client(client)
            end
          end)
          if not wok then
            pv.clients[client] = nil
          end
        end
      end
    end
  end)
  return true
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
    if notify and not sock:is_closing() then
      local ok = pcall(sock.write, sock, sse_frame('close', '{}'), function()
        close_sock(sock)
      end)
      if not ok then
        close_sock(sock)
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
  local frame = sse_frame(event, data)
  for sock in pairs(pv.clients) do
    if sock:is_closing() then
      pv.clients[sock] = nil
    else
      local ok = pcall(sock.write, sock, frame, function(werr)
        if werr then
          prune_client(sock)
        end
      end)
      if not ok then
        pv.clients[sock] = nil
      end
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
  for token in pairs(state.previews) do
    M.close_preview(token, true)
  end
  if state.tcp then
    close_sock(state.tcp)
    state.tcp = nil
  end
  state.host, state.port, state.template = nil, nil, nil
end

return M
