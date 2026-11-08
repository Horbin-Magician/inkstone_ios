import test from 'node:test';
import assert from 'node:assert/strict';
import {EditorState} from 'prosemirror-state';
import {loadMarkdown, saveMarkdown, serializer, schema} from './model.js';

const fixtures = [
  '', '\n\n', '\r\n', '# 中文 😀\r\n\r\n正文 **粗体** 和 *斜体*。\r\n',
  '---\r\ntitle: 属性\r\n...\r\n\r\n# 标题\r\n\r\n段落\r\n',
  '标题\n====\n\n> 引用\n>\n> - [X] nested\n> - [ ] next\n',
  '3. first\n   - nested\n4. second\n\n    code\n',
  '| 左 | 右 |\n| :--- | ---: |\n| a\\|b | **bold** |\n',
  '````swift\n```\n[[not link]]\n````\n\n~~删除~~ `code`\n',
  '[[文件夹/笔记|别名]] ![图片](attachments/a%20b.png)\n',
  '[网站][ref]\n\n[ref]: https://example.com "标题"\n',
  '[ref]: https://example.com\n\n正文 [网站][ref]\n',
  '<script>alert("never")</script>\n\n<span>literal</span>\n',
  '---\nnot closed', '只有正文，没有换行', 'line  \nbreak\n\nnew'
];
for (const source of fixtures) test('opening preserves bytes: ' + JSON.stringify(source.slice(0, 40)), () => {
  const loaded = loadMarkdown(source);
  assert.equal(saveMarkdown(loaded.doc, loaded), source);
  loaded.doc.check();
});

test('an edited paragraph retains frontmatter, CRLF, reference definitions and untouched blocks', () => {
  const source = '---\r\ntitle: 属性\r\n---\r\n\r\nTitle\r\n=====\r\n\r\n[链接][ref]\r\n\r\n[ref]: https://example.com\r\n';
  const loaded = loadMarkdown(source);
  let state = EditorState.create({doc: loaded.doc});
  let pos; state.doc.descendants((node, at) => { if (node.isText && node.text === '链接') pos = at; });
  state = state.apply(state.tr.insertText('新', pos));
  const saved = saveMarkdown(state.doc, loaded);
  assert.ok(saved.startsWith('---\r\ntitle: 属性\r\n---\r\n\r\nTitle\r\n=====\r\n\r\n'));
  assert.ok(saved.endsWith('[ref]: https://example.com\r\n'));
  assert.ok(loadMarkdown(saved).doc.textContent.includes('新链接'));
  assert.equal(saved.replace(/\r\n/g, '').includes('\n'), false);
});

test('edited table retains alignment, escaped pipes, and inline formatting', () => {
  const loaded = loadMarkdown('| 左 | 右 |\n| :--- | ---: |\n| a\\|b | **bold** |\n');
  const normalized = serializer.serialize(loaded.doc);
  const roundtrip = loadMarkdown(normalized).doc;
  assert.equal(roundtrip.firstChild.firstChild.child(1).attrs.align, 'right');
  assert.equal(roundtrip.firstChild.child(1).firstChild.textContent, 'a|b');
  assert.equal(roundtrip.firstChild.child(1).child(1).firstChild.firstChild.marks[0].type.name, 'strong');
});

test('task markers, nested lists, wiki aliases, inline HTML and code round trip', () => {
  const loaded = loadMarkdown('- [ ] first\n  - [x] nested [[路径|别名]]\n\n<span>x</span>\n\n```swift\nlet x = 1\n```');
  const normalized = serializer.serialize(loaded.doc);
  assert.match(normalized, /\[ \] first/);
  assert.match(normalized, /\[x\] nested \[\[路径\|别名\]\]/);
  assert.match(normalized, /<span>x<\/span>/);
  const restored = loadMarkdown(normalized).doc;
  assert.equal(restored.firstChild.firstChild.attrs.checked, false);
  assert.equal(restored.firstChild.firstChild.child(1).firstChild.attrs.checked, true);
});

test('literal Markdown punctuation typed into rich text is escaped', () => {
  const doc = schema.nodes.doc.create(null, schema.nodes.paragraph.create(null, schema.text('# not a heading *not bold* [[literal]]')));
  const saved = serializer.serialize(doc);
  const restored = loadMarkdown(saved).doc;
  assert.equal(restored.firstChild.type.name, 'paragraph');
  assert.equal(restored.textContent, doc.textContent);
});
