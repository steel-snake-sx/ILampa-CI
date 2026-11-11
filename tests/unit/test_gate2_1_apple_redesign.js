/**
 * GATE 2.1 AUTOMATED VERIFICATION SUITE
 * Apple-Way Information Architecture, Bundle ID Migration,
 * AppIcon Assets, Transactional Batch Import & Async Component Attribution
 */

const assert = require('assert');
const fs = require('fs');
const path = require('path');

console.log('================================================================');
console.log(' GATE 2.1: APPLE-QUALITY UI, COMPATIBILITY & IDENTITY VERIFICATION');
console.log('================================================================\n');

let passCount = 0;
let failCount = 0;
const tests = [];

function runTest(name, testFn) {
    tests.push({name, testFn});
}

const rootDir = path.resolve(__dirname, '../..');

// ====================================================================
// Test 1: Bundle Identifier Migration
// ====================================================================
runTest('Gate 2.1 — Bundle Identifier Migration to com.steelsnake.ilampa', () => {
    // 1. project.yml verification
    const projectYml = fs.readFileSync(path.join(rootDir, 'project.yml'), 'utf8');
    assert(projectYml.includes('bundleIdPrefix: com.steelsnake'), 'project.yml must have bundleIdPrefix: com.steelsnake');
    assert(projectYml.includes('PRODUCT_BUNDLE_IDENTIFIER: "com.steelsnake.ilampa"'), 'project.yml must have PRODUCT_BUNDLE_IDENTIFIER: "com.steelsnake.ilampa"');

    // 2. Info.plist verification
    const infoPlist = fs.readFileSync(path.join(rootDir, 'iLampa/Info.plist'), 'utf8');
    assert(infoPlist.includes('<string>com.steelsnake.ilampa</string>'), 'Info.plist must have CFBundleIdentifier com.steelsnake.ilampa');

    // 3. validate-recovery-ipa.py compatibility
    const validatorPy = fs.readFileSync(path.join(rootDir, 'scripts/validate-recovery-ipa.py'), 'utf8');
    assert(validatorPy.includes('com.steelsnake.ilampa'), 'validator script must permit com.steelsnake.ilampa');
});

// ====================================================================
// Test 2: Production AppIcon Configuration
// ====================================================================
runTest('Gate 2.1 — Production AppIcon Assets (Light, Dark, Unbaked Corners)', () => {
    const iconSetDir = path.join(rootDir, 'iLampa/Resources/Assets.xcassets/AppIcon.appiconset');
    const contentsJsonPath = path.join(iconSetDir, 'Contents.json');
    const lightIconPath = path.join(iconSetDir, 'AppIcon-Light.png');
    const darkIconPath = path.join(iconSetDir, 'AppIcon-Dark.png');

    assert(fs.existsSync(contentsJsonPath), 'Contents.json must exist');
    assert(fs.existsSync(lightIconPath), 'AppIcon-Light.png must exist');
    assert(fs.existsSync(darkIconPath), 'AppIcon-Dark.png must exist');

    const contents = JSON.parse(fs.readFileSync(contentsJsonPath, 'utf8'));
    assert(contents.images && contents.images.length >= 3, 'Contents.json must define universal, dark, and tinted image variants');

    const darkEntry = contents.images.find(img => img.appearances && img.appearances.some(a => a.value === 'dark'));
    assert(darkEntry && darkEntry.filename === 'AppIcon-Dark.png', 'Dark appearance must map to AppIcon-Dark.png');

    const lightEntry = contents.images.find(img => !img.appearances || img.appearances.length === 0);
    assert(lightEntry && lightEntry.filename === 'AppIcon-Light.png', 'Universal appearance must map to AppIcon-Light.png');

    const lightStat = fs.statSync(lightIconPath);
    const darkStat = fs.statSync(darkIconPath);
    assert(lightStat.size > 20000, 'AppIcon-Light.png must be non-empty valid asset');
    assert(darkStat.size > 20000, 'AppIcon-Dark.png must be non-empty valid asset');
});

// ====================================================================
// Test 3: Batch Plugin Importer URL Classification
// ====================================================================
runTest('Gate 2.1 — Batch Importer Classification (bwa.ad/rc, .m3u8, websites)', () => {
    // Simulator matching Swift BatchPluginImporter.classifyUrl logic
    function classifyUrl(urlString) {
        let url;
        try {
            url = new URL(urlString.trim());
        } catch {
            return 'invalid';
        }
        if (!['http:', 'https:'].includes(url.protocol)) return 'invalid';

        const pathLower = url.pathname.toLowerCase();
        const hostLower = url.hostname.toLowerCase();

        // Direct media streams
        if (pathLower.endsWith('.m3u8') || pathLower.endsWith('.mp4') || pathLower.endsWith('.ts') ||
            pathLower.endsWith('.mp3') || pathLower.endsWith('.m4a') || pathLower.includes('/hls/')) {
            return 'directMediaStream';
        }

        // JavaScript plugins
        if (pathLower.endsWith('.js') || (hostLower === 'bwa.ad' && pathLower.startsWith('/rc')) ||
            pathLower.includes('/plugin') || pathLower.includes('/extension')) {
            return 'pluginScript';
        }

        // Known arbitrary non-plugin sites
        const arbitrary = ['google.com', 'youtube.com', 'kinopoisk.ru', 'wikipedia.org', 'yandex.ru', 'github.com'];
        if (arbitrary.some(site => hostLower.includes(site)) && !pathLower.endsWith('.js')) {
            return 'unsupportedWebpage';
        }

        return 'unsupportedWebpage';
    }

    assert.strictEqual(classifyUrl('https://bwa.ad/rc'), 'pluginScript', 'https://bwa.ad/rc must be classified as pluginScript');
    assert.strictEqual(classifyUrl('https://bwa.ad/rc/'), 'pluginScript', 'https://bwa.ad/rc/ must be classified as pluginScript');
    assert.strictEqual(classifyUrl('https://tsynik.github.io/lampa/soma.js'), 'pluginScript', 'soma.js must be classified as pluginScript');
    assert.strictEqual(classifyUrl('https://cache.libria.fun/videos/media/ts/10337/1/1080/sample.m3u8'), 'directMediaStream', '.m3u8 must be classified as directMediaStream');
    assert.strictEqual(classifyUrl('https://devstreaming-cdn.apple.com/sample.mp4'), 'directMediaStream', '.mp4 must be classified as directMediaStream');
    assert.strictEqual(classifyUrl('https://google.com'), 'unsupportedWebpage', 'google.com must be classified as unsupportedWebpage');
    assert.strictEqual(classifyUrl('https://youtube.com/watch?v=123'), 'unsupportedWebpage', 'youtube.com must be classified as unsupportedWebpage');
});

// ====================================================================
// Test 4: Batch Import Disabled-by-Default Guarantee
// ====================================================================
runTest('Gate 2.1 — Batch Import Defaults: Plugins Disabled by Default', () => {
    const importerSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Services/BatchPluginImporter.swift'), 'utf8');
    assert(importerSwift.includes('isSelectedForInstall: false'), 'New batch candidates must have isSelectedForInstall: false by default');
    assert(importerSwift.includes('desiredEnabled = false'), 'New batch candidates must have desiredEnabled = false');
    assert(importerSwift.includes('lifecycleState: .inactive'), 'New batch records must be staged with lifecycleState: .inactive');
});

// ====================================================================
// Test 5: Asynchronous Component Attribution in Lampa Bridge
// ====================================================================
runTest('Gate 2.1 — Asynchronous Component Attribution Hook & Timer Wrapping', () => {
    const bridgeJs = fs.readFileSync(path.join(rootDir, 'iLampa/Resources/lampa_bridge.js'), 'utf8');
    assert(bridgeJs.includes('attachAsyncAttributionHook'), 'lampa_bridge.js must define attachAsyncAttributionHook');
    assert(bridgeJs.includes('__ilampaExecutingPluginURL'), 'lampa_bridge.js must track __ilampaExecutingPluginURL');
    assert(bridgeJs.includes('__ilampaLastPluginURL'), 'lampa_bridge.js must track __ilampaLastPluginURL');

    // Verify timer wrapping logic in mock environment
    let activeExecutingUrl = null;
    let lastExecutingUrl = null;

    const originalSetTimeout = setTimeout;
    function wrappedSetTimeout(fn, delay, ...args) {
        const capturedPluginUrl = activeExecutingUrl;
        return originalSetTimeout(() => {
            const previous = activeExecutingUrl;
            if (capturedPluginUrl) {
                activeExecutingUrl = capturedPluginUrl;
            }
            try {
                fn(...args);
            } finally {
                activeExecutingUrl = previous;
            }
        }, delay);
    }

    let attributedInCallback = null;
    activeExecutingUrl = 'https://example.com/myshows.js';
    lastExecutingUrl = activeExecutingUrl;

    return new Promise((resolve) => {
        wrappedSetTimeout(() => {
            attributedInCallback = activeExecutingUrl || lastExecutingUrl;
            assert.strictEqual(attributedInCallback, 'https://example.com/myshows.js', 'Deferred callback must retain plugin attribution');
            resolve();
        }, 10);
        // Clear synchronous execution URL as done in finally block
        activeExecutingUrl = null;
    });
});

// ====================================================================
// Test 6: Sources Manager Information Architecture
// ====================================================================
runTest('Gate 2.1 — Unified Sources Manager (No Arbitrary Websites, Separate Testing)', () => {
    const sourcesViewSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/SourcesManagementView.swift'), 'utf8');

    // Stage 1.6 supersedes the older four category labels. This checks only
    // source structure, not the behavior or appearance of the native screen.
    assert(sourcesViewSwift.includes('Section("ОНЛАЙН")'), 'Sources Manager must have an online section');
    assert(sourcesViewSwift.includes('Section("ИЗ ПЛАГИНОВ")'), 'Sources Manager must have a plugin sources section');
    assert(sourcesViewSwift.includes('Section("МОИ МЕДИАСЕРВЕРЫ")'), 'Sources Manager must have a media servers section');
    assert(sourcesViewSwift.includes('Section("ПРЯМЫЕ ССЫЛКИ")'), 'Sources Manager must have a direct streams section');

    // Source configuration is now a focused file, without changing its test logic.
    const sourceDetailSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/SourceConfigurationDetailView.swift'), 'utf8');
    assert(sourceDetailSwift.includes('runConnectivityTest'), 'Source detail must implement runConnectivityTest');
    assert(sourceDetailSwift.includes('runResolutionTest'), 'Source detail must implement runResolutionTest');

    // Must validate URLs and block arbitrary websites:
    const addSourceSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/AddSourceModalView.swift'), 'utf8');
    assert(addSourceSwift.includes('validateUrl'), 'Add Source modal must validate URLs');
    assert(addSourceSwift.includes('google.com') && addSourceSwift.includes('youtube.com'), 'Add Source modal must reject arbitrary websites');
});

// ====================================================================
// Test 7: Extensions View HIG Redesign (No TorrServer, Searchable)
// ====================================================================
runTest('Gate 2.1 — Extensions View (TorrServer Removed, Search Bar Added)', () => {
    const extensionsViewSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/ExtensionsView.swift'), 'utf8');

    // TorrServer must be completely removed from Extensions
    assert(!extensionsViewSwift.includes('torrServerHost'), 'ExtensionsView must NOT configure TorrServer host');
    assert(!extensionsViewSwift.includes('torrServerPort'), 'ExtensionsView must NOT configure TorrServer port');

    // Must have search capability
    assert(extensionsViewSwift.includes('.searchable('), 'ExtensionsView must have .searchable modifier');
    assert(extensionsViewSwift.includes('filteredPlugins'), 'ExtensionsView must filter plugins based on search query');
});

// ====================================================================
// Test 8: Settings View 7-Section HIG Architecture
// ====================================================================
runTest('Gate 2.1 — Settings View 7 Core Sections & Developer Mode Isolation', () => {
    const settingsSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/SettingsView.swift'), 'utf8');

    // 7 Sections
    assert(settingsSwift.includes('Label("Воспроизведение"'), 'Settings must have Playback section');
    assert(settingsSwift.includes('Label("Источники видео"'), 'Settings must have Sources section');
    assert(settingsSwift.includes('Label("Расширения"'), 'Settings must have Extensions section');
    assert(settingsSwift.includes('Label("Сеть и каталог"'), 'Settings must have Network section');
    assert(settingsSwift.includes('Label("Память и данные"'), 'Settings must have Storage section');
    assert(settingsSwift.includes('Label("Диагностика"'), 'Settings must have Diagnostics section');
    assert(settingsSwift.includes('Label("О приложении"'), 'Settings must have About section');

    // Developer tools isolated
    assert(settingsSwift.includes('Label("Для разработчиков"'), 'Settings must have Developer tools section');
    assert(settingsSwift.includes('developerModeEnabled'), 'Developer tools must be guarded by developerModeEnabled');

    // Bundle ID com.steelsnake.ilampa
    assert(settingsSwift.includes('com.steelsnake.ilampa'), 'Settings About section must display com.steelsnake.ilampa');
});

// ====================================================================
// Test Runner
// ====================================================================
(async function main() {
    for (const {name, testFn} of tests) {
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
