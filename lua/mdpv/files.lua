---@brief Static file serving: async whole-file reads for content rendered
--- in-process, and chunk-streamed responses (byte ranges, Last-Modified/304
--- revalidation) for everything served as-is.

local uv = vim.uv
local http = require('mdpv.http')

local M = {}

local MAX_FILE_BYTES = 64 * 1024 * 1024 -- refuse to buffer files larger than this in memory
local CHUNK_BYTES = 256 * 1024 -- streamed file responses go out in pieces this size

local function http_date(sec)
  return os.date('!%a, %d %b %Y %H:%M:%S GMT', sec)
end

--- Read a whole file into memory (for content the server renders itself,
--- e.g. the page template and static markdown). cb(data) on success,
--- cb(nil, 'open'|'stat'|'toobig'|'read') on failure.
function M.read(path, cb)
  uv.fs_open(path, 'r', 292, function(err, fd) -- 292 = 0444
    if err or not fd then
      return cb(nil, 'open')
    end
    uv.fs_fstat(fd, function(serr, stat)
      if serr or not stat or stat.type ~= 'file' then
        uv.fs_close(fd)
        return cb(nil, 'stat')
      end
      if stat.size > MAX_FILE_BYTES then
        uv.fs_close(fd)
        return cb(nil, 'toobig')
      end
      uv.fs_read(fd, stat.size, 0, function(rerr, data)
        uv.fs_close(fd)
        if rerr or not data then
          return cb(nil, 'read')
        end
        cb(data)
      end)
    end)
  end)
end

--- Parse a single-range `bytes=a-b` header value against a file of `size`
--- bytes. Returns 0-based inclusive first,last; nil to serve the whole file
--- (absent, malformed, or multi-range headers degrade to a full 200); or
--- 'unsatisfiable' (start beyond EOF) which must answer 416.
local function parse_range(spec, size)
  if not spec or size == 0 then
    return nil
  end
  local a, b = spec:match('^%s*bytes%s*=%s*(%d*)%-(%d*)%s*$')
  if not a or (a == '' and b == '') then
    return nil
  end
  if a == '' then
    local n = tonumber(b) or 0 -- suffix form: the last n bytes
    if n == 0 then
      return 'unsatisfiable'
    end
    return math.max(0, size - n), size - 1
  end
  local first = tonumber(a) or 0
  if first >= size then
    return 'unsatisfiable'
  end
  local bn = tonumber(b)
  local last = bn and math.min(bn, size - 1) or size - 1
  if last < first then
    return nil
  end
  return first, last
end

--- Pump fd's [first, last] byte range to sock after `head` (response head
--- including the blank line). Closes fd and sock when done or on any error.
local function stream_body(sock, fd, first, last, head)
  local finished = false
  local function finish(broken)
    if finished then
      return
    end
    finished = true
    uv.fs_close(fd, function() end)
    if broken then
      http.close_sock(sock)
    end
  end
  local offset = first
  local function pump()
    if sock:is_closing() then
      return finish(true)
    end
    local want = math.min(CHUNK_BYTES, last - offset + 1)
    if want <= 0 then
      finish(false)
      http.close_sock(sock) -- Connection: close, and the last write has flushed
      return
    end
    uv.fs_read(fd, want, offset, function(rerr, data)
      if rerr or not data or #data == 0 then
        return finish(true) -- truncated mid-stream (file shrank?): drop the socket
      end
      offset = offset + #data
      local ok = pcall(sock.write, sock, data, function(werr)
        if werr then
          return finish(true)
        end
        pump() -- next chunk only after this one flushed: natural backpressure
      end)
      if not ok then
        finish(true)
      end
    end)
  end
  local ok = pcall(sock.write, sock, head, function(werr)
    if werr then
      return finish(true)
    end
    pump()
  end)
  if not ok then
    finish(true)
  end
end

--- Serve a file from disk, streamed in chunks: no whole-file buffering, byte
--- ranges so media can seek, and Last-Modified revalidation so a reload of an
--- unchanged file costs a 304 instead of a re-download.
---@param req { head_only: boolean?, range: string?, if_modified_since: string? }?
function M.serve(sock, path, cache_control, req)
  req = req or {}
  local ext = path:match('%.([%w]+)$')
  local mime = http.MIME[ext and ext:lower() or ''] or 'application/octet-stream'
  uv.fs_open(path, 'r', 292, function(err, fd) -- 292 = 0444
    if err or not fd then
      return http.respond(sock, 404)
    end
    uv.fs_fstat(fd, function(serr, stat)
      if serr or not stat or stat.type ~= 'file' then
        uv.fs_close(fd, function() end)
        return http.respond(sock, 404)
      end
      local modified = http_date(stat.mtime.sec)
      if req.if_modified_since == modified then
        uv.fs_close(fd, function() end)
        return http.respond(sock, 304, {
          ['Content-Type'] = mime,
          ['Cache-Control'] = cache_control or 'no-cache',
          ['Last-Modified'] = modified,
        })
      end
      local first, last = parse_range(req.range, stat.size)
      if first == 'unsatisfiable' then
        uv.fs_close(fd, function() end)
        return http.respond(sock, 416, { ['Content-Range'] = 'bytes */' .. stat.size })
      end
      local headers = {
        ['Content-Type'] = mime,
        ['Cache-Control'] = cache_control or 'no-cache',
        ['Last-Modified'] = modified,
        ['Accept-Ranges'] = 'bytes',
        ['Connection'] = 'close',
      }
      local status = 200
      if first then
        status = 206
        headers['Content-Range'] = ('bytes %d-%d/%d'):format(first, last, stat.size)
      else
        first, last = 0, stat.size - 1
      end
      headers['Content-Length'] = tostring(math.max(0, last - first + 1))
      local head = http.head(status, headers)
      if req.head_only or last < first then
        uv.fs_close(fd, function() end)
        return http.write_and_close(sock, head)
      end
      stream_body(sock, fd, first, last, head)
    end)
  end)
end

return M
