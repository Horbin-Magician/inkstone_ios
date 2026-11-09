import test from 'node:test';
import assert from 'node:assert/strict';
import {EditorState} from 'prosemirror-state';
import {loadMarkdown, saveMarkdown, serializer, schema, obsidianImage} from './model.js';

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

test('serialization caches immutable blocks and keeps separators correct after reorder', () => {
  const loaded = loadMarkdown('first\r\n\r\nsecond\r\n\r\nthird\r\n');
  const nodes = [];
  loaded.doc.forEach(node => nodes.push(node.type.create(node.attrs, schema.text(node.textContent + ' changed'))));
  const serialize = serializer.serialize;
  let calls = 0;
  serializer.serialize = function(...args) { calls++; return serialize.apply(this, args); };
  try {
    const doc = schema.nodes.doc.create(null, nodes);
    const output = saveMarkdown(doc, loaded);
    assert.equal(calls, 3);
    assert.equal(saveMarkdown(doc, loaded), output);
    assert.equal(calls, 3);
    nodes[0] = nodes[0].type.create(nodes[0].attrs, schema.text('new'));
    const edited = schema.nodes.doc.create(null, [nodes[2], nodes[0], nodes[1]]);
    const result = saveMarkdown(edited, loaded);
    assert.equal(calls, 4);
    assert.match(result, /^third changed\r\n\r\nnew\r\n\r\nsecond changed/);
    assert.equal(saveMarkdown(loaded.doc, loaded), loaded.source);
  } finally { serializer.serialize = serialize; }
});

for (const container of [
  '> quoted\n>\n> [ref]: https://example.com "nested title"\n',
  '- first\n\n  [ref]: https://example.com\n',
  '1. first\n   > nested\n   >\n   > [ref]: https://example.com\n',
]) test('nested definitions stay in a source atom after another block changes: ' + container, () => {
  const source = container + '\nuntouched [link][ref]\n\neditable\n';
  const loaded = loadMarkdown(source);
  assert.equal(loaded.doc.firstChild.type.name, 'raw_block');
  assert.ok(loaded.doc.firstChild.attrs.source.startsWith(container));
  let state = EditorState.create({doc: loaded.doc});
  let pos;
  state.doc.descendants((node, at) => { if (node.isText && node.text === 'editable') pos = at; });
  state = state.apply(state.tr.insertText('new ', pos));
  const saved = saveMarkdown(state.doc, loaded);
  assert.ok(saved.startsWith(container));
  const reopened = loadMarkdown(saved);
  let href;
  reopened.doc.descendants(node => { if (node.isText && node.text === 'link') href = node.marks.find(mark => mark.type.name === 'link')?.attrs.href; });
  assert.equal(href, 'https://example.com');
  assert.equal(saveMarkdown(reopened.doc, reopened), saved);
});

test('Obsidian images render and retain syntax when the paragraph is edited', () => {
  const source = 'before ![[附件/中文 photo.png|320x200]] after';
  const loaded = loadMarkdown(source);
  const image = loaded.doc.firstChild.child(1);
  assert.equal(image.type.name, 'image');
  assert.equal(decodeURIComponent(image.attrs.src), 'inkstone-embed:附件/中文 photo.png|320x200');
  const changed = EditorState.create({doc: loaded.doc}).tr.insertText('edited ', 1).doc;
  assert.equal(saveMarkdown(changed, loaded), 'edited ' + source);
});

test('Obsidian code, escaped embeds and non-image embeds remain literal', () => {
  for (const source of ['`![[a.png]]`', '\\![[a.png]]', '![[note]]', '![[file.pdf]]']) {
    const loaded = loadMarkdown(source);
    let images = 0;
    loaded.doc.descendants(node => { if (node.type.name === 'image') images++; });
    assert.equal(images, 0, source);
    assert.equal(saveMarkdown(loaded.doc, loaded), source);
  }
});

test('Obsidian sizes allow padding used by existing notes', () => {
  assert.deepEqual(obsidianImage('/附件/photo.png| 500 '), {target: '/附件/photo.png', width: '500', height: undefined});
});
