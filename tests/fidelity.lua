-- Browser-level fidelity test: renders a live preview in headless Chromium
-- and asserts the DOM matches GitHub's markup conventions.
--
--   nvim --clean --headless -l tests/fidelity.lua
--
-- Requires curl and chromium (or set MDPV_CHROME).

local script = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(script, ':p')))
vim.opt.runtimepath:prepend(root)

local chrome = os.getenv('MDPV_CHROME') or 'chromium'
if vim.fn.executable(chrome) == 0 then
  print('SKIP: no chromium found (set MDPV_CHROME)')
  os.exit(0)
end

local failures, passes = {}, 0
local function check(name, cond)
  if cond then
    passes = passes + 1
    print('  ok  ' .. name)
  else
    failures[#failures + 1] = name
    print('FAIL  ' .. name)
  end
end

require('mdpv').setup({ open_browser = false })
vim.cmd.edit(root .. '/tests/fixtures/sample.md')
local url = assert(require('mdpv').open(0), 'preview failed to open')
local token = url:match('/p/(%x+)$')

-- No --virtual-time-budget: the open SSE stream counts as pending network
-- activity and virtual time would never expire. --timeout force-dumps the
-- DOM after real time, well past the initial render (which happens at load
-- from the embedded boot payload).
--
-- Run async + vim.wait: SystemObj:wait() starves the vim.schedule hops the
-- server needs for buffer access.
local done, res
vim.system({
  chrome,
  '--headless=new',
  '--disable-gpu',
  '--user-data-dir=' .. vim.fn.tempname(),
  '--timeout=9000', -- KaTeX/Mermaid lazy-load and typeset after the initial render

  '--dump-dom',
  url,
}, { text = true, timeout = 30000 }, function(r)
  res = r
  done = true
end)
vim.wait(35000, function()
  return done == true
end, 10)

local dom = res and res.stdout or ''
check('chromium rendered the page', #dom > 1000)

-- Assert against the rendered article only: the raw markdown source is also
-- present in the page (boot JSON data block) and would confuse the checks.
local content = dom:match('<article id="content".-</article>') or ''
check('content region rendered', #content > 1000)

-- GitHub alert markup
check('alert div markup', content:find('class="markdown%-alert markdown%-alert%-note"') ~= nil)
check(
  'alert title with octicon',
  content:find('markdown%-alert%-title"><svg class="octicon octicon%-info mr%-2"') ~= nil
)
check('warning alert variant', content:find('class="markdown-alert markdown-alert-warning"', 1, true) ~= nil)
check('plain blockquote untouched', content:find('<blockquote[^>]*>%s*<p[^>]*>Regular blockquote') ~= nil)

-- Obsidian callouts (superset of GitHub alerts: more types, custom titles,
-- folding, nesting)
check('obsidian callout type', content:find('class="markdown-alert markdown-alert-success"', 1, true) ~= nil)
check(
  'custom title keeps inline markup',
  content:find('octicon%-check%-circle.-<span>All <strong>checks</strong> passed</span>') ~= nil
)
check('default title from type', content:find('octicon%-zap.-</svg>Danger</p>') ~= nil)
check(
  'alias resolves (faq -> question)',
  content:find('<details class="markdown%-alert markdown%-alert%-question"') ~= nil
)
check(
  '[!type]- folds closed',
  content:match('<details class="markdown%-alert markdown%-alert%-question"[^>]*') ~= nil
    and content:match('<details class="markdown%-alert markdown%-alert%-question"[^>]*'):find('open') == nil
)
check('[!type]+ folds open', content:find('<details class="markdown%-alert markdown%-alert%-tip"[^>]*open') ~= nil)
check(
  'summary title with fold chevron',
  content:find('<summary class="markdown%-alert%-title">.-octicon%-chevron%-down.-</summary>') ~= nil
)
check(
  'callouts nest',
  content:find('Can callouts nest%?</span>.-<div class="markdown%-alert markdown%-alert%-todo"') ~= nil
)
check('unknown type stays a blockquote', content:find('<blockquote[^>]*>%s*<p[^>]*>%[!unknown%]') ~= nil)

-- Task lists (GitHub classes come from markdown-it-task-lists). Live previews
-- render the checkboxes enabled — clicking one toggles the buffer line.
check('task list ul class', content:find('contains-task-list', 1, true) ~= nil)
check('task list item class', content:find('task-list-item', 1, true) ~= nil)
local checkbox = content:match('<input[^>]*task%-list%-item%-checkbox[^>]*>')
check('live checkbox is enabled (clickable)', checkbox ~= nil and checkbox:find('disabled') == nil)
check('checked state rendered', content:find('<input[^>]*checked[^>]*>') ~= nil)

-- Wikilinks (Obsidian style, resolved through the /f/ file route)
check('wikilink resolves to page.md', content:find('<a href="/f/' .. token .. '/second.md">second</a>', 1, true) ~= nil)
check('wikilink alias text', content:find('<a href="/f/' .. token .. '/second.md">the second page</a>', 1, true) ~= nil)
check('same-page heading wikilink', content:find('<a href="#wikilinks">#wikilinks</a>', 1, true) ~= nil)
check(
  'cross-page heading wikilink',
  content:find('<a href="/f/' .. token .. '/second.md#top">jump</a>', 1, true) ~= nil
)
check('image embed wikilink', content:find('<img src="/f/' .. token .. '/img.png" alt="img.png"', 1, true) ~= nil)

-- Heading anchors + GitHub slugs (incl. dedup)
check('heading id slug', content:find('id="sample%-document"') ~= nil)
check('anchor with octicon-link', content:find('class="anchor".-octicon%-link') ~= nil)
check(
  'duplicate slug deduped',
  content:find('id="duplicate%-heading"') ~= nil and content:find('id="duplicate%-heading%-1"') ~= nil
)

-- Footnotes (GitHub shape)
check(
  'footnotes section',
  content:find('data%-footnotes.-class="footnotes"') ~= nil or content:find('class="footnotes".-data%-footnotes') ~= nil
)
check('sr-only Footnotes label', content:find('class="sr%-only" id="footnote%-label">Footnotes') ~= nil)
check('backref GitHub class', content:find('data-footnote-backref', 1, true) ~= nil)
check('bare superscript ref (no brackets)', content:find('footnote%-ref"><a[^>]*>1</a>') ~= nil)

-- Syntax highlighting + GFM inline
check('hljs highlighted lua keyword', content:find('hljs%-keyword">local<') ~= nil)
check(
  'code blocks carry a copy button',
  content:find('<div class="mdpv%-pre"><pre>') ~= nil and content:find('class="mdpv%-copy"') ~= nil
)
check('strikethrough rendered', content:find('<s>strikethrough</s>', 1, true) ~= nil)
check('autolinked bare URL', content:find('<a href="https://example.com">https://example.com</a>', 1, true) ~= nil)
check('table rendered', content:find('<table>', 1, true) ~= nil)
check('details/summary HTML preserved', content:find('<summary>Raw HTML details</summary>', 1, true) ~= nil)

-- Math (KaTeX, lazy-loaded)
check('inline math typeset', content:find('class="katex"', 1, true) ~= nil)
local katex_displays = select(2, content:gsub('class="katex%-display"', ''))
check('$$ block and ```math fence typeset as display math', katex_displays >= 2)
check('math placeholder gone after typeset', content:find('language-math', 1, true) == nil)
check('lone $ left alone', content:find('($5) untouched', 1, true) ~= nil)

-- Mermaid (lazy-loaded)
check(
  'mermaid block rendered to svg',
  content:find('class="mdpv%-mermaid mdpv%-typeset"') ~= nil and content:find('<svg', 1, true) ~= nil
)
check('mermaid node label present', content:find('Edit buffer', 1, true) ~= nil)
check('no mermaid parse error', content:find('mdpv-error', 1, true) == nil)
check('mermaid pan/zoom controls attached', content:find('mdpv%-diagram%-controls') ~= nil)

-- Emoji shortcodes
check('emoji shortcode expanded', content:find('\240\159\154\128', 1, true) ~= nil) -- 🚀

-- Frontmatter rendered as a table (GitHub file view)
check('frontmatter table with keys', content:find('<th>title</th>', 1, true) ~= nil)
check('frontmatter value cell', content:find('FRONTMATTER_TITLE_VALUE</td>', 1, true) ~= nil)
check('frontmatter list joined', content:find('alpha, beta', 1, true) ~= nil)
check('frontmatter nested map flattened', content:find('status: passing, ci: local', 1, true) ~= nil)
check('frontmatter not rendered as markdown', content:find('<p>title:', 1, true) == nil)

-- Outline: a dedicated floating overlay, built from the slugged headings
check(
  'outline items built from headings',
  -- the first item also carries the scroll-spy "active" class by default
  dom:find('<a href="#sample%-document" class="outline%-h1[ "]') ~= nil
    and dom:find('<a href="#code" class="outline%-h3[ "]') ~= nil
)
check('outline rail shown by default', dom:find('id="mdpv%-toc"[^>]*hidden') == nil)
check(
  'outline rows carry rail dashes + labels',
  dom:find('class="toc%-bar"') ~= nil and dom:find('class="toc%-text"') ~= nil
)
check(
  'outline switch offered in the menu, on',
  dom:find('outline%-toggle"[^>]*aria%-pressed="true"') ~= nil and dom:find('outline%-toggle"[^>]*hidden') == nil
)

-- Menu: theme segmented control replaces the old cycling row
check(
  'theme options rendered as a segmented control',
  dom:find('data%-theme%-opt="auto"') ~= nil and dom:find('data%-theme%-opt="dark"') ~= nil
)

-- Scroll sync + diffing plumbing
check('blocks carry data-source-line', content:find('data-source-line="', 1, true) ~= nil)
check('sync toggles shown on a live preview', dom:find('id="sync%-group"[^>]*hidden') == nil)
check(
  'follow toggle visible and on',
  dom:find('follow%-toggle"[^>]*aria%-pressed="true"') ~= nil and dom:find('follow%-toggle"[^>]*hidden') == nil
)
check(
  'move-cursor-on-scroll toggle off under scroll_sync = true',
  dom:find('syncback%-toggle"[^>]*aria%-pressed="false"') ~= nil
)
check('typeset nodes keyed by source (morphdom)', content:find('data-mdpv-src="', 1, true) ~= nil)
check('morphdom loaded', dom:find('vendor/morphdom%-umd%.min%.js') ~= nil)

-- Local file routing + hygiene
check('relative image routed via /f/<token>/', content:find('src="/f/' .. token .. '/img.png"', 1, true) ~= nil)
check(
  'script tag sanitized out',
  content:find('<script', 1, true) == nil and content:find('document.body.innerHTML', 1, true) == nil
)
check('live status shown', dom:find('id="mdpv%-fab" data%-status="live"') ~= nil)

require('mdpv').stop()

print(('\n%d passed, %d failed'):format(passes, #failures))
if #failures > 0 then
  print('failed: ' .. table.concat(failures, ', '))
  os.exit(1)
end
