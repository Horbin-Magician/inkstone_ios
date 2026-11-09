import {test, expect} from '@playwright/test';
const source = '# 扩展格式\n\n公式 $x_1 + \\alpha$ 和 **粗体**。\n\n$$\n\\frac{a}{b} = \\sqrt{2}\n$$\n\n```swift\nlet greeting = "你好"\nprint(greeting)\n```\n\n```mermaid\nflowchart LR\n A[开始] --> B[完成]\n```\n\n> [!WARNING]- 提醒\n> 内容 **加粗**\n>\n> - [ ] 待办\n';
async function load(page, value = source) {
  await page.goto('http://127.0.0.1:8765/editor.html');
  await page.waitForFunction(() => window.inkstone);
  expect(await page.evaluate(value => inkstone.load(value, 'extensions'), value)).toBe(true);
}
test('offline math, diagram, highlighting and callout previews preserve original source', async ({page}) => {
  const external = []; page.on('request', request => { if (!request.url().startsWith('http://127.0.0.1:8765')) external.push(request.url()); });
  await load(page);
  await expect(page.locator('.katex')).toHaveCount(2);
  await expect(page.locator('.hljs-keyword').first()).toHaveText('let');
  await expect(page.locator('.diagram-preview svg')).toBeVisible();
  const callout = page.locator('.callout');
  await expect(callout.getByRole('button', {name: '提醒'})).toHaveAttribute('aria-expanded', 'false');
  await callout.getByRole('button').click();
  await expect(callout.locator('strong')).toHaveText('加粗');
  expect(await page.evaluate(() => inkstone.flush().text)).toBe(source);
  expect(external).toEqual([]);
  await page.screenshot({path: 'test-results/markdown-extensions.png', fullPage: true});
});
test('formula editing and highlighted code preserve undo and serialization', async ({page}) => {
  await load(page, '前 $x^2$ 后\n\n```swift\nlet x = 1\n```');
  await page.locator('.math-preview').click();
  await expect(page.locator('.math-source')).toBeVisible();
  await page.keyboard.insertText('y+');
  expect(await page.evaluate(() => inkstone.flush().text)).toContain('$y+x^2$');
  await page.evaluate(() => inkstone.command('撤销'));
  expect(await page.evaluate(() => inkstone.flush().text)).toContain('$x^2$');
  await page.locator('pre code').click();
  await page.keyboard.press('End'); await page.keyboard.insertText(' + 2');
  expect(await page.evaluate(() => inkstone.flush().text)).toContain(' + 2');
  await expect(page.locator('.hljs-keyword')).toHaveText('let');
});
test('invalid diagrams and math remain visible without executing markup', async ({page}) => {
  await load(page, '$\\notARealCommand{<script>}$\n\n```mermaid\ninvalid diagram\n```');
  await expect(page.locator('.math-preview.render-error')).toBeVisible();
  await expect(page.locator('.diagram-preview.render-error')).toBeVisible();
  expect(await page.evaluate(() => inkstone.flush().text)).toContain('invalid diagram');
  await expect(page.locator('.ProseMirror script')).toHaveCount(0);
});
test('reader fragments render formulas, highlighted code, diagrams and report height', async ({page}) => {
  await page.goto('http://127.0.0.1:8765/reader.html');
  await page.waitForFunction(() => window.renderFragment);
  await page.evaluate(async () => {
    window.heights = []; window.webkit = {messageHandlers: {renderHeight: {postMessage: value => heights.push(value)}}};
    await renderFragment({kind: 'inline', html: '公式 <span data-tex="x^2"></span>', fontSize: 20, dark: false, revision: 1});
  });
  await expect(page.locator('.katex')).toBeVisible();
  await page.evaluate(() => renderFragment({kind: 'code', source: 'let x = 1', language: 'swift', fontSize: 16, dark: false, revision: 2}));
  await expect(page.locator('.hljs-keyword')).toHaveText('let');
  await page.evaluate(() => renderFragment({kind: 'code', source: 'sequenceDiagram\n Alice->>Bob: Hello', language: 'mermaid', fontSize: 16, dark: false, revision: 3}));
  await expect(page.locator('svg')).toBeVisible();
  expect(await page.evaluate(() => heights.some(value => value.revision === 3 && value.height > 40))).toBe(true);
});
test('typed math and callout prefixes become editable formatted nodes', async ({page}) => {
  await load(page, '');
  await page.locator('.ProseMirror').click();
  await page.keyboard.type('$x^2$');
  await expect(page.locator('.math-node')).toHaveCount(1);
  expect(await page.evaluate(() => inkstone.flush().text)).toContain('$x^2$');
  await page.evaluate(() => inkstone.load('> ', 'callout-input'));
  await page.locator('.ProseMirror p').click();
  await page.keyboard.type('[!TIP] ');
  await expect(page.locator('.callout')).toHaveCount(1);
  await page.keyboard.insertText('提示正文');
  expect(await page.evaluate(() => inkstone.flush().text)).toContain('[!TIP]');
  expect(await page.evaluate(() => inkstone.flush().text)).toContain('提示正文');
});
