// Minimal Chrome DevTools Protocol driver for tests/sync.lua — no deps
// (uses Node's built-in WebSocket, Node 22+).
//
//   node tests/cdp.js watch-scroll <url>   print LOADED, then poll until the
//                                          page scrolls (editor -> browser);
//                                          prints SCROLLED <y> and exits 0.
//   node tests/cdp.js user-scroll <url>    print LOADED, wait out the page's
//                                          programmatic-scroll suppression,
//                                          then scroll like a user would
//                                          (browser -> editor); prints
//                                          SCROLLED <y> and exits 0.
//
// Exits non-zero on any timeout. Chromium binary from $MDPV_CHROME.
'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const [mode, url] = process.argv.slice(2);
const chrome = process.env.MDPV_CHROME || 'chromium';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const proc = spawn(chrome, [
  '--headless=new',
  '--disable-gpu',
  '--user-data-dir=' + fs.mkdtempSync(path.join(os.tmpdir(), 'mdpv-cdp-')),
  '--window-size=1100,800',
  '--remote-debugging-port=0',
  url,
], { stdio: ['ignore', 'ignore', 'pipe'] });

const die = (msg, code) => {
  console.error(msg);
  proc.kill();
  process.exit(code);
};
setTimeout(() => die('TIMEOUT: overall', 3), 30000).unref();

let stderr = '';
proc.stderr.on('data', (d) => {
  stderr += d;
  const m = stderr.match(/DevTools listening on (ws:\/\/\S+)/);
  if (m) {
    stderr = ''; // stop matching
    run(m[1]).catch((e) => die('ERROR: ' + e.message, 2));
  }
});

async function run(wsUrl) {
  const ws = new WebSocket(wsUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });

  let msgId = 0;
  const pending = new Map();
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      pending.get(m.id)(m);
      pending.delete(m.id);
    }
  };
  const send = (method, params, sessionId) => new Promise((res) => {
    const id = ++msgId;
    pending.set(id, res);
    ws.send(JSON.stringify({ id, method, params: params || {}, sessionId }));
  });

  // Attach to the page target.
  let targetId;
  for (let i = 0; i < 100 && !targetId; i++) {
    const r = await send('Target.getTargets');
    targetId = r.result.targetInfos.find((t) => t.type === 'page')?.targetId;
    if (!targetId) await sleep(100);
  }
  if (!targetId) return die('TIMEOUT: no page target', 3);
  const attach = await send('Target.attachToTarget', { targetId, flatten: true });
  const sid = attach.result.sessionId;
  const evaluate = async (expression) =>
    (await send('Runtime.evaluate', { expression, returnByValue: true }, sid)).result.result?.value;

  // Wait for the preview to render (source-line map present = app.js ran).
  let ready = false;
  for (let i = 0; i < 100 && !ready; i++) {
    ready = await evaluate(
      "document.readyState === 'complete' && document.querySelectorAll('#content [data-source-line]').length > 0",
    );
    if (!ready) await sleep(100);
  }
  if (!ready) return die('TIMEOUT: page never rendered', 3);
  console.log('LOADED');

  if (mode === 'watch-scroll') {
    // Editor -> browser: the Lua side moves the cursor once it sees LOADED;
    // wait for the resulting smooth scroll to land.
    for (let i = 0; i < 100; i++) {
      const y = await evaluate('window.scrollY');
      if (y > 200) {
        console.log('SCROLLED ' + Math.round(y));
        return die('', 0);
      }
      await sleep(100);
    }
    return die('TIMEOUT: page never scrolled', 1);
  }

  if (mode === 'user-scroll') {
    // Browser -> editor: scroll like a user; app.js should POST the line.
    await sleep(1500); // clear any programmatic-scroll suppression window
    await evaluate("window.scrollTo({ top: document.body.scrollHeight, behavior: 'instant' })");
    await sleep(600); // > the 150 ms send debounce
    const y = await evaluate('window.scrollY');
    console.log('SCROLLED ' + Math.round(y));
    return die('', y > 0 ? 0 : 1);
  }

  return die('ERROR: unknown mode ' + mode, 2);
}
