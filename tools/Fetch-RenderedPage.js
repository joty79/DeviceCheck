#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const { spawn } = require('child_process');

const targetUrl = process.argv[2];
let targetText = '';
let inputText = '';
let timeoutMs = 45000;
if (process.argv[3]) {
  if (/^\d+$/.test(process.argv[3])) {
    timeoutMs = Number(process.argv[3]);
  } else {
    targetText = process.argv[3];
    if (process.argv[4] && !/^\d+$/.test(process.argv[4])) {
      inputText = process.argv[4];
      timeoutMs = Number(process.argv[5] || 45000);
    } else {
      timeoutMs = Number(process.argv[4] || 45000);
    }
  }
}

if (!targetUrl) {
  console.error('Usage: node Fetch-RenderedPage.js <url> [timeoutMs]');
  process.exit(2);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function findChrome() {
  const candidates = [
    process.env.CHROME_PATH,
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  ].filter(Boolean);

  for (const candidate of candidates) {
    try {
      if (fs.existsSync(candidate)) return candidate;
    } catch {}
  }
  throw new Error('Chrome or Edge executable was not found.');
}

function httpJson(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, res => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', chunk => { body += chunk; });
      res.on('end', () => {
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error(`HTTP ${res.statusCode}: ${body.slice(0, 300)}`));
          return;
        }
        try {
          resolve(JSON.parse(body));
        } catch (error) {
          reject(error);
        }
      });
    });
    req.on('error', reject);
    req.setTimeout(5000, () => {
      req.destroy(new Error('HTTP request timed out.'));
    });
  });
}

async function waitForDevToolsPort(profileDir, deadline) {
  const activePortPath = path.join(profileDir, 'DevToolsActivePort');
  while (Date.now() < deadline) {
    try {
      const raw = fs.readFileSync(activePortPath, 'utf8').trim().split(/\r?\n/);
      const port = Number(raw[0]);
      if (port > 0) return port;
    } catch {}
    await sleep(100);
  }
  throw new Error('Timed out waiting for Chrome DevToolsActivePort.');
}

async function waitForPageTarget(port, deadline) {
  while (Date.now() < deadline) {
    const targets = await httpJson(`http://127.0.0.1:${port}/json/list`).catch(() => []);
    const page = targets.find(t => t.type === 'page' && t.webSocketDebuggerUrl && !String(t.url || '').startsWith('chrome://'));
    if (page) return page;
    await sleep(250);
  }
  throw new Error('Timed out waiting for a Chrome page target.');
}

async function connectCdp(wsUrl) {
  if (typeof WebSocket === 'undefined') {
    throw new Error('This Node.js runtime does not provide global WebSocket.');
  }

  const ws = new WebSocket(wsUrl);
  const pending = new Map();
  let id = 0;

  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Timed out opening CDP websocket.')), 10000);
    ws.addEventListener('open', () => {
      clearTimeout(timer);
      resolve();
    }, { once: true });
    ws.addEventListener('error', event => {
      clearTimeout(timer);
      reject(new Error(`CDP websocket error: ${event.message || 'unknown error'}`));
    }, { once: true });
  });

  ws.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (!message.id || !pending.has(message.id)) return;
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) {
      reject(new Error(message.error.message || JSON.stringify(message.error)));
    } else {
      resolve(message.result || {});
    }
  });

  function send(method, params = {}) {
    const messageId = ++id;
    ws.send(JSON.stringify({ id: messageId, method, params }));
    return new Promise((resolve, reject) => {
      pending.set(messageId, { resolve, reject });
      setTimeout(() => {
        if (pending.delete(messageId)) reject(new Error(`CDP command timed out: ${method}`));
      }, 15000);
    });
  }

  return { ws, send };
}

async function main() {
  const deadline = Date.now() + timeoutMs;
  const runStartedAt = Date.now();
  const timings = [];
  const markTiming = (name, startedAt) => {
    timings.push({
      name,
      durationMs: Date.now() - startedAt,
      elapsedMs: Date.now() - runStartedAt,
    });
  };
  const chrome = findChrome();
  const profileDir = fs.mkdtempSync(path.join(os.tmpdir(), 'devicecheck-chrome-'));
  const args = [
    '--remote-debugging-port=0',
    `--user-data-dir=${profileDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-sync',
    '--disable-extensions',
    '--window-size=1400,1000',
    targetUrl,
  ];

  const child = spawn(chrome, args, { stdio: 'ignore', windowsHide: false });
  let cdp = null;

  try {
    let stageStartedAt = Date.now();
    const port = await waitForDevToolsPort(profileDir, deadline);
    const target = await waitForPageTarget(port, deadline);
    cdp = await connectCdp(target.webSocketDebuggerUrl);
    markTiming('chrome-cdp-connect', stageStartedAt);
    const { send } = cdp;

    stageStartedAt = Date.now();
    await send('Page.enable');
    await send('Runtime.enable');
    await send('Page.navigate', { url: targetUrl });
    await sleep(6000);
    markTiming('initial-page-wait', stageStartedAt);

    stageStartedAt = Date.now();
    await send('Runtime.evaluate', {
      expression: `(() => {
        const candidates = Array.from(document.querySelectorAll('button, a, [role="button"], div, span'));
        const accept = candidates.find(el => /^(accept all|accept|αποδοχή όλων|συμφωνώ|αποδοχή|agree|consent)$/i.test((el.innerText || el.textContent || '').trim()));
        if (accept) { accept.click(); return true; }
        return false;
      })()`,
      returnByValue: true,
    }).catch(() => {});
    await sleep(1500);
    markTiming('consent-check', stageStartedAt);

    if (targetText) {
      stageStartedAt = Date.now();
      await send('Runtime.evaluate', {
        expression: `(() => {
          const rawNeedles = ${JSON.stringify(targetText)}.split('|').map(s => s.trim().toLowerCase()).filter(Boolean);
          if (!rawNeedles.length) return { clicked: false, reason: 'no target text' };
          const normalize = s => String(s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
          const visible = el => {
            const style = getComputedStyle(el);
            const rect = el.getBoundingClientRect();
            return style.visibility !== 'hidden' && style.display !== 'none' && rect.width > 0 && rect.height > 0;
          };
          const candidates = Array.from(document.querySelectorAll('button, a, [role="button"], li, div, span'))
            .filter(visible)
            .map(el => ({ el, text: normalize(el.innerText || el.textContent || '') }))
            .filter(x => x.text && rawNeedles.some(n => x.text === n || x.text.includes(n)))
            .sort((a, b) => a.text.length - b.text.length);
          if (!candidates.length) return { clicked: false, reason: 'target not found', targetText: ${JSON.stringify(targetText)} };
          candidates[0].el.scrollIntoView({ block: 'center', inline: 'center' });
          candidates[0].el.click();
          return { clicked: true, text: candidates[0].text };
        })()`,
        returnByValue: true,
      }).catch(() => {});
      await sleep(4000);
      markTiming('target-click-wait', stageStartedAt);
    }

    if (inputText) {
      stageStartedAt = Date.now();
      await send('Runtime.evaluate', {
        expression: `(() => {
          const value = ${JSON.stringify(inputText)};
          const visible = el => {
            const style = getComputedStyle(el);
            const rect = el.getBoundingClientRect();
            return style.visibility !== 'hidden' && style.display !== 'none' && rect.width > 0 && rect.height > 0;
          };
          const inputs = Array.from(document.querySelectorAll('input[type="search"], input[type="text"], input:not([type]), textarea'))
            .filter(visible)
            .sort((a, b) => {
              const ah = /search|model|product|keyword/i.test([a.name, a.id, a.placeholder, a.getAttribute('aria-label')].join(' ')) ? 0 : 1;
              const bh = /search|model|product|keyword/i.test([b.name, b.id, b.placeholder, b.getAttribute('aria-label')].join(' ')) ? 0 : 1;
              return ah - bh;
            });
          if (!inputs.length) return { submitted: false, reason: 'no visible input' };
          const input = inputs[0];
          input.focus();
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
          if (setter) setter.call(input, value);
          else input.value = value;
          input.dispatchEvent(new Event('input', { bubbles: true }));
          input.dispatchEvent(new Event('change', { bubbles: true }));
          const form = input.closest('form');
          const scope = input.closest('.search-widget, form, main') || document;
          const buttons = Array.from(scope.querySelectorAll('button, input[type="submit"], [role="button"], a')).filter(visible);
          const submit = buttons.find(el => /submit|search|find|go/i.test((el.innerText || el.value || el.getAttribute('aria-label') || '').trim()));
          if (submit) {
            submit.click();
          } else if (form && typeof form.requestSubmit === 'function') {
            form.requestSubmit();
          } else {
            input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true }));
            input.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', bubbles: true }));
          }
          return { submitted: true, input: input.outerHTML.slice(0, 300), clicked: submit ? (submit.innerText || submit.value || submit.outerHTML).slice(0, 120) : '' };
        })()`,
        returnByValue: true,
      }).catch(() => {});
      await sleep(7000);
      markTiming('input-submit-wait', stageStartedAt);
    }

    stageStartedAt = Date.now();
    for (let i = 0; i < 4; i++) {
      await send('Runtime.evaluate', {
        expression: 'window.scrollTo(0, document.body.scrollHeight);',
        returnByValue: true,
      }).catch(() => {});
      await sleep(1000);
    }
    await send('Runtime.evaluate', {
      expression: 'window.scrollTo(0, 0);',
      returnByValue: true,
    }).catch(() => {});
    await sleep(1000);
    markTiming('scroll-settle', stageStartedAt);

    const expression = `(() => {
      const text = (document.body && document.body.innerText || '').replace(/[ \\t]+/g, ' ').replace(/\\n{3,}/g, '\\n\\n').trim();
      const links = Array.from(document.links || []).map(a => ({
        text: (a.innerText || a.textContent || '').replace(/\\s+/g, ' ').trim(),
        href: a.href || ''
      })).filter(x => x.href);
      const downloadLinks = links.filter(x => /\\.(zip|exe|cab|msi|inf)(\\?|#|$)/i.test(x.href) || /download/i.test(x.text + ' ' + x.href));
      const candidateBlocks = Array.from(document.querySelectorAll('tr, li, article, section, div'))
        .map(el => (el.innerText || '').replace(/[ \\t]+/g, ' ').replace(/\\n{3,}/g, '\\n\\n').trim())
        .filter(t => t.length >= 20 && t.length <= 1800 && /(driver|bios|firmware|version|release date|file size|download|realtek|intel|amd|nvidia)/i.test(t));
      return {
        finalUrl: location.href,
        title: document.title,
        textLength: text.length,
        textSnippet: text.slice(0, 12000),
        downloadLinks: downloadLinks.slice(0, 60),
        candidateBlocks: Array.from(new Set(candidateBlocks)).slice(0, 80)
      };
    })()`;

    stageStartedAt = Date.now();
    const evaluated = await send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    markTiming('extract-page', stageStartedAt);

    const value = evaluated.result.value || {};
    value.timings = timings;
    value.totalDurationMs = Date.now() - runStartedAt;
    value.timeoutMs = timeoutMs;
    console.log(JSON.stringify(value, null, 2));
  } finally {
    try {
      if (cdp && cdp.ws) cdp.ws.close();
    } catch {}
    try {
      child.kill();
    } catch {}
    await sleep(500);
    try {
      fs.rmSync(profileDir, { recursive: true, force: true });
    } catch {}
  }
}

main().catch(error => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});
