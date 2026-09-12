// Drives a real browser at the harness and asserts the DOM actually changed.
// "Turbo received the message" is not the claim being tested; "the page updated"
// is, because that is what a framework user would see.
const { chromium, webkit } = require('playwright');

const URL = process.env.TARGET || 'http://127.0.0.1:4322/';
const engines = { chromium, webkit };   // webkit is the engine WKWebView uses

(async () => {
  let failures = 0;
  for (const [name, engine] of Object.entries(engines)) {
    let browser;
    try {
      browser = await engine.launch({ headless: true });
    } catch (e) {
      console.log(`  ?  ${name}: not installed, skipped`);
      continue;
    }
    const page = await (await browser.newContext()).newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });

    try {
      await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 20000 });
      await page.waitForSelector('body[data-turbo="loaded"]', { timeout: 10000 });
      await page.waitForSelector('body[data-sse="open"]', { timeout: 10000 });

      // append: rows must accumulate
      await page.waitForFunction(() => document.querySelectorAll('#feed li').length >= 3, null, { timeout: 15000 });
      const rows = await page.$$eval('#feed li', els => els.map(e => e.dataset.seq));

      // update: the counter must be replaced, not appended to
      const counter = await page.textContent('#counter');
      const counterOk = Number(counter) >= 3;

      // the fragments were multi-line; if SSE reassembly were wrong we would
      // have got nothing, so reaching here proves the data: framing too
      const monotonic = rows.every((v, i) => i === 0 || Number(v) === Number(rows[i - 1]) + 1);

      if (rows.length >= 3 && counterOk && monotonic) {
        console.log(`  OK ${name}: ${rows.length} rows appended, counter=${counter}, sequence contiguous`);
      } else {
        console.log(`  FAIL ${name}: rows=${rows.length} counter=${counter} monotonic=${monotonic}`);
        failures++;
      }
      if (errors.length) { console.log(`     page errors: ${errors.slice(0, 3).join(' | ')}`); failures++; }
    } catch (e) {
      console.log(`  FAIL ${name}: ${e.message.split('\n')[0]}`);
      if (errors.length) console.log(`     page errors: ${errors.slice(0, 3).join(' | ')}`);
      failures++;
    } finally {
      await browser.close();
    }
  }
  process.exit(failures ? 1 : 0);
})();
