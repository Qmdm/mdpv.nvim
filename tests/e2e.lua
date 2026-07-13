-- End-to-end test: drives the plugin inside this Neovim instance while curl
-- exercises the HTTP/SSE server it starts.
--
--   nvim --clean --headless -l tests/e2e.lua
--
-- Exits non-zero on failure. Requires curl.

local script = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(script, ':p')))
vim.opt.runtimepath:prepend(root)

-- Page preferences persist to stdpath('state'); point that at a throwaway
-- directory so tests neither read nor overwrite the user's real prefs.
vim.env.XDG_STATE_HOME = vim.fn.tempname()

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

-- Run a command while pumping the main loop. SystemObj:wait() only processes
-- fast events, which would starve the vim.schedule hops the server uses for
-- buffer access; vim.wait() keeps the whole loop alive like a real session.
local function run(cmd, timeout)
  local done, result
  vim.system(cmd, { text = true }, function(res)
    result = res
    done = true
  end)
  vim.wait(timeout or 8000, function()
    return done == true
  end, 10)
  return result or { code = -1, stdout = '', stderr = '' }
end

local function http(args)
  return run(vim.list_extend({ 'curl', '-s' }, args))
end

--- GET returning (status, full response incl. headers)
local function get(url, extra)
  local args = { '-i', '--max-time', '5' }
  vim.list_extend(args, extra or {})
  args[#args + 1] = url
  local res = http(args)
  return tonumber(res.stdout:match('HTTP/1%.1 (%d+)') or 0), res.stdout
end

-- --- Boot the plugin exactly as a user would -------------------------------

vim.cmd.source(root .. '/plugin/mdpv.lua')
check(':Preview command registered', vim.fn.exists(':Preview') == 2)

require('mdpv').setup({ open_browser = false, debounce = 50, scroll_sync = 'both' })

vim.cmd.edit(root .. '/tests/fixtures/sample.md')
local buf1 = vim.api.nvim_get_current_buf()
check('fixture filetype is markdown', vim.bo[buf1].filetype == 'markdown')

vim.cmd.Preview() -- default subcommand: open
local url = require('mdpv').url(buf1)
check('preview URL allocated', url ~= nil, 'url is nil')
if not url then
  print(('\n%d passed, %d FAILED'):format(passes, #failures))
  os.exit(1)
end
local base, token = url:match('^(http://.-)/p/(%x+)$')
check('URL shape http://host:port/p/<hex token>', base ~= nil and #token == 32, url)

-- --- Page + assets ----------------------------------------------------------

local status, body = get(url)
check('GET /p/<token> is 200', status == 200, status)
check('page has markdown-body container', body:find('markdown-body', 1, true) ~= nil)
check('page embeds boot token', body:find(token, 1, true) ~= nil)
check('page title is buffer name', body:find('<title>sample.md', 1, true) ~= nil)
check('page sends CSP', body:find('Content%-Security%-Policy') ~= nil)
check('all template placeholders expanded', body:find('{{', 1, true) == nil)
check('github stylesheet linked', body:find('github%-markdown[%w%-]*%.css') ~= nil)

for _, rel in ipairs({
  'app.js',
  'mdpv.css',
  'favicon.svg',
  'vendor/markdown-it.min.js',
  'vendor/github-markdown.css',
  'vendor/hljs-github-auto.css',
}) do
  local s = get(base .. '/assets/' .. rel)
  check('GET /assets/' .. rel .. ' is 200', s == 200, s)
end

status = get(base .. '/assets/../lua/mdpv/init.lua', { '--path-as-is' })
check('asset path traversal rejected', status == 403, status)
status = get(base .. '/assets/%2e%2e/lua/mdpv/init.lua', { '--path-as-is' })
check('encoded asset traversal rejected', status == 403, status)
status = get(base .. '/p/' .. ('0'):rep(32))
check('unknown token page is 404', status == 404, status)
status = get(base .. '/nope')
check('unknown route is 404', status == 404, status)
local s405 = http({ '-i', '--max-time', '5', '-X', 'POST', base .. '/' })
check('POST is 405', s405.stdout:find('405') ~= nil)

status, body = get(base .. '/')
check('index lists active previews', status == 200 and body:find('sample.md', 1, true) ~= nil)

-- --- File route (relative image) -------------------------------------------

local fres = http({
  '-o',
  '/dev/null',
  '-w',
  '%{http_code} %{content_type}',
  '--max-time',
  '5',
  base .. '/f/' .. token .. '/img.png',
})
check('GET /f/<token>/img.png is 200 image/png', fres.stdout == '200 image/png', fres.stdout)
fres = http({ '-o', '/dev/null', '-w', '%{http_code}', '--max-time', '5', base .. '/f/' .. token .. '/missing.png' })
check('missing file is 404', fres.stdout == '404', fres.stdout)

-- Path traversal through the file route must be rejected, just like /assets/.
status = get(base .. '/f/' .. token .. '/../../../../../../etc/passwd', { '--path-as-is' })
check('file route path traversal rejected', status == 403, status)
status = get(base .. '/f/' .. token .. '/%2e%2e/%2e%2e/%2e%2e/etc/passwd', { '--path-as-is' })
check('encoded file traversal rejected', status == 403, status)

-- Relative .md links render as a static page instead of serving raw bytes.
status, body = get(base .. '/f/' .. token .. '/second.md')
check('relative .md renders as page', status == 200 and body:find('markdown-body', 1, true) ~= nil, status)
check('static page marked static', body:find('"static":true', 1, true) ~= nil)
check('static page base points at file dir', body:find('"base":"/f/' .. token .. '"', 1, true) ~= nil)
status, body = get(base .. '/f/' .. token .. '/second.md?raw')
check('?raw serves markdown source', status == 200 and body:find('Content%-Type: text/plain') ~= nil, status)
status, body = get(base .. '/f/' .. token .. '/second.md?raw=1')
check('?raw=1 serves markdown source', status == 200 and body:find('Content%-Type: text/plain') ~= nil, status)
status, body = get(base .. '/f/' .. token .. '/second.md?rawr')
check('?rawr is not ?raw (renders page)', status == 200 and body:find('Content%-Type: text/html') ~= nil, status)

-- --- Byte ranges + revalidation (media seeking, cheap reloads) ---------------

local img = base .. '/f/' .. token .. '/img.png'
status, body = get(img)
check('file responses advertise Accept-Ranges', body:find('Accept%-Ranges: bytes') ~= nil)
local lastmod = body:match('Last%-Modified: ([^\r\n]+)')
check('file responses carry Last-Modified', lastmod ~= nil)
local size = tonumber(body:match('Content%-Length: (%d+)') or 0)

status, body = get(img, { '-H', 'Range: bytes=0-3' })
check('range request answers 206', status == 206, status)
check('206 carries Content-Range', body:find('Content%-Range: bytes 0%-3/' .. size, 1, false) ~= nil)
check('206 length is the slice', body:find('Content%-Length: 4') ~= nil)
check('206 body starts at byte 0', body:find('\137PNG', 1, true) ~= nil) -- PNG magic = bytes 0-3

status, body = get(img, { '-H', 'Range: bytes=' .. (size - 2) .. '-' })
check('open-ended range answers 206', status == 206 and body:find('Content%-Length: 2') ~= nil, status)
status, body = get(img, { '-H', 'Range: bytes=-2' })
check('suffix range answers 206', status == 206 and body:find('Content%-Length: 2') ~= nil, status)
status, body = get(img, { '-H', 'Range: bytes=999999999-' })
check('range past EOF answers 416', status == 416 and body:find('Content%-Range: bytes %*/' .. size) ~= nil, status)
status, body = get(img, { '-H', 'Range: bytes=0-1,4-5' })
check('multi-range degrades to full 200', status == 200 and body:find('Content%-Length: ' .. size) ~= nil, status)

status, body = get(img, { '-H', 'If-Modified-Since: ' .. (lastmod or '') })
check('unchanged file revalidates as 304', status == 304, status)
check('304 carries no body', body:match('\r?\n\r?\n(.*)$') == '') -- text=true maps \r\n to \n

local hres = http({ '-i', '-I', '--max-time', '5', img })
check(
  'HEAD answers headers only',
  hres.stdout:find('HTTP/1%.1 200') ~= nil and hres.stdout:find('Content%-Length: ' .. size) ~= nil,
  hres.stdout:match('^[^\r\n]*')
)

-- --- SSE: initial content + live edit ---------------------------------------

local sse_done = false
local sse_out = nil
vim.system({ 'curl', '-sN', '--max-time', '2', base .. '/events/' .. token }, { text = true }, function(res)
  sse_out = res.stdout
  sse_done = true
end)
vim.wait(400) -- let it connect and receive the initial push
vim.api.nvim_buf_set_lines(buf1, -1, -1, false, { '', '# LIVE_EDIT_MARKER' })
vim.wait(300)
-- Cursor movement should stream a scroll event (scroll_sync default).
vim.api.nvim_win_set_cursor(0, { 5, 0 })
vim.cmd('doautocmd CursorMoved')
vim.wait(4000, function()
  return sse_done
end)
check('SSE stream received data', sse_out ~= nil and #sse_out > 0)
if sse_out then
  check('SSE initial update event', sse_out:find('event: update', 1, true) ~= nil)
  check('SSE initial content matches buffer', sse_out:find('Sample Document', 1, true) ~= nil)
  check('SSE pushed live edit', sse_out:find('LIVE_EDIT_MARKER', 1, true) ~= nil)
  check('SSE payload carries feature flags', sse_out:find('"features":', 1, true) ~= nil)
  check(
    'SSE pushed cursor scroll event',
    sse_out:find('event: scroll', 1, true) ~= nil and sse_out:find('"line":5', 1, true) ~= nil
  )
end

-- --- Bidirectional sync: page scroll POSTs a line, the cursor follows --------

local pres = http({
  '-o',
  '/dev/null',
  '-w',
  '%{http_code}',
  '--max-time',
  '5',
  '-X',
  'POST',
  '-d',
  '{"line":3}',
  base .. '/sync/' .. token,
})
check('POST /sync/<token> is 204', pres.stdout == '204', pres.stdout)
local moved = vim.wait(2000, function()
  return vim.api.nvim_win_get_cursor(0)[1] == 3
end, 10)
check('page scroll moved the cursor', moved, 'cursor at line ' .. vim.api.nvim_win_get_cursor(0)[1])
pres = http({
  '-o',
  '/dev/null',
  '-w',
  '%{http_code}',
  '--max-time',
  '5',
  '-X',
  'POST',
  '-d',
  '{"line":9999}',
  base .. '/sync/' .. token,
})
check('out-of-range line clamps, still 204', pres.stdout == '204', pres.stdout)
check(
  'clamped to last line',
  vim.wait(2000, function()
    return vim.api.nvim_win_get_cursor(0)[1] == vim.api.nvim_buf_line_count(buf1)
  end, 10)
)
pres = http({
  '-o',
  '/dev/null',
  '-w',
  '%{http_code}',
  '--max-time',
  '5',
  '-X',
  'POST',
  '-d',
  '{"line":3}',
  base .. '/sync/' .. ('0'):rep(32),
})
check('POST /sync unknown token is 404', pres.stdout == '404', pres.stdout)
pres = http({
  '-o',
  '/dev/null',
  '-w',
  '%{http_code}',
  '--max-time',
  '5',
  '-X',
  'POST',
  '-d',
  'not json',
  base .. '/sync/' .. token,
})
check('malformed sync body ignored (204)', pres.stdout == '204', pres.stdout)
pres = http({
  '-o',
  '/dev/null',
  '-w',
  '%{http_code}',
  '--max-time',
  '5',
  '-X',
  'POST',
  '-H',
  'CONTENT-LENGTH: 10',
  '-d',
  '{"line":4}',
  base .. '/sync/' .. token,
})
check('all-caps Content-Length accepted', pres.stdout == '204', pres.stdout)
check(
  'all-caps sync applied',
  vim.wait(2000, function()
    return vim.api.nvim_win_get_cursor(0)[1] == 4
  end, 10)
)

-- --- Task checkbox toggle: the page POSTs it, the buffer line flips ----------

local function post_toggle(line, checked)
  return http({
    '-o',
    '/dev/null',
    '-w',
    '%{http_code}',
    '--max-time',
    '5',
    '-X',
    'POST',
    '-d',
    ('{"toggle":{"line":%d,"checked":%s}}'):format(line, checked and 'true' or 'false'),
    base .. '/sync/' .. token,
  })
end
local task_line
for i, l in ipairs(vim.api.nvim_buf_get_lines(buf1, 0, -1, false)) do
  if l:find('%[ %]') then
    task_line = i
    break
  end
end
check('fixture has an unchecked task', task_line ~= nil)
pres = post_toggle(task_line, true)
check('POST toggle is 204', pres.stdout == '204', pres.stdout)
check(
  'checkbox click checked the buffer line',
  vim.wait(2000, function()
    return (vim.api.nvim_buf_get_lines(buf1, task_line - 1, task_line, false)[1] or ''):find('%[x%]') ~= nil
  end, 10)
)
pres = post_toggle(task_line, false)
check(
  'toggle back unchecks it',
  vim.wait(2000, function()
    return (vim.api.nvim_buf_get_lines(buf1, task_line - 1, task_line, false)[1] or ''):find('%[ %]') ~= nil
  end, 10)
)
local before_toggle = vim.api.nvim_buf_get_lines(buf1, 0, 1, false)[1]
post_toggle(1, true)
vim.wait(300)
check('non-task line is left alone', vim.api.nvim_buf_get_lines(buf1, 0, 1, false)[1] == before_toggle)

-- --- Page preferences: POSTed by the page, persisted, shipped in the shell ---

local function post_prefs(tok, json)
  return http({
    '-o',
    '/dev/null',
    '-w',
    '%{http_code}',
    '--max-time',
    '5',
    '-X',
    'POST',
    '-d',
    json,
    base .. '/prefs/' .. tok,
  })
end
pres = post_prefs(token, '{"mdpv-theme":"dark","mdpv-wide":"1"}')
check('POST /prefs/<token> is 204', pres.stdout == '204', pres.stdout)
vim.wait(300)
status, body = get(url)
check(
  'page ships the posted prefs',
  body:find('"mdpv-theme":"dark"', 1, true) ~= nil and body:find('"mdpv-wide":"1"', 1, true) ~= nil
)
local prefs_file = vim.fn.stdpath('state') .. '/mdpv-prefs.json'
check('prefs written to the state file', vim.fn.filereadable(prefs_file) == 1, prefs_file)
-- Junk never reaches the file or the page: unknown keys, unknown values, and
-- non-string values are dropped; the valid key in the same POST still lands.
pres = post_prefs(token, '{"mdpv-theme":"neon","evil":"x","mdpv-outline":true,"mdpv-fab-corner":"tl"}')
check('junk-pref POST still 204', pres.stdout == '204', pres.stdout)
vim.wait(300)
status, body = get(url)
check('valid pref in a mixed POST lands', body:find('"mdpv-fab-corner":"tl"', 1, true) ~= nil)
check(
  'unknown keys and values dropped',
  body:find('"mdpv-theme":"dark"', 1, true) ~= nil
    and body:find('neon', 1, true) == nil
    and body:find('evil', 1, true) == nil
)
pres = post_prefs(('0'):rep(32), '{"mdpv-theme":"light"}')
check('POST /prefs unknown token is 404', pres.stdout == '404', pres.stdout)
pres = post_prefs(token, 'not json')
check('malformed prefs body ignored (204)', pres.stdout == '204', pres.stdout)

-- --- Live asset reload: a served file changing pushes an `assets` event ------

local watch_dir = vim.fn.tempname()
vim.fn.mkdir(watch_dir, 'p')
local function write_file(path, data)
  local f = assert(io.open(path, 'wb'))
  f:write(data)
  f:close()
end
write_file(watch_dir .. '/pic.png', 'PNG0')
write_file(watch_dir .. '/doc.md', '# Doc\n\n![pic](pic.png)\n')
vim.cmd.edit(watch_dir .. '/doc.md')
local wbuf = vim.api.nvim_get_current_buf()
local wurl = require('mdpv').open(wbuf)
local wtoken = wurl and wurl:match('/p/(%x+)$')
check('watched preview opened', wtoken ~= nil)
-- Serving the image is what registers the watch.
local ires = http({ '-o', '/dev/null', '-w', '%{http_code}', '--max-time', '5', base .. '/f/' .. wtoken .. '/pic.png' })
check('watched image served', ires.stdout == '200', ires.stdout)
local asset_out = ''
vim.system({ 'curl', '-sN', '--max-time', '4', base .. '/events/' .. wtoken }, {
  text = true,
  stdout = function(_, d)
    if d then
      asset_out = asset_out .. d
    end
  end,
}, function() end)
vim.wait(500)
write_file(watch_dir .. '/pic.png', 'PNG1-CHANGED')
local saw_asset = vim.wait(3000, function()
  return asset_out:find('event: assets', 1, true) ~= nil and asset_out:find('pic.png', 1, true) ~= nil
end, 50)
check('image change pushed an assets event', saw_asset, asset_out)
vim.cmd('bwipeout! ' .. wbuf)
-- Pump the loop until the deferred auto-close lands (url() would be nil for
-- the wiped buffer immediately, so count previews instead).
check(
  'watched preview auto-closed',
  vim.wait(2000, function()
    return #require('mdpv').list() == 1
  end, 10)
)

-- --- Multiple simultaneous previews ------------------------------------------

vim.cmd.edit(root .. '/tests/fixtures/second.md')
local buf2 = vim.api.nvim_get_current_buf()
local url2 = require('mdpv').open(buf2)
check('second preview opened', url2 ~= nil and url2 ~= url)
check('both previews listed', #require('mdpv').list() == 2)
if url2 then
  local s2 = get(url2)
  check('second preview page is 200', s2 == 200, s2)
  local s1 = get(url)
  check('first preview still live', s1 == 200, s1)
end

-- Same buffer opened again reuses the preview.
local url1b = require('mdpv').open(buf1)
check('re-open reuses URL', url1b == url, ('%s vs %s'):format(url1b, url))
check('re-open does not duplicate', #require('mdpv').list() == 2)

-- --- Filetype guard -----------------------------------------------------------

vim.cmd.edit(root .. '/tests/fixtures/note.txt')
local buf3 = vim.api.nvim_get_current_buf()
check('non-markdown buffer refused', require('mdpv').open(buf3) == nil)
check('non-markdown buffer forced with bang', require('mdpv').open(buf3, { force = true }) ~= nil)
require('mdpv').close(buf3)

-- --- Close / auto-close / stop -------------------------------------------------

require('mdpv').close(buf2)
check('closed preview removed from list', #require('mdpv').list() == 1)
local s2b = get(url2)
check('closed preview page is 404', s2b == 404, s2b)

-- auto_close via buffer wipeout
vim.cmd('bwipeout! ' .. buf1)
vim.wait(200, function()
  return #require('mdpv').list() == 0
end)
check('buffer wipeout auto-closes preview', #require('mdpv').list() == 0)

-- auto_stop: last preview gone -> server down
local down = vim.wait(1000, function()
  local res = http({ '-o', '/dev/null', '-w', '%{http_code}', '--max-time', '1', base .. '/' })
  return res.stdout ~= '200'
end)
check('server auto-stops after last preview', down)

-- Server restarts cleanly for a fresh preview (reconfigured with KaTeX
-- macros, which must ship to the page in the feature flags).
require('mdpv').setup({ open_browser = false, math = { macros = { ['\\RR'] = '\\mathbb{R}' } } })
vim.cmd.edit(root .. '/tests/fixtures/second.md')
local url3 = require('mdpv').open(0)
check('server restarts on demand', url3 ~= nil)
local s3, body3 = get(url3)
check('restarted preview page is 200', s3 == 200, s3)
check('math macros ship in the boot payload', body3:find('mathbb', 1, true) ~= nil)
-- The page prefs POSTed earlier came back from the state file: this is the
-- cross-session path (a real restart also means a new port = a fresh origin).
check('prefs survive a server restart', body3:find('"mdpv-theme":"dark"', 1, true) ~= nil)

-- Reverse sync stays wired under the default scroll_sync = true: the page's
-- "move cursor on scroll" switch decides whether lines are POSTed, so the
-- editor accepts them regardless of the configured mode.
local base3, token3 = url3:match('^(http://.-)/p/(%x+)$')
local sres3 = http({
  '-o',
  '/dev/null',
  '-w',
  '%{http_code}',
  '--max-time',
  '5',
  '-X',
  'POST',
  '-d',
  '{"line":2}',
  base3 .. '/sync/' .. token3,
})
check('sync POST accepted under scroll_sync = true', sres3.stdout == '204', sres3.stdout)
local moved3 = vim.wait(2000, function()
  return vim.api.nvim_win_get_cursor(0)[1] == 2
end, 10)
check('cursor followed without scroll_sync = "both"', moved3, 'cursor at line ' .. vim.api.nvim_win_get_cursor(0)[1])
require('mdpv').stop()
check('stop clears previews', #require('mdpv').list() == 0)

-- ------------------------------------------------------------------------------

print(('\n%d passed, %d failed'):format(passes, #failures))
if #failures > 0 then
  print('failed: ' .. table.concat(failures, ', '))
  os.exit(1)
end
