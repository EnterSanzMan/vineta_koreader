#!/usr/bin/env node
// Genera el fichero de viñetas de uno o varios cómics para el plugin de KOReader.
//
//   node panels.mjs <cómic o carpeta>... [opciones]
//
//   (por defecto)   escribe «<cómic>.panels.json» junto a cada cómic
//   --prepare       escribe en su lugar «<cómic>.vineta.cbz»: páginas en grises, reducidas,
//                   con panels.json dentro (más ligero y rápido en el lector)
//   --out <dir>     carpeta de salida (por defecto, la del cómic)
//   --rtl           marca el cómic como manga (derecha a izquierda)
//   --max-side <n>  con --prepare, lado mayor de las páginas (por defecto 3360)
//   --quality <n>   con --prepare, calidad JPEG (por defecto 85)
//   --force         rehace los que ya tienen fichero de viñetas
//
// Admite .cbz, .zip, .cbr y .rar. Las páginas se numeran como lo hace MuPDF (el motor de
// KOReader): ver order.mjs.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import AdmZip from 'adm-zip';
import sharp from 'sharp';
import { createExtractorFromData } from 'node-unrar-js';
import { detectPage } from './detect.mjs';
import { orderPages } from './order.mjs';

const GENERATOR = 'vineta-panels 0.1 (detector Viñeta 3.6.1)';
const COMIC_EXTS = ['.cbz', '.zip', '.cbr', '.rar'];

export function parseArgs(argv) {
  const opts = { inputs: [], prepare: false, out: null, rtl: false, maxSide: 3360, quality: 85, force: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--prepare') opts.prepare = true;
    else if (a === '--rtl') opts.rtl = true;
    else if (a === '--force') opts.force = true;
    else if (a === '--out') opts.out = argv[++i];
    else if (a === '--max-side') opts.maxSide = Number(argv[++i]);
    else if (a === '--quality') opts.quality = Number(argv[++i]);
    else if (a === '-h' || a === '--help') opts.help = true;
    else if (a.startsWith('--')) throw new Error(`opción desconocida: ${a}`);
    else opts.inputs.push(a);
  }
  if (!(opts.maxSide >= 600)) throw new Error('--max-side debe ser al menos 600');
  if (!(opts.quality >= 30 && opts.quality <= 100)) throw new Error('--quality debe estar entre 30 y 100');
  return opts;
}

function findComics(input) {
  const st = fs.statSync(input);
  if (st.isFile()) return [input];
  const out = [];
  for (const entry of fs.readdirSync(input, { withFileTypes: true })) {
    const p = path.join(input, entry.name);
    if (entry.isDirectory()) out.push(...findComics(p));
    else if (COMIC_EXTS.includes(path.extname(entry.name).toLowerCase()) && !entry.name.endsWith('.vineta.cbz')) out.push(p);
  }
  return out;
}

// Returns { names: [...entry names], read(name) → Buffer }.
export async function openArchive(file) {
  const buf = fs.readFileSync(file);
  const isRar = buf.subarray(0, 4).toString('latin1') === 'Rar!';
  if (!isRar) {
    const zip = new AdmZip(buf);
    const entries = zip.getEntries().filter((e) => !e.isDirectory);
    const byName = new Map(entries.map((e) => [e.entryName, e]));
    return { names: [...byName.keys()], read: (name) => byName.get(name).getData() };
  }
  const extractor = await createExtractorFromData({ data: Uint8Array.from(buf).buffer });
  const list = extractor.getFileList();
  const names = [...list.fileHeaders].filter((h) => !h.flags.directory).map((h) => h.name.replace(/\\/g, '/'));
  return {
    names,
    read: (name) => {
      const { files } = extractor.extract({ files: (h) => h.name.replace(/\\/g, '/') === name });
      for (const f of files) return Buffer.from(f.extraction);
      throw new Error(`no se pudo extraer ${name}`);
    },
  };
}

const KIND = { comic: 'normal', single: 'single', text: 'text' };

function toPixels(list, w, h) {
  return list.map((r) => ({
    x: Math.round(r.x * w),
    y: Math.round(r.y * h),
    w: Math.round(r.w * w),
    h: Math.round(r.h * h),
  }));
}

const sameOrder = (a, b) => a.length === b.length && a.every((r, i) => r.x === b[i].x && r.y === b[i].y);

// Decodes one page (EXIF orientation applied, as MuPDF does) and detects its panels.
export async function analysePage(buf) {
  const { data, info } = await sharp(buf, { limitInputPixels: false }).rotate().ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const det = detectPage(data, info.width, info.height);
  return { width: info.width, height: info.height, ...det };
}

export function pageEntry(file, width, height, det) {
  const entry = { file, width, height, kind: KIND[det.kind] || 'normal', panels: toPixels(det.panels, width, height) };
  const rtl = toPixels(det.panelsRtl, width, height);
  if (!sameOrder(entry.panels, rtl)) entry.panels_rtl = rtl;
  return entry;
}

async function processComic(file, opts) {
  const dir = opts.out || path.dirname(file);
  const base = path.basename(file, path.extname(file));
  const target = path.join(dir, opts.prepare ? `${base}.vineta.cbz` : `${base}.panels.json`);
  if (!opts.force && fs.existsSync(target)) {
    console.log(`= ${file}: ya existe ${target} (usa --force para rehacerlo)`);
    return;
  }
  const arc = await openArchive(file);
  const pages = orderPages(arc.names);
  if (pages.length === 0) throw new Error('no tiene páginas que KOReader pueda abrir (¿WebP?)');
  const skipped = arc.names.filter((n) => /\.webp$/i.test(n)).length;
  if (skipped) console.warn(`  aviso: ${skipped} páginas WebP: KOReader no las muestra y no se cuentan`);

  const json = {
    version: 1,
    generator: GENERATOR,
    source: { file: path.basename(file), size: fs.statSync(file).size },
    reading_direction: opts.rtl ? 'rtl' : 'ltr',
    pages: [],
  };
  const out = opts.prepare ? [] : null; // prepared pages: [name, jpeg]
  const digits = Math.max(4, String(pages.length).length);
  const t0 = Date.now();
  for (let i = 0; i < pages.length; i++) {
    const name = pages[i];
    process.stdout.write(`\r  página ${i + 1}/${pages.length}`);
    let buf;
    let det;
    try {
      buf = arc.read(name);
      det = await analysePage(buf);
    } catch (err) {
      // A page MuPDF lists but nobody can decode (e.g. a __MACOSX resource fork):
      // keep its slot so the numbering still matches KOReader's.
      if (opts.prepare) {
        console.warn(`\n  aviso: se omite ${name}: ${err.message}`);
      } else {
        console.warn(`\n  aviso: ${name} no se pudo leer (${err.message}); se mostrará entera`);
        json.pages.push({ file: name, error: String(err.message) });
      }
      continue;
    }
    if (!opts.prepare) {
      json.pages.push(pageEntry(name, det.width, det.height, det));
      continue;
    }
    const outName = `${String(json.pages.length + 1).padStart(digits, '0')}.jpg`;
    const { data, info } = await sharp(buf, { limitInputPixels: false })
      .rotate()
      .grayscale()
      .resize({ width: opts.maxSide, height: opts.maxSide, fit: 'inside', withoutEnlargement: true })
      .jpeg({ quality: opts.quality, mozjpeg: true })
      .toBuffer({ resolveWithObject: true });
    out.push([outName, data]);
    json.pages.push(pageEntry(outName, info.width, info.height, det));
  }
  process.stdout.write('\n');
  if (out) json.source = { file: path.basename(target) };

  fs.mkdirSync(dir, { recursive: true });
  const text = JSON.stringify(json);
  const tmp = `${target}.tmp`;
  if (out) {
    // panels.json first: the plugin finds it without reading the pages.
    const zip = new AdmZip();
    zip.addFile('panels.json', Buffer.from(text, 'utf8'));
    for (const [name, data] of out) {
      zip.addFile(name, data);
      zip.getEntry(name).header.method = 0; // stored: JPEG does not compress further
    }
    zip.writeZip(tmp);
  } else {
    fs.writeFileSync(tmp, text);
  }
  fs.renameSync(tmp, target);
  const counts = json.pages.reduce((n, p) => n + (p.panels ? p.panels.length : 0), 0);
  console.log(`✓ ${file} → ${target}: ${json.pages.length} páginas, ${counts} viñetas, ${((Date.now() - t0) / 1000).toFixed(1)} s`);
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(err.message);
    process.exit(2);
  }
  if (opts.help || opts.inputs.length === 0) {
    console.log(fs.readFileSync(new URL(import.meta.url)).toString().split('\n').slice(1, 17).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
    process.exit(opts.help ? 0 : 2);
  }
  let failed = 0;
  for (const input of opts.inputs) {
    for (const file of findComics(input)) {
      try {
        await processComic(file, opts);
      } catch (err) {
        failed++;
        console.error(`✗ ${file}: ${err.message}`);
      }
    }
  }
  process.exit(failed ? 1 : 0);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
