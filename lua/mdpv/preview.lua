---@brief Per-buffer preview lifecycle: token allocation, change tracking
--- (debounced), and teardown. One preview per buffer; any number of buffers
--- may be previewed concurrently on the shared server.

local server = require('mdpv.server')

local M = {}

---@class mdpv.SseClient
---@field assets table<string, true>
---@field assets_frame string?
---@field update string?
---@field scroll string?
---@field other table<string, string>
---@field pending_bytes integer
---@field writing boolean
---@field closing boolean?
---@field close_frame string?

---@class mdpv.Preview
---@field token string unguessable route id
---@field bufnr integer
---@field title string tail of the buffer name (or a placeholder)
---@field dir string directory relative file requests resolve against
---@field clients table<uv.uv_tcp_t, mdpv.SseClient> attached SSE sockets and queue state
---@field payload fun(): string? buffer content as JSON (SSE payload and page boot data)
---@field timer uv.uv_timer_t debounce timer
---@field scroll_timer uv.uv_timer_t? cursor-sync debounce timer
---@field on_sync fun(line: integer)? browser->editor cursor move (page's "move cursor on scroll" switch)
---@field on_toggle fun(line: integer, checked: boolean)? browser->editor task checkbox flip
---@field augroup integer
---@field config table current plugin configuration
---@field debounce integer current edit debounce
---@field payload_generation integer invalidates the serialized payload cache
---@field revision fun(): string? payload revision for SSE boot handoff

M.previews = {} ---@type table<integer, mdpv.Preview> bufnr -> preview

local function new_token()
  local ok, bytes = pcall(vim.uv.random, 16)
  if ok and type(bytes) == 'string' and #bytes == 16 then
    return (bytes:gsub('.', function(c)
      return ('%02x'):format(c:byte())
    end))
  end
  return nil, 'secure preview-token generation is unavailable'
end

local function buf_meta(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then
    return ('buffer %d'):format(bufnr), assert(vim.uv.cwd())
  end
  return vim.fn.fnamemodify(name, ':t'), vim.fs.dirname(name)
end

local function make_features(config)
  return {
    -- false | true | table of KaTeX options ({ macros = ... }), passed through
    math = config.math == false and false or (type(config.math) == 'table' and config.math or true),
    mermaid = config.mermaid ~= false,
    emoji = config.emoji ~= false,
    wikilinks = config.wikilinks ~= false,
    -- false | true (editor -> browser) | 'both' (adds browser -> editor)
    scrollSync = config.scroll_sync == nil and true or config.scroll_sync,
  }
end

--- Serialize the buffer into a JSON payload. The cache is shared by the page
--- boot response and the first SSE update, while changedtick and the preview
--- generation invalidate it after edits or reconfiguration. Main loop only.
local function make_payload(pv)
  local cached_tick, cached_title, cached_modifiable, cached_generation, cached_json
  return function()
    if not vim.api.nvim_buf_is_valid(pv.bufnr) then
      return nil
    end
    local tick = vim.api.nvim_buf_get_changedtick(pv.bufnr)
    local modifiable = vim.bo[pv.bufnr].modifiable
    if
      cached_json
      and cached_tick == tick
      and cached_title == pv.title
      and cached_modifiable == modifiable
      and cached_generation == pv.payload_generation
    then
      return cached_json
    end
    local lines = vim.api.nvim_buf_get_lines(pv.bufnr, 0, -1, false)
    local json = vim.json.encode({
      token = pv.token,
      title = pv.title,
      md = table.concat(lines, '\n'),
      modifiable = modifiable,
      revision = ('%d:%d'):format(tick, pv.payload_generation),
      features = make_features(pv.config),
    })
    cached_tick, cached_title, cached_modifiable = tick, pv.title, modifiable
    cached_generation, cached_json = pv.payload_generation, json
    return json
  end
end

local function push_now(pv)
  if M.previews[pv.bufnr] ~= pv then
    return
  end
  if next(pv.clients) == nil then
    return -- nobody listening: skip the encode; a client connecting later gets a fresh push
  end
  local json = pv.payload()
  if json then
    server.broadcast(pv.token, 'update', json)
  end
end

--- Debounced change notification: (re)arm the timer; only the last change in
--- a burst reaches the browser.
local function on_change(pv)
  pv.timer:stop()
  pv.timer:start(
    pv.debounce,
    0,
    vim.schedule_wrap(function()
      push_now(pv)
    end)
  )
end

--- Content tracking via buffer attach: on_lines fires for every mutation
--- (typing, :s, undo, LSP edits, API calls), unlike TextChanged autocmds.
--- The callback runs under textlock, so it only re-arms the uv timer.
local function track_changes(pv)
  local bufnr = pv.bufnr
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      if M.previews[bufnr] ~= pv then
        return true -- preview closed: detach
      end
      on_change(pv)
    end,
    on_reload = function()
      if M.previews[bufnr] == pv then
        on_change(pv)
      end
    end,
  })
end

--- Scroll sync: stream the cursor line so the page can follow it. Cursor
--- position (not topline) is the anchor — it is what the user is editing.
local function setup_scroll_sync(pv)
  local bufnr = pv.bufnr
  local timer = vim.uv.new_timer()
  if not timer then
    return false
  end
  pv.scroll_timer = timer
  local last_line = 0
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = pv.augroup,
    buffer = bufnr,
    callback = function()
      if next(pv.clients) == nil then
        return -- no browser attached: nothing to scroll
      end
      local line = vim.api.nvim_win_get_cursor(0)[1]
      if line == last_line then
        return -- column-only movement (or a browser-initiated move): nothing to sync
      end
      last_line = line
      pv.scroll_timer:stop()
      pv.scroll_timer:start(
        80,
        0,
        vim.schedule_wrap(function()
          if M.previews[bufnr] == pv then
            server.broadcast(pv.token, 'scroll', vim.json.encode({ line = line }))
          end
        end)
      )
    end,
  })
  -- Browser -> editor: the page POSTs a line when its "move cursor on
  -- scroll" switch is on (scroll_sync = 'both' only sets that switch's
  -- default, so the handler is registered either way); move the cursor
  -- there. Setting last_line first suppresses the echo broadcast the
  -- resulting CursorMoved would otherwise trigger.
  pv.on_sync = function(line)
    if not (M.previews[bufnr] and vim.api.nvim_buf_is_valid(bufnr)) then
      return
    end
    local wins = vim.fn.win_findbuf(bufnr)
    if #wins == 0 then
      return
    end
    line = math.max(1, math.min(line, vim.api.nvim_buf_line_count(bufnr)))
    last_line = line
    vim.api.nvim_win_set_cursor(wins[1], { line, 0 })
  end
  return true
end

local function disable_scroll_sync(pv)
  vim.api.nvim_clear_autocmds({
    group = pv.augroup,
    buffer = pv.bufnr,
    event = { 'CursorMoved', 'CursorMovedI' },
  })
  if pv.scroll_timer then
    pv.scroll_timer:stop()
    pv.scroll_timer:close()
    pv.scroll_timer = nil
  end
  pv.on_sync = nil
end

--- Task-list checkboxes clicked in the page POST their new state; flip the
--- [ ]/[x] on that source line, provided it still is a task item. The buffer
--- change then streams back through the normal debounced update.
local function setup_checkbox_toggle(pv)
  local bufnr = pv.bufnr
  pv.on_toggle = function(line, checked)
    if not (M.previews[bufnr] and vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modifiable) then
      return
    end
    if line < 1 or line > vim.api.nvim_buf_line_count(bufnr) then
      return
    end
    local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
    -- List marker ([-*+] or "1."/"1)"), optionally inside blockquote/callout
    -- '>' prefixes, followed by the [ ]/[x] state box.
    local marker = text:match('^([>%s]*[-*+]%s+%[)[ xX]%]') or text:match('^([>%s]*%d+[.%)]%s+%[)[ xX]%]')
    if not marker then
      return
    end
    vim.api.nvim_buf_set_text(bufnr, line - 1, #marker, line - 1, #marker + 1, { checked and 'x' or ' ' })
  end
end

local function setup_auto_close(pv)
  local bufnr = pv.bufnr
  vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
    group = pv.augroup,
    buffer = bufnr,
    once = true,
    callback = function()
      -- Autocmd fires mid-unload; defer teardown out of the critical path.
      vim.schedule(function()
        if M.previews[bufnr] == pv then
          M.close(bufnr, pv.config)
        end
      end)
    end,
  })
end

---@param bufnr integer
---@param config table plugin config (see mdpv/init.lua defaults)
---@return string? url, string? err
function M.open(bufnr, config)
  local existing = M.previews[bufnr]
  if existing then
    return server.url(existing.token)
  end

  local token, token_err = new_token()
  if not token then
    return nil, token_err
  end
  local preview_timer = vim.uv.new_timer()
  if not preview_timer then
    return nil, 'could not create preview timer'
  end
  local server_was_running = server.is_running()
  local ok, err = server.start(config)
  if not ok then
    preview_timer:close()
    return nil, err
  end

  local title, dir = buf_meta(bufnr)
  local pv = {
    token = token,
    bufnr = bufnr,
    title = title,
    dir = dir,
    clients = {},
    timer = preview_timer,
    config = config,
    debounce = config.debounce,
    payload_generation = 0,
  }
  pv.revision = function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end
    return ('%d:%d'):format(vim.api.nvim_buf_get_changedtick(bufnr), pv.payload_generation)
  end
  pv.payload = make_payload(pv)
  pv.augroup = vim.api.nvim_create_augroup('mdpv.' .. bufnr, { clear = true })

  if config.scroll_sync ~= false and not setup_scroll_sync(pv) then
    pcall(vim.api.nvim_del_augroup_by_id, pv.augroup)
    pv.timer:close()
    if not server_was_running then
      server.stop()
    end
    return nil, 'could not create scroll-sync timer'
  end
  track_changes(pv)
  vim.api.nvim_create_autocmd('BufFilePost', {
    group = pv.augroup,
    buffer = bufnr,
    callback = function()
      local old_title = pv.title
      pv.title, pv.dir = buf_meta(bufnr)
      if pv.title ~= old_title then
        pv.payload_generation = pv.payload_generation + 1
      end
      on_change(pv)
    end,
  })
  vim.api.nvim_create_autocmd('OptionSet', {
    group = pv.augroup,
    pattern = 'modifiable',
    callback = function(args)
      if args.buf == bufnr then
        pv.payload_generation = pv.payload_generation + 1
        on_change(pv)
      end
    end,
  })
  setup_checkbox_toggle(pv)
  if config.auto_close then
    setup_auto_close(pv)
  end

  server.register(pv)
  M.previews[bufnr] = pv
  return server.url(pv.token)
end

--- Apply configuration changes to previews that are already open. The server
--- sends a config event after this method returns; browser pages reload from
--- the now-consistent server and preview state.
---@param config table
function M.reconfigure(config)
  local browser_changed = false
  for _, pv in pairs(M.previews) do
    local auto_close_changed = pv.config.auto_close ~= config.auto_close
    local features_changed = not vim.deep_equal(make_features(pv.config), make_features(config))
    if features_changed then
      browser_changed = true
      pv.payload_generation = pv.payload_generation + 1
    end
    pv.config = config
    pv.debounce = config.debounce

    if config.scroll_sync ~= false then
      if not pv.scroll_timer then
        setup_scroll_sync(pv)
      end
    elseif pv.scroll_timer then
      disable_scroll_sync(pv)
    end

    if auto_close_changed then
      vim.api.nvim_clear_autocmds({
        group = pv.augroup,
        buffer = pv.bufnr,
        event = { 'BufUnload', 'BufWipeout' },
      })
      if config.auto_close then
        setup_auto_close(pv)
      end
    end
  end
  return browser_changed
end

---@param bufnr integer
---@param config table
---@param silent boolean? skip the closing SSE event (the client is being
--- redirected elsewhere and does not need the "closed" page)
---@return boolean closed
function M.close(bufnr, config, silent)
  local pv = M.previews[bufnr]
  if not pv then
    return false
  end
  M.previews[bufnr] = nil
  pv.timer:stop()
  pv.timer:close()
  if pv.scroll_timer then
    pv.scroll_timer:stop()
    pv.scroll_timer:close()
  end
  pcall(vim.api.nvim_del_augroup_by_id, pv.augroup)
  server.close_preview(pv.token, not silent)
  if config.auto_stop and vim.tbl_isempty(M.previews) then
    server.stop()
  end
  return true
end

---@param config table
function M.close_all(config)
  local buffers = vim.tbl_keys(M.previews)
  for _, bufnr in ipairs(buffers) do
    M.close(bufnr, config)
  end
  server.stop()
end

---@return { bufnr: integer, title: string, url: string }[]
function M.list()
  local out = {}
  for bufnr, pv in pairs(M.previews) do
    out[#out + 1] = { bufnr = bufnr, title = pv.title, url = server.url(pv.token) }
  end
  table.sort(out, function(a, b)
    return a.bufnr < b.bufnr
  end)
  return out
end

return M
