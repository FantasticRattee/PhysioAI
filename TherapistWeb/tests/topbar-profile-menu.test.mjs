import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const topbar = await readFile(new URL('../src/components/Topbar.jsx', import.meta.url), 'utf8');
const styles = await readFile(new URL('../app/globals.css', import.meta.url), 'utf8');

test('account details and logout are contained in an accessible profile menu', () => {
  assert.match(topbar, /aria-haspopup="menu"/);
  assert.match(topbar, /aria-expanded=\{accountMenuOpen\}/);
  assert.match(topbar, /className="account-popover"/);
  assert.match(topbar, /className="account-logout-button"/);
  assert.match(topbar, /document\.addEventListener\('pointerdown'/);
  assert.match(topbar, /event\.key === 'Escape'/);
  assert.doesNotMatch(topbar, /className="icon-button signout-button"/);
});

test('profile trigger is circular and popover remains inside narrow viewports', () => {
  assert.match(styles, /\.profile-button\s*\{[\s\S]*?border-radius: 50%/);
  assert.match(styles, /\.account-popover\s*\{[\s\S]*?width: min\(290px, calc\(100vw - 28px\)\)/);
  assert.match(styles, /@media \(max-width: 700px\)[\s\S]*?\.communication-shell \.topbar\s*\{[\s\S]*?display: grid/);
  assert.doesNotMatch(styles, /\.communication-shell \.topbar\s*\{\s*display: none/);
});
