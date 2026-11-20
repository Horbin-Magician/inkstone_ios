import {extensionNodeViews, extensionDecorations} from './extension-views.js';
import {obsidianImage} from './model.js';
import {EditorState, TextSelection} from 'prosemirror-state';
import {EditorView} from 'prosemirror-view';
import {baseKeymap, toggleMark, setBlockType, wrapIn, lift, chainCommands, exitCode} from 'prosemirror-commands';
import {history, undo, redo} from 'prosemirror-history';
import {keymap} from 'prosemirror-keymap';
import {wrapInList, splitListItem, sinkListItem, liftListItem} from 'prosemirror-schema-list';
import {tableEditing, goToNextCell, addRowAfter, deleteRow, addColumnAfter, deleteColumn, deleteTable} from 'prosemirror-tables';
import {schema, loadMarkdown, saveMarkdown} from './model.js';
import {undoInputRule} from 'prosemirror-inputrules';
import {markdownInputRules} from './input-rules.js';

let loaded, view, session, revision = 0, lastSource, imageBookmark, composition = false;
let frozen = false, editorEnabled = true, imageContext = "";
let publishTimer, compositionTimer, blurTimer, toolbarTimer, lastToolbarJSON = '', serializedRevision = -1, serializedText;
const post = value => window.webkit?.messageHandlers.richEditor.postMessage({...value, session});
const editor = document.querySelector('#editor');
const status = document.querySelector('#status');
const commands = new Map();
let noteTitles = [], titlesDirty = false;
let linkEditRange = null;
function prepareTitles() {
  if (!titlesDirty) return;
  const options = document.createDocumentFragment();
  for (const title of noteTitles) {
    const option = document.createElement('option'); option.value = '[[' + title + ']]'; options.appendChild(option);
  }
  document.querySelector('#note-targets').replaceChildren(options);
  titlesDirty = false;
}

function snapshot() {
  if (serializedRevision !== revision) {
    serializedText = saveMarkdown(view.state.doc, loaded);
    serializedRevision = revision;
  }
  lastSource = serializedText;
  return {text: serializedText, composing: composition || view.composing, revision, session};
}
function schedulePublish() {
  // Bound latency during continuous typing while coalescing bursts of transactions.
  if (publishTimer == null) publishTimer = setTimeout(publish, 50);
}
function publish() {
  clearTimeout(publishTimer); publishTimer = null;
  if (!view) return;
  // Input notifications carry versions only. Native save/navigation explicitly
  // requests flush(), which is the sole full-text snapshot boundary.
  post({type: 'change', revision, composing: composition || view.composing});
}
function run(command) {
  if (!view || composition || view.composing) return;
  command(view.state, view.dispatch, view);
  view.focus();
}
function register(label, title, command) { commands.set(title, command); }
function canRun(title) {
  return !!view && !composition && !view.composing && !frozen && editorEnabled && !!commands.get(title)?.(view.state);
}
function block(type, attrs) { return setBlockType(schema.nodes[type], attrs); }
function list(type) {
  return (state, dispatch) => {
    for (let depth = state.selection.$from.depth; depth > 0; depth--) {
      if (state.selection.$from.node(depth).type === schema.nodes[type]) return liftListItem(schema.nodes.list_item)(state, dispatch);
    }
    return wrapInList(schema.nodes[type])(state, dispatch);
  };
}
function task(state, dispatch) {
  const {$from} = state.selection;
  for (let depth = $from.depth; depth > 0; depth--) {
    const node = $from.node(depth);
    if (node.type === schema.nodes.list_item) {
      if (dispatch) dispatch(state.tr.setNodeMarkup($from.before(depth), null, {...node.attrs, checked: node.attrs.checked == null ? false : null}));
      return true;
    }
  }
  return wrapInList(schema.nodes.bullet_list)(state, dispatch && (tr => {
    const pos = tr.selection.$from;
    for (let depth = pos.depth; depth > 0; depth--) {
      const node = pos.node(depth);
      if (node.type === schema.nodes.list_item) {
        tr.setNodeMarkup(pos.before(depth), null, {...node.attrs, checked: false}); break;
      }
    }
    dispatch(tr);
  }));
}
function linkRangeAt(state) {
  const {$from, $to, empty} = state.selection;
  const markType = schema.marks.link;
  if (!empty) return {from: $from.pos, to: $to.pos, mark: markType.isInSet($from.marks())};
  const parent = $from.parent;
  const offset = $from.parentOffset;
  const startPos = $from.start();
  let found = null;
  let pos = 0;
  for (let i = 0; i < parent.childCount; i++) {
    const child = parent.child(i);
    const nextPos = pos + child.nodeSize;
    const mark = markType.isInSet(child.marks);
    if (mark && offset >= pos && offset <= nextPos) {
      let left = pos, right = nextPos;
      for (let j = i - 1; j >= 0; j--) {
        const prev = parent.child(j);
        if (!prev.marks.some(m => m.eq(mark))) break;
        left -= prev.nodeSize;
      }
      for (let j = i + 1; j < parent.childCount; j++) {
        const next = parent.child(j);
        if (!next.marks.some(m => m.eq(mark))) break;
        right += next.nodeSize;
      }
      found = {from: startPos + left, to: startPos + right, mark};
      break;
    }
    pos = nextPos;
  }
  return found;
}
function inBlock(state, type, attrs) {
  const {$from} = state.selection;
  for (let depth = $from.depth; depth > 0; depth--) {
    const node = $from.node(depth);
    if (node.type === type) {
      if (!attrs) return true;
      return Object.entries(attrs).every(([k, v]) => node.attrs[k] === v);
    }
  }
  return false;
}
function markActive(state, markType) {
  const {from, $from, to, empty} = state.selection;
  if (empty) return !!markType.isInSet(state.storedMarks || $from.marks());
  return state.doc.rangeHasMark(from, to, markType);
}
function toolbarSnapshot() {
  if (!view) return null;
  const state = view.state;
  const enabled = {};
  for (const title of commands.keys()) enabled[title] = canRun(title);
  const active = {
    '1 级标题': inBlock(state, schema.nodes.heading, {level: 1}),
    '2 级标题': inBlock(state, schema.nodes.heading, {level: 2}),
    '3 级标题': inBlock(state, schema.nodes.heading, {level: 3}),
    '加粗': markActive(state, schema.marks.strong),
    '斜体': markActive(state, schema.marks.em),
    '删除线': markActive(state, schema.marks.strike),
    '行内代码': markActive(state, schema.marks.code),
    '无序列表': inBlock(state, schema.nodes.bullet_list),
    '有序列表': inBlock(state, schema.nodes.ordered_list),
    '引用': inBlock(state, schema.nodes.blockquote),
    '代码块': inBlock(state, schema.nodes.code_block),
    '取消链接': !!linkRangeAt(state)?.mark,
    '表格': inBlock(state, schema.nodes.table)
  };
  return {enabled, active};
}
function scheduleToolbarState() {
  if (toolbarTimer != null) return;
  const currentSession = session;
  toolbarTimer = setTimeout(() => {
    toolbarTimer = null;
    if (!view || currentSession !== session) return;
    const state = toolbarSnapshot();
    if (!state) return;
    const serialized = JSON.stringify(state);
    if (serialized === lastToolbarJSON) return;
    lastToolbarJSON = serialized;
    post({type: 'toolbar', ...state});
  }, 60);
}
function isSafeLinkURL(url) {
  if (!url || /[\x00-\x1f\x7f]/.test(url)) return false;
  if (/^\[\[[^\]\n]+\]\]$/.test(url)) return true;
  if (/^https?:\/\//i.test(url) || /^mailto:/i.test(url) || url.startsWith('#')) return true;
  if (url.startsWith('//')) return false;
  if (/^[a-z][a-z0-9+.-]*:/i.test(url)) return false;
  return true;
}
function deleteBodyRow(state, dispatch) {
  const {$from} = state.selection;
  for (let depth = $from.depth; depth > 0; depth--) {
    if ($from.node(depth).type === schema.nodes.table_row) {
      if ($from.index(depth - 1) === 0) return false;
      break;
    }
  }
  return deleteRow(state, dispatch);
}
register('正文', '正文', block('paragraph'));
for (let level = 1; level <= 3; level++) register('H' + level, level + ' 级标题', block('heading', {level}));
for (const [name, label, title] of [['strong', 'B', '加粗'], ['em', 'I', '斜体'], ['strike', 'S', '删除线'], ['code', '</>', '行内代码']]) {
  register(label, title, toggleMark(schema.marks[name]));
}
register('• 列表', '无序列表', list('bullet_list'));
register('1. 列表', '有序列表', list('ordered_list'));
register('☑ 待办', '待办列表', task);
register('引用', '引用', (state, dispatch) => {
  if (inBlock(state, schema.nodes.blockquote)) return lift(state, dispatch);
  return wrapIn(schema.nodes.blockquote)(state, dispatch);
});
register('代码块', '代码块', block('code_block'));
register('缩进', '增加列表缩进', sinkListItem(schema.nodes.list_item));
register('退格', '减少列表缩进', liftListItem(schema.nodes.list_item));
register('链接', '插入或修改链接', (state, dispatch) => {
  if (!dispatch) return true;
  const dialog = document.querySelector('#link-dialog');
  const existing = linkRangeAt(state);
  linkEditRange = existing?.mark ? {from: existing.from, to: existing.to} : null;
  document.querySelector('#link-error').textContent = '';
  document.querySelector('#link-url').value = existing?.mark?.attrs.href || '';
  document.querySelector('#link-label').value = linkEditRange
    ? state.doc.textBetween(linkEditRange.from, linkEditRange.to)
    : state.doc.textBetween(state.selection.from, state.selection.to);
  prepareTitles();
  dialog.showModal();
  return true;
});
register('取消链接', '取消链接', (state, dispatch) => {
  const existing = linkRangeAt(state);
  if (!existing?.mark) return false;
  if (dispatch) dispatch(state.tr.removeMark(existing.from, existing.to, schema.marks.link));
  return true;
});
register('表格', '插入表格', (state, dispatch) => {
  if (dispatch) {
    const row = header => schema.nodes.table_row.create(null, Array.from({length: 2}, () =>
      (header ? schema.nodes.table_header : schema.nodes.table_cell).create(null, schema.nodes.paragraph.create())));
    dispatch(state.tr.replaceSelectionWith(schema.nodes.table.create(null, [row(true), row(false)])).scrollIntoView());
  }
  return true;
});
register('+行', '表格添加行', addRowAfter);
register('+列', '表格添加列', addColumnAfter);
register('删行', '表格删除行', deleteBodyRow);
register('删列', '表格删除列', deleteColumn);
register('删表', '删除表格', deleteTable);
register('撤销', '撤销', undo);
register('重做', '重做', redo);
register('完成', '收起键盘', (state, dispatch) => {
  if (dispatch) { view.dom.blur(); post({type: 'focus', focused: false}); }
  return true;
});

document.querySelector('#link-form').addEventListener('submit', event => {
  event.preventDefault();
  const errorEl = document.querySelector('#link-error');
  const url = document.querySelector('#link-url').value.trim();
  const rawLabel = document.querySelector('#link-label').value;
  const label = rawLabel || url;
  if (!isSafeLinkURL(url)) {
    errorEl.textContent = '请输入网页地址、相对路径或 [[笔记路径]]。'; return;
  }
  const wiki = /^\[\[([^\]\n]+)\]\]$/.exec(url);
  if (wiki) {
    const sep = wiki[1].indexOf('|');
    const target = (sep < 0 ? wiki[1] : wiki[1].slice(0, sep)).trim();
    const alias = sep < 0 ? '' : wiki[1].slice(sep + 1);
    if (!target) { errorEl.textContent = '请输入有效的 [[笔记路径]]。'; return; }
    const displayLabel = (alias || (label === url ? target : label)).replace(/\]/g, '');
    const tr = view.state.tr;
    if (linkEditRange) tr.replaceWith(linkEditRange.from, linkEditRange.to, schema.nodes.wiki.create({target, label: displayLabel}));
    else tr.replaceSelectionWith(schema.nodes.wiki.create({target, label: displayLabel}));
    view.dispatch(tr);
  } else {
    const linkMark = schema.marks.link.create({href: url});
    const range = linkEditRange || (view.state.selection.empty ? null : {from: view.state.selection.from, to: view.state.selection.to});
    if (!range) {
      view.dispatch(view.state.tr.replaceSelectionWith(schema.text(label, [linkMark]), false));
    } else {
      const originalText = view.state.doc.textBetween(range.from, range.to);
      if (rawLabel && rawLabel !== originalText) {
        view.dispatch(view.state.tr.replaceWith(range.from, range.to, schema.text(rawLabel, [linkMark])));
      } else {
        view.dispatch(view.state.tr.addMark(range.from, range.to, linkMark));
      }
    }
  }
  errorEl.textContent = '';
  linkEditRange = null;
  document.querySelector('#link-dialog').close(); view.focus();
});
document.querySelector('#cancel-link').onclick = () => {
  document.querySelector('#link-error').textContent = '';
  linkEditRange = null;
  document.querySelector('#link-dialog').close(); view.focus();
};

function imageURL(source) {
  const trimmed = (source || '').trim();
  if (!trimmed || trimmed.startsWith('//')) return '';
  if (/^[a-z][a-z0-9+.-]*:/i.test(trimmed) && !/^https?:\/\//i.test(trimmed) && !trimmed.startsWith('inkstone-embed:')) return '';
  return 'inkstone-attachment://file?source=' + encodeURIComponent(trimmed) + '&context=' + encodeURIComponent(imageContext);
}
function imageView(node) {
  const dom = document.createElement('img');
  dom.dataset.attachmentSource = node.attrs.src;
  dom.src = imageURL(node.attrs.src); dom.alt = node.attrs.alt || '图片'; dom.title = node.attrs.title || '';
  if (node.attrs.src.startsWith('inkstone-embed:')) {
    const image = obsidianImage(decodeURIComponent(node.attrs.src.slice('inkstone-embed:'.length)));
    if (image?.width) dom.style.width = image.width + 'px';
    if (image?.height) { dom.style.maxHeight = image.height + 'px'; dom.style.objectFit = 'contain'; }
  }
  return {dom};
}
function itemView(node, editorView, getPos) {
  const dom = document.createElement('li'), contentDOM = document.createElement('div');
  let checkbox = null;
  function syncTask(current) {
    if (current.attrs.checked != null) {
      dom.className = 'task';
      if (!checkbox) {
        checkbox = document.createElement('input'); checkbox.type = 'checkbox';
        checkbox.contentEditable = 'false'; checkbox.setAttribute('aria-label', '完成待办');
        checkbox.addEventListener('change', () => {
          const pos = getPos(); if (typeof pos !== 'number') return;
          const item = editorView.state.doc.nodeAt(pos);
          if (!editorView.editable) { checkbox.checked = !!item?.attrs.checked; return; }
          editorView.dispatch(editorView.state.tr.setNodeMarkup(pos, null, {...item.attrs, checked: checkbox.checked}));
        });
        dom.insertBefore(checkbox, contentDOM);
      }
      checkbox.checked = current.attrs.checked;
      checkbox.disabled = !editorView.editable;
    } else {
      dom.className = '';
      if (checkbox) { checkbox.remove(); checkbox = null; }
    }
  }
  dom.appendChild(contentDOM);
  syncTask(node);
  return {
    dom,
    contentDOM,
    update(next) {
      if (next.type !== node.type) return false;
      node = next;
      syncTask(next);
      return true;
    }
  };
}

function exitCodeOnEmptyTrailingLine(state, dispatch) {
  const {$from, empty} = state.selection;
  if (!empty || !$from.parent.type.spec.code) return false;
  if ($from.parentOffset === $from.parent.content.size && $from.parent.textContent.endsWith('\n')) {
    if (dispatch) {
      const tr = state.tr.delete($from.pos - 1, $from.pos);
      const after = tr.doc.resolve(tr.selection.from).after();
      const paragraph = schema.nodes.paragraph.create();
      tr.insert(after, paragraph);
      tr.setSelection(TextSelection.create(tr.doc, after + 1));
      dispatch(tr.scrollIntoView());
    }
    return true;
  }
  return false;
}

function initialize(source, token, initialRevision = 0, context = imageContext) {
  frozen = false; imageContext = context;
  clearTimeout(publishTimer); publishTimer = null;
  clearTimeout(compositionTimer); compositionTimer = null;
  clearTimeout(blurTimer); blurTimer = null;
  clearTimeout(toolbarTimer); toolbarTimer = null;
  lastToolbarJSON = '';
  serializedRevision = -1;
  try {
    loaded = loadMarkdown(source); revision = token === session ? revision + 1 : initialRevision;
    session = token; lastSource = source; serializedRevision = revision; serializedText = source; composition = false; imageBookmark = null;
    if (view) view.destroy();
    view = new EditorView(editor, {
      state: EditorState.create({doc: loaded.doc, plugins: [history(), extensionDecorations(), markdownInputRules(), keymap({
        Backspace: undoInputRule,
        'Mod-z': undo, 'Mod-y': redo, 'Shift-Mod-z': redo,
        'Mod-b': toggleMark(schema.marks.strong), 'Mod-i': toggleMark(schema.marks.em),
        Enter: (state, dispatch) => {
          if (exitCodeOnEmptyTrailingLine(state, dispatch)) return true;
          const {$from} = state.selection;
          const item = $from.depth >= 2 ? $from.node($from.depth - 1) : null;
          return splitListItem(schema.nodes.list_item, {checked: item?.attrs.checked == null ? null : false})(state, dispatch);
        },
        Tab: chainCommands(goToNextCell(1), sinkListItem(schema.nodes.list_item)),
        'Shift-Tab': chainCommands(goToNextCell(-1), liftListItem(schema.nodes.list_item)),
        'Shift-Enter': chainCommands(exitCode, (state, dispatch) => {
          if (dispatch) dispatch(state.tr.replaceSelectionWith(schema.nodes.hard_break.create()).scrollIntoView()); return true;
        })
      }), keymap(baseKeymap), tableEditing()] }),
      attributes: {role: 'textbox', 'aria-label': '富文本正文', 'aria-multiline': 'true', spellcheck: 'true'},
      nodeViews: {...extensionNodeViews, image: imageView, list_item: itemView},
      dispatchTransaction(tr) {
        if (imageBookmark) imageBookmark = imageBookmark.map(tr.mapping);
        const result = view.state.applyTransaction(tr);
        view.updateState(result.state);
        if (result.transactions.some(transaction => transaction.docChanged)) { revision++; schedulePublish(); }
        scheduleToolbarState();
      },
      handlePaste(editorView, event) {
        const file = Array.from(event.clipboardData?.files || []).find(file => file.type.startsWith('image/'));
        if (!file) return false;
        event.preventDefault();
        if (file.size > 32 * 1024 * 1024 || imageBookmark) { status.textContent = '图片过大或上一张图片仍在插入'; return true; }
        imageBookmark = editorView.state.selection.getBookmark();
        const pasteSession = session;
        const reader = new FileReader();
        reader.onload = () => { if (pasteSession === session) post({type: 'image', data: reader.result, mime: file.type}); };
        reader.onerror = () => { imageBookmark = null; status.textContent = '图片读取失败'; };
        reader.readAsDataURL(file);
        return true;
      },
      handleDOMEvents: {
        compositionstart() { composition = true; post({type: 'composition', composing: true}); return false; },
        compositionend() {
          const currentSession = session;
          clearTimeout(compositionTimer);
          compositionTimer = setTimeout(() => {
            compositionTimer = null;
            if (currentSession !== session) return;
            composition = false; publish();
          }, 0);
          return false;
        },
        focus() { post({type: 'focus', focused: true}); scheduleToolbarState(); return false; },
        blur() {
          const currentSession = session;
          clearTimeout(blurTimer);
          blurTimer = setTimeout(() => {
            blurTimer = null;
            if (currentSession !== session) return;
            publish();
          }, 0);
          post({type: 'focus', focused: false});
          return false;
        },
        click(_, event) { if (event.target.closest('a')) event.preventDefault(); return false; }
      }
    });
    status.textContent = '';
    scheduleToolbarState();
    return true;
  } catch (error) {
    if (view) view.destroy();
    view = null; editor.replaceChildren(); session = token;
    status.textContent = '富文本加载失败，请切换到源码编辑。';
    post({type: 'error', message: String(error)}); return false;
  }
}

window.inkstone = {
  applyUpdates(updates) {
    for (const [name, args] of updates) window.inkstone[name](...args);
  },
  load: initialize,
  flush: (freeze = false) => {
    if (!view) return null;
    if (freeze && !composition && !view.composing) {
      frozen = true;
      window.inkstone.setEnabled(editorEnabled);
    }
    publish(); return snapshot();
  },
  releaseSnapshot() { frozen = false; window.inkstone.setEnabled(editorEnabled); },
  setSource(source, token) {
    if (token === session && source === lastSource) return;
    // External appends (photos/attachments) are undoable and keep the selection.
    if (view && token === session && lastSource && lastSource.length > 0 && serializedRevision === revision && source.startsWith(lastSource) && !view.composing) {
      try {
        const suffix = source.slice(lastSource.length);
        const parsed = loadMarkdown(suffix).doc;
        const children = [];
        parsed.forEach(node => children.push(node.type.create({...node.attrs, origin: null}, node.content, node.marks)));
        const addition = schema.nodes.doc.create(null, children);
        view.dispatch(view.state.tr.insert(view.state.doc.content.size, addition.content));
        return;
      } catch {
        // Fall back to full reload if incremental suffix cannot be parsed standalone.
      }
    }
    initialize(source, token);
  },
  focus(focused) { if (view) { if (focused) view.focus(); else view.dom.blur(); } },
  setEnabled(enabled) {
    editorEnabled = enabled;
    if (view) {
      const editable = enabled && !frozen;
      view.setProps({editable: () => editable});
      view.dom.querySelectorAll('li.task > input[type=checkbox]').forEach(el => { el.disabled = !editable; });
      scheduleToolbarState();
    }
  },
  setPalette(colors) {
    if (typeof colors.dark === 'boolean') {
      document.documentElement.dataset.theme = colors.dark ? 'dark' : 'light';
    }
    for (const key of ['accent', 'background', 'text', 'muted', 'line', 'panel', 'inline-code']) {
      if (colors[key]) document.documentElement.style.setProperty('--' + key, colors[key]);
    }
  },
  setAppearance(size, spacing) { document.documentElement.style.setProperty('--body-size', size + 'px'); document.documentElement.style.setProperty('--text-scale', size / 17); document.documentElement.style.setProperty('--line-spacing', spacing + 'px'); },
  setImageContext(context) {
    if (context === imageContext) return;
    imageContext = context;
    view?.dom.querySelectorAll('img[data-attachment-source]').forEach(img => { img.src = imageURL(img.dataset.attachmentSource); });
  },
  setTitles(titles) {
    noteTitles = titles; titlesDirty = true;
    if (document.querySelector('#link-dialog').open) prepareTitles();
  },
  insertImage(path) {
    if (!imageBookmark || !view) return;
    if (path) {
      const selection = imageBookmark.resolve(view.state.doc);
      view.dispatch(view.state.tr.setSelection(selection).replaceSelectionWith(schema.nodes.image.create({src: path, alt: '图片'})).scrollIntoView());
    }
    imageBookmark = null;
  },
  canRun,
  command(title) { if (!canRun(title)) return false; run(commands.get(title)); return true; },
  // The test harness uses the same commands and state as the shipped editor.
  get view() { return view; },
  select(from, to = from) { view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, from, to))); }
};
post({type: 'ready'});
