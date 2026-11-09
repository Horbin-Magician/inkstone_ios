import {renderMath, renderDiagram, highlighted, languageName} from './rendering.js';
const root = document.querySelector('main');
let revision = 0;
function reportHeight() {
  window.webkit?.messageHandlers.renderHeight.postMessage({revision, height: Math.ceil(root.getBoundingClientRect().height)});
}
new ResizeObserver(reportHeight).observe(root);
root.addEventListener('click', event => {
  const link = event.target.closest('a');
  if (!link) return;
  event.preventDefault();
  window.webkit?.messageHandlers.renderHeight.postMessage({revision, href: link.getAttribute('href')});
});
window.renderFragment = async payload => {
  const current = revision = payload.revision;
  document.documentElement.style.fontSize = payload.fontSize + 'px';
  document.documentElement.style.colorScheme = payload.dark ? 'dark' : 'light';
  document.body.style.color = payload.dark ? '#eee' : '#202423';
  if (payload.kind === 'code') {
    const language = languageName(payload.language);
    root.replaceChildren();
    if (language === 'mermaid') {
      const diagram = document.createElement('div'); diagram.className = 'diagram-preview'; root.append(diagram);
      await renderDiagram(diagram, payload.source, () => current === revision);
    } else if (['math', 'latex', 'tex'].includes(language)) {
      const math = document.createElement('div'); root.append(math); renderMath(math, payload.source, true);
    } else {
      const pre = document.createElement('pre'), code = document.createElement('code');
      code.innerHTML = highlighted(payload.source.replace(/\n$/, ''), language); pre.append(code); root.append(pre);
    }
  } else {
    // HTML comes exclusively from escaped native presentation nodes, never note HTML.
    root.innerHTML = payload.html;
    for (const math of root.querySelectorAll('[data-tex]')) renderMath(math, math.dataset.tex, math.dataset.display === 'true');
  }
  if (current === revision) { await document.fonts.ready; reportHeight(); }
};
