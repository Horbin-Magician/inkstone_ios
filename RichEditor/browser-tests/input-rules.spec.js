import {test, expect} from '@playwright/test';

async function load(page, source = '') {
  await page.goto('http://127.0.0.1:8765/editor.html');
  await page.waitForFunction(() => window.inkstone);
  await page.evaluate(source => { inkstone.load(source, 'shortcuts'); inkstone.select(1); inkstone.focus(true); }, source);
}

for (const [prefix, selector] of [
  ['* ', 'ul > li'], ['- ', 'ul > li'], ['+ ', 'ul > li'],
  ['1. ', 'ol > li'], ['3) ', 'ol[start="3"] > li'],
  ...Array.from({length: 6}, (_, i) => ['#'.repeat(i + 1) + ' ', `h${i + 1}`]),
  ['> ', 'blockquote'], ['``` ', 'pre'], ['```swift ', 'pre'], ['~~~js ', 'pre'],
  ['--- ', 'hr'], ['*** ', 'hr'], ['___ ', 'hr'],
  ['- [ ] ', 'li.task input:not(:checked)'], ['* [x] ', 'li.task input:checked'], ['+ [X] ', 'li.task input:checked']
]) {
  test(`typed Markdown prefix ${JSON.stringify(prefix)} converts`, async ({page}) => {
    await load(page);
    await page.keyboard.type(prefix);
    await expect(page.locator('.ProseMirror ' + selector)).toHaveCount(1);
    await page.keyboard.insertText('中文内容');
    const saved = await page.evaluate(() => inkstone.flush().text);
    expect(saved).toContain('中文内容');
    await page.evaluate(source => inkstone.load(source, 'reopened'), saved);
    await expect(page.locator('.ProseMirror ' + selector)).toHaveCount(1);
  });
}

test('Backspace restores literal prefix, list continues, undo and redo work', async ({page}) => {
  await load(page);
  await page.keyboard.type('* ');
  await page.keyboard.press('Backspace');
  await expect(page.locator('.ProseMirror p')).toHaveText('* ');
  await expect(page.locator('.ProseMirror ul')).toHaveCount(0);
  await page.keyboard.press('Backspace');
  await page.keyboard.type(' first');
  await page.keyboard.press('Enter');
  await page.keyboard.insertText('second');
  await expect(page.locator('.ProseMirror li')).toHaveCount(2);
  await page.evaluate(() => inkstone.command('撤销'));
  await page.evaluate(() => inkstone.command('重做'));
  await expect(page.locator('.ProseMirror li').last()).toHaveText('second');
});

test('mid-paragraph, escaped prefixes and code stay literal', async ({page}) => {
  for (const text of ['正文 * ', '\\* ', '####### ', '1234567890. ']) {
    await load(page);
    await page.keyboard.type(text);
    await expect(page.locator('.ProseMirror > p')).toHaveText(text);
  }
  await load(page);
  await page.evaluate(() => inkstone.command('代码块'));
  await page.keyboard.type('* ');
  await expect(page.locator('.ProseMirror pre')).toHaveText('* ');
});

test('complete committed task prefix converts and next task is unchecked', async ({page}) => {
  await load(page);
  await page.keyboard.insertText('- [x] ');
  await expect(page.locator('li.task input')).toBeChecked();
  await page.keyboard.insertText('完成');
  await page.keyboard.press('Enter');
  await page.keyboard.insertText('待办');
  await expect(page.locator('li.task input')).toHaveCount(2);
  await expect(page.locator('li.task input').last()).not.toBeChecked();
});

test('composition defers shortcut conversion until committed', async ({page}) => {
  await load(page);
  await page.locator('.ProseMirror').dispatchEvent('compositionstart');
  await page.keyboard.insertText('* ');
  await expect(page.locator('.ProseMirror ul')).toHaveCount(0);
  await page.locator('.ProseMirror').dispatchEvent('compositionend');
  await expect(page.locator('.ProseMirror ul')).toHaveCount(1);
  expect(await page.evaluate(() => inkstone.flush().composing)).toBe(false);
});
