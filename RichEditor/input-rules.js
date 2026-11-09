import {InputRule, inputRules, wrappingInputRule, textblockTypeInputRule} from 'prosemirror-inputrules';
import {schema} from './model.js';

export function markdownInputRules() {
  const {paragraph, bullet_list, ordered_list, blockquote, heading, code_block, list_item, horizontal_rule} = schema.nodes;
  const bullet = wrappingInputRule(/^ {0,3}[-+*] $/, bullet_list);
  const rules = [
    new InputRule(/\$([^\s$](?:[^$\n]*?[^\s$])?)\$$/, (state, match, start, end) => {
      if (start > 0 && state.doc.textBetween(start - 1, start) === '\\') return null;
      return state.tr.replaceWith(start, end, schema.nodes.math_inline.create(null, schema.text(match[1])));
    }),
    textblockTypeInputRule(/^\$\$ $/, schema.nodes.math_block),
    new InputRule(/^\[!([\w-]+)\]([+-])? $/, (state, match, start, end) => {
      const pos = state.selection.$from;
      if (pos.depth < 2 || pos.node(-1).type !== blockquote || pos.index(-1) !== 0) return null;
      return state.tr.delete(start, end).setNodeMarkup(pos.before(pos.depth - 1), null,
        {...pos.node(-1).attrs, callout: {type: match[1].toLowerCase(), fold: match[2] || '', title: match[1].toUpperCase()}});
    }),
    bullet,
    wrappingInputRule(/^ {0,3}(\d{1,9})[.)] $/, ordered_list,
      match => ({order: Number(match[1])}),
      (match, node) => node.attrs.order + node.childCount === Number(match[1])),
    wrappingInputRule(/^ {0,3}> $/, blockquote),
    textblockTypeInputRule(/^ {0,3}(#{1,6}) $/, heading, match => ({level: match[1].length})),
    textblockTypeInputRule(/^ {0,3}(?:```|~~~)([\w+-]*) $/, code_block, match => ({params: match[1]})),
    new InputRule(/^ {0,3}(?:\*\*\*|---|___) $/, (state, match, start, end) => {
      const $start = state.doc.resolve(start);
      if ($start.parentOffset !== 0 || end !== $start.end()) return null;
      return state.tr.replaceWith($start.before(), $start.after(), [horizontal_rule.create(), paragraph.create()]);
    }),
    // Normally the bullet has already converted before the checkbox is typed.
    // Also accept a complete prefix committed in a single text-input event.
    new InputRule(/^(?: {0,3}[-+*] )?\[([ xX])\] $/, (state, match, start, end) => {
      let tr;
      if (/[-+*]/.test(match[0])) {
        tr = bullet.handler(state, match, start, end);
        if (!tr) return null;
      } else {
        const $start = state.doc.resolve(start);
        if ($start.depth < 2 || $start.node(-1).type !== list_item || $start.index(-1) !== 0) return null;
        tr = state.tr.delete(start, end);
      }
      const $pos = tr.selection.$from;
      return tr.setNodeMarkup($pos.before($pos.depth - 1), null,
        {...$pos.node(-1).attrs, checked: match[1].toLowerCase() === 'x'});
    })
  ];
  // Only paragraph prefixes are shortcuts; headings and inline code stay literal.
  for (const rule of rules) {
    const handler = rule.handler;
    rule.inCodeMark = false;
    rule.handler = (state, ...args) => state.selection.$from.parent.type === paragraph ? handler(state, ...args) : null;
  }
  return inputRules({rules});
}
