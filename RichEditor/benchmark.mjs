import {performance} from 'node:perf_hooks';
import {schema, loadMarkdown, saveMarkdown} from './model.js';
const loaded = loadMarkdown(Array.from({length: 1000}, (_, i) => `Paragraph ${i} 中文 **bold** text.`).join('\n\n'));
let nodes = [];
loaded.doc.forEach(node => nodes.push(node.type.create(node.attrs, node.content.append(schema.nodes.paragraph.create(null, schema.text(' changed')).content))));
const samples = [];
for (let i = 0; i < 50; i++) {
  nodes[0] = schema.nodes.paragraph.create(nodes[0].attrs, schema.text(`Edit ${i}`));
  const doc = schema.nodes.doc.create(null, nodes);
  const start = performance.now();
  const source = saveMarkdown(doc, loaded);
  samples.push(performance.now() - start);
  if (!source.includes('changed')) throw new Error('Invalid output');
}
samples.sort((a,b) => a-b);
console.log(JSON.stringify({blocks: 1000, edits: 50, medianMs: samples[25], p95Ms: samples[47]}));
