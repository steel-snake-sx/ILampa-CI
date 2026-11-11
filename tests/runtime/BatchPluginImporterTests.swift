import XCTest
@testable import iLampa

final class BatchPluginImporterTests: XCTestCase {
    @MainActor
    private func fixture(cacheIsFile: Bool = false, corruptStorage: Bool = false, allowRuntimeConfiguration: Bool = false) throws -> (PluginManager, UserDefaults, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("cache")
        if cacheIsFile {
            try Data().write(to: cache)
        } else {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        if corruptStorage { defaults.set(Data("bad".utf8), forKey: "ilampa_webkit_plugins_v1") }
        return (PluginManager(defaults: defaults, cacheDirectory: cache, runtimeConfiguration: { _, _ in
            if !allowRuntimeConfiguration { XCTFail("Batch must not start runtime") }
        }), defaults, root)
    }

    private func selected(_ text: String) -> [BatchImportCandidate] {
        BatchPluginImporter.shared.parse(rawText: text).map { candidate in
            var candidate = candidate
            candidate.isSelectedForInstall = candidate.isInstallable
            return candidate
        }
    }

    private func response(_ request: URLRequest, status: Int = 200, body: String = "console.log('ok')") -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    @MainActor
    func testSuccessfulCommitPersistsDisabledRecordAndScript() async throws {
        let (manager, defaults, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = "https://example.test/a.js"
        let result = await BatchPluginImporter.shared.executeBatchInstall(candidates: selected(url), manager: manager, fetch: { self.response($0) })
        XCTAssertEqual(result.installedSuccessfully, [url])
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(try String(contentsOf: manager.scriptURL(for: url), encoding: .utf8), "console.log('ok')")
        let reloaded = PluginManager(defaults: defaults, cacheDirectory: root.appendingPathComponent("cache"), runtimeConfiguration: { _, _ in XCTFail("Unexpected runtime") })
        XCTAssertEqual(reloaded.installedPlugins.count, 1)
        XCTAssertFalse(reloaded.installedPlugins[0].isEnabled)
    }

    @MainActor
    func testCacheAndStorageFailureAreNotReportedAsInstalled() async throws {
        for (badCache, badStorage) in [(true, false), (false, true)] {
            let (manager, _, root) = try fixture(cacheIsFile: badCache, corruptStorage: badStorage)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = "https://example.test/a.js"
            let result = await BatchPluginImporter.shared.executeBatchInstall(candidates: selected(url), manager: manager, fetch: { self.response($0) })
            XCTAssertTrue(result.installedSuccessfully.isEmpty)
            XCTAssertNotNil(result.failedInstallations[url])
            XCTAssertTrue(manager.installedPlugins.isEmpty)
            XCTAssertEqual(result.outcome, .partial)
        }
    }

    @MainActor
    func testDuplicateCannotOverwriteExistingPluginOrCache() async throws {
        let (manager, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = "https://example.test/a.js"
        let candidates = selected(url)
        _ = await BatchPluginImporter.shared.executeBatchInstall(candidates: candidates, manager: manager, fetch: { self.response($0) })
        let id = manager.installedPlugins[0].id
        let result = await BatchPluginImporter.shared.executeBatchInstall(candidates: candidates, manager: manager, fetch: { self.response($0, body: "changed") })
        XCTAssertTrue(result.installedSuccessfully.isEmpty)
        XCTAssertNotNil(result.failedInstallations[url])
        XCTAssertEqual(manager.installedPlugins[0].id, id)
        XCTAssertEqual(try String(contentsOf: manager.scriptURL(for: url), encoding: .utf8), "console.log('ok')")
    }

    @MainActor
    func testCancellationAndRetryKeepEarlierCommit() async throws {
        let (manager, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = "https://example.test/a.js"
        let second = "https://example.test/b.js"
        let candidates = selected("\(first)\n\(second)")
        var canceled = false
        let result = await BatchPluginImporter.shared.executeBatchInstall(candidates: candidates, isCancelled: { canceled }, onProgress: { done, _ in if done == 1 { canceled = true } }, manager: manager, fetch: { self.response($0) })
        XCTAssertEqual(result.installedSuccessfully, [first])
        XCTAssertEqual(result.canceledInstallations, [second])
        XCTAssertEqual(result.outcome, .canceled)
        let retry = await BatchPluginImporter.shared.executeBatchInstall(candidates: candidates.filter { $0.cleanUrl == second }, manager: manager, fetch: { self.response($0) })
        XCTAssertEqual(retry.installedSuccessfully, [second])
        XCTAssertEqual(manager.installedPlugins.count, 2)
        XCTAssertTrue(manager.installedPlugins.allSatisfy { !$0.isEnabled })
    }

    @MainActor
    func testCancellationDuringDownloadDoesNotCommit() async throws {
        let (manager, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var canceled = false
        let url = "https://example.test/a.js"
        let result = await BatchPluginImporter.shared.executeBatchInstall(candidates: selected(url), isCancelled: { canceled }, manager: manager, fetch: { request in
            canceled = true
            return self.response(request)
        })
        XCTAssertEqual(result.canceledInstallations, [url])
        XCTAssertTrue(manager.installedPlugins.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.scriptURL(for: url).path))
    }

    @MainActor
    func testBulkRemovalWhileDownloadIsInFlightRevokesWholeBatch() async throws {
        let (manager, defaults, root) = try fixture(allowRuntimeConfiguration: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = ["https://example.test/a.js", "https://example.test/b.js"]
        var requests = 0
        let result = await BatchPluginImporter.shared.executeBatchInstall(
            candidates: selected(urls.joined(separator: "\n")), manager: manager, fetch: { request in
                requests += 1
                await MainActor.run { manager.bulkRemoveAll() }
                return self.response(request)
            })
        XCTAssertEqual(requests, 1, "Remaining old-batch requests must not start")
        XCTAssertEqual(result.canceledInstallations, urls)
        XCTAssertTrue(result.installedSuccessfully.isEmpty)
        XCTAssertTrue(manager.installedPlugins.isEmpty)
        for url in urls { XCTAssertFalse(FileManager.default.fileExists(atPath: manager.scriptURL(for: url).path)) }
        let reloaded = PluginManager(defaults: defaults, cacheDirectory: root.appendingPathComponent("cache"), runtimeConfiguration: { _, _ in })
        XCTAssertTrue(reloaded.installedPlugins.isEmpty)
        // A genuinely new batch is not permanently blocked by the revocation.
        let retry = await BatchPluginImporter.shared.executeBatchInstall(candidates: selected(urls[0]), manager: manager,
                                                                        fetch: { self.response($0) })
        XCTAssertEqual(retry.installedSuccessfully, [urls[0]])
    }

    func testStreamsAndEndpointsAreNotOfferedAsPlugins() {
        let candidates = BatchPluginImporter.shared.parse(rawText: "https://example.test/a.m3u8\nhttps://example.test/torrserver")
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.allSatisfy { !$0.isInstallable && !$0.isSelectedForInstall })
    }

    @MainActor
    func testHTTPFailureDoesNotPreventOtherItemsFromCommitting() async throws {
        let (manager, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = "https://example.test/bad.js"
        let good = "https://example.test/good.js"
        let result = await BatchPluginImporter.shared.executeBatchInstall(candidates: selected("\(bad)\n\(good)"), manager: manager, fetch: { request in
            self.response(request, status: request.url?.absoluteString == bad ? 404 : 200)
        })
        XCTAssertEqual(result.installedSuccessfully, [good])
        XCTAssertNotNil(result.failedInstallations[bad])
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(manager.installedPlugins.map { $0.url.absoluteString }, [good])
    }

    func testInstalledFragmentsAreNormalizedDuringReview() {
        let rows = BatchPluginImporter.shared.parse(rawText: "https://example.test/a.js", currentlyInstalledUrls: ["https://example.test/a.js#old"])
        if case .duplicate(_, let installed) = rows[0].status {
            XCTAssertTrue(installed)
        } else { XCTFail("Installed URLs must be normalized before comparison") }
    }
    func testJSONRegistryOnKnownPluginHostIsNotInstallableScript() {
        let importer = BatchPluginImporter.shared
        let rows = importer.parse(rawText: "https://lampame.github.io/main/data/plugins.json")
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].isInstallable)
        if case .unsupportedWebpage = rows[0].status {} else {
            XCTFail("A catalog must not be staged as a plugin script")
        }
    }

    func testDuplicatesKeepDistinctQueryStringsAndStartUnselected() {
        let importer = BatchPluginImporter.shared
        let rows = importer.parse(rawText: """
        https://example.test/plugin.js?version=1
        https://example.test/plugin.js?version=1#fragment
        https://example.test/plugin.js?version=2
        invalid
        """)
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { !$0.isSelectedForInstall })
        if case .duplicate(_, let installed) = rows[1].status {
            XCTAssertFalse(installed)
        } else { XCTFail("The same URL without a fragment is a duplicate") }
        if case .pluginScript = rows[2].status {} else {
            XCTFail("Distinct query strings must not be deduplicated")
        }
        if case .invalid = rows[3].status {} else { XCTFail("Invalid input must be rejected") }
    }
}
