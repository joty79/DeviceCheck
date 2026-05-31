#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const { spawn } = require('child_process');

const query = process.argv[2];
const timeoutMs = Number(process.argv[3] || 60000);

if (!query) {
  console.error('Usage: node Search-GoogleRendered.js <query> [timeoutMs]');
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
    req.setTimeout(5000, () => req.destroy(new Error('HTTP request timed out.')));
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

async function waitForBodyText(send, deadline) {
  let last = { readyState: '', href: '', textLength: 0 };
  while (Date.now() < deadline) {
    const evaluated = await send('Runtime.evaluate', {
      expression: `(() => ({
        readyState: document.readyState,
        href: location.href,
        textLength: (document.body?.innerText || '').trim().length
      }))()`,
      returnByValue: true,
    }).catch(() => null);
    if (evaluated?.result?.value) {
      last = evaluated.result.value;
      if (last.textLength > 80) return last;
    }
    await sleep(500);
  }
  throw new Error(`Timed out waiting for Google body text. Last state: ${JSON.stringify(last)}`);
}

async function main() {
  const deadline = Date.now() + timeoutMs;
  const chrome = findChrome();
  
  const isPersistent = !process.env.DEVICECHECK_TEMP_PROFILE;
  const profileDir = process.env.DEVICECHECK_CHROME_PROFILE || 
    path.join(process.env.LOCALAPPDATA || os.homedir(), 'DeviceCheck', 'browser-profile');
  
  if (!fs.existsSync(profileDir)) {
    fs.mkdirSync(profileDir, { recursive: true });
  }

  const googleHl = process.env.DEVICECHECK_GOOGLE_HL || 'en';
  const googleGl = process.env.DEVICECHECK_GOOGLE_GL || 'gr';
  
  // Navigate to Google home first instead of direct search URL
  const startUrl = `https://www.google.gr/?hl=${encodeURIComponent(googleHl)}&gl=${encodeURIComponent(googleGl)}`;
  
  const args = [
    '--remote-debugging-port=0',
    `--user-data-dir=${profileDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-sync',
    '--disable-extensions',
    '--window-size=1400,1000',
    startUrl,
  ];

  const child = spawn(chrome, args, { stdio: 'ignore', windowsHide: false });
  let cdp = null;

  try {
    const port = await waitForDevToolsPort(profileDir, deadline);
    const target = await waitForPageTarget(port, deadline);
    cdp = await connectCdp(target.webSocketDebuggerUrl);
    const { send } = cdp;

    await send('Page.enable');
    await send('Runtime.enable');
    await send('Page.navigate', { url: startUrl });
    await sleep(2500);
    await waitForBodyText(send, Math.min(deadline, Date.now() + 25000));

    // Handle Google Consent popup if visible
    await send('Runtime.evaluate', {
      expression: `(() => {
        const candidates = Array.from(document.querySelectorAll('button, a, [role="button"], div, span'));
        const accept = candidates.find(el => /^(accept all|accept|αποδοχή όλων|συμφωνώ)$/i.test((el.innerText || el.textContent || '').trim()));
        if (accept) { accept.click(); return true; }
        return false;
      })()`,
      returnByValue: true,
    }).catch(() => {});
    await sleep(2000);
    await waitForBodyText(send, Math.min(deadline, Date.now() + 15000));

    // Emulate typing the search query like a real user
    const typeAndSearchExpression = `(async () => {
      const sleep = ms => new Promise(r => setTimeout(r, ms));
      const input = document.querySelector('textarea[name="q"]') || document.querySelector('input[name="q"]');
      if (!input) return false;
      
      input.focus();
      input.click();
      await sleep(300);
      
      input.value = '';
      const queryText = ${JSON.stringify(query)};
      for (let i = 0; i < queryText.length; i++) {
        input.value += queryText[i];
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new KeyboardEvent('keydown', { key: queryText[i] }));
        input.dispatchEvent(new KeyboardEvent('keypress', { key: queryText[i] }));
        input.dispatchEvent(new KeyboardEvent('keyup', { key: queryText[i] }));
        await sleep(40 + Math.random() * 70);
      }
      
      await sleep(500);
      const form = input.closest('form');
      if (form) {
        form.submit();
        return true;
      }
      return false;
     })()`;

    await send('Runtime.evaluate', {
      expression: typeAndSearchExpression,
      returnByValue: true,
      awaitPromise: true
    }).catch(() => {});
    
    // Wait for search results page to load
    await sleep(3500);
    await waitForBodyText(send, Math.min(deadline, Date.now() + 20000));

    for (let i = 0; i < 2; i++) {
      await send('Runtime.evaluate', { expression: 'window.scrollBy(0, 650);', returnByValue: true }).catch(() => {});
      await sleep(1200);
    }
    await send('Runtime.evaluate', { expression: 'window.scrollTo(0, 0);', returnByValue: true }).catch(() => {});
    await sleep(800);

    const expression = `(() => {
      const normalize = value => String(value || '').replace(/\\s+/g, ' ').trim();
      const decodeGoogleUrl = href => {
        try {
          const url = new URL(href);
          if (/google\\./i.test(url.hostname) && url.pathname === '/url') {
            return url.searchParams.get('q') || href;
          }
          return href;
        } catch {
          return href;
        }
      };
      const pageText = normalize(document.body?.innerText || '');
      const blockedByGoogle = /(?:I'm not a robot|unusual traffic|About this page|reCAPTCHA|detected unusual traffic)/i.test(pageText);
      const aiIndex = pageText.toLowerCase().indexOf('ai overview');
      let aiOverviewHint = '';
      if (aiIndex >= 0) {
        const after = pageText.slice(aiIndex);
        const stop = after.search(/(?:People also ask|Videos|Forums|Images|More results|Related searches)/i);
        aiOverviewHint = (stop > 0 ? after.slice(0, stop) : after.slice(0, 2500)).trim();
      }
      const resultNodes = Array.from(document.querySelectorAll('a'))
        .map(anchor => {
          const titleNode = anchor.querySelector('h3') || anchor.closest('div')?.querySelector('h3');
          const href = decodeGoogleUrl(anchor.href || '');
          if (!titleNode || !href || /google\\.|webcache|translate\\.google/i.test(href)) return null;
          const container = anchor.closest('div.g, div[data-sokoban-container], div.MjjYud, div') || anchor.parentElement;
          return {
            title: normalize(titleNode.innerText || titleNode.textContent || ''),
            url: href,
            snippet: normalize(container?.innerText || '').slice(0, 900)
          };
        })
        .filter(Boolean);
      const seen = new Set();
      const organicResults = [];
      for (const result of resultNodes) {
        if (!result.title || !result.url || seen.has(result.url)) continue;
        seen.add(result.url);
        organicResults.push(result);
        if (organicResults.length >= 8) break;
      }
      return {
        query: ${JSON.stringify(query)},
        finalUrl: location.href,
        title: document.title,
        blockedByGoogle,
        blockReason: blockedByGoogle ? 'Google returned anti-bot/reCAPTCHA page for this automated browser session.' : '',
        aiOverviewHint: aiOverviewHint.slice(0, 2500),
        organicResults,
        textSnippet: pageText.slice(0, 5000)
      };
    })()`;

    const evaluated = await send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });

    const value = evaluated.result.value || {};
    if (value.blockedByGoogle) {
      console.log(JSON.stringify(value, null, 2));
      return;
    }
    if (!String(value.textSnippet || '').trim() && !String(value.aiOverviewHint || '').trim() && !(value.organicResults || []).length) {
      throw new Error(`Google rendered search returned empty page text at ${value.finalUrl || startUrl}`);
    }
    console.log(JSON.stringify(value, null, 2));
  } finally {
    try {
      if (cdp && cdp.ws) cdp.ws.close();
    } catch {}
    try {
      child.kill();
    } catch {}
    await sleep(500);
    if (!isPersistent) {
      try {
        fs.rmSync(profileDir, { recursive: true, force: true });
      } catch {}
    }
  }
}

main().catch(error => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});
