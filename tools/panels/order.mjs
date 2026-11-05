// Page order exactly as MuPDF (KOReader's engine) builds it for CBZ/CBR/CBT:
// every archive entry whose extension is in MuPDF's list, sorted with its
// natural comparison (digit runs compared as numbers, letters uppercased).
// Source: mupdf/source/cbz/mucbz.c (cbz_ext_list, cbz_strnatcmp).
// If this differs from MuPDF, JSON page i no longer matches KOReader page i.

export const MUPDF_IMAGE_EXTS = [
  '.bmp', '.gif', '.hdp', '.j2k', '.jb2', '.jbig2', '.jp2', '.jpeg', '.jpg', '.jpx',
  '.jxr', '.pam', '.pbm', '.pgm', '.pkm', '.png', '.pnm', '.ppm', '.tif', '.tiff', '.wdp',
];

export function isPageName(name) {
  const dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return MUPDF_IMAGE_EXTS.includes(name.slice(dot).toLowerCase());
}

const isDigit = (c) => c >= 48 && c <= 57;
const upper = (c) => (c >= 97 && c <= 122 ? c - 32 : c);

// Port of cbz_strnatcmp. Works on bytes (UTF-8), like the C code.
export function mupdfNatCmp(a, b) {
  const A = Buffer.from(a, 'utf8');
  const B = Buffer.from(b, 'utf8');
  let i = 0;
  let j = 0;
  while (i < A.length || j < B.length) {
    let x;
    let y;
    const ca = i < A.length ? A[i] : 0;
    const cb = j < B.length ? B[j] : 0;
    if (isDigit(ca) && isDigit(cb)) {
      x = 0;
      while (i < A.length && isDigit(A[i])) x = x * 10 + (A[i++] - 48);
      y = 0;
      while (j < B.length && isDigit(B[j])) y = y * 10 + (B[j++] - 48);
    } else {
      x = upper(ca);
      y = upper(cb);
      i++;
      j++;
    }
    if (x < y) return -1;
    if (x > y) return 1;
  }
  return 0;
}

// Names of the pages, in reading order. Note: MuPDF ignores .webp (and any other
// extension not in the list), and does NOT skip __MACOSX/ resource forks.
export function orderPages(names) {
  return names.filter(isPageName).sort(mupdfNatCmp);
}
