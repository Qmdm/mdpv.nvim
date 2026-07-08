---@brief Public API and configuration for mdpv.nvim.

local M = {}

local defaults = {
  host = '127.0.0.1', -- interface to bind; keep loopback unless you know why
  port = 0, -- 0 = pick a free ephemeral port
  theme = 'auto', -- 'auto' | 'light' | 'dark'
  debounce = 150, -- ms of quiet time before pushing an edit to the browser
  filetypes = { 'markdown' }, -- buffers eligible without :Preview! force
  auto_close = true, -- close the preview when its buffer is unloaded
  auto_stop = true, -- stop the server when the last preview closes
  open_browser = true, -- false: only print the URL (headless/remote setups)
  math = true, -- render $…$ / $$…$$ / ```math with KaTeX
  mermaid = true, -- render ```mermaid blocks as diagrams
  emoji = true, -- expand :shortcodes: like GitHub
  -- false: off | true: browser follows the cursor line (toggleable in-page)
  -- | 'both': additionally, scrolling the page moves the cursor
  scroll_sync = true,
}

M.config = vim.deepcopy(defaults)

---@param opts table?
function M.setup(opts)
  opts = opts or {}
  vim.validate('opts', opts, 'table')
  M.config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts)
  vim.validate('config.theme', M.config.theme, function(t)
    return t == 'auto' or t == 'light' or t == 'dark'
  end, "'auto', 'light' or 'dark'")
  vim.validate('config.port', M.config.port, 'number')
  vim.validate('config.debounce', M.config.debounce, 'number')
  vim.validate('config.filetypes', M.config.filetypes, 'table')
  vim.validate('config.math', M.config.math, 'boolean')
  vim.validate('config.mermaid', M.config.mermaid, 'boolean')
  vim.validate('config.emoji', M.config.emoji, 'boolean')
  vim.validate('config.scroll_sync', M.config.scroll_sync, function(t)
    return t == true or t == false or t == 'both'
  end, "true, false or 'both'")
end

local function notify(msg, level)
  vim.notify('mdpv: ' .. msg, level or vim.log.levels.INFO)
end

local function resolve_buf(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return bufnr
end

local function open_in_browser(url)
  local _, err = vim.ui.open(url)
  if err then
    notify(('could not open a browser (%s) — open %s manually'):format(err, url), vim.log.levels.WARN)
  end
end

--- Open (or focus) a preview for a buffer and open a browser tab for it.
---@param bufnr integer? defaults to the current buffer
---@param opts { force: boolean? }? force skips the filetype check
---@return string? url
function M.open(bufnr, opts)
  opts = opts or {}
  bufnr = resolve_buf(bufnr)
  if not bufnr then
    notify('invalid buffer', vim.log.levels.ERROR)
    return nil
  end
  if not opts.force and not vim.tbl_contains(M.config.filetypes, vim.bo[bufnr].filetype) then
    notify(
      ("buffer filetype '%s' is not in config.filetypes — use :Preview! to force"):format(vim.bo[bufnr].filetype),
      vim.log.levels.WARN
    )
    return nil
  end

  local preview = require('mdpv.preview')
  local already = preview.previews[bufnr] ~= nil
  local url, err = preview.open(bufnr, M.config)
  if not url then
    notify(err or 'failed to start server', vim.log.levels.ERROR)
    return nil
  end
  if M.config.open_browser then
    open_in_browser(url)
  end
  notify((already and 'preview already live: %s' or 'preview: %s'):format(url))
  return url
end

---@param bufnr integer?
function M.close(bufnr)
  bufnr = resolve_buf(bufnr)
  if bufnr and require('mdpv.preview').close(bufnr, M.config) then
    notify('preview closed')
  else
    notify('no preview for this buffer', vim.log.levels.WARN)
  end
end

---@param bufnr integer?
---@return string? url
function M.toggle(bufnr)
  bufnr = resolve_buf(bufnr)
  if bufnr and require('mdpv.preview').previews[bufnr] then
    return M.close(bufnr)
  end
  return M.open(bufnr)
end

--- Stop everything: all previews and the server.
function M.stop()
  require('mdpv.preview').close_all(M.config)
  notify('server stopped')
end

--- Preview URL for a buffer, if one is live.
---@param bufnr integer?
---@return string?
function M.url(bufnr)
  bufnr = resolve_buf(bufnr)
  local pv = bufnr and require('mdpv.preview').previews[bufnr]
  return pv and require('mdpv.server').url(pv.token) or nil
end

---@return { bufnr: integer, title: string, url: string }[]
function M.list()
  return require('mdpv.preview').list()
end

------------------------------------------------------------------------------
-- :Preview command plumbing
------------------------------------------------------------------------------

local subcommands = { 'open', 'close', 'toggle', 'stop', 'list' }

function M._command(cmd)
  local sub = cmd.fargs[1] or 'open'
  if sub == 'open' then
    M.open(nil, { force = cmd.bang })
  elseif sub == 'close' then
    M.close()
  elseif sub == 'toggle' then
    M.toggle()
  elseif sub == 'stop' then
    M.stop()
  elseif sub == 'list' then
    local items = M.list()
    if #items == 0 then
      notify('no active previews')
      return
    end
    local lines = {}
    for _, it in ipairs(items) do
      lines[#lines + 1] = ('%3d  %-30s %s'):format(it.bufnr, it.title, it.url)
    end
    notify('active previews:\n' .. table.concat(lines, '\n'))
  else
    notify(('unknown subcommand %q (expected: %s)'):format(sub, table.concat(subcommands, ', ')), vim.log.levels.ERROR)
  end
end

function M._complete(arglead)
  return vim.tbl_filter(function(s)
    return vim.startswith(s, arglead)
  end, subcommands)
end

return M
