// Runs Viñeta's panel detector on one decoded page, reproducing what
// processPage() does in the app (panels-core.js), without a browser canvas.

import {
  DETECT_MAX,
  boxAccumulate,
  boxFinish,
  detectPanels,
  negativeOf,
  paperMaps,
} from './detector/panels-core.js';

const DISPLAY_MAX = 3000; // processPage's displayMax: the app analyses from this size

// rgba: Uint8Array/Buffer w×h×4. Returns { kind, style, panels, panelsRtl } with
// rectangles normalised to 0..1, in reading order.
export function detectPage(rgba, iw, ih, { style = 'auto' } = {}) {
  const k = Math.min(1, DISPLAY_MAX / Math.max(iw, ih));
  const dw = Math.round(iw * k);
  const dh = Math.round(ih * k);
  const ak = Math.min(1, DETECT_MAX / Math.max(dw, dh));
  const aw = Math.max(8, Math.round(dw * ak));
  const ah = Math.max(8, Math.round(dh * ak));

  // analysisImage(): box-filter the original page to aw×ah and to 2aw×2ah.
  const W = aw * 2;
  const H = ah * 2;
  const sum = new Uint32Array(W * H * 3);
  const cnt = new Uint16Array(W * H);
  const sum1 = new Uint32Array(aw * ah * 3);
  const cnt1 = new Uint16Array(aw * ah);
  const src = rgba instanceof Uint8ClampedArray ? rgba : new Uint8ClampedArray(rgba.buffer, rgba.byteOffset, rgba.length);
  boxAccumulate(sum, cnt, src, iw, ih, W, H, 0, ih);
  boxAccumulate(sum1, cnt1, src, iw, ih, aw, ah, 0, ih);
  const big = boxFinish(sum, cnt, W, H);
  const { hi, hiLuma } = paperMaps(big, W, H);
  const data = boxFinish(sum1, cnt1, aw, ah);
  const neg = negativeOf(data, big, aw, ah);

  const r = detectPanels(data, aw, ah, { rtl: false, style, hi, hiLuma, neg });
  return {
    kind: r.kind,
    style: r.style,
    panels: r.panels,
    panelsRtl: r.panelsRtl || r.panels,
  };
}
