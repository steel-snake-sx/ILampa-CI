/**
 * iLampa — Final Design Lock Verification Suite
 * Validates complete conformance to C:\dev\ILampa\iLampa_Stage1_6_Final\docs\DESIGN_LOCK.md:
 * 1. 4-Tab Architecture & Canonical Search
 * 2. 9 Settings Direct Destinations
 * 3. 4-Stage Transactional Batch Importer with 20-line Counting & Zero-Select Lock
 * 4. Compact Source Picker (iPhone XS 3-Facet Layout + Independent Sort + 2x03 Identity)
 * 5. Plugin Capabilities, JS Attribution Isolation (cub_sport / shots_*), and Unsupported Compatibility View
 * 6. Native Diagnostics (16 MiB / 7-day / 8x2MiB Bounded Retention, 24h Detailed TTL, Privacy Scrub, WebKit-Dead Fallback)
 */

const assert = require('assert');
const fs = require('fs');
const path = require('path');

console.log('================================================================');
console.log(' iLampa: FINAL DESIGN LOCK AUTOMATED VERIFICATION SUITE');
console.log('================================================================\n');

let passCount = 0;
let failCount = 0;
const tests = [];

function runTest(name, testFn) {
    tests.push({ name, testFn });
}

const rootDir = path.resolve(__dirname, '../..');

// ====================================================================
// Test 1: Four permanent tabs, one canonical SearchView
// ====================================================================
runTest('Navigation — Каталог, Поиск, Моё, Настройки in one TabView', () => {
    const content = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/App/ContentView.swift'), 'utf8');
    for (const [index, label] of [['0', 'Каталог'], ['1', 'Поиск'], ['2', 'Моё'], ['3', 'Настройки']]) {
        assert(content.includes(`.tag(${index})`) && content.includes(`Label("${label}"`), `Missing tab ${index} ${label}`);
    }
    assert(!content.includes('.tag(4)'), 'No fifth tab');
    assert(content.includes('SearchView(onPlayRequest:'), 'Root must host the canonical SearchView');
});

// ====================================================================
// Test 2: Catalog entries switch to the canonical search tab
// ====================================================================
runTest('Navigation — catalog entries use the same Search tab', () => {
    const catalog = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/CatalogView.swift'), 'utf8');
    assert(catalog.includes('catalogSearchEntry'), 'Prominent catalog search entry');
    assert(catalog.includes('catalogSearchToolbarButton'), 'Catalog toolbar search entry');
    assert(catalog.includes('TextField("Поиск фильмов'), 'Catalog search must be editable in place');
    assert(catalog.includes('.onSubmit { submitCatalogSearch() }'), 'Catalog must submit before switching tabs');
    assert(catalog.includes('onSearchRequested(submitted)'), 'Only a submitted query may navigate to results');
    const search = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/SearchView.swift'), 'utf8');
    assert(search.includes('catalogSearchInput'), 'Search must have a persistent input');
    assert(!search.includes('.searchable('), 'Do not use collapsing search modifier');
});

// ====================================================================
// Test 3: Settings 9 Direct Destinations
// ====================================================================
runTest('Settings — 8 purposeful destinations without duplicate catalog navigation', () => {
    const settingsSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/SettingsView.swift'), 'utf8');

    assert(settingsSwift.includes('navPlayerOptions'), 'Settings must route to Воспроизведение');
    assert(settingsSwift.includes('navSourcesManagement'), 'Settings must route to Источники');
    assert(settingsSwift.includes('navExtensions'), 'Settings must route to Плагины');
    assert(!settingsSwift.includes('navCatalogSettings'), 'Catalog and network settings share one canonical destination');
    assert(settingsSwift.includes('navNetwork'), 'Settings must route to Сеть');
    assert(settingsSwift.includes('navStorage'), 'Settings must route to Хранилище');
    assert(settingsSwift.includes('navAppearance'), 'Settings must route to Внешний вид');
    assert(settingsSwift.includes('navDiagnostics'), 'Settings must route to Диагностика');
    assert(settingsSwift.includes('navAbout'), 'Settings must route to Об iLampa');
});

// ====================================================================
// Test 4: 4-Stage Batch Importer State Machine & Invariants
// ====================================================================
runTest('Design Lock M2 — 4-Stage Importer, 20-line count, zero-select lock', () => {
    const modalSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/BatchImportModalView.swift'), 'utf8');

    // 4 stages
    assert(modalSwift.includes('case input'), 'BatchImportStage must include input');
    assert(modalSwift.includes('case review'), 'BatchImportStage must include review');
    assert(modalSwift.includes('case installing'), 'BatchImportStage must include installing');
    assert(modalSwift.includes('case results'), 'BatchImportStage must include results');

    // Non-empty line counting logic
    assert(modalSwift.includes('nonEmptyLineCount'), 'Importer must compute non-blank line count');

    // Zero-selection install lock
    assert(modalSwift.includes('.disabled(selectedCount == 0)'), 'Installer must disable install button when 0 items selected');

    // Toolbar Done dismissal
    assert(modalSwift.includes('placement: .keyboard') && modalSwift.includes('Готово'), 'Importer must have reachable Done keyboard button');

    // Preservation of input on return from review
    assert(modalSwift.includes('currentStage = .input'), 'Review must allow navigation back to input');
});

// ====================================================================
// Test 5: Batch Importer Outcomes & Disabled-by-Default
// ====================================================================
runTest('Design Lock M2 — Batch Importer complete, partial, and canceled outcomes', () => {
    const importerSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Services/BatchPluginImporter.swift'), 'utf8');

    assert(importerSwift.includes('case complete'), 'BatchImportOutcome must have complete');
    assert(importerSwift.includes('case partial'), 'BatchImportOutcome must have partial');
    assert(importerSwift.includes('case canceled'), 'BatchImportOutcome must have canceled');
    assert(importerSwift.includes('desiredEnabled = false'), 'Imported plugins must be staged disabled by default');
    assert(importerSwift.includes('lifecycleState: .inactive'), 'Imported plugins must have lifecycleState inactive');
});

// ====================================================================
// Test 6: Compact Source Picker & iPhone XS 3-Facet Layout
// ====================================================================
runTest('Design Lock M3 — Source Picker 3 facets, independent sort, 2x03 identity', () => {
    const pickerSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/SourcePickerSheetView.swift'), 'utf8');

    assert(pickerSwift.includes('facet_quality'), 'Picker must have facet_quality');
    assert(pickerSwift.includes('facet_studio'), 'Picker must have facet_studio');
    assert(pickerSwift.includes('facet_provider'), 'Picker must have facet_provider');
    assert(pickerSwift.includes('picker_sorting_button'), 'Picker must have independent sorting button');

    // Episode 2x03 identity
    assert(pickerSwift.includes('episodeIdentityText'), 'Picker must compute explicit episode identity text');

    // Recovery failure sheet
    assert(pickerSwift.includes('struct ResolveFailureView'), 'Must define ResolveFailureView');
    assert(pickerSwift.includes('retryResolutionButton'), 'ResolveFailureView must have retry button');
    assert(pickerSwift.includes('chooseAnotherSourceButton'), 'ResolveFailureView must have choose another source button');
    assert(pickerSwift.includes('configureSourceRecoveryButton'), 'ResolveFailureView must have configure source button');
    assert(pickerSwift.includes('viewLogsRecoveryButton'), 'ResolveFailureView must have view logs button');
});

// ====================================================================
// Test 7: JavaScript Component Attribution Isolation (cub_sport / shots_*)
// ====================================================================
runTest('Design Lock M4 — Platform component attribution isolation in bridge & host', () => {
    const bridgeJs = fs.readFileSync(path.join(rootDir, 'iLampa/Resources/lampa_bridge.js'), 'utf8');
    const hostSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Web/LampaHeadlessHost.swift'), 'utf8');

    // Bridge checks platform components before last plugin url
    assert(bridgeJs.includes('name.indexOf(\'cub_\') === 0 || name.indexOf(\'shots_\') === 0'),
           'lampa_bridge.js must isolate cub_ and shots_ platform components');

    // Swift host drops or categorizes platform components without resolving to unrelated plugin
    assert(hostSwift.includes('name.hasPrefix("cub_") || name.hasPrefix("shots_")'),
           'LampaHeadlessHost must identify cub_ and shots_ platform components');
    assert(hostSwift.includes('Зарегистрирован платформенный компонент Lampa'),
           'LampaHeadlessHost must log platform components cleanly');
});

// ====================================================================
// Test 8: Unsupported Plugin UI & Actions Presentation
// ====================================================================
runTest('Design Lock M4 — Plugin unsupported view without fake launch button', () => {
    const pluginViewsSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/PluginExtensionsDetailViews.swift'), 'utf8');

    assert(pluginViewsSwift.includes('struct PluginUnsupportedView'), 'Must define PluginUnsupportedView');
    assert(pluginViewsSwift.includes('struct PluginActionsView'), 'Must define PluginActionsView');
    assert(pluginViewsSwift.includes('struct PluginSettingsApiView'), 'Must define PluginSettingsApiView');
    assert(pluginViewsSwift.includes('struct PluginCollisionsView'), 'Must define PluginCollisionsView');

    // No fake "Запустить" button in PluginUnsupportedView
    assert(!pluginViewsSwift.includes('Button("Запустить")'), 'PluginUnsupportedView must NEVER contain a fake "Запустить" button');
});

// ====================================================================
// Test 9: Diagnostics Bounded Retention & Privacy Scrub
// ====================================================================
runTest('Diagnostics — 16 MiB disk ring, configurable bounded memory and 24h detailed TTL', () => {
    const logManagerSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Services/DiagnosticsLogManager.swift'), 'utf8');

    assert(logManagerSwift.includes('maxMemoryEntries: Int') &&
           logManagerSwift.includes('10000') &&
           logManagerSwift.includes('ilampa_diagnostics_memory_entries'),
           'In-memory buffer must have an explicit, configurable upper limit');
    assert(logManagerSwift.includes('16 * 1024 * 1024'), 'Disk quota must be 16 MiB');
    assert(logManagerSwift.includes('maxSegmentBytes: Int64 = 2 * 1024 * 1024'), 'Each segment must be max 2 MiB');
    assert(logManagerSwift.includes('maxSegmentsCount = 8'), 'Must rotate across 8 segments');
    assert(logManagerSwift.includes('7 * 86400'), 'Must enforce 7-day age expiry');

    // 24h Detailed TTL
    assert(logManagerSwift.includes('detailedModeTtlKey'), 'Must track 24h detailed mode TTL key');
    assert(logManagerSwift.includes('checkDetailedModeTtl'), 'Must check detailed mode expiration');

    // WebKit offline view
    const diagSettings = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/DiagnosticsSettingsView.swift'), 'utf8');
    const diagExport = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/DiagnosticsExportView.swift'), 'utf8');
    assert(diagSettings.includes('struct WebKitOfflineView'), 'Must implement WebKitOfflineView');
    assert(diagExport.includes('struct PrivacyExportView'), 'Must implement PrivacyExportView');
    assert(diagSettings.includes('struct LogRetentionPolicyView'), 'Must implement LogRetentionPolicyView');
});

// ====================================================================
// Test 10: Sources Manager Singleton Add & Unconfigured State
// ====================================================================
runTest('Design Lock M5 — Sources manager empty state center CTA and unconfigured button', () => {
    const sourcesViewSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/SourcesManagementView.swift'), 'utf8');

    assert(sourcesViewSwift.includes('centerAddSourceButton'), 'Empty state must have centerAddSourceButton');
    assert(sourcesViewSwift.includes('status == .unconfigured || status == .authRequired ? "Настроить" : "Подробнее"'),
           'Unconfigured sources must expose a direct setup action');
});

// ====================================================================
// Test 11: Generalized Async Component Attribution & Promise Propagation
// ====================================================================
runTest('Design Lock M4 — Generalized async component attribution without last-plugin fallback', () => {
    const bridgeJs = fs.readFileSync(path.join(rootDir, 'iLampa/Resources/lampa_bridge.js'), 'utf8');

    // Must NOT fall back to __ilampaLastPluginURL
    assert(!bridgeJs.includes('pluginUrl = window.__ilampaLastPluginURL'),
           'Component registration must NEVER fall back to window.__ilampaLastPluginURL');

    // Must wrap Promise.prototype.then and setTimeout for lexical closure propagation
    assert(bridgeJs.includes('Promise.prototype.then') && bridgeJs.includes('wrapCallback'),
           'lampa_bridge.js must propagate plugin execution context across Promise chains');
    assert(bridgeJs.includes('window.setTimeout') && bridgeJs.includes('wrapCallback'),
           'lampa_bridge.js must propagate plugin execution context across setTimeout callbacks');
});

// ====================================================================
// Test 12: Bundle ID, AppIcon, Version, Monotonic Build & Git SHA
// ====================================================================
runTest('Design Lock Identity — Bundle ID, AppIcon, Version, Build Number, Git SHA', () => {
    const projectYml = fs.readFileSync(path.join(rootDir, 'project.yml'), 'utf8');
    const infoPlist = fs.readFileSync(path.join(rootDir, 'iLampa/Info.plist'), 'utf8');
    const settingsSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/SettingsView.swift'), 'utf8');
    const diagSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/DiagnosticsConsoleView.swift'), 'utf8');

    // Bundle ID com.steelsnake.ilampa
    assert(projectYml.includes('PRODUCT_BUNDLE_IDENTIFIER: "com.steelsnake.ilampa"'), 'project.yml must use com.steelsnake.ilampa');
    assert(infoPlist.includes('<string>com.steelsnake.ilampa</string>'), 'Info.plist must use com.steelsnake.ilampa');

    // Release identity: verify the source-of-truth and its checked-in plist agree.
    // Codemagic increases CFBundleVersion during the build; checked-in base must
    // already be above the previously delivered 2.0.1 (1002) release.
    const marketingVersion = projectYml.match(/^\s*MARKETING_VERSION:\s*"([^"]+)"\s*$/m)?.[1];
    const baseBuild = Number(projectYml.match(/^\s*CURRENT_PROJECT_VERSION:\s*"(\d+)"\s*$/m)?.[1]);
    const projectPlistVersion = projectYml.match(/^\s*CFBundleShortVersionString:\s*"([^"]+)"\s*$/m)?.[1];
    const projectPlistBuild = Number(projectYml.match(/^\s*CFBundleVersion:\s*"(\d+)"\s*$/m)?.[1]);
    const plistMarketingVersion = infoPlist.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/)?.[1];
    const plistBuild = Number(infoPlist.match(/<key>CFBundleVersion<\/key>\s*<string>(\d+)<\/string>/)?.[1]);
    assert.strictEqual(marketingVersion, '2.2.1', 'Current integration patch must be iLampa 2.2.1');
    assert(Number.isInteger(baseBuild) && baseBuild >= 2000, 'Build base must be >= 2000');
    assert.strictEqual(projectPlistVersion, marketingVersion, 'project.yml Info.plist version must match MARKETING_VERSION');
    assert.strictEqual(projectPlistBuild, baseBuild, 'project.yml Info.plist build must match CURRENT_PROJECT_VERSION');
    assert.strictEqual(plistMarketingVersion, marketingVersion, 'Info.plist marketing version must match project.yml');
    assert.strictEqual(plistBuild, baseBuild, 'Info.plist build base must match project.yml');

    // AppIcon assets
    assert(fs.existsSync(path.join(rootDir, 'iLampa/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-Dark.png')), 'Dark AppIcon asset must exist');
    assert(fs.existsSync(path.join(rootDir, 'iLampa/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-Light.png')), 'Light AppIcon asset must exist');

    // Git commit SHA display in About and Diagnostics
    assert(settingsSwift.includes('Text("Коммит")') && settingsSwift.includes('ILAMPA_GIT_COMMIT'),
           'AboutSettingsView must display Git commit SHA');
    assert(diagSwift.includes('Text("Коммит")') && diagSwift.includes('ILAMPA_GIT_COMMIT'),
           'DiagnosticsConsoleView must display Git commit SHA');
});

// ====================================================================
// Test Runner
// ====================================================================
(async function main() {
    for (const { name, testFn } of tests) {
        try {
            await testFn();
            console.log(`[PASS] ${name}`);
            passCount++;
        } catch (error) {
            console.error(`[FAIL] ${name}: ${error.stack || error}`);
            failCount++;
        }
    }
    console.log(`\n================================================================`);
    console.log(` RESULTS: ${passCount} PASSED, ${failCount} FAILED (TOTAL: ${passCount + failCount})`);
    console.log(`================================================================`);
    process.exitCode = failCount > 0 ? 1 : 0;
})();
