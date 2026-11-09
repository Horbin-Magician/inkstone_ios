import katex from 'katex';
import hljs from 'highlight.js/lib/common';
import swift from 'highlight.js/lib/languages/swift';
import rust from 'highlight.js/lib/languages/rust';
import kotlin from 'highlight.js/lib/languages/kotlin';
hljs.registerLanguage('swift', swift); hljs.registerLanguage('rust', rust); hljs.registerLanguage('kotlin', kotlin);
export const escapeHTML = text => text.replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
export const languageName = params => (params || '').trim().split(/\s+/)[0].toLowerCase();
export function highlighted(source, language) {
  return hljs.getLanguage(language) ? hljs.highlight(source, {language, ignoreIllegals: true}).value : escapeHTML(source);
}
export function renderMath(element, source, displayMode) {
  try { katex.render(source, element, {displayMode, throwOnError: true, trust: false, maxExpand: 1000, maxSize: 20, strict: 'ignore'}); }
  catch { element.textContent = source; element.classList.add('render-error'); element.title = '公式无法解析，请检查 LaTeX 语法'; }
}
let diagramRuntime;
export async function renderDiagram(element, source, isCurrent = () => true) {
  try {
    if (!diagramRuntime) diagramRuntime = new Promise((resolve, reject) => {
      const script = document.createElement('script'); script.src = 'diagrams.js';
      script.onload = resolve; script.onerror = reject; document.head.append(script);
    });
    await diagramRuntime;
    if (isCurrent()) await window.inkstoneRenderDiagram(element, source, isCurrent);
  } catch {
    if (isCurrent()) { element.textContent = '图表资源加载失败。\n' + source; element.classList.add('render-error'); }
  }
}
export function calloutColor(type) {
  if (/^(warning|caution|attention|question|help|faq)$/.test(type)) return 'amber';
  if (/^(danger|error|bug|failure|fail|missing)$/.test(type)) return 'red';
  if (/^(success|check|done|tip|hint|important)$/.test(type)) return 'green';
  if (/^(quote|cite)$/.test(type)) return 'gray';
  return 'blue';
}
