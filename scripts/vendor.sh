#!/usr/bin/env bash
# Re-download the pinned frontend dependencies into assets/vendor/.
# Bump the pins deliberately and re-run tests/e2e.lua afterwards.
set -euo pipefail

MARKDOWN_IT=14.3.0
TASK_LISTS=2.1.1
FOOTNOTE=4.0.0
EMOJI=3.0.0
DOMPURIFY=3.4.11
HLJS=11.11.1
GH_MD_CSS=5.9.0
KATEX=0.17.0
MERMAID=11.16.0
MORPHDOM=2.7.8

dir="$(cd "$(dirname "$0")/../assets/vendor" && pwd)"
cd "$dir"

fetch() { echo "  $2"; curl -fsSL -o "$2" "$1"; }

fetch "https://unpkg.com/markdown-it@$MARKDOWN_IT/dist/markdown-it.min.js" markdown-it.min.js
fetch "https://unpkg.com/markdown-it-task-lists@$TASK_LISTS/dist/markdown-it-task-lists.min.js" markdown-it-task-lists.min.js
fetch "https://unpkg.com/markdown-it-footnote@$FOOTNOTE/dist/markdown-it-footnote.min.js" markdown-it-footnote.min.js
fetch "https://unpkg.com/markdown-it-emoji@$EMOJI/dist/markdown-it-emoji.min.js" markdown-it-emoji.min.js
fetch "https://unpkg.com/dompurify@$DOMPURIFY/dist/purify.min.js" purify.min.js
fetch "https://unpkg.com/@highlightjs/cdn-assets@$HLJS/highlight.min.js" highlight.min.js
fetch "https://unpkg.com/@highlightjs/cdn-assets@$HLJS/styles/github.min.css" github.min.css
fetch "https://unpkg.com/@highlightjs/cdn-assets@$HLJS/styles/github-dark.min.css" github-dark.min.css
fetch "https://unpkg.com/github-markdown-css@$GH_MD_CSS/github-markdown.css" github-markdown.css
fetch "https://unpkg.com/github-markdown-css@$GH_MD_CSS/github-markdown-light.css" github-markdown-light.css
fetch "https://unpkg.com/github-markdown-css@$GH_MD_CSS/github-markdown-dark.css" github-markdown-dark.css
fetch "https://unpkg.com/mermaid@$MERMAID/dist/mermaid.min.js" mermaid.min.js
fetch "https://unpkg.com/morphdom@$MORPHDOM/dist/morphdom-umd.min.js" morphdom-umd.min.js

# KaTeX ships fonts referenced relatively from its CSS, so it gets its own
# subdirectory (only the woff2 fonts; every current browser uses those).
echo "  katex/ (js + css + woff2 fonts)"
rm -rf katex && mkdir -p katex
curl -fsSL "https://registry.npmjs.org/katex/-/katex-$KATEX.tgz" \
  | tar -xz -C katex --strip-components=2 --wildcards \
      package/dist/katex.min.js package/dist/katex.min.css 'package/dist/fonts/*.woff2'

{
  echo "/* github + github-dark hljs themes gated on prefers-color-scheme (built by scripts/vendor.sh) */"
  echo "@media (prefers-color-scheme: light) {"
  cat github.min.css
  echo
  echo "}"
  echo "@media (prefers-color-scheme: dark) {"
  cat github-dark.min.css
  echo
  echo "}"
} > hljs-github-auto.css

{
  echo "Pinned vendor versions (refresh with scripts/vendor.sh):"
  echo "  markdown-it            $MARKDOWN_IT"
  echo "  markdown-it-task-lists $TASK_LISTS"
  echo "  markdown-it-footnote   $FOOTNOTE"
  echo "  markdown-it-emoji      $EMOJI"
  echo "  dompurify              $DOMPURIFY"
  echo "  highlight.js           $HLJS"
  echo "  github-markdown-css    $GH_MD_CSS"
  echo "  katex                  $KATEX"
  echo "  mermaid                $MERMAID"
  echo "  morphdom               $MORPHDOM"
} > VERSIONS.txt

echo "done."
