import {test, expect} from '@playwright/test';

test('bridge input benchmark', async ({page}) => {
  test.skip(process.env.INKSTONE_BRIDGE_BENCHMARK !== '1');
  test.setTimeout(180000);
  await page.goto('http://127.0.0.1:8765/editor.html');
  await page.waitForFunction(() => window.inkstone);
  for (const bytes of [32768, 8 * 1024 * 1024 - 1024]) {
    await page.evaluate(bytes => {
      const paragraph = '中文 benchmark paragraph. '.repeat(32) + '\n\n';
      const count = Math.floor(bytes / new TextEncoder().encode(paragraph).length);
      if (!inkstone.load(paragraph.repeat(count), 'benchmark-' + bytes)) throw new Error('Load failed');
      window.bridgeBytes = 0; window.bridgeChanges = 0;
      window.webkit = {messageHandlers: {richEditor: {postMessage: message => {
        if (message.type === 'change') {
          bridgeChanges++;
          bridgeBytes += new TextEncoder().encode(JSON.stringify(message)).length;
        }
      }}}};
      inkstone.select(1); inkstone.focus(true);
    }, bytes);
    const latencies = [];
    for (let i = 0; i < 10; i++) {
      await page.evaluate(() => { window.beforeInput = performance.now(); });
      await page.keyboard.insertText('新');
      latencies.push(await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => resolve(performance.now() - beforeInput)))));
      await page.waitForTimeout(80);
    }
    const result = await page.evaluate(() => {
      const result = {messages: bridgeChanges, bytes: bridgeBytes};
      result.latest = inkstone.flush().text.startsWith('新'.repeat(10));
      return result;
    });
    latencies.sort((a, b) => a - b);
    expect(result.latest).toBe(true);
    console.log('BRIDGE_BENCH ' + JSON.stringify({documentBytes: bytes, p50InputToFrameMs: latencies[5], p95InputToFrameMs: latencies[9], ...result}));
  }
});

test('document initialization versus retained mode switch benchmark', async ({page}) => {
  test.skip(process.env.INKSTONE_LOAD_BENCHMARK !== '1');
  await page.goto('http://127.0.0.1:8765/editor.html');
  await page.waitForFunction(() => window.inkstone);
  const result = await page.evaluate(() => {
    const source = Array.from({length: 300}, (_, i) => `## 段落 ${i}\n\n中文正文 **格式** 与 [链接](https://example.com)。\n\n`).join('');
    const cold = [], retained = [];
    for (let i = 0; i < 11; i++) {
      let start = performance.now();
      if (!inkstone.load(source, 'load-' + i)) throw new Error('Load failed');
      void inkstone.view.dom.offsetHeight;
      cold.push(performance.now() - start);
      inkstone.flush(true); inkstone.setEnabled(false); inkstone.focus(false);
      start = performance.now();
      inkstone.applyUpdates([['releaseSnapshot', []], ['setEnabled', [true]], ['focus', [true]]]);
      void inkstone.view.dom.offsetHeight;
      retained.push(performance.now() - start);
    }
    const median = values => values.slice(1).sort((a, b) => a - b)[5];
    return {bytes: new TextEncoder().encode(source).length, initializationMedianMs: median(cold), retainedSwitchMedianMs: median(retained)};
  });
  console.log('LOAD_BENCH ' + JSON.stringify(result));
});
