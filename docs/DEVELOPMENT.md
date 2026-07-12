# Development

## Tests

All suites run headless and exit non-zero on failure:

```sh
nvim --clean --headless -l tests/e2e.lua      # server, SSE, ranges/304, lifecycle (curl)
nvim --clean --headless -l tests/fidelity.lua # rendered DOM vs GitHub markup (chromium)
nvim --clean --headless -l tests/sync.lua     # scroll sync both ways, cursor marker, hash (chromium CDP + node)
nvim --clean --headless -l tests/interact.lua # task-checkbox click round trip (chromium CDP + node)
```

- `e2e.lua` needs `curl`.
- The rest need a `chromium` binary (or set `$MDPV_CHROME`); `sync.lua` and
  `interact.lua` also need Node 22+ (for its built-in WebSocket). All skip
  cleanly when a binary is missing.
- `tests/cdp.js` is the shared DevTools-protocol driver — dependency-free,
  spawned by the CDP-based suites.

## Formatting & lint

One gate runs everything:

```sh
./scripts/check.sh
```

That is: [StyLua](https://github.com/JohnnyMorganz/StyLua) in check mode
(config in `stylua.toml`; run `stylua lua/ tests/` to format),
`node --check` on the hand-written JS, and a headless
[lua-language-server](https://github.com/LuaLS/lua-language-server) run
(0 findings expected). Note the script resolves `$VIMRUNTIME` from Neovim
into a temporary copy of `.luarc.json` first — the headless checker does not
expand it, so a bare `lua-language-server --check .` reports spurious
undefined-`vim` findings.

The frontend (`assets/app.js`, `assets/mdpv.css`, `assets/index.html`) is
hand-formatted — no Prettier config on purpose; `node --check` guards syntax
and the test suites exercise the rest.

## Vendored assets

Frontend libraries live in `assets/vendor/` (pinned versions in
`assets/vendor/VERSIONS.txt`). Re-download them with:

```sh
./scripts/vendor.sh
```

## Design

Architecture and the reasoning behind each decision: [DESIGN.md](DESIGN.md).
