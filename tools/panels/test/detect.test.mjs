import test from 'node:test';
import assert from 'node:assert/strict';
import sharp from 'sharp';
import { analysePage, pageEntry } from '../panels.mjs';
import { EXPECTED, pages } from './fixture.mjs';

test('the detector finds the synthetic panels in reading order', async () => {
  const svgs = pages();
  for (let i = 0; i < svgs.length; i++) {
    const png = await sharp(svgs[i]).png().toBuffer();
    const det = await analysePage(png);
    const entry = pageEntry(EXPECTED[i].file, det.width, det.height, det);
    assert.equal(entry.width, 1600);
    assert.equal(entry.height, 2400);
    assert.equal(entry.panels.length, EXPECTED[i].panels, `${EXPECTED[i].file}: ${JSON.stringify(entry.panels)}`);
    for (const r of entry.panels) {
      assert.ok(r.x >= 0 && r.y >= 0 && r.x + r.w <= 1600 && r.y + r.h <= 2400, 'inside the page');
    }
    if (EXPECTED[i].panels === 4) {
      // left to right, top to bottom; manga order starts top right
      const [a, b, c] = entry.panels;
      assert.ok(a.x < b.x && Math.abs(a.y - b.y) < 20 && c.y > a.y);
      assert.ok(entry.panels_rtl && entry.panels_rtl[0].x > entry.panels_rtl[1].x);
    }
  }
});
