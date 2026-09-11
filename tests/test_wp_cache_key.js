// Tests for modules/edge/functions/wp-cache-key.js. Run: node tests/test_wp_cache_key.js
'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const vm = require('vm');

const src = fs.readFileSync(path.join(__dirname, '..', 'modules', 'edge', 'functions', 'wp-cache-key.js'), 'utf8');
const ctx = {};
vm.createContext(ctx);
vm.runInContext(src, ctx);
const handler = ctx.handler;

function ev(cookies, headers) {
  const c = {};
  for (const [k, v] of Object.entries(cookies || {})) c[k] = { value: v };
  return { request: { method: 'GET', uri: '/', headers: headers || {}, cookies: c, querystring: {} } };
}

let n = 0;
function test(name, fn) { fn(); n++; console.log('ok -', name); }

test('anonymous visitor: no bypass header', () => {
  const r = handler(ev({}));
  assert.strictEqual(r.headers['x-wp-nocache'], undefined);
});

test('analytics and consent cookies only: still shares cache', () => {
  const r = handler(ev({ _ga: 'GA1.1.123', _ga_ABC: 'GS1', _fbp: 'fb.1', 'cookieyes-consent': 'yes' }));
  assert.strictEqual(r.headers['x-wp-nocache'], undefined);
});

test('logged-in editor: unique bypass value per request', () => {
  const a = handler(ev({ wordpress_logged_in_5f2a: 'user|123|abc', _ga: 'x' }));
  const b = handler(ev({ wordpress_logged_in_5f2a: 'user|123|abc' }));
  assert.ok(a.headers['x-wp-nocache'] && a.headers['x-wp-nocache'].value.length >= 8);
  assert.notStrictEqual(a.headers['x-wp-nocache'].value, b.headers['x-wp-nocache'].value);
});

test('woocommerce session and password-protected post cookies bypass', () => {
  assert.ok(handler(ev({ wp_woocommerce_session_9a: 'x' })).headers['x-wp-nocache']);
  assert.ok(handler(ev({ woocommerce_items_in_cart: '1' })).headers['x-wp-nocache']);
  assert.ok(handler(ev({ 'wp-postpass_ab12': 'x' })).headers['x-wp-nocache']);
  assert.ok(handler(ev({ comment_author_ab12: 'Pat' })).headers['x-wp-nocache']);
});

test('viewer-supplied x-wp-nocache is stripped for anonymous visitors', () => {
  const r = handler(ev({}, { 'x-wp-nocache': { value: 'attacker-random' } }));
  assert.strictEqual(r.headers['x-wp-nocache'], undefined);
});

test('request without a cookies object does not throw', () => {
  const r = handler({ request: { method: 'GET', uri: '/', headers: {} } });
  assert.strictEqual(r.headers['x-wp-nocache'], undefined);
});

console.log(`${n} tests passed`);
