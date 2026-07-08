// mdpv client: receives raw markdown over SSE, renders it GitHub-style.
//
// Pipeline: markdown-it (CommonMark + GFM plugins) -> DOMPurify -> DOM
// post-processing that reshapes the output into the exact markup GitHub emits
// (alerts, heading anchors, footnotes), so github-markdown-css styles it 1:1.
(() => {
  'use strict';

  // {token, title, md, features, static?, base?} — embedded server-side for
  // an instant first paint.
  const BOOT = JSON.parse(document.getElementById('mdpv-boot').textContent);
  const FEATURES = BOOT.features || {};
  const FILE_BASE = BOOT.base || `/f/${BOOT.token}`;
  // Session cache-buster, recovered from our own <script src="...?v=...">
  // so lazily loaded vendor assets (KaTeX, Mermaid) get the same versioning.
  const V = new URL(document.currentScript.src, location.href).searchParams.get('v') || '0';
  const $content = document.getElementById('content');
  const $fab = document.getElementById('mdpv-fab');
  const $fabToggle = document.getElementById('fab-toggle');
  const $fabMenu = document.getElementById('fab-menu');
  const $status = document.getElementById('status');
  const $statusText = document.getElementById('status-text');
  const $follow = document.getElementById('follow-toggle');

  // Primer octicons, the same glyphs GitHub uses.
  const svg = (cls, path) =>
    `<svg class="octicon ${cls}" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path fill="currentColor" d="${path}"></path></svg>`;
  const OCTICON = {
    link: svg('octicon-link', 'm7.775 3.275 1.25-1.25a3.5 3.5 0 1 1 4.95 4.95l-2.5 2.5a3.5 3.5 0 0 1-4.95 0 .751.751 0 0 1 .018-1.042.751.751 0 0 1 1.042-.018 1.998 1.998 0 0 0 2.83 0l2.5-2.5a2.002 2.002 0 0 0-2.83-2.83l-1.25 1.25a.751.751 0 0 1-1.042-.018.751.751 0 0 1-.018-1.042Zm-4.69 9.64a1.998 1.998 0 0 0 2.83 0l1.25-1.25a.751.751 0 0 1 1.042.018.751.751 0 0 1 .018 1.042l-1.25 1.25a3.5 3.5 0 1 1-4.95-4.95l2.5-2.5a3.5 3.5 0 0 1 4.95 0 .751.751 0 0 1-.018 1.042.751.751 0 0 1-1.042.018 1.998 1.998 0 0 0-2.83 0l-2.5 2.5a1.998 1.998 0 0 0 0 2.83Z'),
    note: svg('octicon-info mr-2', 'M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z'),
    tip: svg('octicon-light-bulb mr-2', 'M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z'),
    important: svg('octicon-report mr-2', 'M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z'),
    warning: svg('octicon-alert mr-2', 'M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z'),
    caution: svg('octicon-stop mr-2', 'M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z'),
  };

  // Math is parsed with markdown-it rules (adapted from markdown-it-katex,
  // MIT) into inert placeholder elements; KaTeX itself is lazy-loaded and
  // typesets them after sanitization. GitHub's delimiters: $…$, $$…$$, and
  // ```math fences (fences are handled at the DOM stage).
  function mathPlugin(mdi) {
    function validDelim(state, pos) {
      const prev = pos > 0 ? state.src.charCodeAt(pos - 1) : -1;
      const next = pos + 1 <= state.posMax ? state.src.charCodeAt(pos + 1) : -1;
      return {
        canOpen: next !== 0x20 && next !== 0x09,
        canClose: !(prev === 0x20 || prev === 0x09 || (next >= 0x30 && next <= 0x39)),
      };
    }

    function mathInline(state, silent) {
      if (state.src[state.pos] !== '$') return false;
      if (!validDelim(state, state.pos).canOpen) {
        if (!silent) state.pending += '$';
        state.pos += 1;
        return true;
      }
      const start = state.pos + 1;
      let match = start;
      while ((match = state.src.indexOf('$', match)) !== -1) {
        let pos = match - 1;
        while (state.src[pos] === '\\') pos -= 1;
        if ((match - pos) % 2 === 1) break; // unescaped $
        match += 1;
      }
      if (match === -1) {
        if (!silent) state.pending += '$';
        state.pos = start;
        return true;
      }
      if (match - start === 0) {
        if (!silent) state.pending += '$$';
        state.pos = start + 1;
        return true;
      }
      if (!validDelim(state, match).canClose) {
        if (!silent) state.pending += '$';
        state.pos = start;
        return true;
      }
      if (!silent) {
        const token = state.push('math_inline', 'math', 0);
        token.markup = '$';
        token.content = state.src.slice(start, match);
      }
      state.pos = match + 1;
      return true;
    }

    function mathBlock(state, start, end, silent) {
      let pos = state.bMarks[start] + state.tShift[start];
      let max = state.eMarks[start];
      if (pos + 2 > max || state.src.slice(pos, pos + 2) !== '$$') return false;
      pos += 2;
      let firstLine = state.src.slice(pos, max);
      let lastLine = '';
      let found = false;
      let next = start;
      if (firstLine.trim().slice(-2) === '$$') {
        firstLine = firstLine.trim().slice(0, -2); // single-line $$…$$
        found = true;
      }
      while (!found) {
        next += 1;
        if (next >= end) break;
        pos = state.bMarks[next] + state.tShift[next];
        max = state.eMarks[next];
        if (pos < max && state.tShift[next] < state.blkIndent) break;
        if (state.src.slice(pos, max).trim().slice(-2) === '$$') {
          const lastPos = state.src.slice(0, max).lastIndexOf('$$');
          lastLine = state.src.slice(pos, lastPos);
          found = true;
        }
      }
      if (!found) return false; // unclosed $$: leave the text alone (GitHub does too)
      if (silent) return true;
      const token = state.push('math_block', 'math', 0);
      token.block = true;
      token.content =
        (firstLine.trim() ? firstLine + '\n' : '') +
        state.getLines(start + 1, next, state.tShift[start], true) +
        (lastLine.trim() ? lastLine : '');
      token.map = [start, next + 1];
      token.markup = '$$';
      state.line = next + 1;
      return true;
    }

    mdi.inline.ruler.after('escape', 'math_inline', mathInline);
    mdi.block.ruler.after('blockquote', 'math_block', mathBlock, {
      alt: ['paragraph', 'reference', 'blockquote', 'list'],
    });
    mdi.renderer.rules.math_inline = (tokens, i) =>
      `<span class="mdpv-math">${mdi.utils.escapeHtml(tokens[i].content)}</span>`;
    mdi.renderer.rules.math_block = (tokens, i, opts, env, self) =>
      `<div class="mdpv-math mdpv-math-display"${self.renderAttrs(tokens[i])}>${mdi.utils.escapeHtml(tokens[i].content)}</div>`;
  }

  const md = window
    .markdownit({
      html: true, // raw HTML passes through, DOMPurify sanitizes after
      linkify: true, // GFM autolinks bare URLs
      typographer: false, // GitHub does not smart-quote
      highlight(code, lang) {
        const l = (lang || '').split(/\s+/)[0].toLowerCase();
        if (l && window.hljs.getLanguage(l)) {
          try {
            return window.hljs.highlight(code, { language: l, ignoreIllegals: true }).value;
          } catch (_) { /* fall through to plain escaping */ }
        }
        return ''; // markdown-it escapes it
      },
    })
    .use(window.markdownitTaskLists) // emits GitHub's task-list-item classes
    .use(window.markdownitFootnote);
  if (FEATURES.emoji !== false && window.markdownitEmoji) md.use(window.markdownitEmoji);
  if (FEATURES.math !== false) md.use(mathPlugin);

  // Every block element carries its markdown source line so the page can
  // scroll to wherever the Neovim cursor is (scroll sync). `srcLineOffset`
  // accounts for a frontmatter block removed before rendering.
  let srcLineOffset = 0;
  md.core.ruler.push('mdpv_source_lines', (state) => {
    for (const t of state.tokens) {
      if (t.map && t.nesting !== -1) {
        t.attrSet('data-source-line', String(t.map[0] + 1 + srcLineOffset));
      }
    }
  });

  // --- GitHub-shaped post-processing -------------------------------------

  // YAML frontmatter: GitHub's file view renders it as a table (keys as the
  // header row, values below). A minimal YAML subset is parsed — flat
  // `key: value` pairs, block/inline lists of scalars, and one level of
  // nested maps (joined as "sub: value, …"); anything more complex falls
  // back to stripping the block, never to rendering it as markdown.
  // Returns {body, offset, pairs}.
  const FM_RE = /^---\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/;
  function parseFrontmatter(src) {
    if (!/^---\r?\n/.test(src)) return { body: src, offset: 0, pairs: null };
    const m = FM_RE.exec(src);
    if (!m) return { body: src, offset: 0, pairs: null };
    const offset = m[0].split('\n').length - 1;
    const stripped = { body: src.slice(m[0].length), offset, pairs: null };
    const unquote = (v) => v.replace(/^(['"])(.*)\1$/, '$2');
    const pairs = [];
    let open = null; // key awaiting indented list items / nested map entries
    for (const raw of m[1].split(/\r?\n/)) {
      if (!raw.trim() || raw.trim().startsWith('#')) continue;
      if (/^\s/.test(raw) && open) {
        const item = /^\s+-\s*(.*)$/.exec(raw);
        const sub = /^\s+([\w][\w .-]*):\s*(.+)$/.exec(raw);
        let piece;
        if (item) piece = unquote(item[1].trim());
        else if (sub) piece = `${sub[1]}: ${unquote(sub[2].trim())}`;
        else return stripped; // deeper nesting than we render
        const p = pairs[pairs.length - 1];
        p[1] = p[1] ? `${p[1]}, ${piece}` : piece;
        continue;
      }
      const kv = /^([\w][\w .-]*):\s*(.*)$/.exec(raw);
      if (!kv) return stripped;
      let value = kv[2].trim();
      open = value === '' ? kv[1] : null;
      if (/^\[.*\]$/.test(value)) {
        value = value.slice(1, -1).split(',').map((s) => unquote(s.trim())).join(', ');
      }
      pairs.push([kv[1], unquote(value)]);
    }
    return { body: stripped.body, offset, pairs: pairs.length ? pairs : null };
  }

  function frontmatterTable(pairs) {
    const table = document.createElement('table');
    const thead = table.createTHead().insertRow();
    const row = table.createTBody().insertRow();
    for (const [key, value] of pairs) {
      const th = document.createElement('th');
      th.textContent = key;
      thead.appendChild(th);
      row.insertCell().textContent = value;
    }
    return table;
  }

  // github-slugger-compatible heading ids (common cases).
  function makeSlugger() {
    const seen = Object.create(null);
    return (text) => {
      let slug = text
        .trim()
        .toLowerCase()
        .replace(/[^\p{L}\p{N}\p{Emoji_Presentation} _-]/gu, '')
        .replace(/ /g, '-');
      if (slug in seen) {
        seen[slug] += 1;
        slug = `${slug}-${seen[slug]}`;
      } else {
        seen[slug] = 0;
      }
      return slug;
    };
  }

  function addHeadingAnchors(root) {
    const slug = makeSlugger();
    for (const h of root.querySelectorAll('h1,h2,h3,h4,h5,h6')) {
      const id = slug(h.textContent || '');
      if (!id) continue;
      h.id = id;
      const a = document.createElement('a');
      a.className = 'anchor';
      a.href = `#${id}`;
      a.setAttribute('aria-hidden', 'true');
      a.tabIndex = -1;
      a.innerHTML = OCTICON.link;
      h.prepend(a);
    }
  }

  // > [!NOTE] blockquotes -> GitHub's <div class="markdown-alert ..."> markup.
  const ALERT_RE = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*(\r?\n|$)/;
  function transformAlerts(root) {
    for (const bq of root.querySelectorAll('blockquote')) {
      const first = bq.firstElementChild;
      if (!first || first.tagName !== 'P') continue;
      const textNode = first.firstChild;
      if (!textNode || textNode.nodeType !== Node.TEXT_NODE) continue;
      const m = ALERT_RE.exec(textNode.nodeValue);
      if (!m) continue;

      const kind = m[1].toLowerCase();
      textNode.nodeValue = textNode.nodeValue.slice(m[0].length);
      if (first.firstElementChild && first.firstElementChild.tagName === 'BR' && !textNode.nodeValue) {
        first.firstElementChild.remove();
      }
      if (!first.textContent.trim() && first.children.length === 0) first.remove();

      const div = document.createElement('div');
      div.className = `markdown-alert markdown-alert-${kind}`;
      const title = document.createElement('p');
      title.className = 'markdown-alert-title';
      title.innerHTML = `${OCTICON[kind]}${m[1].charAt(0)}${m[1].slice(1).toLowerCase()}`;
      div.appendChild(title);
      while (bq.firstChild) div.appendChild(bq.firstChild);
      bq.replaceWith(div);
    }
  }

  // Align markdown-it-footnote output with GitHub's rendering: GitHub emits
  // <section data-footnotes class="footnotes"> with an sr-only "Footnotes"
  // heading, bare superscript numbers, and octicon-free "↩" backrefs.
  function polishFootnotes(root) {
    const section = root.querySelector('section.footnotes');
    if (!section) return;
    section.setAttribute('data-footnotes', '');
    const sep = root.querySelector('hr.footnotes-sep');
    if (sep) sep.remove(); // .footnotes already has a border-top
    const label = document.createElement('h2');
    label.className = 'sr-only';
    label.id = 'footnote-label';
    label.textContent = 'Footnotes';
    section.prepend(label);
    for (const ref of root.querySelectorAll('sup.footnote-ref > a')) {
      ref.textContent = ref.textContent.replace(/^\[(.+)\]$/, '$1'); // [1] -> 1
      ref.setAttribute('data-footnote-ref', '');
      ref.setAttribute('aria-describedby', 'footnote-label');
    }
    for (const back of root.querySelectorAll('a.footnote-backref')) {
      back.classList.add('data-footnote-backref');
      back.textContent = '↩';
    }
  }

  // Point relative resources at the /f/<token>/ file route so images and
  // links next to the markdown file resolve like they do on GitHub. On a
  // statically rendered .md file the base is that file's own directory.
  const ABSOLUTE_RE = /^(?:[a-z][a-z0-9+.-]*:|\/\/|#|\/)/i;
  function rewriteRelativeUrls(root) {
    const rewrite = (el, attr) => {
      const v = el.getAttribute(attr);
      if (v && !ABSOLUTE_RE.test(v)) {
        el.setAttribute(attr, `${FILE_BASE}/${v}`);
      }
    };
    for (const el of root.querySelectorAll('img[src]')) rewrite(el, 'src');
    for (const el of root.querySelectorAll('video[src], audio[src], source[src]')) rewrite(el, 'src');
    for (const el of root.querySelectorAll('a[href]')) rewrite(el, 'href');
  }

  // --- Lazy typesetting: KaTeX (math) and Mermaid (diagrams) ---------------
  //
  // Both libraries are heavyweight, so they are vendored but only fetched the
  // first time a document actually needs them (CSP script-src 'self' allows
  // same-origin injection). Typesetting is async; a generation counter makes
  // sure a slow pass never touches a newer render.

  function loadAsset(tag, attrs) {
    return new Promise((resolve, reject) => {
      const el = document.createElement(tag);
      Object.assign(el, attrs, { onload: resolve, onerror: reject });
      document.head.appendChild(el);
    });
  }

  const isDark = () => {
    const t = document.documentElement.dataset.theme;
    return t === 'dark' || (t !== 'light' && matchMedia('(prefers-color-scheme: dark)').matches);
  };

  let katexReady = null;
  const ensureKatex = () =>
    (katexReady ??= Promise.all([
      loadAsset('script', { src: `/assets/vendor/katex/katex.min.js?v=${V}` }),
      loadAsset('link', { rel: 'stylesheet', href: `/assets/vendor/katex/katex.min.css?v=${V}` }),
    ]));

  // Typeset targets are normalized to placeholder <div>/<span>s carrying
  // their source in data-mdpv-src *before* the DOM diff, so a typeset result
  // and its regenerated placeholder share a tag and the differ can pair them
  // up (and skip re-typesetting when the source didn't change). The
  // 'mdpv-typeset' class marks finished nodes.
  function normalizeTypeset(root) {
    const swap = (code, cls) => {
      const div = document.createElement('div');
      div.className = cls;
      div.textContent = code.textContent;
      const line = code.getAttribute('data-source-line');
      if (line) div.setAttribute('data-source-line', line);
      code.parentElement.replaceWith(div);
    };
    if (FEATURES.math !== false) {
      for (const code of root.querySelectorAll('pre > code.language-math')) {
        swap(code, 'mdpv-math mdpv-math-display'); // ```math fence -> display math
      }
    }
    if (FEATURES.mermaid !== false) {
      for (const code of root.querySelectorAll('pre > code.language-mermaid')) {
        swap(code, 'mdpv-mermaid');
      }
    }
    for (const el of root.querySelectorAll('.mdpv-math, .mdpv-mermaid')) {
      el.dataset.mdpvSrc = el.textContent;
    }
  }

  function typesetMath(root, gen) {
    const nodes = root.querySelectorAll('.mdpv-math:not(.mdpv-typeset)');
    if (nodes.length === 0) return;
    ensureKatex().then(() => {
      if (gen !== generation) return;
      for (const el of nodes) {
        const src = el.dataset.mdpvSrc ?? el.textContent;
        try {
          window.katex.render(src, el, {
            displayMode: el.classList.contains('mdpv-math-display'),
            throwOnError: false, // invalid TeX renders in red, like a typo should
          });
        } catch (_) {
          el.textContent = src;
        }
        el.classList.add('mdpv-typeset');
      }
    }, () => {});
  }

  let mermaidReady = null;
  let mermaidSeq = 0;
  const ensureMermaid = () =>
    (mermaidReady ??= loadAsset('script', { src: `/assets/vendor/mermaid.min.js?v=${V}` }).then(() => {
      window.mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        theme: isDark() ? 'dark' : 'default',
      });
    }));

  function typesetMermaid(root, gen) {
    const blocks = root.querySelectorAll('.mdpv-mermaid:not(.mdpv-typeset)');
    if (blocks.length === 0) return;
    ensureMermaid().then(async () => {
      for (const div of blocks) {
        if (gen !== generation) return;
        const id = `mdpv-mermaid-${++mermaidSeq}`;
        try {
          const { svg } = await window.mermaid.render(id, div.dataset.mdpvSrc ?? div.textContent);
          if (gen !== generation) return;
          div.innerHTML = svg; // generated by vendored mermaid in strict mode
        } catch (_) {
          document.getElementById(`d${id}`)?.remove(); // mermaid's error scratch node
          div.classList.add('mdpv-error'); // invalid diagram: source stays visible
        }
        div.classList.add('mdpv-typeset');
      }
    }, () => {});
  }

  // Re-theme diagrams when the effective color scheme changes: reset every
  // rendered diagram to its source and typeset again. Called on the theme
  // toggle and when the OS scheme flips under the auto theme.
  function rethemeMermaid() {
    if (!mermaidReady) return;
    mermaidReady.then(() => {
      window.mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        theme: isDark() ? 'dark' : 'default',
      });
      for (const div of $content.querySelectorAll('.mdpv-mermaid.mdpv-typeset')) {
        div.classList.remove('mdpv-typeset', 'mdpv-error');
        div.textContent = div.dataset.mdpvSrc || '';
      }
      typesetMermaid($content, generation);
    });
  }

  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (document.documentElement.dataset.theme === 'auto') rethemeMermaid();
  });

  // --- Render loop ---------------------------------------------------------

  let lastSource = null;
  let firstRender = true;
  let generation = 0;

  function render(src) {
    if (src === lastSource) return;
    lastSource = src;
    generation += 1;
    const gen = generation;

    const fm = parseFrontmatter(src);
    srcLineOffset = fm.offset;
    const html = md.render(fm.body);
    const clean = window.DOMPurify.sanitize(html, {
      FORBID_TAGS: ['style'], // GitHub strips <style> from markdown too
      USE_PROFILES: { html: true, svg: true, svgFilters: true },
    });

    // Post-process a detached copy, then diff it into the live article with
    // morphdom: untouched subtrees keep their DOM nodes, so images don't
    // reload, open <details> stay open, and unchanged math/diagrams keep
    // their typeset result instead of flashing back to source.
    const next = $content.cloneNode(false);
    next.innerHTML = clean;
    if (fm.pairs) next.prepend(frontmatterTable(fm.pairs));
    transformAlerts(next);
    addHeadingAnchors(next);
    polishFootnotes(next);
    rewriteRelativeUrls(next);
    normalizeTypeset(next);

    const scrollX = window.scrollX;
    const scrollY = window.scrollY;
    if (window.morphdom) {
      window.morphdom($content, next, {
        onBeforeElUpdated(from, to) {
          if (
            from.classList.contains('mdpv-typeset')
            && from.dataset.mdpvSrc === to.dataset.mdpvSrc
          ) {
            // Same source: keep the typeset node, just refresh its line map.
            const line = to.getAttribute('data-source-line');
            if (line) from.setAttribute('data-source-line', line);
            return false;
          }
          if (from.tagName === 'DETAILS' && from.open !== to.open) {
            to.open = from.open; // keep reader-toggled state across updates
          }
          return !from.isEqualNode(to);
        },
      });
    } else {
      $content.innerHTML = next.innerHTML; // fallback: full swap
    }

    if (FEATURES.math !== false) typesetMath($content, gen);
    if (FEATURES.mermaid !== false) typesetMermaid($content, gen);

    if (firstRender) {
      firstRender = false;
      if (location.hash) {
        const target = document.getElementById(decodeURIComponent(location.hash.slice(1)));
        if (target) target.scrollIntoView();
      }
    } else {
      window.scrollTo(scrollX, scrollY);
    }
  }

  function setStatus(state, text, tip) {
    $fab.dataset.status = state; // colors the connection dot on the button and in the menu
    $statusText.textContent = text;
    $status.title = tip || '';
  }

  // --- Floating menu ---------------------------------------------------------
  // A Next.js-devtools-style round button opens a small panel: connection
  // status, follow toggle (live previews only), theme, full width, go to top.
  // Drag it to park it in any corner; the corner persists per browser.

  function toggleMenu(open) {
    const show = open ?? $fabMenu.hidden;
    $fabMenu.hidden = !show;
    $fabToggle.setAttribute('aria-expanded', String(show));
  }
  document.addEventListener('click', (ev) => {
    if (!$fabMenu.hidden && !$fab.contains(ev.target)) toggleMenu(false);
  });
  document.addEventListener('keydown', (ev) => {
    if (ev.key === 'Escape') toggleMenu(false);
  });

  const FAB_MARGIN = 20; // distance from the viewport edges, all corners
  const stored = localStorage.getItem('mdpv-fab-corner');
  if (/^[tb][lr]$/.test(stored)) $fab.dataset.corner = stored;

  let drag = null; // {x, y, dx, dy, moved} while the pointer is down
  let dragged = false; // the click that ends a drag must not open the menu
  $fabToggle.addEventListener('pointerdown', (ev) => {
    if (ev.button !== 0) return;
    dragged = false; // pointercancel ends a drag without a click; don't go stale
    const r = $fab.getBoundingClientRect();
    drag = { x: ev.clientX, y: ev.clientY, dx: ev.clientX - r.left, dy: ev.clientY - r.top, moved: false };
    $fabToggle.setPointerCapture(ev.pointerId);
  });
  $fabToggle.addEventListener('pointermove', (ev) => {
    if (!drag) return;
    if (!drag.moved) {
      if (Math.hypot(ev.clientX - drag.x, ev.clientY - drag.y) < 5) return; // still a click
      drag.moved = true;
      toggleMenu(false);
      $fab.classList.add('dragging');
    }
    const w = $fab.offsetWidth;
    const h = $fab.offsetHeight;
    $fab.style.left = `${Math.max(0, Math.min(ev.clientX - drag.dx, window.innerWidth - w))}px`;
    $fab.style.top = `${Math.max(0, Math.min(ev.clientY - drag.dy, window.innerHeight - h))}px`;
    $fab.style.right = 'auto';
    $fab.style.bottom = 'auto';
  });
  const endDrag = (ev) => {
    if (!drag) return;
    dragged = drag.moved;
    drag = null;
    $fab.classList.remove('dragging');
    if (!dragged) return;
    // Snap to the nearest corner, glide there, then hand anchoring back to CSS.
    const corner = (ev.clientY < window.innerHeight / 2 ? 't' : 'b')
      + (ev.clientX < window.innerWidth / 2 ? 'l' : 'r');
    localStorage.setItem('mdpv-fab-corner', corner);
    $fab.classList.add('snapping');
    $fab.style.left = `${corner[1] === 'l' ? FAB_MARGIN : window.innerWidth - $fab.offsetWidth - FAB_MARGIN}px`;
    $fab.style.top = `${corner[0] === 't' ? FAB_MARGIN : window.innerHeight - $fab.offsetHeight - FAB_MARGIN}px`;
    setTimeout(() => {
      $fab.classList.remove('snapping');
      $fab.style.cssText = '';
      $fab.dataset.corner = corner;
    }, 160);
  };
  $fabToggle.addEventListener('pointerup', endDrag);
  $fabToggle.addEventListener('pointercancel', endDrag);
  $fabToggle.addEventListener('click', () => {
    if (dragged) {
      dragged = false;
      return;
    }
    toggleMenu();
  });

  // Theme: the server renders the configured theme; the toggle cycles
  // auto -> light -> dark per browser (persisted in localStorage), swapping
  // in the same stylesheet pair the server would have injected.
  const THEME_CSS = {
    auto: ['github-markdown.css', 'hljs-github-auto.css'],
    light: ['github-markdown-light.css', 'github.min.css'],
    dark: ['github-markdown-dark.css', 'github-dark.min.css'],
  };
  const THEMES = Object.keys(THEME_CSS);

  function applyTheme(theme) {
    document.documentElement.dataset.theme = theme;
    document.querySelector('meta[name="color-scheme"]').content = theme === 'auto' ? 'light dark' : theme;
    document.getElementById('mdpv-css-md').href = `/assets/vendor/${THEME_CSS[theme][0]}?v=${V}`;
    document.getElementById('mdpv-css-hljs').href = `/assets/vendor/${THEME_CSS[theme][1]}?v=${V}`;
    document.getElementById('theme-value').textContent = theme;
    rethemeMermaid();
  }

  const storedTheme = localStorage.getItem('mdpv-theme');
  if (THEME_CSS[storedTheme] && storedTheme !== document.documentElement.dataset.theme) {
    applyTheme(storedTheme);
  }
  document.getElementById('theme-toggle').addEventListener('click', () => {
    const cur = document.documentElement.dataset.theme;
    const next = THEMES[(THEMES.indexOf(cur) + 1) % THEMES.length];
    localStorage.setItem('mdpv-theme', next);
    applyTheme(next);
  });

  // Full width: drop the GitHub-like 1012px cap on the content column.
  const $width = document.getElementById('width-toggle');
  let wide = localStorage.getItem('mdpv-wide') === '1';

  function paintWide() {
    document.body.classList.toggle('mdpv-wide', wide);
    $width.setAttribute('aria-pressed', String(wide));
  }
  paintWide();
  $width.addEventListener('click', () => {
    wide = !wide;
    localStorage.setItem('mdpv-wide', wide ? '1' : '0');
    paintWide();
  });

  // Shared with scroll sync below: self-inflicted smooth scrolls are ignored
  // (and never POSTed back to the editor) until this timestamp.
  let progUntil = 0;

  document.getElementById('top-button').addEventListener('click', () => {
    progUntil = performance.now() + 1200;
    window.scrollTo({ top: 0, behavior: 'smooth' });
    toggleMenu(false);
  });

  // First paint from the embedded boot payload — no SSE round-trip needed.
  if (typeof BOOT.md === 'string') render(BOOT.md);

  // A .md file rendered through the /f/ route has no buffer behind it:
  // nothing to stream, nothing to follow.
  if (BOOT.static) {
    setStatus('static', 'static file', 'Rendered from disk — not a live buffer');
    return;
  }

  // --- Scroll sync -----------------------------------------------------------
  // Editor -> browser: the server streams the cursor line; block elements
  // carry data-source-line, and interpolating between the surrounding two
  // mapped elements keeps long paragraphs/code blocks tracking smoothly.
  // Browser -> editor (scroll_sync = 'both'): user scrolls POST the line
  // under the viewport anchor back, moving the cursor. Echo control: our own
  // smooth scrolls are ignored for a beat (progUntil), and the editor skips
  // re-broadcasting a cursor line it just applied.

  const SYNC = FEATURES.scrollSync; // false | true | 'both'
  const ANCHOR = 0.35; // aim sync at the upper third — where your eyes are
  let follow = localStorage.getItem('mdpv-follow') !== '0';
  let lastSentLine = 0;

  function paintFollow() {
    $follow.setAttribute('aria-pressed', String(follow)); // drives the menu switch
  }
  if (SYNC) {
    $follow.hidden = false;
    paintFollow();
    $follow.addEventListener('click', () => {
      follow = !follow;
      localStorage.setItem('mdpv-follow', follow ? '1' : '0');
      paintFollow();
    });
  }

  function scrollToLine(line) {
    progUntil = performance.now() + 1200; // smooth scroll settles well within this
    let prev = null;
    let next = null;
    for (const el of $content.querySelectorAll('[data-source-line]')) {
      if (+el.dataset.sourceLine <= line) prev = el;
      else { next = el; break; }
    }
    if (!prev) {
      window.scrollTo({ top: 0, behavior: 'smooth' });
      return;
    }
    let y = prev.getBoundingClientRect().top + window.scrollY;
    if (next) {
      const prevLine = +prev.dataset.sourceLine;
      const span = +next.dataset.sourceLine - prevLine;
      if (span > 0) {
        y += (next.getBoundingClientRect().top - prev.getBoundingClientRect().top)
          * ((line - prevLine) / span);
      }
    }
    window.scrollTo({ top: Math.max(0, y - window.innerHeight * ANCHOR), behavior: 'smooth' });
  }

  // Inverse of scrollToLine: which source line sits at the viewport anchor?
  function lineAtAnchor() {
    const anchor = window.scrollY + window.innerHeight * ANCHOR;
    let prev = null;
    let next = null;
    for (const el of $content.querySelectorAll('[data-source-line]')) {
      if (el.getBoundingClientRect().top + window.scrollY <= anchor) prev = el;
      else { next = el; break; }
    }
    if (!prev) return 1;
    const prevLine = +prev.dataset.sourceLine;
    if (!next) return prevLine;
    const a = prev.getBoundingClientRect().top + window.scrollY;
    const b = next.getBoundingClientRect().top + window.scrollY;
    const span = +next.dataset.sourceLine - prevLine;
    if (b <= a || span <= 0) return prevLine;
    return Math.max(1, Math.round(prevLine + span * ((anchor - a) / (b - a))));
  }

  if (SYNC === 'both') {
    let sendTimer = 0;
    window.addEventListener('scroll', () => {
      if (!follow || performance.now() < progUntil) return;
      clearTimeout(sendTimer);
      sendTimer = setTimeout(() => {
        if (performance.now() < progUntil) return;
        const line = lineAtAnchor();
        if (!line || line === lastSentLine) return;
        lastSentLine = line;
        fetch(`/sync/${BOOT.token}`, { method: 'POST', body: JSON.stringify({ line }) })
          .catch(() => {});
      }, 150);
    }, { passive: true });
  }

  // --- SSE wiring ----------------------------------------------------------

  let docTitle = BOOT.title;
  const es = new EventSource(`/events/${BOOT.token}`);

  es.addEventListener('update', (ev) => {
    let payload;
    try {
      payload = JSON.parse(ev.data);
    } catch (_) {
      return;
    }
    if (payload.title && payload.title !== docTitle) {
      docTitle = payload.title;
      document.title = `${docTitle} · mdpv`;
    }
    setStatus('live', 'live', 'Connected — updates live as you edit');
    render(typeof payload.md === 'string' ? payload.md : '');
  });

  es.addEventListener('scroll', (ev) => {
    if (!follow || !SYNC) return;
    let payload;
    try {
      payload = JSON.parse(ev.data);
    } catch (_) {
      return;
    }
    if (typeof payload.line === 'number') {
      lastSentLine = payload.line; // don't POST straight back what we just applied
      scrollToLine(payload.line);
    }
  });

  es.addEventListener('close', () => {
    es.close();
    setStatus('ended', 'preview closed', 'The preview was closed in Neovim');
  });

  es.onerror = () => {
    if (es.readyState !== EventSource.CLOSED) {
      setStatus('reconnecting', 'reconnecting…', 'Lost connection to Neovim, retrying');
    }
  };
})();
