// Markdown syntax only; shared by the editor parser and the read-only renderer.
export function markdownExtensions(md) {
  md.inline.ruler.before('escape', 'math_inline', (state, silent) => {
    if (state.src[state.pos] !== '$' || state.src[state.pos + 1] === '$') return false;
    const start = state.pos + 1;
    if (/\s/.test(state.src[start] || ' ')) return false;
    let end = start;
    while ((end = state.src.indexOf('$', end)) >= 0) {
      let escapes = 0; for (let i = end - 1; i >= start && state.src[i] === '\\'; i--) escapes++;
      if (!(escapes % 2)) break;
      end++;
    }
    if (end <= start || /\s/.test(state.src[end - 1]) || /\d/.test(state.src[end + 1] || '') || state.src.slice(start, end).includes('\n')) return false;
    if (!silent) { const token = state.push('math_inline', 'math', 0); token.content = state.src.slice(start, end); }
    state.pos = end + 1; return true;
  });
  md.block.ruler.before('fence', 'math_block', (state, start, end, silent) => {
    const line = i => state.src.slice(state.bMarks[i] + state.tShift[i], state.eMarks[i]);
    if (state.sCount[start] - state.blkIndent >= 4 || !line(start).startsWith('$$')) return false;
    let text = line(start).slice(2), next = start + 1;
    if (text.trimEnd().endsWith('$$')) text = text.trimEnd().slice(0, -2);
    else {
      let found = false;
      for (; next < end; next++) {
        if (state.sCount[next] < state.blkIndent) break;
        const value = line(next);
        if (value.trimEnd().endsWith('$$')) { text += '\n' + value.trimEnd().slice(0, -2); next++; found = true; break; }
        text += '\n' + value;
      }
      if (!found) return false;
    }
    if (silent) return true;
    const token = state.push('math_block', 'math', 0); token.block = true; token.content = text.trim(); token.map = [start, next];
    state.line = next; return true;
  }, {alt: ['paragraph', 'reference', 'blockquote', 'list']});
  md.core.ruler.after('inline', 'callouts', state => {
    state.tokens.forEach((token, index, tokens) => {
      if (token.type !== 'blockquote_open' || tokens[index + 1]?.type !== 'paragraph_open') return;
      const inline = tokens[index + 2];
      const match = /^\[!([\w-]+)\]([+-])?(?:[ \t]+([^\n]*))?(?:\n|$)/.exec(inline?.content || '');
      if (!match) return;
      token.meta = {...token.meta, callout: {type: match[1].toLowerCase(), fold: match[2] || '', title: match[3] || match[1].toUpperCase()}};
      inline.content = inline.content.slice(match[0].length);
      inline.children = []; state.md.inline.parse(inline.content, state.md, state.env, inline.children);
    });
  });
}
