import MarkdownIt from 'markdown-it';
import {Schema} from 'prosemirror-model';
import {schema as baseSchema, defaultMarkdownParser, defaultMarkdownSerializer, MarkdownParser, MarkdownSerializer} from 'prosemirror-markdown';
import {tableNodes} from 'prosemirror-tables';

// The editor never executes HTML from a note. Unknown syntax stays in a source atom.
let nodes = baseSchema.spec.nodes;
nodes = nodes.update('heading', {...nodes.get('heading'), content: 'inline*'});
nodes = nodes.update('list_item', {...nodes.get('list_item'), attrs: {checked: {default: null}},
  toDOM: node => ['li', node.attrs.checked == null ? {} : {'data-checked': String(node.attrs.checked)}, 0]});
nodes = nodes.append(tableNodes({tableGroup: 'block', cellContent: 'paragraph+', cellAttributes: {
  align: {default: null, getFromDOM: dom => dom.style.textAlign || null,
    setDOMAttr: (value, attrs) => { if (value) attrs.style = `text-align: ${value}`; }}
}}));
nodes = nodes.append({
  raw_block: {group: 'block', atom: true, attrs: {source: {}, label: {default: '特殊语法 · 可在源码模式编辑'}},
    toDOM: node => ['div', {class: 'raw-block', contenteditable: 'false'}, ['small', node.attrs.label], ['pre', node.attrs.source]]},
  raw_inline: {inline: true, group: 'inline', atom: true, attrs: {source: {}},
    toDOM: node => ['code', {class: 'raw-inline'}, node.attrs.source]},
  wiki: {inline: true, group: 'inline', atom: true, attrs: {target: {}, label: {}},
    toDOM: node => ['span', {class: 'wiki', 'data-target': node.attrs.target}, node.attrs.label]}
});
// An origin is only bookkeeping, never exported as Markdown or copied via HTML.
nodes.forEach((name, spec) => {
  if (spec.group === 'block') nodes = nodes.update(name, {...spec, attrs: {...spec.attrs, origin: {default: null}}});
});
const marks = baseSchema.spec.marks.append({strike: {parseDOM: [{tag: 's'}, {tag: 'del'}], toDOM: () => ['s']}});
export const schema = new Schema({nodes, marks});

const tokenizer = new MarkdownIt('default', {html: true, linkify: false, typographer: false});
tokenizer.inline.ruler.before('link', 'wiki', (state, silent) => {
  if (state.src.slice(state.pos, state.pos + 2) !== '[[' || state.linkLevel > 0) return false;
  const match = /^\[\[([^\]\n]+)\]\]/.exec(state.src.slice(state.pos));
  if (!match) return false;
  const separator = match[1].indexOf('|');
  const target = separator < 0 ? match[1] : match[1].slice(0, separator);
  if (!target) return false;
  if (!silent) {
    const token = state.push('wiki', '', 0);
    token.meta = {target, label: separator < 0 ? target : match[1].slice(separator + 1)};
  }
  state.pos += match[0].length;
  return true;
});
tokenizer.core.ruler.after('inline', 'tasks', state => {
  state.tokens.forEach((token, index, tokens) => {
    if (token.type !== 'list_item_open' || tokens[index + 1]?.type !== 'paragraph_open') return;
    const inline = tokens[index + 2];
    const first = inline?.children?.[0];
    const match = first?.type === 'text' && /^\[([ xX])\](?:[ \t]+|$)/.exec(first.content);
    if (!match) return;
    token.meta = {checked: match[1].toLowerCase() === 'x'};
    first.content = first.content.slice(match[0].length);
  });
});
const cellAttrs = token => ({align: token.attrGet('style')?.replace('text-align:', '').trim() || null});
const parser = new MarkdownParser(schema, tokenizer, {
  ...defaultMarkdownParser.tokens,
  list_item: {block: 'list_item', getAttrs: token => ({checked: token.meta?.checked ?? null})},
  s: {mark: 'strike'},
  table: {block: 'table'}, thead: {ignore: true}, tbody: {ignore: true}, tr: {block: 'table_row'},
  th: {block: 'table_header', getAttrs: cellAttrs}, td: {block: 'table_cell', getAttrs: cellAttrs},
  html_block: {node: 'raw_block', getAttrs: token => ({source: token.content})},
  html_inline: {node: 'raw_inline', getAttrs: token => ({source: token.content})},
  wiki: {node: 'wiki', getAttrs: token => token.meta}
});
// Markdown table cells have inline tokens rather than explicit paragraphs.
for (const name of ['th', 'td']) {
  const open = parser.tokenHandlers[name + '_open'], close = parser.tokenHandlers[name + '_close'];
  parser.tokenHandlers[name + '_open'] = (state, ...args) => { open(state, ...args); state.openNode(schema.nodes.paragraph); };
  parser.tokenHandlers[name + '_close'] = (state, ...args) => { state.closeNode(); close(state, ...args); };
}

export const serializer = new MarkdownSerializer({
  ...defaultMarkdownSerializer.nodes,
  list_item(state, node) {
    if (node.attrs.checked != null) state.write(node.attrs.checked ? '[x] ' : '[ ] ');
    state.renderContent(node);
  },
  raw_block(state, node) { state.write(node.attrs.source); state.closeBlock(node); },
  raw_inline(state, node) { state.write(node.attrs.source); },
  wiki(state, node) { state.write('[[' + node.attrs.target + (node.attrs.label === node.attrs.target ? '' : '|' + node.attrs.label) + ']]'); },
  table(state, node) {
    const rows = [];
    node.forEach(row => {
      const cells = [];
      row.forEach(cell => {
        let value = serializer.serialize(schema.nodes.doc.create(null, cell.content));
        // Pipes are structural even inside inline code in a GFM table.
        value = value.replace(/\\\|/g, '|').replace(/\|/g, '\\|').replace(/\n+/g, '<br>');
        cells.push(value);
      });
      rows.push('| ' + cells.join(' | ') + ' |');
    });
    const separators = [];
    node.firstChild.forEach(cell => separators.push(cell.attrs.align === 'center' ? ':---:' : cell.attrs.align === 'right' ? '---:' : cell.attrs.align === 'left' ? ':---' : '---'));
    rows.splice(1, 0, '| ' + separators.join(' | ') + ' |');
    for (const row of rows) { state.write(row); state.ensureNewLine(); }
    state.closeBlock(node);
  }
}, {...defaultMarkdownSerializer.marks, strike: {open: '~~', close: '~~', mixable: true, expelEnclosingWhitespace: true}});

function raw(source, label) { return schema.nodes.raw_block.create({source, label}); }

/** Retain exact source for untouched top-level blocks, plus non-rendered metadata
 * and reference definitions. Editing one paragraph cannot rewrite the whole file. */
export function loadMarkdown(source) {
  const lines = source.match(/[^\r\n]*(?:\r\n|\r|\n|$)/g).filter(Boolean);
  const clean = lines.map(line => line.replace(/[\r\n]+$/, ''));
  let frontmatterEnd = 0;
  if (clean[0]?.trim() === '---') {
    const end = clean.findIndex((line, i) => i > 0 && ['---', '...'].includes(line.trim()));
    if (end > 0) frontmatterEnd = end + 1;
  }
  const parseSource = clean.map((line, i) => i < frontmatterEnd ? '' : line).join('\n');
  const tokens = tokenizer.parse(parseSource, {});
  const ranges = tokens.filter(token => token.level === 0 && token.nesting >= 0 && token.map).map(token => token.map);
  const parsed = parser.parse(parseSource);
  const content = [], originals = new Map();
  let cursor = 0, nextID = 0, prefix = '';
  const add = (node, original, tail = '') => {
    const origin = String(nextID++);
    node = node.type.create({...node.attrs, origin}, node.content, node.marks);
    content.push(node); originals.set(origin, {node, source: original, tail});
  };
  if (!ranges.length) {
    if (source.trim()) add(raw(source, frontmatterEnd ? '笔记属性 · 可在源码模式编辑' : '引用定义 · 可在源码模式编辑'), source);
    else if (source) add(schema.nodes.paragraph.create(), source);
  } else {
    // Fail closed instead of silently dropping unsupported parsed blocks.
    if (parsed.childCount !== ranges.length) throw new Error('Markdown 结构无法安全转换，请使用源码模式');
    ranges.forEach(([start, end], index) => {
      const gap = lines.slice(cursor, start).join('');
      if (gap.trim()) add(raw(gap, cursor === 0 && frontmatterEnd ? '笔记属性 · 可在源码模式编辑' : '引用定义 · 可在源码模式编辑'), gap);
      else if (gap && content.length) {
        const last = originals.get(content.at(-1).attrs.origin); last.source += gap; last.tail += gap;
      } else if (gap) prefix = gap;
      const original = lines.slice(start, end).join('');
      const newline = original.match(/(?:\r\n|\r|\n)$/)?.[0] || '';
      add(parsed.child(index), original, newline);
      cursor = end;
    });
    const rest = lines.slice(cursor).join('');
    if (rest.trim()) add(raw(rest, '引用定义 · 可在源码模式编辑'), rest);
    else if (rest) { const last = originals.get(content.at(-1).attrs.origin); last.source += rest; last.tail += rest; }
  }
  if (!content.length) content.push(schema.nodes.paragraph.create());
  const doc = schema.nodes.doc.create(null, content);
  doc.check();
  return {doc, originals, source, prefix, newline: source.includes('\r\n') ? '\r\n' : source.includes('\r') && !source.includes('\n') ? '\r' : '\n'};
}

export function saveMarkdown(doc, loaded) {
  if (doc.eq(loaded.doc)) return loaded.source;
  let result = loaded.prefix;
  doc.forEach((node, _, index) => {
    const original = loaded.originals.get(node.attrs.origin);
    let part;
    if (original && node.eq(original.node)) part = original.source;
    else {
      part = serializer.serialize(schema.nodes.doc.create(null, node)).replace(/\n/g, loaded.newline);
      part += original?.tail || '';
    }
    // A removed/inserted paragraph still needs a block boundary.
    if (index && result && part && !/(?:\r\n|\n|\r){2}$/.test(result)) {
      result += /[\r\n]$/.test(result) ? loaded.newline : loaded.newline + loaded.newline;
    }
    result += part;
  });
  return result;
}
