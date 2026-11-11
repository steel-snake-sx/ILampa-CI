// Controlled-order regression of the SHIPPED bridge. The native rendezvous is
// simulated here; RuntimeExecutionWebKitTests covers its real WKUIDelegate path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const bridge = fs.readFileSync('iLampa/Resources/lampa_bridge.js', 'utf8')
  .replace('window.LampaNativeBridge.init();', '');
function fixture() {
  const store = new Map(), messages = [], events = [], permits = new Set();
  let eligible = true, sequence = 0;
  const window = { __ilampaGeneration: 1, __ilampaDocumentToken: 'doc', __ilampaNativeManaged: true,
    localStorage: { getItem: k => store.get(k) ?? null },
    prompt(name, json) {
      assert.equal(name, '__ilampa_execute_v1__');
      const ticket = JSON.parse(json);
      if (!eligible || !permits.delete(ticket.id)) return null;
      return ticket.id;
    },
    webkit: { messageHandlers: { lampaSettings: { postMessage: m => messages.push(m) } } } };
  const Lampa = { Lang: { translate: s => s },
    SettingsApi: { addComponent() {}, addParam() {}, removeComponent() {}, removeParams() {} },
    Storage: { field: k => store.get(k) ?? false,
      set(k, v) { store.set(k, v); events.push('storage:' + v); } } };
  vm.runInNewContext(bridge, { window, Lampa, setInterval, clearInterval });
  const api = window.LampaNativeBridge;
  api.attachLegacySettingsHook();
  const register = () => {
    window.__ilampaExecutingPluginURL = 'owner';
    Lampa.SettingsApi.addParam({ component: 'fixture', param: { name: 'key', type: 'trigger' },
      field: { name: 'Key' }, onChange: v => events.push('callback:' + v) });
    window.__ilampaExecutingPluginURL = null;
    return messages.at(-1).settings.at(-1).id;
  };
  const id = register();
  const queue = (value, settingID = id) => {
    const ticket = { id: String(++sequence), generation: 1, documentToken: 'doc' };
    permits.add(ticket.id);
    return () => api.executeNativeAction(ticket, () => api.changeLegacySetting('owner', settingID, value, 1, 'doc'));
  };
  return { api, id, queue, store, events, register, Lampa,
    invalidate() { eligible = false; permits.clear(); }, reenable() { eligible = true; } };
}
for (const reason of ['disable', 'remove', 'restart', 'collision', 'termination', 'navigation']) {
  const f = fixture();
  assert.equal(f.queue('false')().success, true);
  assert.deepEqual(f.events, ['storage:false', 'callback:false']);
  const queued = f.queue('true'); // Native admission before invalidation.
  f.invalidate(reason); // No asynchronous JS invalidation call is required.
  assert.equal(queued().success, false, reason);
  assert.equal(f.store.get('key'), 'false', reason);
  assert.deepEqual(f.events, ['storage:false', 'callback:false'], reason);
}
{
  const f = fixture(), old = f.queue('true');
  f.invalidate(); f.reenable();
  assert.equal(old().success, false, 're-enable cannot resurrect a revoked ticket');
  const action = f.queue('false');
  assert.equal(action().success, true);
  assert.equal(action().success, false, 'one-use ticket');
  assert.equal(f.api.changeLegacySetting('owner', f.id, 'true', 1, 'doc').success, false, 'no ungated native-managed write');
}
{
  const f = fixture(), old = f.queue('true');
  f.Lampa.SettingsApi.removeParams('fixture'); f.register();
  assert.equal(old().success, false, 'registration replacement must not reuse old callback');
  assert.deepEqual(f.events, []);
}
{
  const f = fixture();
  const actions = ['true', 'false', 'true'].map(v => f.queue(v));
  actions.forEach(run => assert.equal(run().success, true));
  assert.deepEqual(f.events, ['storage:true', 'callback:true', 'storage:false', 'callback:false', 'storage:true', 'callback:true']);
}
console.log('queued settings actions reject stale execution before side effects (JS contract; not WKWebView proof)');
