import {Plugin, TextSelection} from 'prosemirror-state';
import {Decoration, DecorationSet} from 'prosemirror-view';
import {renderMath, renderDiagram, highlighted, languageName, calloutColor} from './rendering.js';

function isDarkTheme() {
  const theme = document.documentElement.dataset.theme;
  if (theme === 'dark') return true;
  if (theme === 'light') return false;
  return window.matchMedia?.('(prefers-color-scheme: dark)').matches || false;
}

function mathView(node, view, getPos) {
  const display = node.type.name === 'math_block';
  const dom = document.createElement(display ? 'div' : 'span'); dom.className = display ? 'math-block math-node' : 'math-inline math-node';
  const preview = document.createElement('span'); preview.className = 'math-preview'; preview.contentEditable = 'false'; preview.title = '点击编辑公式';
  const contentDOM = document.createElement('code'); contentDOM.className = 'math-source';
  dom.append(preview, contentDOM);
  preview.addEventListener('mousedown', event => {
    const pos = getPos(); if (typeof pos !== 'number' || !view.editable) return;
    event.preventDefault(); view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, pos + 1))); view.focus();
  });
  const render = current => {
    preview.classList.remove('render-error');
    if (!current.textContent.trim()) {
      preview.textContent = display ? '公式（点击编辑）' : '公式';
      return;
    }
    renderMath(preview, current.textContent, display);
  };
  render(node);
  return {dom, contentDOM, update(next) {
    if (next.type !== node.type) return false;
    const changed = next.textContent !== node.textContent;
    node = next;
    if (changed) render(next);
    return true;
  }, ignoreMutation: event => event.type !== 'selection' && !contentDOM.contains(event.target) && event.target !== contentDOM};
}
function codeView(node) {
  const dom = document.createElement('div'); dom.className = 'code-node';
  const preview = document.createElement('div'); preview.className = 'diagram-preview'; preview.contentEditable = 'false';
  const pre = document.createElement('pre'), contentDOM = document.createElement('code'); pre.append(contentDOM); dom.append(preview, pre);
  let version = 0, timer;
  function render(next) {
    const language = languageName(next.attrs.params); dom.dataset.language = language;
    preview.hidden = !['mermaid', 'math', 'latex', 'tex'].includes(language);
    const current = ++version; clearTimeout(timer);
    if (['math', 'latex', 'tex'].includes(language)) renderMath(preview, next.textContent, true);
    if (language === 'mermaid') timer = setTimeout(() => renderDiagram(preview, next.textContent, () => current === version, isDarkTheme()), 200);
  }
  render(node);
  return {dom, contentDOM, update(next) { if (next.type !== node.type) return false; if (!next.eq(node)) render(next); node = next; return true; },
    destroy() { version++; clearTimeout(timer); },
    ignoreMutation: event => event.type !== 'selection' && !contentDOM.contains(event.target) && event.target !== contentDOM};
}
function quoteView(node, view, getPos) {
  const callout = node.attrs.callout;
  const dom = document.createElement(callout ? 'aside' : 'blockquote');
  const contentDOM = document.createElement('div');
  if (callout) {
    dom.className = 'callout ' + calloutColor(callout.type); dom.dataset.callout = callout.type;
    const header = document.createElement(callout.fold ? 'button' : 'div'); header.className = 'callout-title'; header.contentEditable = 'false';
    header.textContent = callout.title; dom.append(header);
    if (callout.fold) {
      const pos = typeof getPos === 'function' ? getPos() : null;
      const selectionInside = typeof pos === 'number' && view?.state.selection.from >= pos && view?.state.selection.to <= pos + node.nodeSize;
      contentDOM.hidden = callout.fold === '-' && !selectionInside;
      header.setAttribute('aria-expanded', String(!contentDOM.hidden));
      header.onclick = () => { contentDOM.hidden = !contentDOM.hidden; header.setAttribute('aria-expanded', String(!contentDOM.hidden)); };
    }
  }
  dom.append(contentDOM);
  return {dom, contentDOM, ignoreMutation: event => event.type === 'attributes' && (event.target === contentDOM || !contentDOM.contains(event.target))};
}
export const extensionNodeViews = {math_inline: mathView, math_block: mathView, code_block: codeView, blockquote: quoteView};
const highlights = new WeakMap();
function codeSpans(node) {
  if (highlights.has(node)) return highlights.get(node);
  const root = document.createElement('div'); root.innerHTML = highlighted(node.textContent, languageName(node.attrs.params));
  const spans = []; let offset = 0;
  function walk(element, classes = '') {
    if (element.nodeType === Node.TEXT_NODE) {
      const end = offset + element.textContent.length;
      if (classes && end > offset) spans.push([offset, end, classes]); offset = end; return;
    }
    for (const child of element.childNodes) walk(child, [classes, element.className || ''].filter(Boolean).join(' '));
  }
  walk(root); highlights.set(node, spans); return spans;
}
function buildCodeDecorations(doc) {
  const decorations = [];
  doc.descendants((node, pos) => {
    if (node.type.name === 'code_block') {
      for (const [from, to, classes] of codeSpans(node)) decorations.push(Decoration.inline(pos + 1 + from, pos + 1 + to, {class: classes}));
      return false;
    }
  });
  return DecorationSet.create(doc, decorations);
}
function editingMathDecoration(state) {
  const {$from, $to} = state.selection;
  for (let depth = $from.depth; depth > 0; depth--) {
    const node = $from.node(depth);
    if (node.type.name === 'math_inline' || node.type.name === 'math_block') {
      const pos = $from.before(depth);
      if ($to.pos <= pos + node.nodeSize) {
        return Decoration.node(pos, pos + node.nodeSize, {class: 'editing-math'});
      }
      break;
    }
  }
  return null;
}
export function extensionDecorations() {
  return new Plugin({
    state: {
      init(_, state) {
        return {code: buildCodeDecorations(state.doc)};
      },
      apply(tr, value, _oldState, newState) {
        if (!tr.docChanged) return value;
        // Recompute only when a code_block was touched; otherwise map existing decorations.
        let codeTouched = false;
        let hasCode = false;
        newState.doc.descendants(node => {
          if (node.type.name === 'code_block') {
            hasCode = true;
            if (!highlights.has(node)) codeTouched = true;
            return false;
          }
        });
        if (!hasCode) return {code: DecorationSet.empty};
        if (codeTouched) return {code: buildCodeDecorations(newState.doc)};
        return {code: value.code.map(tr.mapping, newState.doc)};
      }
    },
    props: {
      decorations(state) {
        const pluginState = this.getState(state);
        const mathDeco = editingMathDecoration(state);
        if (!mathDeco) return pluginState.code;
        return pluginState.code.add(state.doc, [mathDeco]);
      }
    }
  });
}
