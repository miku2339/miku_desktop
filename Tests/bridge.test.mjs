import test from 'node:test';
import assert from 'node:assert/strict';
import { createNativeBridge, TAURI_COMMAND } from '../Wallpaper/companion/bridge.js';

const settle = () => new Promise(resolve => setTimeout(resolve, 0));

test('in the macOS app messages go to the WKWebView handler, as before', () => {
  const sent = [];
  const win = { webkit: { messageHandlers: { miku: { postMessage: message => sent.push(message) } } } };
  const bridge = createNativeBridge(win);
  assert.equal(bridge.platform(), 'mac');
  assert.equal(bridge.available(), true);
  assert.equal(bridge.post({ type: 'touch', zone: 'head' }), true);
  assert.deepEqual(sent, [{ type: 'touch', zone: 'head' }]);
});

test('in the Windows app messages go to the Tauri command', async () => {
  const calls = [];
  const win = { __TAURI__: { core: { invoke: (command, args) => { calls.push([command, args]); return Promise.resolve(); } } } };
  const bridge = createNativeBridge(win);
  assert.equal(bridge.platform(), 'windows');
  assert.equal(bridge.post({ type: 'pin', x: 0.4 }), true);
  await settle();
  assert.deepEqual(calls, [[TAURI_COMMAND, { message: { type: 'pin', x: 0.4 } }]]);
});

test('Tauri without the global API still works through its internals', async () => {
  const calls = [];
  const win = { __TAURI_INTERNALS__: { invoke: (command, args) => calls.push([command, args]) } };
  assert.equal(createNativeBridge(win).post({ type: 'diag' }), true);
  await settle();
  assert.equal(calls.length, 1);
});

test('a failed Tauri call is reported, never thrown at the page', async () => {
  const errors = [];
  const win = { __TAURI__: { core: { invoke: () => Promise.reject(new Error('no shell')) } } };
  const bridge = createNativeBridge(win, { onError: error => errors.push(error.message) });
  assert.equal(bridge.post({ type: 'haptic' }), true);
  await settle();
  assert.deepEqual(errors, ['no shell']);
});

test('opened in a browser there is no app to talk to', () => {
  for (const win of [{}, undefined, { webkit: { messageHandlers: {} } }]) {
    const bridge = createNativeBridge(win);
    assert.equal(bridge.available(), false);
    assert.equal(bridge.platform(), null);
    assert.equal(bridge.post({ type: 'touch' }), false);
  }
});

test('the app can set up its side after the page has started', () => {
  const win = {};
  const bridge = createNativeBridge(win);
  assert.equal(bridge.available(), false);
  const sent = [];
  win.webkit = { messageHandlers: { miku: { postMessage: message => sent.push(message) } } };
  assert.equal(bridge.post({ type: 'bounds' }), true);
  assert.equal(sent.length, 1);
});
