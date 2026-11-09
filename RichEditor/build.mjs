import {build} from 'esbuild';
import {mkdir, readFile, writeFile, cp} from 'node:fs/promises';
import path from 'node:path';
const outdir = '../Sources/InkstoneCore/Resources/RichEditor';
await mkdir(outdir, {recursive: true});
await build({entryPoints: ['editor.js'], bundle: true, minify: true, format: 'iife', target: 'safari17', outfile: outdir + '/editor.js', legalComments: 'eof'});
await build({entryPoints: ['reader.js'], bundle: true, minify: true, format: 'iife', target: 'safari17', outfile: outdir + '/reader.js', legalComments: 'eof'});
for (const file of ['reader.html', 'extensions.css']) await cp(file, outdir + '/' + file);
await cp('node_modules/katex/dist/katex.min.css', outdir + '/katex.min.css');
await cp('node_modules/katex/dist/fonts', outdir + '/fonts', {recursive: true});
await build({entryPoints: ['diagrams.js'], bundle: true, minify: true, format: 'iife', target: 'safari17', outfile: outdir + '/diagrams.js', legalComments: 'eof'});
const appearance = await readFile('appearance.json', 'utf8');
await writeFile(outdir + '/appearance.json', appearance);
const variables = Object.entries(JSON.parse(appearance)).map(([key, value]) => `--${key}: ${value}px;`).join(' ');
const html = (await readFile('editor.html', 'utf8')).replace('/* shared-appearance */', `:root { ${variables} }`);
const baseCSS = await readFile('node_modules/prosemirror-view/style/prosemirror.css', 'utf8');
await writeFile(outdir + '/editor.html', html.replace('<style>', '<style>\n' + baseCSS));
const lock = JSON.parse(await readFile('package-lock.json', 'utf8'));
let notices = 'Inkstone rich text editor — bundled production dependencies\n\n';
for (const [key, info] of Object.entries(lock.packages)) {
  if (!key || info.dev) continue;
  const name = key.replace(/^node_modules\//, '');
  const dir = path.resolve(key);
  let license = '';
  for (const file of ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'LICENSE-MIT.txt', 'license']) {
    try { license = await readFile(path.join(dir, file), 'utf8'); break; } catch {}
  }
  if (!license) throw new Error('Missing license: ' + name);
  notices += `===== ${name} ${info.version} =====\n${license}\n\n`;
}
await writeFile(outdir + '/ThirdPartyNotices.txt', notices.trimEnd() + '\n');
