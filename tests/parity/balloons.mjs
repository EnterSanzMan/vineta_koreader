// Compares the Lua port of the balloon finder (D.detectBalloonsBoth) with the JS
// original (detectBalloons), panel by panel.
//
//   node tests/parity/balloons.mjs [--every N] [--max N] [--tmp DIR] comic.cbz|cbr ...
//
// For each page the JS detects the panels; each panel is cut out and reduced to the
// balloon size (D.balloonSize, as Viñeta's reader does), and a single-panel page is
// taken whole. The JS looks for balloons in both reading orders; luajit runs
// tests/parity/run_balloons.lua on the same bytes. Exit code 1 if a crop differs.

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const tools = path.join(root, 'tools/panels');
const require = createRequire(path.join(tools, 'package.json'));
const sharp = require('sharp');
const load = (f) => import(pathToFileURL(path.join(tools, f)).href);
const { openArchive } = await load('panels.mjs');
const { orderPages } = await load('order.mjs');
const { detectPage } = await load('detect.mjs');
const { detectBalloons } = await load('detector/panels-core.js');

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

// Same as D.balloonSize in vineta_detect.lua.
function balloonSize(pw, ph) {
  let k = 800 / Math.max(pw, ph);
  if (pw * k * ph * k < 480000) k = Math.sqrt(480000 / (pw * ph));
  k = Math.min(1, k);
  return [Math.max(8, Math.round(pw * k)), Math.max(8, Math.round(ph * k))];
}

const EPS = 1e-9;
const sameRects = (a, b) =>
  a.length === b.length &&
  a.every((r, i) => ['x', 'y', 'w', 'h'].every((k) => Math.abs(r[k] - b[i][k]) <= EPS));
const fmt = (l) => l.map((r) => `[${r.x.toFixed(3)},${r.y.toFixed(3)},${r.w.toFixed(3)},${r.h.toFixed(3)}]`).join(' ');

let total = 0;
let bad = 0;
let found = 0;
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
    const W = info.width;
    const H = info.height;
    const det = detectPage(data, W, H);
    const crops = [];
    const whole = det.kind === 'single' || det.panels.length === 0;
    const rects = whole ? [{ x: 0, y: 0, w: 1, h: 1 }] : det.panels;
    if (det.kind === 'text') continue;
    for (const r of rects) {
      const left = Math.round(r.x * W);
      const top = Math.round(r.y * H);
      const width = Math.max(1, Math.min(W - left, Math.round(r.w * W)));
      const height = Math.max(1, Math.min(H - top, Math.round(r.h * H)));
      const [dw, dh] = balloonSize(width, height);
      const crop = await sharp(data, { raw: { width: W, height: H, channels: 4 } })
        .extract({ left, top, width, height })
        .resize(dw, dh, { fit: 'fill' })
        .raw()
        .toBuffer();
      const file = path.join(tmp, `crop${crops.length}.rgba`);
      fs.writeFileSync(file, crop);
      crops.push({
        file,
        dw,
        dh,
        whole,
        ltr: detectBalloons(crop, dw, dh, false, null, whole),
        rtl: detectBalloons(crop, dw, dh, true, null, whole),
      });
    }
    const list = crops.map((c) => `${c.file} ${c.dw} ${c.dh} ${c.whole ? 1 : 0}`).join('\n') + '\n';
    const run = spawnSync('luajit', [path.join(here, 'run_balloons.lua')], {
      cwd: root,
      input: list,
      encoding: 'utf8',
      maxBuffer: 1 << 24,
    });
    const label = `${path.basename(file)} p${p + 1} (${name})`;
    if (run.status !== 0) {
      bad += crops.length;
      total += crops.length;
      console.log(`ERROR ${label}\n${run.stderr.trim()}`);
      continue;
    }
    const lua = JSON.parse(run.stdout);
    let pageBad = 0;
    crops.forEach((c, i) => {
      total++;
      found += c.ltr.length;
      if (!sameRects(lua[i].ltr, c.ltr) || !sameRects(lua[i].rtl, c.rtl)) {
        pageBad++;
        console.log(`DIFF  ${label} crop ${i} (${c.dw}×${c.dh}${c.whole ? ', página' : ''})`);
        console.log(`  js : ${fmt(c.ltr)}\n  lua: ${fmt(lua[i].ltr)}`);
        if (!sameRects(lua[i].rtl, c.rtl)) console.log(`  rtl js ${fmt(c.rtl)}\n  rtl lua ${fmt(lua[i].rtl)}`);
      }
    });
    bad += pageBad;
    if (!pageBad) {
      const counts = crops.map((c) => c.ltr.length).join(',');
      console.log(`ok    ${label}: ${crops.length} recortes, bocadillos ${counts}`);
    }
    for (const c of crops) fs.rmSync(c.file, { force: true });
  }
}
console.log(`\n${total - bad}/${total} recortes iguales, ${found} bocadillos`);
process.exit(bad ? 1 : 0);
