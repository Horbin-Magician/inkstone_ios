import {test, expect} from '@playwright/test';
async function load(page, source) {
  await page.goto('http://127.0.0.1:8765/editor.html');
  await page.waitForFunction(() => window.inkstone);
  expect(await page.evaluate(source => inkstone.load(source, 'test'), source)).toBe(true);
}
const markdown = page => page.evaluate(() => inkstone.flush().text);

test('edit formatted Chinese, toolbar formatting, undo and redo', async ({page}) => {
  await load(page, '# 标题\n\n你好世界\n');
  await expect(page.locator('.ProseMirror h1')).toHaveText('标题');
  await page.evaluate(() => { inkstone.select(5, 9); });
  await page.getByRole('button', {name: '加粗', exact: true}).click();
  expect(await markdown(page)).toContain('**你好世界**');
  await page.getByRole('button', {name: '撤销', exact: true}).click();
  expect(await markdown(page)).toBe('# 标题\n\n你好世界\n');
  await page.getByRole('button', {name: '重做', exact: true}).click();
  await expect(page.locator('.ProseMirror strong')).toHaveText('你好世界');
  await page.evaluate(() => inkstone.select(9));
  await page.keyboard.insertText('，中文输入😀');
  expect(await markdown(page)).toContain('，中文输入😀');
});

test('new note, headings, lists, task toggle and normal list continuation', async ({page}) => {
  await load(page, '');
  await page.locator('.ProseMirror').click();
  await page.keyboard.insertText('新笔记');
  await page.getByRole('button', {name: '1 级标题', exact: true}).click();
  expect(await markdown(page)).toBe('# 新笔记');
  await page.evaluate(() => inkstone.load('- 普通列表', 'test'));
  await page.evaluate(() => inkstone.select(7));
  await page.locator('.ProseMirror').focus();
  await page.keyboard.press('Enter'); await page.keyboard.insertText('下一项');
  expect(await markdown(page)).not.toContain('[ ]');
  await page.getByRole('button', {name: '待办列表', exact: true}).click();
  await page.locator('input[type=checkbox]').check();
  expect(await markdown(page)).toContain('[x] 下一项');
});

test('table cells are editable and table commands serialize Markdown', async ({page}) => {
  await load(page, '| A | B |\n| :--- | ---: |\n| C | D |');
  await page.locator('td').first().click();
  await page.keyboard.insertText('中文');
  await page.getByRole('button', {name: '表格添加行', exact: true}).click();
  await expect(page.locator('tr')).toHaveCount(3);
  const saved = await markdown(page);
  expect(saved).toContain('中文'); expect(saved).toContain('---:');
  expect(await page.evaluate(source => inkstone.load(source, 'test'), saved)).toBe(true);
  await expect(page.locator('tr')).toHaveCount(3);
});

test('composition blocks actions and reports a final committed snapshot', async ({page}) => {
  await load(page, '正文');
  await page.locator('.ProseMirror').dispatchEvent('compositionstart');
  expect(await page.evaluate(() => inkstone.flush().composing)).toBe(true);
  await expect(page.getByRole('button', {name: '加粗', exact: true})).toBeDisabled();
  await page.locator('.ProseMirror').dispatchEvent('compositionend');
  await expect.poll(() => page.evaluate(() => inkstone.flush().composing)).toBe(false);
});

test('note HTML cannot execute and switching documents resets undo', async ({page}) => {
  await load(page, '<script>window.compromised=true</script>\n\n正文');
  expect(await page.evaluate(() => window.compromised)).toBeUndefined();
  await expect(page.locator('.raw-block')).toContainText('<script>');
  await page.evaluate(() => inkstone.load('另一篇', 'next'));
  await expect(page.getByRole('button', {name: '撤销', exact: true})).toBeDisabled();
  expect(await markdown(page)).toBe('另一篇');
});

test('external photo append preserves text and remains undoable', async ({page}) => {
  await load(page, '# 标题\n\n正文');
  await page.evaluate(() => inkstone.setSource('# 标题\n\n正文\n![图片](attachments/photo.png)\n', 'test'));
  expect(await markdown(page)).toContain('![图片](attachments/photo.png)');
  await page.getByRole('button', {name: '撤销', exact: true}).click();
  expect(await markdown(page)).toBe('# 标题\n\n正文');
});

test('link dialog keeps selection and Wiki links retain their target', async ({page}) => {
  await load(page, '链接文字');
  await page.evaluate(() => inkstone.select(1, 5));
  await page.getByRole('button', {name: '插入或修改链接', exact: true}).click();
  await page.locator('#link-url').fill('https://example.com');
  await page.getByRole('button', {name: '确定', exact: true}).click();
  expect(await markdown(page)).toContain('[链接文字](https://example.com)');
  await page.evaluate(() => inkstone.select(5));
  await page.getByRole('button', {name: '插入或修改链接', exact: true}).click();
  await page.locator('#link-url').fill('[[文件夹/笔记|别名]]');
  await page.getByRole('button', {name: '确定', exact: true}).click();
  expect(await markdown(page)).toContain('[[文件夹/笔记|别名]]');
});

test('native image paste callback follows the original selection while typing continues', async ({page}) => {
  await page.addInitScript(() => {
    window.messages = [];
    window.webkit = {messageHandlers: {richEditor: {postMessage: message => messages.push(message)}}};
  });
  await load(page, '前后');
  await page.evaluate(() => {
    inkstone.select(2);
    const transfer = new DataTransfer();
    transfer.items.add(new File([new Uint8Array([1, 2, 3])], 'image.png', {type: 'image/png'}));
    inkstone.view.dom.dispatchEvent(new ClipboardEvent('paste', {clipboardData: transfer, bubbles: true, cancelable: true}));
  });
  await expect.poll(() => page.evaluate(() => messages.some(message => message.type === 'image'))).toBe(true);
  await page.evaluate(() => {
    inkstone.select(1); inkstone.view.dispatch(inkstone.view.state.tr.insertText('新增'));
    inkstone.insertImage('attachments/pasted.png');
  });
  expect(await markdown(page)).toBe('新增前![图片](attachments/pasted.png)后');
});

test('mobile layout shows rendered content without horizontal document overflow', async ({page}) => {
  await load(page, '# 墨砚 · 编辑体验\n\n直接编辑 **排版后的正文**，用工具栏设置格式。\n\n## 今日计划\n\n- [x] 完成富文本编辑\n- [ ] 整理读书笔记\n\n> 文字保存在 Markdown 文件中。\n\n| 内容 | 状态 |\n| --- | --- |\n| 标题和列表 | 已支持 |\n| 图片与链接 | 已支持 |');
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({path: '/tmp/inkstone-rich-editor-mobile.png', fullPage: true});
});


test('batched edits flush immediately and cannot leak into another document', async ({page}) => {
  await load(page, '');
  await page.evaluate(() => {
    window.changes = [];
    window.webkit = {messageHandlers: {richEditor: {postMessage: message => changes.push(message)}}};
    inkstone.select(1); inkstone.focus(true);
    for (let i = 0; i < 20; i++) document.execCommand('insertText', false, '字');
  });
  expect(await markdown(page)).toBe('字'.repeat(20));
  expect(await page.evaluate(() => changes.filter(m => m.type === 'change').length)).toBeLessThan(20);
  await page.evaluate(() => inkstone.load('新文档', 'new-session'));
  await page.waitForTimeout(100);
  expect(await markdown(page)).toBe('新文档');
  expect(await page.evaluate(() => changes.at(-1).session)).toBe('new-session');
});
