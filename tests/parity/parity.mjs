// Compares the Lua port of the detector with the JS original, page by page.
//
//   node tests/parity/parity.mjs [--every N] [--max N] [--tmp DIR] comic.cbz|cbr ...
//
// Each page is decoded once (sharp, as tools/panels does), detected with the JS
// (tools/panels/detect.mjs) and written raw to DIR; luajit runs
// tests/parity/run.lua on the same bytes. Any difference is printed. Exit code 1
// if a page differs.

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const tools = path.join(root, 'tools/panels');
const require = createRequire(path.join(tools, 'package.json'));
const sharp = require('sharp');
const { openArchive } = await import(path.join(tools, 'panels.mjs').replace(/\\/g, '/').replace(/^([A-Za-z]):/, 'file:///$1:'));
const { orderPages } = await import(path.join(tools, 'order.mjs').replace(/\\/g, '/').replace(/^([A-Za-z]):/, 'file:///$1:'));
const { detectPage } = await import(path.join(tools, 'detect.mjs').replace(/\\/g, '/').replace(/^([A-Za-z]):/, 'file:///$1:'));

const args = process.argv.slice(2);
let every = 1;
let max = Infinity;
let tmp = path.join(root, 'tests/parity/.tmp');
const comics = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--every') every = Number(args[++i]);
  else if (args[i] === '--max') max = Number(args[++i]);
  else if (args[i] === '--tmp') tmp = args[++i];
  else comics.push(args[i]);
}
fs.mkdirSync(tmp, { recursive: true });
const raw = path.join(tmp, 'page.rgba');

const EPS = 1e-9;
const sameRects = (a, b) =>
  a.length === b.length &&
  a.every((r, i) => ['x', 'y', 'w', 'h'].every((k) => Math.abs(r[k] - b[i][k]) <= EPS));
const fmt = (l) => l.map((r) => `[${r.x.toFixed(3)},${r.y.toFixed(3)},${r.w.toFixed(3)},${r.h.toFixed(3)}]`).join(' ');

let total = 0;
let bad = 0;
let tJs = 0;
let tLua = 0;
for (const file of comics) {
  const arc = await openArchive(file);
  const pages = orderPages(arc.names);
  let n = 0;
  for (let p = 0; p < pages.length && n < max; p += every) {
    n++;
    const name = pages[p];
    let img;
    try {
      img = await sharp(arc.read(name), { limitInputPixels: false })
        .rotate()
        .ensureAlpha()
        .raw()
        .toBuffer({ resolveWithObject: true });
    } catch {
      continue;
    }
    const { data, info } = img;
    let t0 = performance.now();
    const js = detectPage(data, info.width, info.height);
    tJs += performance.now() - t0;
    fs.writeFileSync(raw, data);
    t0 = performance.now();
    const run = spawnSync('luajit', [path.join(here, 'run.lua'), raw, String(info.width), String(info.height)], {
      cwd: root,
      encoding: 'utf8',
      maxBuffer: 1 << 24,
    });
    tLua += performance.now() - t0;
    total++;
    const label = `${path.basename(file)} p${p + 1} (${name})`;
    if (run.status !== 0) {
      bad++;
      console.log(`ERROR ${label}\n${run.stderr.trim()}`);
      continue;
    }
    const lua = JSON.parse(run.stdout);
    const ok =
      lua.kind === js.kind &&
      lua.style === js.style &&
      sameRects(lua.panels, js.panels) &&
      sameRects(lua.panelsRtl, js.panelsRtl);
    if (ok) {
      console.log(`ok    ${label}: ${js.kind}/${js.style} ${js.panels.length}  (lua ${lua.ms} ms)`);
    } else {
      bad++;
      console.log(`DIFF  ${label}`);
      console.log(`  js : ${js.kind}/${js.style} ${js.panels.length} ${fmt(js.panels)}`);
      console.log(`  lua: ${lua.kind}/${lua.style} ${lua.panels.length} ${fmt(lua.panels)}`);
      if (!sameRects(lua.panelsRtl, js.panelsRtl)) console.log(`  rtl js ${fmt(js.panelsRtl)}\n  rtl lua ${fmt(lua.panelsRtl)}`);
    }
  }
}
fs.rmSync(raw, { force: true });
console.log(`\n${total - bad}/${total} iguales. JS ${(tJs / 1000).toFixed(1)} s, Lua ${(tLua / 1000).toFixed(1)} s (con lectura y arranque)`);
process.exit(bad ? 1 : 0);
