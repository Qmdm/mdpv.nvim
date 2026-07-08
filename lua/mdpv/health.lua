local M = {}

function M.check()
  local health = vim.health
  health.start('mdpv.nvim')

  if vim.fn.has('nvim-0.12') == 1 then
    health.ok(('Neovim %s'):format(tostring(vim.version())))
  else
    health.error('Neovim 0.12+ required')
  end

  local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
  local required = {
    'assets/index.html',
    'assets/app.js',
    'assets/mdpv.css',
    'assets/favicon.svg',
    'assets/vendor/markdown-it.min.js',
    'assets/vendor/markdown-it-task-lists.min.js',
    'assets/vendor/markdown-it-footnote.min.js',
    'assets/vendor/markdown-it-emoji.min.js',
    'assets/vendor/purify.min.js',
    'assets/vendor/highlight.min.js',
    'assets/vendor/github-markdown.css',
    'assets/vendor/github-markdown-light.css',
    'assets/vendor/github-markdown-dark.css',
    'assets/vendor/github.min.css',
    'assets/vendor/github-dark.min.css',
    'assets/vendor/hljs-github-auto.css',
    'assets/vendor/mermaid.min.js',
    'assets/vendor/morphdom-umd.min.js',
    'assets/vendor/katex/katex.min.js',
    'assets/vendor/katex/katex.min.css',
    'assets/vendor/katex/fonts/KaTeX_Main-Regular.woff2',
  }
  local missing = {}
  for _, rel in ipairs(required) do
    if vim.uv.fs_stat(root .. '/' .. rel) == nil then
      missing[#missing + 1] = rel
    end
  end
  if #missing == 0 then
    health.ok('all frontend assets present')
  else
    health.error('missing assets: ' .. table.concat(missing, ', '))
  end

  local server = require('mdpv.server')
  if server.is_running() then
    local info = server.info()
    health.ok(
      ('server running on %s:%d (%d preview%s)'):format(
        info.host,
        info.port,
        info.previews,
        info.previews == 1 and '' or 's'
      )
    )
  else
    health.info('server not running (starts on first :Preview)')
  end
end

return M
