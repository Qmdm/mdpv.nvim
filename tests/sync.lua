-- Bidirectional scroll-sync test: drives a real headless Chromium via the
-- DevTools protocol (tests/cdp.js) against a live preview, proving both
-- directions end to end:
--   editor -> browser: cursor move scrolls the page
--   browser -> editor: user scroll moves the cursor
--
--   nvim --clean --headless -l tests/sync.lua
--
-- Requires chromium (or MDPV_CHROME) and node 22+ (built-in WebSocket).

local script = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(script, ':p')))
vim.opt.runtimepath:prepend(root)

-- Page preferences persist to stdpath('state'); point that at a throwaway
-- directory so the user's real prefs can't steer the page under test.
vim.env.XDG_STATE_HOME = vim.fn.tempname()

local chrome = os.getenv('MDPV_CHROME') or 'chromium'
if vim.fn.executable(chrome) == 0 then
  print('SKIP: no chromium found (set MDPV_CHROME)')
  os.exit(0)
end
if vim.fn.executable('node') == 0 then
  print('SKIP: no node found')
  os.exit(0)
end

local failures, passes = {}, 0
local function check(name, cond, detail)
  if cond then
    passes = passes + 1
    print('  ok  ' .. name)
  else
    failures[#failures + 1] = name
    print('FAIL  ' .. name .. (detail and (' -- ' .. tostring(detail)) or ''))
  end
end

require('mdpv').setup({ open_browser = false, scroll_sync = 'both', debounce = 50 })
vim.cmd.edit(root .. '/tests/fixtures/sample.md')
local buf = vim.api.nvim_get_current_buf()
local url = assert(require('mdpv').open(0), 'preview failed to open')

--- Spawn tests/cdp.js and stream its stdout; returns handle with wait_for().
local function cdp(mode)
  local out, done, res = '', false, nil
  vim.system({ 'node', root .. '/tests/cdp.js', mode, url }, {
    text = true,
    stdout = function(_, data)
      if data then
        out = out .. data
      end
    end,
  }, function(r)
    res = r
    done = true
  end)
  return {
    -- Wait until the driver has printed `marker` (pumping the main loop).
    saw = function(marker, timeout)
      return vim.wait(timeout or 15000, function()
        return out:find(marker, 1, true) ~= nil
      end, 50)
    end,
    finish = function(timeout)
      vim.wait(timeout or 20000, function()
        return done
      end, 50)
      return res, out
    end,
  }
end

-- --- editor -> browser -------------------------------------------------------

vim.api.nvim_win_set_cursor(0, { 1, 0 })
local watch = cdp('watch-scroll')
check('page rendered under CDP', watch.saw('LOADED'))
-- Move the cursor near the end of the document; the page should follow.
vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf) - 2, 0 })
vim.cmd('doautocmd CursorMoved')
check('cursor move scrolled the page', watch.saw('SCROLLED'))
check('cursor block marked in the page', watch.saw('MARKED'))
-- Park the cursor on a heading line: the page's URL hash should follow.
local heading_line
for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if l == '### Footnotes' then
    heading_line = i
    break
  end
end
vim.api.nvim_win_set_cursor(0, { assert(heading_line, 'fixture lost its Footnotes heading'), 0 })
vim.cmd('doautocmd CursorMoved')
local res, out = watch.finish()
check('cursor on a heading updated the page hash', res and res.code == 0, out)

-- --- browser -> editor -------------------------------------------------------

vim.api.nvim_win_set_cursor(0, { 1, 0 })
local user = cdp('user-scroll')
check('second page rendered under CDP', user.saw('LOADED'))
res, out = user.finish()
check('user scroll reached page bottom', res and res.code == 0, out)
local moved = vim.wait(5000, function()
  return vim.api.nvim_win_get_cursor(0)[1] > 1
end, 50)
check('page scroll moved the cursor', moved, 'cursor still at line ' .. vim.api.nvim_win_get_cursor(0)[1])

require('mdpv').stop()

print(('\n%d passed, %d failed'):format(passes, #failures))
if #failures > 0 then
  print('failed: ' .. table.concat(failures, ', '))
  os.exit(1)
end
