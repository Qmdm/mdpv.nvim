---@brief Served-file watchers behind the live image reload. Files served
--- through /f/ get a directory-level fs watch (deduped per dir, capped,
--- dropped with the preview) — a file-level watch would go stale when tools
--- rename-replace on save. Changes debounce into one `assets` SSE event
--- listing the relative paths; the page cache-busts the matching media.
---
--- State lives here, keyed by preview token; the server calls add() as it
--- serves files and drop() when a preview closes.

local uv = vim.uv

local M = {}

local MAX_WATCH_DIRS = 32
local MAX_WATCH_FILES = 512
local WATCH_EXT = {
  png = true,
  jpg = true,
  jpeg = true,
  gif = true,
  webp = true,
  avif = true,
  bmp = true,
  ico = true,
  mp4 = true,
  webm = true,
  mov = true,
  mp3 = true,
  ogg = true,
  wav = true,
}

---@type table<string, { dirs: table<string, { handle: uv.uv_fs_event_t, files: table<string, string> }>, file_count: integer, pending: table<string, true>, timer: uv.uv_timer_t? }>
local watched = {}

function M.is_watchable(rel)
  local ext = rel:match('%.([%w]+)$')
  return ext and WATCH_EXT[ext:lower()] or false
end

--- Queue `rel` for the token's next `assets` event (debounced: tools
--- rewriting a file emit bursts of events).
local function notify(token, rel)
  local w = watched[token]
  if not w then
    return
  end
  w.pending[rel] = true
  if not w.timer then
    w.timer = uv.new_timer()
    if not w.timer then
      return
    end
  end
  w.timer:stop()
  w.timer:start(
    150,
    0,
    vim.schedule_wrap(function()
      local paths = {}
      for r in pairs(w.pending) do
        paths[#paths + 1] = r
      end
      w.pending = {}
      if #paths > 0 and watched[token] then
        table.sort(paths)
        -- Lazy require: server requires this module at load time.
        require('mdpv.server').broadcast(token, 'assets', vim.json.encode({ paths = paths }))
      end
    end)
  )
end

--- Watch the directory holding `fpath` (served to the token's preview as the
--- relative path `rel`) and report changes to that file.
function M.add(token, fpath, rel)
  if not M.is_watchable(rel) then
    return
  end
  local dir, name = fpath:match('^(.*)/([^/]+)$')
  if not dir or dir == '' then
    return
  end
  local w = watched[token]
  if not w then
    w = { dirs = {}, file_count = 0, pending = {} }
    watched[token] = w
  end
  local d = w.dirs[dir]
  if (not d or not d.files[name]) and w.file_count >= MAX_WATCH_FILES then
    return
  end
  if not d then
    if vim.tbl_count(w.dirs) >= MAX_WATCH_DIRS then
      return
    end
    local handle = uv.new_fs_event()
    if not handle then
      return
    end
    d = { handle = handle, files = {} }
    local ok, r = pcall(handle.start, handle, dir, {}, function(werr, filename)
      if not werr and filename and d.files[filename] then
        notify(token, d.files[filename])
      end
    end)
    if not ok or (r ~= 0 and r ~= true) then
      pcall(handle.close, handle)
      return
    end
    w.dirs[dir] = d
  end
  if not d.files[name] then
    w.file_count = w.file_count + 1
  end
  d.files[name] = rel
end

--- Tear down everything watched for a preview.
function M.drop(token)
  local w = watched[token]
  if not w then
    return
  end
  watched[token] = nil
  if w.timer then
    w.timer:stop()
    w.timer:close()
  end
  for _, d in pairs(w.dirs) do
    pcall(d.handle.stop, d.handle)
    if not d.handle:is_closing() then
      d.handle:close()
    end
  end
end

return M
