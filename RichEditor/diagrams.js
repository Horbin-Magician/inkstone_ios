import mermaid from 'mermaid';
let nextDiagram = 0;
let currentTheme = null;
function ensureInitialized(dark) {
  const theme = dark ? 'dark' : 'neutral';
  if (currentTheme === theme) return;
  currentTheme = theme;
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    suppressErrorRendering: true,
    maxTextSize: 50000,
    maxEdges: 500,
    theme,
    htmlLabels: false,
    flowchart: {htmlLabels: false},
    secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges', 'suppressErrorRendering', 'htmlLabels', 'flowchart', 'themeCSS', 'fontFamily', 'themeVariables']
  });
}
ensureInitialized(false);
window.inkstoneRenderDiagram = async function(element, source, isCurrent = () => true, dark = false) {
  const id = 'inkstoneDiagram' + nextDiagram++;
  try {
    if (source.length > 50000) throw new Error('Diagram too large');
    ensureInitialized(dark);
    const {svg} = await mermaid.render(id, source);
    if (isCurrent()) { element.innerHTML = svg; element.classList.remove('render-error'); }
  } catch {
    if (isCurrent()) { element.textContent = '图表无法解析，请检查 Mermaid 语法。\n' + source; element.classList.add('render-error'); }
  } finally { document.getElementById('d' + id)?.remove(); }
}
