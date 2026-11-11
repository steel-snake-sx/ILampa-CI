/** Behavioral contract for the *selected* upstream core after native-managed adapter. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const code = fs.readFileSync(path.resolve(__dirname, '../../iLampa/Resources/www/app.min.js'), 'utf8');
const start = code.indexOf('  var _created = [];');
const anchor = code.indexOf('  var Plugins = {', start);
const end = code.indexOf('\n  /**', anchor);
assert.ok(start >= 0 && anchor > start && end > anchor, 'Selected core must contain a real Plugins module');

const calls = { reads: 0, writes: 0, scripts: [], account: 0 };
const context = {
    __ilampaNativeManaged: true,
    __ilampaNativePluginManifest: [{url:'https://plugins.example/installed.js', name:'Installed',status:1}],
    lampa_settings: { plugins_use: true },
    console: { log() {}, warn() {} },
    Request: function Request() {},
    Storage: {
        get(name, empty) { calls.reads++; return JSON.parse(empty); },
        set() { calls.writes++; }
    },
    Account: { Api: { plugins(cb) { calls.account++; cb([]); } }, Permit: { access: false } },
    Account$1: { Api: { plugins(cb) { calls.account++; cb([]); } }, Permit: { access: false } },
    Utils$1: { putScriptAsync(urls, cb) { calls.scripts.push(...urls); if (cb) cb(); } },
    Utils: { putScriptAsync(urls, cb) { calls.scripts.push(...urls); if (cb) cb(); } },
    Base64: { encode(v) { return v; } },
    localStorage: { getItem() { return ''; } },
    location: { host: 'test' },
    Arrays: { remove() {} }
};
context.window = context;
vm.createContext(context);
vm.runInContext(code.slice(start, end), context, { filename: 'selected-app.min.js:Plugins' });
vm.runInContext('loadBlackList = function(cb) { cb([]); };', context);
const plugin = context.Plugins;
assert.ok(plugin, 'Expected actual exported Plugins module');
let callbacks = 0;
plugin.task(() => callbacks++);
plugin.load(() => callbacks++);
const item = { url: 'https://plugins.example/unsafe.js', status: 1 };
plugin.add(item);
plugin.push(item);
plugin.save();
plugin.remove(item);
assert.equal(callbacks, 2, 'Managed startup must still report completion');
assert.deepEqual(calls, { reads: 0, writes: 0, scripts: [], account: 0 },
    'Native-managed runtime must not auto-fetch or persist plugins');
assert.deepEqual(Array.from(plugin.get(), entry => entry.url), ['https://plugins.example/installed.js']);
assert.equal(plugin.get()[0].status, 1);
plugin.get()[0].status = 0;
assert.equal(context.__ilampaNativePluginManifest[0].status, 1,
    'Read-only projection must not mutate the native plugin registry');
assert.equal(plugin.awaits().length, 0);
console.log('PASS selected core native-managed Plugins lifecycle: no automatic plugin loading or persistence');
