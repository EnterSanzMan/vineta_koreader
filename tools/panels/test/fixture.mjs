// Builds tests/fixtures/sintetico.cbz: a small comic of our own (no copyright) with
// known panels, to test the detector wrapper, the page order and the plugin.
//
//   node test/fixture.mjs        (from tools/panels)

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import AdmZip from 'adm-zip';
import sharp from 'sharp';

const W = 1600;
const H = 2400;
const M = 80; // page margin
const G = 60; // gutter

function panel(x, y, w, h, label, shade) {
  const lines = [];
  for (let i = 1; i < 6; i++) {
    lines.push(`<line x1="${x + 30}" y1="${y + (h * i) / 6}" x2="${x + w - 30}" y2="${y + (h * i) / 6 + 40}" stroke="#555" stroke-width="6"/>`);
  }
  return `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="${shade}" stroke="#000" stroke-width="10"/>
${lines.join('\n')}
<text x="${x + w / 2}" y="${y + h / 2 + 90}" font-size="260" font-family="sans-serif" font-weight="bold" text-anchor="middle" fill="#000">${label}</text>`;
}

function page(body) {
  return Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">
<rect width="100%" height="100%" fill="#fff"/>
${body}
</svg>`);
}

// Page 1: 2×2 grid. Page 2: three strips. Page 3: one full-bleed illustration.
export const EXPECTED = [
  { file: 'p01.png', panels: 4 },
  { file: 'p02.png', panels: 3 },
  { file: 'p10.png', panels: 1 }, // "10" sorts after "02": natural order
];

export function pages() {
  const cw = (W - 2 * M - G) / 2;
  const ch = (H - 2 * M - G) / 2;
  const grid = [
    panel(M, M, cw, ch, '1', '#ddd'),
    panel(M + cw + G, M, cw, ch, '2', '#bbb'),
    panel(M, M + ch + G, cw, ch, '3', '#999'),
    panel(M + cw + G, M + ch + G, cw, ch, '4', '#777'),
  ].join('\n');
  const sh = (H - 2 * M - 2 * G) / 3;
  const strips = [0, 1, 2].map((i) => panel(M, M + i * (sh + G), W - 2 * M, sh, String(i + 1), ['#ccc', '#aaa', '#888'][i])).join('\n');
  const art = `<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#222"/><stop offset="1" stop-color="#888"/></linearGradient></defs>
<rect width="100%" height="100%" fill="url(#g)"/>
<circle cx="800" cy="1000" r="500" fill="#444"/>
<text x="800" y="1900" font-size="300" font-family="sans-serif" text-anchor="middle" fill="#eee">FIN</text>`;
  return [page(grid), page(strips), page(art)];
}

export async function buildFixture(target) {
  const zip = new AdmZip();
  const svgs = pages();
  for (let i = 0; i < svgs.length; i++) {
    zip.addFile(EXPECTED[i].file, await sharp(svgs[i]).png().toBuffer());
  }
  // Not a page for MuPDF: must not shift the numbering.
  zip.addFile('leeme.txt', Buffer.from('Cómic sintético de prueba de Viñeta para KOReader.\n'));
  fs.mkdirSync(path.dirname(target), { recursive: true });
  zip.writeZip(target);
  return target;
}

const here = path.dirname(fileURLToPath(import.meta.url));
export const FIXTURE = path.resolve(here, '../../../tests/fixtures/sintetico.cbz');

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  console.log(await buildFixture(FIXTURE));
}
