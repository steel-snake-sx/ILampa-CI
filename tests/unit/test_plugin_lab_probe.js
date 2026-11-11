/**
 * Unit test for Plugin Lab Diagnostic Probe & e.js regression detection.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const probeCode = fs.readFileSync('iLampa/Resources/plugins/plugin_lab_probe.js', 'utf8');
const eJsCode = fs.readFileSync('iLampa/Resources/plugins/e.js', 'utf8');

// Set up simulated browser environment
const domNodes = [];
const menuList = {
    append: function (item) {
        domNodes.push(item);
    }
};

const $ = function (selector) {
    if (typeof selector === 'string' && selector.indexOf('<li') >= 0) {
        // Parsing HTML string
        const actionMatch = selector.match(/data-action="([^"]+)"/);
        const action = actionMatch ? actionMatch[1] : null;
        const textMatch = selector.match(/<div class="menu__text">([^<]+)<\/div>/);
        const text = textMatch ? textMatch[1] : '';
        const item = {
            tagName: 'LI',
            className: 'menu__item selector',
            nodeType: 1,
            getAttribute: function (attr) { return attr === 'data-action' ? action : null; },
            textContent: text,
            on: function (event, handler) { this.handler = handler; }
        };
        return {
            on: function (evt, h) { item.on(evt, h); return this; },
            node: item
        };
    }
    if (selector === '.menu .menu__list') {
        return {
            eq: function (idx) {
                return {
                    append: function (wrapper) {
                        menuList.append(wrapper.node || wrapper);
                        // Trigger probe DOM observation simulation
                        if (globalObj.MutationObserverInstance && globalObj.MutationObserverInstance.callback) {
                            globalObj.MutationObserverInstance.callback([{
                                addedNodes: [wrapper.node || wrapper]
                            }]);
                        }
                    }
                };
            }
        };
    }
    return {
        show: function () {},
        hide: function () {},
        append: function () {},
        on: function () {}
    };
};

let observerCallback = null;
class MockMutationObserver {
    constructor(cb) {
        this.callback = cb;
        globalObj.MutationObserverInstance = this;
    }
    observe() {}
    disconnect() {}
}

const globalObj = {
    appready: true,
    MutationObserver: MockMutationObserver,
    console: console,
    setTimeout: setTimeout,
    clearTimeout: clearTimeout,
    document: {
        body: { nodeType: 1 }
    },
    $: $,
    jQuery: $
};
globalObj.window = globalObj;
globalObj.global = globalObj;

// Verify that plugin tests cannot overwrite persisted user settings.
const persistedStorage = { account_user: 'real-user-value' };
globalObj.Lampa = {
    Storage: {
        set: (key, value) => { persistedStorage[key] = value; },
        get: (key, fallback) => Object.prototype.hasOwnProperty.call(persistedStorage, key)
            ? persistedStorage[key] : fallback,
        field: key => persistedStorage[key] || ''
    }
};
const context = vm.createContext(globalObj);
vm.runInContext(probeCode, context);

assert.ok(globalObj.__pluginLab, 'Plugin Lab probe should be defined');
assert.ok(globalObj.Lampa, 'Lampa namespace should be created');

// Background initialization must never be charged to a plugin.
globalObj.Lampa.Component.add('core_component', function () {});
globalObj.Lampa.Storage.get('background_key');
assert.equal(globalObj.__pluginLab.getReport().registeredComponents.length, 0);
assert.equal(Object.keys(globalObj.__pluginLab.getReport().apiTouches).length, 0);

// 2. Run e.js in the same context with the same attribution gate as WebKit.
globalObj.__pluginLab.beginPlugin('bundled://plugins/e.js');
globalObj.__ilampaExecutingPluginURL = 'bundled://plugins/e.js';
vm.runInContext(eJsCode, context);
globalObj.Lampa.Storage.set('account_user', 'script-attempt');
assert.equal(globalObj.Lampa.Storage.get('account_user'), 'script-attempt');
assert.equal(persistedStorage.account_user, 'real-user-value',
    'A plugin test must never write to persisted user settings');
globalObj.__ilampaExecutingPluginURL = null;
globalObj.__pluginLab.endPlugin();
// Asynchronous plugin callbacks must also remain isolated.
globalObj.Lampa.Storage.set('account_user', 'late-script-value');
assert.equal(persistedStorage.account_user, 'real-user-value');

// Post-execution Core activity cannot contaminate the finished plugin report.
globalObj.Lampa.Component.add('later_core_component', function () {});
globalObj.Lampa.Storage.get('background_key');
assert.equal(globalObj.__pluginLab.getReport().registeredComponents.length, 1);

// 3. Inspect report from probe
const report = globalObj.__pluginLab.getReport();
console.log('--- Plugin Lab Probe Report for e.js ---');
console.log('Registered Components:', JSON.stringify(report.registeredComponents, null, 2));
console.log('UI Failures:', JSON.stringify(report.uiFailures, null, 2));
console.log('DOM Additions:', JSON.stringify(report.domAdditions, null, 2));
console.log('Platform Queries:', JSON.stringify(report.platformQueries, null, 2));

// Verifications
assert.equal(report.registeredComponents.length, 1, 'Should register exit_m component');
assert.equal(report.registeredComponents[0].name, 'exit_m');
assert.equal(report.registeredComponents[0].hasNativeRenderer, false, 'exit_m should not have native renderer');

// Registration and data-action alone are NOT proof of a UI or bridge failure.
assert.equal(report.uiFailures.length, 0, 'No speculative compatibility failures');
assert.ok(report.events.some(e => (e.message || '').includes('Custom component requires a real UI check')),
    'Diagnostic must record unverified custom UI without reporting a false failure');

// Verify the exact native JSON contract: event values are strings, including metadata.
const nativeReport = JSON.parse(JSON.stringify(report));
for (const event of nativeReport.events) {
    for (const [key, value] of Object.entries(event)) {
        assert.equal(typeof value, 'string', 'Native report event field ' + key + ' must be a string');
    }
    const metadata = JSON.parse(event.metadata);
    assert.equal(typeof metadata, 'object');
}
assert.ok(nativeReport.events.some(e => JSON.parse(e.metadata).name === 'exit_m'),
    'Nested registration metadata must survive serialization');

// No-op plugin must produce no registrations, API touches, or synthetic PASS.
globalObj.__pluginLab.beginPlugin('bundled://plugins/empty.js');
globalObj.__ilampaExecutingPluginURL = 'bundled://plugins/empty.js';
vm.runInContext('void 0;', context);
globalObj.__ilampaExecutingPluginURL = null;
globalObj.__pluginLab.endPlugin();
const emptyReport = globalObj.__pluginLab.getReport();
assert.equal(emptyReport.registeredComponents.length, 0);
assert.equal(emptyReport.registeredSettings.length, 0);
assert.equal(emptyReport.registeredSources.length, 0);
assert.equal(Object.keys(emptyReport.apiTouches).length, 0);
assert.equal(emptyReport.events.length, 0);

// Check non-destructive storage probe
const probeResult = globalObj.__pluginLab.probeSetting('test_param', 'val123');
assert.equal(probeResult.success, true);
assert.equal(probeResult.restoredValue, undefined);

// The opt-in UI phase must construct an actual plugin UI, not only count
// Component.add registrations. No start(), click() or native playback occurs.
globalObj.__pluginLab.beginPlugin('bundled://plugins/ui-fixture.js');
globalObj.__ilampaExecutingPluginURL = 'bundled://plugins/ui-fixture.js';
let uiCreateCalls = 0;
function ProbeFixtureComponent() {
    this.create = function () {
        uiCreateCalls++;
        const makeRow = n => ({
            nodeType: 1, tagName: 'DIV', className: 'selector',
            textContent: 'Source ' + n,
            getAttribute: () => null
        });
        return {
            nodeType: 1, tagName: 'DIV', className: 'source-list',
            textContent: '', getAttribute: () => null,
            querySelectorAll: () => [makeRow(1), makeRow(2), makeRow(3)]
        };
    };
}
globalObj.Lampa.Component.add('functional_fixture', ProbeFixtureComponent);
globalObj.__ilampaExecutingPluginURL = null;
globalObj.__pluginLab.endPlugin();
assert.equal(uiCreateCalls, 0, 'Registration alone must not instantiate a plugin');
assert.equal(globalObj.__pluginLab.probeRegisteredComponentUI(), 1);
const uiReport = globalObj.__pluginLab.getReport();
assert.equal(uiCreateCalls, 1, 'Behavioral probe must call a real create()');
assert.equal(uiReport.registeredComponents[0].instantiationSuccess, true);
assert.equal(uiReport.domAdditions.length, 3, 'Must report three real selector rows');
assert.ok(uiReport.events.some(e => e.category === '[ComponentUIProbe]' && e.level === 'SUCCESS'));
assert.equal(persistedStorage.account_user, 'real-user-value', 'Probe must preserve user storage');
globalObj.__pluginLab.clear();
assert.equal(globalObj.__pluginLab.getReport().registeredComponents.length, 0);

console.log('All Plugin Lab probe assertions passed successfully!');
