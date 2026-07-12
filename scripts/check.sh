#!/usr/bin/env sh
# Formatting + lint gate: stylua, node --check, lua-language-server.
# Run from anywhere; exits non-zero on the first failure.
set -eu
cd "$(dirname "$0")/.."

echo '== stylua --check'
stylua --check lua/ tests/

echo '== node --check'
node --check assets/app.js
node --check tests/cdp.js

echo '== lua-language-server --check'
# lua-language-server does not expand $VIMRUNTIME in .luarc.json (the
# editor-side LSP inherits it from Neovim; the headless checker does not),
# so resolve it into a temporary config first.
VIMRUNTIME=$(echo 'io.write(vim.env.VIMRUNTIME)' | nvim --clean --headless -l /dev/stdin 2>&1)
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
sed "s#\$VIMRUNTIME#$VIMRUNTIME#g" .luarc.json >"$tmp"
out=$(lua-language-server --check . --checklevel=Information --configpath "$tmp" 2>&1) || true
printf '%s\n' "$out" | tr '\r' '\n' | grep -E 'Diagnosis|\.lua' | tail -n 20
case "$out" in
*'no problems found'*) ;;
*)
  echo 'FAIL: lua-language-server found problems'
  exit 1
  ;;
esac

echo 'all checks passed'
