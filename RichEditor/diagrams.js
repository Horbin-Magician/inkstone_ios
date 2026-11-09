import mermaid from 'mermaid';
let nextDiagram = 0;
mermaid.initialize({startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true,
  maxTextSize: 50000, maxEdges: 500, theme: 'neutral', flowchart: {htmlLabels: false},
  secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges', 'suppressErrorRendering']});
window.inkstoneRenderDiagram = async function(element, source, isCurrent = () => true) {
  const id = 'inkstoneDiagram' + nextDiagram++;
  try {
    if (source.length > 50000) throw new Error('Diagram too large');
    const {svg} = await mermaid.render(id, source);
    if (isCurrent()) { element.innerHTML = svg; element.classList.remove('render-error'); }
  } catch {
    if (isCurrent()) { element.textContent = '图表无法解析，请检查 Mermaid 语法。\n' + source; element.classList.add('render-error'); }
  } finally { document.getElementById('d' + id)?.remove(); }
}
