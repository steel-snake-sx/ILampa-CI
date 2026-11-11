import XCTest
@testable import iLampa

@MainActor
final class PluginLabTests: XCTestCase {

    // MARK: - Discovery & Normalization Tests

    func testDiscoveryDeduplicationAndPrioritization() {
        let rawURL1 = "https://EXAMPLE.COM/plugins/test.js?foo=1#section"
        let rawURL2 = "https://example.com/plugins/test.js?foo=1"
        let norm1 = PluginLabDiscovery.normalizeURL(rawURL1)
        let norm2 = PluginLabDiscovery.normalizeURL(rawURL2)

        XCTAssertEqual(norm1, norm2, "URLs with case differences and fragments must normalize to the same string")

        let discovery = PluginLabDiscovery.shared
        let inventory = discovery.discoverPlugins()

        XCTAssertFalse(inventory.isEmpty, "Discovery should find at least curated and bundled plugins")

        // Check deduplication
        let uniqueURLs = Set(inventory.map(\.url))
        XCTAssertEqual(inventory.count, uniqueURLs.count, "Discovered inventory must have strictly deduplicated URLs")

        // Curated plugins must be present
        XCTAssertTrue(inventory.contains { $0.url.contains("soma.js") }, "SomaFM must be present in discovery")
        XCTAssertTrue(inventory.contains { $0.url.contains("e.js") }, "e.js must be present in discovery")
    }

    func testPilotShikimoriSeedUsesLivePublisherPath() {
        let inventory = PluginLabDiscovery.shared.discoverPlugins()
        XCTAssertFalse(inventory.contains {
            $0.origin == .catalog &&
            $0.url == "https://lampame.github.io/main/shikimori.js"
        }, "Diagnostic seeds must not repeatedly probe the known HTTP 404 URL")
        XCTAssertTrue(inventory.contains {
            $0.url == "https://lampame.github.io/main/Shikimori/Shikimori.js"
        }, "Shikimori should be diagnosed from the publisher's current script path")
    }

    func testStableIdGeneration() {
        let id1 = PluginLabItem.makeStableId(url: "https://tsynik.github.io/lampa/e.js", name: "e.js (Меню выхода)")
        XCTAssertFalse(id1.isEmpty)
        XCTAssertFalse(id1.contains("/"), "Stable ID must be safe for filenames")
        XCTAssertFalse(id1.contains(":"), "Stable ID must be safe for filenames")
        XCTAssertFalse(id1.contains(" "), "Stable ID must not contain spaces")

        let id2 = PluginLabItem.makeStableId(url: "https://tsynik.github.io/lampa/soma.js", name: "SomaFM Radio")
        XCTAssertNotEqual(id1, id2, "Different plugins must have distinct stable IDs")
        let sameNameDifferentURL = PluginLabItem.makeStableId(url: "https://different.example/e.js", name: "e.js (Меню выхода)")
        XCTAssertNotEqual(id1, sameNameDifferentURL, "Stable IDs must not collide for identical names")
    }

    // MARK: - UI & Component Compatibility Tests (e.js Regression)

    func testUIProbeDetectsUnsupportedJSInterfaceAndMissingAction() {
        var rawReport = PluginProbeRawReport()
        rawReport.registeredComponents = [
            .init(
                name: "exit_m",
                isPlatform: false,
                hasNativeRenderer: false,
                lifecycleMethods: ["create", "build", "start", "destroy"],
                instantiationSuccess: true,
                instantiationError: nil
            )
        ]
        rawReport.domAdditions = [
            .init(
                tag: "li",
                action: "exit_r",
                className: "menu__item selector",
                text: "Выход"
            )
        ]
        rawReport.platformQueries = ["apple_tv", "tizen", "webos", "android"]

        let (components, failures, summaries) = PluginUIProbe.analyze(
            rawReport: rawReport,
            pluginUrl: "https://tsynik.github.io/lampa/e.js",
            pluginName: "e.js"
        )

        XCTAssertEqual(components.count, 1)
        let comp = components[0]
        XCTAssertEqual(comp.name, "exit_m")
        XCTAssertFalse(comp.hasNativeRenderer)
        XCTAssertTrue(comp.actionHandlers.contains("exit_r"))
        XCTAssertTrue(comp.missingActions.isEmpty, "Unknown data-action does not prove a missing handler")

        // Exact regression test verification:
        XCTAssertTrue(failures.isEmpty, "Feature detection and DOM insertion are not errors")
        XCTAssertTrue(summaries.isEmpty, "Do not invent UI failures without actual interaction")
    }

    // MARK: - Capability Analyzer Classification Tests

    func testCapabilityAnalyzerClassificationVerdicts() {
        let item = PluginLabItem(
            id: "test_plugin",
            name: "Test Plugin",
            url: "https://example.com/test.js",
            origin: .catalog,
            initialEnabledState: false,
            isInstalled: false
        )

        // Scenario 1: Network Failure -> BLOCKED
        let netResult = PluginCapabilityAnalyzer.analyze(
            item: item,
            rawReport: PluginProbeRawReport(),
            uiComponents: [],
            uiFailures: [.networkFailure],
            uiSummaries: ["HTTP 404"],
            downloadError: "HTTP 404 Not Found"
        )
        XCTAssertEqual(netResult.status, .blocked)
        XCTAssertEqual(netResult.primaryRootCause, .networkFailure)

        // Scenario 2: JS Exception -> FAIL
        var jsFailReport = PluginProbeRawReport()
        jsFailReport.jsErrors = [.init(message: "TypeError: undefined is not a function", filename: nil, lineno: nil, colno: nil, stack: nil)]
        let jsResult = PluginCapabilityAnalyzer.analyze(
            item: item,
            rawReport: jsFailReport,
            uiComponents: [],
            uiFailures: [],
            uiSummaries: [],
            downloadError: nil
        )
        XCTAssertEqual(jsResult.status, .fail)
        XCTAssertEqual(jsResult.primaryRootCause, .runtimeInitializationFailure)

        // Scenario 3: confirmed render failure -> PARTIAL
        let partialResult = PluginCapabilityAnalyzer.analyze(
            item: item,
            rawReport: PluginProbeRawReport(),
            uiComponents: [],
            uiFailures: [.unsupportedCustomUI, .missingNativeBridgeAction],
            uiSummaries: ["JS-интерфейс не поддерживается", "Нативное действие: Недоступно"],
            downloadError: nil
        )
        XCTAssertEqual(partialResult.status, .partial)
        XCTAssertEqual(partialResult.primaryRootCause, .unsupportedCustomUI)

        // Scenario 4: Registered resolver is NOT verified functionality
        var passReport = PluginProbeRawReport()
        passReport.registeredSources = [.init(id: "src1", name: "Working Source", hasResolve: true, hasSearch: true, hasNativeStream: true, isOperational: true)]
        let passResult = PluginCapabilityAnalyzer.analyze(
            item: item,
            rawReport: passReport,
            uiComponents: [],
            uiFailures: [],
            uiSummaries: [],
            downloadError: nil
        )
        XCTAssertEqual(passResult.status, .partial)
        XCTAssertEqual(passResult.confidence, .low)

        let noop = PluginCapabilityAnalyzer.analyze(
            item: item,
            rawReport: PluginProbeRawReport(),
            uiComponents: [],
            uiFailures: [],
            uiSummaries: [],
            downloadError: nil
        )
        XCTAssertEqual(noop.status, .untested, "No-op plugin must never receive PASS")

        var throwingResolver = PluginProbeRawReport()
        throwingResolver.registeredSources = [.init(id: "broken", name: "Broken", hasResolve: true, hasSearch: false, hasNativeStream: false, isOperational: true)]
        throwingResolver.jsErrors = [.init(message: "Resolver callback threw", filename: nil, lineno: nil, colno: nil, stack: "throw new Error()")]
        let failed = PluginCapabilityAnalyzer.analyze(
            item: item, rawReport: throwingResolver, uiComponents: [], uiFailures: [],
            uiSummaries: [], downloadError: nil
        )
        XCTAssertEqual(failed.status, .fail)
    }

    func testProbeReportWithRegistrationMetadataDecodes() throws {
        // The JS probe emits JSON-encoded metadata strings, not nested objects.
        // This exact mismatch previously blocked all 42 plugins in one campaign.
        let json = """
        {
          "events": [
            {
              "timestamp":"2026-11-10T19:00:00Z",
              "level":"INFO",
              "category":"[Component.add]",
              "message":"Component registered",
              "metadata":"{\\"name\\":\\"exit_m\\",\\"isPlatform\\":false,\\"count\\":2}"
            }
          ],
          "jsErrors": [],
          "registeredComponents": [],
          "registeredSources": [],
          "registeredSettings": [],
          "domAdditions": [],
          "platformQueries": [],
          "networkRequests": [],
          "uiFailures": [],
          "apiTouches": {}
        }
        """
        let parsed = try JSONDecoder().decode(PluginProbeRawReport.self, from: Data(json.utf8))
        XCTAssertEqual(parsed.events.count, 1)
        XCTAssertEqual(parsed.events.first?["message"], "Component registered")
        XCTAssertTrue(parsed.events.first?["metadata"]?.contains("exit_m") == true)
    }

    // MARK: - Privacy Redaction Tests

    func testPrivacyRedaction() {
        let sensitive = "GET /api?token=secret12345&key=mykey99&auth=pass777 Header: Bearer eyJhbGciOiJIUzI1NiJ9 Cookie: session=abcdefg"
        let sanitized = PluginDiagnosticsRecorder.redactSensitiveData(sensitive)

        XCTAssertFalse(sanitized.contains("secret12345"), "Token must be redacted")
        XCTAssertFalse(sanitized.contains("mykey99"), "API key must be redacted")
        XCTAssertFalse(sanitized.contains("pass777"), "Auth parameter must be redacted")
        XCTAssertFalse(sanitized.contains("eyJhbGciOiJIUzI1NiJ9"), "Bearer token must be redacted")
        XCTAssertFalse(sanitized.contains("session=abcdefg"), "Cookie must be redacted")
        XCTAssertTrue(sanitized.contains("[REDACTED]"))

        // Test length truncation > 8 KiB
        let oversized = String(repeating: "A", count: 9000)
        let truncated = PluginDiagnosticsRecorder.redactSensitiveData(oversized)
        XCTAssertTrue(truncated.contains("[TRUNCATED >8KiB]"))
        XCTAssertLessThanOrEqual(truncated.utf8.count, 8192)
    }

    func testZIPMarksUnicodeFilenamesAsUTF8() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-lab-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: path) }
        try DiagnosticsZipArchiver.createZip(
            entries: [.init(name: "plugins/Рейтинг_CUB/result.json", data: Data("{}".utf8))],
            destinationURL: path
        )
        let data = try Data(contentsOf: path)
        XCTAssertGreaterThan(data.count, 40)
        XCTAssertEqual(data[6], 0x00)
        XCTAssertEqual(data[7], 0x08, "Local ZIP header must mark UTF-8 filenames")
        let signature = Data([0x50, 0x4B, 0x01, 0x02])
        guard let range = data.range(of: signature) else {
            return XCTFail("Missing ZIP central directory")
        }
        XCTAssertEqual(data[range.lowerBound + 8], 0x00)
        XCTAssertEqual(data[range.lowerBound + 9], 0x08,
                       "Central ZIP header must mark UTF-8 filenames")
    }

    func testArchivedStorageValuesAreAlwaysRedacted() {
        let oldReport = #"{"message":"Storage set: account_user = private-account-value","token":"VERYPRIVATE"}"#
        let result = PluginDiagnosticsRecorder.redactArchiveText(oldReport)
        XCTAssertFalse(result.contains("private-account-value"))
        XCTAssertFalse(result.contains("VERYPRIVATE"))
        XCTAssertNotNil(result.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0)
        })
    }

    // MARK: - Checkpoint Persistence & Resume Tests

    func testCheckpointPersistenceAndResume() {
        let recorder = PluginDiagnosticsRecorder.shared
        let sessionID = UUID()
        let testItem = PluginLabItem(
            id: "checkpoint_test",
            name: "Checkpoint Item",
            url: "https://example.com/cp.js",
            origin: .custom,
            initialEnabledState: false,
            isInstalled: false,
            status: .pass,
            confidence: .high
        )

        recorder.saveCheckpoint(sessionID: sessionID, items: [testItem], completedIDs: ["checkpoint_test"])

        // Small wait for barrier queue sync
        let checkpoint = recorder.loadCheckpoint()
        XCTAssertNotNil(checkpoint)
        XCTAssertEqual(checkpoint?.sessionID, sessionID)
        XCTAssertEqual(checkpoint?.completedPluginIDs, ["checkpoint_test"])
        XCTAssertEqual(checkpoint?.items.first?.name, "Checkpoint Item")

        recorder.clear()
        XCTAssertNil(recorder.loadCheckpoint(), "Checkpoint must be removed after clear()")
    }

    // MARK: - Report Exporter ZIP Archive Structure Tests

    func testReportExporterZIPArchiveStructure() throws {
        let sessionID = UUID()
        let env = PluginLabEnvironment(
            appVersion: "2.0.1",
            buildNumber: "16",
            gitCommit: "plugin-lab-test",
            iosVersion: "18.0",
            deviceModel: "iPhone16,1",
            runtimeType: "WebKit",
            webkitConfiguration: "Policy None",
            testRunnerVersion: "PluginLab-Runner/2.0",
            startedAt: Date()
        )

        var item = PluginLabItem(
            id: "tsynik_e_js",
            name: "e.js",
            url: "https://tsynik.github.io/lampa/e.js",
            origin: .curated,
            initialEnabledState: false,
            isInstalled: false,
            sha256: "abcdef123456",
            byteCount: 1500,
            status: .partial,
            confidence: .high,
            primaryRootCause: .unsupportedCustomUI,
            failureSummary: "JS-интерфейс не поддерживается: Нативное действие: Недоступно"
        )
        item.stage = .completed

        let evidence = PluginDiagnosticEvidence(
            item: item,
            timeline: [
                .init(stage: "activating", category: "[Probe]", message: "Plugin evaluated", level: "INFO")
            ],
            jsErrors: [],
            nativeErrors: [],
            uiComponents: [
                .init(
                    name: "exit_m",
                    isPlatform: false,
                    hasNativeRenderer: false,
                    nativeActionStatus: "Нативное действие: Недоступно",
                    lifecycleMethods: ["create", "destroy"],
                    instantiationSuccess: true,
                    instantiationError: nil,
                    actionHandlers: ["exit_r"],
                    missingActions: ["exit_r"],
                    domElementsCreated: ["<li>"],
                    platformDependencies: ["apple_tv", "tizen"]
                )
            ],
            apiCoverage: [
                .init(apiName: "Lampa.Component.add", isReferenced: true, isUsedAtRuntime: true, isSupported: true, note: nil)
            ],
            bridgeEvents: [["action": "register"]],
            networkErrors: [],
            screenshotData: nil
        )

        let zipURL = try PluginReportExporter.exportArchive(
            sessionID: sessionID,
            environment: env,
            inventory: [item],
            allEvidence: [evidence],
            duration: 2.5
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path), "PluginLab-Report.zip must exist on disk")
        let zipData = try Data(contentsOf: zipURL)
        XCTAssertGreaterThan(zipData.count, 100, "ZIP archive must not be empty")

        // Clean up
        try? FileManager.default.removeItem(at: zipURL)
    }

    func testArchiveRedactionKeepsFullJSON() {
        let large = String(repeating: "test", count: 3000)
        let payload = "{\"token\":\"MYSECRET\",\"description\":\"\(large)\"}"
        let result = PluginDiagnosticsRecorder.redactArchiveText(payload)
        XCTAssertFalse(result.contains("MYSECRET"))
        XCTAssertTrue(result.contains(large), "Complete JSON must not be truncated during export")
        XCTAssertNotNil(result.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0)
        }, "Redacted JSON must remain parseable")
    }

    func testEvidencePersistedToDisk() {
        let recorder = PluginDiagnosticsRecorder.shared
        let item = PluginLabItem(
            id: "persistence_test", name: "Persistence", url: "https://example.com/persist.js",
            origin: .custom, initialEnabledState: false, isInstalled: false
        )
        let evidence = PluginDiagnosticEvidence(
            item: item,
            timeline: [.init(stage: "test", category: "[Evidence]", message: "Persisted event")],
            jsErrors: [], nativeErrors: [], uiComponents: [],
            apiCoverage: [], bridgeEvents: [["message": "stored"]], networkErrors: [],
            screenshotData: nil
        )
        recorder.recordEvidence(evidence)
        XCTAssertNotNil(recorder.getEvidence(for: item.id))
        XCTAssertTrue(recorder.allEvidence().contains { $0.item.id == item.id })
        recorder.clear()
        XCTAssertNil(recorder.getEvidence(for: item.id))
    }

    // MARK: - State Isolation Tests

    func testUserPluginStatePreservation() {
        let pluginManager = PluginManager.shared
        let initialInstalled = pluginManager.installedPlugins

        // Verify that running coordinator or discovery never modifies user's installed list
        let discovery = PluginLabDiscovery.shared
        _ = discovery.discoverPlugins()

        XCTAssertEqual(pluginManager.installedPlugins, initialInstalled, "Discovery must never alter user's installed plugin list")
    }
}
