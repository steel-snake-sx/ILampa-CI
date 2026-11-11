import Foundation
import XCTest
import CryptoKit
@testable import iLampa

@MainActor
final class PluginPersistenceTests: XCTestCase {
    private let storageKey = "ilampa_webkit_plugins_v1"

    /// Never use the app's defaults, cache, network, or shared WebKit host in these tests.
    private func withStore(_ body: @MainActor (UserDefaults, URL) async throws -> Void) async throws {
        let suite = "PluginPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache)
        }
        try await body(defaults, cache)
    }

    private func record(_ state: LampaPluginLifecycleState = .active) -> LampaPluginRecord {
        LampaPluginRecord(url: URL(string: "https://plugins.example.test/alpha.js")!,
                          name: "Persistence fixture", lifecycleState: state)
    }

    private func seed(_ records: [LampaPluginRecord], in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(records), forKey: storageKey)
    }

    private func persisted(in defaults: UserDefaults) throws -> [LampaPluginRecord] {
        let data = try XCTUnwrap(defaults.data(forKey: storageKey))
        return try JSONDecoder().decode([LampaPluginRecord].self, from: data)
    }

    private func legacyData(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: rows)
    }

    private func makeManager(defaults: UserDefaults, cache: URL) -> PluginManager {
        PluginManager(defaults: defaults, cacheDirectory: cache, runtimeConfiguration: { _, _ in })
    }

    func testPersistedEmptyArrayDoesNotReinstallDefaultsOnRepeatedInitialization() async throws {
        try await withStore { defaults, cache in
            try self.seed([], in: defaults)
            let first = self.makeManager(defaults: defaults, cache: cache)
            XCTAssertTrue(first.installedPlugins.isEmpty)
            let reloaded = self.makeManager(defaults: defaults, cache: cache)
            XCTAssertTrue(reloaded.installedPlugins.isEmpty)
            XCTAssertEqual(try self.persisted(in: defaults), [])
        }
    }

    func testPersistedRecordsKeepIdentityAndExplicitEnabledSubset() async throws {
        try await withStore { defaults, cache in
            let enabled = self.record(.active)
            var disabled = LampaPluginRecord(url: URL(string: "https://plugins.example.test/beta.js")!,
                                             name: "Disabled", lifecycleState: .active)
            disabled.desiredEnabled = false
            try self.seed([enabled, disabled], in: defaults)
            let manager = self.makeManager(defaults: defaults, cache: cache)
            XCTAssertEqual(manager.installedPlugins.map(\.id), [enabled.id, disabled.id])
            XCTAssertEqual(manager.installedPlugins.map(\.url), [enabled.url, disabled.url])
            XCTAssertEqual(manager.installedPlugins.map(\.isEnabled), [true, false])
            XCTAssertEqual(manager.installedPlugins.map(\.lifecycleState), [.loading, .inactive])
            XCTAssertNil(manager.installedPlugins[0].lastValidatedAt,
                         "Loading persisted intent is not successful script execution")
        }
    }

    func testLegacyRecordsWithoutDesiredEnabledDecodeAndMigrateActiveIntent() async throws {
        try await withStore { defaults, cache in
            var active = self.record(.active)
            var inactive = LampaPluginRecord(url: URL(string: "https://plugins.example.test/beta.js")!,
                                             name: "Legacy disabled", lifecycleState: .inactive)
            active.desiredEnabled = nil
            inactive.desiredEnabled = nil
            let data = try JSONEncoder().encode([active, inactive])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            XCTAssertTrue(json.allSatisfy { $0["desiredEnabled"] == nil })
            let decoded = try JSONDecoder().decode([LampaPluginRecord].self, from: data)
            XCTAssertNil(decoded[0].desiredEnabled)
            XCTAssertEqual(decoded.map(\.isEnabled), [true, false])
            defaults.set(data, forKey: self.storageKey)

            let manager = self.makeManager(defaults: defaults, cache: cache)
            XCTAssertEqual(manager.installedPlugins.map(\.desiredEnabled), [true, false])
            XCTAssertEqual(manager.installedPlugins.map(\.isEnabled), [true, false])
            XCTAssertEqual(manager.installedPlugins.map(\.lifecycleState), [.loading, .inactive])
        }
    }

    func testLegacyV3SchemaMigratesEnabledDisabledIntentAndCachedScriptToStablePath() async throws {
        try await withStore { defaults, cache in
            let legacyURL = "https://plugins.example.test/legacy.js"
            let legacyFileName = "legacy-cached.js"
            let script = "window.legacyMigrationFixture = true;"
            try script.write(to: cache.appendingPathComponent(legacyFileName), atomically: true, encoding: .utf8)
            let legacy = try self.legacyData([
                ["url": legacyURL, "name": "Enabled legacy", "author": "Fixture", "status": 1,
                 "localFileName": legacyFileName],
                ["url": "https://plugins.example.test/disabled.js", "name": "Disabled legacy", "status": 0]
            ])
            defaults.set(legacy, forKey: "ilampa_installed_plugins_v3")

            let manager = self.makeManager(defaults: defaults, cache: cache)
            XCTAssertEqual(manager.installedPlugins.map(\.name), ["Enabled legacy", "Disabled legacy"])
            XCTAssertEqual(manager.installedPlugins.map(\.isEnabled), [true, false])
            XCTAssertEqual(manager.installedPlugins.map(\.lifecycleState), [.loading, .inactive])
            XCTAssertEqual(manager.installedPlugins.first?.author, "Fixture")
            XCTAssertEqual(defaults.data(forKey: "ilampa_installed_plugins_v3"), legacy,
                           "Migration keeps the old record intact for recovery")

            let currentData = try XCTUnwrap(defaults.data(forKey: self.storageKey))
            let currentRecords = try JSONDecoder().decode([LampaPluginRecord].self, from: currentData)
            XCTAssertEqual(currentRecords.map(\.isEnabled), [true, false])
            let stableScriptURL = manager.scriptURL(for: legacyURL)
            let reloaded = self.makeManager(defaults: defaults, cache: cache)
            XCTAssertEqual(reloaded.scriptURL(for: legacyURL), stableScriptURL)
            XCTAssertEqual(try String(contentsOf: stableScriptURL, encoding: .utf8), script)
        }
    }

    func testLegacyEmptyListMigratesToCurrentEmptyIntentWithoutDefaults() async throws {
        try await withStore { defaults, cache in
            let legacy = try self.legacyData([])
            defaults.set(legacy, forKey: "ilampa_installed_plugins_v3")

            let manager = self.makeManager(defaults: defaults, cache: cache)
            XCTAssertTrue(manager.installedPlugins.isEmpty)
            XCTAssertEqual(try self.persisted(in: defaults), [])
            XCTAssertEqual(defaults.data(forKey: "ilampa_installed_plugins_v3"), legacy)
            XCTAssertTrue(self.makeManager(defaults: defaults, cache: cache).installedPlugins.isEmpty)
        }
    }

    func testCorruptCurrentAndLegacyBytesFailClosedWithoutOverwritingEitherKey() async throws {
        try await withStore { defaults, cache in
            let corruptCurrent = Data([0x00, 0xFF, 0x11])
            let validLegacy = try self.legacyData([
                ["url": "https://plugins.example.test/legacy.js", "name": "Must not migrate", "status": 1]
            ])
            defaults.set(corruptCurrent, forKey: self.storageKey)
            defaults.set(validLegacy, forKey: "ilampa_installed_plugins_v3")

            let currentManager = self.makeManager(defaults: defaults, cache: cache)
            currentManager.invalidateRuntimeCapabilities()
            currentManager.installPreparedScript("window.shouldNotExecute = true;", url: "https://plugins.example.test/new.js", name: "Blocked until explicit reset")
            XCTAssertTrue(currentManager.installedPlugins.isEmpty)
            XCTAssertNotNil(currentManager.lastError)
            XCTAssertEqual(defaults.data(forKey: self.storageKey), corruptCurrent)
            XCTAssertEqual(defaults.data(forKey: "ilampa_installed_plugins_v3"), validLegacy)

            defaults.removeObject(forKey: self.storageKey)
            let corruptLegacy = Data([0xFE, 0xED, 0x00])
            defaults.set(corruptLegacy, forKey: "ilampa_installed_plugins_v3")
            let legacyManager = self.makeManager(defaults: defaults, cache: cache)
            legacyManager.invalidateRuntimeCapabilities()
            XCTAssertTrue(legacyManager.installedPlugins.isEmpty)
            XCTAssertNotNil(legacyManager.lastError)
            XCTAssertEqual(defaults.data(forKey: "ilampa_installed_plugins_v3"), corruptLegacy)
            XCTAssertNil(defaults.data(forKey: self.storageKey), "Failed migration must not persist defaults")
        }
    }

    func testCurrentKeyTakesPrecedenceOverLegacyEnabledRecords() async throws {
        try await withStore { defaults, cache in
            try self.seed([], in: defaults)
            let legacy = try self.legacyData([
                ["url": "https://plugins.example.test/legacy.js", "name": "Obsolete enabled", "status": 1]
            ])
            defaults.set(legacy, forKey: "ilampa_installed_plugins_v3")

            let manager = self.makeManager(defaults: defaults, cache: cache)
            XCTAssertTrue(manager.installedPlugins.isEmpty)
            XCTAssertEqual(try self.persisted(in: defaults), [])
            XCTAssertEqual(defaults.data(forKey: "ilampa_installed_plugins_v3"), legacy)
        }
    }

    func testStaleActiveAndFailureCallbacksCannotRevivePersistedDisabledRecord() async throws {
        try await withStore { defaults, cache in
            let disabled = self.record(.inactive)
            try self.seed([disabled], in: defaults)
            let originalData = defaults.data(forKey: self.storageKey)
            let manager = self.makeManager(defaults: defaults, cache: cache)
            manager.markPluginActive(urlString: disabled.urlString)
            manager.markPluginFailed(urlString: disabled.urlString, reason: "late result")

            let current = try XCTUnwrap(manager.installedPlugins.first)
            XCTAssertFalse(current.isEnabled)
            XCTAssertEqual(current.lifecycleState, .inactive)
            XCTAssertNil(current.lastValidatedAt)
            XCTAssertEqual(defaults.data(forKey: self.storageKey), originalData)
            let reloaded = self.makeManager(defaults: defaults, cache: cache)
            XCTAssertFalse(try XCTUnwrap(reloaded.installedPlugins.first).isEnabled)
        }
    }

    func testFailurePersistsWithoutLosingEnabledIntentAndReloadCanRetry() async throws {
        try await withStore { defaults, cache in
            let enabled = self.record(.active)
            try self.seed([enabled], in: defaults)
            let manager = self.makeManager(defaults: defaults, cache: cache)
            manager.markPluginFailed(urlString: enabled.urlString, reason: "script rejected")
            let failed = try XCTUnwrap(manager.installedPlugins.first)
            XCTAssertEqual(failed.lifecycleState, .failed(reason: "script rejected"))
            XCTAssertTrue(failed.isEnabled)
            XCTAssertEqual(failed.desiredEnabled, true)
            XCTAssertNil(failed.lastValidatedAt)
            XCTAssertEqual(try self.persisted(in: defaults).first, failed)

            let reloaded = self.makeManager(defaults: defaults, cache: cache)
            let retry = try XCTUnwrap(reloaded.installedPlugins.first)
            XCTAssertEqual(retry.id, enabled.id)
            XCTAssertTrue(retry.isEnabled)
            XCTAssertEqual(retry.lifecycleState, .loading)
        }
    }

    func testExplicitIntentSurvivesFailureAndContradictoryExecutionStateRoundTrips() async throws {
        var enabled = record(.loading)
        enabled.lifecycleState = .failed(reason: "execution failure")
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertFalse(enabled.lifecycleState.isOperational)

        var disabled = record(.active)
        disabled.isEnabled = false
        disabled.lifecycleState = .active // A stale result must not redefine the desired intent.
        XCTAssertFalse(disabled.isEnabled)
        let decoded = try JSONDecoder().decode([LampaPluginRecord].self,
                                              from: JSONEncoder().encode([enabled, disabled]))
        XCTAssertEqual(decoded.map(\.isEnabled), [true, false])
        XCTAssertEqual(decoded.map(\.desiredEnabled), [true, false])
    }

    func testScriptCacheURLUsesStableSHA256AcrossManagerInstances() async throws {
        try await withStore { defaults, cache in
            try self.seed([], in: defaults)
            let first = self.makeManager(defaults: defaults, cache: cache)
            let second = self.makeManager(defaults: defaults, cache: cache)
            let url = "https://plugins.example.test/alpha.js"
            let expected = cache.appendingPathComponent(
                "plugin_347fa6922fa3d9006ff6469034dae9546f45d6eb31568318898a2c61762d5276.js")
            XCTAssertEqual(first.scriptURL(for: url), expected)
            XCTAssertEqual(second.scriptURL(for: url), expected)
            XCTAssertNotEqual(first.scriptURL(for: url), first.scriptURL(for: url + "?version=2"))
        }
    }

    func testEnabledPluginReadsPersistedCacheWithoutNetworkOrRuntime() async throws {
        try await withStore { defaults, cache in
            let enabled = self.record(.loading)
            try self.seed([enabled], in: defaults)
            let manager = self.makeManager(defaults: defaults, cache: cache)
            let script = "/* persisted fixture */ window.fixtureLoaded = true;"
            try script.write(to: manager.scriptURL(for: enabled.urlString), atomically: true, encoding: .utf8)
            let hash = try XCTUnwrap(manager.cachedScriptSHA256(for: enabled.urlString))
            XCTAssertTrue(manager.approveCachedScript(pluginID: enabled.id, expectedSHA256: hash))
            let reloaded = self.makeManager(defaults: defaults, cache: cache)
            let actual = try await reloaded.script(for: RuntimePlugin(id: enabled.urlString, name: enabled.name))
            XCTAssertEqual(actual, script)
            XCTAssertEqual(reloaded.installedPlugins.first?.lifecycleState, .loading)
        }
    }

    func testDisabledPluginCannotLoadEvenWhenItsScriptIsCached() async throws {
        try await withStore { defaults, cache in
            let disabled = self.record(.inactive)
            try self.seed([disabled], in: defaults)
            let manager = self.makeManager(defaults: defaults, cache: cache)
            try "cached disabled plugin".write(to: manager.scriptURL(for: disabled.urlString),
                                               atomically: true, encoding: .utf8)
            do {
                _ = try await manager.script(for: RuntimePlugin(id: disabled.urlString, name: disabled.name))
                XCTFail("Disabled plugin must be rejected before reading its cache or requesting the network")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
    }

    func testBulkRemoveAllPersistsEmptyAcrossReloadAndSynchronizesEmptyIntent() async throws {
        try await withStore { defaults, cache in
            try self.seed([self.record(.active)], in: defaults)
            var configurations: [[RuntimePlugin]] = []
            let manager = PluginManager(defaults: defaults, cacheDirectory: cache,
                                        runtimeConfiguration: { plugins, _ in configurations.append(plugins) })
            manager.bulkRemoveAll()
            XCTAssertTrue(manager.installedPlugins.isEmpty)
            XCTAssertEqual(try self.persisted(in: defaults), [])
            XCTAssertEqual(configurations, [[]])
            XCTAssertTrue(self.makeManager(defaults: defaults, cache: cache).installedPlugins.isEmpty)
        }
    }

    func testRemovePersistsOnlySurvivorsDeletesCacheAndIgnoresLateActiveCallback() async throws {
        try await withStore { defaults, cache in
            let removed = self.record(.active)
            let survivor = LampaPluginRecord(url: URL(string: "https://plugins.example.test/beta.js")!,
                                             name: "Survivor", lifecycleState: .loading)
            try self.seed([removed, survivor], in: defaults)
            var configurations: [[RuntimePlugin]] = []
            let manager = PluginManager(defaults: defaults, cacheDirectory: cache,
                                        runtimeConfiguration: { plugins, _ in configurations.append(plugins) })
            let cachedScript = manager.scriptURL(for: removed.urlString)
            try "removed fixture".write(to: cachedScript, atomically: true, encoding: .utf8)
            manager.remove(plugin: removed)
            manager.markPluginActive(urlString: removed.urlString)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cachedScript.path))
            XCTAssertEqual(manager.installedPlugins.map(\.id), [survivor.id])
            XCTAssertEqual(try self.persisted(in: defaults).map(\.id), [survivor.id])
            XCTAssertEqual(configurations, [[RuntimePlugin(id: survivor.urlString, name: survivor.name)]])
            XCTAssertEqual(self.makeManager(defaults: defaults, cache: cache).installedPlugins.map(\.id), [survivor.id])
        }
    }

    func testTogglePersistsDesiredIntentAndLateExecutionCannotReenableDisabledPlugin() async throws {
        try await withStore { defaults, cache in
            let plugin = self.record(.active)
            try self.seed([plugin], in: defaults)
            var configurations: [[RuntimePlugin]] = []
            let manager = PluginManager(defaults: defaults, cacheDirectory: cache,
                                        runtimeConfiguration: { plugins, _ in configurations.append(plugins) })
            manager.toggle(plugin: plugin)
            manager.markPluginActive(urlString: plugin.urlString)
            let disabled = try XCTUnwrap(manager.installedPlugins.first)
            XCTAssertFalse(disabled.isEnabled)
            XCTAssertEqual(disabled.lifecycleState, .inactive)
            XCTAssertNil(disabled.lastValidatedAt)
            XCTAssertFalse(try XCTUnwrap(self.persisted(in: defaults).first).isEnabled)
            XCTAssertFalse(try XCTUnwrap(self.makeManager(defaults: defaults, cache: cache).installedPlugins.first).isEnabled)
            XCTAssertEqual(configurations, [[]])

            manager.toggle(plugin: disabled)
            let enabled = try XCTUnwrap(manager.installedPlugins.first)
            XCTAssertTrue(enabled.isEnabled)
            XCTAssertEqual(enabled.lifecycleState, .loading)
            XCTAssertTrue(try XCTUnwrap(self.persisted(in: defaults).first).isEnabled)
            XCTAssertTrue(try XCTUnwrap(self.makeManager(defaults: defaults, cache: cache).installedPlugins.first).isEnabled)
            XCTAssertEqual(configurations, [[], [RuntimePlugin(id: plugin.urlString, name: plugin.name)]])
        }
    }

    func testDisabledBundledSampleIsExcludedFromNextRuntimeAndCannotLoadCachedScript() async throws {
        try await withStore { defaults, cache in
            let sampleURL = "bundled://plugins/sample_source_plugin.js"
            let sample = LampaPluginRecord(url: URL(string: sampleURL)!, name: "Sample Source", origin: .bundled,
                                           lifecycleState: .active, registeredComponents: ["sample_source"])
            try self.seed([sample], in: defaults)
            var configurations: [[RuntimePlugin]] = []
            let manager = PluginManager(defaults: defaults, cacheDirectory: cache,
                                        runtimeConfiguration: { plugins, _ in configurations.append(plugins) })
            try "Lampa.Component.add('sample_source', function () {});".write(
                to: manager.scriptURL(for: sampleURL), atomically: true, encoding: .utf8)
            manager.toggle(plugin: sample)
            manager.synchronizeRuntime(reason: "post-toggle regression")
            let disabled = try XCTUnwrap(manager.installedPlugins.first)
            XCTAssertFalse(disabled.isEnabled)
            XCTAssertEqual(disabled.lifecycleState, .inactive)
            XCTAssertEqual(Array(configurations.suffix(2)), [[], []])
            do {
                _ = try await manager.script(for: RuntimePlugin(id: sampleURL, name: sample.name))
                XCTFail("Disabled bundled sample must not reach the cached script")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            manager.markPluginActive(urlString: sampleURL)
            XCTAssertFalse(try XCTUnwrap(manager.installedPlugins.first).isEnabled,
                           "A stale execution acknowledgment cannot re-enable Sample Source")
        }
    }

    func testDeterministicInvalidResponseIsBlockedFromUnrelatedRuntimeRebuilds() async throws {
        try await withStore { defaults, cache in
            let cubURL = "https://cub.best/plugin/cub"
            let cub = LampaPluginRecord(url: URL(string: cubURL)!, name: "CUB Sync", lifecycleState: .active)
            try self.seed([cub], in: defaults)
            var configurations: [[RuntimePlugin]] = []
            let manager = PluginManager(defaults: defaults, cacheDirectory: cache,
                                        runtimeConfiguration: { plugins, _ in configurations.append(plugins) })
            let diagnostic = PluginScriptResponseDiagnostic(statusCode: 404, contentType: "text/javascript; charset=utf-8",
                                                            requestedURL: "https://cub.best/plugin/cub", finalURL: "https://cub.best/plugin/cub",
                                                            bodyKind: .empty, byteCount: 0)
            let error = PluginScriptFetchError.invalidResponse(diagnostic)
            manager.markPluginFailed(urlString: cubURL, reason: error.localizedDescription, blockAutomaticRetry: error.blocksAutomaticRetry)
            manager.invalidateRuntimeCapabilities()
            manager.synchronizeRuntime(reason: "unrelated plugin toggle")
            manager.synchronizeRuntime(reason: "explicit runtime refresh")
            let record = try XCTUnwrap(manager.installedPlugins.first)
            XCTAssertTrue(record.isEnabled, "The user's intent remains visible rather than being silently changed")
            XCTAssertTrue(record.automaticRetryBlocked == true)
            XCTAssertEqual(record.lifecycleState, .failed(reason: error.localizedDescription))
            manager.markPluginActive(urlString: cubURL)
            XCTAssertEqual(try XCTUnwrap(manager.installedPlugins.first).lifecycleState, .failed(reason: error.localizedDescription),
                           "A stale execution callback cannot clear a retry block")
            XCTAssertEqual(configurations, [[], []], "Blocked endpoint must not be included in later reconstructions")
            XCTAssertEqual(diagnostic.sanitizedDescription,
                           "HTTP=404, type=text/javascript; charset=utf-8, requested=https://cub.best/plugin/cub, final=https://cub.best/plugin/cub, redirected=false, body=empty, bytes=0")
            let reloaded = self.makeManager(defaults: defaults, cache: cache)
            let persisted = try XCTUnwrap(reloaded.installedPlugins.first)
            XCTAssertTrue(persisted.automaticRetryBlocked == true)
            XCTAssertEqual(persisted.lifecycleState, .failed(reason: error.localizedDescription))
        }
    }

    func testInvalidRemoteScriptLogsStructuredResponseAndNeverWritesCache() async throws {
        try await withStore { defaults, cache in
            try await self.withTransport(fileName: "cub") { session, url, exchange in
                let plugin = LampaPluginRecord(url: url, name: "CUB fixture", lifecycleState: .active)
                try self.seed([plugin], in: defaults)
                let manager = PluginManager(defaults: defaults, cacheDirectory: cache, session: session,
                                            runtimeConfiguration: { _, _ in })
                let load = Task { try await manager.script(for: RuntimePlugin(id: url.absoluteString, name: plugin.name)) }
                await self.fulfillment(of: [exchange.started], timeout: 3)
                exchange.complete(statusCode: 404, contentType: "text/javascript; charset=utf-8", body: Data())
                do {
                    _ = try await load.value
                    XCTFail("HTTP 404 must not be accepted as a plugin script")
                } catch let error as PluginScriptFetchError {
                    guard case .invalidResponse(let diagnostic) = error else {
                        return XCTFail("Expected invalid response")
                    }
                    XCTAssertEqual(diagnostic.statusCode, 404)
                    XCTAssertEqual(diagnostic.contentType, "text/javascript; charset=utf-8")
                    XCTAssertEqual(diagnostic.requestedURL, url.absoluteString)
                    XCTAssertEqual(diagnostic.finalURL, url.absoluteString)
                    XCTAssertEqual(diagnostic.bodyKind, .empty)
                    XCTAssertEqual(diagnostic.byteCount, 0)
                    XCTAssertTrue(error.blocksAutomaticRetry)
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: manager.scriptURL(for: url.absoluteString).path))
            }
        }
    }

    func testFreshDefaultsDoNotEnableKnownInvalidCubEndpoint() async throws {
        try await withStore { defaults, cache in
            let manager = self.makeManager(defaults: defaults, cache: cache)
            XCTAssertFalse(manager.installedPlugins.contains { $0.urlString == "https://cub.best/plugin/cub" })
            XCTAssertTrue(manager.installedPlugins.isEmpty,
                          "A fresh product install must not execute diagnostic or third-party plugins without consent")
        }
    }

    func testRuntimeSnapshotSeparatesInstalledIntentExecutionAndCapabilityRegistration() throws {
        let enabled = LampaPluginRecord(url: URL(string: "https://plugins.example.test/enabled.js")!, name: "Enabled", lifecycleState: .active)
        let disabled = LampaPluginRecord(url: URL(string: "https://plugins.example.test/disabled.js")!, name: "Disabled", lifecycleState: .inactive)
        let enabledCapability = PluginRegisteredSource(id: "interactive", pluginUrl: enabled.urlString,
                                                       name: "Interactive", description: nil, isEnabled: true,
                                                       hasExecutableResolver: false, capability: .interactiveComponent,
                                                       operationalStatus: .registered)
        let staleCapability = PluginRegisteredSource(id: "stale", pluginUrl: disabled.urlString,
                                                     name: "Stale", description: nil, isEnabled: true,
                                                     hasExecutableResolver: false, capability: .unsupported,
                                                     operationalStatus: .registered)

        let snapshot = PluginRuntimeSnapshot(installed: [enabled, disabled],
                                             runningPluginURLs: [enabled.urlString, disabled.urlString],
                                             capabilities: [enabledCapability, staleCapability])
        XCTAssertEqual(snapshot.installedCount, 2)
        XCTAssertEqual(snapshot.desiredEnabledCount, 1)
        XCTAssertEqual(snapshot.executedCurrentGenerationCount, 1)
        XCTAssertEqual(snapshot.registeredActiveCapabilityCount, 1)
        XCTAssertTrue(snapshot.isExecutedInCurrentGeneration(enabled))
        XCTAssertFalse(snapshot.isExecutedInCurrentGeneration(disabled))
        XCTAssertTrue(snapshot.isCapabilityActive(enabledCapability))
        XCTAssertFalse(snapshot.isCapabilityActive(staleCapability))
    }

    func testOwnedComponentIsClassifiedAsInteractiveNotNativeMediaResolver() async throws {
        try await withStore { defaults, cache in
            PluginCapabilityRegistry.shared.clear()
            defer { PluginCapabilityRegistry.shared.clear() }
            let plugin = LampaPluginRecord(url: URL(string: "https://plugins.example.test/interface.js")!, name: "Interface", lifecycleState: .active)
            try self.seed([plugin], in: defaults)
            let manager = self.makeManager(defaults: defaults, cache: cache)
            manager.markComponentRegistered(urlString: plugin.urlString, name: "custom_browser")
            let updated = try XCTUnwrap(manager.installedPlugins.first)
            XCTAssertTrue(updated.registeredComponents.contains("custom_browser"))
            let capability = try XCTUnwrap(PluginCapabilityRegistry.shared.registeredSources.first { $0.pluginUrl == plugin.urlString })
            XCTAssertEqual(capability.capability, .interactiveComponent)
            XCTAssertFalse(capability.hasExecutableResolver)
        }
    }

    func testExplicitRetryIsTheOnlyWayToReincludeAutomaticallyBlockedPlugin() async throws {
        try await withStore { defaults, cache in
            let url = "https://plugins.example.test/retired.js"
            var blocked = LampaPluginRecord(url: URL(string: url)!, name: "Blocked", lifecycleState: .failed(reason: "HTTP 404"))
            blocked.desiredEnabled = true
            blocked.automaticRetryBlocked = true
            try self.seed([blocked], in: defaults)
            var configurations: [[RuntimePlugin]] = []
            let manager = PluginManager(defaults: defaults, cacheDirectory: cache,
                                        runtimeConfiguration: { plugins, _ in configurations.append(plugins) })
            manager.synchronizeRuntime(reason: "unrelated rebuild")
            XCTAssertEqual(configurations, [[]])
            manager.retry(plugin: try XCTUnwrap(manager.installedPlugins.first))
            XCTAssertEqual(configurations.last, [RuntimePlugin(id: url, name: "Blocked")])
            let retried = try XCTUnwrap(manager.installedPlugins.first)
            XCTAssertTrue(retried.isEnabled)
            XCTAssertFalse(retried.automaticRetryBlocked == true)
            XCTAssertEqual(retried.lifecycleState, .loading)
        }
    }

    private func withTransport(fileName: String = "extension.js", _ body: @MainActor (URLSession, URL, DelayedPluginURLProtocol.Exchange) async throws -> Void) async throws {
        let url = URL(string: "https://plugin-tests.invalid/\(UUID().uuidString)/\(fileName)")!
        let exchange = DelayedPluginURLProtocol.Exchange()
        DelayedPluginURLProtocol.register(exchange, for: url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedPluginURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            DelayedPluginURLProtocol.unregister(url)
        }
        try await body(session, url, exchange)
    }

    func testCustomPluginCacheMissDownloadsItsOwnScriptInsteadOfURLSubstringFallback() async throws {
        for name in ["source.js", "soma_custom.js", "diagnostic_custom.js"] {
            try await withStore { defaults, cache in
                try await self.withTransport(fileName: name) { session, url, exchange in
                    let fixture = LampaPluginRecord(url: url, name: "Custom", lifecycleState: .active)
                    try self.seed([fixture], in: defaults)
                    let manager = PluginManager(defaults: defaults, cacheDirectory: cache, session: session,
                                                runtimeConfiguration: { _, _ in })
                    let loading = Task { try await manager.script(for: RuntimePlugin(id: url.absoluteString, name: "Custom")) }
                    await self.fulfillment(of: [exchange.started], timeout: 3)
                    exchange.complete()
                    do {
                        _ = try await loading.value
                        XCTFail("Freshly downloaded bytes need approval")
                    } catch is PluginTrustError { }
                    let actual = try String(contentsOf: manager.scriptURL(for: url.absoluteString), encoding: .utf8)
                    XCTAssertEqual(actual, "window.testPluginLoaded = true;")
                }
            }
        }
    }

    func testTrustPersistsAndChangesRequireNewApproval() async throws {
        try await withStore { defaults, cache in
            let plugin = self.record(.inactive)
            try self.seed([plugin], in: defaults)
            let manager = self.makeManager(defaults: defaults, cache: cache)
            let path = manager.scriptURL(for: plugin.urlString)
            let original = "window.approved = true;"
            try original.write(to: path, atomically: true, encoding: .utf8)
            let hash = try XCTUnwrap(manager.cachedScriptSHA256(for: plugin.urlString))
            XCTAssertTrue(manager.approveCachedScript(pluginID: plugin.id, expectedSHA256: hash))
            let reloaded = self.makeManager(defaults: defaults, cache: cache)
            XCTAssertTrue(reloaded.hasTrustedCachedScript(try XCTUnwrap(reloaded.installedPlugins.first)))
            let runtime = RuntimePlugin(id: plugin.urlString, name: plugin.name)
            let loaded = try await reloaded.script(for: runtime)
            XCTAssertEqual(loaded, original)
            try "window.changed = true;".write(to: path, atomically: true, encoding: .utf8)
            XCTAssertFalse(reloaded.approveCachedScript(pluginID: plugin.id, expectedSHA256: hash))
            do { _ = try await reloaded.script(for: runtime); XCTFail("Changed code must not run") }
            catch is PluginTrustError { }
            XCTAssertFalse(reloaded.isApproved(script: "window.changed = true;", for: plugin.urlString))
        }
    }

    func testBatchRecordsCannotSupplyTrustOrEnableThemselves() async throws {
        try await withStore { defaults, cache in
            let manager = self.makeManager(defaults: defaults, cache: cache)
            var plugin = self.record(.active)
            let script = "window.batch = true;"
            _ = manager.saveScriptToDisk(script: script, forUrl: plugin.urlString)
            plugin.approvedScriptSHA256 = manager.cachedScriptSHA256(for: plugin.urlString)
            manager.batchAdd(records: [plugin])
            let staged = try XCTUnwrap(manager.installedPlugins.first)
            XCTAssertFalse(staged.isEnabled)
            XCTAssertNil(staged.approvedScriptSHA256)
            manager.bulkToggleAll(enabled: true)
            do {
                _ = try await manager.script(for: RuntimePlugin(id: plugin.urlString, name: plugin.name))
                XCTFail("Bulk enable must not bypass approval")
            } catch is PluginTrustError { }
        }
    }

    func testBatchCommitDiscardsSuppliedApproval() async throws {
        try await withStore { defaults, cache in
            let manager = self.makeManager(defaults: defaults, cache: cache)
            var plugin = self.record(.active)
            plugin.approvedScriptSHA256 = String(repeating: "a", count: 64)
            try manager.commitBatchPlugin(plugin, script: "window.batchCommit = true;")
            let staged = try XCTUnwrap(manager.installedPlugins.first)
            XCTAssertFalse(staged.isEnabled)
            XCTAssertNil(staged.approvedScriptSHA256)
            let reloaded = self.makeManager(defaults: defaults, cache: cache)
            XCTAssertNil(reloaded.installedPlugins.first?.approvedScriptSHA256)
        }
    }

    func testBuiltInUsesApplicationBytesNotMutableCacheOrOrigin() async throws {
        try await withStore { defaults, cache in
            let url = "ilampa://internal/diagnostic_plugin.js"
            let builtIn = LampaPluginRecord(url: URL(string: url)!, name: "Built-in", origin: .bundled, lifecycleState: .active)
            let impostor = LampaPluginRecord(url: URL(string: "https://plugins.example.test/impostor.js")!, name: "Impostor", origin: .bundled, lifecycleState: .active)
            try self.seed([builtIn, impostor], in: defaults)
            let manager = self.makeManager(defaults: defaults, cache: cache)
            let tampered = "window.tampered = true;"
            try tampered.write(to: manager.scriptURL(for: url), atomically: true, encoding: .utf8)
            try tampered.write(to: manager.scriptURL(for: impostor.urlString), atomically: true, encoding: .utf8)
            let actual = try await manager.script(for: RuntimePlugin(id: url, name: builtIn.name))
            XCTAssertNotEqual(actual, tampered)
            XCTAssertTrue(manager.isApproved(script: actual, for: url))
            XCTAssertFalse(manager.isApproved(script: tampered, for: url))
            XCTAssertFalse(manager.isApproved(script: tampered, for: impostor.urlString))
        }
    }

    func testPreparingMissingCacheStagesWithoutEnablingOrApproving() async throws {
        try await withStore { defaults, cache in
            try await self.withTransport { session, url, exchange in
                let plugin = LampaPluginRecord(url: url, name: "Pending", lifecycleState: .inactive)
                try self.seed([plugin], in: defaults)
                let manager = PluginManager(defaults: defaults, cacheDirectory: cache, session: session,
                                            runtimeConfiguration: { _, _ in })
                let preparation = Task { try await manager.prepareScriptForApproval(pluginID: plugin.id) }
                await self.fulfillment(of: [exchange.started], timeout: 3)
                exchange.complete()
                let hash = try await preparation.value
                XCTAssertEqual(hash, manager.cachedScriptSHA256(for: plugin.urlString))
                XCTAssertFalse(try XCTUnwrap(manager.installedPlugins.first).isEnabled)
                XCTAssertNil(manager.installedPlugins.first?.approvedScriptSHA256)
                XCTAssertTrue(manager.approveCachedScript(pluginID: plugin.id, expectedSHA256: hash))
            }
        }
    }

    func testCacheMissRefetchRequiresMatchingPreviouslyApprovedHash() async throws {
        for changed in [false, true] {
            try await withStore { defaults, cache in
                try await self.withTransport { session, url, exchange in
                    let plugin = LampaPluginRecord(url: url, name: "Refetch", lifecycleState: .inactive)
                    try self.seed([plugin], in: defaults)
                    let manager = PluginManager(defaults: defaults, cacheDirectory: cache, session: session,
                                                runtimeConfiguration: { _, _ in })
                    let original = "window.original = true;"
                    try original.write(to: manager.scriptURL(for: plugin.urlString), atomically: true, encoding: .utf8)
                    let hash = try XCTUnwrap(manager.cachedScriptSHA256(for: plugin.urlString))
                    XCTAssertTrue(manager.approveCachedScript(pluginID: plugin.id, expectedSHA256: hash))
                    try FileManager.default.removeItem(at: manager.scriptURL(for: plugin.urlString))
                    let runtime = RuntimePlugin(id: plugin.urlString, name: plugin.name)
                    let loading = Task { try await manager.script(for: runtime) }
                    await self.fulfillment(of: [exchange.started], timeout: 3)
                    exchange.complete(body: Data((changed ? "window.changed = true;" : original).utf8))
                    do {
                        let result = try await loading.value
                        XCTAssertFalse(changed, "Changed refetched code must not run")
                        XCTAssertEqual(result, original)
                    } catch is PluginTrustError {
                        XCTAssertTrue(changed)
                    }
                }
            }
        }
    }

    func testDelayedCustomInstallCannotReinstallAfterBulkRemoval() async throws {
        try await withStore { defaults, cache in
            try self.seed([], in: defaults)
            try await self.withTransport { session, url, exchange in
                let manager = PluginManager(defaults: defaults, cacheDirectory: cache, session: session,
                                            runtimeConfiguration: { _, _ in })
                let completed = self.expectation(description: "cancelled custom install callback")
                var success: Bool?
                manager.addCustom(url: url.absoluteString) { installed, _ in
                    success = installed
                    completed.fulfill()
                }
                await self.fulfillment(of: [exchange.started], timeout: 3)
                XCTAssertTrue(manager.isInstalling(url: url.absoluteString))
                // The HTTP response is released, but its MainActor completion cannot run before removal.
                exchange.complete()
                manager.bulkRemoveAll()
                await self.fulfillment(of: [completed], timeout: 3)
                XCTAssertEqual(success, false)
                XCTAssertTrue(manager.installedPlugins.isEmpty)
                XCTAssertTrue(manager.installingUrls.isEmpty)
                XCTAssertEqual(try self.persisted(in: defaults), [])
                XCTAssertFalse(FileManager.default.fileExists(atPath: manager.scriptURL(for: url.absoluteString).path))
                XCTAssertTrue(self.makeManager(defaults: defaults, cache: cache).installedPlugins.isEmpty)
            }
        }
    }

    func testDelayedCuratedInstallCannotReinstallAfterResetToDefaults() async throws {
        try await withStore { defaults, cache in
            try self.seed([], in: defaults)
            try await self.withTransport { session, url, exchange in
                let manager = PluginManager(defaults: defaults, cacheDirectory: cache, session: session,
                                            runtimeConfiguration: { _, _ in })
                let curated = CuratedPlugin(name: "Delayed fixture", description: "Test only",
                                            url: url.absoluteString, iconName: "puzzlepiece")
                let completed = self.expectation(description: "cancelled curated install callback")
                var success: Bool?
                manager.install(curated: curated) { installed, _ in
                    success = installed
                    completed.fulfill()
                }
                await self.fulfillment(of: [exchange.started], timeout: 3)
                exchange.complete()
                manager.resetToDefaults()
                let resetIDs = manager.installedPlugins.map(\.id)
                XCTAssertTrue(resetIDs.isEmpty, "Reset returns to an explicit no-plugin product baseline")
                await self.fulfillment(of: [completed], timeout: 3)
                XCTAssertEqual(success, false)
                XCTAssertEqual(manager.installedPlugins.map(\.id), resetIDs)
                XCTAssertFalse(manager.isInstalled(url: url.absoluteString))
                XCTAssertTrue(manager.installingUrls.isEmpty)
                XCTAssertEqual(try self.persisted(in: defaults).map(\.id), resetIDs)
                XCTAssertFalse(FileManager.default.fileExists(atPath: manager.scriptURL(for: url.absoluteString).path))
            }
        }
    }

    func testCancellingAsyncInstallCancelsTransportAndCannotPersistPlugin() async throws {
        try await withStore { defaults, cache in
            try self.seed([], in: defaults)
            try await self.withTransport { session, url, exchange in
                let manager = PluginManager(defaults: defaults, cacheDirectory: cache, session: session,
                                            runtimeConfiguration: { _, _ in })
                let completed = self.expectation(description: "cancelled async install returns")
                var finished = false
                let installation = Task { @MainActor () -> Result<LampaPluginRecord, Error> in
                    defer {
                        finished = true
                        completed.fulfill()
                    }
                    do { return .success(try await manager.installPlugin(url: url, origin: .userCustom)) }
                    catch { return .failure(error) }
                }
                await self.fulfillment(of: [exchange.started], timeout: 3)
                installation.cancel()
                await self.fulfillment(of: [exchange.stopped, completed], timeout: 3)
                guard finished else { return } // The expectation already failed; do not hang CI on a regression.
                let outcome = await installation.value
                if case .success = outcome { XCTFail("Cancelled installation must not succeed") }
                XCTAssertTrue(manager.installedPlugins.isEmpty)
                XCTAssertTrue(manager.installingUrls.isEmpty)
                XCTAssertEqual(try self.persisted(in: defaults), [])
                XCTAssertFalse(FileManager.default.fileExists(atPath: manager.scriptURL(for: url.absoluteString).path))
            }
        }
    }

    func testStagedUpdatePreservesTrustedScriptUntilExactApproval() async throws {
        try await withStore { defaults, cache in
            let record = self.record(.active)
            try self.seed([record], in: defaults)
            let manager = self.makeManager(defaults: defaults, cache: cache)
            let destination = manager.scriptURL(for: record.urlString)
            let oldScript = "window.oldVersion = true;"
            try oldScript.write(to: destination, atomically: true, encoding: .utf8)
            let approved = try XCTUnwrap(manager.cachedScriptSHA256(for: record.urlString))
            XCTAssertTrue(manager.approveCachedScript(pluginID: record.id, expectedSHA256: approved))

            let candidate = "window.newVersion = true;"
            let pending = destination.appendingPathExtension("pending")
            try candidate.write(to: pending, atomically: true, encoding: .utf8)
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), oldScript)

            manager.discardStagedUpdate(pluginID: record.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), oldScript)
            XCTAssertTrue(manager.hasTrustedCachedScript(try XCTUnwrap(manager.installedPlugins.first)))

            try candidate.write(to: pending, atomically: true, encoding: .utf8)
            XCTAssertFalse(manager.approveStagedUpdate(pluginID: record.id, expectedSHA256: "wrong"))
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), oldScript)

            let newHash = SHA256.hash(data: Data(candidate.utf8))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertTrue(manager.approveStagedUpdate(pluginID: record.id, expectedSHA256: newHash))
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), candidate)
            XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
            XCTAssertTrue(manager.hasTrustedCachedScript(try XCTUnwrap(manager.installedPlugins.first)))
        }
    }

}

/// Session-local transport: no requests escape to DNS/network and each URL has its own locked exchange.
private final class DelayedPluginURLProtocol: URLProtocol {
    final class Exchange {
        let started = XCTestExpectation(description: "plugin request started")
        let stopped = XCTestExpectation(description: "plugin request cancelled")
        private let lock = NSLock()
        private var loader: DelayedPluginURLProtocol?

        func attach(_ loader: DelayedPluginURLProtocol) {
            lock.lock()
            self.loader = loader
            lock.unlock()
            started.fulfill()
        }

        func complete(statusCode: Int = 200, contentType: String? = nil, body: Data = Data("window.testPluginLoaded = true;".utf8)) {
            lock.lock()
            let loader = self.loader
            lock.unlock()
            guard let loader, let url = loader.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: statusCode,
                                                 httpVersion: "HTTP/1.1",
                                                 headerFields: contentType.map { ["Content-Type": $0] }) else {
                XCTFail("No suspended plugin request")
                return
            }
            loader.client?.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
            loader.client?.urlProtocol(loader, didLoad: body)
            loader.client?.urlProtocolDidFinishLoading(loader)
        }
    }

    private static let lock = NSLock()
    private static var exchanges: [URL: Exchange] = [:]

    static func register(_ exchange: Exchange, for url: URL) {
        lock.lock()
        exchanges[url] = exchange
        lock.unlock()
    }

    static func unregister(_ url: URL) {
        lock.lock()
        exchanges[url] = nil
        lock.unlock()
    }

    private static func exchange(for url: URL?) -> Exchange? {
        lock.lock()
        defer { lock.unlock() }
        return url.flatMap { exchanges[$0] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let exchange = Self.exchange(for: request.url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        exchange.attach(self)
    }

    override func stopLoading() {
        Self.exchange(for: request.url)?.stopped.fulfill()
    }
}
