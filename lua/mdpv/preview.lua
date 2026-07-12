---@brief Per-buffer preview lifecycle: token allocation, change tracking
--- (debounced), and teardown. One preview per buffer; any number of buffers
--- may be previewed concurrently on the shared server.

local server = require('mdpv.server')

local M = {}

---@class mdpv.Preview
---@field token string unguessable route id
---@field bufnr integer
---@field title string tail of the buffer name (or a placeholder)
---@field dir string directory relative file requests resolve against
---@field clients table<uv.uv_tcp_t, true> attached SSE sockets
---@field payload fun(): string? buffer content as JSON (SSE payload and page boot data)
---@field timer uv.uv_timer_t debounce timer
---@field scroll_timer uv.uv_timer_t? cursor-sync debounce timer
---@field on_sync fun(line: integer)? browser->editor cursor move (page's "move cursor on scroll" switch)
---@field on_toggle fun(line: integer, checked: boolean)? browser->editor task checkbox flip
---@field augroup integer

M.previews = {} ---@type table<integer, mdpv.Preview> bufnr -> preview

local function new_token()
  local ok, bytes = pcall(vim.uv.random, 16)
  if ok and type(bytes) == 'string' then
    return (bytes:gsub('.', function(c)
      return ('%02x'):format(c:byte())
    end))
  end
  -- Fallback: not cryptographic, but the server only listens on localhost.
  -- Pick exactly one hex digit per iteration so the token is always 32 chars.
  math.randomseed(vim.uv.hrtime() % 2 ^ 31)
  local hex = '0123456789abcdef'
  local t = {}
  for i = 1, 32 do
    local n = math.random(16)
    t[i] = hex:sub(n, n)
  end
  return table.concat(t)
end

local function buf_meta(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then
    return ('buffer %d'):format(bufnr), assert(vim.uv.cwd())
  end
  return vim.fn.fnamemodify(name, ':t'), vim.fs.dirname(name)
end

--- Serialize the buffer into a JSON payload. Used both as the SSE `update`
--- event body and as the boot data embedded in the page shell (instant first
--- paint, no SSE round-trip). Main loop only.
local function make_payload(pv, config)
  local features = {
    -- false | true | table of KaTeX options ({ macros = ... }), passed through
    math = config.math == false and false or (type(config.math) == 'table' and config.math or true),
    mermaid = config.mermaid ~= false,
    emoji = config.emoji ~= false,
    wikilinks = config.wikilinks ~= false,
    -- false | true (editor -> browser) | 'both' (adds browser -> editor)
    scrollSync = config.scroll_sync == nil and true or config.scroll_sync,
  }
  return function()
    if not vim.api.nvim_buf_is_valid(pv.bufnr) then
      return nil
    end
    local lines = vim.api.nvim_buf_get_lines(pv.bufnr, 0, -1, false)
    return vim.json.encode({
      token = pv.token,
      title = pv.title,
      md = table.concat(lines, '\n'),
      features = features,
    })
  end
end

local function push_now(pv)
  if not M.previews[pv.bufnr] then
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
local function on_change(pv, debounce_ms)
  pv.timer:stop()
  pv.timer:start(
    debounce_ms,
    0,
    vim.schedule_wrap(function()
      push_now(pv)
    end)
  )
end

--- Content tracking via buffer attach: on_lines fires for every mutation
--- (typing, :s, undo, LSP edits, API calls), unlike TextChanged autocmds.
--- The callback runs under textlock, so it only re-arms the uv timer.
local function track_changes(pv, config)
  local bufnr = pv.bufnr
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      if not M.previews[bufnr] then
        return true -- preview closed: detach
      end
      on_change(pv, config.debounce)
    end,
    on_reload = function()
      if M.previews[bufnr] then
        on_change(pv, config.debounce)
      end
    end,
  })
end

--- Scroll sync: stream the cursor line so the page can follow it. Cursor
--- position (not topline) is the anchor — it is what the user is editing.
local function setup_scroll_sync(pv, config)
  local bufnr = pv.bufnr
  pv.scroll_timer = assert(vim.uv.new_timer())
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
          if M.previews[bufnr] then
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

local function setup_auto_close(pv, config)
  local bufnr = pv.bufnr
  vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
    group = pv.augroup,
    buffer = bufnr,
    once = true,
    callback = function()
      -- Autocmd fires mid-unload; defer teardown out of the critical path.
      vim.schedule(function()
        M.close(bufnr, config)
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

  local ok, err = server.start(config)
  if not ok then
    return nil, err
  end

  local title, dir = buf_meta(bufnr)
  local pv = {
    token = new_token(),
    bufnr = bufnr,
    title = title,
    dir = dir,
    clients = {},
    timer = assert(vim.uv.new_timer()),
  }
  pv.payload = make_payload(pv, config)
  pv.augroup = vim.api.nvim_create_augroup('mdpv.' .. bufnr, { clear = true })

  track_changes(pv, config)
  vim.api.nvim_create_autocmd('BufFilePost', {
    group = pv.augroup,
    buffer = bufnr,
    callback = function()
      pv.title, pv.dir = buf_meta(bufnr)
      on_change(pv, config.debounce)
    end,
  })
  if config.scroll_sync ~= false then
    setup_scroll_sync(pv, config)
  end
  setup_checkbox_toggle(pv)
  if config.auto_close then
    setup_auto_close(pv, config)
  end

  server.register(pv)
  M.previews[bufnr] = pv
  return server.url(pv.token)
end

---@param bufnr integer
---@param config table
---@return boolean closed
function M.close(bufnr, config)
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
  server.close_preview(pv.token, true)
  if config.auto_stop and vim.tbl_isempty(M.previews) then
    server.stop()
  end
  return true
end

---@param config table
function M.close_all(config)
  for bufnr in pairs(M.previews) do
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
