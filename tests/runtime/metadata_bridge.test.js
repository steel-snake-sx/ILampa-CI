// Fast contract check; the XCTest fixture separately exercises actual WKWebView.
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync('iLampa/Resources/lampa_bridge.js', 'utf8')
  .replace('window.LampaNativeBridge.init();', '');
const messages = [];
const window = {
  __ilampaGeneration: 7,
  __ilampaDocumentToken: 'document',
  webkit: { messageHandlers: { lampaMetadata: { postMessage: x => messages.push(x) } } }
};
vm.runInNewContext(source, { window, console });
assert.strictEqual(window.iLampaMetadata.register('x', () => {}), false);
window.__ilampaExecutingPluginURL = 'plugin';
let emitFirst;
assert.strictEqual(window.iLampaMetadata.register('ratings', (media, emit) => {
  if (!emitFirst) emitFirst = emit;
  emit({ title: 'Scores', state: 'ready', fields: [{ label: 'ID', value: media.canonicalId }] });
}), true);
assert.strictEqual(window.iLampaMetadata.register('ratings', () => {}), false);
assert.strictEqual(messages[0].owner, 'plugin');
const allowed = [{ owner: 'plugin', id: 'ratings' }];
window.LampaNativeBridge.requestMetadata({ requestId: 'a', canonicalId: 'movie:a' }, allowed);
assert.strictEqual(messages[1].canonicalId, 'movie:a');
window.LampaNativeBridge.requestMetadata({ requestId: 'b', canonicalId: 'movie:b' }, allowed);
assert.strictEqual(emitFirst({ title: 'Late', state: 'ready', fields: [] }), false);
assert.strictEqual(messages.length, 3);
let previous = emitFirst;
window.LampaNativeBridge.requestMetadata({ requestId: 'a', dispatchId: 'new', canonicalId: 'movie:a' }, allowed);
assert.strictEqual(previous({ title: 'Superseded', state: 'ready', fields: [] }), false);
assert.strictEqual(messages[3].dispatchId, 'new');
window.LampaNativeBridge.clearMetadata('old-request');
assert.strictEqual(messages.length, 4);
window.LampaNativeBridge.clearMetadata('a');
assert.strictEqual(emitFirst.remove(), false);
console.log('metadata bridge contract passed');
