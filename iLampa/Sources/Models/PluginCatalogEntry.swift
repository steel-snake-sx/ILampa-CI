import Foundation

/// Catalog presence is not evidence of installability or native compatibility.
struct PluginCatalogEntry: Identifiable, Codable, Equatable {
    enum Compatibility: String, Codable {
        case notTested, nativeSupported, webKitOnly, partial, unsupported, loadFailed
    }

    struct Provenance: Codable, Equatable, Hashable {
        let registryID: String
        let registryURL: URL
    }

    /// Exact normalized URL is the deduplication key. Query parameters are retained.
    let sourceURL: URL
    let title: String
    let author: String?
    let description: String?
    let category: String?
    let provenance: [Provenance]
    let compatibility: Compatibility

    var id: String { sourceURL.absoluteString }

    /// Registry entries with credentials or non-HTTPS URLs are never silently promoted
    /// to installable entries. Callers should surface them separately as unsupported.
    static func normalizedHTTPSURL(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil else { return nil }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.url
    }
}
