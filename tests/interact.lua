-- In-page interaction test: drives headless Chromium via the DevTools
-- protocol (tests/cdp.js) against a live preview and proves the browser ->
-- editor task-checkbox round trip with a real, trusted click:
--   click checkbox -> POST /sync -> buffer line flips -> SSE re-render
--   confirms the checked state back in the page.
--
--   nvim --clean --headless -l tests/interact.lua
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

require('mdpv').setup({ open_browser = false, debounce = 50 })
vim.cmd.edit(root .. '/tests/fixtures/sample.md')
local buf = vim.api.nvim_get_current_buf()
local url = assert(require('mdpv').open(0), 'preview failed to open')

-- The first unchecked task in the fixture — the checkbox cdp.js will click.
local task_line
for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if l:find('%[ %]') then
    task_line = i
    break
  end
end
check('fixture has an unchecked task', task_line ~= nil)

local out, done, res = '', false, nil
vim.system({ 'node', root .. '/tests/cdp.js', 'toggle-task', url }, {
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

check(
  'checkbox clicked in the page',
  vim.wait(20000, function()
    return out:find('CLICKED', 1, true) ~= nil
  end, 50),
  out
)
local clicked_line = tonumber(out:match('CLICKED (%d+)'))
check('clicked checkbox maps to the fixture task line', clicked_line == task_line, clicked_line)
check(
  'click flipped the buffer line to [x]',
  vim.wait(5000, function()
    return (vim.api.nvim_buf_get_lines(buf, task_line - 1, task_line, false)[1] or ''):find('%[x%]') ~= nil
  end, 50)
)
vim.wait(20000, function()
  return done
end, 50)
check('page saw the checked state come back (SYNCED)', res and res.code == 0, out)

require('mdpv').stop()

print(('\n%d passed, %d failed'):format(passes, #failures))
if #failures > 0 then
  print('failed: ' .. table.concat(failures, ', '))
  os.exit(1)
end
