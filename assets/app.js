// mdpv client: receives raw markdown over SSE, renders it GitHub-style.
//
// Pipeline: markdown-it (CommonMark + GFM plugins) -> DOMPurify -> DOM
// post-processing that reshapes the output into the exact markup GitHub emits
// (alerts/callouts, heading anchors, footnotes), so github-markdown-css
// styles it 1:1.
(() => {
  'use strict';

  // {token, title, md, features, static?, base?} — embedded server-side for
  // an instant first paint.
  const BOOT = JSON.parse(document.getElementById('mdpv-boot').textContent);
  const FEATURES = BOOT.features || {};
  // math is false | true | {macros: …} — KaTeX options configured editor-side.
  const MATH_OPTS = (typeof FEATURES.math === 'object' && FEATURES.math) || {};
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
  const $syncBack = document.getElementById('syncback-toggle');
  const $toc = document.getElementById('mdpv-toc');

  // Primer octicons: GitHub's own glyphs for its five alerts, plus stand-ins
  // for the icons of Obsidian's remaining callout types.
  const svg = (cls, ...paths) =>
    `<svg class="octicon ${cls}" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">${paths
      .map((d) => `<path fill="currentColor" d="${d}"></path>`)
      .join('')}</svg>`;
  const OCTICON = {
    link: svg('octicon-link', 'm7.775 3.275 1.25-1.25a3.5 3.5 0 1 1 4.95 4.95l-2.5 2.5a3.5 3.5 0 0 1-4.95 0 .751.751 0 0 1 .018-1.042.751.751 0 0 1 1.042-.018 1.998 1.998 0 0 0 2.83 0l2.5-2.5a2.002 2.002 0 0 0-2.83-2.83l-1.25 1.25a.751.751 0 0 1-1.042-.018.751.751 0 0 1-.018-1.042Zm-4.69 9.64a1.998 1.998 0 0 0 2.83 0l1.25-1.25a.751.751 0 0 1 1.042.018.751.751 0 0 1 .018 1.042l-1.25 1.25a3.5 3.5 0 1 1-4.95-4.95l2.5-2.5a3.5 3.5 0 0 1 4.95 0 .751.751 0 0 1-.018 1.042.751.751 0 0 1-1.042.018 1.998 1.998 0 0 0-2.83 0l-2.5 2.5a1.998 1.998 0 0 0 0 2.83Z'),
    info: svg('octicon-info mr-2', 'M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z'),
    lightBulb: svg('octicon-light-bulb mr-2', 'M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z'),
    report: svg('octicon-report mr-2', 'M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z'),
    alert: svg('octicon-alert mr-2', 'M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z'),
    stop: svg('octicon-stop mr-2', 'M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z'),
    note: svg('octicon-note mr-2', 'M0 3.75C0 2.784.784 2 1.75 2h12.5c.966 0 1.75.784 1.75 1.75v8.5A1.75 1.75 0 0 1 14.25 14H1.75A1.75 1.75 0 0 1 0 12.25Zm1.75-.25a.25.25 0 0 0-.25.25v8.5c0 .138.112.25.25.25h12.5a.25.25 0 0 0 .25-.25v-8.5a.25.25 0 0 0-.25-.25ZM3.5 6.25a.75.75 0 0 1 .75-.75h7a.75.75 0 0 1 0 1.5h-7a.75.75 0 0 1-.75-.75Zm.75 2.25h4a.75.75 0 0 1 0 1.5h-4a.75.75 0 0 1 0-1.5Z'),
    checklist: svg('octicon-checklist mr-2', 'M2.5 1.75v11.5c0 .138.112.25.25.25h3.17a.75.75 0 0 1 0 1.5H2.75A1.75 1.75 0 0 1 1 13.25V1.75C1 .784 1.784 0 2.75 0h8.5C12.216 0 13 .784 13 1.75v7.736a.75.75 0 0 1-1.5 0V1.75a.25.25 0 0 0-.25-.25h-8.5a.25.25 0 0 0-.25.25Zm13.274 9.537v-.001l-4.557 4.45a.75.75 0 0 1-1.055-.008l-1.943-1.95a.75.75 0 0 1 1.062-1.058l1.419 1.425 4.026-3.932a.75.75 0 1 1 1.048 1.074ZM4.75 4h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM4 7.75A.75.75 0 0 1 4.75 7h2a.75.75 0 0 1 0 1.5h-2A.75.75 0 0 1 4 7.75Z'),
    checkCircle: svg('octicon-check-circle mr-2', 'M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm1.5 0a6.5 6.5 0 1 0 13 0 6.5 6.5 0 0 0-13 0Zm10.28-1.72-4.5 4.5a.75.75 0 0 1-1.06 0l-2-2a.751.751 0 0 1 .018-1.042.751.751 0 0 1 1.042-.018l1.47 1.47 3.97-3.97a.751.751 0 0 1 1.042.018.751.751 0 0 1 .018 1.042Z'),
    question: svg('octicon-question mr-2', 'M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.92 6.085h.001a.749.749 0 1 1-1.342-.67c.169-.339.436-.701.849-.977C6.845 4.16 7.369 4 8 4a2.756 2.756 0 0 1 1.637.525c.503.377.863.965.863 1.725 0 .448-.115.83-.329 1.15-.205.307-.47.513-.692.662-.109.072-.22.138-.313.195l-.006.004a6.24 6.24 0 0 0-.26.16.952.952 0 0 0-.276.245.75.75 0 0 1-1.248-.832c.184-.264.42-.489.692-.661.103-.067.207-.132.313-.195l.007-.004c.1-.061.182-.11.258-.161a.969.969 0 0 0 .277-.245C8.96 6.514 9 6.427 9 6.25a.612.612 0 0 0-.262-.525A1.27 1.27 0 0 0 8 5.5c-.369 0-.595.09-.74.187a1.01 1.01 0 0 0-.34.398ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z'),
    xCircle: svg('octicon-x-circle mr-2', 'M2.344 2.343h-.001a8 8 0 0 1 11.314 11.314A8.002 8.002 0 0 1 .234 10.089a8 8 0 0 1 2.11-7.746Zm1.06 10.253a6.5 6.5 0 1 0 9.108-9.275 6.5 6.5 0 0 0-9.108 9.275ZM6.03 4.97 8 6.94l1.97-1.97a.749.749 0 0 1 1.275.326.749.749 0 0 1-.215.734L9.06 8l1.97 1.97a.749.749 0 0 1-.326 1.275.749.749 0 0 1-.734-.215L8 9.06l-1.97 1.97a.749.749 0 0 1-1.275-.326.749.749 0 0 1 .215-.734L6.94 8 4.97 6.03a.751.751 0 0 1 .018-1.042.751.751 0 0 1 1.042-.018Z'),
    zap: svg('octicon-zap mr-2', 'M9.504.43a1.516 1.516 0 0 1 2.437 1.713L10.415 5.5h2.123c1.57 0 2.346 1.909 1.22 3.004l-7.34 7.142a1.249 1.249 0 0 1-.871.354h-.302a1.25 1.25 0 0 1-1.157-1.723L5.633 10.5H3.462c-1.57 0-2.346-1.909-1.22-3.004L9.503.429Zm1.047 1.074L3.286 8.571A.25.25 0 0 0 3.462 9H6.75a.75.75 0 0 1 .694 1.034l-1.713 4.188 6.982-6.793A.25.25 0 0 0 12.538 7H9.25a.75.75 0 0 1-.683-1.06l2.008-4.418.003-.006a.036.036 0 0 0-.004-.009l-.006-.006-.008-.001c-.003 0-.006.002-.009.004Z'),
    bug: svg('octicon-bug mr-2', 'M4.72.22a.75.75 0 0 1 1.06 0l1 .999a3.488 3.488 0 0 1 2.441 0l.999-1a.748.748 0 0 1 1.265.332.75.75 0 0 1-.205.729l-.775.776c.616.63.995 1.493.995 2.444v.327c0 .1-.009.197-.025.292.408.14.764.392 1.029.722l1.968-.787a.75.75 0 0 1 .556 1.392L13 7.258V9h2.25a.75.75 0 0 1 0 1.5H13v.5c0 .409-.049.806-.141 1.186l2.17.868a.75.75 0 0 1-.557 1.392l-2.184-.873A4.997 4.997 0 0 1 8 16a4.997 4.997 0 0 1-4.288-2.427l-2.183.873a.75.75 0 0 1-.558-1.392l2.17-.868A5.036 5.036 0 0 1 3 11v-.5H.75a.75.75 0 0 1 0-1.5H3V7.258L.971 6.446a.75.75 0 0 1 .558-1.392l1.967.787c.265-.33.62-.583 1.03-.722a1.677 1.677 0 0 1-.026-.292V4.5c0-.951.38-1.814.995-2.444L4.72 1.28a.75.75 0 0 1 0-1.06Zm.53 6.28a.75.75 0 0 0-.75.75V11a3.5 3.5 0 1 0 7 0V7.25a.75.75 0 0 0-.75-.75ZM6.173 5h3.654A.172.172 0 0 0 10 4.827V4.5a2 2 0 1 0-4 0v.327c0 .096.077.173.173.173Z'),
    listUnordered: svg('octicon-list-unordered mr-2', 'M5.75 2.5h8.5a.75.75 0 0 1 0 1.5h-8.5a.75.75 0 0 1 0-1.5Zm0 5h8.5a.75.75 0 0 1 0 1.5h-8.5a.75.75 0 0 1 0-1.5Zm0 5h8.5a.75.75 0 0 1 0 1.5h-8.5a.75.75 0 0 1 0-1.5ZM2 14a1 1 0 1 1 0-2 1 1 0 0 1 0 2Zm1-6a1 1 0 1 1-2 0 1 1 0 0 1 2 0ZM2 4a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z'),
    quote: svg('octicon-quote mr-2', 'M1.75 2.5h10.5a.75.75 0 0 1 0 1.5H1.75a.75.75 0 0 1 0-1.5Zm4 5h8.5a.75.75 0 0 1 0 1.5h-8.5a.75.75 0 0 1 0-1.5Zm0 5h8.5a.75.75 0 0 1 0 1.5h-8.5a.75.75 0 0 1 0-1.5ZM2.5 7.75v6a.75.75 0 0 1-1.5 0v-6a.75.75 0 0 1 1.5 0Z'),
    chevronDown: svg('octicon-chevron-down mdpv-fold', 'M12.78 5.22a.749.749 0 0 1 0 1.06l-4.25 4.25a.749.749 0 0 1-1.06 0L3.22 6.28a.749.749 0 1 1 1.06-1.06L8 8.939l3.72-3.719a.749.749 0 0 1 1.06 0Z'),
    copy: svg('octicon-copy', 'M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75 0 0 1 0 1.5h-1.5a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .25-.25v-1.5a.75.75 0 0 1 1.5 0v1.5A1.75 1.75 0 0 1 9.25 16h-7.5A1.75 1.75 0 0 1 0 14.25Z', 'M5 1.75C5 .784 5.784 0 6.75 0h7.5C15.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0 1 14.25 11h-7.5A1.75 1.75 0 0 1 5 9.25Zm1.75-.25a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .25-.25v-7.5a.25.25 0 0 0-.25-.25Z'),
    check: svg('octicon-check', 'M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.751.751 0 0 1 .018-1.042.751.751 0 0 1 1.042-.018L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0Z'),
    plus: svg('octicon-plus', 'M7.75 2a.75.75 0 0 1 .75.75V7h4.25a.75.75 0 0 1 0 1.5H8.5v4.25a.75.75 0 0 1-1.5 0V8.5H2.75a.75.75 0 0 1 0-1.5H7V2.75A.75.75 0 0 1 7.75 2Z'),
    dash: svg('octicon-dash', 'M2 7.75A.75.75 0 0 1 2.75 7h10a.75.75 0 0 1 0 1.5h-10A.75.75 0 0 1 2 7.75Z'),
    sync: svg('octicon-sync', 'M1.705 8.005a.75.75 0 0 1 .834.656 5.5 5.5 0 0 0 9.592 2.97l-1.204-1.204a.25.25 0 0 1 .177-.427h3.646a.25.25 0 0 1 .25.25v3.646a.25.25 0 0 1-.427.177l-1.38-1.38A7.002 7.002 0 0 1 1.05 8.84a.75.75 0 0 1 .656-.834ZM8 2.5a5.487 5.487 0 0 0-4.131 1.869l1.204 1.204A.25.25 0 0 1 4.896 6H1.25A.25.25 0 0 1 1 5.75V2.104a.25.25 0 0 1 .427-.177l1.38 1.38A7.002 7.002 0 0 1 14.95 7.16a.75.75 0 0 1-1.49.178A5.5 5.5 0 0 0 8 2.5Z'),
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

  // No highlight() hook: fenced code renders escaped with a language-x class
  // and highlightCode() rewrites it in place once highlight.js lazy-loads.
  // Obsidian wikilinks: [[Page]], [[Page|alias]], [[Page#Heading]], and
  // ![[img.png]] image embeds. A page without a known file extension resolves
  // to <page>.md, so vault-style links render through the /f/ route like any
  // relative link; heading fragments slug the same way heading anchors do.
  // GitHub renders [[…]] literally outside wikis, hence the feature flag.
  const WIKI_EXT_RE = /\.(md|markdown|png|jpe?g|gif|svg|webp|avif|bmp|ico|pdf|txt|mp[34]|webm|ogg|wav|mov)$/i;
  const WIKI_IMG_RE = /\.(png|jpe?g|gif|svg|webp|avif|bmp|ico)$/i;
  function wikilinkPlugin(mdi) {
    const slugify = (text) =>
      text
        .trim()
        .toLowerCase()
        .replace(/[^\p{L}\p{N}\p{Emoji_Presentation} _-]/gu, '')
        .replace(/ /g, '-');
    function wikilink(state, silent) {
      const src = state.src;
      let pos = state.pos;
      const embed = src.charCodeAt(pos) === 0x21; /* ! */
      if (embed) pos += 1;
      if (src.charCodeAt(pos) !== 0x5b || src.charCodeAt(pos + 1) !== 0x5b /* [[ */) return false;
      const close = src.indexOf(']]', pos + 2);
      if (close === -1) return false;
      const inner = src.slice(pos + 2, close);
      if (!inner.trim() || /[[\]\n]/.test(inner)) return false;
      const bar = inner.indexOf('|');
      const target = (bar === -1 ? inner : inner.slice(0, bar)).trim();
      const alias = bar === -1 ? '' : inner.slice(bar + 1).trim();
      const hashAt = target.indexOf('#');
      const page = (hashAt === -1 ? target : target.slice(0, hashAt)).trim();
      const heading = hashAt === -1 ? '' : target.slice(hashAt + 1).trim();
      if (!page && !heading) return false;
      if (!silent) {
        const hash = heading ? `#${slugify(heading)}` : '';
        const href = page ? encodeURI(WIKI_EXT_RE.test(page) ? page : `${page}.md`) + hash : hash;
        if (embed && page && WIKI_IMG_RE.test(page)) {
          const img = state.push('image', 'img', 0);
          img.attrs = [['src', href], ['alt', '']];
          const alt = new state.Token('text', '', 0);
          alt.content = alias || page;
          img.children = [alt];
        } else {
          // Non-image embeds degrade to a plain link (no transclusion).
          const open = state.push('link_open', 'a', 1);
          open.attrs = [['href', href]];
          open.markup = 'wikilink';
          const text = state.push('text', '', 0);
          text.content = alias || target;
          state.push('link_close', 'a', -1);
        }
      }
      state.pos = close + 2;
      return true;
    }
    mdi.inline.ruler.before('link', 'wikilink', wikilink);
  }

  const md = window
    .markdownit({
      html: true, // raw HTML passes through, DOMPurify sanitizes after
      linkify: true, // GFM autolinks bare URLs
      typographer: false, // GitHub does not smart-quote
    })
    // GitHub's task-list-item classes; live previews render the checkboxes
    // enabled so a click can toggle the source line (see the change listener).
    .use(window.markdownitTaskLists, { enabled: !BOOT.static })
    .use(window.markdownitFootnote);
  if (FEATURES.emoji !== false && window.markdownitEmoji) md.use(window.markdownitEmoji);
  if (FEATURES.math !== false) md.use(mathPlugin);
  if (FEATURES.wikilinks !== false) md.use(wikilinkPlugin);

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
  // A bare GitHub alert type renders exactly as GitHub does; the rest of
  // Obsidian's callout vocabulary (obsidian.md/help/callouts) rides on the
  // same markup, as do Obsidian's extras on every type: a custom title after
  // the marker, [!type]- / [!type]+ folding into <details>, and nesting.
  const CALLOUT_ICON = {
    note: 'info',
    tip: 'lightBulb',
    important: 'report',
    warning: 'alert',
    caution: 'stop',
    abstract: 'note',
    info: 'info',
    todo: 'checklist',
    success: 'checkCircle',
    question: 'question',
    failure: 'xCircle',
    danger: 'zap',
    bug: 'bug',
    example: 'listUnordered',
    quote: 'quote',
  };
  // Obsidian's aliases. Where the vocabularies collide, GitHub wins:
  // important and caution are alert kinds above, not tip/warning aliases.
  const CALLOUT_ALIAS = {
    summary: 'abstract',
    tldr: 'abstract',
    hint: 'tip',
    check: 'success',
    done: 'success',
    help: 'question',
    faq: 'question',
    attention: 'warning',
    fail: 'failure',
    missing: 'failure',
    error: 'danger',
    cite: 'quote',
  };
  const CALLOUT_RE = /^\[!([A-Za-z]+)\]([-+]?)(?:[ \t]+|(?=\r?\n|$))/;

  // Detach the rest of the marker line — the custom title, which may hold
  // inline markup — and return it. The line ends at a softbreak "\n" inside
  // a text node (markdown-it default) or at a <br>.
  function detachTitleLine(p) {
    const frag = document.createDocumentFragment();
    while (p.firstChild) {
      const node = p.firstChild;
      if (node.nodeType === Node.TEXT_NODE) {
        const cut = node.nodeValue.search(/\r?\n/);
        if (cut !== -1) {
          frag.appendChild(document.createTextNode(node.nodeValue.slice(0, cut)));
          node.nodeValue = node.nodeValue.slice(cut).replace(/^\r?\n/, '');
          break;
        }
      } else if (node.nodeType === Node.ELEMENT_NODE && node.tagName === 'BR') {
        node.remove();
        break;
      }
      frag.appendChild(node);
    }
    return frag;
  }

  function transformCallouts(root) {
    for (const bq of root.querySelectorAll('blockquote')) {
      const first = bq.firstElementChild;
      if (!first || first.tagName !== 'P') continue;
      const textNode = first.firstChild;
      if (!textNode || textNode.nodeType !== Node.TEXT_NODE) continue;
      const m = CALLOUT_RE.exec(textNode.nodeValue);
      if (!m) continue;
      const raw = m[1].toLowerCase();
      const kind = CALLOUT_ICON[raw] ? raw : CALLOUT_ALIAS[raw];
      if (!kind) continue; // unknown type: stays a blockquote, like on GitHub

      textNode.nodeValue = textNode.nodeValue.slice(m[0].length);
      const custom = detachTitleLine(first);
      if (!first.textContent.trim() && first.children.length === 0) first.remove();

      const fold = m[2];
      const box = document.createElement(fold ? 'details' : 'div');
      box.className = `markdown-alert markdown-alert-${kind}`;
      const line = bq.getAttribute('data-source-line');
      if (line) box.setAttribute('data-source-line', line);
      if (fold === '+') box.open = true;

      const title = document.createElement(fold ? 'summary' : 'p');
      title.className = 'markdown-alert-title';
      title.innerHTML = OCTICON[CALLOUT_ICON[kind]];
      if (custom.textContent.trim()) {
        // One <span> flex item, so the flex title doesn't swallow the
        // whitespace between the title's own inline elements.
        const span = document.createElement('span');
        span.appendChild(custom);
        title.appendChild(span);
      } else {
        title.appendChild(document.createTextNode(m[1].charAt(0).toUpperCase() + m[1].slice(1).toLowerCase()));
      }
      if (fold) title.insertAdjacentHTML('beforeend', OCTICON.chevronDown);

      box.appendChild(title);
      while (bq.firstChild) box.appendChild(bq.firstChild);
      bq.replaceWith(box);
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

  // A hover copy button on every code block, like GitHub's. Runs on the
  // detached copy before the diff, so both sides carry the same wrapper and
  // the button survives morphdom untouched. (Math/mermaid fences are already
  // swapped for placeholder divs by the time this runs.)
  function addCopyButtons(root) {
    for (const pre of root.querySelectorAll('pre')) {
      if (!pre.querySelector(':scope > code')) continue;
      const wrap = document.createElement('div');
      wrap.className = 'mdpv-pre';
      pre.replaceWith(wrap);
      wrap.appendChild(pre);
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'mdpv-copy';
      btn.title = 'Copy';
      btn.setAttribute('aria-label', 'Copy code');
      btn.innerHTML = OCTICON.copy;
      wrap.appendChild(btn);
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

  // highlight.js is ~130 KB and plenty of documents carry no fenced code, so
  // it lazy-loads the same way. Unknown languages keep markdown-it's escaped
  // output, exactly as the old synchronous path did.
  let hljsReady = null;
  const ensureHljs = () => (hljsReady ??= loadAsset('script', { src: `/assets/vendor/highlight.min.js?v=${V}` }));

  function highlightCode(root, gen) {
    const nodes = root.querySelectorAll('pre > code[class*="language-"]:not(.mdpv-hl)');
    if (nodes.length === 0) return;
    ensureHljs().then(() => {
      if (gen !== generation) return;
      for (const code of nodes) {
        code.classList.add('mdpv-hl'); // processed, even when the language is unknown
        const lang = ((code.className.match(/language-(\S+)/) || [])[1] || '').toLowerCase();
        if (!lang || !window.hljs.getLanguage(lang)) continue;
        try {
          code.innerHTML = window.hljs.highlight(code.textContent, { language: lang, ignoreIllegals: true }).value;
        } catch (_) { /* leave the escaped source */ }
      }
    }, () => {});
  }

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
            // KaTeX writes \gdef definitions into the macros object it's
            // handed; a fresh copy per block keeps them order-independent.
            macros: MATH_OPTS.macros ? { ...MATH_OPTS.macros } : undefined,
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

  // Pan/zoom on rendered diagrams: hover controls (+ / − / reset), drag to
  // pan while zoomed, double-click to reset. The transform lives on the
  // <svg>; morphdom keeps the typeset node (keyed by source), so the view
  // survives edits elsewhere and resets naturally when the diagram changes.
  function addDiagramControls(div) {
    const svgEl = div.querySelector('svg');
    if (!svgEl) return;
    const view = { x: 0, y: 0, k: 1 };
    const apply = () => {
      const idle = view.k === 1 && view.x === 0 && view.y === 0;
      svgEl.style.transform = idle ? '' : `translate(${view.x}px, ${view.y}px) scale(${view.k})`;
      div.classList.toggle('mdpv-zoomed', !idle);
    };
    const zoom = (f) => {
      view.k = Math.min(8, Math.max(0.25, view.k * f));
      apply();
    };
    const reset = () => {
      view.x = 0;
      view.y = 0;
      view.k = 1;
      apply();
    };
    const controls = document.createElement('div');
    controls.className = 'mdpv-diagram-controls';
    for (const [icon, title, fn] of [
      [OCTICON.plus, 'Zoom in', () => zoom(1.25)],
      [OCTICON.dash, 'Zoom out', () => zoom(0.8)],
      [OCTICON.sync, 'Reset view', reset],
    ]) {
      const b = document.createElement('button');
      b.type = 'button';
      b.title = title;
      b.innerHTML = icon;
      b.addEventListener('click', fn);
      controls.appendChild(b);
    }
    div.appendChild(controls);
    let pan = null;
    svgEl.addEventListener('pointerdown', (ev) => {
      if (view.k === 1 || ev.button !== 0) return;
      pan = { x: ev.clientX - view.x, y: ev.clientY - view.y };
      svgEl.setPointerCapture(ev.pointerId);
      ev.preventDefault(); // no text selection while panning
    });
    svgEl.addEventListener('pointermove', (ev) => {
      if (!pan) return;
      view.x = ev.clientX - pan.x;
      view.y = ev.clientY - pan.y;
      apply();
    });
    const endPan = () => {
      pan = null;
    };
    svgEl.addEventListener('pointerup', endPan);
    svgEl.addEventListener('pointercancel', endPan);
    div.addEventListener('dblclick', reset);
  }

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
          addDiagramControls(div);
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

  // Where scroll sync and the outline spy aim in the viewport: the upper
  // third, which is where your eyes are.
  const ANCHOR = 0.35;

  // Scroll-sync anchors, cached per render. They sit in document order with
  // non-decreasing source lines and offsets, so both lookups binary-search
  // instead of walking (and measuring) every mapped block per event.
  let syncEls = [];
  const refreshSyncEls = () => {
    syncEls = [...$content.querySelectorAll('[data-source-line]')];
  };

  // Cursor-block indicator: the block under the editor cursor carries a
  // marker class while follow is on (set from the SSE scroll handler);
  // re-applied per render because the diff wipes it.
  let cursorLine = 0;
  let cursorEl = null;

  function paintCursorBlock() {
    let el = null;
    if (cursorLine > 0) {
      const i = bisect(syncEls, cursorLine, (n) => +n.dataset.sourceLine);
      el = i === -1 ? null : syncEls[i];
      // Fenced code carries the line map on <code>; mark the block instead.
      if (el && el.tagName === 'CODE' && el.parentElement?.tagName === 'PRE') el = el.parentElement;
    }
    if (cursorEl && cursorEl !== el) cursorEl.classList.remove('mdpv-cursor');
    cursorEl = el;
    if (el) el.classList.add('mdpv-cursor');
  }

  // Rightmost index in els whose measure(el) <= limit, or -1.
  function bisect(els, limit, measure) {
    let lo = 0;
    let hi = els.length - 1;
    let found = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (measure(els[mid]) <= limit) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }

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
    transformCallouts(next);
    addHeadingAnchors(next);
    polishFootnotes(next);
    rewriteRelativeUrls(next);
    normalizeTypeset(next);
    addCopyButtons(next);

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
          if (
            from.tagName === 'CODE'
            && from.classList.contains('mdpv-hl')
            && from.textContent === to.textContent
            && from.getAttribute('class').replace(/\s*\bmdpv-hl\b/, '') === (to.getAttribute('class') || '')
          ) {
            // Unchanged code block: keep the highlighted DOM, refresh its line.
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
    refreshSyncEls();
    rebuildOutline();
    paintCursorBlock();

    highlightCode($content, gen);
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
  // A Next.js-devtools-style round button opens a small grouped panel: sync
  // toggles (live previews only), outline, full width, theme, go to top.
  // Drag it to park it in any corner; the corner persists per browser. The
  // outline panel (#mdpv-toc) floats and corner-parks the same way.

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
  // When the outline panel and the button rest in the same corner, the panel
  // yields: it anchors past the button (button + gap) instead of at the edge
  // margin, so the two never overlap. CSS mirrors this via .mdpv-evade.
  const TOC_EVADE = 72;

  function updateEvade() {
    $toc.classList.toggle('mdpv-evade', $toc.dataset.corner === $fab.dataset.corner);
  }

  // Corner-parking drag, shared by the button and the outline panel: under
  // 5px of pointer travel stays a click; past it the element follows the
  // pointer, then snaps (and glides) to the nearest corner, which persists.
  function cornerDrag(el, handle, storageKey, opts = {}) {
    const stored = localStorage.getItem(storageKey);
    if (/^[tb][lr]$/.test(stored)) el.dataset.corner = stored;
    let drag = null; // {id, x, y, dx, dy, moved} while the pointer is down
    let dragged = false; // the click that ends a drag must not act as one
    handle.addEventListener('pointerdown', (ev) => {
      if (ev.button !== 0) return;
      dragged = false; // pointercancel ends a drag without a click; don't go stale
      const r = el.getBoundingClientRect();
      drag = { id: ev.pointerId, x: ev.clientX, y: ev.clientY, dx: ev.clientX - r.left, dy: ev.clientY - r.top, moved: false };
    });
    // Move/up listen on window, with no pointer capture: capture would
    // retarget the tail click away from the element under the pointer (the
    // outline's links), and handle-scoped moves lose fast drags that leave
    // the handle between two events.
    window.addEventListener('pointermove', (ev) => {
      if (!drag || ev.pointerId !== drag.id) return;
      if (!drag.moved) {
        if (Math.hypot(ev.clientX - drag.x, ev.clientY - drag.y) < 5) return; // still a click
        drag.moved = true;
        el.classList.add('dragging');
        if (opts.onDragStart) opts.onDragStart();
      }
      el.style.left = `${Math.max(0, Math.min(ev.clientX - drag.dx, window.innerWidth - el.offsetWidth))}px`;
      el.style.top = `${Math.max(0, Math.min(ev.clientY - drag.dy, window.innerHeight - el.offsetHeight))}px`;
      el.style.right = 'auto';
      el.style.bottom = 'auto';
    });
    const endDrag = (ev) => {
      if (!drag || ev.pointerId !== drag.id) return;
      dragged = drag.moved;
      drag = null;
      el.classList.remove('dragging');
      if (!dragged) return;
      // Snap to the nearest corner, glide there, then hand anchoring back to CSS.
      const corner = (ev.clientY < window.innerHeight / 2 ? 't' : 'b')
        + (ev.clientX < window.innerWidth / 2 ? 'l' : 'r');
      localStorage.setItem(storageKey, corner);
      const m = opts.margins ? opts.margins(corner) : { x: FAB_MARGIN, y: FAB_MARGIN };
      el.classList.add('snapping');
      el.style.left = `${corner[1] === 'l' ? m.x : window.innerWidth - el.offsetWidth - m.x}px`;
      el.style.top = `${corner[0] === 't' ? m.y : window.innerHeight - el.offsetHeight - m.y}px`;
      setTimeout(() => {
        el.classList.remove('snapping');
        el.style.cssText = '';
        el.dataset.corner = corner;
        if (opts.onSnap) opts.onSnap(corner);
      }, 160);
    };
    window.addEventListener('pointerup', endDrag);
    window.addEventListener('pointercancel', endDrag);
    return {
      wasDrag: () => {
        const was = dragged;
        dragged = false;
        return was;
      },
    };
  }

  const fabDrag = cornerDrag($fab, $fabToggle, 'mdpv-fab-corner', {
    onDragStart: () => toggleMenu(false),
    onSnap: updateEvade,
  });
  $fabToggle.addEventListener('click', () => {
    if (fabDrag.wasDrag()) return;
    toggleMenu();
  });
  // The whole outline is its own drag handle; a sub-5px press stays a link
  // click (nothing is captured, so the click reaches the link untouched).
  const tocDrag = cornerDrag($toc, $toc, 'mdpv-toc-corner', {
    margins: (corner) => ({ x: FAB_MARGIN, y: corner === $fab.dataset.corner ? TOC_EVADE : FAB_MARGIN }),
    onSnap: updateEvade,
  });
  $toc.addEventListener('dragstart', (ev) => ev.preventDefault()); // anchors native-drag by default
  updateEvade();

  // Theme: the server renders the configured theme; the segmented control
  // picks auto/light/dark per browser (persisted in localStorage), swapping
  // in the same stylesheet pair the server would have injected.
  const THEME_CSS = {
    auto: ['github-markdown.css', 'hljs-github-auto.css'],
    light: ['github-markdown-light.css', 'github.min.css'],
    dark: ['github-markdown-dark.css', 'github-dark.min.css'],
  };
  const $themeSeg = document.getElementById('theme-seg');

  function paintThemeSeg(theme) {
    for (const b of $themeSeg.children) {
      b.setAttribute('aria-pressed', String(b.dataset.themeOpt === theme));
    }
  }

  function applyTheme(theme) {
    document.documentElement.dataset.theme = theme;
    document.querySelector('meta[name="color-scheme"]').content = theme === 'auto' ? 'light dark' : theme;
    document.getElementById('mdpv-css-md').href = `/assets/vendor/${THEME_CSS[theme][0]}?v=${V}`;
    document.getElementById('mdpv-css-hljs').href = `/assets/vendor/${THEME_CSS[theme][1]}?v=${V}`;
    paintThemeSeg(theme);
    rethemeMermaid();
  }

  const storedTheme = localStorage.getItem('mdpv-theme');
  if (THEME_CSS[storedTheme] && storedTheme !== document.documentElement.dataset.theme) {
    applyTheme(storedTheme);
  } else {
    paintThemeSeg(document.documentElement.dataset.theme);
  }
  $themeSeg.addEventListener('click', (ev) => {
    const btn = ev.target.closest('button');
    const theme = btn && btn.dataset.themeOpt;
    if (!theme || !THEME_CSS[theme] || theme === document.documentElement.dataset.theme) return;
    localStorage.setItem('mdpv-theme', theme);
    applyTheme(theme);
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

  // --- Outline ---------------------------------------------------------------
  // A bare floating heading list (#mdpv-toc, corner-parked above — no panel
  // box; a feathered frost veil keeps it legible over content), rebuilt per
  // render from the headings (which already carry slug ids), with a
  // scroll-spy highlight on the one under the viewport anchor. The menu's
  // Outline switch owns its visibility.

  const $outlineBtn = document.getElementById('outline-toggle');
  const $outline = document.getElementById('outline-list');
  let outlineHeads = [];
  let outlineActive = null;
  let outlineOn = localStorage.getItem('mdpv-outline') !== '0'; // on by default

  // The switch reflects the user's wish; the panel shows only while the
  // document also has headings to list.
  function paintOutline() {
    $outlineBtn.setAttribute('aria-pressed', String(outlineOn));
    $toc.hidden = !(outlineOn && outlineHeads.length > 0);
    if (!$toc.hidden) markOutlineActive();
  }

  function setOutlineOn(on) {
    outlineOn = on;
    localStorage.setItem('mdpv-outline', on ? '1' : '0');
    paintOutline();
  }

  function setOutlineActive(link) {
    if (link === outlineActive) return;
    outlineActive?.classList.remove('active');
    outlineActive = link || null;
    if (link) {
      link.classList.add('active');
      link.scrollIntoView({ block: 'nearest' });
    }
  }

  function markOutlineActive() {
    if ($toc.hidden || outlineHeads.length === 0) return;
    // A programmatic glide is in flight (outline click, go-to-top, cursor
    // follow): whoever started it set the right active item; a spy pass
    // mid-flight — or pinned at the page bottom — would fight it.
    if (performance.now() < progUntil) return;
    const anchor = window.scrollY + window.innerHeight * ANCHOR;
    const i = bisect(outlineHeads, anchor, (h) => h.getBoundingClientRect().top + window.scrollY);
    setOutlineActive($outline.children[Math.max(i, 0)]);
  }

  function rebuildOutline() {
    outlineHeads = [...$content.querySelectorAll('h1[id],h2[id],h3[id],h4[id],h5[id],h6[id]')];
    $outlineBtn.hidden = outlineHeads.length === 0;
    outlineActive = null;
    $outline.textContent = '';
    for (const h of outlineHeads) {
      const a = document.createElement('a');
      a.href = `#${h.id}`;
      a.className = `outline-${h.tagName.toLowerCase()}`;
      const bar = document.createElement('span');
      bar.className = 'toc-bar'; // the collapsed-rail dash
      const label = document.createElement('span');
      label.className = 'toc-text';
      label.textContent = h.textContent;
      a.title = h.textContent; // full text when the label ellipsizes
      a.append(bar, label);
      $outline.appendChild(a);
    }
    paintOutline();
  }

  // Follow-mode hook: pick the active item by source line — the spy is
  // suppressed while the programmatic glide is in flight.
  function outlineActiveByLine(line) {
    if (outlineHeads.length === 0) return;
    const i = bisect(outlineHeads, line, (h) => +h.dataset.sourceLine);
    setOutlineActive($outline.children[Math.max(i, 0)]);
  }

  $outlineBtn.addEventListener('click', () => setOutlineOn(!outlineOn));

  // Hover-intent expansion: the collapsed rail becomes the full list after
  // a short dwell (so a pointer merely passing by doesn't pop the card) and
  // collapses as soon as the pointer leaves. CSS also expands on
  // :focus-within, so keyboard users never need the pointer.
  let tocOpenTimer = 0;
  $toc.addEventListener('pointerenter', () => {
    clearTimeout(tocOpenTimer);
    tocOpenTimer = setTimeout(() => $toc.classList.add('open'), 120);
  });
  $toc.addEventListener('pointerleave', () => {
    clearTimeout(tocOpenTimer);
    $toc.classList.remove('open');
  });
  $outline.addEventListener('click', (ev) => {
    const a = ev.target.closest('a');
    if (!a) return;
    ev.preventDefault();
    if (tocDrag.wasDrag()) return; // the click that ends a drag isn't a jump
    const target = document.getElementById(decodeURIComponent(a.hash.slice(1)));
    if (!target) return;
    history.replaceState(null, '', a.hash);
    progUntil = performance.now() + 1200;
    window.scrollTo({ top: target.getBoundingClientRect().top + window.scrollY - 12, behavior: 'smooth' });
    setOutlineActive(a);
  });
  let spyRaf = 0;
  window.addEventListener('scroll', () => {
    if (spyRaf) return;
    spyRaf = requestAnimationFrame(() => {
      spyRaf = 0;
      markOutlineActive();
    });
  }, { passive: true });

  // --- Copy buttons ----------------------------------------------------------
  // 127.0.0.1 is a secure context, so navigator.clipboard is available.

  $content.addEventListener('click', (ev) => {
    const btn = ev.target.closest('button.mdpv-copy');
    if (!btn) return;
    const code = btn.parentElement.querySelector('pre > code');
    if (!code || !navigator.clipboard) return;
    navigator.clipboard.writeText(code.textContent).then(() => {
      btn.classList.add('mdpv-copied');
      btn.innerHTML = OCTICON.check;
      setTimeout(() => {
        btn.classList.remove('mdpv-copied');
        btn.innerHTML = OCTICON.copy;
      }, 1500);
    }, () => {});
  });

  // First paint from the embedded boot payload — no SSE round-trip needed.
  if (typeof BOOT.md === 'string') render(BOOT.md);

  // A .md file rendered through the /f/ route has no buffer behind it:
  // nothing to stream, nothing to follow.
  if (BOOT.static) {
    setStatus('static', 'static file', 'Rendered from disk — not a live buffer');
    return;
  }

  // --- Task checkboxes -------------------------------------------------------
  // A click POSTs the new state; the editor flips [ ]/[x] on that line (the
  // buffer must be modifiable) and the change streams back through the normal
  // render path, which confirms the box's state.

  $content.addEventListener('change', (ev) => {
    const box = ev.target;
    if (!(box instanceof HTMLInputElement) || !box.classList.contains('task-list-item-checkbox')) return;
    const li = box.closest('[data-source-line]');
    if (!li) return;
    fetch(`/sync/${BOOT.token}`, {
      method: 'POST',
      body: JSON.stringify({ toggle: { line: +li.dataset.sourceLine, checked: box.checked } }),
    }).catch(() => {});
  });

  // --- Scroll sync -----------------------------------------------------------
  // Editor -> browser ("Follow cursor"): the server streams the cursor line;
  // block elements carry data-source-line, and interpolating between the
  // surrounding two mapped elements keeps long paragraphs/code blocks
  // tracking smoothly. Browser -> editor ("Move cursor on scroll"): user
  // scrolls POST the line under the viewport anchor back, moving the cursor.
  // Both directions are per-browser switches in the menu; scroll_sync =
  // 'both' only picks the second one's default. Echo control: our own smooth
  // scrolls are ignored for a beat (progUntil), and the editor skips
  // re-broadcasting a cursor line it just applied.

  const SYNC = FEATURES.scrollSync; // false | true | 'both'
  let follow = localStorage.getItem('mdpv-follow') !== '0';
  let syncBack = (localStorage.getItem('mdpv-sync-back') ?? (SYNC === 'both' ? '1' : '0')) === '1';
  let lastSentLine = 0;

  function paintSync() {
    $follow.setAttribute('aria-pressed', String(follow)); // drives the menu switches
    $syncBack.setAttribute('aria-pressed', String(syncBack));
  }
  if (SYNC) {
    document.getElementById('sync-group').hidden = false;
    paintSync();
    $follow.addEventListener('click', () => {
      follow = !follow;
      localStorage.setItem('mdpv-follow', follow ? '1' : '0');
      paintSync();
      if (!follow) {
        cursorLine = 0;
        paintCursorBlock();
      }
    });
    $syncBack.addEventListener('click', () => {
      syncBack = !syncBack;
      localStorage.setItem('mdpv-sync-back', syncBack ? '1' : '0');
      paintSync();
    });
  }

  // Deep-linkable position: when the cursor sits on a heading line, mirror
  // its slug into the URL hash (replaceState: no scroll, no history spam).
  function syncHashToCursor(line) {
    const i = bisect(syncEls, line, (n) => +n.dataset.sourceLine);
    const el = i === -1 ? null : syncEls[i];
    if (el && /^H[1-6]$/.test(el.tagName) && el.id && +el.dataset.sourceLine === line) {
      history.replaceState(null, '', `#${el.id}`);
    }
  }

  function scrollToLine(line) {
    progUntil = performance.now() + 1200; // smooth scroll settles well within this
    const i = bisect(syncEls, line, (el) => +el.dataset.sourceLine);
    if (i === -1) {
      window.scrollTo({ top: 0, behavior: 'smooth' });
      return;
    }
    const prev = syncEls[i];
    const next = syncEls[i + 1];
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
    const top = (el) => el.getBoundingClientRect().top + window.scrollY;
    const i = bisect(syncEls, anchor, top);
    if (i === -1) return 1;
    const prev = syncEls[i];
    const next = syncEls[i + 1];
    const prevLine = +prev.dataset.sourceLine;
    if (!next) return prevLine;
    const a = top(prev);
    const b = top(next);
    const span = +next.dataset.sourceLine - prevLine;
    if (b <= a || span <= 0) return prevLine;
    return Math.max(1, Math.round(prevLine + span * ((anchor - a) / (b - a))));
  }

  if (SYNC) {
    let sendTimer = 0;
    window.addEventListener('scroll', () => {
      if (!syncBack || performance.now() < progUntil) return;
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
      cursorLine = payload.line;
      paintCursorBlock();
      outlineActiveByLine(payload.line);
      syncHashToCursor(payload.line);
    }
  });

  // Live asset reload: the server watches files it has served and pushes the
  // relative paths that changed; cache-bust the matching media elements so a
  // regenerated image refreshes without reloading the page.
  let assetSeq = 0;
  es.addEventListener('assets', (ev) => {
    let payload;
    try {
      payload = JSON.parse(ev.data);
    } catch (_) {
      return;
    }
    if (!Array.isArray(payload.paths)) return;
    const targets = new Set(payload.paths.map((p) => `${FILE_BASE}/${p}`));
    assetSeq += 1;
    for (const el of $content.querySelectorAll('img[src], video[src], audio[src], source[src]')) {
      const u = new URL(el.getAttribute('src'), location.href);
      let file;
      try {
        file = decodeURIComponent(u.pathname);
      } catch (_) {
        continue;
      }
      if (u.origin !== location.origin || !targets.has(file)) continue;
      u.searchParams.set('r', String(assetSeq));
      el.setAttribute('src', u.pathname + u.search);
      const media = el.tagName === 'SOURCE' ? el.parentElement : el;
      if (media && (media.tagName === 'VIDEO' || media.tagName === 'AUDIO')) media.load();
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
