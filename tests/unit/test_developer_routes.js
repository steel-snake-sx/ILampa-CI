// Source-level safeguards; these do not execute SwiftUI or WebKit.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname, '../../iLampa/Sources/Views/DeveloperToolsView.swift'), 'utf8');
const mediaTest = source.split('private struct DeveloperMediaTestView: View {')[1].split('private struct WebKitCacheView: View {')[0];
assert.match(mediaTest, /"Тест видеопотока", true\)/);
assert.match(source, /ForEach\(registry\.registeredSources\)/);
assert.match(source, /ForEach\(host\.runningPlugins, id: \\.self\)/);
assert(!source.includes('WebKitComponentDetailView('));
assert(!source.includes('WebKitScriptDetailView('));
assert(!source.includes('componentLink(component, owner: "Не определён")'));
console.log('Developer route source safeguards: OK');
