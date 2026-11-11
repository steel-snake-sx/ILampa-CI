// Fast fixture regression only; real DOM/trusted taps are covered by XCTest.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
let Component;
let played;
let playlist;
function node(html) {
    return {
        html, children: [], handlers: {},
        append(child) { this.children.push(child); },
        on(events, callback) { this.handlers[events] = callback; }
    };
}
function surface() {
    const root = node('surface');
    this.append = child => root.append(child);
    this.render = () => root;
    this.destroy = () => { root.children = []; };
}
vm.runInNewContext(fs.readFileSync('iLampa/Resources/plugins/sample_source_plugin.js', 'utf8'), {
    console,
    $: node,
    Lampa: {
        Scroll: surface, Files: surface,
        Component: { add(name, constructor) { assert.equal(name, 'sample_source'); Component = constructor; } },
        Listener: { follow() {} },
        Player: { play(item) { played = item; }, playlist(items) { playlist = items; } }
    }
});
const component = new Component({ movie: { id: 550 } });
// Same lifecycle order as Activity: ignore create()'s return, mount render().
component.create();
const root = component.render();
assert.equal(component.render(), root, 'Activity must mount the same root');
const rows = root.children[0].children[0].children;
assert.equal(rows.length, 3);
assert.match(rows[0].html, /Apple Test Stream \(BipBop 1080p\)/);
assert.equal(played, undefined, 'Construction must not auto-play');
rows[0].handlers['click hover:enter']();
assert.equal(played.title, 'Apple Test Stream (BipBop 1080p)');
assert.match(played.url, /^https:\/\/devstreaming-cdn\.apple\.com\//);
assert.equal(playlist.length, 3);
component.destroy();
assert.equal(root.children.length, 0);
console.log('PASS sample source Activity lifecycle and selection callback (stub DOM, not E2E)');
