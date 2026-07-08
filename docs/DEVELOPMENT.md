# Development

## Tests

All suites run headless and exit non-zero on failure:

```sh
nvim --clean --headless -l tests/e2e.lua      # server, SSE, lifecycle (curl)
nvim --clean --headless -l tests/fidelity.lua # rendered DOM vs GitHub markup (chromium)
nvim --clean --headless -l tests/sync.lua     # bidirectional scroll sync (chromium CDP + node)
```

- `e2e.lua` needs `curl`.
- `fidelity.lua` and `sync.lua` need a `chromium` binary; `sync.lua` also needs
  Node 22+ (for its built-in WebSocket). Both skip cleanly when the binary is
  missing.

## Formatting & lint

Lua is formatted with [StyLua](https://github.com/JohnnyMorganz/StyLua)
(config in `stylua.toml`) and linted with
[lua-language-server](https://github.com/LuaLS/lua-language-server)
(config in `.luarc.json` — it resolves the `vim`/`uv` types from the Neovim
runtime):

```sh
stylua .                                        # format
stylua --check .                                # verify formatting
lua-language-server --check . --checklevel=Information  # lint (0 findings expected)
```

The frontend (`assets/app.js`, `assets/mdpv.css`, `assets/index.html`) is
hand-formatted — no Prettier config on purpose; `node --check assets/app.js`
guards syntax, and the test suites exercise the rest.

## Vendored assets

Frontend libraries live in `assets/vendor/` (pinned versions in
`assets/vendor/VERSIONS.txt`). Re-download them with:

```sh
./scripts/vendor.sh
```

## Design

Architecture and the reasoning behind each decision: [DESIGN.md](DESIGN.md).
