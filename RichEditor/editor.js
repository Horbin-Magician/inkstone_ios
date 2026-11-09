import {EditorState, TextSelection} from 'prosemirror-state';
import {EditorView} from 'prosemirror-view';
import {baseKeymap, toggleMark, setBlockType, wrapIn, lift, chainCommands, exitCode} from 'prosemirror-commands';
import {history, undo, redo} from 'prosemirror-history';
import {keymap} from 'prosemirror-keymap';
import {wrapInList, splitListItem, sinkListItem, liftListItem} from 'prosemirror-schema-list';
import {tableEditing, goToNextCell, addRowAfter, deleteRow, addColumnAfter, deleteColumn, deleteTable} from 'prosemirror-tables';
import {schema, loadMarkdown, saveMarkdown} from './model.js';

let loaded, view, session, revision = 0, lastSource, imageBookmark, composition = false;
let frozen = false, editorEnabled = true;
let publishTimer, serializedRevision = -1, serializedText;
const post = value => window.webkit?.messageHandlers.richEditor.postMessage({...value, session});
const editor = document.querySelector('#editor');
const toolbar = document.querySelector('#toolbar');
const status = document.querySelector('#status');
const buttons = new Map();

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
  updateToolbar();
}
function publish() {
  clearTimeout(publishTimer); publishTimer = null;
  if (!view) return;
  // Input notifications carry versions only. Native save/navigation explicitly
  // requests flush(), which is the sole full-text snapshot boundary.
  post({type: 'change', revision, composing: composition || view.composing});
  updateToolbar();
}
function run(command) {
  if (!view || composition || view.composing) return;
  command(view.state, view.dispatch, view);
  view.focus();
}
function button(label, title, command, active) {
  const element = document.createElement('button');
  element.type = 'button'; element.textContent = label; element.title = title; element.setAttribute('aria-label', title);
  element.addEventListener('pointerdown', event => event.preventDefault());
  element.addEventListener('click', () => run(command));
  toolbar.appendChild(element);
  buttons.set(title, {element, command, active});
}
function markActive(type) {
  const {from, to, empty, $from} = view.state.selection;
  return empty ? !!type.isInSet(view.state.storedMarks || $from.marks()) : view.state.doc.rangeHasMark(from, to, type);
}
function updateToolbar() {
  if (!view) return;
  buttons.forEach(({element, command, active}) => {
    element.disabled = composition || view.composing || !command(view.state);
    if (active) element.setAttribute('aria-pressed', String(active()));
  });
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
button('正文', '正文', block('paragraph'));
for (let level = 1; level <= 3; level++) button('H' + level, level + ' 级标题', block('heading', {level}));
for (const [name, label, title] of [['strong', 'B', '加粗'], ['em', 'I', '斜体'], ['strike', 'S', '删除线'], ['code', '</>', '行内代码']]) {
  button(label, title, toggleMark(schema.marks[name]), () => markActive(schema.marks[name]));
}
button('• 列表', '无序列表', list('bullet_list'));
button('1. 列表', '有序列表', list('ordered_list'));
button('☑ 待办', '待办列表', task);
button('引用', '引用', chainCommands(wrapIn(schema.nodes.blockquote), lift));
button('代码块', '代码块', block('code_block'));
button('缩进', '增加列表缩进', sinkListItem(schema.nodes.list_item));
button('退格', '减少列表缩进', liftListItem(schema.nodes.list_item));
button('链接', '插入或修改链接', (state, dispatch) => {
  if (!dispatch) return true;
  const dialog = document.querySelector('#link-dialog');
  const current = schema.marks.link.isInSet(state.selection.$from.marks());
  document.querySelector('#link-url').value = current?.attrs.href || '';
  document.querySelector('#link-label').value = state.doc.textBetween(state.selection.from, state.selection.to);
  dialog.showModal();
  return true;
});
button('取消链接', '取消链接', (state, dispatch) => {
  if (state.selection.empty) return false;
  if (dispatch) dispatch(state.tr.removeMark(state.selection.from, state.selection.to, schema.marks.link));
  return true;
});
button('表格', '插入表格', (state, dispatch) => {
  if (dispatch) {
    const row = header => schema.nodes.table_row.create(null, Array.from({length: 2}, () =>
      (header ? schema.nodes.table_header : schema.nodes.table_cell).create(null, schema.nodes.paragraph.create())));
    dispatch(state.tr.replaceSelectionWith(schema.nodes.table.create(null, [row(true), row(false)])).scrollIntoView());
  }
  return true;
});
button('+行', '表格添加行', addRowAfter);
button('+列', '表格添加列', addColumnAfter);
button('删行', '表格删除行', deleteRow);
button('删列', '表格删除列', deleteColumn);
button('删表', '删除表格', deleteTable);
button('撤销', '撤销', undo);
button('重做', '重做', redo);
button('完成', '收起键盘', (state, dispatch) => {
  if (dispatch) { view.dom.blur(); post({type: 'focus', focused: false}); }
  return true;
});
// run() normally restores the caret; the last action deliberately dismisses it.
buttons.get('收起键盘').element.addEventListener('click', () => view.dom.blur());

document.querySelector('#link-form').addEventListener('submit', event => {
  event.preventDefault();
  const url = document.querySelector('#link-url').value.trim();
  const label = document.querySelector('#link-label').value || url;
  if (!url || /^(?:javascript|data|file|vbscript):/i.test(url)) {
    document.querySelector('#link-error').textContent = '请输入网页地址、相对路径或 [[笔记路径]]。'; return;
  }
  const wiki = /^\[\[([^\]\n]+)\]\]$/.exec(url);
  if (wiki) {
    const [target, alias] = wiki[1].split('|', 2);
    view.dispatch(view.state.tr.replaceSelectionWith(schema.nodes.wiki.create({target, label: alias || (label === url ? target : label)})));
  } else if (view.state.selection.empty) {
    view.dispatch(view.state.tr.replaceSelectionWith(schema.text(label, [schema.marks.link.create({href: url})]), false));
  } else {
    view.dispatch(view.state.tr.addMark(view.state.selection.from, view.state.selection.to, schema.marks.link.create({href: url})));
  }
  document.querySelector('#link-dialog').close(); view.focus();
});
document.querySelector('#cancel-link').onclick = () => { document.querySelector('#link-dialog').close(); view.focus(); };

function imageURL(source) {
  if (/^https?:\/\//i.test(source)) return source;
  if (/^[a-z][a-z0-9+.-]*:/i.test(source)) return '';
  return 'inkstone-attachment://file?source=' + encodeURIComponent(source);
}
function imageView(node) {
  const dom = document.createElement('img');
  dom.src = imageURL(node.attrs.src); dom.alt = node.attrs.alt || '图片'; dom.title = node.attrs.title || '';
  return {dom};
}
function itemView(node, editorView, getPos) {
  const dom = document.createElement('li'), contentDOM = document.createElement('div');
  if (node.attrs.checked != null) {
    dom.className = 'task';
    const checkbox = document.createElement('input'); checkbox.type = 'checkbox'; checkbox.checked = node.attrs.checked;
    checkbox.contentEditable = 'false'; checkbox.setAttribute('aria-label', '完成待办');
    checkbox.addEventListener('change', () => {
      const pos = getPos(); if (typeof pos !== 'number') return;
      const item = editorView.state.doc.nodeAt(pos);
      editorView.dispatch(editorView.state.tr.setNodeMarkup(pos, null, {...item.attrs, checked: checkbox.checked}));
    });
    dom.appendChild(checkbox);
  }
  dom.appendChild(contentDOM);
  return {dom, contentDOM};
}

function initialize(source, token, initialRevision = 0) {
  frozen = false;
  clearTimeout(publishTimer); publishTimer = null; serializedRevision = -1;
  try {
    loaded = loadMarkdown(source); revision = token === session ? revision + 1 : initialRevision;
    session = token; lastSource = source; composition = false; imageBookmark = null;
    if (view) view.destroy();
    view = new EditorView(editor, {
      state: EditorState.create({doc: loaded.doc, plugins: [history(), keymap({
        'Mod-z': undo, 'Mod-y': redo, 'Shift-Mod-z': redo,
        'Mod-b': toggleMark(schema.marks.strong), 'Mod-i': toggleMark(schema.marks.em),
        Enter: (state, dispatch) => {
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
      nodeViews: {image: imageView, list_item: itemView},
      dispatchTransaction(tr) {
        if (imageBookmark) imageBookmark = imageBookmark.map(tr.mapping);
        const result = view.state.applyTransaction(tr);
        view.updateState(result.state);
        if (result.transactions.some(transaction => transaction.docChanged)) { revision++; schedulePublish(); }
        else updateToolbar();
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
        compositionstart() { composition = true; post({type: 'composition', composing: true}); updateToolbar(); return false; },
        compositionend() { setTimeout(() => { composition = false; publish(); }, 0); return false; },
        focus() { post({type: 'focus', focused: true}); return false; },
        blur() { setTimeout(publish, 0); post({type: 'focus', focused: false}); return false; },
        click(_, event) { if (event.target.closest('a')) event.preventDefault(); return false; }
      }
    });
    status.textContent = ''; updateToolbar();
    return true;
  } catch (error) {
    if (view) view.destroy();
    view = null; editor.replaceChildren(); session = token;
    buttons.forEach(({element}) => { element.disabled = true; });
    status.textContent = '富文本加载失败，请切换到源码编辑。';
    post({type: 'error', message: String(error)}); return false;
  }
}

window.inkstone = {
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
    if (view && token === session && source.startsWith(lastSource) && !view.composing) {
      const suffix = source.slice(lastSource.length);
      const parsed = loadMarkdown(suffix).doc;
      const children = [];
      parsed.forEach(node => children.push(node.type.create({...node.attrs, origin: null}, node.content, node.marks)));
      const addition = schema.nodes.doc.create(null, children);
      view.dispatch(view.state.tr.insert(view.state.doc.content.size, addition.content));
    } else initialize(source, token);
  },
  focus(focused) { if (view) { if (focused) view.focus(); else view.dom.blur(); } },
  setEnabled(enabled) { editorEnabled = enabled; if (view) view.setProps({editable: () => enabled && !frozen}); toolbar.inert = !enabled || frozen; },
  setAppearance(size, spacing) { document.documentElement.style.setProperty('--body-size', size + 'px'); document.documentElement.style.setProperty('--line-spacing', spacing + 'px'); },
  setTitles(titles) {
    const datalist = document.querySelector('#note-targets'); datalist.replaceChildren();
    for (const title of titles) { const option = document.createElement('option'); option.value = '[[' + title + ']]'; datalist.appendChild(option); }
  },
  insertImage(path) {
    if (!imageBookmark || !view) return;
    if (path) {
      const selection = imageBookmark.resolve(view.state.doc);
      view.dispatch(view.state.tr.setSelection(selection).replaceSelectionWith(schema.nodes.image.create({src: path, alt: '图片'})).scrollIntoView());
    }
    imageBookmark = null;
  },
  // The test harness uses the same commands and state as the shipped editor.
  get view() { return view; },
  select(from, to = from) { view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, from, to))); }
};
post({type: 'ready'});
