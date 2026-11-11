/** Contract probes for the shipped Lampa implementation, not a native compatibility test. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../../iLampa/Resources/www/app.min.js'), 'utf8');

// Extract named functions from the bundled runtime instead of reimplementing their logic.
function functionSource(name, nextComment) {
    const start = source.indexOf('\n  function ' + name + '(');
    assert.notEqual(start, -1, `missing ${name}`);
    const end = source.indexOf(nextComment, start);
    assert.notEqual(end, -1, `missing end marker for ${name}`);
    return source.slice(start, end);
}

const templates = [];
const changes = [];
const disk = new Map();
const ctx = {
    components$1: {}, params$3: {}, values: {}, defaults: {}, readed: {}, reserve: {},
    Template: { add: (...args) => templates.push(args) },
    Arrays: { isObject: v => v !== null && typeof v === 'object' && !Array.isArray(v),
        isArray: Array.isArray, getKeys: Object.keys },
    listener: { send: (...args) => changes.push(args) },
    window: { localStorage: {
        getItem: key => disk.has(key) ? disk.get(key) : null,
        setItem: (key, value) => disk.set(key, String(value)),
        removeItem: key => disk.delete(key)
    } },
    console
};
vm.createContext(ctx);
const beforeComment = '  /**';
for (const name of ['addComponent', 'addParam', 'getParam', 'getComponent', 'removeComponent',
    'removeParams', 'trigger', 'select', 'get$1', 'set', 'field$1', 'field']) {
    vm.runInContext(functionSource(name, beforeComment), ctx, { filename: name });
}
ctx.Storage = { get: ctx.get$1, set: ctx.set };
ctx.Params = { trigger: ctx.trigger, select: ctx.select, field: ctx.field$1 };

ctx.addComponent({ component: 'sample', name: 'Sample', icon: '<svg/>' });
assert.equal(templates[0][0], 'settings_sample');
const trigger = { component: 'sample', param: { name: 'enabled', type: 'trigger', default: false }, field: { name: 'Enabled' } };
const select = { component: 'sample', param: { name: 'quality', type: 'select', values: { low: 'Low', high: 'High' }, default: 'high' }, field: { name: 'Quality' } };
const input = { component: 'sample', param: { name: 'server', type: 'input', default: 'example' }, field: { name: 'Server' } };
for (const param of [trigger, select, input]) ctx.addParam(param);
assert.deepEqual(Array.from(ctx.getParam('sample')), [trigger, select, input]);
assert.equal(ctx.field('enabled'), false);
assert.equal(ctx.field('quality'), 'high');
assert.equal(ctx.field('server'), 'example');
assert.equal(ctx.values.quality.high, 'High');

// Lampa's toggle handler writes the strings "true"/"false", not booleans, to Storage.
ctx.set('enabled', 'true');
assert.equal(disk.get('enabled'), 'true');
assert.equal(ctx.field('enabled'), true);
assert.equal(changes.at(-1)[0], 'change');
assert.equal(changes.at(-1)[1].value, 'true');
ctx.set('quality', '123');
ctx.readed = {}; // emulate the next document reading persistent localStorage
assert.equal(ctx.field('quality'), 123); // numeric strings are converted by Storage.get
ctx.set('server', '');
ctx.readed = {};
assert.equal(ctx.field('server'), 'example'); // upstream treats an empty value as its default

// Exercise the shipped Params.bind event handler with a minimal event-element harness.
vm.runInContext(functionSource('bind', beforeComment), ctx, { filename: 'bind' });
ctx.update$3 = () => {};
ctx.listener$1 = { send: (...args) => changes.push(args) };
ctx.Lang = { translate: value => value };
ctx.Controller = { enabled: () => ({ name: 'settings' }), toggle() {} };
ctx.Navigator = { focused() {} };
ctx.$ = element => element;
ctx.Input = { edit: (_, done) => done('changed input') };
ctx.Select = { show: options => options.onSelect({ value: 'low' }) };
const callbackValues = [];
function activate(type, name) {
    const element = { data: key => ({ type, name, onChange: value => {
        callbackValues.push({ type, value, stored: disk.get(name) });
    } })[key] };
    let enter;
    const elements = {
        on(event, handler) { if (event === 'hover:enter') enter = handler; return this; },
        each() { return this; },
        eq() { return { data: () => undefined }; }
    };
    ctx.bind(elements, {});
    enter({ target: element });
}
activate('toggle', 'enabled');
activate('input', 'server');
activate('select', 'quality');
activate('button', 'action');
assert.deepEqual(callbackValues, [
    { type: 'toggle', value: 'false', stored: 'false' },
    { type: 'input', value: 'changed input', stored: 'changed input' },
    { type: 'select', value: 'low', stored: 'low' },
    { type: 'button', value: undefined, stored: undefined }
]);
assert.equal(changes.at(-1)[0], 'button');

ctx.removeParams('sample');
assert.equal(ctx.getParam('sample'), undefined);
assert.equal(ctx.getComponent('sample').name, 'Sample');
ctx.addParam(trigger);
ctx.removeComponent('sample');
assert.equal(ctx.getComponent('sample'), undefined);
assert.equal(ctx.getParam('sample'), undefined);
assert.equal(disk.get('enabled'), 'false'); // removing settings does not erase storage

console.log('Bundled legacy SettingsApi/Storage contract probes passed (not WKWebView or native verification).');
