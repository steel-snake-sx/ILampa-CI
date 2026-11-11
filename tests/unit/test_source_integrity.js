/**
 * Cheap Windows/Linux-safe checks before requesting an expensive macOS runner.
 * They catch stale type names and the misplaced XCTest regression we hit in CI.
 * They do not replace a real Swift compiler or simulator tests.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8');
const sources = path.join(root, 'iLampa', 'Sources');

function swiftFiles(dir) {
    return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
        const p = path.join(dir, entry.name);
        return entry.isDirectory() ? swiftFiles(p) : entry.name.endsWith('.swift') ? [p] : [];
    });
}

const obsoleteCalls = [
    'PoCHybridTestView',
    'CatalogSettingsView',
    'CatalogUrlView',
    'NetworkCheckView',
    'DownloadsView',
    'WebKitMaintenanceConfirmationView',
    'PreferredVoiceView',
    'GlobalSubsView',
    'GlobalQualityView',
    'WebKitComponentDetailView',
    'WebKitScriptDetailView',
    'PluginCapabilityDetailsView'
];

for (const file of swiftFiles(sources)) {
    const content = fs.readFileSync(file, 'utf8');
    for (const name of obsoleteCalls) {
        const call = new RegExp('\\b' + name + '\\s*\\(');
        assert.ok(!call.test(content), 'Obsolete Swift view call ' + name + ' in ' + path.relative(root, file));
    }
}

// A private Swift view cannot be constructed from another source file.
// This specific mistake previously caused a full macOS compilation failure.
const developerTools = read('iLampa/Sources/Views/DeveloperToolsView.swift');
assert.ok(developerTools.includes('private struct WebKitEngineDiagnosticsView'),
    'DeveloperToolsView must retain its private engine diagnostics implementation');
for (const file of swiftFiles(sources)) {
    if (path.basename(file) === 'DeveloperToolsView.swift') continue;
    const source = fs.readFileSync(file, 'utf8');
    assert.ok(!/\bWebKitEngineDiagnosticsView\s*\(/.test(source),
        'Inaccessible private WebKitEngineDiagnosticsView used from ' + path.relative(root, file));
}

const rootView = read('iLampa/Sources/App/ContentView.swift');
assert.ok(!rootView.includes('revealPlayerActionsButton') &&
          !rootView.includes('closePlayerButton'),
    'Do not recreate duplicate AVKit transport actions');
assert.ok(rootView.includes('.ignoresSafeArea()'),
    'Native player must fill the video presentation area');

// Keep the single native AVKit controller when URL/episode changes.
const playerModel = read('iLampa/Sources/Player/PlayerModel.swift');
assert.ok(playerModel.includes('var id: String { "\\(action)_\\(canonicalId ?? hash ?? url)" }'),
    'PlayPayload presentation identity must not depend on the episode URL');
assert.ok(playerModel.includes('static func chooseNextSource('),
    'Next episode must enforce original provider/voice selection');
assert.ok(rootView.includes('resolveNextEpisodeFromProvider(for: payload)'),
    'Unknown native playlists must resolve through the current source');
assert.ok(rootView.includes('onControlsInteraction: { showPlayerActionsTemporarily() }') &&
          rootView.includes('.simultaneousGesture(TapGesture().onEnded { showPlayerActionsTemporarily() })') &&
          !rootView.includes('togglePlayerActionsOnTap()') &&
          rootView.includes('.seconds(3)') && !rootView.includes('.seconds(7)'),
    'Every user tap must reveal custom controls even if both AVKit and SwiftUI gestures fire');
assert.ok(read('iLampa/Sources/Services/ImageNetworkDiagnostics.swift').includes('inspectFailure(of url: URL)'),
    'Artworks must log safe failures when their CDN is unreachable');

const test = read('tests/runtime/PluginPersistenceTests.swift');
const suiteStart = test.indexOf('final class PluginPersistenceTests: XCTestCase {');
const methodStart = test.indexOf('func testStagedUpdatePreservesTrustedScriptUntilExactApproval()');
const suiteEnd = test.indexOf('\n}\n\n/// Session-local transport:');
const helperStart = test.indexOf('private final class DelayedPluginURLProtocol: URLProtocol {');
assert.ok(suiteStart >= 0 && methodStart > suiteStart && suiteEnd > methodStart && helperStart > suiteEnd,
    'Staged-update test must be inside PluginPersistenceTests, before DelayedPluginURLProtocol');
assert.equal(test.split('func testStagedUpdatePreservesTrustedScriptUntilExactApproval()').length - 1, 1,
    'Staged-update regression test must have exactly one definition');

console.log('Source integrity precheck passed (obsolete views and XCTest location).');
