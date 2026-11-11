import XCTest
@testable import iLampa

@MainActor
final class PluginCatalogStoreTests: XCTestCase {
    func testRegistryParsingDeduplicatesAndKeepsProvenance() throws {
        let data = Data("""
        {"results":[{"title":"Видео","results":[
          {"name":"One","author":"Author","link":"https://EXAMPLE.test/p.js?q=1#x","descr":"Description"},
          {"name":"Duplicate","link":"https://example.test/p.js?q=1"},
          {"name":"Other","link":"https://example.test/p.js?q=2"},
          {"name":"Insecure","link":"http://example.test/a.js"},
          {"name":"Credentials","link":"https://user:pass@example.test/a.js"}
        ]}]}
        """.utf8)
        let snapshot = try PluginCatalogStore.parse(data)
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertEqual(snapshot.unsupportedCount, 2)
        XCTAssertEqual(snapshot.entries[0].title, "One")
        XCTAssertEqual(snapshot.entries[0].author, "Author")
        XCTAssertEqual(snapshot.entries[0].category, "Видео")
        XCTAssertEqual(snapshot.entries[0].compatibility, .notTested)
        XCTAssertEqual(snapshot.entries[0].provenance.first?.registryID, "lampaplugins-store")
    }

    func testRetiredShikimoriRegistryURLUsesPublisherExistingMovedScript() throws {
        let data = Data("""
        {"results":[{"title":"Аниме","results":[
            {"name":"Shikimori catalog","link":"https://lampame.github.io/main/shikimori.js"},
            {"name":"Other","link":"https://example.test/plugin.js"}
        ]}]}
        """.utf8)
        let snapshot = try PluginCatalogStore.parse(data)
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertEqual(snapshot.entries[0].sourceURL.absoluteString,
            "https://lampame.github.io/main/Shikimori/Shikimori.js")
        XCTAssertEqual(snapshot.entries[0].provenance.first?.registryID, "lampaplugins-store")
        XCTAssertEqual(snapshot.entries[1].sourceURL.absoluteString, "https://example.test/plugin.js")
    }

    func testPreviouslyCachedShikimoriEntryIsRemappedWithoutNetwork() throws {
        let suite = "CachedShikimori.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Cache must be treated as source data, not a guarantee that the
        // plugin author's historical URL is still reachable.
        let cached = PluginCatalogStore.Snapshot(entries: [
            PluginCatalogEntry(
                sourceURL: try XCTUnwrap(URL(string: "https://lampame.github.io/main/shikimori.js")),
                title: "Shikimori catalog", author: "Community",
                description: nil, category: "Anime", provenance: [], compatibility: .partial)
        ], unsupportedCount: 0, fetchedAt: Date())
        defaults.set(try JSONEncoder().encode(cached),
            forKey: "ilampa_lampaplugins_catalog_v1")
        let store = PluginCatalogStore(defaults: defaults, fetch: { _ in
            throw URLError(.notConnectedToInternet)
        })
        XCTAssertEqual(store.snapshot?.entries.first?.sourceURL.absoluteString,
            "https://lampame.github.io/main/Shikimori/Shikimori.js")
        XCTAssertEqual(store.snapshot?.entries.first?.compatibility, .notTested)
    }

    func testEmptyOrOversizedRegistryFailsClosed() {
        XCTAssertThrowsError(try PluginCatalogStore.parse(Data("{\"results\":[]}".utf8)))
        XCTAssertThrowsError(try PluginCatalogStore.parse(Data(repeating: 0, count: 2_000_001)))
    }

    func testRefreshCachesAndOfflineFailureRetainsSnapshot() async throws {
        let suite = "PluginCatalogStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let body = Data("""
        {"results":[{"title":"Видео","results":[{"name":"Filmix","link":"https://example.test/fx.js"}]}]}
        """.utf8)
        let success = PluginCatalogStore(defaults: defaults, fetch: { request in
            (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await success.refresh()
        XCTAssertEqual(success.snapshot?.entries.first?.title, "Filmix")
        let offline = PluginCatalogStore(defaults: defaults, fetch: { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(offline.snapshot?.entries.count, 1)
        await offline.refresh()
        XCTAssertEqual(offline.snapshot?.entries.first?.title, "Filmix")
        XCTAssertNotNil(offline.error)
    }
}
