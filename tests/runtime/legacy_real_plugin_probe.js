// Optional: supply an unmodified downloaded head_filter.js path. Not a WKWebView test.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
if (!process.argv[2]) throw new Error('Pass the path to the unmodified third-party script');
const bridge = fs.readFileSync('iLampa/Resources/lampa_bridge.js', 'utf8').replace('window.LampaNativeBridge.init();', '');
const plugin = fs.readFileSync(process.argv[2], 'utf8');
const store = new Map(), registrations = [], messages = [], dom = [];
const listener = { callbacks: [], follow(_, fn) { this.callbacks.push(fn); }, send(e) { this.callbacks.forEach(fn => fn(e)); } };
const window = { appready: true, __ilampaGeneration: 1, __ilampaDocumentToken: 'real-plugin-probe',
  localStorage: { getItem: k => store.has(k) ? store.get(k) : null },
  webkit: { messageHandlers: { lampaSettings: { postMessage: m => messages.push(m) } } } };
const Lampa = {
  Manifest: {}, Template: { add() {} }, Lang: { add() {}, translate: s => s },
  SettingsApi: { addComponent() {}, addParam(data) { registrations.push(data); }, removeComponent() {}, removeParams() {} },
  Storage: { listener, get(k, fallback) { const v = store.get(k); return v == null ? fallback : v === 'true' ? true : v === 'false' ? false : v; },
    field(k) { const p = registrations.find(x => x.param.name === k); return this.get(k, p.param.default); },
    set(k, v) { store.set(k, v); listener.send({ name: k, value: v }); } }
};
const $ = selector => ({ show() { dom.push(['show', selector]); }, hide() { dom.push(['hide', selector]); } });
const context = { window, Lampa, $, console, setInterval, clearInterval, setTimeout };
vm.runInNewContext(bridge, context);
window.LampaNativeBridge.attachLegacySettingsHook();
window.__ilampaExecutingPluginURL = 'head-filter';
vm.runInNewContext(plugin, context);
window.__ilampaExecutingPluginURL = null;
const setting = messages.at(-1).settings.find(x => x.name === 'search');
assert.ok(setting);
assert.equal(setting.component, 'head_filter');
assert.equal(window.LampaNativeBridge.changeLegacySetting('head-filter', setting.id, 'false', 1, 'real-plugin-probe').success, true);
assert.equal(store.get('head_filter_show_search'), 'false');
assert.equal(dom.at(-1)[0], 'hide');
assert.equal(dom.at(-1)[1], '.open--search');
console.log('unmodified head_filter registration and storage listener passed in Node harness; DOM effect mocked, not native verification');
