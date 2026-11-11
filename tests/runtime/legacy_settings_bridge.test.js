// Exercises the production bridge with a deterministic legacy plugin, not WKWebView.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const bridge = fs.readFileSync('iLampa/Resources/lampa_bridge.js', 'utf8').replace('window.LampaNativeBridge.init();', '');
const messages = [], events = [], store = new Map(), params = {};
const listener = { callbacks: [], follow(_, fn) { this.callbacks.push(fn); }, send(event) { this.callbacks.forEach(fn => fn(event)); } };
const window = { __ilampaGeneration: 1, __ilampaDocumentToken: 'doc', localStorage: {
  getItem: k => store.has(k) ? store.get(k) : null, setItem: (k,v) => store.set(k, String(v))
}, webkit: { messageHandlers: { lampaSettings: { postMessage: x => messages.push(x) } } } };
const Lampa = {
  Lang: { translate: s => s },
  SettingsApi: {
    addComponent() { return 'component-result'; },
    addParam(data) { (params[data.component] ||= []).push(data); return 'param-result'; },
    removeComponent(name) { delete params[name]; }, removeParams(name) { delete params[name]; }
  },
  Storage: {
    listener,
    field(name) { const data = Object.values(params).flat().find(x => x.param.name === name); const v = store.get(name) ?? String(data.param.default); return v === 'true' ? true : v === 'false' ? false : v; },
    set(name, value) { store.set(name, value); events.push(['storage', name, value]); listener.send({ name, value }); }
  }
};
const ctx = { window, Lampa, console, setInterval, clearInterval };
vm.runInNewContext(bridge, ctx);
window.LampaNativeBridge.attachLegacySettingsHook();
window.__ilampaExecutingPluginURL = 'plugin';
vm.runInNewContext(`
Lampa.SettingsApi.addComponent({component:'fixture',name:'Fixture'});
Lampa.SettingsApi.addParam({component:'fixture',param:{name:'enabled',type:'trigger',default:false},field:{name:'Enabled'},onChange:function(v){ events.push(['callback',v,window.__ilampaExecutingPluginURL]); }});
Lampa.SettingsApi.addParam({component:'fixture',param:{name:'quality',type:'select',values:{low:'Low',high:'High'},default:'high'},field:{name:'Quality'}});
Lampa.SettingsApi.addParam({component:'fixture',param:{name:'server',type:'input',default:'abc'},field:{name:'Server'},onRender:function(){}});
Lampa.SettingsApi.addParam({component:'fixture',param:{type:'title'},field:{name:'Heading'}});
Lampa.SettingsApi.addParam({component:'fixture',param:{type:'button'},field:{name:'DOM button'}});
`, { Lampa, window, events });
window.__ilampaExecutingPluginURL = null;
let settings = messages.at(-1).settings;
assert.equal(settings.length, 4);
assert.equal(settings[0].componentName, 'Fixture');
assert.equal(settings[2].onRender, true);
assert.equal(settings[1].options[0].label, 'Low');
const change = window.LampaNativeBridge.changeLegacySetting;
let result = change('plugin', settings[0].id, 'true', 1, 'doc');
assert.equal(result.success, true);
assert.deepEqual(JSON.parse(JSON.stringify(events)), [['storage','enabled','true'],['callback','true','plugin']]);
assert.equal(result.settings[0].value, 'true');
assert.equal(change('plugin', settings[1].id, 'unknown', 1, 'doc').success, false);
assert.equal(change('other', settings[0].id, 'false', 1, 'doc').success, false);
assert.equal(change('plugin', settings[0].id, 'false', 2, 'doc').success, false);
assert.equal(change('plugin', settings[1].id, 'low', 1, 'doc').success, true);
assert.equal(store.get('quality'), 'low');
params.fixture[0].onChange = function () { throw new Error('callback failed'); };
result = change('plugin', settings[0].id, 'false', 1, 'doc');
assert.equal(result.success, false);
assert.match(result.error, /callback failed/);
assert.equal(result.settings[0].value, 'false'); // storage already changed, as in Lampa
assert.equal(window.__ilampaExecutingPluginURL, null);
Lampa.SettingsApi.removeParams('fixture');
assert.equal(change('plugin', settings[0].id, 'false', 1, 'doc').success, false);
assert.equal(messages.at(-1).settings.length, 0);
console.log('legacy bridge contract passed (not native WKWebView verification)');
