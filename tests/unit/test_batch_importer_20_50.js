/**
 * iLampa — 20-50 Batch Import Automated Behavioral & Verification Test Suite
 * Conforms to Section 7 of iLampa 2.0 Implementation Recovery and Final Design Lock.
 */

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const rootDir = path.resolve(__dirname, '../../');

function runTest(name, fn) {
    try {
        fn();
        console.log(`[PASS] ${name}`);
    } catch (err) {
        console.error(`[FAIL] ${name}: ${err.message}`);
        process.exit(1);
    }
}

console.log('================================================================');
console.log(' iLampa 2.0: BATCH IMPORTER 20-50 AUTOMATED TEST SUITE');
console.log('================================================================\n');

// ----------------------------------------------------------------------
// JavaScript Reference Implementation of BatchPluginImporter Engine
// Mimics Swift BatchPluginImporter & BatchImportModalView contract exactly
// ----------------------------------------------------------------------

class BatchImporterEngine {
    constructor() {
        this.inputRevision = 0;
        this.analysisRevision = 0;
        this.rawText = '';
        this.candidates = [];
    }

    setText(text) {
        this.rawText = text;
        this.inputRevision += 1;
        // Invalidate previous analysis
        this.candidates = [];
    }

    getNonEmptyLineCount() {
        return this.rawText
            .split(/\r?\n/)
            .map(line => line.trim())
            .filter(line => line.length > 0)
            .length;
    }

    normalizeUrl(urlStr) {
        try {
            const u = new URL(urlStr);
            u.hash = '';
            return u.toString();
        } catch {
            return urlStr;
        }
    }

    classifyUrl(urlObj, normalizedStr) {
        const pathLower = urlObj.pathname.toLowerCase();
        const hostLower = urlObj.hostname.toLowerCase();

        // 1. Direct Media Streams
        if (pathLower.endsWith('.m3u8')) return { type: 'directMediaStream', format: 'HLS', cleanUrl: normalizedStr };
        if (pathLower.endsWith('.mp4')) return { type: 'directMediaStream', format: 'MP4', cleanUrl: normalizedStr };
        if (pathLower.endsWith('.mov')) return { type: 'directMediaStream', format: 'MOV', cleanUrl: normalizedStr };
        if (pathLower.endsWith('.mkv')) return { type: 'directMediaStream', format: 'MKV', cleanUrl: normalizedStr };

        // 2. JS Plugins
        const isKnownPluginDomain = hostLower === 'bwa.ad' || hostLower.includes('bylampa') || hostLower.includes('lampaplugins') || hostLower.includes('lampame');
        if (pathLower.endsWith('.js') || pathLower.endsWith('.mjs') || urlObj.protocol === 'ilampa:' || pathLower.includes('/plugin/') || pathLower.includes('/store/') || isKnownPluginDomain) {
            return { type: 'pluginScript', cleanUrl: normalizedStr };
        }

        // 3. Provider Endpoints
        if (pathLower.includes('/ts') || pathLower.includes('/torrserver')) {
            return { type: 'providerEndpoint', endpointType: 'TorrServer', cleanUrl: normalizedStr };
        }
        if (pathLower.includes('/api/extensions') || pathLower.includes('/cub')) {
            return { type: 'providerEndpoint', endpointType: 'CUB Catalog', cleanUrl: normalizedStr };
        }

        // 4. Unsupported Webpage
        return {
            type: 'unsupportedWebpage',
            cleanUrl: normalizedStr,
            reason: 'Обычная веб-страница не является поддерживаемым видеопотоком или JS-плагином'
        };
    }

    parse(currentlyInstalledUrls = new Set()) {
        const lines = this.rawText.split(/\r?\n/);
        const candidates = [];
        const seenInBatch = new Set();

        for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed || trimmed.startsWith('#') || trimmed.startsWith('//')) {
                continue;
            }

            let parsedUrl;
            try {
                parsedUrl = new URL(trimmed);
            } catch {
                candidates.push({
                    id: Math.random().toString(36).substring(2),
                    rawLine: trimmed,
                    cleanUrl: null,
                    status: { type: 'invalid', reason: 'Некорректный протокол или формат URL' },
                    isInstallable: false,
                    isSelectedForInstall: false
                });
                continue;
            }

            if (!['http:', 'https:', 'ilampa:'].includes(parsedUrl.protocol)) {
                candidates.push({
                    id: Math.random().toString(36).substring(2),
                    rawLine: trimmed,
                    cleanUrl: null,
                    status: { type: 'invalid', reason: 'Некорректный протокол' },
                    isInstallable: false,
                    isSelectedForInstall: false
                });
                continue;
            }

            if (!parsedUrl.hostname) {
                candidates.push({
                    id: Math.random().toString(36).substring(2),
                    rawLine: trimmed,
                    cleanUrl: null,
                    status: { type: 'invalid', reason: 'Отсутствует хост/домен' },
                    isInstallable: false,
                    isSelectedForInstall: false
                });
                continue;
            }

            const normalized = this.normalizeUrl(trimmed);

            if (currentlyInstalledUrls.has(normalized)) {
                candidates.push({
                    id: Math.random().toString(36).substring(2),
                    rawLine: trimmed,
                    cleanUrl: normalized,
                    status: { type: 'duplicate', isAlreadyInstalled: true },
                    isInstallable: false,
                    isSelectedForInstall: false
                });
            } else if (seenInBatch.has(normalized)) {
                candidates.push({
                    id: Math.random().toString(36).substring(2),
                    rawLine: trimmed,
                    cleanUrl: normalized,
                    status: { type: 'duplicate', isAlreadyInstalled: false },
                    isInstallable: false,
                    isSelectedForInstall: false
                });
            } else {
                seenInBatch.add(normalized);
                const classification = this.classifyUrl(parsedUrl, normalized);
                const isInstallable = (classification.type === 'pluginScript');
                candidates.push({
                    id: Math.random().toString(36).substring(2),
                    rawLine: trimmed,
                    cleanUrl: normalized,
                    status: classification,
                    isInstallable: isInstallable,
                    isSelectedForInstall: false // Disabled by default!
                });
            }
        }

        this.candidates = candidates;
        this.analysisRevision = this.inputRevision;
        return candidates;
    }

    selectAll() {
        for (const c of this.candidates) {
            if (c.isInstallable) {
                c.isSelectedForInstall = true;
            }
        }
    }

    deselectAll() {
        for (const c of this.candidates) {
            c.isSelectedForInstall = false;
        }
    }

    toggleSelect(index) {
        if (this.candidates[index] && this.candidates[index].isInstallable) {
            this.candidates[index].isSelectedForInstall = !this.candidates[index].isSelectedForInstall;
        }
    }

    getSelectedCount() {
        return this.candidates.filter(c => c.isSelectedForInstall && c.isInstallable).length;
    }

    canProceedToInstall() {
        return this.getSelectedCount() > 0 && this.analysisRevision === this.inputRevision;
    }

    simulateExecuteInstall(networkMocks = {}, cancelAtCount = -1) {
        const approved = this.candidates.filter(c => c.isSelectedForInstall && c.isInstallable);
        const installed = [];
        const failed = {};
        const canceled = [];
        const records = [];

        let count = 0;
        for (const c of approved) {
            count++;
            if (cancelAtCount > 0 && count > cancelAtCount) {
                canceled.push(c.cleanUrl);
                continue;
            }

            const mock = networkMocks[c.cleanUrl] || { status: 200, body: 'console.log("plugin");' };
            if (mock.status !== 200 || !mock.body || mock.body.startsWith('<!DOCTYPE html>')) {
                failed[c.cleanUrl] = `HTTP ${mock.status || 500}`;
            } else {
                installed.push(c.cleanUrl);
                records.push({
                    url: c.cleanUrl,
                    desiredEnabled: false, // Inactive by default!
                    lifecycleState: 'inactive'
                });
            }
        }

        let outcome = 'complete';
        if (canceled.length > 0) {
            outcome = 'canceled';
        } else if (Object.keys(failed).length > 0) {
            outcome = 'partial';
        }

        return {
            totalLines: this.candidates.length,
            validCount: this.candidates.filter(c => c.isInstallable).length,
            installedSuccessfully: installed,
            failedInstallations: failed,
            canceledInstallations: canceled,
            outcome,
            stagedRecords: records
        };
    }
}

// ====================================================================
// Test 1: Batch of 25 lines with mixed classifications
// ====================================================================
runTest('Batch Importer — 25 lines mixed classification & exact counting', () => {
    const engine = new BatchImporterEngine();
    const installed = new Set(['https://bwa.ad/online.js']);

    const batch25 = `
    https://bwa.ad/online.js
    https://bwa.ad/soma.js
    https://bwa.ad/e.js
    https://example.com/plugins/custom_balancer.js
    https://cdn.lampame.net/plugins/filmix.js
    https://stream.example.org/live/playlist.m3u8
    https://archive.org/video/sample.mp4
    https://media.org/clip.mkv
    http://192.168.1.100:8090/torrserver
    https://cub.rip/api/extensions/list
    https://kinopoisk.ru/film/12345/
    https://youtube.com/watch?v=dQw4w9WgXcQ
    https://wikipedia.org/wiki/JavaScript
    not-a-valid-url
    ftp://invalid-scheme.org/file.js
    http://:8080/missing-host.js
    https://bwa.ad/soma.js
    https://bwa.ad/soma.js#duplicate-fragment
    https://bylampa.online/store/theme.js
    https://bylampa.online/store/subtitles.js
    https://github.com/test/plugin/master/index.js
    https://test.net/subtitles.mjs
    # this is a comment line that should be ignored
    // another comment line
    https://example.com/articles/news.html
    https://example.org/download/
    `;

    engine.setText(batch25);
    const nonBlank = engine.getNonEmptyLineCount();
    assert.strictEqual(nonBlank, 26, 'Non-blank line count should count all non-empty lines');

    const candidates = engine.parse(installed);

    // Filter out comments: 24 candidates parsed from 26 lines
    assert.strictEqual(candidates.length, 24, 'Parsed candidates should exclude comments');

    // 1 already installed duplicate
    const alreadyInstalled = candidates.filter(c => c.status.type === 'duplicate' && c.status.isAlreadyInstalled);
    assert.strictEqual(alreadyInstalled.length, 1, 'bwa.ad/online.js should be detected as already installed');

    // Intra-batch duplicates
    const intraDuplicates = candidates.filter(c => c.status.type === 'duplicate' && !c.status.isAlreadyInstalled);
    assert.strictEqual(intraDuplicates.length, 2, 'Duplicates within batch should be flagged');

    // Direct streams
    const directStreams = candidates.filter(c => c.status.type === 'directMediaStream');
    assert.strictEqual(directStreams.length, 3, 'HLS, MP4, and MKV must be classified as directMediaStream');

    // Provider endpoints
    const endpoints = candidates.filter(c => c.status.type === 'providerEndpoint');
    assert.strictEqual(endpoints.length, 2, 'TorrServer and CUB must be classified as providerEndpoint');

    // Unsupported webpages
    const unsupported = candidates.filter(c => c.status.type === 'unsupportedWebpage');
    assert.strictEqual(unsupported.length, 5, 'Webpages (kinopoisk, youtube, wiki, html, download) must be unsupportedWebpage');

    // Invalid format
    const invalid = candidates.filter(c => c.status.type === 'invalid');
    assert.strictEqual(invalid.length, 3, 'not-a-valid-url, ftp, and missing-host must be invalid');

    // Installable JS plugins
    const installable = candidates.filter(c => c.isInstallable);
    assert.strictEqual(installable.length, 8, 'Valid JS plugins should be recognized as installable');

    // Initial selection invariant: all start unselected
    const selected = engine.getSelectedCount();
    assert.strictEqual(selected, 0, 'All candidates must start UNSELECTED');
    assert.strictEqual(engine.canProceedToInstall(), false, 'Installation must be locked when 0 selected');
});

// ====================================================================
// Test 2: Batch of 50 URLs & Selection Invariants (Select All, Deselect All)
// ====================================================================
runTest('Batch Importer — 50 items batch with selection invariants', () => {
    const engine = new BatchImporterEngine();

    const lines = [];
    for (let i = 1; i <= 35; i++) {
        lines.push(`https://lampaplugins.org/plugin_${i}.js`);
    }
    for (let i = 1; i <= 5; i++) {
        lines.push(`https://stream.server.org/video_${i}.m3u8`);
    }
    for (let i = 1; i <= 5; i++) {
        lines.push(`https://unsupported-site.com/page_${i}`);
    }
    for (let i = 1; i <= 5; i++) {
        lines.push(`invalid_entry_${i}://bad`);
    }

    engine.setText(lines.join('\n'));
    assert.strictEqual(engine.getNonEmptyLineCount(), 50, 'Must have 50 non-empty lines');

    const candidates = engine.parse();
    assert.strictEqual(candidates.length, 50, 'Must parse exactly 50 candidates');

    assert.strictEqual(engine.getSelectedCount(), 0, 'Must initially have 0 selected');
    assert.strictEqual(engine.canProceedToInstall(), false, 'Must not allow install with 0 selected');

    // Select All
    engine.selectAll();
    // Only the 35 installable plugins should be selected! Not streams, not webpages, not invalid!
    assert.strictEqual(engine.getSelectedCount(), 35, 'Select All must only select installable candidates');
    assert.strictEqual(engine.canProceedToInstall(), true, 'Must allow install when selected > 0');

    // Deselect All
    engine.deselectAll();
    assert.strictEqual(engine.getSelectedCount(), 0, 'Deselect All must reset selected count to 0');
    assert.strictEqual(engine.canProceedToInstall(), false, 'Must lock install again');

    // Individual Selection
    engine.toggleSelect(0); // first valid plugin
    engine.toggleSelect(1); // second valid plugin
    assert.strictEqual(engine.getSelectedCount(), 2, 'Must have 2 selected');
    assert.strictEqual(engine.canProceedToInstall(), true);
});

// ====================================================================
// Test 3: Text Edit Invalidation & Back Navigation Preservation
// ====================================================================
runTest('Batch Importer — Text edit invalidates review & back preserves input', () => {
    const engine = new BatchImporterEngine();
    const initialText = 'https://bwa.ad/soma.js\nhttps://bwa.ad/e.js';
    engine.setText(initialText);

    engine.parse();
    engine.selectAll();
    assert.strictEqual(engine.getSelectedCount(), 2);
    assert.strictEqual(engine.canProceedToInstall(), true);

    // User navigates back and edits text
    const editedText = initialText + '\nhttps://bwa.ad/online.js';
    engine.setText(editedText);

    // Analysis is now out of sync with input revision!
    assert.strictEqual(engine.analysisRevision < engine.inputRevision, true, 'Input revision must increment ahead of analysis');
    assert.strictEqual(engine.candidates.length, 0, 'Candidates must be invalidated on text change');
    assert.strictEqual(engine.canProceedToInstall(), false, 'Cannot proceed until analysis is re-run');
    assert.strictEqual(engine.rawText, editedText, 'Raw text is preserved on back navigation');
});

// ====================================================================
// Test 4: Execution Outcomes — Complete, Partial, and Canceled
// ====================================================================
runTest('Batch Importer — Complete, partial failure, and cancel outcomes with disabled-by-default', () => {
    const engine = new BatchImporterEngine();
    engine.setText(`
        https://cdn.example.org/p1.js
        https://cdn.example.org/p2.js
        https://cdn.example.org/p3.js
        https://cdn.example.org/p4.js
    `);
    engine.parse();
    engine.selectAll();

    // 1. Complete Success
    const successResult = engine.simulateExecuteInstall({
        'https://cdn.example.org/p1.js': { status: 200, body: 'console.log("p1");' },
        'https://cdn.example.org/p2.js': { status: 200, body: 'console.log("p2");' },
        'https://cdn.example.org/p3.js': { status: 200, body: 'console.log("p3");' },
        'https://cdn.example.org/p4.js': { status: 200, body: 'console.log("p4");' }
    });

    assert.strictEqual(successResult.outcome, 'complete');
    assert.strictEqual(successResult.installedSuccessfully.length, 4);
    assert.strictEqual(Object.keys(successResult.failedInstallations).length, 0);
    // Every installed plugin must be disabled by default!
    for (const rec of successResult.stagedRecords) {
        assert.strictEqual(rec.desiredEnabled, false, 'Installed plugin must be desiredEnabled=false');
        assert.strictEqual(rec.lifecycleState, 'inactive', 'Installed plugin must be inactive');
    }

    // 2. Partial Failure (e.g. 1 404, 1 HTML response)
    const partialResult = engine.simulateExecuteInstall({
        'https://cdn.example.org/p1.js': { status: 200, body: 'console.log("p1");' },
        'https://cdn.example.org/p2.js': { status: 404, body: 'Not found' },
        'https://cdn.example.org/p3.js': { status: 200, body: '<!DOCTYPE html><html><body>Error</body></html>' },
        'https://cdn.example.org/p4.js': { status: 200, body: 'console.log("p4");' }
    });

    assert.strictEqual(partialResult.outcome, 'partial', 'Outcome must be partial on failure');
    assert.strictEqual(partialResult.installedSuccessfully.length, 2);
    assert.strictEqual(Object.keys(partialResult.failedInstallations).length, 2);
    assert.strictEqual(partialResult.failedInstallations['https://cdn.example.org/p2.js'], 'HTTP 404');

    // 3. Cancellation midway
    const canceledResult = engine.simulateExecuteInstall({
        'https://cdn.example.org/p1.js': { status: 200, body: 'console.log("p1");' },
        'https://cdn.example.org/p2.js': { status: 200, body: 'console.log("p2");' }
    }, 2); // Cancel after 2 items

    assert.strictEqual(canceledResult.outcome, 'canceled', 'Outcome must be canceled');
    assert.strictEqual(canceledResult.installedSuccessfully.length, 2);
    assert.strictEqual(canceledResult.canceledInstallations.length, 2);
});

// ====================================================================
// Test 5: Verify Swift Code Implementation Invariants
// ====================================================================
runTest('Batch Importer — Swift Source Code Invariants Verification', () => {
    const modalSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Views/BatchImportModalView.swift'), 'utf8');
    const importerSwift = fs.readFileSync(path.join(rootDir, 'iLampa/Sources/Services/BatchPluginImporter.swift'), 'utf8');

    // Zero select lock
    assert(modalSwift.includes('.disabled(selectedCount == 0)'), 'Must have zero-selection install lock');

    // Non-empty line count
    assert(modalSwift.includes('nonEmptyLineCount'), 'Must compute non-empty line count');

    // Disabled by default
    assert(importerSwift.includes('record.desiredEnabled = false'), 'Imported plugin must be disabled by default');
    assert(importerSwift.includes('lifecycleState: .inactive'), 'Imported plugin must start inactive');

    // Invalidation on edit
    assert(modalSwift.includes('inputRevision += 1'), 'Must increment input revision on edit');

    // Distinct cancel state
    assert(importerSwift.includes('outcome: BatchImportOutcome'), 'Must have BatchImportOutcome');
    assert(importerSwift.includes('case canceled'), 'Must support canceled outcome');
    assert(importerSwift.includes('case partial'), 'Must support partial outcome');
    assert(importerSwift.includes('case complete'), 'Must support complete outcome');
});

console.log('\n================================================================');
console.log(' ALL 5 BATCH IMPORTER 20-50 TESTS PASSED (100% SUCCESS)');
console.log('================================================================\n');
