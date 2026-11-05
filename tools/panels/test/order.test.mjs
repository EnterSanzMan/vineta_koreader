import test from 'node:test';
import assert from 'node:assert/strict';
import { isPageName, mupdfNatCmp, orderPages } from '../order.mjs';

test('natural order like MuPDF: numbers by value, case-insensitive', () => {
  assert.deepEqual(orderPages(['10.jpg', '2.jpg', '1.jpg']), ['1.jpg', '2.jpg', '10.jpg']);
  assert.deepEqual(orderPages(['b.JPG', 'A.jpg', 'a2.png', 'a10.png']), ['A.jpg', 'a2.png', 'a10.png', 'b.JPG']);
  assert.equal(mupdfNatCmp('page007.jpg', 'page7.jpg'), 0); // leading zeros: same number
  assert.equal(mupdfNatCmp('cap1/10.jpg', 'cap2/1.jpg'), -1); // the folder counts
});

test('only MuPDF image extensions are pages', () => {
  assert.ok(isPageName('x/001.jpeg'));
  assert.ok(isPageName('PAGE.PNG'));
  assert.ok(!isPageName('001.webp')); // MuPDF does not list WebP
  assert.ok(!isPageName('ComicInfo.xml'));
  assert.ok(!isPageName('panels.json'));
  assert.ok(!isPageName('sin-extension'));
  // MuPDF does not skip resource forks: they keep a slot
  assert.deepEqual(orderPages(['__MACOSX/._1.jpg', '1.jpg']), ['1.jpg', '__MACOSX/._1.jpg']);
});
