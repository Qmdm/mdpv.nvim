---@brief Wire-level HTTP helpers shared by the server and the file server:
--- status reasons, MIME types, response serialization, socket write/close,
--- SSE framing, and small request/text utilities. No routing, no state.

local M = {}

M.REASONS = {
  [200] = 'OK',
  [204] = 'No Content',
  [206] = 'Partial Content',
  [304] = 'Not Modified',
  [400] = 'Bad Request',
  [403] = 'Forbidden',
  [404] = 'Not Found',
  [405] = 'Method Not Allowed',
  [413] = 'Payload Too Large',
  [416] = 'Range Not Satisfiable',
  [431] = 'Request Header Fields Too Large',
  [500] = 'Internal Server Error',
}

M.MIME = {
  html = 'text/html; charset=utf-8',
  js = 'text/javascript; charset=utf-8',
  css = 'text/css; charset=utf-8',
  json = 'application/json',
  txt = 'text/plain; charset=utf-8',
  md = 'text/plain; charset=utf-8',
  markdown = 'text/plain; charset=utf-8',
  svg = 'image/svg+xml',
  png = 'image/png',
  jpg = 'image/jpeg',
  jpeg = 'image/jpeg',
  gif = 'image/gif',
  webp = 'image/webp',
  avif = 'image/avif',
  bmp = 'image/bmp',
  ico = 'image/x-icon',
  mp4 = 'video/mp4',
  webm = 'video/webm',
  mov = 'video/quicktime',
  mp3 = 'audio/mpeg',
  ogg = 'audio/ogg',
  wav = 'audio/wav',
  pdf = 'application/pdf',
  woff2 = 'font/woff2',
}

function M.close_sock(sock)
  if sock and not sock:is_closing() then
    sock:close()
  end
end

--- Write `data` then close the connection once flushed.
function M.write_and_close(sock, data)
  local ok = pcall(sock.write, sock, data, function()
    M.close_sock(sock)
  end)
  if not ok then
    M.close_sock(sock)
  end
end

--- Serialize a response head: status line, headers, and the blank line.
function M.head(status, headers)
  local lines = { ('HTTP/1.1 %d %s'):format(status, M.REASONS[status] or 'OK') }
  for k, v in pairs(headers) do
    lines[#lines + 1] = k .. ': ' .. v
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = ''
  return table.concat(lines, '\r\n')
end

--- Write a complete response and close the socket. For HEAD requests,
--- `head_only` suppresses the body while preserving the GET Content-Length.
--- `omit_length` is for responses whose GET body has no finite length (SSE).
function M.respond(sock, status, headers, body, head_only, omit_length)
  if status == 304 or status == 204 then
    body = '' -- 304/204 must not carry content or a Content-Length header
    headers = headers or {}
    headers['Content-Length'] = nil
  else
    body = body or (status ~= 200 and status ~= 204 and (M.REASONS[status] or '') or '')
  end
  headers = headers or {}
  if not headers['Content-Type'] then
    headers['Content-Type'] = 'text/plain; charset=utf-8'
  end
  if status ~= 304 and status ~= 204 and not omit_length then
    headers['Content-Length'] = tostring(#body)
  end
  headers['Connection'] = 'close'
  M.write_and_close(sock, M.head(status, headers) .. (head_only and '' or body))
end

function M.sse_frame(event, data)
  return 'event: ' .. event .. '\ndata: ' .. data .. '\n\n'
end

function M.html_escape(s)
  return (
    s:gsub('[&<>"\']', {
      ['&'] = '&amp;',
      ['<'] = '&lt;',
      ['>'] = '&gt;',
      ['"'] = '&quot;',
      ["'"] = '&#39;',
    })
  )
end

function M.percent_decode(s)
  return (s:gsub('%%(%x%x)', function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- Case-insensitive request-header lookup; `name` must be given lowercase.
function M.req_headers(head, name)
  local values = {}
  for k, v in head:gmatch('\r\n([%w%-]+):[ \t]*([^\r\n]*)') do
    if k:lower() == name then
      values[#values + 1] = (v:gsub('%s+$', ''))
    end
  end
  return values
end

function M.req_header(head, name)
  for k, v in head:gmatch('\r\n([%w%-]+):[ \t]*([^\r\n]*)') do
    if k:lower() == name then
      return (v:gsub('%s+$', ''))
    end
  end
end

--- True if `name` appears as a key in the query string (`?raw`, `?raw=1`).
function M.has_param(query, name)
  for pair in query:gmatch('[^&;]+') do
    if pair:match('^([^=]*)') == name then
      return true
    end
  end
  return false
end

--- Reject relative paths that could escape their base directory.
function M.is_confined(rel)
  if rel:find('\0', 1, true) or rel:find('\\', 1, true) or rel:sub(1, 1) == '/' or rel:match('^%a:') then
    return false
  end
  for seg in rel:gmatch('[^/]+') do
    if seg == '..' then
      return false
    end
  end
  return true
end

return M
