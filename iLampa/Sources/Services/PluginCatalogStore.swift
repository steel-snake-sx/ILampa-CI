import Foundation

private final class CatalogRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.host?.lowercased() == "raw.githubusercontent.com" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Public registry metadata is untrusted and is never executed by this service.
@MainActor
final class PluginCatalogStore: ObservableObject {
    static let registryURL = URL(string: "https://raw.githubusercontent.com/lampaplugins/store/main/extensions.json")!
    private static let cacheKey = "ilampa_lampaplugins_catalog_v1"
    // The public extensions.json still lists the removed flat URL. The
    // publisher moved this script into its Shikimori/ directory. Match
    // only this exact retired path; never rewrite arbitrary plugin URLs.
    private static let knownMovedScripts: [String: String] = [
        "https://lampame.github.io/main/shikimori.js":
            "https://lampame.github.io/main/Shikimori/Shikimori.js"
    ]

    struct Snapshot: Codable {
        let entries: [PluginCatalogEntry]
        let unsupportedCount: Int
        let fetchedAt: Date
    }

    private struct Registry: Decodable {
        struct Category: Decodable {
            struct Item: Decodable {
                let name: String?
                let author: String?
                let link: String?
                let descr: String?
            }
            let title: String?
            let results: [Item]
        }
        let results: [Category]
    }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)

    init(defaults: UserDefaults = .standard, fetch: ((URLRequest) async throws -> (Data, URLResponse))? = nil) {
        self.defaults = defaults
        self.fetch = fetch ?? { request in
            let session = URLSession(configuration: .ephemeral, delegate: CatalogRedirectDelegate(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (bytes, response) = try await session.bytes(for: request)
            guard response.expectedContentLength <= 2_000_000 else { throw CatalogError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 2_000_000 else { throw CatalogError.invalidResponse }
                data.append(byte)
            }
            return (data, response)
        }
        if let data = defaults.data(forKey: Self.cacheKey) {
            snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        }
    }

    static func parse(_ data: Data, registryURL: URL = PluginCatalogStore.registryURL, fetchedAt: Date = Date()) throws -> Snapshot {
        guard data.count <= 2_000_000 else { throw CatalogError.invalidResponse }
        let registry = try JSONDecoder().decode(Registry.self, from: data)
        let provenance = PluginCatalogEntry.Provenance(registryID: "lampaplugins-store", registryURL: registryURL)
        var entries: [PluginCatalogEntry] = []
        var seen = Set<String>()
        var unsupported = 0
        func clean(_ value: String?, limit: Int) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return String(value.prefix(limit))
        }
        for category in registry.results {
            for item in category.results {
                guard let raw = item.link, let originalURL = PluginCatalogEntry.normalizedHTTPSURL(raw),
                      let title = clean(item.name, limit: 160) else {
                    unsupported += 1
                    continue
                }
                let url = Self.knownMovedScripts[originalURL.absoluteString]
                    .flatMap(PluginCatalogEntry.normalizedHTTPSURL) ?? originalURL
                guard seen.insert(url.absoluteString).inserted else { continue }
                entries.append(PluginCatalogEntry(sourceURL: url, title: title,
                    author: clean(item.author, limit: 120), description: clean(item.descr, limit: 500),
                    category: clean(category.title, limit: 120), provenance: [provenance], compatibility: .notTested))
            }
        }
        guard !entries.isEmpty else { throw CatalogError.invalidResponse }
        return Snapshot(entries: entries, unsupportedCount: unsupported, fetchedAt: fetchedAt)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            var request = URLRequest(url: Self.registryURL)
            request.timeoutInterval = 15
            let (data, response) = try await fetch(request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  http.url?.scheme?.lowercased() == "https",
                  http.url?.host?.lowercased() == Self.registryURL.host?.lowercased() else {
                throw CatalogError.invalidResponse
            }
            let updated = try Self.parse(data)
            let encoded = try JSONEncoder().encode(updated)
            defaults.set(encoded, forKey: Self.cacheKey)
            snapshot = updated
            error = nil
        } catch {
            self.error = "Не удалось обновить каталог. Сохранённая копия, если есть, остаётся доступной."
        }
    }

    private enum CatalogError: Error { case invalidResponse }
}
