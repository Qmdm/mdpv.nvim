# mdpv.nvim — Design

Goals, research, and the reasoning behind every load-bearing decision.
Written against Neovim 0.12.4, 2026-07.

## 1. Requirements

1. `:Preview` opens a browser tab previewing the current buffer, updating
   live. (User commands must start uppercase, so `:preview` itself is
   impossible.)
2. Rendering visually identical to GitHub's markdown rendering (file/README
   view), light and dark.
3. Multiple previews at once (different buffers, same server).
4. Simple and robust: no external runtimes, no build step, no port conflicts.
5. Efficient: Neovim must never stall because a preview is open.

## 2. Research: prior art

Three plugins define the space (full report sources: their repos, issue
trackers, and raw sources; GitHub's live Markdown API; Neovim release-0.12
docs):

| | markdown-preview.nvim | peek.nvim | live-preview.nvim |
| --- | --- | --- | --- |
| Runtime | **Node.js** + socket.io | **Deno** + WebSocket | pure Lua `vim.uv` |
| Renderer | markdown-it (server) | markdown-it (Deno) | markdown-it (browser) |
| Port | `g:mkdp_port`, random | `port: 0` ephemeral | fixed 5500 |
| State (2026) | unmaintained, 262 open issues | stale | active |

Lessons taken:

- **The external runtime is the #1 failure class.** markdown-preview.nvim's
  most-commented issues are all install/build breakage (yarn builds, prebuilt
  binary downloads, `E117: Unknown function: mkdp#util#install`); peek.nvim's
  are "main.bundle.js not found" (skipped `deno task build`) and it broke on
  Deno 2's API removals. → *Pure `vim.uv` Lua, vendored frontend, no build.*
- **Fixed ports conflict.** (`EADDRINUSE`, markdown-preview.nvim #286;
  live-preview.nvim's fixed 5500.) → *Default `port = 0`: the OS hands out a
  free ephemeral port.*
- **Long-cached assets go stale across plugin updates** (live-preview.nvim
  tells users to clear their browser cache). → *Assets served
  `immutable` but URL-versioned per server session.*
- **live-preview.nvim proves feasibility** of the pure-Lua stack — it
  hand-rolls RFC 6455 WebSockets in ~60 lines. Its gap: browser-side plain
  markdown-it output doesn't match GitHub's rendering (no alerts, no GitHub
  anchor/footnote markup, non-Primer CSS). That gap is this plugin's focus.

## 3. Architecture

```
lua/mdpv/init.lua      config, :Preview command, public API
lua/mdpv/preview.lua   per-buffer lifecycle: token, buf_attach, debounce, teardown
lua/mdpv/server.lua    vim.uv TCP server: HTTP parsing, routes, SSE, static files
assets/index.html      page shell (template: {{TITLE}} {{BOOT}} {{CSS_LINKS}} …)
assets/app.js          browser renderer (markdown-it → DOMPurify → GitHub markup)
assets/mdpv.css        page chrome (floating menu, container) in Primer tokens
assets/vendor/         pinned deps (scripts/vendor.sh re-downloads them)
tests/                 e2e.lua · fidelity.lua · sync.lua (+ cdp.js driver)
```

Lua is `stylua`-formatted (`stylua.toml`); vendored frontend assets are the
only non-authored files.

### Routes

| Route | Serves |
| --- | --- |
| `GET /` | index of active previews |
| `GET /p/<token>` | page shell with the buffer content embedded (instant first paint) |
| `GET /events/<token>` | SSE stream: `update` events (JSON `{token,title,md,features}`), `scroll` events (cursor line), `close` event, 30 s heartbeat comments |
| `GET /f/<token>/<path>` | files resolved against the buffer's directory; `.md` files render as static pages (`?raw` for bytes) |
| `POST /sync/<token>` | browser → editor scroll sync: JSON `{line}` moves the cursor (`scroll_sync = 'both'`) |
| `GET /assets/<path>` | plugin frontend, `Cache-Control: immutable` + per-session `?v=` buster |

### Data flow

`nvim_buf_attach(on_lines)` → re-arm 150 ms `uv_timer` → (debounce elapses) →
`vim.schedule` → `nvim_buf_get_lines` → `vim.json.encode` → one SSE frame
written to every attached client → browser re-renders (~10 ms for a typical
README), restoring scroll position and skipping if content is unchanged.

## 4. Key decisions

**Pure `vim.uv`, HTTP hand-parsed.** Neovim 0.12 has an HTTP *client*
(`vim.net.request`) but no server API, so the server is ~150 lines over
`uv_tcp`: accumulate until `\r\n\r\n`, parse the request line, route GETs.
No keep-alive (each response closes; SSE sockets persist). This is the whole
protocol surface a preview needs.

**SSE instead of WebSocket.** Updates flow one way (editor → browser).
Server-Sent Events are plain HTTP — no RFC 6455 handshake/frame/mask code to
hand-roll (compare live-preview.nvim's 60-line websocket.lua), and the
browser's `EventSource` reconnects automatically with `retry:` for free, which
covers the "stale connection after suspend" pain point in prior art. Even
scroll sync — the usual argument for WebSocket — is editor → browser, so it
rides the same SSE stream as a `scroll` event. The reverse direction
(page-scroll moving the cursor, `scroll_sync = 'both'`) is a rare, tiny
message, which a plain `POST /sync/<token>` carries in ~20 lines — far
cheaper than upgrading the whole transport to RFC 6455.

**Render in the browser, not in Lua.** GitHub parses with cmark-gfm.
No Lua markdown parser is close; porting one would be the whole project.
markdown-it is a strict CommonMark implementation (same spec family as
cmark-gfm) with first-party GFM plugins, runs in the page, and moves 100% of
parse/render cost off the editor thread. Neovim's only per-edit work is
`nvim_buf_get_lines` + JSON encode.

**Fidelity = official CSS + exact GitHub markup.** `github-markdown-css` is
generated from GitHub's real Primer styles, so fidelity reduces to emitting
the markup GitHub emits (verified live against `POST api.github.com/markdown`
during research):

- *Alerts*: markdown-it has no alert plugin with GitHub markup, so a DOM pass
  converts `blockquote` starting with `[!NOTE]`… into
  `div.markdown-alert.markdown-alert-note` + `p.markdown-alert-title` with the
  correct Primer octicon (`octicon-info mr-2`, `light-bulb`, `report`,
  `alert`, `stop`) inlined from `@primer/octicons`.
- *Heading anchors*: `a.anchor` + `svg.octicon-link` prepended into `h1–h6`,
  hover-revealed by the stock CSS; ids from a github-slugger-compatible
  slugger (lowercase, strip punctuation, spaces→`-`, `-1`/`-2` dedup).
  Unprefixed ids (GitHub uses `user-content-` + JS indirection) so plain
  `#fragment` links work in a static page.
- *Task lists*: markdown-it-task-lists already emits GitHub's classes
  (`contains-task-list`, `task-list-item`, `task-list-item-checkbox`).
- *Footnotes*: markdown-it-footnote output is reshaped — `data-footnotes` on
  the section, an `sr-only` "Footnotes" `h2` (GitHub's markup; the CSS assumes
  the host provides `.sr-only`, so mdpv.css does), bare superscript numbers
  (the CSS draws GitHub's `[1]` brackets via `[data-footnote-ref]::before/
  ::after`), `data-footnote-backref` ↩ links.
- *Code*: highlight.js with its github/github-dark themes (media-query-merged
  for auto mode by `scripts/vendor.sh`).
- *Emoji*: markdown-it-emoji expands `:shortcodes:` to native unicode — the
  same glyphs GitHub's `<g-emoji>` wrapper displays on modern platforms.
- *Frontmatter*: rendered as a table (keys as the header row), matching
  GitHub's file view. Only flat `key: value` pairs and scalar lists are
  parsed; anything hairier degrades to stripping the block — never to
  rendering YAML as markdown.
- Raw HTML passes through markdown-it (`html: true`) and is sanitized by
  DOMPurify (scripts/handlers stripped, `<style>` forbidden — GitHub strips it
  too).

**Math and Mermaid: vendored but lazy.** GitHub renders `$…$`/`$$…$$`/
```` ```math ```` and ```` ```mermaid ```` client-side; so does mdpv. KaTeX
(+ fonts) and Mermaid are ~3.5 MB together, so the page never loads them up
front: markdown-it rules (adapted from markdown-it-katex) parse math into
inert placeholder elements, fences keep their `language-*` class, and after
each render a typesetting pass injects the vendored scripts *only if the
document needs them* (CSP `script-src 'self'` permits same-origin injection).
A render-generation counter discards typesetting results that finish after a
newer edit. KaTeX over MathJax (GitHub's engine): an order of magnitude
smaller and synchronous, with visually near-identical output; Mermaid runs
with `securityLevel: 'strict'`. Invalid TeX renders red in place; an invalid
diagram keeps its source block, like any unknown fence.

**Scroll sync over the existing SSE stream.** Every block element carries
`data-source-line` (markdown-it `token.map`, offset by the stripped
frontmatter). `CursorMoved` autocmds debounce 80 ms and broadcast the cursor
line; the page scrolls to the nearest mapped element, interpolating between
neighbours so long paragraphs track smoothly, aimed at the upper third of the
viewport. It follows the *cursor*, not the topline — the cursor is where the
user is working. The floating menu toggles it (persisted in localStorage);
`scroll_sync = false` removes the toggle entirely. The same menu carries the
connection dot plus per-browser theme, full-width, and go-to-top controls,
behind a Next.js-devtools-style round button that can be dragged to any
corner — the page itself stays chrome-free, like a rendered file on GitHub.

**Bidirectional sync (`scroll_sync = 'both'`) without feedback loops.** User
scrolls (debounced 150 ms) invert the line mapping at the viewport anchor and
`POST /sync/<token>`; Neovim clamps the line and moves the cursor in the
first window showing the buffer. Two guards kill the echo: the page ignores
scroll events for 1.2 s after its own programmatic smooth-scroll, and the
editor records a browser-applied line as "already broadcast" so the resulting
`CursorMoved` stays silent. Opt-in rather than default because a page scroll
yanking the cursor mid-edit is a taste decision.

**DOM diffing with morphdom.** Each update post-processes a detached copy of
the article, then morphs it into the live DOM instead of `innerHTML`-swapping.
Unchanged subtrees keep their nodes: images don't reflash, reader-opened
`<details>` stay open, and — via `data-mdpv-src` keys checked in
`onBeforeElUpdated` — typeset math and rendered diagrams survive edits
elsewhere in the document untouched (Mermaid renders cost 50–200 ms each, so
not re-rendering them per keystroke matters). Math/mermaid fences are
normalized to their placeholder `<div>`s *before* the diff so placeholder and
typeset result share a tag and can be paired. Falls back to a full swap if
morphdom is unavailable.

**Relative `.md` links render as pages.** A markdown file fetched through
`/f/<token>/…` gets the same page shell and renderer as a live preview, with
`base` pointing relative URLs at that file's own directory and `static: true`
telling the client to skip the EventSource (the floating menu shows "static
file"). `?raw` opts out. Navigation between linked docs therefore works like
browsing a repo on GitHub.

**Instant first paint.** The page embeds the buffer as a
`<script type="application/json">` data block (non-executable, hence CSP-safe;
`<` escaped as `\u003c` against `</script>` breakout) and renders at load.
SSE then only carries changes. Bonus: rendering is deterministic at the
`load` event, which makes DOM-dump testing reliable.

**Multiple previews = tokens, not servers.** One lazily-started server;
each buffer registers a 128-bit hex token namespacing its three routes.
Closing a preview 404s its routes and sends a final SSE `close` event so the
tab shows "preview closed" instead of silently reconnecting forever. The
server auto-stops with the last preview (`auto_stop`).

**Fast-event discipline.** Every socket/fs callback runs in libuv's fast
context where `vim.api` is off-limits (`E5560`). The rule used throughout:
fast context does string/socket work only; anything touching buffers hops via
`vim.schedule`. Corollary found while testing: `vim.system():wait()` pumps
only fast events, so the test harness polls with `vim.wait()` instead —
scheduled callbacks starve otherwise.

**Change detection via `nvim_buf_attach`, not autocmds.** `TextChanged*`
misses API-driven edits (confirmed by a failing e2e test — and in real use
that means LSP formatting, code actions, `nvim_buf_set_lines` from other
plugins). `on_lines` fires for every mutation; under textlock it only re-arms
a `uv_timer`, so it's safe and O(1) per keystroke. Autocmds remain for
lifecycle only (`BufFilePost` rename, `BufUnload`/`BufWipeout` auto-close).

**Security posture.** Binds `127.0.0.1`; tokens are `uv.random` 128-bit
(URL knowledge = capability); strict CSP (`script-src 'self'`, no inline
scripts — boot data is a JSON block); DOMPurify on rendered HTML. Both the
`/assets/` and `/f/<token>/` routes reject NUL bytes, absolute paths, and any
`..` segment, so a token holder cannot traverse out of the plugin's asset
directory or the buffer's own directory. The trade-off is deliberate: a
relative link pointing *above* the file's directory (`../sibling/x.png`) does
not resolve — the safe choice for a loopback server that would otherwise hand
arbitrary files to anyone holding the token, and there is no repo-root concept
here to bound traversal against.

## 5. Performance notes

- Server work per edit burst: one timer re-arm per `on_lines` (no allocation),
  then a single lines-join + JSON encode after 150 ms of quiet.
- No markdown parsing in Neovim, ever.
- Browser re-render parses + diffs (morphdom) in ~5–20 ms on README-sized
  documents; only changed DOM subtrees are touched. Content-unchanged pushes
  are skipped by string compare; typeset math/diagrams are keyed by source and
  skipped when unchanged.
- Static assets: `immutable` + per-session `?v=` — one fetch per session,
  correct across plugin updates.
- SSE heartbeat every 30 s doubles as dead-socket collection; closed tabs
  are also pruned on read-EOF.

## 6. Testing

- `tests/e2e.lua` (62 checks): real Neovim + curl against the live server —
  routes, headers, CSP, `..` traversal rejection on both `/assets/` and `/f/`,
  SSE initial + live-edit push,
  scroll events, `POST /sync` cursor moves (incl. clamping and bad payloads),
  static `.md` pages + `?raw`, multi-preview isolation, re-open reuse,
  filetype guard, auto-close on wipeout, auto-stop, restart, `:Preview`
  command surface.
- `tests/fidelity.lua` (41 checks): headless Chromium `--dump-dom` of a live
  preview asserting GitHub markup (alert divs + octicons, task-list classes,
  slug dedup, footnote shape, hljs spans, KaTeX inline/display typesetting,
  Mermaid SVG, emoji expansion, frontmatter table incl. nested maps,
  source-line mapping, morphdom keys, sanitization, `/f/` URL rewriting).
- `tests/sync.lua` (5 checks): drives headless Chromium over the DevTools
  protocol (tests/cdp.js, dependency-free — Node's built-in WebSocket) to
  prove scroll sync in both directions against a real page: a cursor move
  scrolls the browser, and a synthetic user scroll moves the cursor.
- All run headless: `nvim --clean --headless -l tests/<file>.lua`.

## 7. Future work

- Optional MathJax backend for glyph-exact GitHub math (KaTeX covers the
  practical cases at a tenth of the weight).
- Frontmatter nested beyond one level (currently degrades to stripping).
- `:Preview export` — write the rendered page (assets inlined) to a
  self-contained HTML file.
